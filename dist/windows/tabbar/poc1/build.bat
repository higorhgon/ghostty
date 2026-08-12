@echo off
REM Build PoC 1. Uses the Windows SDK's prebuilt C++/WinRT headers, so no
REM NuGet restore and no cppwinrt.exe projection step is needed.
setlocal

set SDKVER=10.0.22621.0
set VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat

call "%VCVARS%" >nul
if errorlevel 1 (
  echo FATAL: could not initialize MSVC environment
  exit /b 1
)

cd /d "%~dp0"

REM Embed the manifest as a resource; XAML Islands refuses to start without
REM the supportedOS entries it declares.
rc /nologo /fo app.res app.rc
if errorlevel 1 exit /b 1

REM /DNOMINMAX and the GetCurrentTime undef avoid the well-known clash
REM between windows.h macros and the XAML animation headers.
cl /nologo /std:c++17 /EHsc /DWIN32_LEAN_AND_MEAN /DNOMINMAX /D_UNICODE /DUNICODE ^
   /I "C:\Program Files (x86)\Windows Kits\10\Include\%SDKVER%\cppwinrt" ^
   main.cpp app.res ^
   /link /SUBSYSTEM:WINDOWS ^
   user32.lib gdi32.lib windowsapp.lib ^
   /OUT:poc1.exe
if errorlevel 1 exit /b 1

echo BUILD OK
