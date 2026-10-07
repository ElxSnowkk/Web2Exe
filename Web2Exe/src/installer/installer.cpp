// Instalador universal (PE x86). O payload W2EA (x86/x64/arm64) está embutido como recurso RCDATA "W2E_PAYLOAD".
// Instala por usuário em %LOCALAPPDATA%\<INSTALL_DIR>: não exige administrador.
//   /S                 instalação silenciosa
//   --uninstall        desinstala (usado pelo registro do Windows)
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;
static const wchar_t* APP_NAME = L"__WEB2EXE_NAME__";
static const wchar_t* APP_ID = L"__WEB2EXE_ID__";
static const wchar_t* APP_EXE_NAME = L"__WEB2EXE_EXE_NAME__";
static const wchar_t* APP_VERSION = L"__WEB2EXE_VERSION__";
static const wchar_t* APP_DIR = L"__WEB2EXE_INSTALL_DIR__";

static bool g_silent = false;
static void message(const wchar_t* text, UINT icon) { if (!g_silent) MessageBoxW(nullptr, text, APP_NAME, MB_OK | icon); }

static std::string native_arch() {
    USHORT native = 0, process = 0;
    using F = BOOL(WINAPI*)(HANDLE, USHORT*, USHORT*);
    if (auto f = (F)GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "IsWow64Process2")) f(GetCurrentProcess(), &process, &native);
    if (!native) {
        SYSTEM_INFO s{};
        GetNativeSystemInfo(&s);
        switch (s.wProcessorArchitecture) {
        case PROCESSOR_ARCHITECTURE_ARM64: native = IMAGE_FILE_MACHINE_ARM64; break;
        case PROCESSOR_ARCHITECTURE_AMD64: native = IMAGE_FILE_MACHINE_AMD64; break;
        default: native = IMAGE_FILE_MACHINE_I386;
        }
    }
    return native == IMAGE_FILE_MACHINE_ARM64 ? "arm64" : native == IMAGE_FILE_MACHINE_AMD64 ? "x64" : "x86";
}

static fs::path known(REFKNOWNFOLDERID id) {
    PWSTR p = nullptr;
    fs::path r;
    if (SUCCEEDED(SHGetKnownFolderPath(id, 0, nullptr, &p))) { r = p; CoTaskMemFree(p); }
    return r;
}
static std::wstring lnk_name() { return std::wstring(APP_NAME) + L".lnk"; }

static bool make_shortcut(const fs::path& lnk, const fs::path& exe) {
    IShellLinkW* sl = nullptr;
    if (FAILED(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER, IID_IShellLinkW, (void**)&sl))) return false;
    sl->SetPath(exe.c_str());
    sl->SetWorkingDirectory(exe.parent_path().c_str());
    sl->SetIconLocation(exe.c_str(), 0);
    sl->SetDescription(APP_NAME);
    IPersistFile* pf = nullptr;
    bool okk = SUCCEEDED(sl->QueryInterface(IID_IPersistFile, (void**)&pf)) && SUCCEEDED(pf->Save(lnk.c_str(), TRUE));
    if (pf) pf->Release();
    sl->Release();
    return okk;
}

// Lê o payload embutido (recurso RCDATA).
static bool payload(const unsigned char*& data, size_t& size) {
    HRSRC r = FindResourceW(nullptr, L"W2E_PAYLOAD", RT_RCDATA);
    if (!r) return false;
    HGLOBAL g = LoadResource(nullptr, r);
    if (!g) return false;
    data = (const unsigned char*)LockResource(g);
    size = SizeofResource(nullptr, r);
    return data && size;
}

static bool safe_relative(const std::string& rel) {
    if (rel.empty() || rel[0] == '/' || rel[0] == '\\' || rel.find(':') != std::string::npos) return false;
    size_t pos = 0;
    while (pos <= rel.size()) {
        size_t n = rel.find_first_of("/\\", pos);
        std::string part = rel.substr(pos, n == std::string::npos ? std::string::npos : n - pos);
        if (part == "..") return false;
        if (n == std::string::npos) break;
        pos = n + 1;
    }
    return true;
}

static bool extract(const fs::path& root, const std::string& want, std::wstring& error) {
    const unsigned char* d = nullptr;
    size_t sz = 0;
    if (!payload(d, sz) || sz < 9 || std::memcmp(d, "W2EA\0", 5) != 0) { error = L"Payload inválido ou corrompido."; return false; }
    uint32_t n = 0;
    std::memcpy(&n, d + 5, 4);
    size_t off = 9;
    for (uint32_t i = 0; i < n; i++) {
        uint16_t nl = 0;
        if (off + 2 > sz) { error = L"Payload truncado."; return false; }
        std::memcpy(&nl, d + off, 2); off += 2;
        if (off + nl + 8 > sz) { error = L"Payload truncado."; return false; }
        std::string name((const char*)d + off, nl); off += nl;
        uint64_t dl = 0;
        std::memcpy(&dl, d + off, 8); off += 8;
        if (dl > sz - off) { error = L"Payload truncado."; return false; }
        auto slash = name.find('/');
        if (slash == std::string::npos || name.substr(0, slash) != want) { off += (size_t)dl; continue; }
        std::string rel = name.substr(slash + 1);
        if (!safe_relative(rel)) { error = L"Payload contém caminho inseguro."; return false; }
        fs::path out = root / fs::u8path(rel);
        std::error_code ec;
        fs::create_directories(out.parent_path(), ec);
        std::ofstream f(out, std::ios::binary | std::ios::trunc);
        if (!f) { error = L"Não foi possível gravar:\n" + out.wstring() + L"\n\nFeche o aplicativo se ele estiver aberto e tente novamente."; return false; }
        f.write((const char*)d + off, (std::streamsize)dl);
        if (!f) { error = L"Erro de escrita (disco cheio?)."; return false; }
        off += (size_t)dl;
    }
    return true;
}

static std::wstring uninstall_key() { return std::wstring(L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\") + APP_ID; }

// Remove atalhos, registro e arquivos. Roda a partir de uma cópia em %TEMP% (um .exe não apaga a si mesmo).
static int uninstall_run(const fs::path& root) {
    std::error_code e;
    fs::remove(known(FOLDERID_Programs) / APP_DIR / lnk_name(), e);
    fs::remove(known(FOLDERID_Programs) / APP_DIR, e);
    fs::remove(known(FOLDERID_Desktop) / lnk_name(), e);
    RegDeleteTreeW(HKEY_CURRENT_USER, uninstall_key().c_str());
    for (int i = 0; i < 20; i++) {  // aguarda o desinstalador original encerrar
        e.clear();
        fs::remove_all(root, e);
        if (!fs::exists(root)) break;
        Sleep(300);
    }
    fs::remove_all(known(FOLDERID_LocalAppData) / APP_ID, e);  // dados do WebView2
    wchar_t self[MAX_PATH]{};
    GetModuleFileNameW(nullptr, self, MAX_PATH);
    std::wstring cmd = L"/c ping 127.0.0.1 -n 3 >nul & del /f /q \"" + std::wstring(self) + L"\"";
    ShellExecuteW(nullptr, L"open", L"cmd.exe", cmd.c_str(), nullptr, SW_HIDE);
    message(L"Aplicativo removido.", MB_ICONINFORMATION);
    return 0;
}

static int uninstall_start() {
    fs::path root = known(FOLDERID_LocalAppData) / APP_DIR;
    if (!g_silent && MessageBoxW(nullptr, (std::wstring(L"Remover ") + APP_NAME + L"?").c_str(), APP_NAME, MB_YESNO | MB_ICONQUESTION) != IDYES) return 0;
    wchar_t self[MAX_PATH]{}, tmp[MAX_PATH]{};
    GetModuleFileNameW(nullptr, self, MAX_PATH);
    GetTempPathW(MAX_PATH, tmp);
    fs::path copy = fs::path(tmp) / (std::wstring(APP_ID) + L"-uninstall.exe");
    if (!CopyFileW(self, copy.c_str(), FALSE)) return uninstall_run(root);  // melhor esforço
    std::wstring args = L"--uninstall-run" + std::wstring(g_silent ? L" /S" : L"");
    ShellExecuteW(nullptr, L"open", copy.c_str(), args.c_str(), nullptr, SW_SHOWNORMAL);
    return 0;
}

int WINAPI wWinMain(HINSTANCE, HINSTANCE, LPWSTR cmd, int) {
    std::wstring args = cmd ? cmd : L"";
    g_silent = args.find(L"/S") != std::wstring::npos || args.find(L"/s") != std::wstring::npos;
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    int rc = 0;
    if (args.find(L"--uninstall-run") != std::wstring::npos) rc = uninstall_run(known(FOLDERID_LocalAppData) / APP_DIR);
    else if (args.find(L"--uninstall") != std::wstring::npos) rc = uninstall_start();
    else {
        fs::path root = known(FOLDERID_LocalAppData) / APP_DIR;
        std::error_code ec;
        fs::create_directories(root, ec);
        std::wstring error;
        if (!extract(root, native_arch(), error)) { message(error.c_str(), MB_ICONERROR); CoUninitialize(); return 2; }

        fs::path exe = root / (std::wstring(APP_EXE_NAME) + L".exe");
        fs::path self_copy = root / L"uninstall.exe";
        wchar_t me[MAX_PATH]{};
        GetModuleFileNameW(nullptr, me, MAX_PATH);
        CopyFileW(me, self_copy.c_str(), FALSE);

        fs::path programs = known(FOLDERID_Programs) / APP_DIR;
        fs::create_directories(programs, ec);
        make_shortcut(programs / lnk_name(), exe);
        make_shortcut(known(FOLDERID_Desktop) / lnk_name(), exe);

        HKEY k{};
        if (RegCreateKeyExW(HKEY_CURRENT_USER, uninstall_key().c_str(), 0, nullptr, 0, KEY_SET_VALUE, nullptr, &k, nullptr) == ERROR_SUCCESS) {
            auto set = [&](const wchar_t* n, const std::wstring& v) { RegSetValueExW(k, n, 0, REG_SZ, (const BYTE*)v.c_str(), (DWORD)((v.size() + 1) * sizeof(wchar_t))); };
            DWORD one = 1;
            set(L"DisplayName", APP_NAME);
            set(L"DisplayVersion", APP_VERSION);
            set(L"Publisher", L"Web2Exe");
            set(L"InstallLocation", root.wstring());
            set(L"DisplayIcon", exe.wstring());
            set(L"UninstallString", L"\"" + self_copy.wstring() + L"\" --uninstall");
            RegSetValueExW(k, L"NoModify", 0, REG_DWORD, (const BYTE*)&one, sizeof one);
            RegSetValueExW(k, L"NoRepair", 0, REG_DWORD, (const BYTE*)&one, sizeof one);
            RegCloseKey(k);
        }
        if (!g_silent && MessageBoxW(nullptr, L"Instalação concluída.\n\nDeseja abrir o aplicativo agora?", APP_NAME, MB_YESNO | MB_ICONINFORMATION) == IDYES)
            ShellExecuteW(nullptr, L"open", exe.c_str(), nullptr, root.c_str(), SW_SHOWNORMAL);
    }
    CoUninitialize();
    return rc;
}
