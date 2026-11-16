# Downloads the NuGet packages and generates the C++/WinRT projections the
# tab bar needs. Neither is committed: together they are ~600 MB, and both
# are fully reproducible from this script.
#
# Requires: a Windows SDK (for cppwinrt.exe) and network access. 10.0.22621.0
# is what the projection was developed against and is used when installed;
# failing that, the newest SDK that has everything needed.

param(
    # Force a specific SDK version, e.g. 10.0.22621.0.
    [string]$SdkVersion
)

$ErrorActionPreference = "Stop"
$base = $PSScriptRoot
$pkgDir = Join-Path $base "packages"
New-Item -ItemType Directory -Force $pkgDir | Out-Null

$kits = "${env:ProgramFiles(x86)}\Windows Kits\10"

# The XAML *hosting* types (DesktopWindowXamlSource, WindowsXamlManager)
# are desktop-only and live in their own contract, not in
# UniversalApiContract -- without this input they simply won't exist in the
# generated projection.
function Get-HostingContract($version) {
    Get-ChildItem (Join-Path $kits "References\$version\Windows.UI.Xaml.Hosting.HostingContract") `
        -Recurse -Filter "Windows.UI.Xaml.Hosting.HostingContract.winmd" -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
}

# An SDK is only usable if it has both the tool and that contract.
function Test-Sdk($version) {
    (Test-Path (Join-Path $kits "bin\$version\x64\cppwinrt.exe")) -and (Get-HostingContract $version)
}

if (-not $SdkVersion) {
    $installed = Get-ChildItem (Join-Path $kits "bin") -Directory -Filter "10.*" -ErrorAction SilentlyContinue |
        Sort-Object { [version]$_.Name } -Descending | ForEach-Object Name
    $SdkVersion = @("10.0.22621.0") + @($installed) | Where-Object { Test-Sdk $_ } | Select-Object -First 1
    if (-not $SdkVersion) { throw "no usable Windows SDK found under $kits -- install the Windows SDK 10.0.22621.0" }
} elseif (-not (Test-Sdk $SdkVersion)) {
    throw "Windows SDK $SdkVersion is missing cppwinrt.exe or the XAML hosting contract"
}
Write-Host "Using Windows SDK $SdkVersion"

$cppwinrt = Join-Path $kits "bin\$SdkVersion\x64\cppwinrt.exe"
$hosting = Get-HostingContract $SdkVersion

# NuGet serves .nupkg, which Expand-Archive refuses by extension, so each
# download is copied to .zip before extracting.
function Get-Package($id, $version) {
    $target = Join-Path $pkgDir "$id.$version"
    if (Test-Path $target) {
        Write-Host "  $id $version (cached)"
        return $target
    }
    Write-Host "  $id $version ..."
    $zip = Join-Path $pkgDir "$id.$version.zip"
    Invoke-WebRequest -Uri "https://www.nuget.org/api/v2/package/$id/$version" `
        -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $target -Force
    Remove-Item $zip -Force
    return $target
}

Write-Host "Downloading packages..."
$uiXaml   = Get-Package "Microsoft.UI.Xaml" "2.8.6"
$webView2 = Get-Package "Microsoft.Web.WebView2" "1.0.2903.40"

# WinUI 2 metadata references WebView2 types, so cppwinrt needs that winmd
# too or it fails with "Type 'Microsoft.Web.WebView2.Core.CoreWebView2'
# could not be found".
$wv2Winmd = Join-Path $webView2 "lib\Microsoft.Web.WebView2.Core.winmd"

Write-Host "Generating WinUI 2 projection..."
$proj = Join-Path $base "projection"
& $cppwinrt `
    -input (Join-Path $uiXaml "lib\uap10.0\Microsoft.UI.Xaml.winmd") `
    -input $wv2Winmd `
    -input $hosting `
    -input $SdkVersion `
    -output $proj
if ($LASTEXITCODE -ne 0) { throw "cppwinrt failed for the WinUI 2 projection" }

Write-Host ""
Write-Host "Done. Now run ghostty-tabbar\build.bat"
