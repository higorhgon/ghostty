// PoC 3: WinUI 3's TabView in a plain Win32 HWND, *unpackaged*.
//
// Same goal as PoC 2 but on WinUI 3 instead of WinUI 2. The tradeoff:
//
//   WinUI 2 -> packaged-only. Its theme resources live behind
//              ms-appx://Microsoft.UI.Xaml.2.8/... which only resolves
//              with real package identity, so it needs MSIX. (PoC 2 got
//              all the way to that wall.)
//
//   WinUI 3 -> officially supports unpackaged apps. The Windows App SDK
//              bootstrapper wires up both activation *and* resource
//              resolution, so a plain .exe can use it.
//
// The lesson carried over from PoC 2 is the initialization ORDER inside
// the Application-derived class -- see the App ctor comment. That single
// ordering bug is what produced the RPC_E_WRONG_THREAD that killed the
// earlier C#/WinUI 3 attempt.

#include <windows.h>
#undef GetCurrentTime
#include <appmodel.h>
#include <MddBootstrap.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
// IXamlMetadataProvider::GetXamlType still takes the *Windows* TypeName
// even in WinUI 3.
#include <winrt/Windows.UI.Xaml.Interop.h>

#include <winrt/Microsoft.UI.h>
#include <winrt/Microsoft.UI.Interop.h>
#include <winrt/Microsoft.UI.Dispatching.h>
#include <winrt/Microsoft.UI.Xaml.h>
#include <winrt/Microsoft.UI.Xaml.Markup.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Controls.Primitives.h>
#include <winrt/Microsoft.UI.Xaml.Hosting.h>
#include <winrt/Microsoft.UI.Xaml.Media.h>
#include <winrt/Microsoft.UI.Xaml.XamlTypeInfo.h>
#include <winrt/Microsoft.UI.Windowing.h>
// SiteBridge().MoveAndResize() lives on Microsoft.UI.Content, which must
// be included for the definition (not just the forward declaration).
#include <winrt/Microsoft.UI.Content.h>
#include <winrt/Windows.Graphics.h>

#include <cstdio>
#include <cstdarg>

using namespace winrt;
namespace MUX = winrt::Microsoft::UI::Xaml;

namespace {

void Log(const char* fmt, ...) {
    char buf[2048];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    FILE* f = nullptr;
    fopen_s(&f, "poc3_log.txt", "a");
    if (f) { fprintf(f, "%s\n", buf); fclose(f); }
    OutputDebugStringA(buf);
    OutputDebugStringA("\n");
}

struct App : MUX::ApplicationT<App, MUX::Markup::IXamlMetadataProvider> {
    App() {
        // Order, as learned the hard way in PoC 2:
        //   1. base Application ctor runs implicitly (sets Current);
        //   2. boot XAML on this thread;
        //   3. only then touch Resources().
        // Doing (3) before (2) throws RPC_E_WRONG_THREAD.
        Log("App ctor: InitializeForCurrentThread");
        manager_ = MUX::Hosting::WindowsXamlManager::InitializeForCurrentThread();
        Log("App ctor: manager OK, merging XamlControlsResources");
        Resources().MergedDictionaries().Append(MUX::Controls::XamlControlsResources());
        Log("App ctor: resources merged OK");
    }

    MUX::Markup::IXamlType GetXamlType(Windows::UI::Xaml::Interop::TypeName const& type) {
        return provider_.GetXamlType(type);
    }
    MUX::Markup::IXamlType GetXamlType(hstring const& name) {
        return provider_.GetXamlType(name);
    }
    com_array<MUX::Markup::XmlnsDefinition> GetXmlnsDefinitions() {
        return provider_.GetXmlnsDefinitions();
    }

private:
    MUX::XamlTypeInfo::XamlControlsXamlMetaDataProvider provider_;
    MUX::Hosting::WindowsXamlManager manager_{nullptr};
};

HWND g_hwnd = nullptr;
MUX::Hosting::DesktopWindowXamlSource g_source{nullptr};

void LayoutIsland() {
    if (!g_source || !g_hwnd) return;
    RECT rc{};
    GetClientRect(g_hwnd, &rc);
    if (auto bridge = g_source.SiteBridge()) {
        bridge.MoveAndResize({0, 0, rc.right - rc.left, rc.bottom - rc.top});
    }
}

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    switch (msg) {
    case WM_SIZE:
        LayoutIsland();
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

} // namespace

int WINAPI wWinMain(HINSTANCE hinstance, HINSTANCE, PWSTR, int) {
    Log("=== poc3 start ===");

    // Bootstrap the Windows App Runtime. 0x00010008 == 1.8, matching the
    // NuGet packages the projection was generated from.
    PACKAGE_VERSION minVersion{};
    HRESULT hr = MddBootstrapInitialize2(
        0x00010008, L"", minVersion, MddBootstrapInitializeOptions_OnNoMatch_ShowUI);
    if (FAILED(hr)) {
        Log("FATAL: MddBootstrapInitialize2 failed 0x%08X", (unsigned)hr);
        return 1;
    }
    Log("bootstrap OK");

    init_apartment(apartment_type::single_threaded);

    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hinstance;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszClassName = L"Poc3Window";
    RegisterClassExW(&wc);

    g_hwnd = CreateWindowExW(
        0, L"Poc3Window", L"WinUI 3 TabView in a Win32 HWND (unpackaged)",
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 1000, 240,
        nullptr, nullptr, hinstance, nullptr);
    if (!g_hwnd) { Log("FATAL: CreateWindowExW failed"); return 2; }

    try {
        // WinUI 3 requires a DispatcherQueue on the thread before XAML.
        auto controller =
            Microsoft::UI::Dispatching::DispatcherQueueController::CreateOnCurrentThread();
        Log("DispatcherQueueController OK");

        auto app = winrt::make<App>();
        Log("App created");

        g_source = MUX::Hosting::DesktopWindowXamlSource();
        auto windowId = Microsoft::UI::GetWindowIdFromWindow(g_hwnd);
        g_source.Initialize(windowId);
        Log("island initialized");

        MUX::Controls::TabView tabView;
        tabView.TabWidthMode(MUX::Controls::TabViewWidthMode::Equal);

        auto addTab = [tabView](hstring const& title) {
            try {
                MUX::Controls::TabViewItem item;
                item.Header(winrt::box_value(title));
                item.Content(MUX::Controls::Grid());
                tabView.TabItems().Append(item);
                Log("  addTab(%ls) OK, count now=%u", title.c_str(),
                    tabView.TabItems().Size());
            } catch (hresult_error const& e) {
                Log("  addTab(%ls) FAILED 0x%08X: %ls", title.c_str(),
                    (unsigned)e.code(), e.message().c_str());
            }
        };
        addTab(L"C:\\WINDOWS\\system32\\cmd.exe");
        addTab(L"pwsh");
        addTab(L"ghostty");
        Log("final TabItems count=%u, SelectedIndex=%d",
            tabView.TabItems().Size(), tabView.SelectedIndex());

        tabView.AddTabButtonClick([addTab](auto&&, auto&&) { addTab(L"new tab"); });
        tabView.TabCloseRequested(
            [](MUX::Controls::TabView const& sender,
               MUX::Controls::TabViewTabCloseRequestedEventArgs const& args) {
                uint32_t index{};
                if (sender.TabItems().IndexOf(args.Tab(), index)) {
                    sender.TabItems().RemoveAt(index);
                }
            });

        // Host the TabView in a Grid with an explicit theme + background.
        // Without this the island inherits an ambiguous theme: the strip
        // paints on a white surface while unselected tabs pick up
        // dark-theme foreground brushes, rendering white-on-white (which
        // looks exactly like "only one tab exists").
        MUX::Controls::Grid root;
        root.RequestedTheme(MUX::ElementTheme::Dark);
        root.Background(MUX::Media::SolidColorBrush(
            winrt::Windows::UI::Color{255, 32, 32, 32}));
        root.Children().Append(tabView);

        g_source.Content(root);
        Log("TabView set; Style=%p", (void*)winrt::get_abi(tabView.Style()));

        // Report the realized size of every tab once layout has run, so a
        // zero-sized (rather than merely invisible) container is
        // distinguishable.
        tabView.Loaded([tabView](auto&&, auto&&) {
            Log("Loaded: TabView %fx%f, items=%u",
                tabView.ActualWidth(), tabView.ActualHeight(),
                tabView.TabItems().Size());
            for (uint32_t i = 0; i < tabView.TabItems().Size(); ++i) {
                if (auto item = tabView.TabItems().GetAt(i)
                                    .try_as<MUX::Controls::TabViewItem>()) {
                    Log("  tab[%u] %fx%f visible=%d", i,
                        item.ActualWidth(), item.ActualHeight(),
                        item.Visibility() == MUX::Visibility::Visible);
                }
            }
        });
    } catch (hresult_error const& e) {
        Log("FATAL hresult 0x%08X: %ls", (unsigned)e.code(), e.message().c_str());
        return 3;
    } catch (...) {
        Log("FATAL: unknown exception");
        return 4;
    }

    LayoutIsland();
    ShowWindow(g_hwnd, SW_SHOW);
    UpdateWindow(g_hwnd);
    Log("entering message loop");

    MSG msg{};
    while (GetMessageW(&msg, nullptr, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    Log("=== poc3 exit ===");
    MddBootstrapShutdown();
    return 0;
}
