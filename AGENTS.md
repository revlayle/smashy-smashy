# Smashy Smashy: instructions for AI coding agents

A small single-screen C64 platformer written in **Prog8 12.3.4**. An AI agent writes the code; the designer (Rev. Layle) knows Prog8, reviews it and decides all gameplay.

This file is for any agent (Claude Code, opencode, Codex, Cursor, ...). Claude Code reads it through `CLAUDE.md`.

## Toolchain (project-local, in `tools/`)

Run `python tools/setup.py` once; it downloads everything into `tools/` and the C64 reference texts into `docs/c64/`.

- **Build:** `build.cmd` (Windows) or `./build.sh` (Linux/macOS). It runs `tools/gfx.py` (text art → `src/gen_assets.p8` and binaries), then compiles `src/main.p8` to `build/main.prg`.
  - Compiler directly: `tools/jdk21/bin/java -jar tools/prog8/prog8c-12.3.4-all.jar -target c64 -out build src/main.p8`.
  - Always use `tools/jdk21`; Prog8 needs Java 17+.
  - 64tass must be on the PATH (the build scripts add `tools/64tass` if setup installed it there).
- **Check your work in the emulator:** `x64sc -default -silent -sounddev dummy -warp -autostartprgmode 1 -limitcycles <N> -exitscreenshot <png> -autostart build/main.prg`, then look at the PNG.
  - The program is running by about 3,500,000 cycles; 985,248 cycles = 1 s.
  - `x64sc` is `tools/vice/bin/x64sc.exe` on Windows; on Linux/macOS it's on the PATH, or `flatpak run --command=x64sc net.sf.VICE`.
- **Launching for the designer to play:** `build.cmd run` / `./build.sh run`. It passes `-config tools/vicerc`, which maps the arrow keys and left Ctrl to joystick port 2. Without it the designer's keys don't work.

## Coding rules

- No floating point (`%import floats` is banned). Prefer `ubyte`/`byte`, `uword` only when values exceed 255. Multiply and divide by shifts or lookup tables in per-frame code. See `docs/spec.md` §1 "Number rules".
- Never guess a Prog8 library routine: look it up in `tools/prog8-src/compiler/res/prog8lib/` or with `prog8c -libsearch <regex>`.
- Look up C64 hardware facts in `docs/c64/` (index in `docs/README.md`) instead of relying on memory.
- Self-test switches (`input.SCRIPTED`, `main.TEST`, `FRAME_STATS`, ...) must be off in builds handed to the designer.

## Guides (skills)

Plain Markdown, readable by any agent. Read the matching one before that kind of work:
- `.claude/skills/prog8-coder/SKILL.md`: Prog8 language rules (from the Prog8 project). Read before writing Prog8.
- `.claude/skills/asm6502-coder/SKILL.md`: inline 6502 assembly in 64tass syntax.

Claude Code loads these automatically as skills; other agents should open them when needed.

## Game design and workflow

- `platformer-game.txt`: the designer's original notes. `docs/spec.md` is the source of truth for every rule and number; keep it updated when a decision changes.
- `docs/phases.md`: the build plan and log. **To continue coding, follow "How to work a phase" there:** do the next unfinished phase, verify every "Done when" item, record status and notes, then stop for the designer to play it.
- Changes after the phases are one-off changes. A pending change has its own file in `docs/` until it's built; then it's merged into `spec.md` and deleted.
- Don't change gameplay rules without asking the designer.
- Commit only after the designer approves.
- `docs/session-prompts.md` has the prompts the designer uses to start sessions.
