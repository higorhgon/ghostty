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
#include <winrt/Windows.UI.Xaml.Media.Imaging.h>
#include <winrt/Windows.System.h>
#include <shellapi.h>
#include <appmodel.h>
// FSCTL_GET_REPARSE_POINT; WIN32_LEAN_AND_MEAN leaves it out of windows.h.
#include <winioctl.h>
#include <dwmapi.h>
#include <robuffer.h>
// ITaskbarList3, for progress on the taskbar button.
#include <shobjidl.h>
// SetWindowTheme, for a dark scrollbar in the input popup's list.
#include <uxtheme.h>
#include <winrt/Windows.Data.Xml.Dom.h>
#include <winrt/Windows.UI.Notifications.h>

#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.XamlTypeInfo.h>

#include <windows.ui.xaml.hosting.desktopwindowxamlsource.h>

#include <chrono>
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

// Geometry of the "+" / chevron split button trailing the tabs.
//
// The height and width come from Windows Terminal's strip at 100%
// scaling. The bottom gap does not: it is set so the glyphs land on the
// same baseline as a tab's close button, which sits with its glyph
// centred at y=23 in a 39px strip. A 24px button 5px off the bottom puts
// its centre at 23 too.
constexpr double kFooterButtonHeight = 24;
constexpr double kFooterButtonWidth = 32;
constexpr double kFooterButtonBottomGap = 5;
constexpr double kFooterCornerRadius = 4;

// How long after the profile menu closes a click on the chevron is
// ignored. Long enough to swallow the press that did the closing, short
// enough that a deliberate second click still opens the menu.
constexpr LONG kMenuReopenGuardMs = 250;

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

        // A XAML exception raised during layout (applying a template, say)
        // reaches the dispatcher, not whatever C++ call kicked it off, and
        // terminates the process with nothing written down. This is the
        // only place it can be seen.
        UnhandledException([](auto&&, WUX::UnhandledExceptionEventArgs const& e) {
            Log("XAML UNHANDLED 0x%08X: %ls", (unsigned)e.Exception(),
                e.Message().c_str());
        });
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

// Defined further down, alongside the menu itself. Declared here so the
// bar can hold a pointer to the open one.
struct ProfileMenu;
struct InputPopup;

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
    // The two halves of the new-tab split button, plus the rule between
    // them. Held so the pair can be lit while the profile menu is open.
    WUX::Controls::Button plus{nullptr};
    WUX::Controls::Button chevron{nullptr};
    WUX::Controls::Border footer_divider{nullptr};
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
    WUX::Media::SolidColorBrush b_pressed{nullptr};

    /// The tab and button templates and the brushes above, parsed for
    /// this bar alone and merged into its own root rather than into the
    /// Application.
    ///
    /// The Application is shared by every window in the process, and its
    /// dictionary used to be where these went. A second window then merged
    /// a second copy on top, and the objects its templates are built from
    /// ended up belonging to two XAML trees at once -- which XAML answers
    /// by killing the process ("Failed to assign to property
    /// Path.Data"). So every new window, the quick terminal and a tab
    /// moved to a window of its own all took Ghostty down. One dictionary
    /// per bar keeps each tree's objects its own.
    WUX::ResourceDictionary theme_dict{nullptr};

    std::unordered_map<GhosttyTabId, MUX::Controls::TabViewItem> tabs;
    GhosttyTabId next_id = 1;

    // Guards against feedback loops: when Ghostty drives the selection we
    // must not report it back as if the user had clicked.
    bool suppress_selection = false;
    // The same for the order: set while Ghostty adds, removes or moves a
    // tab, so that only a drag by the user is reported as a move.
    bool suppress_items = false;

    /// Set on the strip's first composed frame. Until then the island
    /// paints white, so the host keeps the window off-screen.
    int frames = 0;
    bool rendered = false;
    winrt::event_token rendering_token{};

    /// GetMessageTime of the moment the profile menu last closed, so a
    /// click on the chevron that closed it cannot immediately reopen it.
    LONG menu_closed_at = 0;
    /// The profile menu, or null until it is first built. It outlives
    /// being closed: see ProfileMenu for why it is parked, not destroyed.
    ProfileMenu* menu = nullptr;
    /// Set when the profiles or the theme changed since the menu was last
    /// built, so its content has to be laid out again.
    bool menu_dirty = true;
    /// Builds the menu shortly after startup, so the first click on the
    /// chevron does not pay for a XAML island.
    WUX::DispatcherTimer menu_prewarm{nullptr};
    /// The search box / command palette / rename prompt, built on first
    /// use and then kept.
    InputPopup* input = nullptr;

    /// Menu chrome. Kept as plain colours, not brushes: the menu lives in
    /// a second XAML island with its own XamlRoot, and a Brush belongs to
    /// the tree it was first used in. Handing the strip's brushes to the
    /// menu left its background unpainted -- the window came up showing
    /// the terminal straight through it. Fresh brushes are built per menu.
    winrt::Windows::UI::Color menu_bg{255, 32, 32, 32};
    winrt::Windows::UI::Color menu_border{255, 48, 48, 48};
    winrt::Windows::UI::Color menu_hover{255, 45, 45, 45};
    winrt::Windows::UI::Color menu_text{255, 255, 255, 255};

    void Notify(GhosttyTabSelectedFn fn, GhosttyTabId id) {
        if (fn) fn(cb.ctx, id);
    }
};

namespace {

/// Installs an implicit TabViewItem Style whose ControlTemplate paints the
/// tabs from three brushes we own, and keeps handles so `set_theme` can
/// recolour them in place.
///
/// A full template override rather than the documented resource keys,
/// because overriding those keys does nothing. Setting
/// TabViewItemHeaderBackground* was measured as having no effect through
/// four scopes: the TabView's dictionary, the Application's, each item's
/// own, and merged ThemeDictionaries. Rendered values stayed at 46,48,53
/// unselected and 103,105,108 selected in every case.
///
/// WinUI 2.8's Generic.xaml shows the shape of the problem. The stock
/// template gives the *selected* tab's background to a separate shape,
/// `SelectedBackgroundPath`, then paints `TabContainer` over it with
/// `TabViewItemHeaderBackground`. That the overlay is translucent is
/// inference rather than something read -- the keys are not defined in
/// Generic.xaml at all, only referenced, so their values live in the
/// compiled theme resources -- but it is the only thing that explains a
/// selected tab rendering lighter than both the strip and the content.
///
/// Inside a template we own the lookup is no longer in question:
/// `{StaticResource}` resolves against the dictionary the Style lives in,
/// so it can only find our brushes.
///
/// Verified by sampling: unselected 26,29,34 against a 24,27,32 strip,
/// selected 40,44,52 exactly matching the terminal background, hover
/// 32,35,41. Note that hover cannot be provoked with SetCursorPos --
/// XAML pointer state only follows synthesized relative mouse input.
///
/// Kept deliberately close to the stock template. Three deviations, each
/// forced:
///   - `x:Load` is dropped: XamlReader::Load does not support it. The
///     deferred elements are declared Visibility="Collapsed" instead,
///     which is the state the template starts them in anyway.
///   - TabContainer's CornerRadius is a literal instead of a binding
///     through `{StaticResource TopCornerRadiusFilterConverter}`: a
///     StaticResource that is not in the parsed markup fails at Load
///     time, and that converter lives in WinUI's compiled resources.
///   - The reorder/drag Storyboard states are omitted. VisualStateManager
///     ignores a state it cannot find, so this costs the drag animations
///     and nothing else.
bool InstallThemeOverrides(GhosttyTabBar* bar) {
    // Split into chunks and joined at runtime only because MSVC caps a
    // single string literal at 16380 bytes and this template is larger.
    // The split points are arbitrary; keep them on element boundaries so
    // the pieces stay readable.
    //
    // Placeholder colours; set_theme recolours these brushes in place.
    static constexpr wchar_t kXaml1[] =
        LR"XAML(<ResourceDictionary
              xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
              xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
              xmlns:muxc="using:Microsoft.UI.Xaml.Controls">
              <SolidColorBrush x:Key="GhosttyTabSelected" Color="#FF202020"/>
              <SolidColorBrush x:Key="GhosttyTabUnselected" Color="#FF141414"/>
              <SolidColorBrush x:Key="GhosttyTabHover" Color="#FF2D2D2D"/>
              <SolidColorBrush x:Key="GhosttyTabPressed" Color="#FF3A3A3A"/>
              <SolidColorBrush x:Key="GhosttyMenuBackground" Color="#FF202020"/>
              <SolidColorBrush x:Key="GhosttyMenuBorder" Color="#FF303030"/>

              <!-- One row of the shell picker. Left-aligned content and a
                   themed hover fill, which the stock Button style gives
                   neither of. -->
              <Style x:Key="GhosttyMenuItemStyle" TargetType="Button">
                <Setter Property="Background" Value="Transparent"/>
                <Setter Property="Foreground" Value="{ThemeResource TabViewItemHeaderForeground}"/>
                <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
                <Setter Property="Template">
                  <Setter.Value>
                    <ControlTemplate TargetType="Button">
                      <Border x:Name="Root" Background="{TemplateBinding Background}" CornerRadius="{TemplateBinding CornerRadius}" Padding="{TemplateBinding Padding}">
                        <VisualStateManager.VisualStateGroups>
                          <VisualStateGroup x:Name="CommonStates">
                            <VisualState x:Name="Normal"/>
                            <VisualState x:Name="PointerOver">
                              <VisualState.Setters>
                                <Setter Target="Root.Background" Value="{StaticResource GhosttyTabHover}"/>
                              </VisualState.Setters>
                            </VisualState>
                            <VisualState x:Name="Pressed">
                              <VisualState.Setters>
                                <Setter Target="Root.Background" Value="{StaticResource GhosttyTabHover}"/>
                              </VisualState.Setters>
                            </VisualState>
                            <VisualState x:Name="Disabled"/>
                          </VisualStateGroup>
                        </VisualStateManager.VisualStateGroups>
                        <ContentPresenter x:Name="ContentPresenter" HorizontalAlignment="Stretch" VerticalAlignment="Center" Content="{TemplateBinding Content}" Foreground="{TemplateBinding Foreground}"/>
                      </Border>
                    </ControlTemplate>
                  </Setter.Value>
                </Setter>
              </Style>

              <!-- A copy of WinUI's TabViewCloseButtonStyle. The stock
                   template reaches it by name, but that Style is defined in
                   WinUI's own Generic.xaml and is not reachable from a
                   dictionary of ours: looking it up throws 0x802B000A
                   "Cannot find a Resource with the Name/Key
                   TabViewCloseButtonStyle" when the template is applied,
                   which kills the process rather than the tab. The brush
                   and size keys below do resolve, because those live in the
                   compiled theme resources that XamlControlsResources
                   merges into Application.Resources.
                   UseSystemFocusVisuals is dropped for the same reason as
                   the converter: a StaticResource outside the parsed markup
                   fails at Load time. -->
              <Style x:Key="GhosttyTabCloseButtonStyle" TargetType="Button">
                <Setter Property="HorizontalContentAlignment" Value="Center"/>
                <Setter Property="VerticalContentAlignment" Value="Center"/>
                <Setter Property="FontFamily" Value="{ThemeResource SymbolThemeFontFamily}"/>
                <Setter Property="FontSize" Value="{ThemeResource TabViewItemHeaderCloseFontSize}"/>
                <Setter Property="Width" Value="{ThemeResource TabViewItemHeaderCloseButtonWidth}"/>
                <Setter Property="Height" Value="{ThemeResource TabViewItemHeaderCloseButtonHeight}"/>
                <Setter Property="Background" Value="{ThemeResource TabViewItemHeaderCloseButtonBackground}"/>
                <Setter Property="Foreground" Value="{ThemeResource TabViewItemHeaderCloseButtonForeground}"/>
                <Setter Property="BorderBrush" Value="{ThemeResource TabViewItemHeaderCloseButtonBorderBrush}"/>
                <Setter Property="BorderThickness" Value="{ThemeResource TabViewItemHeaderCloseButtonBorderThickness}"/>
                <Setter Property="FocusVisualMargin" Value="-3"/>
                <Setter Property="Template">
                  <Setter.Value>
                    <ControlTemplate TargetType="Button">
                      <ContentPresenter x:Name="ContentPresenter" AutomationProperties.AccessibilityView="Raw" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" ContentTemplate="{TemplateBinding ContentTemplate}" Content="{TemplateBinding Content}" CornerRadius="{ThemeResource ControlCornerRadius}" ContentTransitions="{TemplateBinding ContentTransitions}" HorizontalContentAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalContentAlignment="{TemplateBinding VerticalContentAlignment}">
                        <VisualStateManager.VisualStateGroups>
                          <VisualStateGroup x:Name="CommonStates">
                            <VisualState x:Name="Normal"/>
                            <VisualState x:Name="PointerOver">
                              <VisualState.Setters>
                                <Setter Target="ContentPresenter.Background" Value="{ThemeResource TabViewItemHeaderCloseButtonBackgroundPointerOver}"/>
                                <Setter Target="ContentPresenter.Foreground" Value="{ThemeResource TabViewItemHeaderCloseButtonForegroundPointerOver}"/>
                                <Setter Target="ContentPresenter.BorderBrush" Value="{ThemeResource TabViewItemHeaderCloseButtonBorderBrushPointerOver}"/>
                              </VisualState.Setters>
                            </VisualState>
                            <VisualState x:Name="Pressed">
                              <VisualState.Setters>
                                <Setter Target="ContentPresenter.Background" Value="{ThemeResource TabViewItemHeaderCloseButtonBackgroundPressed}"/>
                                <Setter Target="ContentPresenter.Foreground" Value="{ThemeResource TabViewItemHeaderCloseButtonForegroundPressed}"/>
                                <Setter Target="ContentPresenter.BorderBrush" Value="{ThemeResource TabViewItemHeaderCloseButtonBorderBrushPressed}"/>
                              </VisualState.Setters>
                            </VisualState>
                          </VisualStateGroup>
                        </VisualStateManager.VisualStateGroups>
                      </ContentPresenter>
                    </ControlTemplate>
                  </Setter.Value>
                </Setter>
              </Style>)XAML";

    // The "+" / chevron split button. Its own template so hover uses our
    // themed brush instead of WinUI's default translucent overlay. That
    // overlay is also why lighting the pair from code did not match:
    // whichever half the pointer sat on stacked the overlay on top of the
    // brush and came out lighter.
    //
    // Three fills, as in Windows Terminal: hovered, pressed (a step
    // lighter again, which is the only feedback a click gets), and "lit"
    // while the profile menu is open. Lit is a second Border drawn over the
    // state-driven one and filled from BorderBrush -- unused otherwise,
    // since these buttons have no border -- so that code can light both
    // halves at once and neither half's pointer state can disagree with it.
    static constexpr wchar_t kXamlFooter[] =
        LR"XAML(   <Style x:Key="GhosttyFooterButtonStyle" TargetType="Button">
                <Setter Property="Background" Value="Transparent"/>
                <Setter Property="BorderBrush" Value="Transparent"/>
                <Setter Property="Foreground" Value="{ThemeResource TabViewItemHeaderForeground}"/>
                <Setter Property="Template">
                  <Setter.Value>
                    <ControlTemplate TargetType="Button">
                      <Grid>
                        <VisualStateManager.VisualStateGroups>
                          <VisualStateGroup x:Name="CommonStates">
                            <VisualState x:Name="Normal"/>
                            <VisualState x:Name="PointerOver">
                              <VisualState.Setters>
                                <Setter Target="Root.Background" Value="{StaticResource GhosttyTabHover}"/>
                              </VisualState.Setters>
                            </VisualState>
                            <VisualState x:Name="Pressed">
                              <VisualState.Setters>
                                <Setter Target="Root.Background" Value="{StaticResource GhosttyTabPressed}"/>
                              </VisualState.Setters>
                            </VisualState>
                            <VisualState x:Name="Disabled"/>
                          </VisualStateGroup>
                        </VisualStateManager.VisualStateGroups>
                        <Border x:Name="Root" Background="{TemplateBinding Background}" CornerRadius="{TemplateBinding CornerRadius}"/>
                        <Border x:Name="Lit" Background="{TemplateBinding BorderBrush}" CornerRadius="{TemplateBinding CornerRadius}"/>
                        <ContentPresenter x:Name="ContentPresenter" HorizontalAlignment="Center" VerticalAlignment="Center" Content="{TemplateBinding Content}" Foreground="{TemplateBinding Foreground}"/>
                      </Grid>
                    </ControlTemplate>
                  </Setter.Value>
                </Setter>
              </Style>)XAML";

    static constexpr wchar_t kXaml2[] =
        LR"XAML(   <Style TargetType="muxc:TabViewItem">
                <Setter Property="Background" Value="{StaticResource GhosttyTabUnselected}"/>
                <Setter Property="HorizontalContentAlignment" Value="Left"/>
                <Setter Property="MinHeight" Value="{ThemeResource TabViewItemMinHeight}"/>
                <Setter Property="BorderThickness" Value="{ThemeResource TabViewItemBorderThickness}"/>
                <Setter Property="BorderBrush" Value="{ThemeResource TabViewItemBorderBrush}"/>
                <Setter Property="Template">
                  <Setter.Value>
                    <ControlTemplate TargetType="muxc:TabViewItem">
                      <Grid x:Name="LayoutRoot" Padding="{TemplateBinding Padding}" UseLayoutRounding="False">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition x:Name="LeftColumn" Width="Auto"/>
                          <ColumnDefinition Width="*"/>
                          <ColumnDefinition x:Name="RightColumn" Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <Grid.RenderTransform>
                          <ScaleTransform x:Name="LayoutRootScale"/>
                        </Grid.RenderTransform>
                        <VisualStateManager.VisualStateGroups>
                          <VisualStateGroup x:Name="CommonStates">
                            <VisualState x:Name="Normal"/>
                            <VisualState x:Name="PointerOver">
                              <VisualState.Setters>
                                <Setter Target="TabContainer.Background" Value="{StaticResource GhosttyTabHover}"/>
                                <Setter Target="ContentPresenter.Foreground" Value="{ThemeResource TabViewItemHeaderForegroundPointerOver}"/>
                                <Setter Target="IconControl.Foreground" Value="{ThemeResource TabViewItemIconForegroundPointerOver}"/>
                                <Setter Target="CloseButton.Background" Value="{ThemeResource TabViewItemHeaderPointerOverCloseButtonBackground}"/>
                                <Setter Target="CloseButton.Foreground" Value="{ThemeResource TabViewItemHeaderPointerOverCloseButtonForeground}"/>
                                <Setter Target="TabSeparator.Opacity" Value="0"/>
                              </VisualState.Setters>
                            </VisualState>
                            <VisualState x:Name="Pressed">
                              <VisualState.Setters>
                                <Setter Target="TabContainer.Background" Value="{StaticResource GhosttyTabHover}"/>
                                <Setter Target="ContentPresenter.Foreground" Value="{ThemeResource TabViewItemHeaderForegroundPressed}"/>
                                <Setter Target="IconControl.Foreground" Value="{ThemeResource TabViewItemIconForegroundPressed}"/>
                                <Setter Target="CloseButton.Background" Value="{ThemeResource TabViewItemHeaderPressedCloseButtonBackground}"/>
                                <Setter Target="CloseButton.Foreground" Value="{ThemeResource TabViewItemHeaderPressedCloseButtonForeground}"/>
                                <Setter Target="TabSeparator.Opacity" Value="0"/>
                              </VisualState.Setters>
                            </VisualState>)XAML";

    static constexpr wchar_t kXaml3[] =
        LR"XAML(   <VisualState x:Name="Selected">
                              <VisualState.Setters>
                                <Setter Target="BottomBorderLine.Visibility" Value="Collapsed"/>
                                <Setter Target="LeftRadiusRenderArc.Visibility" Value="Visible"/>
                                <Setter Target="RightRadiusRenderArc.Visibility" Value="Visible"/>
                                <Setter Target="SelectedBackgroundPath.Visibility" Value="Visible"/>
                                <Setter Target="SelectedBackgroundPath.Fill" Value="{StaticResource GhosttyTabSelected}"/>
                                <Setter Target="TabContainer.Background" Value="Transparent"/>
                                <Setter Target="TabContainer.Margin" Value="{ThemeResource TabViewSelectedItemHeaderMargin}"/>
                                <Setter Target="TabContainer.Padding" Value="{ThemeResource TabViewSelectedItemHeaderPadding}"/>
                                <Setter Target="ContentPresenter.Foreground" Value="{ThemeResource TabViewItemHeaderForegroundSelected}"/>
                                <Setter Target="IconControl.Foreground" Value="{ThemeResource TabViewItemIconForegroundSelected}"/>
                                <Setter Target="CloseButton.Background" Value="{ThemeResource TabViewItemHeaderSelectedCloseButtonBackground}"/>
                                <Setter Target="CloseButton.Foreground" Value="{ThemeResource TabViewItemHeaderSelectedCloseButtonForeground}"/>
                                <Setter Target="LayoutRoot.Background" Value="Transparent"/>
                                <Setter Target="ContentPresenter.FontWeight" Value="SemiBold"/>
                              </VisualState.Setters>
                            </VisualState>
                            <VisualState x:Name="PointerOverSelected">
                              <VisualState.Setters>
                                <Setter Target="BottomBorderLine.Visibility" Value="Collapsed"/>
                                <Setter Target="LeftRadiusRenderArc.Visibility" Value="Visible"/>
                                <Setter Target="RightRadiusRenderArc.Visibility" Value="Visible"/>
                                <Setter Target="SelectedBackgroundPath.Visibility" Value="Visible"/>
                                <Setter Target="SelectedBackgroundPath.Fill" Value="{StaticResource GhosttyTabSelected}"/>
                                <Setter Target="TabContainer.Background" Value="Transparent"/>
                                <Setter Target="TabContainer.Margin" Value="{ThemeResource TabViewSelectedItemHeaderMargin}"/>
                                <Setter Target="TabContainer.Padding" Value="{ThemeResource TabViewSelectedItemHeaderPadding}"/>
                                <Setter Target="ContentPresenter.Foreground" Value="{ThemeResource TabViewItemHeaderForegroundSelected}"/>
                                <Setter Target="IconControl.Foreground" Value="{ThemeResource TabViewItemIconForegroundSelected}"/>
                                <Setter Target="CloseButton.Background" Value="{ThemeResource TabViewItemHeaderSelectedCloseButtonBackground}"/>
                                <Setter Target="CloseButton.Foreground" Value="{ThemeResource TabViewItemHeaderSelectedCloseButtonForeground}"/>
                                <Setter Target="LayoutRoot.Background" Value="Transparent"/>
                                <Setter Target="ContentPresenter.FontWeight" Value="SemiBold"/>
                              </VisualState.Setters>
                            </VisualState>
                            <VisualState x:Name="PressedSelected">
                              <VisualState.Setters>
                                <Setter Target="BottomBorderLine.Visibility" Value="Collapsed"/>
                                <Setter Target="LeftRadiusRenderArc.Visibility" Value="Visible"/>
                                <Setter Target="RightRadiusRenderArc.Visibility" Value="Visible"/>
                                <Setter Target="SelectedBackgroundPath.Visibility" Value="Visible"/>
                                <Setter Target="SelectedBackgroundPath.Fill" Value="{StaticResource GhosttyTabSelected}"/>
                                <Setter Target="TabContainer.Background" Value="Transparent"/>
                                <Setter Target="TabContainer.Margin" Value="{ThemeResource TabViewSelectedItemHeaderMargin}"/>
                                <Setter Target="TabContainer.Padding" Value="{ThemeResource TabViewSelectedItemHeaderPadding}"/>
                                <Setter Target="ContentPresenter.Foreground" Value="{ThemeResource TabViewItemHeaderForegroundSelected}"/>
                                <Setter Target="IconControl.Foreground" Value="{ThemeResource TabViewItemIconForegroundSelected}"/>
                                <Setter Target="CloseButton.Background" Value="{ThemeResource TabViewItemHeaderSelectedCloseButtonBackground}"/>
                                <Setter Target="CloseButton.Foreground" Value="{ThemeResource TabViewItemHeaderSelectedCloseButtonForeground}"/>
                                <Setter Target="LayoutRoot.Background" Value="Transparent"/>
                                <Setter Target="ContentPresenter.FontWeight" Value="SemiBold"/>
                              </VisualState.Setters>
                            </VisualState>
                          </VisualStateGroup>)XAML";

    static constexpr wchar_t kXaml4[] =
        LR"XAML(   <VisualStateGroup x:Name="DisabledStates">
                            <VisualState x:Name="Enabled"/>
                            <VisualState x:Name="Disabled">
                              <VisualState.Setters>
                                <Setter Target="TabContainer.Background" Value="{ThemeResource TabViewItemHeaderBackgroundDisabled}"/>
                                <Setter Target="ContentPresenter.Foreground" Value="{ThemeResource TabViewItemHeaderForegroundDisabled}"/>
                                <Setter Target="IconControl.Foreground" Value="{ThemeResource TabViewButtonForegroundDisabled}"/>
                                <Setter Target="CloseButton.Background" Value="{ThemeResource TabViewItemHeaderDisabledCloseButtonBackground}"/>
                                <Setter Target="CloseButton.Foreground" Value="{ThemeResource TabViewItemHeaderDisabledCloseButtonForeground}"/>
                              </VisualState.Setters>
                            </VisualState>
                          </VisualStateGroup>
                          <VisualStateGroup x:Name="IconStates">
                            <VisualState x:Name="Icon"/>
                            <VisualState x:Name="NoIcon">
                              <VisualState.Setters>
                                <Setter Target="IconBox.Visibility" Value="Collapsed"/>
                              </VisualState.Setters>
                            </VisualState>
                          </VisualStateGroup>
                          <VisualStateGroup x:Name="TabWidthModes">
                            <VisualState x:Name="StandardWidth"/>
                            <VisualState x:Name="Compact">
                              <VisualState.Setters>
                                <Setter Target="IconBox.Margin" Value="0,0,0,0"/>
                                <Setter Target="ContentPresenter.Visibility" Value="Collapsed"/>
                                <Setter Target="IconColumn.Width" Value="{ThemeResource TabViewItemHeaderIconSize}"/>
                              </VisualState.Setters>
                            </VisualState>
                          </VisualStateGroup>
                          <VisualStateGroup x:Name="CloseIconStates">
                            <VisualState x:Name="CloseButtonVisible"/>
                            <VisualState x:Name="CloseButtonCollapsed">
                              <VisualState.Setters>
                                <Setter Target="CloseButton.Visibility" Value="Collapsed"/>
                              </VisualState.Setters>
                            </VisualState>
                          </VisualStateGroup>
                          <VisualStateGroup>
                            <VisualState x:Name="ForegroundNotSet"/>
                            <VisualState x:Name="ForegroundSet">
                              <VisualState.Setters>
                                <Setter Target="IconControl.Foreground" Value="{Binding RelativeSource={RelativeSource TemplatedParent}, Path=Foreground}"/>
                                <Setter Target="ContentPresenter.Foreground" Value="{Binding RelativeSource={RelativeSource TemplatedParent}, Path=Foreground}"/>
                              </VisualState.Setters>
                            </VisualState>
                          </VisualStateGroup>
                          <VisualStateGroup>
                            <VisualState x:Name="NormalBottomBorderLine"/>
                            <VisualState x:Name="LeftOfSelectedTab">
                              <VisualState.Setters>
                                <Setter Target="BottomBorderLine.Margin" Value="0,0,2,0"/>
                              </VisualState.Setters>
                            </VisualState>
                            <VisualState x:Name="RightOfSelectedTab">
                              <VisualState.Setters>
                                <Setter Target="BottomBorderLine.Margin" Value="2,0,0,0"/>
                              </VisualState.Setters>
                            </VisualState>
                            <VisualState x:Name="NoBottomBorderLine">
                              <VisualState.Setters>
                                <Setter Target="BottomBorderLine.Visibility" Value="Collapsed"/>
                              </VisualState.Setters>
                            </VisualState>
                          </VisualStateGroup>
                        </VisualStateManager.VisualStateGroups>)XAML";

    static constexpr wchar_t kXaml5[] =
        LR"XAML(   <Border x:Name="BottomBorderLine" BorderBrush="{ThemeResource TabViewBorderBrush}" BorderThickness="1" Height="1" Grid.ColumnSpan="3" VerticalAlignment="Bottom"/>
                        <!-- The two arcs fill the notch where the selected tab meets the strip, so they take the selected colour, not the border colour the stock template uses. -->
                        <Path x:Name="LeftRadiusRenderArc" Fill="{StaticResource GhosttyTabSelected}" VerticalAlignment="Bottom" Visibility="Collapsed" Margin="-4,0,0,0" Height="4" Width="4" Data="M4 0C4 1.19469 3.47624 2.26706 2.64582 3H0C1.65685 3 3 1.65685 3 0H4Z"/>
                        <Path x:Name="RightRadiusRenderArc" Grid.Column="2" Visibility="Collapsed" Fill="{StaticResource GhosttyTabSelected}" VerticalAlignment="Bottom" Margin="0,0,-4,0" Height="4" Width="4" Data="M0 0C0 1.19469 0.523755 2.26706 1.35418 3H4C2.34315 3 1 1.65685 1 0H0Z"/>
                        <!-- Wrapped in a Canvas to prevent an infinite loop in calculating its width. -->
                        <Canvas>
                          <Path x:Name="SelectedBackgroundPath" Grid.ColumnSpan="3" Fill="{StaticResource GhosttyTabSelected}" VerticalAlignment="Bottom" Margin="-4,0,-4,0" Visibility="Collapsed" Data="{Binding RelativeSource={RelativeSource TemplatedParent}, Path=TabViewTemplateSettings.TabGeometry}"/>
                        </Canvas>
                        <Border x:Name="TabSeparator" HorizontalAlignment="Right" Width="1" Grid.Column="1" BorderBrush="{ThemeResource TabViewItemSeparator}" BorderThickness="1" Margin="{ThemeResource TabViewItemSeparatorMargin}"/>
                        <Grid x:Name="TabContainer" Grid.Column="1" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" Control.IsTemplateFocusTarget="True" Padding="{ThemeResource TabViewItemHeaderPadding}" CornerRadius="4,4,0,0" FocusVisualMargin="{TemplateBinding FocusVisualMargin}">
                          <Grid.ColumnDefinitions>
                            <ColumnDefinition x:Name="IconColumn" Width="Auto"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                          </Grid.ColumnDefinitions>
                          <Viewbox x:Name="IconBox" MaxWidth="{ThemeResource TabViewItemHeaderIconSize}" MaxHeight="{ThemeResource TabViewItemHeaderIconSize}" Margin="{ThemeResource TabViewItemHeaderIconMargin}">
                            <ContentControl x:Name="IconControl" Content="{Binding RelativeSource={RelativeSource TemplatedParent}, Path=TabViewTemplateSettings.IconElement}" IsTabStop="False" Foreground="{ThemeResource TabViewItemIconForeground}" HighContrastAdjustment="None"/>
                          </Viewbox>
                          <!-- Content is deliberately empty and filled in code-behind: template-binding it to Header makes an empty header implicitly bind to TabViewItem.Content. -->
                          <ContentPresenter x:Name="ContentPresenter" Grid.Column="1" HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}" Content="" ContentTemplate="{TemplateBinding HeaderTemplate}" ContentTransitions="{TemplateBinding ContentTransitions}" FontWeight="{TemplateBinding FontWeight}" FontSize="{ThemeResource TabViewItemHeaderFontSize}" Foreground="{ThemeResource TabViewItemHeaderForeground}" OpticalMarginAlignment="TrimSideBearings" HighContrastAdjustment="None"/>
                          <Button x:Name="CloseButton" Grid.Column="2" Margin="{ThemeResource TabViewItemHeaderCloseMargin}" Content="&#xE711;" IsTextScaleFactorEnabled="False" IsTabStop="False" Style="{StaticResource GhosttyTabCloseButtonStyle}" HighContrastAdjustment="None"/>
                        </Grid>
                      </Grid>
                    </ControlTemplate>
                  </Setter.Value>
                </Setter>
              </Style>
            </ResourceDictionary>)XAML";

    auto app = WUX::Application::Current();
    if (!app) return false;

    const std::wstring xaml =
        std::wstring{kXaml1} + kXamlFooter + kXaml2 + kXaml3 + kXaml4 + kXaml5;

    WUX::ResourceDictionary dict{nullptr};
    try {
        dict = WUX::Markup::XamlReader::Load(winrt::hstring{xaml})
                   .try_as<WUX::ResourceDictionary>();
    } catch (hresult_error const& e) {
        // A parse failure is not fatal: the strip still works, it just
        // wears WinUI's default tab colours.
        Log("theme: XamlReader failed 0x%08X: %ls", (unsigned)e.code(),
            e.message().c_str());
        return false;
    }
    if (!dict) {
        Log("theme: XamlReader did not yield a ResourceDictionary");
        return false;
    }
    // Merged into the bar's root once that exists, not into the
    // Application: see GhosttyTabBar::theme_dict.
    bar->theme_dict = dict;

    auto grab = [&](wchar_t const* key) {
        return dict.TryLookup(winrt::box_value(key))
            .try_as<WUX::Media::SolidColorBrush>();
    };
    bar->b_selected = grab(L"GhosttyTabSelected");
    bar->b_unselected = grab(L"GhosttyTabUnselected");
    bar->b_hover = grab(L"GhosttyTabHover");
    bar->b_pressed = grab(L"GhosttyTabPressed");

    Log("theme: template installed (selected=%d unselected=%d hover=%d)",
        bar->b_selected ? 1 : 0, bar->b_unselected ? 1 : 0,
        bar->b_hover ? 1 : 0);
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
struct Profile {
    GhosttyProfileId id;
    std::wstring name;
    std::wstring icon_path;
    /// A Segoe Fluent Icons glyph to show instead of a file's icon, for
    /// the rows that are commands rather than shells.
    std::wstring glyph;
};
std::unordered_map<GhosttyTabBar*, std::vector<Profile>> g_profiles;

// Caption button metrics, matching the system title bar at 96 DPI.
constexpr double kCaptionButtonWidth = 46.0;

// Puts Win32 popup menus into dark or light mode.
//
// TrackPopupMenu draws a classic menu, which does not follow the app's
// XAML theme and defaults to light -- so the shell picker came up white
// on a dark title bar. The switch for this is uxtheme's SetPreferredAppMode,
// which has no header and no name in the export table: it is ordinal 135
// (and FlushMenuThemes, needed to repaint already-created menu theme data,
// is 136). This is what Explorer, Windows Terminal and Notepad++ all use.
//
// Undocumented means it can vanish; every step is failure-tolerant and a
// menu that stays light is the worst case. Ordinal 135 was AllowDarkModeForApp
// taking a BOOL before Windows 10 1903, so this is gated on the build.
void SetMenuTheme(bool dark) {
    enum class PreferredAppMode { Default, AllowDark, ForceDark, ForceLight };
    using SetPreferredAppModeFn = PreferredAppMode(WINAPI*)(PreferredAppMode);
    using FlushMenuThemesFn = void(WINAPI*)();

    static HMODULE uxtheme = ::LoadLibraryExW(
        L"uxtheme.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!uxtheme) return;

    // RtlGetVersion rather than GetVersionEx: the latter lies about the
    // build number unless the app manifest opts in per OS release.
    using RtlGetVersionFn = LONG(WINAPI*)(PRTL_OSVERSIONINFOW);
    static const DWORD build = [] () -> DWORD {
        HMODULE nt = ::GetModuleHandleW(L"ntdll.dll");
        if (!nt) return 0;
        auto fn = reinterpret_cast<RtlGetVersionFn>(
            ::GetProcAddress(nt, "RtlGetVersion"));
        if (!fn) return 0;
        RTL_OSVERSIONINFOW vi{};
        vi.dwOSVersionInfoSize = sizeof(vi);
        if (fn(&vi) != 0) return 0;
        return vi.dwBuildNumber;
    }();
    if (build < 18362) return;

    static auto set_mode = reinterpret_cast<SetPreferredAppModeFn>(
        ::GetProcAddress(uxtheme, MAKEINTRESOURCEA(135)));
    static auto flush = reinterpret_cast<FlushMenuThemesFn>(
        ::GetProcAddress(uxtheme, MAKEINTRESOURCEA(136)));
    if (!set_mode) return;

    set_mode(dark ? PreferredAppMode::ForceDark : PreferredAppMode::ForceLight);
    if (flush) flush();
}

// Segoe Fluent Icons / Segoe MDL2 Assets codepoints. These are literal
// characters in the private use area, so they show up blank in most
// editors: Add E710, Chevron E70D, Minimize E921, Maximize E922, Restore
// E923, Close E8BB. Writing them as \uXXXX escapes instead does not
// stick -- something in this checkout rewrites them back to literals --
// which is exactly why build.bat must pass /utf-8. Without it MSVC reads
// them in the system ANSI codepage and every one renders as tofu.
constexpr wchar_t kGlyphAdd[]      = L"";
constexpr wchar_t kGlyphChevron[]  = L"";
constexpr wchar_t kGlyphMinimize[] = L"";
constexpr wchar_t kGlyphMaximize[] = L"";
constexpr wchar_t kGlyphRestore[]  = L"";
constexpr wchar_t kGlyphClose[]    = L"";

// TaskView, E7C4: the overlapping-windows glyph Windows itself uses for
// "show me everything that is open". Spelled as a number so that it does
// not depend on the literals above surviving an editor.
constexpr wchar_t kGlyphOverview[] = {0xE7C4, 0};

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

// The shell picker.
//
// This is a real Fluent menu: a WinUI list in its own XAML island, in its
// own top-level window. It has to be its own window because island popups
// are clipped to the island's HWND, and the strip's island is only as tall
// as the strip -- a MenuFlyout hung off the chevron opens correctly and is
// entirely invisible. That clipping is why this used to be a Win32
// TrackPopupMenu, which looks like Windows 95 next to the rest of the
// title bar.
//
// The window is modeless. A modal loop of our own would starve the XAML
// dispatcher that this very menu needs to lay out and animate, so instead
// it is shown, activated, and left to the host's message loop; it closes
// itself when an item is picked, when Escape is pressed, or when it loses
// activation.
//
// It is built once and then kept, parked off-screen while closed, rather
// than created on every click. Building it on demand cost the better part
// of half a second -- a second XAML island each time -- and the window was
// on screen before XAML had composed anything into it, so it opened as an
// empty frame with the terminal showing through. Hiding it instead of
// parking it would bring that frame back: XAML does not compose for a
// hidden window, which is the same reason the main window starts life
// off-screen. Parked, it is already composed, and opening it is a move.
struct ProfileMenu {
    GhosttyTabBar* bar = nullptr;
    HWND hwnd = nullptr;
    WUX::Hosting::DesktopWindowXamlSource source{nullptr};
    com_ptr<IDesktopWindowXamlSourceNative2> native;
    /// On screen and taking input, as opposed to parked.
    bool open = false;
    /// Set once the window has actually taken activation. Until then a
    /// WM_ACTIVATE(WA_INACTIVE) is part of the show sequence, not the user
    /// dismissing anything -- closing on it made the menu vanish the
    /// instant it appeared.
    bool activated = false;
    /// One row per profile, in order, and the profile each one opens.
    std::vector<WUX::Controls::Border> rows;
    std::vector<GhosttyProfileId> ids;
    /// The row the pointer or the arrow keys are on, or -1.
    int highlighted = -1;
};

// Where a closed menu waits. The same coordinates Windows itself uses for
// a minimized window, so nothing treats it as being on any monitor.
constexpr int kMenuParkedAt = -32000;

constexpr wchar_t kMenuClassName[] = L"GhosttyProfileMenu";

// Posted to the menu window to make it appear.
//
// Showing it inline from the chevron's Click handler does not survive:
// the menu takes activation, the handler returns, and XAML then finishes
// processing the very pointer release that ran it -- restoring focus to
// the strip's island, which activates the main window and deactivates the
// menu instantly. Posting defers the show until that is all over.
constexpr UINT WM_GHOSTTY_SHOW_MENU = WM_APP + 1;

// Menu metrics at 96 DPI, matching a Windows 11 context menu.
constexpr int kMenuItemHeight = 32;
constexpr int kMenuIconSize = 16;
constexpr int kMenuPadding = 4;
constexpr int kMenuWidth = 300;
constexpr int kMenuCornerRadius = 8;

std::unordered_map<HWND, ProfileMenu*> g_menus;

/// Follows an app execution alias to the executable behind it.
///
/// A Store-installed shell is reached through a zero-byte stub in
/// %LOCALAPPDATA%\Microsoft\WindowsApps -- that is what `pwsh.exe` resolves
/// to on the search path when PowerShell came from the Store or winget's
/// MSIX. The stub has no resources, so asking the shell for its icon gets
/// the generic "program" one. The real path is recorded in the stub's
/// reparse data: a version, then three NUL-terminated strings, of which
/// the third is the target executable. Anything that is not such a stub
/// comes back unchanged.
std::wstring ResolveAppExecAlias(std::wstring const& path) {
    const DWORD attrs = ::GetFileAttributesW(path.c_str());
    if (attrs == INVALID_FILE_ATTRIBUTES ||
        !(attrs & FILE_ATTRIBUTE_REPARSE_POINT)) {
        return path;
    }

    HANDLE file = ::CreateFileW(
        path.c_str(), 0,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
        OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (file == INVALID_HANDLE_VALUE) return path;

    std::vector<uint8_t> data(MAXIMUM_REPARSE_DATA_BUFFER_SIZE);
    DWORD got = 0;
    const BOOL ok = ::DeviceIoControl(
        file, FSCTL_GET_REPARSE_POINT, nullptr, 0, data.data(),
        static_cast<DWORD>(data.size()), &got, nullptr);
    ::CloseHandle(file);

    // An 8-byte reparse header, then the 4-byte version.
    constexpr size_t kStrings = 12;
    if (!ok || got <= kStrings) return path;
    DWORD tag = 0;
    memcpy(&tag, data.data(), sizeof(tag));
    if (tag != IO_REPARSE_TAG_APPEXECLINK) return path;

    const size_t count = (got - kStrings) / sizeof(wchar_t);
    std::vector<wchar_t> text(count);
    memcpy(text.data(), data.data() + kStrings, count * sizeof(wchar_t));

    size_t start = 0;
    for (int field = 0; field < 3; ++field) {
        size_t end = start;
        while (end < count && text[end] != L'\0') ++end;
        if (field == 2) {
            return end > start
                       ? std::wstring(text.data() + start, end - start)
                       : path;
        }
        start = end + 1;
        if (start >= count) break;
    }
    return path;
}

/// Turns a file's shell icon into something XAML can draw.
///
/// SHGetFileInfo gives an HICON; WinUI wants pixels. The colour bitmap
/// inside the icon is already 32-bit BGRA, which is exactly the layout a
/// WriteableBitmap wants, so this is a straight copy -- except that icon
/// bitmaps carry straight alpha and XAML expects it premultiplied, hence
/// the scaling of the colour channels.
WUX::Media::Imaging::WriteableBitmap LoadShellIcon(std::wstring const& given) {
    if (given.empty()) return nullptr;
    const std::wstring path = ResolveAppExecAlias(given);

    SHFILEINFOW info{};
    if (!::SHGetFileInfoW(path.c_str(), 0, &info, sizeof(info),
                          SHGFI_ICON | SHGFI_SMALLICON)) {
        return nullptr;
    }
    if (!info.hIcon) return nullptr;

    ICONINFO ii{};
    if (!::GetIconInfo(info.hIcon, &ii)) {
        ::DestroyIcon(info.hIcon);
        return nullptr;
    }

    BITMAP bm{};
    ::GetObjectW(ii.hbmColor, sizeof(bm), &bm);
    const int w = bm.bmWidth, h = bm.bmHeight;

    std::vector<uint8_t> pixels(static_cast<size_t>(w) * h * 4);
    BITMAPINFO bi{};
    bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
    bi.bmiHeader.biWidth = w;
    // Negative height: top-down rows, so no flip afterwards.
    bi.bmiHeader.biHeight = -h;
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;

    HDC dc = ::GetDC(nullptr);
    const bool ok = ::GetDIBits(dc, ii.hbmColor, 0, h, pixels.data(), &bi,
                                DIB_RGB_COLORS) != 0;
    ::ReleaseDC(nullptr, dc);
    if (ii.hbmColor) ::DeleteObject(ii.hbmColor);
    if (ii.hbmMask) ::DeleteObject(ii.hbmMask);
    ::DestroyIcon(info.hIcon);
    if (!ok) return nullptr;

    for (size_t i = 0; i < pixels.size(); i += 4) {
        const uint32_t a = pixels[i + 3];
        pixels[i + 0] = static_cast<uint8_t>(pixels[i + 0] * a / 255);
        pixels[i + 1] = static_cast<uint8_t>(pixels[i + 1] * a / 255);
        pixels[i + 2] = static_cast<uint8_t>(pixels[i + 2] * a / 255);
    }

    WUX::Media::Imaging::WriteableBitmap bmp{w, h};
    auto buffer = bmp.PixelBuffer();
    auto access = buffer.as<::Windows::Storage::Streams::IBufferByteAccess>();
    uint8_t* dst = nullptr;
    if (FAILED(access->Buffer(&dst)) || !dst) return nullptr;
    memcpy(dst, pixels.data(), pixels.size());
    bmp.Invalidate();
    return bmp;
}

/// LoadShellIcon, memoized by path.
///
/// Tabs ask for their icon on every creation and several tabs running the
/// same shell is the ordinary case, so without this the strip goes to disk
/// through SHGetFileInfo once per tab -- on the UI thread. A failed lookup
/// is cached as null too, so a path that has no icon is not retried
/// forever.
WUX::Media::Imaging::WriteableBitmap CachedShellIcon(std::wstring const& path) {
    static std::unordered_map<std::wstring,
                              WUX::Media::Imaging::WriteableBitmap> cache;
    auto it = cache.find(path);
    if (it != cache.end()) return it->second;
    auto bmp = LoadShellIcon(path);
    cache.emplace(path, bmp);
    return bmp;
}

UINT DpiOf(GhosttyTabBar* bar) {
    if (bar && bar->parent_hwnd) {
        if (UINT dpi = ::GetDpiForWindow(bar->parent_hwnd)) return dpi;
    }
    return 96;
}

/// Lights both halves of the new-tab button, or puts them back. See the
/// "Lit" border in GhosttyFooterButtonStyle.
void LightFooter(GhosttyTabBar* bar, bool lit) {
    try {
        for (auto const& button : {bar->plus, bar->chevron}) {
            if (!button) continue;
            if (lit && bar->b_pressed) {
                button.BorderBrush(bar->b_pressed);
            } else {
                button.BorderBrush(WUX::Media::SolidColorBrush(
                    winrt::Windows::UI::Color{0, 0, 0, 0}));
            }
        }
    } catch (...) {
    }
}

/// Moves the highlight to `index`, or clears it with -1.
///
/// Driven from code rather than from XAML pointer states because the
/// arrow keys move it too, and because a row the pointer was on when the
/// menu was parked never hears that the pointer left.
void HighlightMenuRow(ProfileMenu* menu, int index) {
    if (!menu || menu->highlighted == index) return;
    const int count = static_cast<int>(menu->rows.size());
    try {
        if (menu->highlighted >= 0 && menu->highlighted < count) {
            menu->rows[menu->highlighted].Background(WUX::Media::SolidColorBrush(
                winrt::Windows::UI::Color{0, 0, 0, 0}));
        }
        if (index >= 0 && index < count) {
            menu->rows[index].Background(
                WUX::Media::SolidColorBrush(menu->bar->menu_hover));
        }
    } catch (...) {
    }
    menu->highlighted = (index >= 0 && index < count) ? index : -1;
}

/// Takes the menu off screen. `reactivate` hands activation back to the
/// host window, which is wanted when the menu closed itself (a pick,
/// Escape) and not when it closed because something else was activated.
void HideProfileMenu(ProfileMenu* menu, bool reactivate) {
    if (!menu || !menu->open) return;
    menu->open = false;
    menu->activated = false;

    GhosttyTabBar* bar = menu->bar;
    bar->menu_closed_at = ::GetMessageTime();
    LightFooter(bar, false);
    HighlightMenuRow(menu, -1);

    const bool active = ::GetActiveWindow() == menu->hwnd;
    ::SetWindowPos(menu->hwnd, nullptr, kMenuParkedAt, kMenuParkedAt, 0, 0,
                   SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    // Destroying the window used to return activation to its owner for
    // free. Parking it does not, and a parked window that still holds
    // activation would swallow the keyboard.
    if (reactivate && active && bar->parent_hwnd) {
        ::SetActiveWindow(bar->parent_hwnd);
    }
}

void PickMenuRow(ProfileMenu* menu, int index) {
    if (!menu || index < 0 || index >= static_cast<int>(menu->ids.size())) return;
    GhosttyTabBar* bar = menu->bar;
    GhosttyProfileId id = menu->ids[index];
    // Ctrl held while picking a shell asks for it elevated, which is
    // Windows Terminal's gesture for the same thing.
    if (id < GHOSTTY_MENU_SETTINGS && ::GetKeyState(VK_CONTROL) < 0) {
        id |= GHOSTTY_PROFILE_ELEVATED;
    }
    HideProfileMenu(menu, true);
    if (bar->cb.on_new_tab) bar->cb.on_new_tab(bar->cb.ctx, id);
}

/// Builds one row: icon, then label, filling the menu's width.
///
/// A Border with its own brushes and hand-rolled hover, rather than a
/// Button wearing a Style out of the shared dictionary. Everything the
/// menu draws with has to be created here, in the menu's own tree -- see
/// the note on GhosttyTabBar::menu_bg.
WUX::Controls::Border MakeMenuItem(GhosttyTabBar* bar, Profile const& p,
                                   ProfileMenu* menu, int index) {
    WUX::Controls::Grid row;
    WUX::Controls::ColumnDefinition icon_col;
    icon_col.Width(WUX::GridLengthHelper::FromValueAndType(
        kMenuIconSize + 12, WUX::GridUnitType::Pixel));
    WUX::Controls::ColumnDefinition text_col;
    text_col.Width(WUX::GridLengthHelper::FromValueAndType(
        1, WUX::GridUnitType::Star));
    row.ColumnDefinitions().Append(icon_col);
    row.ColumnDefinitions().Append(text_col);

    if (!p.glyph.empty()) {
        WUX::Controls::FontIcon icon;
        icon.Glyph(p.glyph);
        icon.FontFamily(
            WUX::Media::FontFamily(L"Segoe Fluent Icons, Segoe MDL2 Assets"));
        icon.FontSize(kMenuIconSize);
        icon.HorizontalAlignment(WUX::HorizontalAlignment::Left);
        icon.VerticalAlignment(WUX::VerticalAlignment::Center);
        icon.Foreground(WUX::Media::SolidColorBrush(bar->menu_text));
        row.Children().Append(icon);
    } else if (auto bmp = CachedShellIcon(p.icon_path)) {
        WUX::Controls::Image image;
        image.Source(bmp);
        image.Width(kMenuIconSize);
        image.Height(kMenuIconSize);
        image.HorizontalAlignment(WUX::HorizontalAlignment::Left);
        image.VerticalAlignment(WUX::VerticalAlignment::Center);
        row.Children().Append(image);
    }

    WUX::Controls::TextBlock label;
    label.Text(p.name);
    label.FontSize(14);
    label.VerticalAlignment(WUX::VerticalAlignment::Center);
    label.TextTrimming(WUX::TextTrimming::CharacterEllipsis);
    label.Foreground(WUX::Media::SolidColorBrush(bar->menu_text));
    WUX::Controls::Grid::SetColumn(label, 1);
    row.Children().Append(label);

    WUX::Controls::Border item;
    item.Child(row);
    item.Height(kMenuItemHeight);
    item.Padding(WUX::ThicknessHelper::FromLengths(10, 0, 10, 0));
    item.CornerRadius(WUX::CornerRadiusHelper::FromUniformRadius(4));
    item.Background(WUX::Media::SolidColorBrush(
        winrt::Windows::UI::Color{0, 0, 0, 0}));

    item.PointerEntered([menu, index](auto&&, auto&&) {
        HighlightMenuRow(menu, index);
    });
    item.PointerExited([menu, index](auto&&, auto&&) {
        if (menu->highlighted == index) HighlightMenuRow(menu, -1);
    });
    item.Tapped([menu, index](auto&&, auto&&) { PickMenuRow(menu, index); });
    return item;
}

void DestroyProfileMenu(GhosttyTabBar* bar) {
    ProfileMenu* menu = bar ? bar->menu : nullptr;
    if (!menu) return;
    bar->menu = nullptr;
    menu->open = false;

    if (menu->source) {
        try {
            menu->source.Close();
        } catch (...) {
        }
    }
    if (menu->hwnd) {
        g_menus.erase(menu->hwnd);
        ::DestroyWindow(menu->hwnd);
    }
    delete menu;
}

LRESULT CALLBACK MenuWndProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    auto it = g_menus.find(hwnd);
    ProfileMenu* menu = it == g_menus.end() ? nullptr : it->second;

    switch (msg) {
        case WM_GHOSTTY_SHOW_MENU:
            if (!menu || !menu->open) return 0;
            ::SetForegroundWindow(hwnd);
            ::SetFocus(hwnd);
            return 0;

        case WM_ACTIVATE:
            if (!menu) break;
            if (LOWORD(wparam) != WA_INACTIVE) {
                if (menu->open) menu->activated = true;
                return 0;
            }
            // Anything that takes activation away dismisses the menu, which
            // is how clicking the terminal, another window, or the chevron
            // closes it -- but only once it has been activated at all.
            if (menu->activated) {
                HideProfileMenu(menu, false);
                return 0;
            }
            break;

        // The keyboard. Focus is on this window rather than on anything
        // inside the island -- the rows are Borders, which cannot take
        // focus -- so a KeyDown handler in the XAML tree never fires. That
        // is why Escape used to do nothing.
        case WM_KEYDOWN: {
            if (!menu || !menu->open) break;
            const int count = static_cast<int>(menu->rows.size());
            switch (wparam) {
                case VK_ESCAPE:
                    HideProfileMenu(menu, true);
                    return 0;
                case VK_DOWN:
                    if (count > 0) {
                        HighlightMenuRow(menu, (menu->highlighted + 1) % count);
                    }
                    return 0;
                case VK_UP:
                    if (count > 0) {
                        HighlightMenuRow(
                            menu, menu->highlighted <= 0 ? count - 1
                                                         : menu->highlighted - 1);
                    }
                    return 0;
                case VK_RETURN:
                    PickMenuRow(menu, menu->highlighted);
                    return 0;
            }
            break;
        }

        case WM_SIZE:
            if (menu && menu->source) {
                if (auto n = menu->source.try_as<IDesktopWindowXamlSourceNative>()) {
                    HWND island = nullptr;
                    if (SUCCEEDED(n->get_WindowHandle(&island)) && island) {
                        ::SetWindowPos(island, nullptr, 0, 0, LOWORD(lparam),
                                       HIWORD(lparam),
                                       SWP_NOZORDER | SWP_SHOWWINDOW);
                    }
                }
            }
            return 0;
    }
    return ::DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// Creates the menu's window and island if they do not exist yet, lays its
/// rows out from the current profiles and theme, and leaves it parked.
bool BuildProfileMenu(GhosttyTabBar* bar) {
    auto const& profiles = g_profiles[bar];
    if (profiles.empty()) return false;

    static bool registered = false;
    if (!registered) {
        WNDCLASSEXW wc{};
        wc.cbSize = sizeof(wc);
        // CS_DROPSHADOW is what gives the menu the same soft shadow the
        // system's own menus have.
        wc.style = CS_DROPSHADOW;
        wc.lpfnWndProc = MenuWndProc;
        wc.hInstance = ::GetModuleHandleW(nullptr);
        wc.hCursor = ::LoadCursorW(nullptr, IDC_ARROW);
        wc.lpszClassName = kMenuClassName;
        if (!::RegisterClassExW(&wc)) {
            Log("menu: RegisterClassExW failed err=%lu", ::GetLastError());
            return false;
        }
        registered = true;
    }

    // The island lays out in DIPs and the window is sized in pixels.
    const int dpi = static_cast<int>(DpiOf(bar));
    const int width = ::MulDiv(kMenuWidth, dpi, 96);
    // Below the shells, the two things that are not shells, as in Windows
    // Terminal's menu. They go back through on_new_tab under reserved ids.
    const Profile commands[] = {
        {GHOSTTY_MENU_SETTINGS, L"Settings", L"", {wchar_t{0xE713}}},
        {GHOSTTY_MENU_PALETTE, L"Command palette", L"", {wchar_t{0xE945}}},
    };
    constexpr int kMenuSeparator = 9;
    const int row_count =
        static_cast<int>(profiles.size() + std::size(commands));
    const int height = ::MulDiv(
        row_count * kMenuItemHeight + kMenuSeparator + kMenuPadding * 2, dpi,
        96);

    ProfileMenu* menu = bar->menu;
    try {
        if (!menu) {
            menu = new ProfileMenu{};
            menu->bar = bar;

            // WS_EX_TOOLWINDOW keeps it out of the taskbar and Alt-Tab.
            menu->hwnd = ::CreateWindowExW(
                WS_EX_TOOLWINDOW, kMenuClassName, L"", WS_POPUP, kMenuParkedAt,
                kMenuParkedAt, width, height, bar->parent_hwnd, nullptr,
                ::GetModuleHandleW(nullptr), nullptr);
            if (!menu->hwnd) {
                Log("menu: CreateWindowExW failed err=%lu", ::GetLastError());
                delete menu;
                return false;
            }
            g_menus[menu->hwnd] = menu;
            bar->menu = menu;

            // Rounded corners. Windows 11 only; the call simply fails on
            // 10, which leaves square corners and nothing else broken.
            const DWORD corner = 2;  // DWMWCP_ROUND
            ::DwmSetWindowAttribute(
                menu->hwnd, 33 /* DWMWA_WINDOW_CORNER_PREFERENCE */, &corner,
                sizeof(corner));

            menu->source = WUX::Hosting::DesktopWindowXamlSource();
            auto native = menu->source.as<IDesktopWindowXamlSourceNative>();
            check_hresult(native->AttachToWindow(menu->hwnd));
            HWND island = nullptr;
            check_hresult(native->get_WindowHandle(&island));
            // AttachToWindow leaves the island hidden -- it comes back as a
            // bare WS_CHILD with no WS_VISIBLE, so the window rendered as
            // an empty frame with the terminal showing straight through it.
            ::SetWindowPos(island, nullptr, 0, 0, width, height,
                           SWP_NOZORDER | SWP_SHOWWINDOW);
            menu->native = menu->source.try_as<IDesktopWindowXamlSourceNative2>();
        }

        menu->rows.clear();
        menu->ids.clear();
        menu->highlighted = -1;

        WUX::Controls::StackPanel list;
        list.Orientation(WUX::Controls::Orientation::Vertical);
        int index = 0;
        for (auto const& p : profiles) {
            auto row = MakeMenuItem(bar, p, menu, index++);
            menu->rows.push_back(row);
            menu->ids.push_back(p.id);
            list.Children().Append(row);
        }

        WUX::Controls::Border separator;
        separator.Height(1);
        separator.Margin(WUX::ThicknessHelper::FromLengths(0, 4, 0, 4));
        separator.Background(WUX::Media::SolidColorBrush(bar->menu_border));
        list.Children().Append(separator);

        for (auto const& p : commands) {
            auto row = MakeMenuItem(bar, p, menu, index++);
            menu->rows.push_back(row);
            menu->ids.push_back(p.id);
            list.Children().Append(row);
        }

        WUX::Controls::Border root;
        root.Child(list);
        root.Padding(WUX::ThicknessHelper::FromUniformLength(kMenuPadding));
        root.CornerRadius(
            WUX::CornerRadiusHelper::FromUniformRadius(kMenuCornerRadius));
        root.BorderThickness(WUX::ThicknessHelper::FromUniformLength(1));
        root.RequestedTheme(bar->root ? bar->root.RequestedTheme()
                                      : WUX::ElementTheme::Default);
        root.Background(WUX::Media::SolidColorBrush(bar->menu_bg));
        root.BorderBrush(WUX::Media::SolidColorBrush(bar->menu_border));
        menu->source.Content(root);
    } catch (hresult_error const& e) {
        Log("menu: island failed 0x%08X: %ls", (unsigned)e.code(),
            e.message().c_str());
        DestroyProfileMenu(bar);
        return false;
    }

    // Shown, but where nobody can see it: XAML only composes for a visible
    // window, and composed is what makes opening it instant. An open menu
    // is left where it is and only resized.
    if (menu->open) {
        ::SetWindowPos(menu->hwnd, nullptr, 0, 0, width, height,
                       SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    } else {
        ::SetWindowPos(menu->hwnd, nullptr, kMenuParkedAt, kMenuParkedAt, width,
                       height,
                       SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    }
    bar->menu_dirty = false;
    return true;
}

void ShowProfileMenu(GhosttyTabBar* bar) {
    // Clicking the chevron while the menu is open must only close it. The
    // click first takes activation away, which closes the menu, and only
    // then reaches the button -- which would ask for a new one. Refusing to
    // reopen within a moment of closing is what makes the pair behave as a
    // toggle. GetMessageTime reports when the input happened rather than
    // when we got round to it, which is what makes the window meaningful.
    if (bar->menu && bar->menu->open) {
        HideProfileMenu(bar->menu, true);
        return;
    }
    if (bar->menu_closed_at != 0) {
        const LONG dt = ::GetMessageTime() - bar->menu_closed_at;
        if (dt >= 0 && dt < kMenuReopenGuardMs) {
            bar->menu_closed_at = 0;
            return;
        }
    }

    // Normally already built by the prewarm timer; this is the click that
    // beat it, or the first one after the profiles or theme changed.
    if (!bar->menu || bar->menu_dirty) {
        if (!BuildProfileMenu(bar)) return;
    }
    ProfileMenu* menu = bar->menu;

    // Anchor under the "+" so the menu belongs to the whole split button,
    // which is where Windows Terminal hangs it from -- and below the strip
    // rather than below the button, so it does not sit on top of the
    // strip's bottom edge.
    POINT pt{0, 0};
    auto anchor = bar->plus ? bar->plus : bar->chevron;
    if (anchor && bar->island_hwnd) {
        const double scale = static_cast<double>(DpiOf(bar)) / 96.0;
        try {
            auto transform = anchor.TransformToVisual(nullptr);
            auto origin = transform.TransformPoint(
                winrt::Windows::Foundation::Point{
                    0.0f, static_cast<float>(anchor.ActualHeight())});
            pt.x = static_cast<LONG>(origin.X * scale);
            pt.y = static_cast<LONG>(
                (origin.Y + kFooterButtonBottomGap + 2.0) * scale);
        } catch (...) {
        }
        ::ClientToScreen(bar->island_hwnd, &pt);
    } else {
        ::GetCursorPos(&pt);
    }

    menu->open = true;
    menu->activated = false;
    LightFooter(bar, true);
    ::SetWindowPos(menu->hwnd, HWND_TOP, pt.x, pt.y, 0, 0,
                   SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);

    // Activation is deferred: see WM_GHOSTTY_SHOW_MENU. It is what makes
    // WM_ACTIVATE(WA_INACTIVE) fire when the user clicks anywhere else,
    // which is the whole dismissal mechanism -- so it has to happen after
    // the click that opened the menu is completely done with. The menu is
    // already on screen by then; only the keyboard waits.
    ::PostMessageW(menu->hwnd, WM_GHOSTTY_SHOW_MENU, 0, 0);
}

/// Arranges for the menu to be built once startup has settled.
///
/// A timer rather than building it on the spot: this is reached from
/// set_theme, which runs while the window is still coming up, and a second
/// XAML island is not something to put between the user and a prompt.
void ScheduleMenuPrewarm(GhosttyTabBar* bar) {
    try {
        if (!bar->menu_prewarm) {
            WUX::DispatcherTimer timer;
            timer.Interval(std::chrono::milliseconds(1500));
            timer.Tick([bar](auto&&, auto&&) {
                // The bar's entry in g_profiles lasts exactly as long as
                // the bar does.
                if (g_profiles.find(bar) == g_profiles.end()) return;
                if (bar->menu_prewarm) bar->menu_prewarm.Stop();
                if (bar->menu_dirty) BuildProfileMenu(bar);
            });
            bar->menu_prewarm = timer;
        }
        bar->menu_prewarm.Stop();
        bar->menu_prewarm.Start();
    } catch (...) {
    }
}

// The input popup: one line of text, optionally with a list under it.
//
// It is the search box, the command palette and the rename prompt, which
// are the same thing three times: somewhere to type, something to pick
// from, and Enter or Escape. What each one means is the host's business;
// this only reports what was typed, what was picked and that it was
// dismissed.
//
// Plain Win32 controls rather than a third XAML island. A XAML TextBox
// needs keyboard focus inside its island, and focus across islands is the
// one thing here that has never behaved; an EDIT control simply takes it.
// The price is that the list is an owner-drawn LISTBOX instead of a
// ListView, which nobody looking at a list of commands will notice.
struct InputPopup {
    GhosttyTabBar* bar = nullptr;
    HWND hwnd = nullptr;
    HWND edit = nullptr;
    HWND list = nullptr;
    WNDPROC edit_proc = nullptr;
    GhosttyInputCallbacks cb{};
    /// Enter reports and leaves the popup up, for "find next".
    bool keep_open = false;
    bool visible = false;
    bool activated = false;
    /// Set while the text is being replaced from code, which must not be
    /// reported back as the user typing.
    bool setting = false;
    std::wstring status;
    HFONT font = nullptr;
    HBRUSH bg = nullptr;
    int width = 0;
    int items = 0;
};

constexpr wchar_t kInputClassName[] = L"GhosttyInputPopup";
constexpr UINT WM_GHOSTTY_ACTIVATE_INPUT = WM_APP + 2;

// Metrics at 96 DPI.
constexpr int kInputPad = 8;
constexpr int kInputRowHeight = 36;
constexpr int kInputEditHeight = 20;
constexpr int kInputItemHeight = 30;
constexpr int kInputMaxItems = 10;
constexpr int kInputStatusWidth = 90;

std::unordered_map<HWND, InputPopup*> g_inputs;

COLORREF Ref(winrt::Windows::UI::Color c) { return RGB(c.R, c.G, c.B); }

int InputScale(InputPopup* p, int v) {
    return ::MulDiv(v, static_cast<int>(DpiOf(p->bar)), 96);
}

std::wstring WindowText(HWND hwnd) {
    const int len = ::GetWindowTextLengthW(hwnd);
    std::wstring text(static_cast<size_t>(len), L'\0');
    if (len > 0) ::GetWindowTextW(hwnd, text.data(), len + 1);
    return text;
}

/// Sizes the popup for its current width and item count and puts the
/// controls where they go.
void InputLayout(InputPopup* p) {
    const int pad = InputScale(p, kInputPad);
    const int row = InputScale(p, kInputRowHeight);
    const int edit_h = InputScale(p, kInputEditHeight);
    const int item_h = InputScale(p, kInputItemHeight);
    const int status_w = p->status.empty() ? 0 : InputScale(p, kInputStatusWidth);
    const int shown = p->items > kInputMaxItems ? kInputMaxItems : p->items;
    const int list_h = shown * item_h;
    const int height = row + (shown > 0 ? list_h + pad : 0);

    ::SetWindowPos(p->hwnd, nullptr, 0, 0, p->width, height,
                   SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    ::MoveWindow(p->edit, pad + 4, (row - edit_h) / 2,
                 p->width - 2 * pad - 8 - status_w, edit_h, TRUE);
    ::MoveWindow(p->list, pad, row, p->width - 2 * pad, list_h, TRUE);
    ::ShowWindow(p->list, shown > 0 ? SW_SHOW : SW_HIDE);
    ::InvalidateRect(p->hwnd, nullptr, TRUE);
}

void InputHide(InputPopup* p, bool reactivate) {
    if (!p || !p->visible) return;
    p->visible = false;
    p->activated = false;
    const bool active = ::GetActiveWindow() == p->hwnd;
    ::ShowWindow(p->hwnd, SW_HIDE);
    if (reactivate && active && p->bar->parent_hwnd) {
        ::SetActiveWindow(p->bar->parent_hwnd);
    }
}

void InputCancel(InputPopup* p) {
    if (!p || !p->visible) return;
    const auto cb = p->cb;
    InputHide(p, true);
    if (cb.on_cancel) cb.on_cancel(cb.ctx);
}

void InputSubmit(InputPopup* p, bool shift) {
    if (!p || !p->visible) return;
    const auto cb = p->cb;
    const std::wstring text = WindowText(p->edit);
    int index = -1;
    if (p->items > 0) {
        index = static_cast<int>(::SendMessageW(p->list, LB_GETCURSEL, 0, 0));
    }
    if (!p->keep_open) InputHide(p, true);
    if (cb.on_submit) cb.on_submit(cb.ctx, index, text.c_str(), shift ? 1 : 0);
}

/// The EDIT control, with the keys that mean something to the popup taken
/// out before the control sees them.
LRESULT CALLBACK InputEditProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    auto it = g_inputs.find(hwnd);
    if (it == g_inputs.end()) return ::DefWindowProcW(hwnd, msg, wparam, lparam);
    InputPopup* p = it->second;

    switch (msg) {
        case WM_KEYDOWN:
            switch (wparam) {
                case VK_ESCAPE:
                    InputCancel(p);
                    return 0;
                case VK_RETURN:
                    InputSubmit(p, ::GetKeyState(VK_SHIFT) < 0);
                    return 0;
                case VK_DOWN:
                case VK_UP:
                    if (p->items > 0) {
                        int sel = static_cast<int>(
                            ::SendMessageW(p->list, LB_GETCURSEL, 0, 0));
                        sel += wparam == VK_DOWN ? 1 : -1;
                        if (sel < 0) sel = p->items - 1;
                        if (sel >= p->items) sel = 0;
                        ::SendMessageW(p->list, LB_SETCURSEL, sel, 0);
                    }
                    return 0;
            }
            break;
        // The characters those keys also produce, which an EDIT answers
        // with the system beep.
        case WM_CHAR:
            if (wparam == L'\r' || wparam == L'\n' || wparam == 27 ||
                wparam == L'\t') {
                return 0;
            }
            break;
    }
    return ::CallWindowProcW(p->edit_proc, hwnd, msg, wparam, lparam);
}

LRESULT CALLBACK InputWndProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    auto it = g_inputs.find(hwnd);
    InputPopup* p = it == g_inputs.end() ? nullptr : it->second;
    if (!p) return ::DefWindowProcW(hwnd, msg, wparam, lparam);
    GhosttyTabBar* bar = p->bar;

    switch (msg) {
        case WM_GHOSTTY_ACTIVATE_INPUT:
            if (!p->visible) return 0;
            ::SetForegroundWindow(hwnd);
            ::SetFocus(p->edit);
            return 0;

        case WM_ACTIVATE:
            if (LOWORD(wparam) != WA_INACTIVE) {
                if (p->visible) p->activated = true;
                ::SetFocus(p->edit);
                return 0;
            }
            // Clicking anywhere else dismisses it, as with the menu.
            if (p->activated && p->visible) {
                const auto cb = p->cb;
                InputHide(p, false);
                if (cb.on_cancel) cb.on_cancel(cb.ctx);
                return 0;
            }
            break;

        case WM_CTLCOLOREDIT:
        case WM_CTLCOLORLISTBOX:
        case WM_CTLCOLORSTATIC: {
            HDC dc = reinterpret_cast<HDC>(wparam);
            ::SetTextColor(dc, Ref(bar->menu_text));
            ::SetBkColor(dc, Ref(bar->menu_bg));
            return reinterpret_cast<LRESULT>(p->bg);
        }

        case WM_ERASEBKGND: {
            RECT rc;
            ::GetClientRect(hwnd, &rc);
            ::FillRect(reinterpret_cast<HDC>(wparam), &rc, p->bg);
            return 1;
        }

        case WM_PAINT: {
            PAINTSTRUCT ps;
            HDC dc = ::BeginPaint(hwnd, &ps);
            if (!p->status.empty()) {
                RECT rc;
                ::GetClientRect(hwnd, &rc);
                rc.bottom = InputScale(p, kInputRowHeight);
                rc.right -= InputScale(p, kInputPad) + 4;
                rc.left = rc.right - InputScale(p, kInputStatusWidth);
                HGDIOBJ old = ::SelectObject(dc, p->font);
                ::SetBkMode(dc, TRANSPARENT);
                // Dimmer than the text: it is a count, not content.
                const auto t = bar->menu_text;
                const auto b = bar->menu_bg;
                ::SetTextColor(dc, RGB((t.R + b.R) / 2, (t.G + b.G) / 2,
                                       (t.B + b.B) / 2));
                ::DrawTextW(dc, p->status.c_str(), -1, &rc,
                            DT_RIGHT | DT_VCENTER | DT_SINGLELINE);
                ::SelectObject(dc, old);
            }
            ::EndPaint(hwnd, &ps);
            return 0;
        }

        case WM_COMMAND:
            if (reinterpret_cast<HWND>(lparam) == p->edit &&
                HIWORD(wparam) == EN_CHANGE && !p->setting) {
                const std::wstring text = WindowText(p->edit);
                if (p->cb.on_text) p->cb.on_text(p->cb.ctx, text.c_str());
                return 0;
            }
            // Only the mouse produces this: the arrow keys move the
            // selection with LB_SETCURSEL, which does not notify.
            if (reinterpret_cast<HWND>(lparam) == p->list &&
                HIWORD(wparam) == LBN_SELCHANGE) {
                InputSubmit(p, false);
                return 0;
            }
            break;

        case WM_MEASUREITEM: {
            auto* mi = reinterpret_cast<MEASUREITEMSTRUCT*>(lparam);
            mi->itemHeight = InputScale(p, kInputItemHeight);
            return TRUE;
        }

        case WM_DRAWITEM: {
            auto* di = reinterpret_cast<DRAWITEMSTRUCT*>(lparam);
            if (di->itemID == static_cast<UINT>(-1)) return TRUE;
            const bool selected = (di->itemState & ODS_SELECTED) != 0;
            HBRUSH fill = ::CreateSolidBrush(
                Ref(selected ? bar->menu_hover : bar->menu_bg));
            ::FillRect(di->hDC, &di->rcItem, fill);
            ::DeleteObject(fill);

            wchar_t text[512];
            const LRESULT len = ::SendMessageW(
                di->hwndItem, LB_GETTEXTLEN, di->itemID, 0);
            if (len >= 0 && len < 512) {
                ::SendMessageW(di->hwndItem, LB_GETTEXT, di->itemID,
                               reinterpret_cast<LPARAM>(text));
                RECT rc = di->rcItem;
                rc.left += InputScale(p, 10);
                rc.right -= InputScale(p, 10);
                HGDIOBJ old = ::SelectObject(di->hDC, p->font);
                ::SetBkMode(di->hDC, TRANSPARENT);
                ::SetTextColor(di->hDC, Ref(bar->menu_text));
                ::DrawTextW(di->hDC, text, -1, &rc,
                            DT_LEFT | DT_VCENTER | DT_SINGLELINE |
                                DT_END_ELLIPSIS | DT_NOPREFIX);
                ::SelectObject(di->hDC, old);
            }
            return TRUE;
        }
    }
    return ::DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// Creates the popup's window and controls, once per tab bar.
InputPopup* EnsureInput(GhosttyTabBar* bar) {
    if (bar->input) return bar->input;

    static bool registered = false;
    if (!registered) {
        WNDCLASSEXW wc{};
        wc.cbSize = sizeof(wc);
        wc.style = CS_DROPSHADOW;
        wc.lpfnWndProc = InputWndProc;
        wc.hInstance = ::GetModuleHandleW(nullptr);
        wc.hCursor = ::LoadCursorW(nullptr, IDC_ARROW);
        wc.lpszClassName = kInputClassName;
        if (!::RegisterClassExW(&wc)) return nullptr;
        registered = true;
    }

    auto* p = new InputPopup{};
    p->bar = bar;
    p->hwnd = ::CreateWindowExW(
        WS_EX_TOOLWINDOW, kInputClassName, L"", WS_POPUP | WS_CLIPCHILDREN, 0,
        0, 100, 100, bar->parent_hwnd, nullptr, ::GetModuleHandleW(nullptr),
        nullptr);
    if (!p->hwnd) {
        delete p;
        return nullptr;
    }
    g_inputs[p->hwnd] = p;

    const DWORD corner = 2;  // DWMWCP_ROUND
    ::DwmSetWindowAttribute(p->hwnd, 33, &corner, sizeof(corner));

    p->edit = ::CreateWindowExW(
        0, L"EDIT", L"", WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL, 0, 0, 10, 10,
        p->hwnd, nullptr, ::GetModuleHandleW(nullptr), nullptr);
    p->list = ::CreateWindowExW(
        0, L"LISTBOX", L"",
        WS_CHILD | WS_VSCROLL | LBS_NOTIFY | LBS_OWNERDRAWFIXED |
            LBS_HASSTRINGS | LBS_NOINTEGRALHEIGHT,
        0, 0, 10, 10, p->hwnd, nullptr, ::GetModuleHandleW(nullptr), nullptr);
    if (!p->edit || !p->list) {
        g_inputs.erase(p->hwnd);
        ::DestroyWindow(p->hwnd);
        delete p;
        return nullptr;
    }
    g_inputs[p->edit] = p;
    p->edit_proc = reinterpret_cast<WNDPROC>(::SetWindowLongPtrW(
        p->edit, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(InputEditProc)));

    bar->input = p;
    return p;
}

void DestroyInput(GhosttyTabBar* bar) {
    InputPopup* p = bar ? bar->input : nullptr;
    if (!p) return;
    bar->input = nullptr;
    p->visible = false;
    g_inputs.erase(p->edit);
    g_inputs.erase(p->hwnd);
    ::DestroyWindow(p->hwnd);
    if (p->font) ::DeleteObject(p->font);
    if (p->bg) ::DeleteObject(p->bg);
    delete p;
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
        // Ghostty owns the terminal surface; the TabView draws headers
        // only, so every item's content stays empty.
        tv.CanDragTabs(false);
        tv.CanReorderTabs(true);
        bar->tab_view = tv;

        // WinUI's own add button is switched off and rebuilt below,
        // alongside the chevron. Its geometry and corner radii are baked
        // into the TabView template with no API to reach them, and a split
        // button needs both halves under the same control.
        tv.IsAddTabButtonVisible(false);

        tv.TabCloseRequested(
            [bar](MUX::Controls::TabView const&,
                  MUX::Controls::TabViewTabCloseRequestedEventArgs const& args) {
                // Deliberately does not remove the tab: Ghostty decides.
                auto id = IdOf(args.Tab().try_as<MUX::Controls::TabViewItem>());
                if (id && bar->cb.on_close_requested)
                    bar->cb.on_close_requested(bar->cb.ctx, id);
            });

        // Dragging a tab along the strip reorders the TabView's items by
        // taking the item out and putting it back, so the insertion is the
        // moment the new order exists. Without telling the host, its list
        // stays in the old order and "next tab" walks tabs in an order
        // that is no longer the one on screen.
        tv.TabItemsChanged(
            [bar](MUX::Controls::TabView const&,
                  winrt::Windows::Foundation::Collections::
                      IVectorChangedEventArgs const& args) {
                if (bar->suppress_items) return;
                if (args.CollectionChange() !=
                    winrt::Windows::Foundation::Collections::CollectionChange::
                        ItemInserted) {
                    return;
                }
                try {
                    auto item = bar->tab_view.TabItems()
                                    .GetAt(args.Index())
                                    .try_as<MUX::Controls::TabViewItem>();
                    auto id = IdOf(item);
                    if (id && bar->cb.on_tab_moved) {
                        bar->cb.on_tab_moved(bar->cb.ctx, id,
                                             static_cast<int32_t>(args.Index()));
                    }
                } catch (...) {
                }
            });

        tv.SelectionChanged([bar](auto&&, auto&&) {
            if (bar->suppress_selection) return;
            auto sel = bar->tab_view.SelectedItem()
                           .try_as<MUX::Controls::TabViewItem>();
            auto id = IdOf(sel);
            if (id && bar->cb.on_selected) bar->cb.on_selected(bar->cb.ctx, id);
        });

        // The "+" and the chevron, built as a two-segment split button:
        // equal boxes, a rule between them, and rounding only on the outer
        // corners so the pair reads as one control rather than two.
        //
        // Both are plain Buttons. A DropDownButton would supply its own
        // chevron glyph, but it reserves a content column beside it and
        // ends up drawing the glyph ~5px right of its own centre, which no
        // amount of padding straightens out.
        auto make_button = [&](wchar_t const* glyph, double glyph_size,
                               WUX::CornerRadius radius) {
            WUX::Controls::Button b;
            WUX::Controls::FontIcon icon;
            icon.Glyph(glyph);
            icon.FontFamily(WUX::Media::FontFamily(L"Segoe Fluent Icons"));
            icon.FontSize(glyph_size);
            b.Content(icon);
            b.Width(kFooterButtonWidth);
            b.Height(kFooterButtonHeight);
            // Buttons carry a MinWidth/MinHeight far larger than this;
            // without clearing them the explicit size is ignored.
            b.MinWidth(0);
            b.MinHeight(0);
            b.Padding(WUX::ThicknessHelper::FromUniformLength(0));
            b.CornerRadius(radius);
            b.BorderThickness(WUX::ThicknessHelper::FromUniformLength(0));
            // Flat, and hovering in our own colours rather than WinUI's
            // translucent overlay. From this bar's own dictionary: see
            // GhosttyTabBar::theme_dict.
            if (bar->theme_dict) {
                auto style = bar->theme_dict
                                 .TryLookup(winrt::box_value(
                                     L"GhosttyFooterButtonStyle"))
                                 .try_as<WUX::Style>();
                if (style) b.Style(style);
            }
            return b;
        };

        // FromRadii is (topLeft, topRight, bottomRight, bottomLeft): the
        // square corners are the ones meeting the divider.
        auto plus = make_button(
            kGlyphAdd, 12,
            WUX::CornerRadiusHelper::FromRadii(
                kFooterCornerRadius, 0, 0, kFooterCornerRadius));
        plus.Click([bar](auto&&, auto&&) {
            if (bar->cb.on_new_tab)
                bar->cb.on_new_tab(bar->cb.ctx, GHOSTTY_PROFILE_DEFAULT);
        });
        bar->plus = plus;

        // A size smaller than the "+": Windows Terminal draws the chevron
        // as the lesser half of the pair.
        auto chevron = make_button(
            kGlyphChevron, 10,
            WUX::CornerRadiusHelper::FromRadii(
                0, kFooterCornerRadius, kFooterCornerRadius, 0));
        // The chevron dips while it is held down, as Windows Terminal's
        // does. Hung off IsPressed rather than the Pressed visual state
        // because the two buttons share a template and only this one moves.
        try {
            WUX::Media::TranslateTransform nudge;
            chevron.Content().as<WUX::UIElement>().RenderTransform(nudge);
            chevron.RegisterPropertyChangedCallback(
                WUX::Controls::Primitives::ButtonBase::IsPressedProperty(),
                [nudge](WUX::DependencyObject const& sender,
                        WUX::DependencyProperty const&) {
                    auto button =
                        sender.try_as<WUX::Controls::Primitives::ButtonBase>();
                    nudge.Y(button && button.IsPressed() ? 2.0 : 0.0);
                });
        } catch (...) {
        }
        // No XAML Flyout is attached (see ShowProfileMenu for why); the
        // button just raises Click and we open a Win32 menu ourselves.
        chevron.Click([bar](auto&&, auto&&) { ShowProfileMenu(bar); });
        bar->chevron = chevron;

        WUX::Controls::Border divider;
        divider.Width(1);
        divider.Height(kFooterButtonHeight);
        divider.Background(WUX::Media::SolidColorBrush(
            winrt::Windows::UI::Color{40, 255, 255, 255}));
        bar->footer_divider = divider;

        WUX::Controls::StackPanel footer;
        footer.Orientation(WUX::Controls::Orientation::Horizontal);
        footer.VerticalAlignment(WUX::VerticalAlignment::Bottom);
        footer.Margin(
            WUX::ThicknessHelper::FromLengths(0, 0, 0, kFooterButtonBottomGap));
        footer.Children().Append(plus);
        footer.Children().Append(divider);
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
        // Before anything below it is laid out: the implicit TabViewItem
        // style in here is only found by items that are under it when
        // their template is applied.
        if (bar->theme_dict) root.Resources().MergedDictionaries().Append(bar->theme_dict);
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
        // The tab overview, where GTK's header bar and the macOS toolbar
        // have theirs: beside the window controls, away from the tabs. It
        // is built as a caption button because it should look and hover
        // like its neighbours; only what the click does is its own.
        {
            WUX::Controls::FontIcon icon;
            icon.Glyph(kGlyphOverview);
            icon.FontFamily(WUX::Media::FontFamily(
                L"Segoe Fluent Icons, Segoe MDL2 Assets"));
            icon.FontSize(12);
            WUX::Controls::Button overview;
            overview.Content(icon);
            overview.Width(kCaptionButtonWidth);
            overview.VerticalAlignment(WUX::VerticalAlignment::Stretch);
            overview.Padding(WUX::ThicknessHelper::FromUniformLength(0));
            overview.BorderThickness(WUX::ThicknessHelper::FromUniformLength(0));
            overview.CornerRadius(WUX::CornerRadiusHelper::FromUniformRadius(0));
            overview.Background(WUX::Media::SolidColorBrush(
                winrt::Windows::UI::Color{0, 0, 0, 0}));
            overview.Click([bar](auto&&, auto&&) {
                if (bar->cb.on_overview) bar->cb.on_overview(bar->cb.ctx);
            });
            caption.Children().Append(overview);
        }
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

        // CompositionTarget::Rendering fires once XAML has a frame to
        // present. It is the only honest answer to "has the strip painted
        // yet" -- laid out is not the same as composed, and the island
        // shows white right up until the latter.
        // Several frames, not one. The first Rendering tick fires for the
        // frame that is still blank -- reporting ready then put the window
        // on screen white anyway, just for less time.
        bar->rendering_token = WUX::Media::CompositionTarget::Rendering(
            [bar](auto&&, auto&&) {
                if (bar->rendered) return;
                if (++bar->frames < 4) return;
                bar->rendered = true;
                WUX::Media::CompositionTarget::Rendering(bar->rendering_token);
            });
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
        if (bar->menu_prewarm) bar->menu_prewarm.Stop();
    } catch (...) {
    }
    DestroyProfileMenu(bar);
    DestroyInput(bar);
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
    // Minimize, maximize, close, and the overview button beside them.
    const double reserved = kCaptionButtonWidth * 4.0;
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
    if (!bar || !msg) return 0;

    // The open profile menu gets first refusal. It is a second island in a
    // window of its own, and an island only sees keyboard input that is
    // handed to it here -- without this, Escape and arrow keys never reach
    // the menu.
    if (bar->menu && bar->menu->open && bar->menu->native) {
        BOOL handled = FALSE;
        if (SUCCEEDED(bar->menu->native->PreTranslateMessage(
                static_cast<MSG*>(msg), &handled)) &&
            handled) {
            return 1;
        }
    }

    if (!bar->native) return 0;
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
        // Right-clicking a tab is the host's to answer: what a tab can do
        // -- rename, close the others, move to a window -- is policy.
        item.RightTapped(
            [bar, id](auto&&, WUX::Input::RightTappedRoutedEventArgs const& e) {
                e.Handled(true);
                if (bar->cb.on_tab_context) bar->cb.on_tab_context(bar->cb.ctx, id);
            });

        bar->suppress_selection = true;
        bar->suppress_items = true;
        bar->tab_view.TabItems().Append(item);
        bar->suppress_items = false;
        bar->suppress_selection = false;

        bar->tabs.emplace(id, item);
        return id;
    } catch (...) {
        bar->suppress_items = false;
        bar->suppress_selection = false;
        return 0;
    }
}

GHOSTTY_TABBAR_API void ghostty_tabbar_move_tab(
    GhosttyTabBar* bar, GhosttyTabId tab, int32_t index) {
    if (!bar || !bar->tab_view || index < 0) return;
    auto it = bar->tabs.find(tab);
    if (it == bar->tabs.end()) return;
    try {
        auto items = bar->tab_view.TabItems();
        uint32_t from = 0;
        if (!items.IndexOf(it->second, from)) return;
        const uint32_t to = static_cast<uint32_t>(index);
        if (to >= items.Size() || to == from) return;

        // Taking the selected tab out moves the selection to a neighbour,
        // so it is put back afterwards.
        auto selected = bar->tab_view.SelectedItem();
        bar->suppress_selection = true;
        bar->suppress_items = true;
        items.RemoveAt(from);
        items.InsertAt(to, it->second);
        bar->tab_view.SelectedItem(selected);
        bar->suppress_items = false;
        bar->suppress_selection = false;
    } catch (...) {
        bar->suppress_items = false;
        bar->suppress_selection = false;
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
            bar->suppress_items = true;
            bar->tab_view.TabItems().RemoveAt(index);
            bar->suppress_items = false;
            bar->suppress_selection = false;
        }
    } catch (...) {
        bar->suppress_items = false;
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
        // Ghostty calls this on every frame it draws. A new Header, even
        // an equal one, makes the item rebuild its header content and the
        // island lay out and render again, so an unchanged title is left
        // alone.
        hstring next{title ? title : L""};
        auto current = it->second.Header().try_as<winrt::Windows::Foundation::IPropertyValue>();
        if (current && current.Type() == winrt::Windows::Foundation::PropertyType::String &&
            current.GetString() == next) {
            return;
        }
        it->second.Header(winrt::box_value(next));
    } catch (...) {
    }
}

GHOSTTY_TABBAR_API void ghostty_tabbar_set_tab_icon(
    GhosttyTabBar* bar, GhosttyTabId tab, const wchar_t* icon_path) {
    if (!bar) return;
    auto it = bar->tabs.find(tab);
    if (it == bar->tabs.end()) return;
    try {
        if (!icon_path || !*icon_path) {
            it->second.IconSource(nullptr);
            return;
        }
        auto bmp = CachedShellIcon(icon_path);
        if (!bmp) return;
        // ImageIconSource rather than BitmapIconSource: the latter takes a
        // URI and would mean writing the icon out to a file first, and it
        // recolours what it draws to match the foreground, which would
        // flatten a shell's logo into a monochrome silhouette.
        MUX::Controls::ImageIconSource source;
        source.ImageSource(bmp);
        it->second.IconSource(source);
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
    GhosttyTabBar* bar, GhosttyProfileId profile, const wchar_t* name,
    const wchar_t* icon_path) {
    if (!bar) return;
    g_profiles[bar].push_back(Profile{profile, name ? name : L"",
                                      icon_path ? icon_path : L""});
    bar->menu_dirty = true;
}

GHOSTTY_TABBAR_API int32_t ghostty_tabbar_rendered(GhosttyTabBar* bar) {
    return (bar && bar->rendered) ? 1 : 0;
}

GHOSTTY_TABBAR_API void ghostty_tabbar_clear_profiles(GhosttyTabBar* bar) {
    if (!bar) return;
    g_profiles[bar].clear();
    bar->menu_dirty = true;
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

        // The shell picker is a Win32 menu, which has no idea the XAML
        // above it just changed theme.
        SetMenuTheme(dark != 0);

        // Windows Terminal's colour model, which is the opposite of the
        // obvious one: the *selected* tab takes the terminal's exact
        // background so it reads as continuous with the content below it,
        // and the strip around it is darker (lighter, on a light theme).
        //
        // Painting the strip with the terminal colour instead leaves WinUI
        // to derive the selected tab from it, and its default overlay
        // darkens -- which inverts the whole thing and is what this used
        // to look like.
        //
        // An unselected tab sits just off the strip rather than exactly on
        // it, which is what gives the tabs an edge when none is selected.
        // Windows Terminal's own numbers are 24,24,37 for the strip against
        // 26,26,39 for an unselected tab; this reproduces that ~2-unit lift
        // rather than the colour, since the colour follows the theme.
        const double strip_factor = dark ? 0.62 : 1.12;
        const double unselected_factor = dark ? 0.66 : 1.09;
        const double hover_factor = dark ? 0.80 : 1.06;
        const auto content = Rgb(r, g, b);
        const auto strip = Rgb(Scale(r, strip_factor), Scale(g, strip_factor),
                               Scale(b, strip_factor));
        const auto unselected =
            Rgb(Scale(r, unselected_factor), Scale(g, unselected_factor),
                Scale(b, unselected_factor));
        const auto hover = Rgb(Scale(r, hover_factor), Scale(g, hover_factor),
                               Scale(b, hover_factor));

        bar->root.Background(WUX::Media::SolidColorBrush(strip));

        // Recolour in place: the brushes are already bound into applied
        // templates, so replacing the objects would change nothing.
        if (bar->b_selected) bar->b_selected.Color(content);
        if (bar->b_unselected) bar->b_unselected.Color(unselected);
        if (bar->b_hover) bar->b_hover.Color(hover);
        // Pressed is a fixed step past hovered rather than another factor
        // of the background: Windows Terminal's hover and pressed fills
        // are 12 apart per channel whatever the theme, and a factor would
        // make the step vanish on a near-black background.
        const int press_step = dark ? 12 : -12;
        auto step = [press_step](uint8_t c) {
            const int v = static_cast<int>(c) + press_step;
            return static_cast<uint8_t>(v < 0 ? 0 : (v > 255 ? 255 : v));
        };
        if (bar->b_pressed) {
            bar->b_pressed.Color(Rgb(step(hover.R), step(hover.G), step(hover.B)));
        }
        // A Windows 11 menu sits slightly above its window's background
        // rather than matching it, with a hairline border a step lighter
        // again.
        const double border_f = dark ? 1.6 : 0.85;
        const double hover_f = dark ? 1.35 : 0.94;
        bar->menu_bg = hover;
        bar->menu_border = Rgb(Scale(hover.R, border_f), Scale(hover.G, border_f),
                               Scale(hover.B, border_f));
        bar->menu_hover = Rgb(Scale(hover.R, hover_f), Scale(hover.G, hover_f),
                              Scale(hover.B, hover_f));
        bar->menu_text = dark ? winrt::Windows::UI::Color{255, 255, 255, 255}
                              : winrt::Windows::UI::Color{255, 0, 0, 0};

        // The menu is drawn in these colours, so one built before now is
        // stale. This is also the last thing the host does when it sets a
        // window up, which makes it the moment to start warming the menu.
        bar->menu_dirty = true;
        ScheduleMenuPrewarm(bar);

        Log("set_theme: content=%02X%02X%02X strip=%02X%02X%02X",
            content.R, content.G, content.B, strip.R, strip.G, strip.B);
    } catch (hresult_error const& e) {
        Log("set_theme: FAILED 0x%08X: %ls", (unsigned)e.code(), e.message().c_str());
    } catch (...) {
        Log("set_theme: FAILED (unknown)");
    }
}

GHOSTTY_TABBAR_API void ghostty_tabbar_input_show(
    GhosttyTabBar* bar, int32_t x, int32_t y, int32_t width,
    const wchar_t* placeholder, const wchar_t* text, int32_t keep_open,
    GhosttyInputCallbacks callbacks) {
    if (!bar) return;
    InputPopup* p = EnsureInput(bar);
    if (!p) return;

    // Rebuilt on every show: the theme and the DPI can both have changed
    // since the last one, and neither is worth tracking for two objects.
    const int dpi = static_cast<int>(DpiOf(bar));
    if (p->font) ::DeleteObject(p->font);
    p->font = ::CreateFontW(-::MulDiv(14, dpi, 96), 0, 0, 0, FW_NORMAL, 0, 0, 0,
                            DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0,
                            L"Segoe UI");
    if (p->bg) ::DeleteObject(p->bg);
    p->bg = ::CreateSolidBrush(Ref(bar->menu_bg));
    ::SendMessageW(p->edit, WM_SETFONT, reinterpret_cast<WPARAM>(p->font), TRUE);
    ::SendMessageW(p->list, WM_SETFONT, reinterpret_cast<WPARAM>(p->font), TRUE);

    const COLORREF border = Ref(bar->menu_border);
    ::DwmSetWindowAttribute(p->hwnd, 34 /* DWMWA_BORDER_COLOR */, &border,
                            sizeof(border));
    // The list's scrollbar is the one part the colours above do not reach.
    const bool dark = bar->menu_text.R > 128;
    ::SetWindowTheme(p->list, dark ? L"DarkMode_Explorer" : L"Explorer", nullptr);

    p->cb = callbacks;
    p->keep_open = keep_open != 0;
    p->status.clear();
    p->items = 0;
    ::SendMessageW(p->list, LB_RESETCONTENT, 0, 0);

    p->setting = true;
    ::SetWindowTextW(p->edit, text ? text : L"");
    ::SendMessageW(p->edit, EM_SETSEL, 0, -1);
    ::SendMessageW(p->edit, 0x1501 /* EM_SETCUEBANNER */, TRUE,
                   reinterpret_cast<LPARAM>(placeholder ? placeholder : L""));
    p->setting = false;

    p->width = width;
    p->visible = true;
    p->activated = false;
    InputLayout(p);
    ::SetWindowPos(p->hwnd, HWND_TOP, x, y, 0, 0,
                   SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    // Deferred for the same reason as the profile menu: whatever input
    // opened this is still being processed, and would take focus back.
    ::PostMessageW(p->hwnd, WM_GHOSTTY_ACTIVATE_INPUT, 0, 0);
}

GHOSTTY_TABBAR_API void ghostty_tabbar_input_set_items(
    GhosttyTabBar* bar, const wchar_t* const* items, int32_t count) {
    InputPopup* p = bar ? bar->input : nullptr;
    if (!p || !p->visible) return;
    ::SendMessageW(p->list, WM_SETREDRAW, FALSE, 0);
    ::SendMessageW(p->list, LB_RESETCONTENT, 0, 0);
    int added = 0;
    for (int32_t i = 0; items && i < count; ++i) {
        if (!items[i]) continue;
        ::SendMessageW(p->list, LB_ADDSTRING, 0,
                       reinterpret_cast<LPARAM>(items[i]));
        ++added;
    }
    p->items = added;
    if (added > 0) ::SendMessageW(p->list, LB_SETCURSEL, 0, 0);
    ::SendMessageW(p->list, WM_SETREDRAW, TRUE, 0);
    InputLayout(p);
}

GHOSTTY_TABBAR_API void ghostty_tabbar_input_set_status(
    GhosttyTabBar* bar, const wchar_t* text) {
    InputPopup* p = bar ? bar->input : nullptr;
    if (!p || !p->visible) return;
    const bool had = !p->status.empty();
    p->status = text ? text : L"";
    // The edit gives up room for the status only while there is one.
    if (had != !p->status.empty()) {
        InputLayout(p);
    } else {
        ::InvalidateRect(p->hwnd, nullptr, TRUE);
    }
}

GHOSTTY_TABBAR_API void ghostty_tabbar_input_hide(GhosttyTabBar* bar) {
    if (bar && bar->input) InputHide(bar->input, true);
}

GHOSTTY_TABBAR_API int32_t ghostty_tabbar_input_visible(GhosttyTabBar* bar) {
    return (bar && bar->input && bar->input->visible) ? 1 : 0;
}

GHOSTTY_TABBAR_API uint32_t ghostty_tabbar_popup_menu(
    GhosttyTabBar* bar, int32_t x, int32_t y, const wchar_t* const* labels,
    const uint32_t* ids, int32_t count) {
    if (!bar || !bar->parent_hwnd || !labels || !ids || count <= 0) return 0;
    HMENU menu = ::CreatePopupMenu();
    if (!menu) return 0;
    for (int32_t i = 0; i < count; ++i) {
        if (labels[i]) {
            ::AppendMenuW(menu, MF_STRING, ids[i], labels[i]);
        } else {
            ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
        }
    }

    POINT pt{x, y};
    if (x < 0 && y < 0) ::GetCursorPos(&pt);
    // Without this the menu does not close when the user clicks away from
    // it; the WM_NULL afterwards is the other half of the same old rule.
    ::SetForegroundWindow(bar->parent_hwnd);
    const UINT picked = static_cast<UINT>(::TrackPopupMenu(
        menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY, pt.x, pt.y, 0,
        bar->parent_hwnd, nullptr));
    ::PostMessageW(bar->parent_hwnd, WM_NULL, 0, 0);
    ::DestroyMenu(menu);
    return picked;
}

GHOSTTY_TABBAR_API void ghostty_tabbar_notify(
    const wchar_t* title, const wchar_t* body) {
    // A packaged process has an identity for the notification platform to
    // file the toast under, so there is no AppUserModelID to pass.
    try {
        using namespace winrt::Windows::UI::Notifications;
        auto xml = ToastNotificationManager::GetTemplateContent(
            ToastTemplateType::ToastText02);
        auto nodes = xml.GetElementsByTagName(L"text");
        nodes.Item(0).AppendChild(
            xml.CreateTextNode(title && *title ? title : L"Ghostty"));
        nodes.Item(1).AppendChild(xml.CreateTextNode(body ? body : L""));
        // Without a package (the setup.exe install) there is no identity to
        // file the toast under, and the parameterless notifier throws. The
        // ID is the one Ghostty claims at startup and the installer's Start
        // menu shortcut carries, which is what Windows checks it against.
        UINT32 name_len = 0;
        const bool packaged =
            ::GetCurrentPackageFullName(&name_len, nullptr) != APPMODEL_ERROR_NO_PACKAGE;
        auto notifier = packaged
            ? ToastNotificationManager::CreateToastNotifier()
            : ToastNotificationManager::CreateToastNotifier(L"Ghostty.Terminal");
        notifier.Show(ToastNotification(xml));
    } catch (hresult_error const& e) {
        Log("notify: FAILED 0x%08X: %ls", (unsigned)e.code(),
            e.message().c_str());
    } catch (...) {
        Log("notify: FAILED (unknown)");
    }
}

GHOSTTY_TABBAR_API void ghostty_tabbar_set_progress(
    void* hwnd, int32_t state, int32_t percent) {
    if (!hwnd) return;
    static com_ptr<ITaskbarList3> taskbar;
    if (!taskbar) {
        if (FAILED(::CoCreateInstance(CLSID_TaskbarList, nullptr,
                                      CLSCTX_INPROC_SERVER,
                                      IID_PPV_ARGS(taskbar.put()))) ||
            FAILED(taskbar->HrInit())) {
            taskbar = nullptr;
            return;
        }
    }
    TBPFLAG flag = TBPF_NOPROGRESS;
    switch (state) {
        case GHOSTTY_PROGRESS_NORMAL: flag = TBPF_NORMAL; break;
        case GHOSTTY_PROGRESS_ERROR: flag = TBPF_ERROR; break;
        case GHOSTTY_PROGRESS_INDETERMINATE: flag = TBPF_INDETERMINATE; break;
        case GHOSTTY_PROGRESS_PAUSED: flag = TBPF_PAUSED; break;
        default: break;
    }
    const HWND target = static_cast<HWND>(hwnd);
    taskbar->SetProgressState(target, flag);
    if (flag == TBPF_NORMAL || flag == TBPF_ERROR || flag == TBPF_PAUSED) {
        const int value = percent < 0 ? 0 : (percent > 100 ? 100 : percent);
        taskbar->SetProgressValue(target, static_cast<ULONGLONG>(value), 100);
    }
}

} // extern "C"

BOOL APIENTRY DllMain(HMODULE, DWORD, LPVOID) { return TRUE; }
