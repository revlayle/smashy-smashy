# Build phases

Implementation plan for `docs/spec.md`. Work one phase at a time, in order. Each phase ends with a build the designer can play in VICE.

## How to work a phase

1. Read `CLAUDE.md`, then `docs/spec.md` (the whole thing once; afterwards the sections the phase names).
2. Pick the first phase whose status is not `done`. Set it to `in progress`.
3. Implement only that phase's scope. Things the spec defers to later phases stay out.
4. Verify every "Done when" item (see **Verification** below). Fix until all pass.
5. Set the status to `done`. Under the phase, add a short **Notes** list: deviations from the spec, tuned values, known issues. If a decision changed, update `docs/spec.md` too.
6. Stop and report to the designer. Don't start the next phase without their go-ahead; they will want to play each build.
7. When the designer approves the phase, commit it on `main` with a message like `Phase N: <title>`, summarizing what was built. Don't commit before approval. If a phase goes badly, `git diff` and `git restore` against the last phase commit are the way back.

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
**Status:** done
**Spec:** §4 tile values, §5 landing and treasure rules, §8

Build:
- Fast-fall landing damages the tile under the box centre. A damaged tile is destroyed and the player keeps fast-falling. Floor is immune.
- Treasure pickup, score in BCD via `bcd.addl`, HUD updates only the changed digits.
- Timer counting down from 60. Reaching 0 freezes the game with a "GAME OVER" placeholder.
- 10 treasures collected → "LEVEL COMPLETE" placeholder, then reload the same test level with +60 s.

Done when:
- [x] Scripted test: two fast-falls on the same tile → damaged after the first, gone after the second, player drops through.
- [x] Scripted test: walking over a treasure adds the right points and removes it.
- [x] Timer screenshot after N seconds shows 60 - N.
- [x] Score display correct after passing 999 and 9999 (BCD carry).

**Notes:**
- New `src/score.p8`: BCD score (`long`, `bcd.addl`), timer as BCD seconds (`uword`) plus a 50-frame counter, and `treasures_left`. Treasure points come from a BCD table (`$0100`-`$1500`).
- HUD: score and time are redrawn only when they change, and `video.hud_digits` writes only digits that differ from the screen.
- Verified with scripted input (switch off again in the handed-over build):
  - Fall onto row 5, walk right to column 13, then fire+down twice (rises 2 px, fast-falls). After the first fast-fall the tile shows damaged and the player stands on it. After the second it is gone and the player drops to row 10, damaging that tile on landing.
  - The same walk collects treasures 6 and 7 from row 4: score 000700, then 001500 (carry past 999). Both tiles are cleared.
  - Timer: screenshots 10 s and 30 s after start show 050 and 030.
  - Temporary build with the start score at 9300: landing on treasure 6 shows 010000 (carry past 9999 into the third BCD byte).
  - Temporary build with 1 treasure per level: LEVEL COMPLETE shows, then the level reloads with time 060 + 60 = 120 and the score kept.
  - Temporary build with a 3 s timer: time reaches 000 and the game freezes with GAME OVER.
- Placeholders: messages are hi-res text at char row 7 (`video.message`). Level complete waits 100 frames (timer paused), then reloads `main.test_level` and puts the player back at the start in `FALLING`. Game over loops forever. The level number stays 01 until phase 7.
- Designer decisions after the first review (spec §5 updated):
  - Destroying a tile snaps the box to the centre of the hole so the fast-fall continues. This fixes landing on the edge of the neighbouring tile when straddling two tiles.
  - Target highlight: while airborne, the tile a fast-fall would damage is recoloured white (`video.TARGET_COLOR`, colour RAM only). Checked by script: a short jump from row 5, straddling columns 9-10, shows column 10 highlighted. A fast-fall destroys it and snaps into the hole, and the highlight moves to row 10 column 10. That tile is drilled too, treasure n is collected on the way (+1400), and the player lands on the floor centred in column 10. The highlight is removed on landing. The two-fast-fall test was re-run with the same result.
  - The highlight costs a column scan per frame (at most 11 rows, 2 columns) and redraws only when the target changes.
- Keyboard play in VICE: `tools/vicerc` maps the arrow keys and left Ctrl to joystick port 2 (keyset 1). `build run` loads it with `-config` and injects the PRG (`-autostartprgmode 1`). The game still reads only the joystick.
- Tile changes are drawn immediately with `draw_tile` rather than queued (at most 2 per frame).
- The timer starts with the frame loop and counts the first second after 50 frames.
- Score format changed after the phase was approved (one-off change): the score is now a BCD `uword` in hundreds (`bcd.adduw`, no `long`), shown with a fixed "00" and clamped at 999900. The treasure table is `$01`-`$15`. The notes above describe the original `long` version. Re-verified by script: treasure 6 → 000700; start 009300 + a 1500 treasure → 010800; start 999500 + a 1500 treasure → 999900 (clamped). Code+data is now `$0801-$1F8D`.
- Code+data `$0801-$1FEC`, BSS just after. No `floats` import. The compiler warnings are the 5 expected `const bool` ones.

## Phase 4: Level generator
**Status:** done
**Spec:** §7

Build:
- `src/levelgen.p8`: bands, platform segments, jitter, enemy-climbable spots, reachability BFS, retries, fallback layout, treasure placement, RNG seeding.
- Debug key (e.g. F1) regenerates the level instantly. Remove it or put it behind a switch at the end of the phase.

Done when:
- [x] 10 consecutive generated levels (screenshots with different seeds) all have: full floor, clear spawn zone, 10 treasures on standing cells, no two treasures within 3 tiles.
- [x] Generation time measured (raster or frame count) and noted. Must finish within 50 frames.
- [x] A forced-failure test reaches the fallback layout without hanging.

**Notes:**
- `src/levelgen.p8`: `init()` once, `seed()`, `generate(level)` fills `video.tiles` (does not draw). The level is built as a segment list per band, then written to the tile map. An attempt fails on band connectivity (spec §7 rule 3), fewer than 30 reachable standing cells, or fewer than 10 treasures placed. After 10 failures it uses a fixed fallback layout (a segment table shaped like the phase 3 test level) and places treasures the same way.
- The hand-made test level is gone from `main.p8`. Every level load and the level-complete placeholder now generate a new level (level number 1 for treasure types until phase 7).
- Verified with self-test switches in `main.p8`, all `false` in the handed-over build:
  - `GEN_STATS`: after each generation the HUD shows attempts (hex, +$80 = fallback), a `check_level()` result and the time in frames. `check_level()` checks: full floor, clear spawn zone, exactly 10 treasures, each on a standing cell and reachable, pairwise spacing, none on the start landing cell.
  - `GEN_SOAK`: generates 200 levels at startup and shows fallbacks, most attempts, check failures and slowest time. Result: 0 fallbacks, at most 4-5 attempts, 0 failures, slowest 8-9 frames.
  - 10 screenshots from 10 fixed seeds (temporary builds): all pass `check_level()`, 1-2 attempts, 4-5 frames each. Spawn zone and floor checked by eye too.
  - `levelgen.FORCE_FAIL`: every attempt fails, so all 10 run in full and then the fallback. It ends with the fallback drawn, check result 0, in 40 frames (the worst case).
  - A temporary reference BFS without the speed shortcuts (below) gave the same reachable set as `explore()` on 200 levels.
- Timing (jiffy clock, 1 tick per frame through the frame IRQ): typical generation 4-9 frames, worst case 40. The first version took 120 frames in the worst case. Fixes:
  - `rand_below()`: mask-and-retry on `math.rnd()`. `math.randrange()` does a 16-bit multiply (about 500 cycles).
  - Standing cells are marked from the segment list instead of a scan of all 220 cells.
  - Jump search shortcuts: a side isn't scanned while the neighbouring standing cell on that side has an equally clear column (its own jump covers the same targets). Rows with no standing cells aren't scanned, except for k = 1.
  - Treasures: a walk through the reachable list from a random start with a random prime stride, then a plain scan. A placed treasure blocks the 5x5 cells around it, so the spacing check is one byte read.
- Jump model in the BFS: rise straight up, then up to 3 columns sideways along the top row (spec §7). It is conservative: it can miss a diagonal jump the player could make, but never accepts an impossible one.
- Treasure spacing is read as `|dcol| >= 3` or `|drow| >= 3`, so no other treasure is in the 5x5 square around one.
- Added (not in the spec before, now in §7): no treasure on the cell where the player lands from the spawn point. Without this, the first test runs sometimes gave a free treasure on arrival.
- Designer confirmed: the landing-cell rule, the 5x5 spacing reading, the jump model, and seeding at startup until phase 7.
- Debug key F1 (`main.REGEN_KEY`, read with `cbm.GETIN2()`) generates a new level at once and keeps the score and timer. It is **on** in the handed-over build so the designer can browse levels. Checked with VICE `-keybuf` and a fixed seed: F1 changes the level; another key and a repeat run don't. Phase 8 removes it.
- The RNG is seeded at startup from the CIA1 timer and raster line (placeholder until the title screen). Each VICE start can give a different first level.
- Generator buffers are normal arrays in program RAM (about 1.1 KB of BSS), not the `$C400` game RAM area. Code+data `$0801-$2917`, BSS to `$2DD9`. No `floats` import. The compiler prints 8 "condition is always true/false" warnings, all from `const bool` switches.

## Phase 5a: Enemies with simple AI
**Status:** not started
**Spec:** §4 actors, §5 hit and float, §6 (contact, movement, simple AI, respawn; not navigation AI or treasure handling)

Build:
- `src/enemies.p8`: 5 enemies on sprites 1-5, shared physics, 64 px jump, the **simple AI** from §6 (decisions every 8 frames, staggered), speed scaling by level. Keep the AI behind a small interface (e.g. `ai_decide(i)` setting a walk direction and a jump request) so phase 5b can replace it without touching movement or contact code.
- Contact rules in order: kill (fast-fall), stomp (bounce 24 px), hit.
- Kill: launch 32 px, chain scoring 2, 4, 8, 16, 32 hundred (spec §8), chain reset on landing, respawn timer and placement rules.
- Hit: -10 s, straight-line FLOATING to start at 4 px/f, 2 s invulnerability with flicker.
- Respawn with 1 s warning flicker (inactive, no contact). Unlimited bonks.

Done when:
- [ ] Screenshot: 5 enemies spawned ≥ 8 tiles from the player start.
- [ ] Scripted test: fast-fall onto an enemy → enemy gone, +200, player launched.
- [ ] Scripted test: normal fall onto an enemy → bounce, enemy survives, no points.
- [ ] Scripted test: walking into an enemy → time -10, player floats back, then flickers.
- [ ] Scripted test: jumping up into an enemy from below → hit.
- [ ] Scripted test: a respawning enemy flickers for 1 s and the player can pass through it without any contact result.
- [ ] Frame budget holds with 5 enemies: no slowdown. Measure the worst frame in raster lines (read the raster line at the start and end of the frame update, keep the maximum, show it on the HUD in a test build) and note it. The pre-phase-5 baseline was 58 lines.

## Phase 5b: Navigation AI
**Status:** not started
**Spec:** §6 navigation AI (not the carrier role; that is phase 6)

Build:
- `src/nav.p8`: platform map (`platform_of`, links, `next_link`, `hops`), built after level generation. Time-sliced rebuild into a second table set when a tile is destroyed, then swapped in.
- Replace the simple AI with the navigation AI: route following, take-off and jump execution with the 60-frame timeout, wandering when there's no route, level-scaled mistakes.
- Roles by slot: chasers, ambusher, hunters.
- Debug view (behind a `const bool` switch): show each enemy's current platform and target platform as hex on the HUD row, or recolour the target platform's tiles.

Done when:
- [ ] Platform map check on 20 generated levels: every link is valid when replayed by the physics (a test build makes one enemy walk each link in turn and checks it lands on the expected platform). Note any failures and fix the link rules.
- [ ] Scripted test: player waits on an upper platform → a chaser on a lower band reaches the player's platform by a jump route, not by wandering.
- [ ] Scripted test: player drills a hole that cuts a route → the map is rebuilt and enemies take the new route. No dropped frame during the rebuild (worst-frame raster measure).
- [ ] Worst frame with 5 enemies stays under 250 raster lines; note the number.
- [ ] Report lists feel items for the designer: how threatening enemies feel, mistake rate, decision interval.

## Phase 6: Treasure carrying
**Status:** not started
**Spec:** §6 treasure handling and carrier role

Build:
- Enemy pickup (color change), drop on stomp or kill, dropped treasure falls one tile every 4 frames until it rests.
- Carrier role: hideout choice by `hops`, re-plan rules, never routes onto the player's platform, return to slot role after losing the treasure. 3 s pickup cooldown after losing a treasure.
- Level completion still counts only treasures the player collects.

Done when:
- [ ] Screenshot: an enemy that walked over a treasure has the carry color and the treasure tile is gone.
- [ ] Scripted test: stomp a carrier → treasure reappears and settles on a platform.
- [ ] A treasure dropped where the cell is occupied lands in the nearest free cell above.
- [ ] Scripted test: player approaches a carrier → the carrier moves away (its `hops` from the player's platform goes up, or it leaves the player's platform).
- [ ] Scripted test: bonk a carrier → it does not re-take the dropped treasure within 3 s.
- [ ] Report lists feel items for the designer: is a carrier catchable, how long a chase takes.

## Phase 7: Game flow and difficulty
**Status:** not started
**Spec:** §8 bonus, §9

Build:
- States TITLE, NEW_GAME, LEVEL_START, PLAYING, LEVEL_COMPLETE, GAME_OVER.
- Title screen (seeds RNG on fire), dissolve transition (~8 tiles/frame), player floats to start while the next level generates, timer paused during transitions.
- No-kill bonus +2500, level counter, enemy speed and respawn scaling.
- Pause on Run/Stop (toggle, timer frozen, "PAUSED" shown).
- Session high score: updated at game over, shown on title and game-over screens.

Done when:
- [ ] Full loop works: title → play → complete level → next level → time runs out → game over → title.
- [ ] Two games started at different moments get different first levels.
- [ ] Bonus awarded only when no enemy was destroyed during the level.
- [ ] Pause freezes the game and timer, and resumes cleanly (scripted key press via VICE `-keybuf` or a test switch).
- [ ] A second game shows the first game's score as the high score on the title screen.

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
