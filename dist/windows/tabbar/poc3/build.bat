@echo off
REM Build PoC 3 (WinUI 3, unpackaged). Links the Windows App SDK
REM bootstrapper and copies its DLL next to the exe -- an unpackaged app
REM has to load the runtime itself.
setlocal

set BASE=%~dp0..
set PROJ=%BASE%\projection-winui3
set FOUND=%BASE%\packages\Microsoft.WindowsAppSDK.Foundation.1.8.260709000
REM Microsoft.UI.Interop.h (GetWindowIdFromWindow) is a hand-written SDK
REM header, not something cppwinrt generates, so it needs its own -I.
set IXP=%BASE%\packages\Microsoft.WindowsAppSDK.InteractiveExperiences.1.8.260708001
set VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat

call "%VCVARS%" >nul
if errorlevel 1 (
  echo FATAL: could not initialize MSVC environment
  exit /b 1
)

cd /d "%~dp0"

rc /nologo /fo app.res app.rc
if errorlevel 1 exit /b 1

cl /nologo /std:c++17 /EHsc /DWIN32_LEAN_AND_MEAN /DNOMINMAX /D_UNICODE /DUNICODE ^
   /I "%PROJ%" /I "%FOUND%\include" /I "%IXP%\include" ^
   main.cpp app.res ^
   /link /SUBSYSTEM:WINDOWS ^
   user32.lib gdi32.lib windowsapp.lib ^
   "%FOUND%\lib\native\x64\Microsoft.WindowsAppRuntime.Bootstrap.lib" ^
   /OUT:poc3.exe
if errorlevel 1 exit /b 1

copy /y "%FOUND%\runtimes\win-x64\native\Microsoft.WindowsAppRuntime.Bootstrap.dll" . >nul

echo BUILD OK
