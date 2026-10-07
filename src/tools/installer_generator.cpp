// Gera o fonte do instalador a partir do template (o payload vai como recurso RCDATA, não como array C++).
// Uso: installer_generator template.cpp out.cpp NAME ID EXE_NAME VERSION INSTALL_DIR
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

static std::string esc(const std::string& s) {
    std::string o;
    for (char c : s) { if (c == '\\' || c == '"') o += '\\'; if (c == '\n' || c == '\r') continue; o += c; }
    return o;
}
static void rep(std::string& s, const std::string& a, const std::string& b) {
    for (size_t p = 0; (p = s.find(a, p)) != std::string::npos; p += b.size()) s.replace(p, a.size(), b);
}
int main(int argc, char** argv) {
    if (argc != 8) { std::cerr << "uso: installer_generator template out NAME ID EXE_NAME VERSION INSTALL_DIR\n"; return 2; }
    std::ifstream t(argv[1], std::ios::binary);
    if (!t) { std::cerr << "não foi possível ler " << argv[1] << "\n"; return 3; }
    std::ostringstream ss; ss << t.rdbuf();
    std::string src = ss.str();
    rep(src, "__WEB2EXE_NAME__", esc(argv[3]));
    rep(src, "__WEB2EXE_ID__", esc(argv[4]));
    rep(src, "__WEB2EXE_EXE_NAME__", esc(argv[5]));
    rep(src, "__WEB2EXE_VERSION__", esc(argv[6]));
    rep(src, "__WEB2EXE_INSTALL_DIR__", esc(argv[7]));
    std::ofstream out(argv[2], std::ios::binary);
    out << src;
    return out ? 0 : 4;
}
