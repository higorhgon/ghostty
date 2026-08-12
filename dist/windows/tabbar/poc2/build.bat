@echo off
REM Build PoC 2. Unlike PoC 1 this uses the *generated* projection (which
REM covers both the Windows.* platform types and WinUI 2's Microsoft.UI.*
REM types) instead of the SDK's prebuilt cppwinrt headers -- mixing the two
REM would give duplicate/conflicting definitions.
setlocal

set PROJ=%~dp0..\projection
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
   /I "%PROJ%" ^
   main.cpp app.res ^
   /link /SUBSYSTEM:WINDOWS ^
   user32.lib gdi32.lib windowsapp.lib ^
   /OUT:poc2.exe
if errorlevel 1 exit /b 1

echo BUILD OK
