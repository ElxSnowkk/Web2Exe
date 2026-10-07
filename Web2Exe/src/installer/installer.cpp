// Instalador universal (PE x86, ligado à msvcrt para rodar também em Wine antigo).
// O payload W2EA (x86/x64/arm64 e, opcionalmente, "wine") está embutido como recurso RCDATA "W2E_PAYLOAD".
// Instala por usuário em %LOCALAPPDATA%\<INSTALL_DIR>: não exige administrador.
//   (sem argumentos)   assistente gráfico: boas-vindas -> progresso -> conclusão
//   /S                 instalação silenciosa
//   --wine             força a variante Wine (por padrão ela é escolhida sozinha ao detectar Wine)
//   --uninstall        desinstala (usado pelo registro do Windows)
#include <windows.h>
#include <commctrl.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <functional>
#include <string>
#include <vector>

namespace fs = std::filesystem;
static const wchar_t* APP_NAME = L"__WEB2EXE_NAME__";
static const wchar_t* APP_ID = L"__WEB2EXE_ID__";
static const wchar_t* APP_EXE_NAME = L"__WEB2EXE_EXE_NAME__";
static const wchar_t* APP_VERSION = L"__WEB2EXE_VERSION__";
static const wchar_t* APP_DIR = L"__WEB2EXE_INSTALL_DIR__";

static bool g_silent = false;
static bool g_force_wine = false;
static void message(const wchar_t* text, UINT icon) { if (!g_silent) MessageBoxW(nullptr, text, APP_NAME, MB_OK | icon); }

// ---------------------------------------------------------------- sistema ----
static bool is_wine() {
    HMODULE nt = GetModuleHandleW(L"ntdll.dll");
    return nt && GetProcAddress(nt, "wine_get_version") != nullptr;
}

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

// ---------------------------------------------------------------- payload ----
struct Entry { std::string name; size_t off; uint64_t len; };

static bool payload(const unsigned char*& data, size_t& size) {
    HRSRC r = FindResourceW(nullptr, L"W2E_PAYLOAD", RT_RCDATA);
    if (!r) return false;
    HGLOBAL g = LoadResource(nullptr, r);
    if (!g) return false;
    data = (const unsigned char*)LockResource(g);
    size = SizeofResource(nullptr, r);
    return data && size;
}

static bool parse_payload(const unsigned char* d, size_t sz, std::vector<Entry>& out, std::wstring& error) {
    if (sz < 9 || std::memcmp(d, "W2EA\0", 5) != 0) { error = L"Payload inválido ou corrompido."; return false; }
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
        out.push_back({name, off, dl});
        off += (size_t)dl;
    }
    return true;
}

static bool has_variant(const std::vector<Entry>& v, const std::string& variant) {
    for (auto& e : v) if (e.name.compare(0, variant.size() + 1, variant + "/") == 0) return true;
    return false;
}

// Escolhe a variante a instalar: "wine" sob Wine (se o instalador a contiver); senão a arquitetura nativa.
static std::string pick_variant(const std::vector<Entry>& v) {
    if ((g_force_wine || is_wine()) && has_variant(v, "wine")) return "wine";
    std::string a = native_arch();
    if (!has_variant(v, a) && has_variant(v, "x86")) return "x86";
    return a;
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

using Progress = std::function<void(int pct, const std::wstring& status)>;

static std::wstring widen(const std::string& s) {
    int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
    std::wstring w((size_t)(n > 0 ? n : 0), L'\0');
    if (n > 0) MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), &w[0], n);
    return w;
}

// Extrai a variante escolhida; o progresso vai de 0 a 80.
static bool extract(const fs::path& root, const std::string& want, std::wstring& error, const Progress& prog) {
    const unsigned char* d = nullptr;
    size_t sz = 0;
    std::vector<Entry> entries;
    if (!payload(d, sz) || !parse_payload(d, sz, entries, error)) { if (error.empty()) error = L"Payload inválido ou corrompido."; return false; }
    uint64_t total = 0, done = 0;
    for (auto& e : entries) if (e.name.compare(0, want.size() + 1, want + "/") == 0) total += e.len;
    if (!total && !has_variant(entries, want)) { error = L"Este instalador não contém arquivos para a sua plataforma."; return false; }
    for (auto& e : entries) {
        if (e.name.compare(0, want.size() + 1, want + "/") != 0) continue;
        std::string rel = e.name.substr(want.size() + 1);
        if (!safe_relative(rel)) { error = L"Payload contém caminho inseguro."; return false; }
        fs::path out = root / fs::u8path(rel);
        std::error_code ec;
        fs::create_directories(out.parent_path(), ec);
        if (prog) prog(total ? (int)(done * 80 / total) : 0, L"Copiando " + widen(rel));
        std::ofstream f(out, std::ios::binary | std::ios::trunc);
        if (!f) { error = L"Não foi possível gravar:\n" + out.wstring() + L"\n\nFeche o aplicativo se ele estiver aberto e tente novamente."; return false; }
        f.write((const char*)d + e.off, (std::streamsize)e.len);
        f.close();
        if (!f) { error = L"Erro de escrita (disco cheio?)."; return false; }
        done += e.len;
    }
    if (prog) prog(80, L"Arquivos copiados");
    return true;
}

static std::wstring uninstall_key() { return std::wstring(L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\") + APP_ID; }

// Instalação completa (arquivos, desinstalador, atalhos, registro). Usada pelo modo silencioso e pelo assistente.
static bool do_install(const fs::path& root, std::wstring& error, const Progress& prog) {
    std::error_code ec;
    fs::create_directories(root, ec);
    const unsigned char* d = nullptr;
    size_t sz = 0;
    std::vector<Entry> entries;
    if (!payload(d, sz) || !parse_payload(d, sz, entries, error)) { if (error.empty()) error = L"Payload inválido ou corrompido."; return false; }
    if (!extract(root, pick_variant(entries), error, prog)) return false;

    fs::path exe = root / (std::wstring(APP_EXE_NAME) + L".exe");
    fs::path self_copy = root / L"uninstall.exe";
    wchar_t me[MAX_PATH]{};
    GetModuleFileNameW(nullptr, me, MAX_PATH);
    if (prog) prog(85, L"Criando o desinstalador");
    CopyFileW(me, self_copy.c_str(), FALSE);

    if (prog) prog(90, L"Criando atalhos");
    fs::path programs = known(FOLDERID_Programs) / APP_DIR;
    fs::create_directories(programs, ec);
    make_shortcut(programs / lnk_name(), exe);
    make_shortcut(known(FOLDERID_Desktop) / lnk_name(), exe);

    if (prog) prog(96, L"Registrando o aplicativo");
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
    if (prog) prog(100, L"Concluído");
    return true;
}

// ------------------------------------------------------------ desinstalar ----
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

// -------------------------------------------------------------- assistente ----
enum class Page { Welcome, Installing, Done };
static constexpr int IDC_NEXT = 101, IDC_CANCEL = 102, IDC_OPEN = 103, IDC_BODY = 104, IDC_BAR = 105, IDC_STATUS = 106;

struct Ui {
    HWND wnd{}, body{}, bar{}, status{}, next{}, cancel{}, open{};
    HFONT font{}, title{}, sub{};
    Page page = Page::Welcome;
    bool installing = false, ok = false, wine = false;
    std::wstring error;
    fs::path root;
} U;

static int g_dpi = 96;
static int sc(int v) { return MulDiv(v, g_dpi, 96); }
static HFONT make_font(int pt, int weight) {
    return CreateFontW(-MulDiv(pt, g_dpi, 72), 0, 0, 0, weight, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                       CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
}
static void pump() {
    MSG m;
    while (PeekMessageW(&m, nullptr, 0, 0, PM_REMOVE)) {
        if (m.message == WM_QUIT) { PostQuitMessage((int)m.wParam); return; }
        TranslateMessage(&m);
        DispatchMessageW(&m);
    }
}
static HWND child(const wchar_t* cls, const wchar_t* text, DWORD style, int x, int y, int w, int h, int id) {
    HWND c = CreateWindowExW(0, cls, text, WS_CHILD | WS_VISIBLE | style, sc(x), sc(y), sc(w), sc(h), U.wnd, (HMENU)(INT_PTR)id, GetModuleHandleW(nullptr), nullptr);
    SendMessageW(c, WM_SETFONT, (WPARAM)U.font, TRUE);
    return c;
}

static void set_page(Page p) {
    U.page = p;
    std::wstring text;
    int showBar = SW_HIDE, showOpen = SW_HIDE;
    switch (p) {
    case Page::Welcome:
        text = std::wstring(L"Bem-vindo ao instalador de ") + APP_NAME + L".\r\n\r\nO aplicativo será instalado em:\r\n" + U.root.wstring() +
               L"\r\n\r\nNão é necessário ser administrador.";
        if (U.wine) text += L"\r\n\r\nWine detectado: será instalada a versão compatível com Wine.";
        SetWindowTextW(U.next, L"Instalar");
        SetWindowTextW(U.cancel, L"Cancelar");
        EnableWindow(U.next, TRUE); EnableWindow(U.cancel, TRUE);
        break;
    case Page::Installing:
        text = std::wstring(L"Instalando ") + APP_NAME + L"...\r\n\r\nAguarde enquanto os arquivos são copiados.";
        showBar = SW_SHOW;
        EnableWindow(U.next, FALSE); EnableWindow(U.cancel, FALSE);
        break;
    case Page::Done:
        if (U.ok) {
            text = std::wstring(L"Instalação concluída com sucesso!\r\n\r\n") + APP_NAME + L" foi instalado e os atalhos foram criados no Menu Iniciar e na Área de Trabalho.";
            showOpen = SW_SHOW;
            SendMessageW(U.open, BM_SETCHECK, BST_CHECKED, 0);
            SetWindowTextW(U.next, L"Concluir");
        } else {
            text = U.error.empty() ? L"A instalação não foi concluída." : U.error;
            SetWindowTextW(U.next, L"Fechar");
        }
        EnableWindow(U.next, TRUE);
        ShowWindow(U.cancel, SW_HIDE);
        break;
    }
    SetWindowTextW(U.body, text.c_str());
    ShowWindow(U.bar, showBar);
    ShowWindow(U.status, showBar);
    ShowWindow(U.open, showOpen);
    InvalidateRect(U.wnd, nullptr, TRUE);
}

static void on_next() {
    if (U.page == Page::Welcome) {
        set_page(Page::Installing);
        U.installing = true;
        SendMessageW(U.bar, PBM_SETRANGE32, 0, 100);
        SendMessageW(U.bar, PBM_SETPOS, 0, 0);
        std::wstring err;
        U.ok = do_install(U.root, err, [](int pct, const std::wstring& st) {
            SendMessageW(U.bar, PBM_SETPOS, (WPARAM)pct, 0);
            SetWindowTextW(U.status, st.c_str());
            pump();
        });
        U.error = err;
        if (U.ok) Sleep(400);
        U.installing = false;
        set_page(Page::Done);
        return;
    }
    if (U.page == Page::Done && U.ok && SendMessageW(U.open, BM_GETCHECK, 0, 0) == BST_CHECKED)
        ShellExecuteW(nullptr, L"open", (U.root / (std::wstring(APP_EXE_NAME) + L".exe")).c_str(), nullptr, U.root.c_str(), SW_SHOWNORMAL);
    DestroyWindow(U.wnd);
}

static LRESULT CALLBACK SetupProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    switch (m) {
    case WM_CREATE:
        U.wnd = h;
        U.body = child(L"STATIC", L"", SS_LEFT, 28, 92, 484, 150, IDC_BODY);
        U.bar = child(PROGRESS_CLASSW, L"", 0, 28, 160, 484, 20, IDC_BAR);
        U.status = child(L"STATIC", L"", SS_LEFT | SS_ENDELLIPSIS, 28, 188, 484, 20, IDC_STATUS);
        U.open = child(L"BUTTON", L"Abrir o aplicativo agora", BS_AUTOCHECKBOX | WS_TABSTOP, 28, 252, 484, 22, IDC_OPEN);
        U.next = child(L"BUTTON", L"Instalar", BS_DEFPUSHBUTTON | WS_TABSTOP, 322, 296, 96, 30, IDC_NEXT);
        U.cancel = child(L"BUTTON", L"Cancelar", BS_PUSHBUTTON | WS_TABSTOP, 426, 296, 96, 30, IDC_CANCEL);
        set_page(Page::Welcome);
        return 0;
    case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(h, &ps);
        RECT rc{};
        GetClientRect(h, &rc);
        RECT band{0, 0, rc.right, sc(72)};
        HBRUSH br = CreateSolidBrush(RGB(24, 38, 66));
        FillRect(dc, &band, br);
        DeleteObject(br);
        if (HICON ic = (HICON)LoadImageW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(1), IMAGE_ICON, sc(40), sc(40), LR_DEFAULTCOLOR)) {
            DrawIconEx(dc, sc(24), sc(16), ic, sc(40), sc(40), 0, nullptr, DI_NORMAL);
            DestroyIcon(ic);
        }
        SetBkMode(dc, TRANSPARENT);
        SetTextColor(dc, RGB(255, 255, 255));
        HGDIOBJ old = SelectObject(dc, U.title);
        RECT t{sc(76), sc(10), rc.right - sc(16), sc(42)};
        DrawTextW(dc, APP_NAME, -1, &t, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS | DT_VCENTER);
        SelectObject(dc, U.sub);
        SetTextColor(dc, RGB(190, 200, 220));
        RECT s{sc(76), sc(42), rc.right - sc(16), sc(64)};
        std::wstring sub = std::wstring(L"Assistente de instalação  •  versão ") + APP_VERSION;
        DrawTextW(dc, sub.c_str(), -1, &s, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
        SelectObject(dc, old);
        RECT line{0, sc(284), rc.right, sc(286)};
        DrawEdge(dc, &line, EDGE_ETCHED, BF_TOP);
        EndPaint(h, &ps);
        return 0;
    }
    case WM_COMMAND:
        if (LOWORD(w) == IDC_NEXT) { on_next(); return 0; }
        if (LOWORD(w) == IDC_CANCEL && !U.installing) { DestroyWindow(h); return 0; }
        break;
    case WM_CLOSE:
        if (U.installing) return 0;
        DestroyWindow(h);
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(h, m, w, l);
}

static int run_wizard(HINSTANCE hi) {
    HDC dc = GetDC(nullptr);
    g_dpi = GetDeviceCaps(dc, LOGPIXELSX);
    ReleaseDC(nullptr, dc);
    if (g_dpi < 96) g_dpi = 96;
    U.font = make_font(9, FW_NORMAL);
    U.title = make_font(15, FW_SEMIBOLD);
    U.sub = make_font(9, FW_NORMAL);
    U.root = known(FOLDERID_LocalAppData) / APP_DIR;
    U.wine = g_force_wine || is_wine();

    WNDCLASSEXW wc{};
    wc.cbSize = sizeof wc;
    wc.hInstance = hi;
    wc.lpfnWndProc = SetupProc;
    wc.lpszClassName = L"Web2ExeSetup";
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
    wc.hIcon = (HICON)LoadImageW(hi, MAKEINTRESOURCEW(1), IMAGE_ICON, GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON), LR_DEFAULTCOLOR);
    wc.hIconSm = (HICON)LoadImageW(hi, MAKEINTRESOURCEW(1), IMAGE_ICON, GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), LR_DEFAULTCOLOR);
    if (!RegisterClassExW(&wc)) return 3;

    DWORD style = WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
    RECT r{0, 0, sc(540), sc(344)};
    AdjustWindowRectEx(&r, style, FALSE, 0);
    int w = r.right - r.left, h = r.bottom - r.top;
    RECT wa{0, 0, 800, 600};
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &wa, 0);
    int x = wa.left + ((wa.right - wa.left) - w) / 2, y = wa.top + ((wa.bottom - wa.top) - h) / 2;
    HWND win = CreateWindowExW(0, L"Web2ExeSetup", (std::wstring(APP_NAME) + L" - Instalação").c_str(), style, x, y, w, h, nullptr, nullptr, hi, nullptr);
    if (!win) return 4;
    ShowWindow(win, SW_SHOWNORMAL);
    UpdateWindow(win);
    MSG msg{};
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        if (!IsDialogMessageW(win, &msg)) { TranslateMessage(&msg); DispatchMessageW(&msg); }
    }
    return U.page == Page::Done && !U.ok ? 2 : 0;
}

int WINAPI wWinMain(HINSTANCE hi, HINSTANCE, LPWSTR cmd, int) {
    std::wstring args = cmd ? cmd : L"";
    g_silent = args.find(L"/S") != std::wstring::npos || args.find(L"/s") != std::wstring::npos;
    g_force_wine = args.find(L"--wine") != std::wstring::npos;
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    INITCOMMONCONTROLSEX icc{sizeof icc, ICC_PROGRESS_CLASS};
    InitCommonControlsEx(&icc);
    int rc = 0;
    if (args.find(L"--uninstall-run") != std::wstring::npos) rc = uninstall_run(known(FOLDERID_LocalAppData) / APP_DIR);
    else if (args.find(L"--uninstall") != std::wstring::npos) rc = uninstall_start();
    else if (g_silent) {
        std::wstring error;
        if (!do_install(known(FOLDERID_LocalAppData) / APP_DIR, error, nullptr)) rc = 2;
    } else rc = run_wizard(hi);
    CoUninitialize();
    return rc;
}
