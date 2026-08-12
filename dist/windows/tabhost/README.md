# tabhost — abandoned C#/WinUI 3 tab host

**This is not part of the build.** It is the first attempt at the native
tab strip, kept because of what it cost to learn and because it is the
evidence behind a claim made in `../tabbar/README.md`.

The shipping implementation is `../tabbar/ghostty-tabbar/` — C++/WinRT,
WinUI 2, MSIX-packaged.

## What it was

A WinForms host that creates a `DesktopWindowXamlSource` (XAML Islands)
and puts a WinUI 3 `TabView` in it, with the Windows App SDK started
unpackaged via `Bootstrap.TryInitialize`. The idea was to write the strip
in C# — far pleasanter than C++/WinRT — and talk to Zig across a thin
interop layer.

## Why it was abandoned

Not because the approach is wrong. It was abandoned because of a bug that
looked like a platform limitation and wasn't:

**`RPC_E_WRONG_THREAD`.** Initializing the XAML machinery in the wrong
order throws this, and the error says nothing about ordering. The correct
sequence is: base `Application` constructor, then
`WindowsXamlManager::InitializeForCurrentThread()`, and only then may
`Resources()` be touched. At the time this read as "WinUI 3 cannot be
hosted this way", which is what pushed the work to C++/WinRT.

`MinimalApp.cs` carries the other half of the discovery, in its own doc
comment: islands-only hosting still needs *some* `Application` instance to
exist, or `XamlControlsResources` fails to construct with `Cannot find a
resource with the given key: AcrylicBackgroundFillColorDefaultBrush`.

Both findings transferred directly to the C++ implementation, where they
are what `XamlApp`'s constructor is shaped around.

## Why the shipping version is WinUI 2, not WinUI 3

Once the ordering bug was understood, WinUI 3 was reachable — `../tabbar/poc3/`
proves it runs unpackaged. WinUI 2 won on packaging: it needs MSIX
identity anyway, and an MSIX installer that pulls its own framework
dependencies means the user installs one thing and nothing else. The
`SelfContained=true` in the `.csproj` here is the alternative, and its
cost is visible in `.gitignore`.

## Building it

Requires the .NET 6 SDK and VS Build Tools 2022:

```powershell
dotnet build GhosttyTabHost\GhosttyTabHost.csproj
```

The `AppxMSBuildToolsPath` in the `.csproj` is hardcoded to a Build Tools
install path: `dotnet build` does not discover the UWP/Appx MSBuild tasks
on its own the way a VS-hosted build does. Adjust it if your install
differs.

Every code path logs to `%TEMP%\tabhost_debug.log`.
