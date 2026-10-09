// Web2Exe CLI — gera aplicativos Windows (WebView2) a partir de uma URL.
// Roda no Termux (Bionic/NDK) e em Linux comum.
#include <algorithm>
#include <cctype>
#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <optional>
#include <regex>
#include <sstream>
#include <string>
#include <vector>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include "i18n.hpp"

namespace fs = std::filesystem;
static constexpr const char* kVersion = WEB2EXE_VERSION;

using Props = std::map<std::string, std::string>;

// ------------------------------------------------------------------ log ----
static void info(const std::string& s) { std::cout << "[INFO] " << s << '\n'; }
static void ok(const std::string& s)   { std::cout << "[ OK ] " << s << '\n'; }
static void warn(const std::string& s) { std::cout << "[WARN] " << s << '\n'; }
static void err(const std::string& s)  { std::cout.flush(); std::cerr << "[ERR ] " << s << '\n'; }

// ---------------------------------------------------------------- utils ----
static std::string trim(std::string s) {
    auto ws = [](unsigned char c) { return std::isspace(c) != 0; };
    s.erase(s.begin(), std::find_if(s.begin(), s.end(), [&](char c) { return !ws((unsigned char)c); }));
    s.erase(std::find_if(s.rbegin(), s.rend(), [&](char c) { return !ws((unsigned char)c); }).base(), s.end());
    return s;
}
static std::string lower(std::string s) {
    for (char& c : s) c = (char)std::tolower((unsigned char)c);
    return s;
}
static const char* env(const char* k) { const char* v = std::getenv(k); return (v && *v) ? v : nullptr; }

static bool is_executable_file(const fs::path& p) {
    std::error_code ec;
    return fs::is_regular_file(p, ec) && access(p.c_str(), X_OK) == 0;
}
static fs::path find_in_path(const std::string& name) {
    if (name.find('/') != std::string::npos) return is_executable_file(name) ? fs::path(name) : fs::path();
    const char* path = env("PATH");
    if (!path) return {};
    std::string p(path);
    size_t a = 0;
    while (a <= p.size()) {
        size_t b = p.find(':', a);
        if (b == std::string::npos) b = p.size();
        if (b > a) {
            fs::path q = fs::path(p.substr(a, b - a)) / name;
            if (is_executable_file(q)) return q;
        }
        if (b == p.size()) break;
        a = b + 1;
    }
    return {};
}
static bool command_exists(const std::string& x) { return !find_in_path(x).empty(); }

static bool is_termux() {
    const char* prefix = env("PREFIX");
    if (!prefix) return false;
    return env("TERMUX_VERSION") != nullptr || std::string(prefix).find("com.termux") != std::string::npos;
}
static std::string host_arch() {
    struct utsname u{};
    if (uname(&u) == 0) return u.machine;
    return "desconhecida";
}

static fs::path project_root() {
    if (const char* p = env("WEB2EXE_PROJECT_ROOT")) return fs::path(p);
    return fs::current_path();
}
// Diretório com scripts/, cmake/ e src/. Em instalação Termux é $PREFIX/share/web2exe.
static fs::path data_root() {
    if (const char* p = env("WEB2EXE_DATA_ROOT")) return fs::path(p);
    std::error_code ec;
    fs::path self = fs::read_symlink("/proc/self/exe", ec);
    if (!ec && fs::exists(self.parent_path() / "scripts")) return self.parent_path();
    fs::path up = self.parent_path().parent_path();
    if (!ec && fs::exists(up / "scripts")) return up;
    return fs::current_path();
}

// --------------------------------------------------------- properties ----
static bool valid_key(const std::string& k) {
    static const std::regex re("[A-Z][A-Z0-9_]*");
    return std::regex_match(k, re);
}

// Formato: KEY=valor. Linhas indentadas continuam a chave anterior. '#' e ';' são comentários.
static std::optional<Props> parse_properties(std::istream& in, std::string& why) {
    Props c;
    std::string line, current;
    size_t n = 0;
    while (std::getline(in, line)) {
        ++n;
        if (n == 1 && line.size() >= 3 && (unsigned char)line[0] == 0xEF && (unsigned char)line[1] == 0xBB &&
            (unsigned char)line[2] == 0xBF)
            line.erase(0, 3);  // BOM UTF-8
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.find('\0') != std::string::npos) { why = "byte NUL na linha " + std::to_string(n); return std::nullopt; }
        if (line.empty()) { if (!current.empty()) c[current].push_back('\n'); continue; }
        bool cont = !current.empty() && (line[0] == ' ' || line[0] == '\t');
        if (!cont && (line[0] == '#' || line[0] == ';')) continue;
        auto eq = line.find('=');
        if (!cont && eq != std::string::npos) {
            std::string k = trim(line.substr(0, eq));
            if (!valid_key(k)) { why = "chave inválida na linha " + std::to_string(n) + ": " + k; return std::nullopt; }
            current = k;
            c[k] = line.substr(eq + 1);
            continue;
        }
        if (cont) {
            size_t first = line.find_first_not_of(" \t");
            std::string part = first == std::string::npos ? "" : line.substr(first);
            if (!c[current].empty()) c[current].push_back('\n');
            c[current] += part;
            continue;
        }
        why = "linha " + std::to_string(n) + " não é KEY=VALUE";
        return std::nullopt;
    }
    for (auto& [k, v] : c) {
        while (!v.empty() && v.back() == '\n') v.pop_back();
        v = trim(v);  // remove espaços acidentais nas pontas (ex.: caminhos colados)
    }
    return c;
}
static std::optional<Props> parse_properties_file(const fs::path& p, std::string& why) {
    std::ifstream f(p);
    if (!f) { why = "não foi possível abrir " + p.string(); return std::nullopt; }
    return parse_properties(f, why);
}

static bool has_bad_control(const std::string& s) {
    for (unsigned char c : s) if (c < 0x20 && c != '\t') return true;
    return false;
}
static std::string expand_home(const std::string& p) {
    if (!p.empty() && p[0] == '~' && (p.size() == 1 || p[1] == '/')) if (const char* h = env("HOME")) return h + p.substr(1);
    return p;
}
static void normalize(Props& c) {
    if (auto it = c.find("APP_URL"); it != c.end()) {
        std::string& u = it->second;
        u = trim(u);
        if (u.rfind("http://", 0) == 0) u = "https://" + u.substr(7);
        else if (!u.empty() && u.rfind("https://", 0) != 0) u = "https://" + u;
    }
    for (const char* k : {"APP_LOGO", "APP_ICON"})
        if (auto it = c.find(k); it != c.end()) it->second = expand_home(it->second);
    if (!c.count("APP_VERSION") || c["APP_VERSION"].empty()) c["APP_VERSION"] = "1.0.0";
    if (!c.count("INSTALL_DIR") || trim(c["INSTALL_DIR"]).empty()) c["INSTALL_DIR"] = c["APP_NAME"];
}

static bool validate(const Props& c, std::string& why) {
    auto get = [&](const char* k) -> std::string { auto it = c.find(k); return it == c.end() ? "" : it->second; };
    static const std::regex re_id("[A-Za-z0-9][A-Za-z0-9._-]*");
    static const std::regex re_ver("[0-9]+(\\.[0-9]+){0,3}");
    const std::string name = get("APP_NAME"), id = get("APP_ID"), url = get("APP_URL"), logo = get("APP_LOGO"),
                      icon = get("APP_ICON"), dir = get("INSTALL_DIR"), ver = get("APP_VERSION");
    if (name.empty() || name.size() > 200 || has_bad_control(name)) { why = "APP_NAME vazio, longo demais ou com caracteres de controle"; return false; }
    if (id.empty() || id.size() > 80 || !std::regex_match(id, re_id) || id == "." || id == "..") { why = "APP_ID deve ser um nome de .exe válido (sem a extensão)"; return false; }
    if (!ver.empty() && !std::regex_match(ver, re_ver)) { why = "APP_VERSION deve ser numérica, ex.: 1.0.0"; return false; }
    if (url.size() > 2048 || has_bad_control(url) || url.rfind("https://", 0) != 0 || url.size() <= 8 ||
        url.find_first_of(" \t<>\"'\\") != std::string::npos) { why = "APP_URL deve ser uma URL HTTPS válida"; return false; }

    if (c.count("WINE_COMPAT")) {
        std::string w = lower(c.at("WINE_COMPAT"));
        if (w != "0" && w != "1" && w != "true" && w != "false" && w != "yes" && w != "no" && w != "on" && w != "off" && w != "sim" && w != "auto" && !w.empty()) {
            why = "WINE_COMPAT deve ser auto, 0 ou 1"; return false;
        }
    }
    if (c.count("WINE_EMU")) {
        std::string e = lower(c.at("WINE_EMU"));
        if (e != "auto" && e != "box64" && e != "qemu" && !e.empty()) { why = "WINE_EMU deve ser auto, box64 ou qemu"; return false; }
    }
    std::error_code ec;
    if (logo.empty() || !fs::is_regular_file(logo, ec)) { why = "APP_LOGO não aponta para um arquivo: " + logo; return false; }
    std::ifstream lg(logo, std::ios::binary);
    unsigned char lh[12]{};
    lg.read((char*)lh, 12);
    bool image = lg.gcount() >= 8 &&
        ((lh[0] == 0x89 && lh[1] == 'P' && lh[2] == 'N' && lh[3] == 'G' && lh[4] == 0x0d && lh[5] == 0x0a && lh[6] == 0x1a && lh[7] == 0x0a) ||
         (lh[0] == 0xff && lh[1] == 0xd8) || (lh[0] == 'B' && lh[1] == 'M') ||
         (lh[0] == 'R' && lh[1] == 'I' && lh[2] == 'F' && lh[3] == 'F' && lh[8] == 'W' && lh[9] == 'E' && lh[10] == 'B' && lh[11] == 'P'));
    if (!image) { why = "APP_LOGO não é PNG/JPEG/BMP/WebP reconhecível"; return false; }

    if (icon.empty() || !fs::is_regular_file(icon, ec)) { why = "APP_ICON não aponta para um arquivo: " + icon; return false; }
    std::ifstream ic(icon, std::ios::binary);
    unsigned char h[6]{};
    ic.read((char*)h, 6);
    uint16_t count = (uint16_t)(h[4] | (h[5] << 8));
    if (ic.gcount() != 6 || h[0] != 0 || h[1] != 0 || h[2] != 1 || h[3] != 0 || count < 1) {
        why = "APP_ICON não é um .ico válido (um .png renomeado não funciona; converta de verdade)";
        return false;
    }
    if (dir.empty() || dir.size() > 120 || dir == "." || dir == ".." || dir.find_first_of("<>:\"/\\|?*") != std::string::npos ||
        dir.back() == '.' || dir.back() == ' ' || has_bad_control(dir)) { why = "INSTALL_DIR não é um nome de pasta seguro do Windows"; return false; }
    return true;
}

// --------------------------------------------------------- execução ----
static fs::path find_bash() {
    if (const char* b = env("BASH")) if (b[0] == '/' && is_executable_file(b)) return b;   // só vale se existir de verdade
    if (const char* p = env("PREFIX")) if (is_executable_file(fs::path(p) / "bin/bash")) return fs::path(p) / "bin/bash";
    if (auto p = find_in_path("bash"); !p.empty()) return p;
    for (const char* c : {"/data/data/com.termux/files/usr/bin/bash", "/usr/bin/bash", "/bin/bash"})
        if (is_executable_file(c)) return c;
    return {};
}

// Executa um comando e devolve o código de saída. Nunca falha em silêncio:
// qualquer problema de exec é descrito em stderr.
static int run(std::vector<std::string> cmd) {
    if (cmd.empty()) { err("comando vazio"); return 127; }
    if (fs::path(cmd[0]).extension() == ".sh") {
        // Scripts são sempre executados via bash: o bit +x pode se perder ao copiar/extrair (comum no Termux).
        std::error_code ec;
        if (!fs::is_regular_file(cmd[0], ec)) {
            err("script não encontrado: " + cmd[0]);
            err("WEB2EXE_DATA_ROOT=" + data_root().string() + " — reinstale com ./install.sh");
            return 127;
        }
        fs::path bash = find_bash();
        if (bash.empty()) { err("bash não encontrado. No Termux: pkg install bash"); return 127; }
        cmd.insert(cmd.begin(), bash.string());
    } else if (fs::path p = find_in_path(cmd[0]); !p.empty()) {
        cmd[0] = p.string();
    } else {
        err("comando não encontrado: " + cmd[0]);
        return 127;
    }
    std::string shown;
    for (auto& s : cmd) shown += (shown.empty() ? "" : " ") + s;
    info("Executando: " + shown);

    std::vector<char*> av;
    for (auto& s : cmd) av.push_back(const_cast<char*>(s.c_str()));
    av.push_back(nullptr);

    int pipefd[2];
    if (pipe(pipefd) != 0) { err(std::string("pipe: ") + std::strerror(errno)); return 127; }
    fcntl(pipefd[1], F_SETFD, FD_CLOEXEC);
    std::cout.flush(); std::cerr.flush();
    pid_t pid = fork();
    if (pid < 0) { err(std::string("fork: ") + std::strerror(errno)); return 127; }
    if (pid == 0) {
        close(pipefd[0]);
        execv(av[0], av.data());
        int e = errno;
        ssize_t w = write(pipefd[1], &e, sizeof e);
        (void)w;
        _exit(127);
    }
    close(pipefd[1]);
    int child_errno = 0;
    ssize_t got;
    while ((got = read(pipefd[0], &child_errno, sizeof child_errno)) < 0 && errno == EINTR) {}
    close(pipefd[0]);
    int st = 0;
    while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
    if (got == (ssize_t)sizeof child_errno) {
        err("falha ao executar " + cmd[0] + ": " + std::strerror(child_errno));
        return 127;
    }
    if (WIFEXITED(st)) return WEXITSTATUS(st);
    if (WIFSIGNALED(st)) { err("processo terminou por sinal " + std::to_string(WTERMSIG(st))); return 128 + WTERMSIG(st); }
    return 1;
}

// ---------------------------------------------------------- comandos ----
static void help() {
    std::cout <<
"Web2Exe " << kVersion << "\n\n"
"Transforma sites em aplicativos Windows nativos (WebView2), compilando no Termux/Linux.\n\n"
"Uso:\n"
"  web2exe                              assistente interativo\n"
"  web2exe build [--native|--chroot|--proot]   compila usando ./build.prop\n"
"  web2exe --properties-file build.prop        valida e compila\n"
"  web2exe doctor | clean | --version | --help\n\n"
"Opções:\n"
"  --termux / --linux     força o ambiente\n"
"  --native               LLVM-MinGW nativo do Termux (padrão e recomendado)\n"
"  --chroot / --proot     compila dentro de um Debian (chroot-distro / proot-distro)\n"
"  --properties           lê as propriedades pela entrada padrão\n"
"  --properties-file <f>  lê as propriedades de um arquivo\n"
"  --check                só valida o build.prop, sem compilar\n"
"  --wine                 exige a variante Wine no instalador único (padrão: auto)\n\n"
"Formato do build.prop:\n"
"  APP_NAME=Meu Aplicativo\n"
"  APP_ID=meu-aplicativo\n"
"  APP_VERSION=1.0.0\n"
"  APP_URL=https://example.com\n"
"  APP_LOGO=/caminho/logo.png\n"
"  APP_ICON=/caminho/icone.ico\n"
"  INSTALL_DIR=Meu Aplicativo\n"
"  WINE_COMPAT=auto               (opcional: auto | 1 | 0 — variante Wine dentro do instalador)\n"
"  WINE_EMU=auto                  (opcional: auto | box64 | qemu — emulador x86_64 do modo Wine no Termux)\n\n"
"Linhas indentadas continuam o valor da propriedade anterior.\n";
}

static int doctor() {
    int critical = 0;
    auto need = [&](const std::string& c, bool essential) {
        auto p = find_in_path(c);
        if (!p.empty()) ok(c + " -> " + p.string());
        else if (essential) { err(c + " ausente"); ++critical; }
        else warn(c + " ausente");
    };
    std::cout << "Web2Exe " << tr("doctor") << " (v" << kVersion << ")\n\n";
    ok(tr("system") + ": " + (is_termux() ? "Termux" : "Linux"));
    ok(tr("host") + ": " + host_arch());
    fs::path bash = find_bash();
    if (!bash.empty()) ok("bash -> " + bash.string()); else { err("bash ausente"); ++critical; }
    if (const char* b = env("BASH"); b && !is_executable_file(b)) warn(std::string("a variável BASH aponta para algo inexistente (") + b + ") — ignorada");
    fs::path d = data_root();
    for (const char* f : {"scripts/build.sh", "scripts/common.sh", "scripts/termux-build.sh", "src/app/main.cpp"}) {
        if (fs::exists(d / f)) ok("recurso: " + (d / f).string());
        else { err("recurso ausente: " + (d / f).string()); ++critical; }
    }
    for (auto c : {"cmake", "clang++", "curl", "unzip", "tar"}) need(c, true);
    need("ninja", false);
    if (is_termux()) {
        for (auto c : {"x86_64-w64-mingw32-clang++", "i686-w64-mingw32-clang++", "aarch64-w64-mingw32-clang++"}) need(c, true);
        bool rc = command_exists("llvm-rc") || command_exists("x86_64-w64-mingw32-windres") || command_exists("llvm-windres");
        if (rc) ok("compilador de recursos (llvm-rc/windres) encontrado"); else { err("llvm-rc/windres ausente"); ++critical; }
        need("ld.lld", false);
        need("llvm-readobj", false);
        need("llvm-objdump", false);
        need("proot-distro", false);
        need("chroot-distro", false);
    }
    fs::path home = env("HOME") ? fs::path(env("HOME")) : fs::path(".");
    fs::path cache = home / ".cache/web2exe";
    std::error_code ec;
    auto sp = fs::space(home, ec);
    ok(tr("cache") + ": " + cache.string());
    if (!ec) ok(tr("space") + ": " + std::to_string(sp.available / 1024 / 1024) + " MiB");
    fs::path bp = project_root() / "build.prop";
    if (fs::exists(bp)) {
        std::string why;
        auto c = parse_properties_file(bp, why);
        if (c) { normalize(*c); if (validate(*c, why)) ok("build.prop válido: " + bp.string()); else { warn("build.prop inválido: " + why); } }
        else warn("build.prop ilegível: " + why);
    }
    std::cout << '\n';
    if (critical) { err(std::to_string(critical) + " problema(s) crítico(s)."); return 1; }
    ok("Ambiente pronto.");
    return 0;
}

static int clean() {
    fs::path project = project_root();
    for (auto p : {project / "build", project / "dist", project / ".web2exe-tmp", project / ".web2exe-tmp-appgen"}) {
        std::error_code e;
        fs::remove_all(p, e);
        if (e) { err("falha ao limpar " + p.string() + ": " + e.message()); return 1; }
    }
    ok(tr("clean_ok"));
    return 0;
}

static int dispatch_build(const std::string& mode) {
    fs::path data = data_root(), project = project_root();
    setenv("WEB2EXE_PROJECT_ROOT", project.c_str(), 1);
    setenv("WEB2EXE_DATA_ROOT", data.c_str(), 1);
    if (!mode.empty()) return run({(data / "scripts/termux-build.sh").string(), mode});
    return run({(data / "scripts/build.sh").string()});
}

static std::string serialize(const Props& c) {
    static const char* required[] = {"APP_NAME", "APP_ID", "APP_VERSION", "APP_URL", "APP_LOGO", "APP_ICON", "INSTALL_DIR"};
    std::ostringstream o;
    auto put = [&](const std::string& k, const std::string& v) {
        size_t pos = 0;
        while (true) {
            size_t nl = v.find('\n', pos);
            o << (pos == 0 ? k + "=" : std::string("  ")) << v.substr(pos, nl == std::string::npos ? std::string::npos : nl - pos) << '\n';
            if (nl == std::string::npos) break;
            pos = nl + 1;
        }
    };
    for (auto k : required) if (c.count(k)) put(k, c.at(k));
    for (auto& [k, v] : c) {
        bool req = false;
        for (auto r : required) if (k == r) req = true;
        if (!req) put(k, v);
    }
    return o.str();
}

static int write_and_build(Props c, const std::string& mode, bool check_only) {
    normalize(c);
    std::string why;
    if (!validate(c, why)) { err(why); return 2; }
    fs::path target = project_root() / "build.prop";
    std::string text = serialize(c), old;
    if (std::ifstream f(target); f) { std::ostringstream s; s << f.rdbuf(); old = s.str(); }
    if (old != text) {  // só reescreve se mudou; escrita atômica
        std::error_code ec;
        fs::create_directories(project_root(), ec);
        fs::path tmp = target; tmp += ".tmp";
        { std::ofstream f(tmp, std::ios::trunc | std::ios::binary); f << text; if (!f) { err("não foi possível escrever " + tmp.string()); return 2; } }
        fs::rename(tmp, target, ec);
        if (ec) { err("não foi possível gravar " + target.string() + ": " + ec.message()); return 2; }
        info("build.prop atualizado: " + target.string());
    }
    ok(tr("config_ok"));
    if (check_only) return 0;
    return dispatch_build(mode);
}

// ------------------------------------------------- seletor de arquivos ----
static bool stdin_tty() { return isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0; }
static bool extension_allowed(const fs::path& p, bool icon_mode) {
    if (!p.has_extension()) return false;
    std::string e = lower(p.extension().string());
    if (icon_mode) return e == ".ico";
    return e == ".png" || e == ".jpg" || e == ".jpeg" || e == ".bmp" || e == ".webp";
}
static std::string shorten_path(const fs::path& p) {
    std::string s = p.lexically_normal().string();
    if (const char* home = env("HOME")) {
        std::string h = fs::path(home).lexically_normal().string();
        if (s == h) return "~";
        if (s.rfind(h + "/", 0) == 0) return "~" + s.substr(h.size());
    }
    return s;
}
static std::optional<std::string> file_picker(const std::string& title, bool icon_mode) {
    if (!stdin_tty()) {
        std::cout << title << " (caminho completo):\n> ";
        std::string p; std::getline(std::cin, p);
        return p.empty() ? std::nullopt : std::optional<std::string>(p);
    }
    struct termios oldt{}, raw{};
    if (tcgetattr(STDIN_FILENO, &oldt) != 0) return std::nullopt;
    raw = oldt;
    raw.c_lflag &= (tcflag_t) ~(ICANON | ECHO);
    raw.c_cc[VMIN] = 1; raw.c_cc[VTIME] = 0;
    if (tcsetattr(STDIN_FILENO, TCSANOW, &raw) != 0) return std::nullopt;
    auto restore = [&]() { tcsetattr(STDIN_FILENO, TCSANOW, &oldt); std::cout << "\x1b[2J\x1b[H"; };
    // começa em ~/storage/shared/Download, se existir (atalho comum no Termux)
    fs::path current = fs::current_path();
    if (const char* h = env("HOME")) { std::error_code e; fs::path dl = fs::path(h) / "storage/shared/Download"; if (fs::is_directory(dl, e)) current = dl; }
    size_t index = 0;
    bool show_hidden = false;
    while (true) {
        std::vector<fs::directory_entry> entries;
        std::error_code ec;
        for (auto it = fs::directory_iterator(current, fs::directory_options::skip_permission_denied, ec); !ec && it != fs::directory_iterator(); it.increment(ec)) {
            auto e = *it;
            std::string n = e.path().filename().string();
            if (!show_hidden && !n.empty() && n[0] == '.') continue;
            std::error_code e2;
            if (e.is_directory(e2) || (e.is_regular_file(e2) && extension_allowed(e.path(), icon_mode))) entries.push_back(e);
        }
        std::sort(entries.begin(), entries.end(), [](const auto& a, const auto& b) {
            std::error_code ea, eb;
            bool da = a.is_directory(ea), db = b.is_directory(eb);
            if (da != db) return da > db;
            return lower(a.path().filename().string()) < lower(b.path().filename().string());
        });
        size_t total = entries.size() + 1;
        if (index >= total) index = total - 1;
        std::cout << "\x1b[2J\x1b[H" << "Web2Exe - " << title << "\n\x1b[1m" << shorten_path(current) << "\x1b[0m\n\n"
                  << "Setas: navegar   Enter: abrir/selecionar   Backspace: voltar   h: ocultos   q: cancelar\n\n";
        const size_t max_show = 20;
        size_t first = index >= max_show ? index - max_show + 1 : 0, last = std::min(total, first + max_show);
        for (size_t i = first; i < last; i++) {
            std::string label;
            if (i == 0) label = "..";
            else { std::error_code e3; label = (entries[i - 1].is_directory(e3) ? "[DIR] " : "      ") + entries[i - 1].path().filename().string(); }
            std::cout << (i == index ? "> " : "  ") << label << "\n";
        }
        std::cout << "\n" << (icon_mode ? "Somente arquivos .ico" : "Imagens: PNG JPG JPEG BMP WebP") << std::endl;
        char c = 0;
        if (::read(STDIN_FILENO, &c, 1) != 1) { restore(); return std::nullopt; }
        if (c == 'q' || c == 'Q') { restore(); return std::nullopt; }
        if (c == 'h' || c == 'H') { show_hidden = !show_hidden; index = 0; continue; }
        if (c == 127 || c == 8) { if (current.has_parent_path() && current != current.root_path()) current = current.parent_path(); index = 0; continue; }
        if (c == 27) {
            char seq[2]{};
            if (::read(STDIN_FILENO, seq, 2) == 2 && seq[0] == '[') {
                if (seq[1] == 'A' && index > 0) --index;
                else if (seq[1] == 'B' && index + 1 < total) ++index;
            }
            continue;
        }
        if (c == '\r' || c == '\n') {
            if (index == 0) { if (current.has_parent_path() && current != current.root_path()) current = current.parent_path(); continue; }
            auto p = entries[index - 1].path();
            std::error_code e4;
            if (entries[index - 1].is_directory(e4)) { current = p; index = 0; continue; }
            restore();
            return p.string();
        }
    }
}
static std::string ask_path_or_picker(const std::string& label, bool icon_mode) {
    std::cout << label << ":\n> ";
    std::string typed; std::getline(std::cin, typed);
    typed = trim(typed);
    if (!typed.empty()) return expand_home(typed);
    return file_picker(icon_mode ? "Selecionar ícone" : "Selecionar logo", icon_mode).value_or("");
}

static int wizard(const std::string& mode) {
    Props c;
    std::string s;
    auto ask = [&](const char* label, const char* key) { std::cout << label << ":\n> "; std::getline(std::cin, s); c[key] = trim(s); };
    ask("Nome do aplicativo", "APP_NAME");
    ask("ID do aplicativo (ex.: meu-app)", "APP_ID");
    ask("URL (domínio ou HTTPS)", "APP_URL");
    c["APP_LOGO"] = ask_path_or_picker("Logo (Enter para abrir o gerenciador)", false);
    c["APP_ICON"] = ask_path_or_picker("Ícone .ico (Enter para abrir o gerenciador)", true);
    normalize(c);
    std::cout << "\nResumo:\n";
    for (auto& [k, v] : c) std::cout << k << ": " << v << "\n";
    std::cout << "\nConfirmar? [S/n]\n> ";
    std::getline(std::cin, s);
    if (!s.empty() && (s[0] == 'n' || s[0] == 'N')) return 0;
    return write_and_build(c, mode, false);
}

int main(int argc, char** argv) {
    bool term = is_termux(), check_only = false, properties = false, do_build = false, do_doctor = false, do_clean = false;
    std::string mode;
    std::optional<fs::path> properties_file;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--help" || a == "-h" || a == "help") { help(); return 0; }
        else if (a == "--version" || a == "-v") { std::cout << kVersion << '\n'; return 0; }
        else if (a == "doctor" || a == "--doctor") do_doctor = true;
        else if (a == "clean" || a == "--clean") do_clean = true;
        else if (a == "build") do_build = true;
        else if (a == "--check") check_only = true;
        else if (a == "--wine") setenv("WEB2EXE_WINE", "1", 1);
        else if (a == "--termux") term = true;
        else if (a == "--linux") term = false;
        else if (a == "--chroot") mode = "chroot";
        else if (a == "--proot") mode = "proot";
        else if (a == "--native") mode = "native";
        else if (a == "--properties" || a == "--proprietities") properties = true;
        else if (a == "--properties-file") {
            if (i + 1 >= argc) { err("--properties-file exige um arquivo"); return 2; }
            properties = true; properties_file = fs::path(argv[++i]);
        } else { err("opção desconhecida: " + a + " (veja web2exe --help)"); return 2; }
    }
    if (do_doctor) return doctor();
    if (do_clean) return clean();

    if (term) {
        info(tr("detected_termux"));
        if (mode.empty() && !properties && !do_build && stdin_tty()) {
            std::cout << "Escolha o ambiente de build:\n[1] Termux nativo (recomendado)\n[2] CHROOT\n[3] PRoot\n> ";
            std::string x; std::getline(std::cin, x);
            mode = x == "2" ? "chroot" : (x == "3" ? "proot" : "native");
        }
        if (mode.empty()) mode = "native";   // nunca cai no toolchain glibc, que não roda no Bionic
        info("Modo selecionado: " + mode);
    } else if (!mode.empty()) {
        warn("--native/--chroot/--proot só se aplicam ao Termux; ignorado.");
        mode.clear();
    }

    if (do_build || properties) {
        std::string why;
        std::optional<Props> c;
        if (properties_file) c = parse_properties_file(*properties_file, why);
        else if (do_build) c = parse_properties_file(project_root() / "build.prop", why);
        else c = parse_properties(std::cin, why);
        if (!c) { err(why); return 2; }
        std::cout << "\nResumo das propriedades:\n";
        for (auto& [k, v] : *c) std::cout << k << "=" << v << "\n";
        return write_and_build(*c, mode, check_only);
    }
    return wizard(mode);
}
