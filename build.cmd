@echo off
rem Convert the art, then build src\main.p8 into build\main.prg. "build run" also starts it in VICE.
setlocal
cd /d "%~dp0"
if not exist build mkdir build
python tools\gfx.py || exit /b 1
tools\jdk21\bin\java -jar tools\prog8\prog8c-12.3.4-all.jar -target c64 -out build src\main.p8 || exit /b 1
if /i "%1"=="run" start "" tools\vice\bin\x64sc.exe -autostart build\main.prg
