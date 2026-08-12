# Stages an MSIX layout for the Windows build and registers it locally.
#
# Packaging is required, not cosmetic: the native tab strip is a WinUI 2
# TabView, and WinUI 2 refuses to activate without package identity. An
# unpackaged ghostty.exe still runs, but silently falls back to the
# hand-drawn GDI strip.
#
# Local registration uses loose files (Add-AppxPackage -Register), which
# needs Developer Mode. Shipping to users instead requires signing the
# package with a code-signing certificate.

param(
    # Skips registration; just builds the layout.
    [switch]$NoRegister
)

$ErrorActionPreference = "Stop"
# dist\windows\msix -> dist\windows -> dist -> repo root
$root = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$layout = Join-Path $PSScriptRoot "layout"
$zigOut = Join-Path $root "zig-out"
$dll = Join-Path $root "dist\windows\tabbar\ghostty-tabbar\ghostty_tabbar.dll"

if (-not (Test-Path (Join-Path $zigOut "bin\ghostty.exe"))) {
    throw "zig-out\bin\ghostty.exe not found -- run: zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-msvc"
}
if (-not (Test-Path $dll)) {
    throw "ghostty_tabbar.dll not found -- run dist\windows\tabbar\ghostty-tabbar\build.bat"
}

Write-Host "Staging layout..."
if (Test-Path $layout) { Remove-Item -Recurse -Force $layout }
New-Item -ItemType Directory -Force $layout | Out-Null

# bin/ and share/ only: include/ and lib/ are for embedding libghostty and
# have no business in an end-user package.
Copy-Item (Join-Path $zigOut "bin") $layout -Recurse
Copy-Item (Join-Path $zigOut "share") $layout -Recurse -ErrorAction SilentlyContinue

# The tab bar DLL must sit beside the exe: it is a load-time dependency.
Copy-Item $dll (Join-Path $layout "bin") -Force

Copy-Item (Join-Path $PSScriptRoot "AppxManifest.xml") $layout -Force
Copy-Item (Join-Path $PSScriptRoot "Assets") $layout -Recurse -Force

Write-Host "Layout at $layout"
if ($NoRegister) { return }

Write-Host "Registering package (requires Developer Mode)..."
Add-AppxPackage -Register (Join-Path $layout "AppxManifest.xml")

$pkg = Get-AppxPackage -Name "Ghostty.Terminal"
Write-Host ""
Write-Host "Registered: $($pkg.PackageFullName)"
Write-Host "Launch:     Start-Process 'shell:AppsFolder\$($pkg.PackageFamilyName)!Ghostty'"
Write-Host "Remove:     Remove-AppxPackage $($pkg.PackageFullName)"
