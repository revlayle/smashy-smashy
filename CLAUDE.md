# C64 platformer demo

A small C64 platformer written in Prog8. Claude writes the code; the user knows Prog8 and reviews it.

## Toolchain (all project-local, in `tools/`)

- Compile: `tools/jdk21/bin/java -jar tools/prog8/prog8c-12.3.4-all.jar -target c64 -out build src/main.p8`
  - The system Java is 11, which is too old. Always use `tools/jdk21`.
- Run and check: `tools/vice/bin/x64sc.exe -default -silent -sounddev dummy -warp -autostartprgmode 1 -limitcycles <N> -exitscreenshot <png> -autostart <prg>`, then view the PNG. `-autostartprgmode 1` injects the PRG into RAM; the program runs by about 3,500,000 cycles.
- 64tass is on PATH, and Prog8 calls it automatically.

## Coding rules

- No floating point (`%import floats` is banned). Prefer `ubyte`/`byte`, `uword` only when values exceed 255. Multiply and divide by shifts or lookup tables in per-frame code. See `docs/spec.md` §1 "Number rules".

## Game design

- `platformer-game.txt`: the user's design notes (source of truth for gameplay).
- `docs/spec.md`: the technical spec (memory map, data structures, physics values, milestones). Keep it updated when decisions change.
- `docs/phases.md`: the build plan. **To continue coding, follow "How to work a phase" there:** do the next phase that isn't done, verify it, record status and notes, then stop for the designer to play it.

## References

See `docs/README.md` for the index of C64 hardware docs and Prog8 docs and library source. Search them for exact register bits and library signatures instead of relying on memory.
