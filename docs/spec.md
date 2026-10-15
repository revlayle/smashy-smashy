# Technical spec: C64 single-screen platformer

Source design: `platformer-game.txt`. This document turns it into implementation decisions for Prog8 12.3.4 on a PAL C64.
Items marked **[DECIDE]** are proposals waiting for the designer's confirmation. Items marked **[TUNE]** are starting values expected to change after playtesting.

---

## 1. Platform and timing

- Target: PAL C64, 50 frames/s, Prog8 `-target c64`, 64tass. NTSC is not a goal (timer and speeds would run 20% fast).
- One game update per frame. Frame sync: a raster IRQ at line 251 (bottom border) copies the sprite shadow registers to the VIC and sets a `frame_ready` flag; the main loop waits on it.
- Per-frame order: wait for frame → write sprite registers from state computed last frame → read joystick → update player → update enemies → resolve collisions → apply queued tile changes to screen → update HUD (only changed digits).
- Frame budget is roughly 18,000 CPU cycles. If it overruns, enemy AI decisions (not movement) run on alternating frames, e.g. enemies 1,3,5 on even frames and 2,4 on odd.
- 1 second = 50 frames. All timers count frames or seconds as integers.

### Number rules
- **No floating point anywhere.** Do not `%import floats`. Besides being very slow, using floats keeps the BASIC ROM banked in and costs 8 KB of program RAM.
- Prefer `ubyte`/`byte`. Use `uword` only where a value can exceed 255, such as the player's x pixel (0-319). Use `long` only for the BCD score.
- Multiply and divide only by powers of two (shifts), or use lookup tables. No general `*` or `/` in per-frame code.
- **Speeds are signed bytes in 1/16-pixel steps** ("subpixels"): 24 means 1.5 px per frame. Each actor stores its position as a whole-pixel coordinate plus a `ubyte` fraction (0-15). Each frame: `frac += speed`, carry `frac >> 4` into the pixel coordinate, keep `frac & 15`. Tile lookups then use the pixel coordinate directly, with no 16-bit shifting of a combined value.

## 2. Screen layout

```
char row 0        HUD: SCORE 000000   TIME 060   LEVEL 01
char rows 1-24    playfield: 20 x 12 tiles, each tile 2x2 chars (16x16 px)
tile row 11       indestructible floor (char rows 23-24)
```

- Playfield is 320 x 192 px, in playfield coordinates `px 0..319`, `py 0..191`. `(0,0)` is the top-left of tile `(0,0)` at char row 1.
- Hardware sprite position for an object at `(px, py)`: `sprite_x = px + 24`, `sprite_y = py + 50 + 8` (the +8 is the HUD row).
- Player start: tile column 9.5 (centred, `px = 152`), `py = 0`, regardless of what is below.

### Graphics modes
- **Characters: multicolor character mode** ($D016 bit 4). Shared colors: background $D021, MC1 $D022, MC2 $D023. Color RAM values 8-15 make a cell multicolor; 0-7 make it hi-res. So HUD text stays crisp hi-res while tiles get 4 colors. The trade-off: each multicolor tile's own color is limited to the 8 colors 0-7.
- **Sprites: multicolor sprites** ($D01C), shared colors $D025/$D026, one own color each. Artwork is 16x16 inside the 24x21 sprite frame, top-left aligned. Multicolor pixels are double width, so a 16 px wide figure is 8 fat pixels across.
- **Multicolor first, hi-res may come later.** Keep the switch cheap: one `const bool MULTICOLOR` in `video.p8` controls $D016 bit 4, $D01C and the color RAM values written for tiles. All colors live in one table in `video.p8`. The art files declare their mode, and the converter (§10) rejects art that doesn't match. Switching modes means redrawing the art; no game logic changes.

## 3. Memory map

The VIC-II is moved to **bank 3 ($C000-$FFFF)** so the program gets one contiguous block of RAM and the graphics live outside it.

| Range | Use |
|---|---|
| `$0002-$00FF` | Zero page: KERNAL plus Prog8 variables (`%zeropage basicsafe` while developing; may switch to `kernalsafe` for more ZP) |
| `$0801-$BFFF` | Prog8 program: code, tables, asset source data. `%memtop $C000`. Prog8 banks BASIC ROM out, so this is ~46 KB |
| `$C000-$C3E7` | Screen matrix (1000 bytes) |
| `$C3F8-$C3FF` | Sprite pointers |
| `$C400-$CFDF` | Game RAM: tile map, enemy and treasure tables, misc buffers (memory-mapped `&ubyte[...] name = $C4xx`) |
| `$CFE0-$CFFF` | **Reserved by Prog8** for virtual registers R0-R15. Do not touch |
| `$D000-$DFFF` | I/O |
| `$E000-$E7FF` | Charset (256 chars), in RAM under KERNAL ROM |
| `$E800-$FFBF` | Sprite frames: 95 frames available (pointer values 160-254, = (addr - $C000) / 64). The last 64 bytes are skipped because they overlap the CPU vectors |

Notes:
- The VIC sees RAM at `$E000-$FFFF` even with KERNAL ROM banked in, and CPU *writes* there always go to RAM. So the charset and sprites are copied there once at startup with no ROM banking. They are included in the program with `%asmbinary` and copied from there.
- Register setup: `$DD00` bits 0-1 = `%00` (bank 3), `$D018 = $08` (screen at +$0000, charset at +$2000), `$0288 = $C0` (KERNAL screen editor page, only matters if KERNAL text output is used).
- **Prog8's `txt.setchr`/`txt.plot`-based routines are hard-wired to `$0400`** and must not be used after the switch. The game draws tiles and HUD through its own pointer routines (`^^ubyte @zp` into `$C000` and color RAM `$D800`).
- KERNAL stays banked in and its IRQ keeps running (keyboard scan, harmless). The frame IRQ chains to it.

## 4. Data structures

### Tile map
`&ubyte[240] tiles = $C400`: 20 x 12, index `row * 20 + col`. One byte per tile:

| Value | Meaning |
|---|---|
| 0 | empty |
| 1 | solid platform |
| 2 | damaged platform |
| 3 | indestructible floor |
| 16 + t | treasure of type `t` (0-14), not solid |

Helper: `tile_at(px, py) = tiles[row_start[py >> 4] + (px >> 4)]`, where `row_start` is a 12-entry `ubyte` table (0, 20, 40, ... 220) so no multiply is needed. Row 11 is always 3. Out-of-bounds left/right/top read as solid (walls and ceiling).

Each tile type maps to 4 char codes (top-left, top-right, bottom-left, bottom-right) and a color. Drawing a tile writes 4 screen bytes and 4 color RAM bytes.

### Actors
Player and enemies share one layout in parallel arrays (index 0 = player, 1-5 = enemies), so the same movement and collision code serves both:

```
uword[6] x               ; pixel x of the box's top-left, 0-319 (needs 9 bits)
ubyte[6] y               ; pixel y, 0-191
ubyte[6] x_frac, y_frac  ; 1/16-pixel fractions, 0-15
byte[6]  vy              ; vertical speed in 1/16 px per frame, + = down (range -128..127 covers all speeds)
ubyte[6] state, facing, anim_frame, anim_timer
```
Enemy-only: `carrying` (0 = none, else 1 + treasure type), `respawn_timer` (`ubyte` seconds plus a frame subcounter).
Player-only: `rise_left` (`ubyte` pixels of jump height left, starts at 96), `chain` (fast-fall kills this airborne trip), `invuln_timer` (frames).

### Collision boxes
- Player and enemies: 12 x 16 box, inset 2 px left and right of the 16 x 16 sprite. This gives 2 px of slack per side, so the player can drop through a 1-tile (16 px) hole without pixel-perfect alignment.
- All actor-vs-actor checks are box overlap math in software. Hardware sprite collision registers are not used.

## 5. Player

### States
`GROUNDED` (idle/run), `RISING`, `FALLING`, `FASTFALL`, `LAUNCHED`, `FLOATING`.

### Movement [TUNE]
| Parameter | Value |
|---|---|
| Run speed | 24 subpx/f (1.5 px/f, ~4.3 s across the screen) |
| Rise speed | 40 subpx/f (2.5 px/f, constant; a full 96 px rise takes ~38 frames, 0.77 s) |
| Max jump height | 96 px = 6 tiles; reliably climbs a 5-tile step (`rise_left` counts down in whole pixels) |
| Gravity | 4 subpx/f² |
| Max normal fall | 64 subpx/f (4 px/f) |
| Fast-fall speed | 96 subpx/f (6 px/f), set instantly |
| Kill launch | 32 px up, same rise speed |
| Stomp bounce | 24 px up |

Max speed stays under 16 px/f, so collision never tunnels through a tile.

### Rules
- **Jump:** fire is edge-triggered (it must be released between jumps). While `RISING` and fire is held, rise at constant speed until `rise_left` hits 0. Release or apex → `FALLING` (vy = 0, gravity applies). Hitting a solid tile with the head → `FALLING`.
- **Fall off an edge:** `GROUNDED` with no solid tile under the box → `FALLING`.
- **Fast-fall:** joystick down held while `RISING`, `FALLING` or `LAUNCHED` → `FASTFALL`, vy = 96. Holding down from before a jump or a walk off an edge counts. Fire is ignored once descending. A fast-fall can't be cancelled: it ends only by landing on an intact platform or the floor (then normal ground control returns) or by killing an enemy (→ `LAUNCHED`, with air control).
- **Air control:** full left/right control in the air at run speed while rising, falling or launched. **Fast-fall drops straight down:** no horizontal movement until it ends. Aiming is done before pressing down.
- **Landing in `FASTFALL`:** damage the tile under the box's centre (1 → 2). If it is already damaged (2 → 0, destroyed), the player keeps fast-falling through the hole. The first hit on an intact tile is a normal landing (fast-fall ends).
- **Landing in any state:** chain = 0.
- **Floor (3)** takes no damage.
- **Treasure:** box overlaps a treasure tile → collect: score, clear the tile, `treasures_left -= 1`.

### Hit and float
- Touching an enemy, other than the stomp/kill cases below, while not invulnerable → hit: `time -= 10 s`, state `FLOATING`.
- `FLOATING`: fly in a straight line to the start point, ignoring tiles, enemies and input. Moves 4 px/f along the longer axis. The shorter axis is stepped with a Bresenham-style integer error counter (no division), so the path is a true straight line. The farthest possible trip (176 px vertical) takes 44 frames, under 1 s. Treasures already collected stay collected. **[TUNE]**
- On arrival → `FALLING`, `invuln_timer = 100` frames (2 s), sprite flickers while invulnerable.
- The timer keeps running while floating after a hit; the lost float time is part of the penalty.

## 6. Enemies

### Contact with the player (checked in this order)
1. Player in `FASTFALL`, player's bottom edge in the top half of the enemy box → **kill**: enemy destroyed, any carried treasure dropped, score `200 << chain`, `chain += 1` (max 4), player → `LAUNCHED` 32 px.
2. Player falling (vy > 0, not fast-fall) with the same geometry → **stomp**: carried treasure dropped, player bounces 24 px. Enemy survives. No score.
3. Otherwise → player is hit (unless invulnerable or floating).

### Movement
- Same physics routine as the player, minus fast-fall.
- Speed per level: `enemy_speed = min(12 + (level - 1), 22)` subpx/f, i.e. 50% of the player at level 1, reaching the 91.7% cap (the closest step under 95%) at level 11. **[TUNE]**
- Jump: constant rise at the player's rise speed, max 64 px (4 tiles), so an enemy reliably climbs a step of up to 3 tiles. That covers the normal 3-tile gap between platform bands.

### AI (decisions at most every 8 frames per enemy) [TUNE]
1. Not carrying, and a treasure on the same tile row within 5 tiles with nothing solid in between → walk to it.
2. Else chase the player:
   - Player on the same row → walk toward the player.
   - Player lower → walk toward the player and deliberately walk off edges.
   - Player higher → if a solid tile 1-3 tiles up is reachable within 2 columns ahead, jump; otherwise walk toward the nearest platform end and wander.
3. A wall ahead → turn around, or jump if the step is ≤ 3 tiles.

### Treasure handling
- Not carrying and the box overlaps a treasure tile → pick it up (tile cleared, `carrying = 1 + type`). Shown by a color change: a carrying enemy uses `ENEMY_CARRY_COLOR` instead of `ENEMY_COLOR` (sprite color register $D027+n). No extra frames.
- Dropping: the treasure is placed in the tile at the enemy's centre, or the nearest empty tile above it, then falls one tile every 4 frames until it rests on a solid tile.

### Respawn
- Destroyed enemy → `respawn_timer = max(10 - (level - 1), 3)` seconds. **[TUNE]**
- Respawn location: a random empty tile standing on a solid tile, at least 8 tiles (Manhattan) from the player. Up to 20 tries, then the farthest valid candidate.

## 7. Level generation

Grid is 20 x 12. Row 11 = floor. The spawn zone (columns 8-11, rows 0-1) is kept clear.

### Platform layout
1. Shelf bands at base rows 2, 5 and 8 (3 tiles apart), each platform jittered ±1 row. The worst case after jitter is a 5-tile gap, which the player's 96 px jump still clears. Enemies (3-tile climb) can use every un-jittered gap, so they can always work their way upward somewhere unless the player drills the route away (intended: trapping enemies below is a strategy).
2. Each band gets 2-4 platform segments, 3-8 tiles long, with gaps of 2+ tiles so the player can jump up through them.
3. Each band must contain at least one platform within 3 tiles above some platform in the band below (horizontally within 3 columns), so enemies have a way up. No stair ledges needed.

### Validation
- BFS over "standing cells" (empty cell with solid/damaged/floor below), starting from where the player lands below the spawn point. Edges: walk left/right, fall off edges (falls straight down), jump (up to 5 tiles up, landing within 3 columns).
- Regenerate if fewer than 30 standing cells are reachable, or if any treasure cell is unreachable. After 10 failures, use a fixed fallback layout.
- Drilling makes everything below the player reachable anyway. Validation guarantees the player can also get back up.

### Treasures
- 10 per level, each on a standing cell, at least 3 tiles from any other treasure, not in the spawn zone.
- Type choice: `t = min(14, (level - 1) + randrange(5))`. Early levels give 100-500 pts, and values climb by level. From level 11 on, every treasure is the top type.
- Optional later: 1-2 treasures enclosed by platforms, reachable only by drilling ("drill pockets"), as hinted in the design.

### Enemies at level start
5 enemies on random standing cells ≥ 8 tiles from the player start, at least 3 tiles apart.

### RNG
`math.rnd()` / `math.randrange()`. Seeded once with `math.rndseed()` from the CIA1 timer and raster line at the moment fire is pressed on the title screen.

## 8. Scoring and timer

- Score: 6 decimal digits stored as BCD in a `long` and updated with `bcd.addl()`. The HUD prints each nibble as a digit, so no division is needed.
- Treasure type `t` = `(t + 1) * 100` points (100-1500).
- Fast-fall kill = `200 << chain` → 200, 400, 800, 1600, 3200 in one airborne trip. The chain resets on landing.
- No-kill bonus: 2500 when a level is completed with 0 enemies destroyed.
- Timer: seconds plus a 50-frame subcounter. Starts at 60. +60 on level completion (carried over). -10 per hit, clamped at 0. 0 → game over. Shown as 3 digits.
- Timer paused during: level-complete dissolve and float, new-level draw.

## 9. Game flow

```
TITLE --fire--> NEW_GAME --> LEVEL_START --> PLAYING
PLAYING --10 treasures--> LEVEL_COMPLETE --> LEVEL_START (level+1, +60 s)
PLAYING --time 0--> GAME_OVER --fire--> TITLE
```
- **TITLE**: minimal "press fire" screen, needed to seed the RNG and to restart. Not in the design doc; can stay bare.
- **LEVEL_START**: generate, draw the level, place enemies, player at start in `FALLING`.
- **LEVEL_COMPLETE**: enemies vanish. Non-floor tiles are erased in random order, ~8 tiles per frame (about 1 s). The player floats to the start. The next level is generated during the float.
- **GAME_OVER**: show the final score and level reached; fire → TITLE.

## 10. Assets

Sprite frames (16x16 art in 24x21 frames). Counts are a starting point; placeholder art may use fewer:

| Set | Frames |
|---|---|
| Player run L / R | 4 + 4 |
| Player jump L / R | 1 + 1 |
| Player fall L / R | 1 + 1 |
| Player fast-fall (front) | 1 |
| Player float (front) | 2 |
| Enemy walk L / R | 3 + 3 |
| Enemy air L / R | 1 + 1 |
| **Total** | 23 (of 95 available) |

Charset (2x2 chars per tile):
- Solid, damaged and floor platform: 12 chars
- 15 treasures: 60 chars
- HUD font: digits plus the needed letters, ~36 chars, copied from the character ROM at startup (no art needed)
- Dissolve effect frames (optional): 4-8 chars

That is about 120 of 256 chars.

### Asset pipeline: editable text art

All art lives in plain text files that can be edited in any text editor. A converter turns them into binary data at build time. Claude makes placeholder art first; the designer can redraw any frame by editing characters in the file.

- `assets/sprites.txt` and `assets/tiles.txt`. Each entry has a name line, then the pixel rows:
  ```
  mode multicolor          ; or: mode hires (must match MULTICOLOR)
  colors . bg  1 own  2 mc1  3 mc2

  sprite player_run_r_0
  ..2222..
  .222222.
  ...      (16 rows; 8 fat pixels wide in multicolor, 16 in hi-res)

  tile solid color 5
  33333333
  ...      (16 rows; same widths as sprites)
  ```
  The symbols are `.` = background or transparent, `1` = own color (the sprite's or tile's color), `2` and `3` = the two shared multicolor colors. Hi-res uses only `.` and `1`.
- `tools/gfx.py` (Python 3, already installed) converts them:
  - `build/sprites.bin`: 64 bytes per frame, copied to `$E800+` at startup.
  - `build/chars.bin`: each tile split into its 4 chars.
  - `src/gen_assets.p8`: generated constants such as `const ubyte SPR_PLAYER_RUN_R_0 = 160` and `const ubyte TILE_SOLID_TL = ...`, plus the tile color table. Code refers to art only by these names, so adding, removing or reordering art never breaks the code.
- Charset layout: chars 0-63 are ROM screen codes 0-63 (the HUD font), tile chars start at 64. `assets/tiles.txt` also defines `tile empty` (blank), so every tile value draws through the same table.
- Tile colors are set per tile in `tiles.txt`. Every other color is a constant in `video.p8`.
- `build.cmd` runs the converter before the compiler.
- Later, real art from SpritePad or CharPad can replace a text file by exporting `.bin` files. The name list would then move to a small hand-written file.

## 11. Source layout

```
src/main.p8        entry, state machine, frame loop
src/video.p8       VIC bank setup, IRQ, tile drawing, HUD, sprite register writes
src/input.p8       joystick read and edge detection
src/actors.p8      shared physics and tile collision
src/player.p8      player states
src/enemies.p8     enemy AI, respawn, treasure carry/drop
src/levelgen.p8    generation and validation
src/score.p8       BCD score, timer
src/gen_assets.p8  GENERATED by tools/gfx.py: art name constants, tile colors
assets/            sprites.txt, tiles.txt (editable text art)
tools/gfx.py       text art -> build/sprites.bin, build/chars.bin, src/gen_assets.p8
```

## 12. Build milestones

Each milestone ends with something playable in VICE. **The detailed plan, with scope, acceptance checks and status for each phase, is in `docs/phases.md`.**

1. **Video foundation:** text-art converter with placeholder art, bank 3, custom charset, multicolor mode, a hand-made test level drawn from the tile map, HUD row.
2. **Player physics:** run, variable jump, fall, fast-fall, landing on tiles, head bumps.
3. **Platform damage and treasures:** damage/destroy tiles, collect treasures, score, timer, level-complete check.
4. **Level generator:** bands, treasures, validation. Press a key to regenerate (debug).
5. **Enemies:** movement and AI, stomp, kill, chains, hits, float back, invulnerability.
6. **Treasure carrying:** pickup, drop, falling treasure.
7. **Game flow:** title, dissolve transition, difficulty scaling, respawn, game over.
8. **Art and polish:** real sprites and chars, animations, basic sound effects.

## 13. Open questions

None at the moment.

### Resolved
- Enemy climbing: enemy jump raised to 64 px, player jump to 96 px. No stair ledges. Drilling away an enemy's route is allowed strategy.
- Stomp (landing on an enemy without fast-fall): 24 px bounce, no score, enemy survives, carried treasure drops.
- Air control: full, at run speed, except during fast-fall, which drops straight down.
- Timer runs during the post-hit float; the float is fast (4 px/f, < 1 s worst case).
- Drilling: destroying a damaged tile with a fast-fall keeps the player fast-falling through the hole.
- Graphics: multicolor first, kept switchable to hi-res via one constant.
- Treasure types: `min(14, (level - 1) + randrange(5))`.
- Carrying enemy: shown by a color change.
- Art: placeholder art by Claude, in editable text files converted at build time.
- Sound: left out until milestone 8, then basic SID effects only (no music). Each effect is a small table of SID settings (waveform, envelope, start pitch, pitch slide per frame, length), played on one voice and stepped once per frame by the frame IRQ. Effects: jump, land/damage tile, collect treasure, enemy kill, player hit, level complete.
