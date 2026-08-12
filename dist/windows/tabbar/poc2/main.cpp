// PoC 2: host WinUI 2's real TabView -- the same control Windows Terminal,
// Notepad and Explorer use -- inside a plain Win32 HWND via XAML Islands.
//
// Two pieces make this work where the earlier WinUI 3 attempt failed:
//
//  1. A custom Application that also implements IXamlMetadataProvider.
//     XamlControlsResources is itself XAML markup referencing WinUI 2
//     types, so XAML needs type metadata to parse it. WinUI 2 ships that
//     provider as XamlControlsXamlMetaDataProvider; we delegate to it.
//     (This is exactly what the Community Toolkit's XamlApplication does,
//     and what Windows Terminal derives its App from.)
//
//  2. The Application instance must exist *before*
//     WindowsXamlManager::InitializeForCurrentThread(), because that call
//     creates a default Application if none exists -- and a default one
//     has no WinUI 2 resources, which is what leaves TabView unstyled
//     with a null Style and a 0x0 size.

#include <windows.h>
#undef GetCurrentTime
#include <appmodel.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.UI.h>
#include <winrt/Windows.UI.Xaml.h>
#include <winrt/Windows.UI.Xaml.Markup.h>
#include <winrt/Windows.UI.Xaml.Interop.h>
#include <winrt/Windows.UI.Xaml.Hosting.h>
#include <winrt/Windows.UI.Xaml.Controls.h>
#include <winrt/Windows.UI.Xaml.Media.h>

#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.XamlTypeInfo.h>

#include <windows.ui.xaml.hosting.desktopwindowxamlsource.h>

#include <cstdio>
#include <cstdarg>

using namespace winrt;

namespace WUX = winrt::Windows::UI::Xaml;
namespace MUX = winrt::Microsoft::UI::Xaml;

namespace {

void Log(const char* fmt, ...) {
    char buf[2048];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);

    FILE* f = nullptr;
    fopen_s(&f, "poc2_log.txt", "a");
    if (f) { fprintf(f, "%s\n", buf); fclose(f); }
    OutputDebugStringA(buf);
    OutputDebugStringA("\n");
}

// --- Dynamic package dependencies -------------------------------------
//
// WinUI 2 ships as an MSIX *framework package*, so its WinRT classes are
// normally only activatable from a packaged app -- an unpackaged process
// just gets REGDB_E_CLASSNOTREG. The OS exposes Dynamic Dependency APIs
// (Windows 11+) that let an unpackaged process pull a framework package
// into its activation context at runtime, which is what lets us stay a
// plain .exe instead of shipping Ghostty as an MSIX.
//
// Resolved via GetProcAddress rather than an import lib so that older
// Windows just fails this step gracefully instead of failing to load the
// process at all.

using PFN_TryCreatePackageDependency = HRESULT(WINAPI*)(
    PSID, PCWSTR, PACKAGE_VERSION, PackageDependencyProcessorArchitectures,
    PackageDependencyLifetimeKind, PCWSTR, CreatePackageDependencyOptions, PWSTR*);
using PFN_AddPackageDependency = HRESULT(WINAPI*)(
    PCWSTR, INT32, AddPackageDependencyOptions, PACKAGEDEPENDENCY_CONTEXT*, PWSTR*);

bool AddFrameworkDependency(PCWSTR family) {
    static auto kernelbase = LoadLibraryW(L"kernelbase.dll");
    if (!kernelbase) { Log("dep: kernelbase.dll not loadable"); return false; }

    static auto pTryCreate = reinterpret_cast<PFN_TryCreatePackageDependency>(
        GetProcAddress(kernelbase, "TryCreatePackageDependency"));
    static auto pAdd = reinterpret_cast<PFN_AddPackageDependency>(
        GetProcAddress(kernelbase, "AddPackageDependency"));
    if (!pTryCreate || !pAdd) {
        Log("dep: Dynamic Dependency APIs unavailable (needs Windows 11+)");
        return false;
    }

    PACKAGE_VERSION minVersion{};  // 0 => accept any installed version
    PWSTR depId = nullptr;
    HRESULT hr = pTryCreate(
        nullptr, family, minVersion,
        PackageDependencyProcessorArchitectures_None,
        PackageDependencyLifetimeKind_Process,
        nullptr, CreatePackageDependencyOptions_None, &depId);
    if (FAILED(hr)) {
        Log("dep: TryCreatePackageDependency(%ls) failed 0x%08X", family, (unsigned)hr);
        return false;
    }

    PACKAGEDEPENDENCY_CONTEXT ctx{};
    PWSTR fullName = nullptr;
    hr = pAdd(depId, 0, AddPackageDependencyOptions_None, &ctx, &fullName);
    if (FAILED(hr)) {
        Log("dep: AddPackageDependency(%ls) failed 0x%08X", family, (unsigned)hr);
        HeapFree(GetProcessHeap(), 0, depId);
        return false;
    }

    Log("dep: resolved %ls -> %ls", family, fullName ? fullName : L"(null)");
    // Intentionally leaked: the dependency must outlive this call for the
    // rest of the process's lifetime.
    return true;
}

// Application + metadata provider. See the header comment for why both
// halves are required.
struct App : WUX::ApplicationT<App, WUX::Markup::IXamlMetadataProvider> {
    App() {
        // Order is critical, and is what the Community Toolkit's
        // XamlApplication (the base Windows Terminal uses) does:
        //
        //   1. the base Application ctor runs implicitly, publishing this
        //      instance as Application::Current;
        //   2. WindowsXamlManager::InitializeForCurrentThread() boots XAML
        //      on this thread;
        //   3. only *then* is Resources() safe to touch.
        //
        // Touching Resources() before step 2 throws RPC_E_WRONG_THREAD,
        // because the Application's resource dictionary lives on a XAML
        // thread that doesn't exist yet.
        Log("App ctor: initializing WindowsXamlManager");
        manager_ = WUX::Hosting::WindowsXamlManager::InitializeForCurrentThread();
        Log("App ctor: WindowsXamlManager OK, merging XamlControlsResources");
        Resources().MergedDictionaries().Append(MUX::Controls::XamlControlsResources());
        Log("App ctor: XamlControlsResources merged OK");
    }

    WUX::Markup::IXamlType GetXamlType(WUX::Interop::TypeName const& type) {
        return provider_.GetXamlType(type);
    }
    WUX::Markup::IXamlType GetXamlType(hstring const& name) {
        return provider_.GetXamlType(name);
    }
    com_array<WUX::Markup::XmlnsDefinition> GetXmlnsDefinitions() {
        return provider_.GetXmlnsDefinitions();
    }

private:
    MUX::XamlTypeInfo::XamlControlsXamlMetaDataProvider provider_;
    WUX::Hosting::WindowsXamlManager manager_{nullptr};
};

HWND g_island_hwnd = nullptr;
WUX::Hosting::DesktopWindowXamlSource g_source{nullptr};

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    switch (msg) {
    case WM_SIZE:
        if (g_island_hwnd) {
            SetWindowPos(g_island_hwnd, nullptr, 0, 0,
                         LOWORD(lparam), HIWORD(lparam), SWP_SHOWWINDOW);
        }
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

} // namespace

int WINAPI wWinMain(HINSTANCE hinstance, HINSTANCE, PWSTR, int) {
    Log("=== poc2 start ===");

    // Must happen before any WinUI 2 type is activated.
    AddFrameworkDependency(L"Microsoft.VCLibs.140.00.UWPDesktop_8wekyb3d8bbwe");
    AddFrameworkDependency(L"Microsoft.UI.Xaml.2.8_8wekyb3d8bbwe");

    init_apartment(apartment_type::single_threaded);

    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hinstance;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszClassName = L"Poc2Window";
    RegisterClassExW(&wc);

    HWND hwnd = CreateWindowExW(
        0, L"Poc2Window", L"WinUI 2 TabView in a Win32 HWND",
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 1000, 240,
        nullptr, nullptr, hinstance, nullptr);
    if (!hwnd) { Log("FATAL: CreateWindowExW failed"); return 1; }

    try {
        // Order matters: our App must exist before the XAML manager, or a
        // resource-less default Application gets created instead.
        // App's constructor also boots the XAML manager for this thread.
        auto app = winrt::make<App>();
        Log("App created; Application::Current=%p",
            (void*)winrt::get_abi(WUX::Application::Current()));

        g_source = WUX::Hosting::DesktopWindowXamlSource();
        auto native = g_source.as<IDesktopWindowXamlSourceNative>();
        check_hresult(native->AttachToWindow(hwnd));
        check_hresult(native->get_WindowHandle(&g_island_hwnd));
        Log("island attached, hwnd=%p", (void*)g_island_hwnd);

        MUX::Controls::TabView tabView;
        tabView.TabWidthMode(MUX::Controls::TabViewWidthMode::Equal);

        auto addTab = [&tabView](hstring const& title) {
            MUX::Controls::TabViewItem item;
            item.Header(winrt::box_value(title));
            item.Content(WUX::Controls::Grid());
            tabView.TabItems().Append(item);
        };
        addTab(L"C:\\WINDOWS\\system32\\cmd.exe");
        addTab(L"pwsh");
        addTab(L"ghostty");

        tabView.AddTabButtonClick([addTab](auto&&, auto&&) {
            addTab(L"new tab");
        });
        tabView.TabCloseRequested(
            [](MUX::Controls::TabView const& sender,
               MUX::Controls::TabViewTabCloseRequestedEventArgs const& args) {
                uint32_t index{};
                if (sender.TabItems().IndexOf(args.Tab(), index)) {
                    sender.TabItems().RemoveAt(index);
                }
            });

        g_source.Content(tabView);
        Log("TabView set as island content; Style=%p",
            (void*)winrt::get_abi(tabView.Style()));
    } catch (hresult_error const& e) {
        Log("FATAL hresult 0x%08X: %ls", (unsigned)e.code(), e.message().c_str());
        return 2;
    } catch (...) {
        Log("FATAL: unknown exception");
        return 3;
    }

    RECT rc{};
    GetClientRect(hwnd, &rc);
    if (g_island_hwnd) {
        SetWindowPos(g_island_hwnd, nullptr, 0, 0,
                     rc.right - rc.left, rc.bottom - rc.top, SWP_SHOWWINDOW);
    }

    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);
    Log("entering message loop");

    MSG msg{};
    while (GetMessageW(&msg, nullptr, 0, 0)) {
        BOOL handled = FALSE;
        if (g_source) {
            if (auto n2 = g_source.try_as<IDesktopWindowXamlSourceNative2>()) {
                n2->PreTranslateMessage(&msg, &handled);
            }
        }
        if (!handled) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
    Log("=== poc2 exit ===");
    return 0;
}
