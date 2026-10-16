#!/usr/bin/env python3
"""
Smashy Smashy setup: downloads the toolchain into tools/ and the C64 reference texts into docs/c64/.

    python tools/setup.py

Versions are pinned to what the game was built and tested with. Nothing is installed system-wide and
no admin rights are needed. Where a tool can't be downloaded portably (VICE and 64tass on Linux/macOS),
the script uses an existing install or prints the command to get one. Run it again any time: finished
steps are skipped.
"""

import io
import json
import os
import platform
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOLS = ROOT / "tools"

PROG8_TAG = "v12.3.4"
PROG8_JAR = "prog8c-12.3.4-all.jar"
TASS_VERSION = "1.60.3243"
TASS_MIN = (1, 58)
VICE_WIN_URL = "https://github.com/VICE-Team/svn-mirror/releases/download/3.10.0/GTK3VICE-3.10-win64.zip"

C64_DOCS = {
    "vic-ii.txt": "http://www.zimmers.net/cbmpics/cbm/c64/vic-ii.txt",
    "mapping-c64-io.txt": "https://raw.githubusercontent.com/mist64/c64ref/main/src/c64io/c64io_mapc64.txt",
    "mapping-c64-ram.txt": "https://raw.githubusercontent.com/mist64/c64ref/main/src/c64mem/c64mem_mapc64.txt",
    "prg-io-map.txt": "https://raw.githubusercontent.com/mist64/c64ref/main/src/c64io/c64io_prg.txt",
    "prg-ram-map.txt": "https://raw.githubusercontent.com/mist64/c64ref/main/src/c64mem/c64mem_prg.txt",
    "kernal-api-prg.txt": "https://raw.githubusercontent.com/mist64/c64ref/main/src/kernal/kernal_prg.txt",
    "cpu-6502.txt": "https://raw.githubusercontent.com/mist64/c64ref/main/src/6502/cpu_6502.txt",
}

todo = []       # manual steps, printed at the end


def log(msg):
    print(msg, flush=True)


def host():
    s = {"windows": "windows", "linux": "linux", "darwin": "mac"}.get(platform.system().lower())
    m = platform.machine().lower()
    arch = "x64" if m in ("x86_64", "amd64") else "aarch64" if m in ("arm64", "aarch64") else None
    if not s or not arch:
        sys.exit(f"Unsupported system: {platform.system()} {platform.machine()}")
    return s, arch


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "smashy-smashy-setup"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()


def download(url, what):
    log(f"  downloading {what} ...")
    data = fetch(url)
    log(f"    {len(data) // 1024} KB")
    return data


def extract(data, dest, strip_top=True):
    """Extracts a zip or tar.gz into dest, dropping a single top-level folder."""
    dest = Path(dest)
    tmp = Path(tempfile.mkdtemp(prefix="smashy-"))
    try:
        if data[:2] == b"PK":
            with zipfile.ZipFile(io.BytesIO(data)) as z:
                for info in z.infolist():
                    target = (tmp / info.filename).resolve()
                    if not str(target).startswith(str(tmp.resolve())):
                        raise RuntimeError(f"unsafe path in archive: {info.filename}")
                    z.extract(info, tmp)
                    mode = info.external_attr >> 16
                    if mode and not info.is_dir():
                        os.chmod(target, mode & 0o777 | stat.S_IRUSR)
        else:
            with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as t:
                if hasattr(tarfile, "data_filter"):
                    t.extractall(tmp, filter="tar")
                else:
                    t.extractall(tmp)
        entries = list(tmp.iterdir())
        src = entries[0] if strip_top and len(entries) == 1 and entries[0].is_dir() else tmp
        if dest.exists():
            shutil.rmtree(dest)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(src), str(dest))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def find_java():
    for rel in ("bin", "Contents/Home/bin"):
        for name in ("java", "java.exe"):
            p = TOOLS / "jdk21" / rel / name
            if p.exists():
                return p
    return None


def jdk(os_name, arch):
    if find_java():
        log("  JDK 21 already installed")
        return
    url = f"https://api.adoptium.net/v3/binary/latest/21/ga/{os_name}/{arch}/jdk/hotspot/normal/eclipse"
    extract(download(url, "Temurin JDK 21"), TOOLS / "jdk21")


def prog8():
    jar = TOOLS / "prog8" / PROG8_JAR
    if jar.exists():
        log(f"  Prog8 compiler {PROG8_TAG} already installed")
    else:
        jar.parent.mkdir(parents=True, exist_ok=True)
        jar.write_bytes(download(f"https://github.com/irmen/prog8/releases/download/{PROG8_TAG}/{PROG8_JAR}",
                                 f"Prog8 {PROG8_TAG} compiler"))
    src = TOOLS / "prog8-src"
    if (src / "docs").exists():
        log("  Prog8 source (docs and library, for reference) already present")
    elif shutil.which("git"):
        log(f"  cloning Prog8 {PROG8_TAG} source (docs and library, for reference) ...")
        r = run(["git", "clone", "-q", "--depth", "1", "--branch", PROG8_TAG,
                 "https://github.com/irmen/prog8.git", str(src)])
        if r.returncode != 0:
            todo.append("Cloning the Prog8 source failed (only needed as reference):\n" + r.stderr)
    else:
        extract(download(f"https://codeload.github.com/irmen/prog8/zip/refs/tags/{PROG8_TAG}", "Prog8 source"), src)


def tass_version(cmd):
    try:
        m = re.search(r"V(\d+)\.(\d+)", run([str(cmd), "--version"]).stdout)
    except OSError:
        return None
    return (int(m.group(1)), int(m.group(2))) if m else None


def tass(os_name):
    local_dir = TOOLS / "64tass"
    local = next(local_dir.rglob("64tass.exe" if os_name == "windows" else "64tass"), None) \
        if local_dir.exists() else None
    if local and (tass_version(local) or (0,)) >= TASS_MIN:
        log(f"  64tass already installed: {local}")
        return
    system = shutil.which("64tass")
    if system and (tass_version(system) or (0,)) >= TASS_MIN:
        log(f"  using 64tass on the PATH: {system}")
        return
    if os_name == "windows":
        url = f"https://sourceforge.net/projects/tass64/files/binaries/64tass-{TASS_VERSION}.zip/download"
        extract(download(url, f"64tass {TASS_VERSION}"), local_dir)
        return
    if shutil.which("make") and (shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")):
        url = f"https://sourceforge.net/projects/tass64/files/source/64tass-{TASS_VERSION}-src.zip/download"
        build = TOOLS / "64tass-src"
        extract(download(url, f"64tass {TASS_VERSION} source"), build)
        log("  building 64tass ...")
        r = run(["make", "-j4"], cwd=build)
        if r.returncode == 0 and (build / "64tass").exists():
            local_dir.mkdir(parents=True, exist_ok=True)
            shutil.copy2(build / "64tass", local_dir / "64tass")
            (local_dir / "64tass").chmod(0o755)
            shutil.rmtree(build, ignore_errors=True)
            return
        todo.append("Building 64tass failed:\n" + r.stderr[-1500:])
    if os_name == "mac":
        todo.append("Install 64tass:  brew install tass64")
    else:
        todo.append("Install a C compiler and make (Debian/Ubuntu/Mint: sudo apt install build-essential), "
                    "then run this setup again to build 64tass.")


def vice(os_name):
    if os_name == "windows":
        if (TOOLS / "vice" / "bin" / "x64sc.exe").exists():
            log("  VICE already installed")
        else:
            extract(download(VICE_WIN_URL, "VICE 3.10"), TOOLS / "vice")
        return
    if shutil.which("x64sc"):
        log(f"  using VICE on the PATH: {shutil.which('x64sc')}")
        return
    if os_name == "linux" and shutil.which("flatpak") and run(["flatpak", "info", "net.sf.VICE"]).returncode == 0:
        log("  using VICE from Flatpak (net.sf.VICE)")
        return
    if os_name == "mac":
        todo.append("Install VICE:  brew install vice")
    else:
        todo.append("Install VICE (includes the C64 ROMs):  flatpak install -y flathub net.sf.VICE")


def c64_docs():
    dest = ROOT / "docs" / "c64"
    dest.mkdir(parents=True, exist_ok=True)
    for name, url in C64_DOCS.items():
        f = dest / name
        if not f.exists():
            try:
                f.write_bytes(fetch(url))
                log(f"  fetched {name}")
            except Exception as e:
                todo.append(f"Could not fetch {name} ({url}): {e}")


def main():
    if sys.version_info < (3, 8):
        sys.exit("Python 3.8 or newer is required")
    os_name, arch = host()
    log(f"Smashy Smashy setup ({os_name}/{arch})\n")
    log("[1/5] Java 21");                jdk(os_name, arch)
    log("[2/5] Prog8 12.3.4");           prog8()
    log("[3/5] 64tass assembler");       tass(os_name)
    log("[4/5] VICE emulator");          vice(os_name)
    log("[5/5] C64 reference texts");    c64_docs()

    java = find_java()
    if java:
        r = run([str(java), "-jar", str(TOOLS / "prog8" / PROG8_JAR), "-version"])
        lines = (r.stdout + r.stderr).strip().splitlines()
        log("\n" + (lines[0] if lines else "prog8c did not respond"))
    if todo:
        log("\nStill to do:")
        for t in todo:
            log("  - " + t)
    else:
        build = "build.cmd run" if os_name == "windows" else "./build.sh run"
        log(f"\nAll set. Build and play with:  {build}")


if __name__ == "__main__":
    main()
