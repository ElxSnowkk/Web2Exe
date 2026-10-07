// Aplicativo Win32 + WebView2 gerado pelo Web2Exe.
// WebView2Loader.dll é carregada dinamicamente (sem import lib MSVC).
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <atomic>
#include <string>
#include "WebView2.h"

using CreateEnvFn = HRESULT(STDAPICALLTYPE*)(ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler*);
using CreateEnvOptFn = HRESULT(STDAPICALLTYPE*)(PCWSTR, PCWSTR, ICoreWebView2EnvironmentOptions*,
                                                ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler*);
using GetVersionFn = HRESULT(STDAPICALLTYPE*)(PCWSTR, LPWSTR*);

static HWND g_hwnd = nullptr;
static ICoreWebView2Controller* g_controller = nullptr;
static ICoreWebView2* g_webview = nullptr;
static HMODULE g_loader = nullptr;
static const wchar_t* kUrl = L"__WEB2EXE_URL__";
static const wchar_t* kName = L"__WEB2EXE_NAME__";
static const wchar_t* kAppId = L"__WEB2EXE_ID__";
static constexpr int kIconId = 1;
static constexpr wchar_t kRuntimeUrl[] = L"https://go.microsoft.com/fwlink/p/?LinkId=2124703";

namespace mswebview2 {
static constexpr IID IID_ControllerCompleted{0x6C4819F3, 0xC9B7, 0x4260, {0x81, 0x27, 0xC9, 0xF5, 0xBD, 0xE7, 0xF6, 0x8C}};
static constexpr IID IID_EnvironmentCompleted{0x4E8A3389, 0xC9D8, 0x4BD2, {0xB6, 0xB5, 0x12, 0x4F, 0xEE, 0x6C, 0xC1, 0x4D}};
}  // namespace mswebview2

#ifdef WEB2EXE_WINE
// Modo Wine: o WebView2 Runtime não existe no Wine. Se estivermos sob Wine (ou com --wine),
// abrimos a URL no navegador do sistema hospedeiro (winebrowser/xdg-open) e encerramos.
static bool running_under_wine() {
    HMODULE nt = GetModuleHandleW(L"ntdll.dll");
    return nt && GetProcAddress(nt, "wine_get_version") != nullptr;
}
static int wine_fallback() {
    HINSTANCE r = ShellExecuteW(nullptr, L"open", kUrl, nullptr, nullptr, SW_SHOWNORMAL);
    if ((INT_PTR)r > 32) return 0;
    std::wstring m = std::wstring(L"Este ambiente (Wine) não tem o Microsoft WebView2 Runtime nem navegador configurado.\n\nAbra o endereço manualmente:\n") + kUrl;
    MessageBoxW(nullptr, m.c_str(), kName, MB_ICONINFORMATION | MB_OK);
    return 0;
}
#endif

static void safe_release(IUnknown* p) { if (p) p->Release(); }
static void resize() {
    if (g_controller && g_hwnd) { RECT r{}; GetClientRect(g_hwnd, &r); g_controller->put_Bounds(r); }
}
static void show_error(const wchar_t* msg) { MessageBoxW(g_hwnd, msg, kName, MB_ICONERROR | MB_OK); }

// Pasta de dados do WebView2: %LOCALAPPDATA%\<AppId>\WebView2 (sempre gravável, mesmo se o .exe estiver em Program Files).
static std::wstring user_data_folder() {
    PWSTR base = nullptr;
    std::wstring path;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE, nullptr, &base)) && base) {
        path = std::wstring(base) + L"\\" + kAppId + L"\\WebView2";
        CoTaskMemFree(base);
        SHCreateDirectoryExW(nullptr, path.c_str(), nullptr);
    }
    return path;
}

class ControllerHandler final : public ICoreWebView2CreateCoreWebView2ControllerCompletedHandler {
    std::atomic<ULONG> refs{1};
public:
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override {
        if (!ppv) return E_POINTER;
        *ppv = nullptr;
        if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, mswebview2::IID_ControllerCompleted)) {
            *ppv = static_cast<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler*>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs; }
    ULONG STDMETHODCALLTYPE Release() override { ULONG r = --refs; if (!r) delete this; return r; }
    HRESULT STDMETHODCALLTYPE Invoke(HRESULT result, ICoreWebView2Controller* c) override {
        if (FAILED(result) || !c) { show_error(L"Não foi possível criar a janela do WebView2."); PostMessageW(g_hwnd, WM_CLOSE, 0, 0); return result; }
        g_controller = c;
        g_controller->AddRef();
        if (FAILED(g_controller->get_CoreWebView2(&g_webview))) return E_FAIL;
        resize();
        g_controller->put_IsVisible(TRUE);
        g_controller->MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
        return g_webview->Navigate(kUrl);
    }
};

class EnvironmentHandler final : public ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler {
    std::atomic<ULONG> refs{1};
public:
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override {
        if (!ppv) return E_POINTER;
        *ppv = nullptr;
        if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, mswebview2::IID_EnvironmentCompleted)) {
            *ppv = static_cast<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler*>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs; }
    ULONG STDMETHODCALLTYPE Release() override { ULONG r = --refs; if (!r) delete this; return r; }
    HRESULT STDMETHODCALLTYPE Invoke(HRESULT result, ICoreWebView2Environment* env) override {
        if (FAILED(result) || !env) { show_error(L"Falha ao inicializar o ambiente do WebView2."); PostMessageW(g_hwnd, WM_CLOSE, 0, 0); return result; }
        auto* h = new ControllerHandler();
        HRESULT hr = env->CreateCoreWebView2Controller(g_hwnd, h);
        h->Release();
        return hr;
    }
};

static LRESULT CALLBACK WndProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    switch (m) {
    case WM_SIZE: resize(); return 0;
    case WM_SETFOCUS:
        if (g_controller) g_controller->MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
        return 0;
    case WM_DESTROY:
        safe_release(g_webview); g_webview = nullptr;
        if (g_controller) { g_controller->Close(); safe_release(g_controller); g_controller = nullptr; }
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(h, m, w, l);
}

static int fail_exit(const wchar_t* msg, int code) {
    show_error(msg);
    if (g_hwnd) DestroyWindow(g_hwnd);
    if (g_loader) { FreeLibrary(g_loader); g_loader = nullptr; }
    CoUninitialize();
    return code;
}

int WINAPI wWinMain(HINSTANCE hi, HINSTANCE, LPWSTR cmdline, int show) {
#ifdef WEB2EXE_WINE
    if (running_under_wine() || (cmdline && wcsstr(cmdline, L"--wine"))) return wine_fallback();
#else
    (void)cmdline;
#endif
    // Instância única: se já estiver aberto, apenas traz a janela existente para frente.
    std::wstring cls = std::wstring(L"Web2Exe_") + kAppId;
    HANDLE mutex = CreateMutexW(nullptr, TRUE, (std::wstring(L"Local\\") + cls).c_str());
    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        if (HWND other = FindWindowW(cls.c_str(), nullptr)) {
            if (IsIconic(other)) ShowWindow(other, SW_RESTORE);
            SetForegroundWindow(other);
        }
        if (mutex) CloseHandle(mutex);
        return 0;
    }
    if (FAILED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED))) return 10;
    SetCurrentProcessExplicitAppUserModelID(kAppId);

    WNDCLASSEXW wc{};
    wc.cbSize = sizeof wc;
    wc.hInstance = hi;
    wc.lpfnWndProc = WndProc;
    wc.lpszClassName = cls.c_str();
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.hIcon = (HICON)LoadImageW(hi, MAKEINTRESOURCEW(kIconId), IMAGE_ICON, GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON), LR_DEFAULTCOLOR);
    wc.hIconSm = (HICON)LoadImageW(hi, MAKEINTRESOURCEW(kIconId), IMAGE_ICON, GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), LR_DEFAULTCOLOR);
    RegisterClassExW(&wc);
    g_hwnd = CreateWindowExW(0, cls.c_str(), kName, WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 1280, 800, nullptr, nullptr, hi, nullptr);
    if (!g_hwnd) { CoUninitialize(); return 11; }
    ShowWindow(g_hwnd, show);
    UpdateWindow(g_hwnd);

    g_loader = LoadLibraryW(L"WebView2Loader.dll");
    if (!g_loader) return fail_exit(L"WebView2Loader.dll não foi encontrada ao lado do aplicativo. Reinstale o programa.", 12);

    // Runtime Evergreen instalado?
    if (auto versionFn = reinterpret_cast<GetVersionFn>(GetProcAddress(g_loader, "GetAvailableCoreWebView2BrowserVersionString"))) {
        LPWSTR v = nullptr;
        if (FAILED(versionFn(nullptr, &v)) || !v) {
            if (MessageBoxW(g_hwnd, L"O Microsoft WebView2 Runtime não está instalado neste Windows.\n\nDeseja abrir a página de download?", kName, MB_ICONQUESTION | MB_YESNO) == IDYES)
                ShellExecuteW(nullptr, L"open", kRuntimeUrl, nullptr, nullptr, SW_SHOWNORMAL);
            DestroyWindow(g_hwnd);
            FreeLibrary(g_loader);
            CoUninitialize();
            return 14;
        }
        CoTaskMemFree(v);
    }

    std::wstring data = user_data_folder();
    HRESULT hr = E_FAIL;
    auto* handler = new EnvironmentHandler();
    if (auto fnOpt = reinterpret_cast<CreateEnvOptFn>(GetProcAddress(g_loader, "CreateCoreWebView2EnvironmentWithOptions")); fnOpt && !data.empty()) {
        hr = fnOpt(nullptr, data.c_str(), nullptr, handler);
    } else if (auto fn = reinterpret_cast<CreateEnvFn>(GetProcAddress(g_loader, "CreateCoreWebView2Environment"))) {
        hr = fn(handler);
    }
    handler->Release();
    if (FAILED(hr)) return fail_exit(L"Não foi possível inicializar o WebView2. Instale ou atualize o Microsoft Edge WebView2 Runtime.", 13);

    MSG msg{};
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) { TranslateMessage(&msg); DispatchMessageW(&msg); }
    if (g_loader) FreeLibrary(g_loader);
    CoUninitialize();
    if (mutex) CloseHandle(mutex);
    return 0;
}
