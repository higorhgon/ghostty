// WinUI 2 TabView hosted in a XAML Island, behind the flat C ABI in
// ghostty_tabbar.h. See that header for the threading contract and the
// DLL-is-dumb / Zig-holds-policy split.

#include <windows.h>
#undef GetCurrentTime

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.UI.h>
#include <winrt/Windows.UI.Xaml.h>
#include <winrt/Windows.UI.Xaml.Markup.h>
#include <winrt/Windows.UI.Xaml.Interop.h>
#include <winrt/Windows.UI.Xaml.Hosting.h>
#include <winrt/Windows.UI.Xaml.Controls.h>
#include <winrt/Windows.UI.Xaml.Controls.Primitives.h>
#include <winrt/Windows.UI.Xaml.Media.h>

#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.XamlTypeInfo.h>

#include <windows.ui.xaml.hosting.desktopwindowxamlsource.h>

#include <unordered_map>
#include <vector>
#include <string>

#define GHOSTTY_TABBAR_EXPORTS
#include "ghostty_tabbar.h"

using namespace winrt;
namespace WUX = winrt::Windows::UI::Xaml;
namespace MUX = winrt::Microsoft::UI::Xaml;

namespace {

// Diagnostic log. Writes to %TEMP% because a packaged host cannot write
// to its own install directory.
void Log(const char* fmt, ...) {
    char buf[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);

    char dir[MAX_PATH];
    DWORD n = ::GetTempPathA(MAX_PATH, dir);
    char path[MAX_PATH];
    if (n == 0 || n > MAX_PATH) {
        strcpy_s(path, "ghostty_tabbar.log");
    } else {
        _snprintf_s(path, sizeof(path), _TRUNCATE, "%sghostty_tabbar.log", dir);
    }
    FILE* f = nullptr;
    if (fopen_s(&f, path, "a") == 0 && f) {
        fprintf(f, "%s\n", buf);
        fclose(f);
    }
    ::OutputDebugStringA(buf);
    ::OutputDebugStringA("\n");
}

// Height of the WinUI 2 tab strip at 96 DPI. WinUI doesn't expose this as
// a public metric, so it's mirrored from the TabView default style.
constexpr int32_t kTabStripHeight96 = 40;

// Application + metadata provider.
//
// The ordering inside the constructor is load-bearing and was the single
// hardest thing to get right here:
//
//   1. the base Application ctor runs implicitly, publishing this as
//      Application::Current;
//   2. WindowsXamlManager::InitializeForCurrentThread() boots XAML on
//      this thread;
//   3. only then may Resources() be touched.
//
// Doing (3) before (2) throws RPC_E_WRONG_THREAD. Separately, WinUI 2's
// XamlControlsResources is itself XAML markup, so parsing it needs type
// metadata -- hence IXamlMetadataProvider delegating to WinUI 2's own
// provider. Both halves are what the Community Toolkit's XamlApplication
// (Windows Terminal's base class) does.
struct XamlApp : WUX::ApplicationT<XamlApp, WUX::Markup::IXamlMetadataProvider> {
    XamlApp() {
        Log("XamlApp: base ctor done, initializing manager");
        manager_ = WUX::Hosting::WindowsXamlManager::InitializeForCurrentThread();
        Log("XamlApp: manager OK, constructing XamlControlsResources");
        auto res = MUX::Controls::XamlControlsResources();
        Log("XamlApp: XamlControlsResources OK, merging");
        Resources().MergedDictionaries().Append(res);
        Log("XamlApp: merged OK");
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

} // namespace

struct GhosttyTabBar {
    GhosttyTabBarCallbacks cb{};

    WUX::Application app{nullptr};
    WUX::Hosting::DesktopWindowXamlSource source{nullptr};
    com_ptr<IDesktopWindowXamlSourceNative2> native;
    HWND island_hwnd = nullptr;
    HWND parent_hwnd = nullptr;

    WUX::Controls::Grid root{nullptr};
    MUX::Controls::TabView tab_view{nullptr};
    MUX::Controls::DropDownButton chevron{nullptr};

    std::unordered_map<GhosttyTabId, MUX::Controls::TabViewItem> tabs;
    GhosttyTabId next_id = 1;

    // Guards against feedback loops: when Ghostty drives the selection we
    // must not report it back as if the user had clicked.
    bool suppress_selection = false;

    void Notify(GhosttyTabSelectedFn fn, GhosttyTabId id) {
        if (fn) fn(cb.ctx, id);
    }
};

namespace {

GhosttyTabId IdOf(MUX::Controls::TabViewItem const& item) {
    if (!item) return 0;
    if (auto tag = item.Tag()) {
        try {
            return winrt::unbox_value<uint64_t>(tag);
        } catch (...) {
        }
    }
    return 0;
}

// Profiles live outside the XAML tree: they can be registered before the
// UI exists, and the menu is built fresh each time it opens.
std::unordered_map<GhosttyTabBar*, std::vector<std::pair<GhosttyProfileId, std::wstring>>>
    g_profiles;

// The shell picker is a Win32 popup menu rather than a XAML MenuFlyout.
//
// XAML Island popups are clipped to the island's HWND, and this island is
// only as tall as the tab strip -- a MenuFlyout here opens but is entirely
// invisible. A Win32 menu is its own top-level window, so it escapes those
// bounds. The tabs themselves remain a real WinUI TabView; only this menu
// is native.
void ShowProfileMenu(GhosttyTabBar* bar) {
    auto const& profiles = g_profiles[bar];
    if (profiles.empty()) return;

    HMENU menu = ::CreatePopupMenu();
    if (!menu) return;

    // Menu command ids are 1-based indices into `profiles`; 0 means the
    // user dismissed the menu.
    for (size_t i = 0; i < profiles.size(); ++i) {
        ::AppendMenuW(menu, MF_STRING, static_cast<UINT_PTR>(i + 1),
                      profiles[i].second.c_str());
    }

    // Drop the menu directly under the chevron button.
    POINT pt{0, 0};
    if (bar->chevron && bar->island_hwnd) {
        try {
            auto transform = bar->chevron.TransformToVisual(nullptr);
            auto origin = transform.TransformPoint(
                winrt::Windows::Foundation::Point{0.0f,
                    static_cast<float>(bar->chevron.ActualHeight())});
            pt.x = static_cast<LONG>(origin.X);
            pt.y = static_cast<LONG>(origin.Y);
        } catch (...) {
        }
        ::ClientToScreen(bar->island_hwnd, &pt);
    } else {
        ::GetCursorPos(&pt);
    }

    // TPM_RETURNCMD makes this synchronous: it returns the chosen id
    // instead of posting WM_COMMAND, so no message routing is needed.
    const int chosen = ::TrackPopupMenu(
        menu, TPM_RETURNCMD | TPM_LEFTALIGN | TPM_TOPALIGN | TPM_RIGHTBUTTON,
        pt.x, pt.y, 0, bar->parent_hwnd, nullptr);
    ::DestroyMenu(menu);

    if (chosen > 0 && static_cast<size_t>(chosen) <= profiles.size()) {
        const auto profile = profiles[chosen - 1].first;
        if (bar->cb.on_new_tab) bar->cb.on_new_tab(bar->cb.ctx, profile);
    }
}

} // namespace

extern "C" {

GHOSTTY_TABBAR_API GhosttyTabBar* ghostty_tabbar_create(
    void* parent_hwnd, GhosttyTabBarCallbacks callbacks) {
    if (!parent_hwnd) return nullptr;

    // XAML requires an STA. Tolerate the thread already being in one.
    HRESULT hr = ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) return nullptr;

    auto* bar = new (std::nothrow) GhosttyTabBar();
    if (!bar) return nullptr;
    bar->cb = callbacks;
    bar->parent_hwnd = static_cast<HWND>(parent_hwnd);

    try {
        Log("create: begin, parent=%p", parent_hwnd);
        // Application::Current() is only safe to consult once XAML has
        // been booted at least once on this process; probe it defensively
        // so a first-run throw doesn't masquerade as a create failure.
        WUX::Application existing{nullptr};
        try {
            existing = WUX::Application::Current();
            Log("create: Application::Current()=%p", (void*)winrt::get_abi(existing));
        } catch (...) {
            Log("create: Application::Current() threw (expected on first run)");
        }
        if (!existing) {
            bar->app = winrt::make<XamlApp>();
            Log("create: XamlApp constructed");
        } else {
            bar->app = existing;
            Log("create: reusing existing Application");
        }

        bar->source = WUX::Hosting::DesktopWindowXamlSource();
        Log("create: DesktopWindowXamlSource OK");
        auto native = bar->source.as<IDesktopWindowXamlSourceNative>();
        check_hresult(native->AttachToWindow(bar->parent_hwnd));
        check_hresult(native->get_WindowHandle(&bar->island_hwnd));
        bar->native = bar->source.try_as<IDesktopWindowXamlSourceNative2>();

        MUX::Controls::TabView tv;
        tv.TabWidthMode(MUX::Controls::TabViewWidthMode::Equal);
        tv.IsAddTabButtonVisible(true);
        // Ghostty owns the terminal surface; the TabView draws headers
        // only, so every item's content stays empty.
        tv.CanDragTabs(false);
        tv.CanReorderTabs(true);
        bar->tab_view = tv;

        // "+" opens the default profile, matching Windows Terminal.
        tv.AddTabButtonClick([bar](auto&&, auto&&) {
            if (bar->cb.on_new_tab)
                bar->cb.on_new_tab(bar->cb.ctx, GHOSTTY_PROFILE_DEFAULT);
        });

        tv.TabCloseRequested(
            [bar](MUX::Controls::TabView const&,
                  MUX::Controls::TabViewTabCloseRequestedEventArgs const& args) {
                // Deliberately does not remove the tab: Ghostty decides.
                auto id = IdOf(args.Tab().try_as<MUX::Controls::TabViewItem>());
                if (id && bar->cb.on_close_requested)
                    bar->cb.on_close_requested(bar->cb.ctx, id);
            });

        tv.SelectionChanged([bar](auto&&, auto&&) {
            if (bar->suppress_selection) return;
            auto sel = bar->tab_view.SelectedItem()
                           .try_as<MUX::Controls::TabViewItem>();
            auto id = IdOf(sel);
            if (id && bar->cb.on_selected) bar->cb.on_selected(bar->cb.ctx, id);
        });

        // Chevron button next to "+" that drops down the shell list.
        // DropDownButton renders its own chevron glyph, so it deliberately
        // gets no Content: supplying a FontIcon here stacks a second glyph
        // beside the built-in one.
        MUX::Controls::DropDownButton chevron;
        chevron.Padding(WUX::ThicknessHelper::FromLengths(6, 4, 6, 4));
        // No XAML Flyout is attached (see ShowProfileMenu for why); the
        // button just raises Click and we open a Win32 menu ourselves.
        chevron.Click([bar](auto&&, auto&&) { ShowProfileMenu(bar); });
        bar->chevron = chevron;
        tv.TabStripFooter(chevron);

        WUX::Controls::Grid root;
        // An explicit theme + background is required: without it the strip
        // paints on an undefined surface and unselected tabs can render
        // white-on-white, which looks exactly like missing tabs.
        root.RequestedTheme(WUX::ElementTheme::Dark);
        root.Background(WUX::Media::SolidColorBrush(
            winrt::Windows::UI::Color{255, 32, 32, 32}));
        root.Children().Append(tv);
        bar->root = root;

        bar->source.Content(root);
        Log("create: content set OK");
    } catch (hresult_error const& e) {
        Log("create: FAILED hresult 0x%08X: %ls", (unsigned)e.code(),
            e.message().c_str());
        delete bar;
        return nullptr;
    } catch (std::exception const& e) {
        Log("create: FAILED std::exception: %s", e.what());
        delete bar;
        return nullptr;
    } catch (...) {
        Log("create: FAILED unknown exception");
        delete bar;
        return nullptr;
    }

    g_profiles[bar] = {};
    return bar;
}

GHOSTTY_TABBAR_API void ghostty_tabbar_destroy(GhosttyTabBar* bar) {
    if (!bar) return;
    g_profiles.erase(bar);
    try {
        if (bar->source) bar->source.Close();
    } catch (...) {
    }
    delete bar;
}

GHOSTTY_TABBAR_API int32_t ghostty_tabbar_height(GhosttyTabBar* bar) {
    UINT dpi = 96;
    if (bar && bar->parent_hwnd) {
        UINT d = ::GetDpiForWindow(bar->parent_hwnd);
        if (d) dpi = d;
    }
    return ::MulDiv(kTabStripHeight96, static_cast<int>(dpi), 96);
}

GHOSTTY_TABBAR_API void ghostty_tabbar_resize(
    GhosttyTabBar* bar, int32_t x, int32_t y, int32_t width, int32_t height) {
    if (!bar || !bar->island_hwnd) return;
    ::SetWindowPos(bar->island_hwnd, nullptr, x, y, width, height, SWP_SHOWWINDOW);
}

GHOSTTY_TABBAR_API int32_t ghostty_tabbar_pretranslate(
    GhosttyTabBar* bar, void* msg) {
    if (!bar || !bar->native || !msg) return 0;
    BOOL handled = FALSE;
    if (SUCCEEDED(bar->native->PreTranslateMessage(static_cast<MSG*>(msg), &handled)))
        return handled ? 1 : 0;
    return 0;
}

GHOSTTY_TABBAR_API GhosttyTabId ghostty_tabbar_add_tab(
    GhosttyTabBar* bar, const wchar_t* title) {
    if (!bar || !bar->tab_view) return 0;
    try {
        MUX::Controls::TabViewItem item;
        item.Header(winrt::box_value(hstring{title ? title : L""}));
        const GhosttyTabId id = bar->next_id++;
        item.Tag(winrt::box_value(static_cast<uint64_t>(id)));

        bar->suppress_selection = true;
        bar->tab_view.TabItems().Append(item);
        bar->suppress_selection = false;

        bar->tabs.emplace(id, item);
        return id;
    } catch (...) {
        bar->suppress_selection = false;
        return 0;
    }
}

GHOSTTY_TABBAR_API void ghostty_tabbar_remove_tab(
    GhosttyTabBar* bar, GhosttyTabId tab) {
    if (!bar || !bar->tab_view) return;
    auto it = bar->tabs.find(tab);
    if (it == bar->tabs.end()) return;
    try {
        uint32_t index = 0;
        if (bar->tab_view.TabItems().IndexOf(it->second, index)) {
            bar->suppress_selection = true;
            bar->tab_view.TabItems().RemoveAt(index);
            bar->suppress_selection = false;
        }
    } catch (...) {
        bar->suppress_selection = false;
    }
    bar->tabs.erase(it);
}

GHOSTTY_TABBAR_API void ghostty_tabbar_set_title(
    GhosttyTabBar* bar, GhosttyTabId tab, const wchar_t* title) {
    if (!bar) return;
    auto it = bar->tabs.find(tab);
    if (it == bar->tabs.end()) return;
    try {
        it->second.Header(winrt::box_value(hstring{title ? title : L""}));
    } catch (...) {
    }
}

GHOSTTY_TABBAR_API void ghostty_tabbar_set_selected(
    GhosttyTabBar* bar, GhosttyTabId tab) {
    if (!bar || !bar->tab_view) return;
    auto it = bar->tabs.find(tab);
    if (it == bar->tabs.end()) return;
    try {
        bar->suppress_selection = true;
        bar->tab_view.SelectedItem(it->second);
        bar->suppress_selection = false;
    } catch (...) {
        bar->suppress_selection = false;
    }
}

GHOSTTY_TABBAR_API void ghostty_tabbar_add_profile(
    GhosttyTabBar* bar, GhosttyProfileId profile, const wchar_t* name) {
    if (!bar) return;
    g_profiles[bar].emplace_back(profile, name ? name : L"");
}

GHOSTTY_TABBAR_API void ghostty_tabbar_clear_profiles(GhosttyTabBar* bar) {
    if (!bar) return;
    g_profiles[bar].clear();
}

GHOSTTY_TABBAR_API void ghostty_tabbar_set_theme(
    GhosttyTabBar* bar, uint8_t r, uint8_t g, uint8_t b, int32_t dark) {
    if (!bar || !bar->root) return;
    try {
        bar->root.RequestedTheme(dark ? WUX::ElementTheme::Dark
                                      : WUX::ElementTheme::Light);
        bar->root.Background(WUX::Media::SolidColorBrush(
            winrt::Windows::UI::Color{255, r, g, b}));
    } catch (...) {
    }
}

} // extern "C"

BOOL APIENTRY DllMain(HMODULE, DWORD, LPVOID) { return TRUE; }
