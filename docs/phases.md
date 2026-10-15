# Build phases

Implementation plan for `docs/spec.md`. Work one phase at a time, in order. Each phase ends with a build the designer can play in VICE.

## How to work a phase

1. Read `CLAUDE.md`, then `docs/spec.md` (the whole thing once; afterwards the sections the phase names).
2. Pick the first phase whose status is not `done`. Set it to `in progress`.
3. Implement only that phase's scope. Things the spec defers to later phases stay out.
4. Verify every "Done when" item (see **Verification** below). Fix until all pass.
5. Set the status to `done`. Under the phase, add a short **Notes** list: deviations from the spec, tuned values, known issues. If a decision changed, update `docs/spec.md` too.
6. Stop and report to the designer. Don't start the next phase without their go-ahead; they will want to play each build.

If the spec is ambiguous or wrong for something the phase needs, ask the designer. Don't guess on gameplay. For pure implementation details, pick one and record it in Notes.

## Verification

The coding session can't hold a joystick, so two tools exist for self-testing:

- **Screenshots:** `tools/vice/bin/x64sc.exe -default -silent -sounddev dummy -warp -autostartprgmode 1 -limitcycles <N> -exitscreenshot <png> -autostart build/main.prg`, then view the PNG. About 1,000,000 cycles is 1 second of C64 time; the program is running by about 3,500,000 cycles (`-autostartprgmode 1` injects it into RAM; without it the disk load takes over 8 s).
- **Scripted input** (built in phase 1): a compile-time switch makes `input.p8` read joystick states from a table instead of `$DC00`. Each entry is (frames to hold, joystick bits). Screenshots at chosen cycle counts then show the result of a known input sequence. The switch must be off in builds handed to the designer.

Things that need real feel (speed, jump arc, responsiveness) can't be self-verified. List them in the report for the designer to check.

---

## Phase 1: Video foundation and tooling
**Status:** done
**Spec:** §1, §2, §3, §4 (tile map), §10, §11

Build:
- `tools/gfx.py`: text art → `build/sprites.bin`, `build/chars.bin`, `src/gen_assets.p8` (format in §10). Clear error messages with line numbers for bad art.
- `assets/sprites.txt` and `assets/tiles.txt` with placeholder art: player frames (one frame per pose is enough for now), enemy frames, solid, damaged and floor tiles, and the 15 treasures. Treasures can share one shape with different colors.
- `build.cmd`: run the converter, then the compiler. `build run` launches VICE.
- `src/video.p8`: VIC bank 3, `$D018`, multicolor modes, `MULTICOLOR` constant, color table, copying the charset and sprites to `$E000`/`$E800`, ROM font glyphs copied in for the HUD, `draw_tile(col, row)`, `draw_level()` from the tile map, HUD drawing.
- `src/input.p8`: joystick read with edge detection for fire and down. Scripted-input switch (see Verification).
- `src/main.p8`: hand-made test level in the tile map with every tile type, the HUD showing placeholder values, and the player sprite shown standing at the start position. Frame loop with `sys.waitvsync()`.

Done when:
- [x] Build from a clean `build/` works with one command and has no warnings from the converter.
- [x] Screenshot shows the test level: floor row, solid and damaged tiles, treasures, HUD row with SCORE/TIME/LEVEL, and the player sprite at top middle.
- [x] Changing one pixel in `assets/tiles.txt` and rebuilding changes the screen (proves the pipeline).
- [x] No `floats` import; program ends below `$C000` (check the 64tass output summary).

**Notes:**
- Program ends at `$140A` (code+data `$0801-$13E7`, BSS to `$1409`). No `floats` import.
- VICE screenshots: add `-autostartprgmode 1` (inject the PRG into RAM). Without it the emulated disk load takes over 8 s; with it the program is running by about 3,500,000 cycles.
- Charset layout: chars 0-63 = ROM screen codes 0-63 (HUD font: letters, digits, space, punctuation), copied from the character ROM with IRQs off. Tile chars start at 64 (`assets.TILE_FIRST_CHAR`), 4 per tile in TL, TR, BL, BR order. 19 tiles use chars 64-139.
- The empty tile is art too (`tile empty` in `assets/tiles.txt`, all blank), so empty cells draw through the same table as every other tile.
- Tile colors come from `tiles.txt` (`TILE_<NAME>_COLOR`). All other colors (border, background, shared multicolors, HUD, player, enemy, carry) are constants at the top of `video.p8`. `video.tile_char[]`/`tile_color[]` map tile values 0-30 to art; values 4-15 draw as empty.
- The tile map (`video.tiles` at `$C400`) and `row_start` live in `video.p8` for now.
- HUD numbers are printed from BCD nibbles (`video.hud_digits`), so time and level can be stored as BCD too and never need division. Phase 3 decides how the timer is stored.
- The player sprite is drawn with its left edge at `px = 152` (sprite spans 152-167, centred on 160). The 12 px collision box (phase 2) would then start at x = 154.
- `video.show_sprite` writes sprite registers directly. Phase 2 moves this into the frame IRQ.
- Scripted input: `input.SCRIPTED` plus the `input.script` table of (frames, bits) pairs. Bits are active-high: up 1, down 2, left 4, right 8, fire 16. Verified with a temporary HUD readout (held bits, fire-press count) that has been removed. `input.pressed` holds edges for all five bits.
- The compiler prints 3 "condition is always true/false" warnings. They come from the `const bool` switches (`MULTICOLOR`, `SCRIPTED`) and are expected. The converter prints no warnings.
- Converter errors are `file:line: message`, all reported in one run, and nothing is written on error. Checked: bad symbol, wrong row width, missing row, color > 7 in multicolor, duplicate name, `mode` that doesn't match `MULTICOLOR`.
- Placeholder art: one frame per pose (player run/jump/fall L+R, fast-fall, float; enemy walk/air L+R; 12 sprites). Left frames are mirrors of the right ones. Treasures are 3 shapes (coin, gem, cup) in 5 colors.

## Phase 2: Player physics
**Status:** done
**Spec:** §1 number rules, §4 actors and collision boxes, §5 (except hit/float and damage)

Build:
- `src/actors.p8`: position plus fraction movement, tile collision against the box (feet, head, sides), landing, walls and ceiling at screen edges.
- `src/player.p8`: states GROUNDED, RISING, FALLING, FASTFALL. Run, variable-height jump to 96 px, release-to-fall, head bump, walk off edges, fast-fall straight down, air control in the other air states. Facing direction and pose selection (placeholder frames).
- Frame IRQ replaces `sys.waitvsync()` (spec §1), with sprite registers written at the start of the frame.

Done when:
- [x] Scripted test: hold fire from standing → screenshot at apex shows the player 96 px above the start surface (±2 px).
- [x] Scripted test: tap fire → player rises only a little, then falls.
- [x] Scripted test: run off a platform edge → lands on the platform below.
- [x] Scripted test: jump, then press down while moving sideways → falls vertically.
- [x] Player never ends up inside a solid tile in any of the above.
- [x] Report lists feel items for the designer: run speed, jump arc, fast-fall speed.

**Notes:**
- Verified with a scripted-input build and a debug readout on the HUD row (`main.DEBUG_HUD`, same idea as `input.SCRIPTED`; both are `false` in the handed-over build). The readout shows box x/y, state, highest point of the last air trip, landing x/y, fast-fall start x, and a count of frames with the box overlapping a solid tile.
  - Full jump from the row-8 platform (y = 112), standing at the left wall: peak y = 16, so exactly 96 px.
  - Tap (fire held 3 frames): peak 7 px above the surface, then falls and lands.
  - Walking left off the row-5 platform: falls and lands on row 8 at y = 112.
  - Jump + right for 20 frames, then down+right: fast-fall starts and lands at the same x ($1F).
  - Head bump: jumping under the row-5 platform stops the head at its underside (y = 96), then falls.
  - Overlap counter stayed 0 in all runs.
- Fast-fall triggers while down is **held** in the air (designer decision): a fresh press in the air, or down held from before jumping or walking off an edge. Checked by script: walking off the row-5 edge with left+down held fast-falls straight onto row 8 (start x = landing x = $22); a jump with down held rises 2 px, then fast-falls. Once started, a fast-fall can't be cancelled; it ends on an intact platform or the floor (phase 3 adds breaking through damaged tiles, phase 5 the launch off a killed enemy).
- All speeds are unsigned magnitudes. Rising uses the constant rise speed and `rise_left`, so `vy` is never negative; `actors.advance(frac, speed)` returns whole pixels and leaves the new fraction in `actors.new_frac`.
- Box x is the collision box's left edge; the sprite is drawn at `x - 2`. Start box x = 154.
- Collision moves one axis at a time (horizontal first, then vertical) and checks the two box corners on the leading edge. Speeds stay under 16 px/f, so one tile boundary at most is crossed per step.
- Fast-fall landings are plain landings for now. Tile damage comes in phase 3.
- No coyote time or jump buffering: fire must be pressed while grounded.
- Frame IRQ: `sys.set_rasterirq` at raster line 251 (top of the bottom border). It copies the sprite shadows (`video.spr_*`) to the VIC, sets `video.frame_ready`, and chains to the KERNAL IRQ once per frame. `set_rasterirq` turns off the CIA1 timer IRQ, so the KERNAL routine (keyboard scan, jiffy clock) now runs only from the raster IRQ, at 50 Hz.
- Program ends at `$1ACF`.
- Feel items for the designer: see the phase report (run speed 1.5 px/f, rise 2.5 px/f, gravity 4, max fall 4 px/f, fast-fall 6 px/f, all in `player.p8`).

## Phase 3: Platform damage, treasures, score and timer
**Status:** not started
**Spec:** §4 tile values, §5 landing and treasure rules, §8

Build:
- Fast-fall landing damages the tile under the box centre. A damaged tile is destroyed and the player keeps fast-falling. Floor is immune.
- Treasure pickup, score in BCD via `bcd.addl`, HUD updates only the changed digits.
- Timer counting down from 60. Reaching 0 freezes the game with a "GAME OVER" placeholder.
- 10 treasures collected → "LEVEL COMPLETE" placeholder, then reload the same test level with +60 s.

Done when:
- [ ] Scripted test: two fast-falls on the same tile → damaged after the first, gone after the second, player drops through.
- [ ] Scripted test: walking over a treasure adds the right points and removes it.
- [ ] Timer screenshot after N seconds shows 60 - N.
- [ ] Score display correct after passing 999 and 9999 (BCD carry).

## Phase 4: Level generator
**Status:** not started
**Spec:** §7

Build:
- `src/levelgen.p8`: bands, platform segments, jitter, enemy-climbable spots, reachability BFS, retries, fallback layout, treasure placement, RNG seeding.
- Debug key (e.g. F1) regenerates the level instantly. Remove it or put it behind a switch at the end of the phase.

Done when:
- [ ] 10 consecutive generated levels (screenshots with different seeds) all have: full floor, clear spawn zone, 10 treasures on standing cells, no two treasures within 3 tiles.
- [ ] Generation time measured (raster or frame count) and noted. Must finish within 50 frames.
- [ ] A forced-failure test reaches the fallback layout without hanging.

## Phase 5: Enemies
**Status:** not started
**Spec:** §4 actors, §5 hit and float, §6 (except treasure carrying)

Build:
- `src/enemies.p8`: 5 enemies on sprites 1-5, shared physics, 64 px jump, AI from §6 (decisions every 8 frames), speed scaling by level.
- Contact rules in order: kill (fast-fall), stomp (bounce 24 px), hit.
- Kill: launch 32 px, chain scoring `200 << chain`, chain reset on landing, respawn timer and placement rules.
- Hit: -10 s, straight-line FLOATING to start at 4 px/f, 2 s invulnerability with flicker.

Done when:
- [ ] Screenshot: 5 enemies spawned ≥ 8 tiles from the player start.
- [ ] Scripted test: fast-fall onto an enemy → enemy gone, +200, player launched.
- [ ] Scripted test: normal fall onto an enemy → bounce, enemy survives, no points.
- [ ] Scripted test: walking into an enemy → time -10, player floats back, then flickers.
- [ ] Frame budget holds with 5 enemies: no slowdown (measure with border color timing; note the result).

## Phase 6: Treasure carrying
**Status:** not started
**Spec:** §6 treasure handling

Build:
- Enemy pickup (color change), drop on stomp or kill, dropped treasure falls one tile every 4 frames until it rests.
- Level completion still counts only treasures the player collects.

Done when:
- [ ] Screenshot: an enemy that walked over a treasure has the carry color and the treasure tile is gone.
- [ ] Scripted test: stomp a carrier → treasure reappears and settles on a platform.
- [ ] A treasure dropped where the cell is occupied lands in the nearest free cell above.

## Phase 7: Game flow and difficulty
**Status:** not started
**Spec:** §8 bonus, §9

Build:
- States TITLE, NEW_GAME, LEVEL_START, PLAYING, LEVEL_COMPLETE, GAME_OVER.
- Title screen (seeds RNG on fire), dissolve transition (~8 tiles/frame), player floats to start while the next level generates, timer paused during transitions.
- No-kill bonus +2500, level counter, enemy speed and respawn scaling.

Done when:
- [ ] Full loop works: title → play → complete level → next level → time runs out → game over → title.
- [ ] Two games started at different moments get different first levels.
- [ ] Bonus awarded only when no enemy was destroyed during the level.

## Phase 8: Art, animation and sound
**Status:** not started
**Spec:** §10 asset table, §13 resolved (sound)

Build:
- Full frame sets from §10 with animation timing (placeholder or designer-provided art).
- Basic SID effects: jump, land/damage, collect, kill, hit, level complete. One voice, table-driven, stepped by the frame IRQ.
- Remove or disable all debug switches.

Done when:
- [ ] All poses from §10 appear in the right states (screenshot set).
- [ ] Each sound effect triggers on its event (designer checks by ear).
- [ ] Release build has no debug keys and no scripted input.
