// Empacota dist/{x86,x64,arm64}/** no formato W2EA lido pelo instalador.
// Formato: "W2EA\0" | u32 n | n x ( u16 nome_len | nome "arch/rel/path" | u64 tam | bytes ) — little-endian.
#include <algorithm>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

namespace fs = std::filesystem;
static void w16(std::ostream& f, uint16_t x) { unsigned char b[2] = {(unsigned char)x, (unsigned char)(x >> 8)}; f.write((char*)b, 2); }
static void w32(std::ostream& f, uint32_t x) { for (int i = 0; i < 4; i++) f.put((char)(x >> (8 * i))); }
static void w64(std::ostream& f, uint64_t x) { for (int i = 0; i < 8; i++) f.put((char)(x >> (8 * i))); }

int main(int argc, char** argv) {
    if (argc != 3) { std::cerr << "uso: archive_builder <dist> <payload.bin>\n"; return 2; }
    fs::path root = argv[1], out = argv[2];
    std::vector<std::pair<std::string, fs::path>> files;
    for (const char* arch : {"x86", "x64", "arm64"}) {
        fs::path d = root / arch;
        if (!fs::is_directory(d)) { std::cerr << "diretório ausente: " << d << "\n"; return 3; }
        for (auto& e : fs::recursive_directory_iterator(d))
            if (e.is_regular_file()) files.emplace_back(std::string(arch) + "/" + e.path().lexically_relative(d).generic_string(), e.path());
    }
    std::sort(files.begin(), files.end());
    std::ofstream f(out, std::ios::binary | std::ios::trunc);
    if (!f) { std::cerr << "não foi possível criar " << out << "\n"; return 4; }
    f.write("W2EA\0", 5);
    w32(f, (uint32_t)files.size());
    for (auto& [name, path] : files) {
        if (name.size() > 0xFFFF) { std::cerr << "nome longo demais: " << name << "\n"; return 6; }
        std::ifstream in(path, std::ios::binary);
        std::vector<char> data((size_t)fs::file_size(path));
        if (!in.read(data.data(), (std::streamsize)data.size())) { std::cerr << "falha ao ler " << path << "\n"; return 7; }
        w16(f, (uint16_t)name.size());
        f.write(name.data(), (std::streamsize)name.size());
        w64(f, data.size());
        f.write(data.data(), (std::streamsize)data.size());
    }
    return f ? 0 : 5;
}
