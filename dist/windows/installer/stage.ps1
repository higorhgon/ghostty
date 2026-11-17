# Stages the files the setup.exe installs: Ghostty unpackaged, with no MSIX.
#
# The WinUI 2 tab strip normally needs package identity, for two reasons,
# and both are met here the way Windows Terminal's portable build meets
# them (build/scripts/New-UnpackagedTerminalDistribution.ps1 there):
#
#  - Its classes live in Microsoft.UI.Xaml.dll, a framework package nobody
#    registers for an unpackaged process. C++/WinRT, which the tab bar DLL
#    is written in, falls back to loading that DLL from beside the exe and
#    asking it for the factory, so the DLL only has to be there.
#  - Its themes are ms-appx:///Microsoft.UI.Xaml.2.8/... URIs, which an
#    unpackaged process resolves through the resources.pri next to its exe.
#    The WinUI package's own resources.pri is that file; Ghostty has no
#    resources of its own outside the package.
#
# ghostty.exe's manifest declares maxversiontested, without which XAML
# Islands do not start at all in a process with no package.

param(
    # Where the layout goes. Its contents are replaced.
    [string]$Out = (Join-Path $PSScriptRoot "layout")
)

$ErrorActionPreference = "Stop"
$root = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$zigOut = Join-Path $root "zig-out"
$exe = Join-Path $zigOut "bin\ghostty.exe"
$tabbar = Join-Path $root "dist\windows\tabbar\ghostty-tabbar\ghostty_tabbar.dll"
$conpty = Join-Path $root "dist\windows\conpty\bin"
$xamlAppx = Join-Path $root "dist\windows\tabbar\packages\Microsoft.UI.Xaml.2.8.6\tools\AppX\x64\Release\Microsoft.UI.Xaml.2.8.appx"

if (-not (Test-Path $exe)) {
    throw "zig-out\bin\ghostty.exe not found -- run: zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-msvc -Doptimize=ReleaseFast"
}
# The same guard as the MSIX stage: a debug build is not something to ship.
if ([Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($exe)).Contains("This is a debug build. Performance will be very poor.")) {
    throw "zig-out\bin\ghostty.exe is a debug build -- rebuild with -Doptimize=ReleaseFast"
}
if (-not (Test-Path $tabbar)) { throw "ghostty_tabbar.dll not found -- run dist\windows\tabbar\ghostty-tabbar\build.bat" }
if (-not (Test-Path $xamlAppx)) { throw "WinUI 2 package not found -- run dist\windows\tabbar\fetch-deps.ps1" }

Write-Host "Staging installer layout..."
if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
$bin = New-Item -ItemType Directory -Force (Join-Path $Out "bin")

# Only what the exe loads: no .pdb (about 100 MB), and no ghostty-vt.dll,
# which is libghostty-vt for embedders, not something ghostty.exe uses.
Copy-Item $exe, $tabbar $bin
Copy-Item (Join-Path $zigOut "share") $Out -Recurse -ErrorAction SilentlyContinue

if (Test-Path (Join-Path $conpty "conpty.dll")) {
    Copy-Item (Join-Path $conpty "*") $bin
} else {
    Write-Warning "No bundled ConPTY; run dist\windows\conpty\fetch-conpty.ps1 to use OpenConsole.exe instead of the system conhost.exe."
}

# WinUI 2: the DLL, its resource folder and its resource index. The .winmd
# and the package's own manifest and signature are not wanted.
$xaml = Join-Path ([IO.Path]::GetTempPath()) "ghostty-winui2-$PID"
New-Item -ItemType Directory -Force $xaml | Out-Null
try {
    tar -x -f $xamlAppx -C $xaml
    if ($LASTEXITCODE -ne 0) { throw "could not unpack $xamlAppx" }
    Copy-Item (Join-Path $xaml "Microsoft.UI.Xaml.dll"), (Join-Path $xaml "resources.pri") $bin
    Copy-Item (Join-Path $xaml "Microsoft.UI.Xaml") $bin -Recurse
} finally {
    Remove-Item -Recurse -Force $xaml -ErrorAction SilentlyContinue
}

$size = (Get-ChildItem $Out -Recurse -File | Measure-Object Length -Sum).Sum
Write-Host ("Layout at {0} ({1:N0} MB)" -f $Out, ($size / 1MB))
