@echo off
rem Convert the art, then build src\main.p8 into build\main.prg. "build run" also starts it in VICE.
setlocal
cd /d "%~dp0"
if not exist build mkdir build
if exist tools\64tass\64tass.exe set "PATH=%~dp0tools\64tass;%PATH%"
python tools\gfx.py || exit /b 1
tools\jdk21\bin\java -jar tools\prog8\prog8c-12.3.4-all.jar -target c64 -out build src\main.p8 || exit /b 1
if /i "%1"=="run" start "" tools\vice\bin\x64sc.exe -config tools\vicerc -autostartprgmode 1 -autostart build\main.prg
