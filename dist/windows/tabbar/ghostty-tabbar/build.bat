@echo off
REM Build ghostty_tabbar.dll (WinUI 2 tab strip behind a flat C ABI).
setlocal

set BASE=%~dp0..
set PROJ=%BASE%\projection
set VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat

call "%VCVARS%" >nul
if errorlevel 1 (
  echo FATAL: could not initialize MSVC environment
  exit /b 1
)

cd /d "%~dp0"

cl /nologo /std:c++17 /EHsc /LD /MD ^
   /DWIN32_LEAN_AND_MEAN /DNOMINMAX /D_UNICODE /DUNICODE ^
   /I "%PROJ%" ^
   ghostty_tabbar.cpp ^
   /link user32.lib gdi32.lib windowsapp.lib ^
   /OUT:ghostty_tabbar.dll
if errorlevel 1 exit /b 1

REM The host exe needs its own embedded manifest: XAML Islands checks the
REM *process* manifest for maxversiontested, and fails with a bare
REM E_UNEXPECTED if it's missing -- even when the app is MSIX-packaged and
REM the package manifest already declares MaxVersionTested.
rc /nologo /fo app.res app.rc
if errorlevel 1 exit /b 1

REM Plain-C harness, compiled as C to prove the ABI needs no C++/WinRT.
REM app.res goes after /link: with /TC, cl would otherwise try to compile
REM the .res file as C source.
cl /nologo /TC /MD /DWIN32_LEAN_AND_MEAN /D_UNICODE /DUNICODE ^
   testhost.c ^
   /link /SUBSYSTEM:WINDOWS app.res user32.lib ghostty_tabbar.lib ^
   /OUT:testhost.exe
if errorlevel 1 exit /b 1

echo BUILD OK
