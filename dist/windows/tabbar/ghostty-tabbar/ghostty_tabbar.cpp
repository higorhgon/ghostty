// WinUI 2 TabView hosted in a XAML Island, behind the flat C ABI in
// ghostty_tabbar.h. See that header for the threading contract and the
// DLL-is-dumb / Zig-holds-policy split.

#include <windows.h>
#undef GetCurrentTime

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.UI.h>
// PointerPoint::Properties() is declared in Windows.UI.Input; without the
// definition the drag handler cannot read which button is down.
#include <winrt/Windows.UI.Input.h>
#include <winrt/Windows.UI.Xaml.h>
#include <winrt/Windows.UI.Xaml.Markup.h>
#include <winrt/Windows.UI.Xaml.Interop.h>
#include <winrt/Windows.UI.Xaml.Hosting.h>
#include <winrt/Windows.UI.Xaml.Controls.h>
#include <winrt/Windows.UI.Xaml.Controls.Primitives.h>
#include <winrt/Windows.UI.Xaml.Input.h>
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
    // Maximize/restore share one button; its glyph is swapped to match the
    // window state.
    WUX::Controls::FontIcon max_glyph{nullptr};

    /// Brushes owned by the merged theme dictionary. Re-theming mutates
    /// their Color in place rather than replacing them: WinUI resolves
    /// these once when the TabViewItem template is applied, so swapping
    /// the brush object afterwards would have no effect, while changing
    /// the colour of the brush already in use propagates immediately.
    WUX::Media::SolidColorBrush b_selected{nullptr};
    WUX::Media::SolidColorBrush b_unselected{nullptr};
    WUX::Media::SolidColorBrush b_hover{nullptr};
    /// Every theme slot's copy, so recolouring reaches whichever one the
    /// resource lookup actually resolves against.
    std::vector<WUX::Media::SolidColorBrush> extra_brushes;
    std::vector<WUX::Media::SolidColorBrush> extra_unselected;
    std::vector<WUX::Media::SolidColorBrush> extra_hover;

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

/// Installs the named tab brushes and keeps handles so they can be
/// recoloured in place.
///
/// STATUS: the brushes are created and recoloured correctly, but WinUI
/// 2.8's stock TabViewItem does not read them -- its background is a
/// translucent white overlay baked into the default ControlTemplate.
/// Overriding the documented keys was measured having no effect through
/// four different scopes: the TabView's ResourceDictionary, the
/// Application's, each item's own, and these merged ThemeDictionaries
/// (both the "Default" and "Dark" slots). Rendered values stayed at
/// 46,48,53 unselected and 103,105,108 selected in every case.
///
/// They are kept because the fix is a ControlTemplate override for
/// TabViewItem, and that template will bind to exactly these brushes.
/// Until then the tabs use WinUI's default colours.
bool InstallThemeOverrides(GhosttyTabBar* bar) {
    // Placeholder colours; set_theme recolours these brushes in place.
    static constexpr wchar_t kXaml[] =
        LR"(<ResourceDictionary
              xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
              xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
              <ResourceDictionary.ThemeDictionaries>
                <!-- "Default" is the dark slot by convention, but an
                     element with an explicit RequestedTheme may look up
                     "Dark" by name, so both are provided. -->
                <ResourceDictionary x:Key="Default">
                  <SolidColorBrush x:Key="GhosttyTabSelected" Color="#FF202020"/>
                  <SolidColorBrush x:Key="GhosttyTabUnselected" Color="#FF141414"/>
                  <SolidColorBrush x:Key="GhosttyTabHover" Color="#FF2D2D2D"/>
                  <StaticResource x:Key="TabViewItemHeaderBackgroundSelected" ResourceKey="GhosttyTabSelected"/>
                  <StaticResource x:Key="TabViewItemHeaderBackgroundSelectedPointerOver" ResourceKey="GhosttyTabSelected"/>
                  <StaticResource x:Key="TabViewItemHeaderBackgroundSelectedPressed" ResourceKey="GhosttyTabSelected"/>
                  <StaticResource x:Key="TabViewItemHeaderBackground" ResourceKey="GhosttyTabUnselected"/>
                  <StaticResource x:Key="TabViewItemHeaderBackgroundPointerOver" ResourceKey="GhosttyTabHover"/>
                  <StaticResource x:Key="TabViewItemHeaderBackgroundPressed" ResourceKey="GhosttyTabHover"/>
                </ResourceDictionary>
                <ResourceDictionary x:Key="Dark">
                  <SolidColorBrush x:Key="GhosttyTabSelectedDark" Color="#FF202020"/>
                  <SolidColorBrush x:Key="GhosttyTabUnselectedDark" Color="#FF141414"/>
                  <SolidColorBrush x:Key="GhosttyTabHoverDark" Color="#FF2D2D2D"/>
                  <StaticResource x:Key="TabViewItemHeaderBackgroundSelected" ResourceKey="GhosttyTabSelectedDark"/>
                  <StaticResource x:Key="TabViewItemHeaderBackgroundSelectedPointerOver" ResourceKey="GhosttyTabSelectedDark"/>
                  <StaticResource x:Key="TabViewItemHeaderBackgroundSelectedPressed" ResourceKey="GhosttyTabSelectedDark"/>
                  <StaticResource x:Key="TabViewItemHeaderBackground" ResourceKey="GhosttyTabUnselectedDark"/>
                  <StaticResource x:Key="TabViewItemHeaderBackgroundPointerOver" ResourceKey="GhosttyTabHoverDark"/>
                  <StaticResource x:Key="TabViewItemHeaderBackgroundPressed" ResourceKey="GhosttyTabHoverDark"/>
                </ResourceDictionary>
              </ResourceDictionary.ThemeDictionaries>
            </ResourceDictionary>)";

    auto app = WUX::Application::Current();
    if (!app) return false;

    auto obj = WUX::Markup::XamlReader::Load(kXaml);
    auto dict = obj.try_as<WUX::ResourceDictionary>();
    if (!dict) {
        Log("theme: XamlReader did not yield a ResourceDictionary");
        return false;
    }
    app.Resources().MergedDictionaries().Append(dict);

    // Reach through the theme dictionary to keep the brush instances.
    // Collect the brushes from every theme slot so recolouring hits
    // whichever one the lookup actually settles on.
    auto themes = dict.ThemeDictionaries();
    for (auto const& slot : {L"Default", L"Dark"}) {
        auto sub = themes.TryLookup(winrt::box_value(slot))
                       .try_as<WUX::ResourceDictionary>();
        if (!sub) continue;
        const bool dark_slot = (std::wstring_view{slot} == L"Dark");
        auto grab = [&](wchar_t const* base) {
            std::wstring key{base};
            if (dark_slot) key += L"Dark";
            return sub.TryLookup(winrt::box_value(key))
                .try_as<WUX::Media::SolidColorBrush>();
        };
        if (auto b = grab(L"GhosttyTabSelected")) bar->extra_brushes.push_back(b);
        if (auto b = grab(L"GhosttyTabUnselected")) bar->extra_unselected.push_back(b);
        if (auto b = grab(L"GhosttyTabHover")) bar->extra_hover.push_back(b);
    }
    if (!bar->extra_brushes.empty()) bar->b_selected = bar->extra_brushes.front();
    if (!bar->extra_unselected.empty()) bar->b_unselected = bar->extra_unselected.front();
    if (!bar->extra_hover.empty()) bar->b_hover = bar->extra_hover.front();

    Log("theme: overrides installed (selected=%d unselected=%d hover=%d)",
        bar->b_selected ? 1 : 0, bar->b_unselected ? 1 : 0, bar->b_hover ? 1 : 0);
    return bar->b_selected != nullptr;
}

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

// Caption button metrics, matching the system title bar at 96 DPI.
constexpr double kCaptionButtonWidth = 46.0;

// Segoe Fluent Icons / Segoe MDL2 Assets codepoints for the caption
// glyphs. Written as escapes rather than literal characters so the source
// file stays pure ASCII -- a literal glyph here is easy to mangle in
// transit and renders as tofu.
constexpr wchar_t kGlyphMinimize[] = L"";
constexpr wchar_t kGlyphMaximize[] = L"";
constexpr wchar_t kGlyphRestore[]  = L"";
constexpr wchar_t kGlyphClose[]    = L"";

// Builds one caption button. `danger` gives the close button the standard
// red hover treatment.
WUX::Controls::Button MakeCaptionButton(
    GhosttyTabBar* bar, wchar_t const* glyph, GhosttyCaptionButton which,
    bool danger, WUX::Controls::FontIcon* out_icon) {
    WUX::Controls::FontIcon icon;
    icon.Glyph(glyph);
    icon.FontFamily(WUX::Media::FontFamily(L"Segoe Fluent Icons, Segoe MDL2 Assets"));
    icon.FontSize(10);
    if (out_icon) *out_icon = icon;

    WUX::Controls::Button btn;
    btn.Content(icon);
    btn.Width(kCaptionButtonWidth);
    btn.VerticalAlignment(WUX::VerticalAlignment::Stretch);
    btn.Padding(WUX::ThicknessHelper::FromUniformLength(0));
    btn.BorderThickness(WUX::ThicknessHelper::FromUniformLength(0));
    btn.CornerRadius(WUX::CornerRadiusHelper::FromUniformRadius(0));
    btn.Background(WUX::Media::SolidColorBrush(
        winrt::Windows::UI::Color{0, 0, 0, 0}));

    if (danger) {
        // WinUI has no "close button" style, so the red hover is applied
        // by overriding the button's own hover brushes.
        auto red = WUX::Media::SolidColorBrush(
            winrt::Windows::UI::Color{255, 196, 43, 28});
        btn.Resources().Insert(winrt::box_value(L"ButtonBackgroundPointerOver"), red);
        auto pressed = WUX::Media::SolidColorBrush(
            winrt::Windows::UI::Color{255, 165, 36, 24});
        btn.Resources().Insert(winrt::box_value(L"ButtonBackgroundPressed"), pressed);
        auto white = WUX::Media::SolidColorBrush(
            winrt::Windows::UI::Color{255, 255, 255, 255});
        btn.Resources().Insert(winrt::box_value(L"ButtonForegroundPointerOver"), white);
        btn.Resources().Insert(winrt::box_value(L"ButtonForegroundPressed"), white);
    }

    btn.Click([bar, which](auto&&, auto&&) {
        if (bar->cb.on_caption_button) bar->cb.on_caption_button(bar->cb.ctx, which);
    });
    return btn;
}

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

        // Must precede the TabView: the overrides are only picked up when
        // an item's template is applied, which is too late once tabs exist.
        InstallThemeOverrides(bar);

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
        chevron.Padding(WUX::ThicknessHelper::FromLengths(10, 0, 10, 0));
        chevron.VerticalAlignment(WUX::VerticalAlignment::Stretch);
        // Flat, like the "+" beside it -- the default button chrome draws
        // a filled box that reads as out of place in a title bar.
        chevron.Background(WUX::Media::SolidColorBrush(
            winrt::Windows::UI::Color{0, 0, 0, 0}));
        chevron.BorderThickness(WUX::ThicknessHelper::FromUniformLength(0));
        // No XAML Flyout is attached (see ShowProfileMenu for why); the
        // button just raises Click and we open a Win32 menu ourselves.
        chevron.Click([bar](auto&&, auto&&) { ShowProfileMenu(bar); });
        bar->chevron = chevron;

        // Windows Terminal separates "+" from the profile chevron with a
        // hairline rule; without it the two read as one wide button.
        WUX::Controls::Border separator;
        separator.Width(1);
        separator.Margin(WUX::ThicknessHelper::FromLengths(2, 10, 2, 10));
        separator.Background(WUX::Media::SolidColorBrush(
            winrt::Windows::UI::Color{60, 255, 255, 255}));

        WUX::Controls::StackPanel footer;
        footer.Orientation(WUX::Controls::Orientation::Horizontal);
        footer.VerticalAlignment(WUX::VerticalAlignment::Stretch);
        footer.Children().Append(separator);
        footer.Children().Append(chevron);
        tv.TabStripFooter(footer);

        // The strip doubles as the window's title bar, so it is laid out
        // in three columns, matching Windows Terminal:
        //
        //   [ tabs + "+" + chevron ][ drag area ][ - o x ]
        //         Auto                  *          Auto
        //
        // The middle column is elastic and does nothing but absorb space
        // and start window drags.
        WUX::Controls::Grid root;
        // An explicit theme + background is required: without it the strip
        // paints on an undefined surface and unselected tabs can render
        // white-on-white, which looks exactly like missing tabs.
        root.RequestedTheme(WUX::ElementTheme::Dark);
        root.Background(WUX::Media::SolidColorBrush(
            winrt::Windows::UI::Color{255, 32, 32, 32}));

        {
            WUX::Controls::ColumnDefinition c0, c1, c2;
            c0.Width(WUX::GridLengthHelper::Auto());
            c1.Width(WUX::GridLengthHelper::FromValueAndType(1, WUX::GridUnitType::Star));
            c2.Width(WUX::GridLengthHelper::Auto());
            root.ColumnDefinitions().Append(c0);
            root.ColumnDefinitions().Append(c1);
            root.ColumnDefinitions().Append(c2);
        }

        WUX::Controls::Grid::SetColumn(tv, 0);
        root.Children().Append(tv);

        // Transparent drag surface. A Border with a fully transparent
        // brush still receives pointer input, whereas a null Background
        // would let events fall through.
        WUX::Controls::Border drag;
        drag.Background(WUX::Media::SolidColorBrush(
            winrt::Windows::UI::Color{0, 0, 0, 0}));
        drag.PointerPressed([bar](auto&&, WUX::Input::PointerRoutedEventArgs const& e) {
            auto props = e.GetCurrentPoint(nullptr).Properties();
            if (!props.IsLeftButtonPressed()) return;
            if (bar->cb.on_drag_start) bar->cb.on_drag_start(bar->cb.ctx);
        });
        drag.DoubleTapped([bar](auto&&, auto&&) {
            if (bar->cb.on_drag_double_click) bar->cb.on_drag_double_click(bar->cb.ctx);
        });
        WUX::Controls::Grid::SetColumn(drag, 1);
        root.Children().Append(drag);

        WUX::Controls::StackPanel caption;
        caption.Orientation(WUX::Controls::Orientation::Horizontal);
        caption.VerticalAlignment(WUX::VerticalAlignment::Stretch);
        caption.Children().Append(MakeCaptionButton(
            bar, kGlyphMinimize, GHOSTTY_CAPTION_MINIMIZE, false, nullptr));
        caption.Children().Append(MakeCaptionButton(
            bar, kGlyphMaximize, GHOSTTY_CAPTION_MAXIMIZE_RESTORE, false,
            &bar->max_glyph));
        caption.Children().Append(MakeCaptionButton(
            bar, kGlyphClose, GHOSTTY_CAPTION_CLOSE, true, nullptr));
        WUX::Controls::Grid::SetColumn(caption, 2);
        root.Children().Append(caption);

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

    // The TabView sits in an Auto-width column, so left alone it demands
    // its full natural width and squeezes the drag area and caption
    // buttons off the end of the strip. Cap it explicitly at whatever is
    // left after the caption buttons, in DIPs.
    if (!bar->tab_view) return;
    UINT dpi = 96;
    if (bar->parent_hwnd) {
        UINT d = ::GetDpiForWindow(bar->parent_hwnd);
        if (d) dpi = d;
    }
    const double dips = static_cast<double>(width) * 96.0 / static_cast<double>(dpi);
    const double reserved = kCaptionButtonWidth * 3.0;
    // Always leave a slice of drag area, otherwise a full-width tab strip
    // would make the window impossible to move by its title bar.
    constexpr double kMinDragArea = 32.0;
    const double avail = dips - reserved - kMinDragArea;
    try {
        bar->tab_view.MaxWidth(avail > 0.0 ? avail : 0.0);
    } catch (...) {
    }
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

GHOSTTY_TABBAR_API void ghostty_tabbar_set_maximized(
    GhosttyTabBar* bar, int32_t maximized) {
    if (!bar || !bar->max_glyph) return;
    try {
        bar->max_glyph.Glyph(maximized ? kGlyphRestore : kGlyphMaximize);
    } catch (...) {
    }
}

namespace {

uint8_t Scale(uint8_t c, double factor) {
    const double v = static_cast<double>(c) * factor;
    return static_cast<uint8_t>(v < 0.0 ? 0.0 : (v > 255.0 ? 255.0 : v));
}

winrt::Windows::UI::Color Rgb(uint8_t r, uint8_t g, uint8_t b) {
    return winrt::Windows::UI::Color{255, r, g, b};
}

void PutBrush(WUX::ResourceDictionary const& res, wchar_t const* key,
              winrt::Windows::UI::Color color) {
    res.Insert(winrt::box_value(key), WUX::Media::SolidColorBrush(color));
}

} // namespace

GHOSTTY_TABBAR_API void ghostty_tabbar_set_theme(
    GhosttyTabBar* bar, uint8_t r, uint8_t g, uint8_t b, int32_t dark) {
    if (!bar || !bar->root || !bar->tab_view) return;
    try {
        bar->root.RequestedTheme(dark ? WUX::ElementTheme::Dark
                                      : WUX::ElementTheme::Light);

        // Windows Terminal's colour model, which is the opposite of the
        // obvious one: the *selected* tab takes the terminal's exact
        // background so it reads as continuous with the content below it,
        // and the strip around it is darker (lighter, on a light theme).
        //
        // Painting the strip with the terminal colour instead leaves WinUI
        // to derive the selected tab from it, and its default overlay
        // darkens -- which inverts the whole thing and is what this used
        // to look like.
        const double strip_factor = dark ? 0.62 : 1.12;
        const double hover_factor = dark ? 0.80 : 1.06;
        const auto content = Rgb(r, g, b);
        const auto strip = Rgb(Scale(r, strip_factor), Scale(g, strip_factor),
                               Scale(b, strip_factor));
        const auto hover = Rgb(Scale(r, hover_factor), Scale(g, hover_factor),
                               Scale(b, hover_factor));

        bar->root.Background(WUX::Media::SolidColorBrush(strip));

        // Recolour in place: the brushes are already bound into applied
        // templates, so replacing the objects would change nothing.
        for (auto& b : bar->extra_brushes) b.Color(content);
        for (auto& b : bar->extra_unselected) b.Color(strip);
        for (auto& b : bar->extra_hover) b.Color(hover);

        Log("set_theme: content=%02X%02X%02X strip=%02X%02X%02X",
            content.R, content.G, content.B, strip.R, strip.G, strip.B);
    } catch (hresult_error const& e) {
        Log("set_theme: FAILED 0x%08X: %ls", (unsigned)e.code(), e.message().c_str());
    } catch (...) {
        Log("set_theme: FAILED (unknown)");
    }
}

} // extern "C"

BOOL APIENTRY DllMain(HMODULE, DWORD, LPVOID) { return TRUE; }
