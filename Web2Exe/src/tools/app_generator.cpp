// Gera main.cpp / resources.rc / app.manifest do app a partir dos templates.
// Uso: app_generator main.cpp.in resources.rc.in app.manifest.in NAME VERSION ID URL ICON out_main out_rc out_manifest
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

static std::string read_file(const char* p) {
    std::ifstream f(p, std::ios::binary);
    if (!f) { std::cerr << "não foi possível ler " << p << "\n"; std::exit(3); }
    std::ostringstream s; s << f.rdbuf(); return s.str();
}
// Escapa para literal C/RC entre aspas.
static std::string esc(const std::string& s) {
    std::string o;
    for (char c : s) {
        if (c == '\\' || c == '"') o += '\\';
        if (c == '\n' || c == '\r') continue;
        o += c;
    }
    return o;
}
static void rep(std::string& s, const std::string& a, const std::string& b) {
    for (size_t p = 0; (p = s.find(a, p)) != std::string::npos; p += b.size()) s.replace(p, a.size(), b);
}
// "1.2.3" -> "1,2,3,0"
static std::string numeric_version(const std::string& v) {
    std::string out; int parts = 0; std::string cur;
    auto flush = [&]() { out += (parts ? "," : "") + (cur.empty() ? std::string("0") : cur); ++parts; cur.clear(); };
    for (char c : v) { if (c == '.') flush(); else if (c >= '0' && c <= '9') cur += c; }
    flush();
    while (parts < 4) { out += ",0"; ++parts; }
    return out;
}
int main(int argc, char** argv) {
    if (argc != 12) { std::cerr << "uso: app_generator main rc manifest NAME VERSION ID URL ICON out_main out_rc out_manifest\n"; return 2; }
    std::string a = read_file(argv[1]), r = read_file(argv[2]), m = read_file(argv[3]);
    const std::string name = argv[4], version = argv[5], id = argv[6], url = argv[7], icon = argv[8];
    rep(a, "__WEB2EXE_URL__", esc(url));
    rep(a, "__WEB2EXE_NAME__", esc(name));
    rep(a, "__WEB2EXE_ID__", esc(id));
    rep(r, "__WEB2EXE_NAME__", esc(name));
    rep(r, "__WEB2EXE_VERSION_NUM__", numeric_version(version));
    rep(r, "__WEB2EXE_VERSION__", esc(version));
    rep(r, "__WEB2EXE_ICON__", esc(icon));
    rep(r, "__WEB2EXE_MANIFEST__", esc(argv[11]));
    std::ofstream(argv[9], std::ios::binary) << a;
    std::ofstream(argv[10], std::ios::binary) << r;
    std::ofstream(argv[11], std::ios::binary) << m;
    return 0;
}
