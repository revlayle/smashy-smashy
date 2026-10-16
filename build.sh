#!/bin/sh
# Convert the art, then build src/main.p8 into build/main.prg. "./build.sh run" also starts it in VICE.
# Linux/macOS counterpart of build.cmd. Run "python3 tools/setup.py" once first.
set -e
cd "$(dirname "$0")"
mkdir -p build

JAVA=tools/jdk21/bin/java
[ -x "$JAVA" ] || JAVA=tools/jdk21/Contents/Home/bin/java     # macOS JDK layout
[ -d tools/64tass ] && PATH="$(pwd)/tools/64tass:$PATH" && export PATH

python3 tools/gfx.py
"$JAVA" -jar tools/prog8/prog8c-12.3.4-all.jar -target c64 -out build src/main.p8

if [ "$1" = "run" ]; then
    if command -v x64sc >/dev/null 2>&1; then
        x64sc -config tools/vicerc -autostartprgmode 1 -autostart build/main.prg &
    else
        flatpak run --command=x64sc net.sf.VICE -config "$(pwd)/tools/vicerc" -autostartprgmode 1 \
            -autostart "$(pwd)/build/main.prg" &
    fi
fi
