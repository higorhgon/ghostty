# Packages and signs a distributable .msix installer from the staged layout.
#
# stage.ps1 registers loose files for local dev (Developer Mode only, no
# signature needed). Shipping to someone else requires an actual .msix
# file, and Windows refuses to install one unless its signing certificate
# is trusted on the target machine -- there's no way around signing.
#
# First run generates a self-signed cert (Subject must match the Publisher
# in AppxManifest.xml, currently "CN=Ghostty") and exports both the private
# key (.pfx, password-protected -- keep this) and the public cert (.cer --
# share this). The friend imports the .cer into their Trusted People store
# once; after that, double-clicking the .msix opens App Installer with a
# normal Install button.
#
# Prereqs: run stage.ps1 first so dist\windows\msix\layout exists.

param(
    [string]$CertPath = (Join-Path $PSScriptRoot "GhosttyCert.pfx"),
    [string]$PublicCertPath = (Join-Path $PSScriptRoot "Ghostty.cer"),
    [string]$OutFile = (Join-Path $PSScriptRoot "Ghostty.msix")
)

$ErrorActionPreference = "Stop"
$layout = Join-Path $PSScriptRoot "layout"

if (-not (Test-Path (Join-Path $layout "AppxManifest.xml"))) {
    throw "layout not staged -- run stage.ps1 first"
}

# --- 1. Certificate (create once, reuse on every later run) ---
if (-not (Test-Path $CertPath)) {
    Write-Host "No signing certificate found -- generating one..."
    $pw = Read-Host "Set a password to protect the new .pfx" -AsSecureString
    $cert = New-SelfSignedCertificate -Type Custom -Subject "CN=Ghostty" `
        -KeyUsage DigitalSignature -FriendlyName "Ghostty Terminal" `
        -CertStoreLocation "Cert:\CurrentUser\My" `
        -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3", "2.5.29.19={text}")
    Export-PfxCertificate -Cert $cert -FilePath $CertPath -Password $pw | Out-Null
    Export-Certificate -Cert $cert -FilePath $PublicCertPath | Out-Null
    Remove-Item "Cert:\CurrentUser\My\$($cert.Thumbprint)"
    Write-Host "Saved $CertPath (keep private) and $PublicCertPath (share this one)."
} elseif (-not (Test-Path $PublicCertPath)) {
    throw "$CertPath exists but $PublicCertPath is missing -- delete $CertPath and rerun to regenerate both together."
}

# --- 2. Locate SDK tools (same search stage.ps1 uses for makepri.exe) ---
$kit = "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
$makeappx = Get-ChildItem $kit -Recurse -Filter makeappx.exe -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -like "*\x64\*" } | Sort-Object FullName -Descending | Select-Object -First 1
$signtool = Get-ChildItem $kit -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -like "*\x64\*" } | Sort-Object FullName -Descending | Select-Object -First 1
if (-not $makeappx) { throw "makeappx.exe not found -- install the Windows SDK" }
if (-not $signtool) { throw "signtool.exe not found -- install the Windows SDK" }

# --- 3. Pack ---
if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
Write-Host "Packing $OutFile..."
& $makeappx.FullName pack /d $layout /p $OutFile /o

# --- 4. Sign ---
Write-Host "Signing..."
$pw = Read-Host "Enter the .pfx password" -AsSecureString
$plainPw = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw))
& $signtool.FullName sign /fd SHA256 /a /f $CertPath /p $plainPw $OutFile

Write-Host ""
Write-Host "Done: $OutFile"
Write-Host "Send your friend both $(Split-Path $OutFile -Leaf) and $(Split-Path $PublicCertPath -Leaf)."
Write-Host "They trust the cert once (as admin):"
Write-Host "  certutil -addstore TrustedPeople `"$(Split-Path $PublicCertPath -Leaf)`""
Write-Host "Then they double-click $(Split-Path $OutFile -Leaf) and click Install."
