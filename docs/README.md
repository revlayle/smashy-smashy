# Docs

Project docs: `spec.md` (technical spec), `phases.md` (build plan and status), `session-prompts.md` (prompts for starting coding sessions).

# Reference docs

Plain-text references. Search them (grep for a hex address like `$D016` or a topic word) rather than reading whole files.

## C64 hardware (`c64/`)

| File | What's in it | Source |
|---|---|---|
| `vic-ii.txt` | VIC-II deep dive: raster timing, badlines, sprites, scrolling, graphics modes, bank switching | Christian Bauer, via zimmers.net |
| `mapping-c64-io.txt` | Every I/O register `$D000-$DFFF` (VIC-II, SID, CIA), with explanations | *Mapping the Commodore 64* (Leemon), via mist64/c64ref |
| `mapping-c64-ram.txt` | RAM map `$0000-$CFFF` and ROM areas: zero page, screen, KERNAL vectors | *Mapping the Commodore 64*, via c64ref |
| `prg-io-map.txt` | Terse I/O register map | *C64 Programmer's Reference Guide*, via c64ref |
| `prg-ram-map.txt` | Terse RAM map | *C64 Programmer's Reference Guide*, via c64ref |
| `kernal-api-prg.txt` | KERNAL ROM routines (`CHROUT`, `SETLFS`, ...) | *C64 Programmer's Reference Guide*, via c64ref |
| `cpu-6502.txt` | 6502 instruction set: opcodes, addressing modes, flags, cycles | c64ref |

## Prog8 (`../tools/prog8-src/`, v12.3.4)

| Path | What's in it |
|---|---|
| `docs/source/*.rst` | Language manual (`programming.rst`, `libraries.rst`, `targetsystem.rst`, `technical.rst`) |
| `compiler/res/prog8lib/c64/` | C64 standard library source: exact routine names and signatures |
| `compiler/res/prog8lib/*.p8` | Target-independent library modules |
| `examples/c64/` | Example C64 programs |
| `AGENTS.md` | Maintainer's notes for AI agents |
