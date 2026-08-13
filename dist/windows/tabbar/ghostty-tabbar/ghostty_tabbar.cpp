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
    // brush and came out lighter. Here "lit" is the same brush as
    // "hovered", so the two halves cannot disagree.
    static constexpr wchar_t kXamlFooter[] =
        LR"XAML(   <Style x:Key="GhosttyFooterButtonStyle" TargetType="Button">
                <Setter Property="Background" Value="Transparent"/>
                <Setter Property="Foreground" Value="{ThemeResource TabViewItemHeaderForeground}"/>
                <Setter Property="Template">
                  <Setter.Value>
                    <ControlTemplate TargetType="Button">
                      <Border x:Name="Root" Background="{TemplateBinding Background}" CornerRadius="{TemplateBinding CornerRadius}">
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
                        <ContentPresenter x:Name="ContentPresenter" HorizontalAlignment="Center" VerticalAlignment="Center" Content="{TemplateBinding Content}" Foreground="{TemplateBinding Foreground}"/>
                      </Border>
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
    app.Resources().MergedDictionaries().Append(dict);

    auto grab = [&](wchar_t const* key) {
        return dict.TryLookup(winrt::box_value(key))
            .try_as<WUX::Media::SolidColorBrush>();
    };
    bar->b_selected = grab(L"GhosttyTabSelected");
    bar->b_unselected = grab(L"GhosttyTabUnselected");
    bar->b_hover = grab(L"GhosttyTabHover");

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
std::unordered_map<GhosttyTabBar*, std::vector<std::pair<GhosttyProfileId, std::wstring>>>
    g_profiles;

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

    // Light both halves for as long as the menu is up. Picking a profile
    // opens a new tab, so the "+" is as much a part of this action as the
    // chevron; leaving it dark makes the menu look unrelated to it.
    //
    // IsHitTestVisible goes off alongside the colour so the click that
    // dismisses the menu cannot re-enter Click and reopen what it just
    // closed. The colours match because the footer button template paints
    // PointerOver with the same brush used here -- switching hit testing
    // off does not leave PointerOver, it just freezes it, so relying on
    // that alone was not enough.
    //
    // TrackPopupMenu below is modal and returns before this scope ends, so
    // both are guaranteed to be restored.
    //
    // Restores the transparent background explicitly rather than calling
    // ClearValue: clearing the local value hands the button back to the
    // default style, which paints the filled box this deliberately avoids.
    struct Lit {
        GhosttyTabBar* bar;
        ~Lit() {
            WUX::Media::SolidColorBrush clear{
                winrt::Windows::UI::Color{0, 0, 0, 0}};
            if (bar->plus) {
                bar->plus.Background(clear);
                bar->plus.IsHitTestVisible(true);
            }
            if (bar->chevron) {
                bar->chevron.Background(clear);
                bar->chevron.IsHitTestVisible(true);
            }
        }
    } lit{bar};
    if (bar->b_hover) {
        if (bar->plus) {
            bar->plus.Background(bar->b_hover);
            bar->plus.IsHitTestVisible(false);
        }
        if (bar->chevron) {
            bar->chevron.Background(bar->b_hover);
            bar->chevron.IsHitTestVisible(false);
        }
    }

    // Menu command ids are 1-based indices into `profiles`; 0 means the
    // user dismissed the menu.
    for (size_t i = 0; i < profiles.size(); ++i) {
        ::AppendMenuW(menu, MF_STRING, static_cast<UINT_PTR>(i + 1),
                      profiles[i].second.c_str());
    }

    // Drop the menu below the split button, left-aligned with the "+"
    // rather than with the chevron -- the menu belongs to the whole
    // control, which is where Windows Terminal hangs it from too.
    POINT pt{0, 0};
    auto anchor = bar->plus ? bar->plus : bar->chevron;
    if (anchor && bar->island_hwnd) {
        try {
            auto transform = anchor.TransformToVisual(nullptr);
            auto origin = transform.TransformPoint(
                winrt::Windows::Foundation::Point{0.0f,
                    static_cast<float>(anchor.ActualHeight())});
            pt.x = static_cast<LONG>(origin.X);
            pt.y = static_cast<LONG>(origin.Y);
        } catch (...) {
        }
        ::ClientToScreen(bar->island_hwnd, &pt);
    } else {
        ::GetCursorPos(&pt);
    }

    // The SetForegroundWindow / WM_NULL pair is the documented idiom for
    // TrackPopupMenu and is not optional. Without the first call a menu
    // whose owner is not foreground does not take the click that dismisses
    // it -- the click falls through to the window underneath, which is why
    // dismissing this menu by clicking the terminal started a text
    // selection there. The trailing WM_NULL is the matching half: it
    // unsticks the menu so the *next* click is delivered normally.
    ::SetForegroundWindow(bar->parent_hwnd);

    // TPM_RETURNCMD makes this synchronous: it returns the chosen id
    // instead of posting WM_COMMAND, so no message routing is needed.
    const int chosen = ::TrackPopupMenu(
        menu, TPM_RETURNCMD | TPM_LEFTALIGN | TPM_TOPALIGN | TPM_RIGHTBUTTON,
        pt.x, pt.y, 0, bar->parent_hwnd, nullptr);
    ::DestroyMenu(menu);
    ::PostMessageW(bar->parent_hwnd, WM_NULL, 0, 0);

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
        auto make_button = [&](wchar_t const* glyph, WUX::CornerRadius radius) {
            WUX::Controls::Button b;
            WUX::Controls::FontIcon icon;
            icon.Glyph(glyph);
            icon.FontFamily(WUX::Media::FontFamily(L"Segoe Fluent Icons"));
            icon.FontSize(12);
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
            // translucent overlay. Looked up rather than assigned from a
            // handle because the dictionary is merged at Application level.
            if (auto app = WUX::Application::Current()) {
                auto style = app.Resources()
                                 .Lookup(winrt::box_value(
                                     L"GhosttyFooterButtonStyle"))
                                 .try_as<WUX::Style>();
                if (style) b.Style(style);
            }
            return b;
        };

        // FromRadii is (topLeft, topRight, bottomRight, bottomLeft): the
        // square corners are the ones meeting the divider.
        auto plus = make_button(
            kGlyphAdd, WUX::CornerRadiusHelper::FromRadii(
                           kFooterCornerRadius, 0, 0, kFooterCornerRadius));
        plus.Click([bar](auto&&, auto&&) {
            if (bar->cb.on_new_tab)
                bar->cb.on_new_tab(bar->cb.ctx, GHOSTTY_PROFILE_DEFAULT);
        });
        bar->plus = plus;

        auto chevron = make_button(
            kGlyphChevron, WUX::CornerRadiusHelper::FromRadii(
                               0, kFooterCornerRadius, kFooterCornerRadius, 0));
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
