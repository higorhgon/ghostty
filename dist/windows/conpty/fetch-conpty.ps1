# Fetches the redistributable ConPTY (conpty.dll + OpenConsole.exe) that
# stage.ps1 puts beside ghostty.exe.
#
# Windows' built-in ConPTY runs the system's conhost.exe, which is as old as
# the installed Windows. The Microsoft.Windows.Console.ConPTY package is the
# console host Windows Terminal ships (MIT licensed, from
# microsoft/terminal), and Ghostty loads its conpty.dll when one sits next
# to the exe. Without this, Ghostty still works on the system ConPTY.

param(
    [string]$Version = "1.25.261109001"
)

$ErrorActionPreference = "Stop"
$out = Join-Path $PSScriptRoot "bin"
$id = "microsoft.windows.console.conpty"
$url = "https://api.nuget.org/v3-flatcontainer/$id/$Version/$id.$Version.nupkg"

$tmp = Join-Path ([IO.Path]::GetTempPath()) "ghostty-conpty-$Version"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
New-Item -ItemType Directory -Force $tmp | Out-Null
$zip = Join-Path $tmp "conpty.zip"

Write-Host "Downloading $id $Version..."
Invoke-WebRequest $url -OutFile $zip
Expand-Archive $zip (Join-Path $tmp "pkg")

# The package carries every architecture; only x64's are wanted.
$files = Get-ChildItem (Join-Path $tmp "pkg") -Recurse -Include conpty.dll, OpenConsole.exe |
    Where-Object { $_.FullName -match '[\\/](win-)?x64[\\/]' }
foreach ($name in "conpty.dll", "OpenConsole.exe") {
    if (-not ($files | Where-Object Name -eq $name)) { throw "$name for x64 not found in the package" }
}

if (Test-Path $out) { Remove-Item -Recurse -Force $out }
New-Item -ItemType Directory -Force $out | Out-Null
$files | ForEach-Object { Copy-Item $_.FullName $out -Force; Write-Host "  $($_.Name)  <- $($_.FullName.Substring($tmp.Length + 1))" }
Get-ChildItem (Join-Path $tmp "pkg") -Recurse -Include LICENSE* | Select-Object -First 1 | Copy-Item -Destination (Join-Path $out "LICENSE.conpty.txt")
Remove-Item -Recurse -Force $tmp
Write-Host "ConPTY $Version in $out"
