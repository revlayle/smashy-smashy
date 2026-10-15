"""Text art -> C64 binary data.

Reads assets/sprites.txt and assets/tiles.txt (format: docs/spec.md section 10) and writes
  build/sprites.bin    64 bytes per sprite frame, copied to $E800 at startup
  build/chars.bin      4 chars (TL, TR, BL, BR) per tile, copied to char TILE_FIRST_CHAR onward
  src/gen_assets.p8    name constants for the code

Usage: python tools/gfx.py   (run from the project root; build.cmd does this)
Exits with status 1 and "file:line: message" errors if the art is bad. Nothing is written then.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ART_FILES = [ROOT / "assets" / "sprites.txt", ROOT / "assets" / "tiles.txt"]
VIDEO_SRC = ROOT / "src" / "video.p8"
OUT_SPRITES = ROOT / "build" / "sprites.bin"
OUT_CHARS = ROOT / "build" / "chars.bin"
OUT_P8 = ROOT / "src" / "gen_assets.p8"

ART_ROWS = 16
FIRST_SPRITE_PTR = 160      # $E800 in VIC bank 3: ($E800 - $C000) / 64
MAX_SPRITES = 95            # pointers 160-254
TILE_FIRST_CHAR = 64        # chars 0-63 hold the ROM font for the HUD
MAX_TILES = (256 - TILE_FIRST_CHAR) // 4

# symbol -> 2-bit pixel value. Multicolor chars: 01=$D022 10=$D023 11=color RAM.
# Multicolor sprites: 01=$D025 10=own color $D027+n 11=$D026.
CHAR_MC_BITS = {".": 0, "2": 1, "3": 2, "1": 3}
SPRITE_MC_BITS = {".": 0, "2": 1, "1": 2, "3": 3}
HIRES_BITS = {".": 0, "1": 1}


class ArtError(Exception):
    pass


def read_multicolor_flag():
    m = re.search(r"const\s+bool\s+MULTICOLOR\s*=\s*(true|false)", VIDEO_SRC.read_text())
    if not m:
        raise ArtError(f"{VIDEO_SRC.relative_to(ROOT)}: can't find 'const bool MULTICOLOR = true|false'")
    return m.group(1) == "true"


def parse_file(path, multicolor, entries, errors):
    """Append (kind, name, color, rows, where) to entries. Collect error strings in errors."""
    rel = path.relative_to(ROOT).as_posix()
    width = 8 if multicolor else 16
    symbols = "." + ("123" if multicolor else "1")
    mode_seen = False
    current = None          # [kind, name, color, rows, where]

    def finish(lineno):
        if current is not None and len(current[3]) != ART_ROWS:
            errors.append(f"{current[4]}: {current[0]} '{current[1]}' has {len(current[3])} rows, "
                          f"expected {ART_ROWS} (ends before line {lineno})")

    lines = path.read_text().splitlines()
    for lineno, raw in enumerate(lines, 1):
        where = f"{rel}:{lineno}"
        line = raw.split(";", 1)[0].strip()
        if not line:
            continue
        words = line.split()
        key = words[0]

        if key == "mode":
            if len(words) != 2 or words[1] not in ("multicolor", "hires"):
                errors.append(f"{where}: expected 'mode multicolor' or 'mode hires'")
            elif (words[1] == "multicolor") != multicolor:
                want = "multicolor" if multicolor else "hires"
                errors.append(f"{where}: art is 'mode {words[1]}' but video.p8 MULTICOLOR "
                              f"wants '{want}'. Redraw the art or change the constant.")
            mode_seen = True
        elif key == "colors":
            pass    # legend for the reader only
        elif key in ("sprite", "tile"):
            finish(lineno)
            current = [key, "?", None, [], where]   # placeholder: swallows the rows of a bad header
            if not mode_seen:
                errors.append(f"{where}: 'mode' line must come before the first {key}")
            if len(words) < 2 or not re.fullmatch(r"[a-z][a-z0-9_]*", words[1]):
                errors.append(f"{where}: expected '{key} <name>' with a lowercase name (a-z, 0-9, _)")
                continue
            color = None
            if key == "tile":
                if len(words) != 4 or words[2] != "color" or not words[3].isdigit():
                    errors.append(f"{where}: expected 'tile <name> color <0-15>'")
                    continue
                color = int(words[3])
                limit = 7 if multicolor else 15
                if color > limit:
                    why = "multicolor tiles can only use colors 0-7" if multicolor else "colors are 0-15"
                    errors.append(f"{where}: tile color {color} too high; {why}")
                    continue
            elif len(words) != 2:
                errors.append(f"{where}: expected 'sprite <name>'")
                continue
            current[1] = words[1]
            current[2] = color
            entries.append(current)
        elif len(words) == 1:
            if current is None:
                errors.append(f"{where}: pixel row outside any sprite or tile")
                continue
            if len(current[3]) == ART_ROWS:
                errors.append(f"{where}: {current[0]} '{current[1]}' already has {ART_ROWS} rows")
                continue
            if len(line) != width:
                errors.append(f"{where}: row has {len(line)} pixels, expected {width} "
                              f"({'multicolor' if multicolor else 'hires'})")
            bad = sorted(set(line) - set(symbols))
            if bad:
                errors.append(f"{where}: symbol(s) {' '.join(bad)} not allowed; use {' '.join(symbols)}")
            current[3].append(line)
        else:
            errors.append(f"{where}: can't read this line: {raw.strip()!r}")
    finish(len(lines) + 1)


def pack_row(row, bits_map, multicolor):
    """One art row (8 or 16 symbols) -> 2 bytes."""
    if multicolor:
        value = 0
        for ch in row:
            value = (value << 2) | bits_map[ch]
    else:
        value = 0
        for ch in row:
            value = (value << 1) | HIRES_BITS[ch]
    return [(value >> 8) & 255, value & 255]


def build(multicolor, entries):
    sprites = bytearray()
    chars = bytearray()
    consts = []
    sprite_count = 0
    tile_count = 0
    for kind, name, color, rows, _ in entries:
        packed = [pack_row(r, SPRITE_MC_BITS if kind == "sprite" else CHAR_MC_BITS, multicolor)
                  for r in rows]
        if kind == "sprite":
            frame = bytearray(64)
            for y, (left, right) in enumerate(packed):
                frame[y * 3] = left
                frame[y * 3 + 1] = right
            sprites += frame
            consts.append(f"    const ubyte SPR_{name.upper()} = {FIRST_SPRITE_PTR + sprite_count}")
            sprite_count += 1
        else:
            tl = [p[0] for p in packed[:8]]
            tr = [p[1] for p in packed[:8]]
            bl = [p[0] for p in packed[8:]]
            br = [p[1] for p in packed[8:]]
            chars += bytes(tl + tr + bl + br)
            first = TILE_FIRST_CHAR + tile_count * 4
            consts.append(f"    const ubyte TILE_{name.upper()}_TL = {first}")
            consts.append(f"    const ubyte TILE_{name.upper()}_COLOR = {color}")
            tile_count += 1
    return sprites, chars, consts, sprite_count, tile_count


def main():
    errors = []
    try:
        multicolor = read_multicolor_flag()
    except ArtError as e:
        print(f"gfx.py: error: {e}", file=sys.stderr)
        return 1

    entries = []
    for path in ART_FILES:
        if not path.exists():
            errors.append(f"{path.relative_to(ROOT).as_posix()}: file not found")
            continue
        parse_file(path, multicolor, entries, errors)

    seen = {}
    for kind, name, _, _, where in entries:
        if (kind, name) in seen:
            errors.append(f"{where}: {kind} '{name}' already defined at {seen[(kind, name)]}")
        seen[(kind, name)] = where
    n_sprites = sum(1 for e in entries if e[0] == "sprite")
    n_tiles = sum(1 for e in entries if e[0] == "tile")
    if n_sprites > MAX_SPRITES:
        errors.append(f"too many sprites: {n_sprites}, max {MAX_SPRITES}")
    if n_tiles > MAX_TILES:
        errors.append(f"too many tiles: {n_tiles}, max {MAX_TILES}")

    if errors:
        for e in errors:
            print(f"gfx.py: error: {e}", file=sys.stderr)
        return 1

    sprites, chars, consts, sprite_count, tile_count = build(multicolor, entries)
    OUT_SPRITES.parent.mkdir(exist_ok=True)
    OUT_SPRITES.write_bytes(sprites)
    OUT_CHARS.write_bytes(chars)
    p8 = [
        "; GENERATED by tools/gfx.py from assets/sprites.txt and assets/tiles.txt. Do not edit.",
        "",
        "assets {",
        f"    const ubyte SPRITE_COUNT = {sprite_count}",
        f"    const ubyte TILE_COUNT = {tile_count}",
        f"    const ubyte TILE_FIRST_CHAR = {TILE_FIRST_CHAR}",
        "",
        *consts,
        "}",
        "",
    ]
    text = "\n".join(p8)
    if not OUT_P8.exists() or OUT_P8.read_text() != text:
        OUT_P8.write_text(text)
    print(f"gfx.py: {sprite_count} sprites, {tile_count} tiles ({len(chars) // 8} chars)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
