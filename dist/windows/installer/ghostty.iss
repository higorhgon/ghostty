; Inno Setup script for Ghostty on Windows, without MSIX.
;
; Installs for the current user only, under %LOCALAPPDATA%\Programs, so it
; needs no administrator rights, no Developer Mode and no certificate.
; stage.ps1 next to this file prepares the layout it packs.
;
;   ISCC.exe /DAppVersion=1.4.1.2 dist\windows\installer\ghostty.iss

#ifndef AppVersion
  #define AppVersion "0.0.0.0"
#endif

; Must match the AppUserModelID Ghostty gives itself when it runs without a
; package (src/apprt/win32.zig) and the one the tab bar DLL files its
; notifications under: Windows only shows a toast from an unpackaged app
; whose ID belongs to a Start menu shortcut.
#define AppUserModelID "Ghostty.Terminal"

[Setup]
AppId={{6F3B8A52-4D1C-4E7B-9C2A-7D5E1F0A3B91}
AppName=Ghostty
AppVersion={#AppVersion}
AppVerName=Ghostty {#AppVersion}
VersionInfoVersion={#AppVersion}
AppPublisher=Ghostty for Windows
AppPublisherURL=https://github.com/higorhgon/ghostty
DefaultDirName={localappdata}\Programs\Ghostty
DefaultGroupName=Ghostty
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; XAML Islands, which the tab strip lives in, need Windows 10 1903.
MinVersion=10.0.18362
SetupIconFile=..\ghostty.ico
UninstallDisplayIcon={app}\bin\ghostty.exe
UninstallDisplayName=Ghostty
OutputDir=output
OutputBaseFilename=Ghostty-{#AppVersion}-x64-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Close a running Ghostty instead of leaving files in use, and start it
; again afterwards when it was closed for the update.
CloseApplications=yes
RestartApplications=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[InstallDelete]
; An update replaces the program files wholesale, so nothing a previous
; version shipped and this one dropped is left behind to be loaded.
Type: filesandordirs; Name: "{app}\bin"
Type: filesandordirs; Name: "{app}\share"

[Files]
Source: "layout\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\Ghostty"; Filename: "{app}\bin\ghostty.exe"; AppUserModelID: "{#AppUserModelID}"
Name: "{userdesktop}\Ghostty"; Filename: "{app}\bin\ghostty.exe"; AppUserModelID: "{#AppUserModelID}"; Tasks: desktopicon

[Registry]
; The class Windows' console host calls to hand a console session to Ghostty
; when it is the default terminal (src/apprt/win32/handoff.zig, which holds
; the same CLSID). COM starts ghostty.exe with -Embedding for it. Registering
; it changes nothing by itself: the default terminal is chosen by
; HKCU\Console\%%Startup DelegationTerminal, which this leaves alone.
Root: HKCU; Subkey: "Software\Classes\CLSID\{{5BFD48CD-0D7C-4D2C-96BB-2CC643119AB7}"; ValueType: string; ValueData: "Ghostty terminal handoff"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\CLSID\{{5BFD48CD-0D7C-4D2C-96BB-2CC643119AB7}\LocalServer32"; ValueType: string; ValueData: """{app}\bin\ghostty.exe"""

[Run]
Filename: "{app}\bin\ghostty.exe"; Description: "{cm:LaunchProgram,Ghostty}"; Flags: nowait postinstall skipifsilent
