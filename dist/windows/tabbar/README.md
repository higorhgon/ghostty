# Native Windows tab bar for Ghostty

A real WinUI `TabView` — the same control Windows Terminal, Notepad and
File Explorer use — hosted inside Ghostty's plain Win32 window via XAML
Islands, exposed to Zig through a flat C ABI.

## Why this exists

Win32 has no native tab control with the Windows 11 look. `SysTabControl32`
is XP-era. Every app with Fluent tabs gets them from WinUI's `TabView`, so
matching that appearance means actually using that control, not imitating
it.

## Layout

| Path | What it is |
|---|---|
| `ghostty-tabbar/` | **The real deliverable.** `ghostty_tabbar.dll` + its C ABI, plus a plain-C test host. |
| `poc1/` | Proves XAML Islands host system XAML in a Win32 HWND. No NuGet, no packaging. |
| `poc2/` | Proves WinUI 2's `TabView` renders when MSIX-packaged. |
| `poc3/` | Same for WinUI 3, unpackaged. Kept for comparison. |
| `../tabhost/` | The abandoned C#/WinUI 3 attempt this replaced. Not built. |
| `fetch-deps.ps1` | Downloads NuGet packages and generates the C++/WinRT projections. |

## Building

```powershell
.\fetch-deps.ps1              # once, ~600 MB, not committed
.\ghostty-tabbar\build.bat    # builds the DLL and the C test host
```

WinUI 2 only activates for a process with package identity, so the test
host must be registered before it will run:

```powershell
Add-AppxPackage -Register .\ghostty-tabbar\AppxManifest.xml   # needs Developer Mode
Start-Process "shell:AppsFolder\Ghostty.TabBarTestHost_qdspqvpm741bc!App"
```

Logs land in `%TEMP%\ghostty_tabbar.log` and
`%TEMP%\ghostty_tabbar_testhost.log` — a packaged app cannot write to its
own install directory.

## Design

The DLL is deliberately dumb: it draws tabs and reports what was clicked.
Ghostty keeps all policy — which shells exist, what a tab maps to, whether
one may close. Closing is a *request*: the DLL never removes a tab on its
own, it calls `on_close_requested` and waits for Ghostty to decide.

## Hard-won details

Each of these cost real debugging time; they are not obvious and the error
messages mostly do not point at them.

**Initialization order inside the `Application` subclass.** The base
`Application` constructor must run, then
`WindowsXamlManager::InitializeForCurrentThread()`, and only then may
`Resources()` be touched. Any other order throws `RPC_E_WRONG_THREAD`.
This one bug is what made an earlier C#/WinUI 3 attempt look impossible;
that attempt is kept in `../tabhost/` with the details.

**`Application::Current()` throws** — it does not return null — before any
XAML exists in the process. It must be wrapped in try/catch.

**The host `.exe` needs its own embedded manifest** declaring
`<maxversiontested>`, *even when* MSIX-packaged with `MaxVersionTested`
already in the package manifest. Without it XAML Islands fails with a bare
`E_UNEXPECTED` and no explanation.

**`XamlControlsResources` is XAML markup**, so parsing it needs type
metadata. The `Application` must therefore also implement
`IXamlMetadataProvider`, delegating to WinUI's
`XamlControlsXamlMetaDataProvider`.

**The root element needs an explicit theme and background.** Without one,
unselected tabs render white-on-white — which looks exactly like the tabs
failing to be added, and sends you debugging the wrong thing entirely.

**XAML Island popups are clipped to the island's HWND.** The island here is
only as tall as the tab strip, so a XAML `MenuFlyout` for the shell picker
opens completely invisible. The picker therefore gets a *second* island, in
a top-level window of its own, which escapes those bounds.

Three things that costs, none of them obvious and none of them
reported as an error:

- `AttachToWindow` leaves the new island hidden. It comes back as a bare
  `WS_CHILD` with no `WS_VISIBLE`, so the window renders as an empty frame
  with whatever is behind it showing through. `SWP_SHOWWINDOW` fixes it.
- A `Brush` belongs to the tree it was first used in. Handing the strip's
  brushes to the menu leaves the menu unpainted; every brush it draws with
  has to be created in its own tree.
- Each island only sees the keyboard input handed to it, so the menu's
  island needs its own turn in `ghostty_tabbar_pretranslate`.

**Never take focus from a draw path.** `reflow` both lays out and draws, so
it runs every frame, and it used to call `SetFocus` on the terminal
unconditionally. That yanked focus back ~60 times a second, which nothing
noticed until the profile menu — a window of ours on the same thread —
was deactivated the instant it appeared. It now only reclaims focus when
its own window is already the active one.

Making the tab strip's island cover the whole window instead, and
rendering the terminal into a `SwapChainPanel`, would sidestep the
clipping entirely. That is the full Windows Terminal architecture, and it
needs Ghostty's renderer ported from OpenGL to Direct3D.

**Overriding `TabViewItemHeaderBackground*` does nothing.** The documented
way to recolour tabs was measured as having no effect through four scopes:
the `TabView`'s dictionary, the `Application`'s, each item's own, and
merged `ThemeDictionaries`. The tab colours come from a full
`TabViewItem` `ControlTemplate` override instead, which is why one is
carried here. In WinUI's stock template the *selected* tab is painted by a
separate shape (`SelectedBackgroundPath`) with `TabContainer` drawn over
it — so the selected tab picked up a translucent overlay and rendered
lighter than both the strip and the terminal content.

Note those keys are never *defined* in WinUI's `Generic.xaml`, only
referenced; their values live in compiled theme resources. `Generic.xaml`
is still the place to read the templates themselves, at
`packages/Microsoft.UI.Xaml.2.8.6/lib/uap10.0/Microsoft.UI.Xaml/Themes/`.

**`XamlReader::Load` is not the XAML compiler.** Three things a copied
template will contain that it rejects:

- `x:Load` — unsupported; use `Visibility="Collapsed"`.
- Any `{StaticResource}` whose key is not inside the markup being parsed,
  which fails at *load* time. WinUI's `TopCornerRadiusFilterConverter` and
  `TabViewCloseButtonStyle` are both in this category — the close button
  style has to be copied in wholesale.
- `{ThemeResource}` keys resolve late, so those are fine, but a missing
  one throws when the template is *applied*, not when it is parsed.

**MSVC caps a string literal at 16380 bytes.** A real control template is
larger than that, so it has to be split into several literals and joined at
runtime; concatenating adjacent literals does not raise the cap.

**A XAML exception during layout kills the process silently.** It surfaces
on the dispatcher, not in whatever call triggered it, so a `try/catch`
around `TabItems().Append()` never sees it. Subscribing to
`Application::UnhandledException` is the only way to read it — it is what
turned a bare process exit into `0x802B000A: Cannot find a Resource with
the Name/Key TabViewCloseButtonStyle [Line: 181 Position: 140]`.

**Hover states cannot be provoked with `SetCursorPos`.** XAML pointer
state follows synthesized *relative* mouse input (`mouse_event` with
`MOUSEEVENTF_MOVE`); warping the cursor leaves the control in `Normal` and
makes a perfectly good `PointerOver` state look broken.

## Routes considered

Both were built and compared side by side before choosing.

WinUI 3 works **unpackaged** (see `poc3/`), which would keep Ghostty a
plain `.exe`, but requires the Windows App Runtime installed on the user's
machine.

WinUI 2 requires MSIX packaging, because its theme resources are addressed
as `ms-appx://Microsoft.UI.Xaml.2.8/...` and that URI only resolves with
real package identity. In exchange the installer carries every dependency
and the user installs nothing extra. That is the route taken.
