# Downloads the NuGet packages and generates the C++/WinRT projections the
# tab bar needs. Neither is committed: together they are ~600 MB, and both
# are fully reproducible from this script.
#
# Requires: Windows SDK 10.0.22621.0 (for cppwinrt.exe) and network access.

$ErrorActionPreference = "Stop"
$base = $PSScriptRoot
$pkgDir = Join-Path $base "packages"
New-Item -ItemType Directory -Force $pkgDir | Out-Null

$cppwinrt = "C:\Program Files (x86)\Windows Kits\10\bin\10.0.22621.0\x64\cppwinrt.exe"
if (-not (Test-Path $cppwinrt)) {
    throw "cppwinrt.exe not found at $cppwinrt -- install the Windows SDK 10.0.22621.0"
}

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

# The XAML *hosting* types (DesktopWindowXamlSource, WindowsXamlManager)
# are desktop-only and live in their own contract, not in
# UniversalApiContract -- without this input they simply won't exist in the
# generated projection.
$hosting = "C:\Program Files (x86)\Windows Kits\10\References\10.0.22621.0\" +
           "Windows.UI.Xaml.Hosting.HostingContract\5.0.0.0\" +
           "Windows.UI.Xaml.Hosting.HostingContract.winmd"

Write-Host "Generating WinUI 2 projection..."
$proj = Join-Path $base "projection"
& $cppwinrt `
    -input (Join-Path $uiXaml "lib\uap10.0\Microsoft.UI.Xaml.winmd") `
    -input $wv2Winmd `
    -input $hosting `
    -input 10.0.22621.0 `
    -output $proj
if ($LASTEXITCODE -ne 0) { throw "cppwinrt failed for the WinUI 2 projection" }

Write-Host ""
Write-Host "Done. Now run ghostty-tabbar\build.bat"
