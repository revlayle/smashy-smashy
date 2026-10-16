# Technical spec: Smashy Smashy

A single-screen C64 platformer.

Source design: `platformer-game.txt`. This document turns it into implementation decisions for Prog8 12.3.4 on a PAL C64.
Items marked **[DECIDE]** are proposals waiting for the designer's confirmation. Items marked **[TUNE]** are starting values expected to change after playtesting.

---

## 1. Platform and timing

- Target: PAL C64, 50 frames/s, Prog8 `-target c64`, 64tass. NTSC is not a goal (timer and speeds would run 20% fast).
- One game update per frame. Frame sync: a raster IRQ at line 251 (bottom border) copies the sprite shadow registers and the vertical fine scroll to the VIC, counts frames (`video.frames`, replaces the KERNAL jiffy clock) and sets a `frame_ready` flag; the main loop waits on it. It does not chain to the KERNAL IRQ (phase 7).
- Per-frame order: wait for frame → write sprite registers from state computed last frame → read joystick → update player → update enemies → resolve collisions → apply queued tile changes to screen → update HUD (only changed digits) → platform-map rebuild slices in the time left (§6).
- Frame budget is roughly 18,000 CPU cycles. If it overruns, enemy AI decisions (not movement) run on alternating frames, e.g. enemies 1,3,5 on even frames and 2,4 on odd.
- 1 second = 50 frames. All timers count frames or seconds as integers.

### Number rules
- **No floating point anywhere.** Do not `%import floats`. Besides being very slow, using floats keeps the BASIC ROM banked in and costs 8 KB of program RAM.
- Prefer `ubyte`/`byte`. Use `uword` only where a value can exceed 255, such as the player's x pixel (0-319). No `long`: the score is a BCD `uword` in hundreds (§8).
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
- **Sprites: multicolor sprites** ($D01C), shared colors $D025/$D026, one own color each. Artwork is 16x16 inside the 24x21 sprite frame, top-left aligned. Multicolor pixels are double width, so a 16 px wide figure is 8 fat pixels across. Exception: sprites 6 and 7 (score popups, §8) are hi-res ($D01C = `%00111111`).
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
| `$E800-$FFBF` | Sprite frames: 95 frames available (pointer values 160-254, = (addr - $C000) / 64). The last 64 bytes are skipped because they overlap the CPU vectors. Art from `sprites.txt` starts at 160; frames 253-254 (`$FF40-$FFBF`) are the two score popup frames (§8), drawn at run time |

Notes:
- The VIC sees RAM at `$E000-$FFFF` even with KERNAL ROM banked in, and CPU *writes* there always go to RAM. So the charset and sprites are copied there once at startup with no ROM banking. They are included in the program with `%asmbinary` and copied from there.
- Register setup: `$DD00` bits 0-1 = `%00` (bank 3), `$D018 = $08` (screen at +$0000, charset at +$2000), `$0288 = $C0` (KERNAL screen editor page, only matters if KERNAL text output is used).
- **Prog8's `txt.setchr`/`txt.plot`-based routines are hard-wired to `$0400`** and must not be used after the switch. The game draws tiles and HUD through its own pointer routines (`^^ubyte @zp` into `$C000` and color RAM `$D800`).
- KERNAL ROM stays banked in, but its IRQ routine no longer runs (phase 7): the frame IRQ returns without chaining to it. The game reads Run/Stop and F1 from the keyboard matrix itself (`input.p8`: row 7 bit 7, row 0 bit 4). No KERNAL calls remain in game code.

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
- Player **hurt box**, used only for getting hit by an enemy (§6 contact rule 3): the player box inset 3 px left, 3 px right and 3 px at the top, so 6 x 13; the bottom edge is the same. Kill, stomp and treasure pickup use the full box. **[TUNE]** (`actors.HURT_INSET`)
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
- **Fast-fall:** joystick down held while `RISING`, `FALLING` or `LAUNCHED` → `FASTFALL`, vy = 96. Holding down from before a jump or a walk off an edge counts. Fire is ignored once descending. A fast-fall can't be cancelled: it ends only by landing on an intact platform or the floor (then normal ground control returns) or by killing an enemy (→ `LAUNCHED`, with air control). After a kill, down must be released before it can start another fast-fall, so holding down through a kill gives the full launch; pressing down again during the launch (or the fall after it) fast-falls at once.
- **Air control:** full left/right control in the air at run speed while rising, falling or launched. **Fast-fall drops straight down:** no horizontal movement until it ends. Aiming is done before pressing down.
- **Minimum fast-fall distance:** a fast-fall only damages tiles once the player has fast-fallen at least **8 px** since the fast-fall started (`ff_start_y` recorded when entering `FASTFALL`). A shorter fast-fall lands like a normal landing: no damage, no crack, no screen shake. The distance counts from the start of the fast-fall, not from the last destroyed tile, so one dive still drills through several layers. Enemy kills are not affected. **[TUNE]** (Designer decision after phase 7, lowered from 16 px to 8 px after the phase 8 playtest: stops the "drill hop", where jump + down held smashed the platform the player stood on after a 2 px rise.)
- **Landing in `FASTFALL`** (with the minimum distance met): damage the tile under the box's centre (1 → 2). If it is already damaged (2 → 0, destroyed), the player keeps fast-falling through the hole. The first hit on an intact tile is a normal landing (fast-fall ends). When the tile is destroyed, the box snaps sideways to the centre of the hole (2 px clear each side) so the fall always continues through it, even if the box was straddling two tiles.
- **Target highlight:** while in the air (any state but `GROUNDED`), the tile a fast-fall from the current position would damage is drawn in `TARGET_COLOR` (white). It is found by dropping the box straight down: the landing row is the first row with a solid tile under either box edge, and the target is the tile under the box centre in that row. Nothing is highlighted when that tile is the floor or empty (the drop would land on an edge, no damage). The highlight follows the player and moves down as tiles are drilled.
- **Landing in any state:** chain = 0.
- **Floor (3)** takes no damage.
- **Screen shake** (designer request, phase 7): a fast-fall that cracks a tile shakes the screen for 4 frames; destroying a tile or killing an enemy shakes it for 8. The vertical fine scroll drops 2 px on alternate frames, and sprites move with it. A new shake restarts the timer if longer than what is left. Visual only. **[TUNE]**
- **Treasure:** the box covers a treasure tile by **at least 8 px horizontally and at least 8 px vertically** (half the tile on each axis) → collect: score, clear the tile, `treasures_left -= 1`. Resting and falling treasures alike. A fast-fall drilling down a treasure's column still collects it (the box is centred in the hole). Standing or falling at the spawn x (6 px into each of columns 9 and 10) collects nothing until the player moves a step. **[TUNE]** (`player.TREASURE_COVER`; designer decision after phase 8, replaced "any overlap")

### Hit and float
- Touching an enemy with the hurt box (§4), other than the stomp/kill cases below, while not invulnerable → hit: `time -= 10 s`, state `FLOATING`.
- `FLOATING`: fly in a straight line to the start point, ignoring tiles, enemies and input. Moves 4 px/f along the longer axis. The shorter axis is stepped with a Bresenham-style integer error counter (no division), so the path is a true straight line. The farthest possible trip (176 px vertical) takes 44 frames, under 1 s. Treasures already collected stay collected. **[TUNE]**
- On arrival → `FALLING`, `invuln_timer = 100` frames (2 s), sprite flickers while invulnerable.
- The timer keeps running while floating after a hit; the lost float time is part of the penalty.

## 6. Enemies

### Contact with the player (checked in this order)
1. Player in `FASTFALL`, player's bottom edge in the top half of the enemy box → **kill**: enemy destroyed, any carried treasure dropped, score 2, 4, 8, 16, 32 hundred by chain (§8), `chain += 1` (max 4), player → `LAUNCHED` 32 px.
2. Player falling (vy > 0, not fast-fall) with the same geometry → **stomp** ("bonk"). Any downward fall counts: the descent of a jump, walking off a ledge, or coming down from a bounce or launch: carried treasure dropped, player bounces 24 px. Enemy survives. No score.
3. Otherwise, if the player's **hurt box** (§4) overlaps the enemy box → player is hit (unless invulnerable or floating). This includes jumping up into an enemy from below and any side contact. The sprites must overlap by more than 3 px sideways (or from above) before it counts, so brushing an enemy and moving away is safe. A frame where the full boxes overlap but the hurt box doesn't is no contact.

Rules 1 and 2 use the full player box, so attacking stays generous; only getting hurt is forgiving. (Designer decision after phase 8.)

Bonks are unlimited: an enemy can be bonked again as soon as the player comes back down on it. **Alternate if that feels bad in play:** a bonked enemy is stunned for 1 s (doesn't move, harmless, can't be bonked again, can still be fast-fall killed).

### Movement
- Same physics routine as the player, minus fast-fall.
- Speed per level: `enemy_speed = min(12 + (level - 1), 22)` subpx/f, i.e. 50% of the player at level 1, reaching the 91.7% cap (the closest step under 95%) at level 11. **[TUNE]**
- Jump: constant rise at the player's rise speed, max 80 px (5 tiles), so an enemy reliably climbs a step of up to 4 tiles. That covers the normal 3-tile gap between platform bands and most jittered ones. (64 px until phase 5b playtesting.)
- Enemies pass through each other (no enemy-enemy collision).

### Simple AI (phase 5a; replaced by the navigation AI in phase 5b)
Decisions at most every 8 frames per enemy, staggered so at most one enemy decides per frame. **[TUNE]**
1. Not carrying, and a treasure on the same tile row within 5 tiles with nothing solid in between → walk to it. *(Not built in 5a: without pickup, enemies would just stand on treasures. Designer decision: it waits for pickup in phase 6, or is replaced by the hunter role in 5b.)*
2. Else chase the player:
   - Player on the same row → walk toward the player.
   - Player lower → walk toward the player and deliberately walk off edges.
   - Player higher → if a solid tile 1-3 tiles up is reachable within 2 columns ahead, jump; otherwise walk toward the nearest platform end and wander.
3. A wall ahead → turn around, or jump if the step is ≤ 3 tiles.

### Navigation AI (phase 5b)

**Frame budget (measured before phase 5):** the worst frame of the current game (player, tile redraws, HUD) uses 58 of 312 raster lines. Enemy movement reuses the player physics, about 10-20 lines per enemy. AI decisions must stay table lookups; anything heavier is time-sliced across frames.

**Measured after phase 5a** (from the frame IRQ line, so the IRQ and KERNAL keyboard scan count; 312 lines per frame): worst frame about 200-206 lines with 5 live enemies and respawns; 81 lines with enemy updates switched off. One enemy decision costs up to about 35 lines, one enemy move about 10-15.

**Measured after phase 5b** (same method): worst frame 202 lines with 5 live enemies (TEST 7 and 8), 247-253 lines with 5 live enemies while the player drills and the map is rebuilt; 0 dropped frames.

**Measured after phase 6** (same method, now with treasures on the map): 255-261 lines with 5 live enemies, pickups and carriers; 241 with 5 carriers; 261 while drilling with rebuilds; 0 dropped frames.

**Measured after phase 7** (same method, frame counter instead of the jiffy clock): TEST 7/8/12/20 257/254/260/246 lines without the KERNAL IRQ, 260/257/263/250 with it chained; 0 dropped frames.

**Measured after phase 8** (same method, with walk animation and sound): TEST 7/8/12/20 268/252/254/258 lines; 0 dropped frames.

**Platform map.** Built after level generation, kept in program RAM (BSS and `memory()` slabs, about 6 KB for both table sets):
- A **platform** is a maximal horizontal run of standing cells (a non-solid cell, empty or treasure, above solid/damaged/floor) on one row. Max 32 platforms; extras are ignored (treated as unreachable). `platform_of[220]` maps each cell to its platform (255 = none). Ids are given in row order, top to bottom.
- **Links** from platform P, each storing the take-off column, the kind (walk off or jump, left or right) and the target platform:
  - *Walk off*: from the cell just past P's left or right end, if not solid, falling straight down to the first standing cell. The enemy walks until its box is centred in that column, so it falls straight down.
  - *Jump up*: to a platform Q 1-4 rows higher. Take-off column is the column just past Q's left or right end, which must lie on P, with clear cells from P's row up to **one row above** Q's row, and the cell above Q's end column clear too. The enemy walks to the take-off column (box centred), rises, and once its box is above Q's tiles moves 1 column sideways onto Q. The headroom row gives it about 17 frames for the sideways move; without it, a ceiling right above Q's row leaves a 1-frame window and the jump fails. Platforms on row 0 have no headroom row, so no jump link leads to them. Conservative on purpose: it never includes a jump an enemy can't make (replayed with the physics on several thousand links, phase 5b).
- `next_link[P * 32 + Q]`: the first link to take from P to reach Q (255 = no route). `hops[P * 32 + Q]`: route length in links (255 = no route). Both from one BFS per platform over the link graph. 2 KB per table set.
- **Rebuild** when a tile is destroyed, into a second copy of the tables, then swapped in. Enemies use the old tables until then. A rebuild must never cause a dropped frame. It runs in slices at the end of the frame update: one tile row, one platform's links, or 24 BFS steps per slice. A slice takes up to about 70 raster lines (measured, also with 32 platforms), and slices only start while the frame is less than 185 lines past the frame IRQ. A rebuild takes about 25-30 frames with 5 enemies active. Destroying another tile restarts it.

**Targets.** The player's platform is the one under the player's box (the box centre's cell, else either box edge's cell when standing on an edge). If the player is airborne, it is the first standing cell found by scanning straight down from the box centre.

**Decision** (every 8 frames per enemy, staggered):
- Decisions are made only on the ground.
- Same platform as the target → walk toward the target's x (kept on the platform), then stand.
- Different platform → look up `next_link`. Walk to its take-off column, then walk off or jump. Taking a link commits the enemy to it: no decisions until it lands, or until 60 frames have passed (then it re-decides; usually the same link again if the take-off is far away).
- No route → head for the platform reachable from here that is nearest the target (rows apart plus the column gap; ties go to fewer hops) and wait there; on the enemy's own platform, walk to the spot nearest the target. The chase resumes as soon as the target is reachable. (Designer decision after phase 5b playtesting; it replaced "wander, 1 in 4 decisions walk off an edge", which left enemies pacing the floor.) Wander (turning at edges and walls) only when the enemy or the target is on no mapped platform.
- Mistakes: with probability `max(16 - level, 4)` in 64, take a random link of the platform instead of the planned one. Rolled once per link choice. **[TUNE]**

**Roles.** Assigned by enemy slot at spawn and respawn:

| Slots | Role | Target |
|---|---|---|
| 1, 2 | Chaser | the player's platform |
| 3 | Ambusher | the platform the player is heading toward: the end of the player's platform in the player's facing direction (the ambusher goes to that end of the player's platform), or the landing platform when airborne |
| 4, 5 | Hunter | the nearest platform with a free treasure (by `hops`), else the player's platform. Until pickup exists (phase 6) a hunter walks to the treasure and stands on it. |

**Carrier.** An enemy holding a treasure switches to the carrier role, whatever its slot:
- Target is the **hideout**, a platform reachable from the carrier's current platform, far from the player's platform by `hops` (no route from the player's platform counts as the farthest). Carriers spread out instead of fleeing as one pile (designer decision after phase 8):
  - **Claims:** each carrier stores its hideout (`nav.hideout[i]`, 255 = none; cleared when it loses the treasure, which includes dying, and when the map is rebuilt). Platforms claimed by another carrier are left out. Only if every reachable platform is claimed may it share one.
  - **Near-best choice:** candidates are the unclaimed reachable platforms with `hops` from the player's platform at least best − 1 (`NEAR_BEST`), best taken among the unclaimed ones. Among them, platforms with more than one outgoing link beat dead ends. One is picked at random (`rand_below`). **[TUNE]** the margin.
  - **Keep:** the current hideout stays while it is still a candidate (no flip-flopping on the 32-frame re-plan).
  - **Player near:** within 5 tiles (Manhattan) or on the carrier's platform, only the best-`hops` platforms are candidates, so the escape stays sharp; the current hideout still stays if it is one of them.
- Re-plan (pick the hideout again by the rules above) when the player is near (see above), and every 32 frames (every 4th decision) otherwise; also right after a pickup, after a map rebuild, and at every decision while another carrier claims the same hideout (it moves on as soon as an unclaimed candidate exists). Route following between re-plans uses the normal 8-frame decisions.
- At the hideout, the carrier waits at the end of its platform away from the player. Carriers sharing a hideout spread out by slot: the lowest slot takes that end, the next one the other end, the third the middle. On a platform shorter than 4 tiles: the end, then the middle, then the other end. Any further ones wait in the middle.
- Cost: `find_hideout()` loops over all platforms in assembly (two passes, row addresses patched into the loads), up to about 50 raster lines including the setup. Frame budget (`FRAME_STATS`, `FRAME_SEED`): TEST 7/8/12/20 = 283/260/274/266 lines (the old hideout rule on the same build: 269/–/260/257), 0 dropped frames.
- A carrier never moves toward the player on purpose: a platform whose route starts with a link onto the player's platform is never a candidate. (Only the first link is checked. Mistakes apply to carriers as to every role.)
- **Contact:** touching a carrier from the side hits the player like any enemy. The treasure only comes loose by a stomp or a fast-fall kill.
- When it loses the treasure, the enemy returns to its slot's role.

### Treasure handling
- An enemy that just lost a treasure can't pick one up for 3 s (`pickup_cooldown`), so the player has a fair chance to grab it.
- Not carrying, no cooldown, and the box overlaps a treasure tile (any overlap; the player's 8 px rule in §5 doesn't apply to enemies) → pick it up (tile cleared, `carrying = 1 + type`). Shown by a color change: a carrying enemy uses `ENEMY_CARRY_COLOR` instead of `ENEMY_COLOR` (sprite color register $D027+n). No extra frames.
- Dropping: the treasure is placed in the tile at the enemy's centre, or the nearest empty tile above it, then falls one tile every 4 frames until it rests on a solid tile. On top of another treasure it waits and falls on once that cell is empty. A falling treasure is an ordinary treasure tile, so the player or an enemy can take it on the way.

### Respawn
- Destroyed enemy → `respawn_timer = max(10 - (level - 1), 3)` seconds. **[TUNE]**
- Respawn location: a random empty tile standing on a solid tile, at least 8 tiles (Manhattan) from the player. Up to 20 tries, then the farthest valid candidate. The tries and the fallback scan are spread over frames (a few per frame, only on frames without an AI decision), so a respawn can land a few frames late.
- **Warning flicker:** a respawning enemy appears at its spot and flickers for 1 s before it becomes active. While flickering it doesn't move and has no contact with the player at all (no hit, bonk or kill). Enemies placed at level start get the same 1 s flicker.

## 7. Level generation

Grid is 20 x 12. Row 11 = floor. The spawn zone (columns 8-11, rows 0-1) is kept clear.

### Platform layout
1. Shelf bands at base rows 2, 5 and 8 (3 tiles apart), each platform jittered ±1 row. A band-2 platform jittered to row 1 that would overlap columns 8-11 stays at row 2 (spawn zone). The worst case after jitter is a 5-tile gap, which the player's 96 px jump still clears. Enemies (4-tile climb) can use every un-jittered gap, so they can always work their way upward somewhere unless the player drills the route away (intended: trapping enemies below is a strategy).
2. Each band gets 2-4 platform segments, 3-8 tiles long, with gaps of 2+ tiles so the player can jump up through them.
3. Each band must contain at least one platform within 3 tiles above some platform in the band below (horizontally within 3 columns), so enemies have a way up. No stair ledges needed. "Within 3 columns" means the column ranges overlap or the gap between them is at most 3 columns. The bottom band's partner is the floor (a platform at row 8 or 9). A layout that fails this counts as a failed attempt.

### Validation
- BFS over "standing cells" (empty cell with solid/damaged/floor below), starting from where the player lands below the spawn point. Edges: walk left/right, fall off edges (falls straight down), jump (up to 5 tiles up, landing within 3 columns).
  - Jump model: rise straight up k rows (1-5) in the start column, then move up to 3 columns sideways along row r - k. Every cell on that path must be empty. With k = 1 the jump can also land across a gap on the start row. This is a simplified, conservative model of the real arc: it can miss some jumps the player can make, but every jump it accepts is possible.
- **Enemy route check:** build the enemy platform map (§6) and regenerate unless an enemy starting on the floor can reach a platform in the top band (standing rows 1-2) by its links. Without it, rule 3's "within 3 columns" let most levels (55-70%) strand enemies on the lower bands, because an enemy jump only steps 1 column sideways.
- Regenerate if fewer than 30 standing cells are reachable, or if any treasure cell is unreachable. After 30 failures, use a fixed fallback layout (it passes all checks).
- Drilling makes everything below the player reachable anyway. Validation guarantees the player can also get back up.
- Designer: a treasure that occasionally needs drilling to reach is fine, so a missed or wrong jump in the model is not a bug to chase.

### Treasures
- 10 per level, each on a reachable standing cell, at least 3 tiles from any other treasure (`|dcol| >= 3` or `|drow| >= 3`), not in the spawn zone, and not on the cell where the player lands from the spawn point (it would be collected on arrival).
- Type choice: `t = min(14, (level - 1) + randrange(5))`. Early levels give 100-500 pts, and values climb by level. From level 11 on, every treasure is the top type.
- Optional later: 1-2 treasures enclosed by platforms, reachable only by drilling ("drill pockets"), as hinted in the design.

### Enemies at level start
5 enemies on random standing cells ≥ 8 tiles from the player start, at least 3 tiles apart (`|dcol| >= 3` or `|drow| >= 3`, as for treasures). Same picking rule as a respawn (20 random tries, then the farthest valid cell). They start with the 1 s warning flicker (§6).

### RNG
`math.rnd()`, masked and retried for ranges (`levelgen.rand_below`; `math.randrange()` does a 16-bit multiply and is several times slower). Seeded with `math.rndseed()` from the CIA1 timer and raster line at the moment fire is pressed on the title screen, so every game is seeded anew.

### Time
A level start can take 2-3 seconds (designer decision, phase 5b); the 3 s "READY?" pause (§9) covers it. It must not take much longer. Measured on 200 levels with the 80 px enemy jump: 0 fallbacks, at most 6 attempts, slowest 22 frames. Worst case (30 failed attempts, then the fallback) 119 frames (2.4 s) on the phase 5b seed; 163 frames on another seed in phase 7 (`FORCE_FAIL` lets every attempt pass all checks, so this is a pessimistic bound), 172 frames (3.4 s) including drawing and enemy placement.

## 8. Scoring and timer

- Score: stored in units of 100 points as a 4-digit BCD `uword` and updated with `bcd.adduw()`. The HUD prints each nibble as a digit and appends a fixed "00", so it shows 6 digits and no division is needed. Max 9999 (999,900 shown); adding past it clamps at the max instead of rolling over.
- Point values are BCD hundreds (`ubyte`):
  - Treasure type `t` = `t + 1` hundred (100-1500), table `$01`-`$15`.
  - Fast-fall kill = 2, 4, 8, 16, 32 hundred by chain (`$02`, `$04`, `$08`, `$16`, `$32`) → 200 to 3200 in one airborne trip. The chain resets on landing.
  - No-kill bonus: 25 hundred (`$25`, 2500 points) when a level is completed with 0 enemies destroyed.

### Score feedback
Every score event shows its points where it happened. Implementation: `src/popup.p8`, `score.flash_step()`.
- **Popups (sprites 6 and 7):** treasure collected → its value (100-1500) in yellow (7); fast-fall kill → the chain value (200-3200), coloured by chain step: 1st white (1), 2nd light red (10), 3rd orange (8), 4th and 5th red (2). **[TUNE]**
  - The value as hi-res digits only (no "+"). 5x7 font, 5 px per digit + 1 px gap, so 4 digits are 23 px wide. The font is an 11-entry table (digits 0-9 and a blank, 7 bytes each) in `popup.p8`. A 3-digit value is drawn with a blank first digit and the sprite is offset so the digits stay centred.
  - Each slot has its own sprite frame (253, 254): rows 0-6, 3 bytes per row. `init()` builds pre-shifted copies of the font for the first two digit positions and the constant "00", so a row is two table lookups; the row loop is unrolled assembly (about 15 raster lines per draw).
  - Drawn at most once per frame: a score event only sets the slot's value, colour, life and position and marks it dirty. `popup.update()`, which runs after the contact checks and the treasure pickup, draws each dirty slot once, so a frame draws at most 2 popups (normally 1) however many score events it has. Prog8 adds no `rts` after a sub's final `%asm` block, so `draw()` ends with `return` (the old `show()` lacked it and ran on into `update()` at every event).
  - Starts centred on the treasure tile's centre or the killed enemy's box centre, clamped so the whole 24x21 sprite stays on the playfield (x 0-296, y up to 171) and the top starts at y ≥ 25, so the rise never reaches the HUD row. Screen shake moves it like every sprite (frame IRQ).
  - Rises 1 px every 2 frames for 50 frames, but never above y 0 (a merge restarts the 50 frames, so a popup near the top could otherwise rise into the HUD row). Shown for the first 40, then blinks 2 frames on, 2 off, then disabled. **[TUNE]**
  - **Merging:** a score event within 8 frames (`MERGE_FRAMES`) of the latest event of the newest still-visible popup starts no popup. It adds its points to that popup (BCD; the largest total is 6200 + 1500 = 7700, still 4 digits) and restarts its life (50 frames; the rise continues from where it is). The popup takes the highest-ranked colour so far: kill chain colours rank by chain step, above treasure yellow (`popup.rank`: 0 treasure, chain step + 1 for a kill). The window counts from the latest merged event, so a quick burst keeps merging (a fast-fall onto 3 overlapping enemies is one "1400" in orange). The position stays: a 3-digit popup that grows to 4 digits ends up 3 px left of centre. **[TUNE]**
  - **Stacking:** a popup that starts (not merged) while the other slot's popup is visible, less than 24 px from it horizontally and closer than 2 px vertically (start y within 9 px of its current y), starts directly above it: y = its current y − 9 (`STACK_GAP`, 7 px digits + 2 px gap). If that would put the top above y 25 (the rise would reach the HUD row), it starts directly below instead (y + 9). Two events about 20 frames apart at one spot don't stack: the first has risen 10 px by then, so the second starts with a 3 px gap below it. **[TUNE]**
  - A new popup takes a free slot, else the oldest (least time left). A reused slot is switched off in the VIC at once, so the new digits never show at the old spot.
  - Lower sprite numbers draw on top, so popups pass behind the player and enemies (accepted). They freeze while paused and are removed at level complete and game over.
- **HUD score flash:** every score event (also the no-kill bonus) turns the 6 HUD score digits yellow (7) for 8 frames, colour RAM only; a new event restarts the 8 frames. HUD cells are hi-res (colours 0-7); the HUD is white, so the flash is yellow (`score.FLASH_COLOR`, white if the HUD colour changes). **[TUNE]**
- Cost (`FRAME_STATS`, same seed as before the change): TEST 7/8/12/20 = 273/267/263/260 lines (267/265/261/258 without popups), 0 dropped frames. With merging and once-per-frame drawing (`FRAME_SEED`): 269/269/260/257, the same as the version before it on the same levels. TEST 30 (fast-fall onto 3 overlapping enemies plus a treasure in the same frame: 4 score events, 1 draw): 217 lines.

- Timer: seconds plus a 50-frame subcounter. Starts at 60. +60 on level completion (carried over). -10 per hit, clamped at 0. 0 → game over. Shown as 3 digits.
- Timer paused during: level-complete dissolve and float, the READY? pause (including generation and drawing).

## 9. Game flow

```
ATTRACT (TITLE -> HOW TO PLAY -> SCORING -> TITLE ...) --fire--> NEW_GAME --> LEVEL_START (READY?) --> PLAYING
PLAYING --10 treasures--> LEVEL_COMPLETE --> LEVEL_START (READY?, level+1, +60 s)
PLAYING --time 0--> GAME_OVER --fire--> ATTRACT (starts at TITLE)
```
- **TITLE**: needed to seed the RNG and to restart.
  - **Big title:** SMASHY SMASHY in block letters, one char per letter pixel, 5 chars tall. Two lines, "SMASHY" each, the second shifted right (rows ~3-7 and ~10-14). **No drop shadow** (designer: too murky; removed after phase 7).
    - Letter pixels are a solid block or one of **4 corner triangles**, so letters get rounded corners and smooth diagonals. The triangles are new custom chars matching PETSCII's ◤◥◣◢ (ROM screen codes 105, 95, 223, 233), each exactly half the cell split along the diagonal, all four drawn consistently so neighbouring diagonals line up. (The ROM's reversed versions are offset by a pixel, so don't copy them.)
    - The letter shapes are a table of strings in the title code, so they're easy to redraw. Symbols use numpad positions for the filled corner: `#` block, `.` empty, `7` ◤ (upper-left half filled), `9` ◥ (upper-right), `1` ◣ (lower-left), `3` ◢ (lower-right). Example S = `3## #.. 9#1 ..# ##7`, A = `3#1 #.# ### #.# #.#`, Y = `#.# 9#7 .#. .#. .#.` (rows left to right, top to bottom). M (5 wide) and H are up to the implementer; check them in a screenshot.
    - Letters are 3 wide except M (5 wide), with 1 column of space between letters.
  - **Character mode:** the title screen uses standard (hi-res) character mode ($D016 bit 4 off) so title blocks can use all 16 colours. Multicolour mode limits single-colour cells to colours 0-7. Gameplay switches multicolour back on.
  - **Smash-in intro:** when the title screen opens, the 12 letters drop in from above the screen one after another (about 4 frames apart), falling at about 1 char row per frame. Each landing shakes the screen for about 8 frames: alternate the vertical fine scroll ($D011 bits 0-2) between its normal value and 2 px lower. **[TUNE]**
    - Implementation (phase 7): the bottom line drops first, so a falling letter never passes through a landed one. Each frame a falling letter moves down one row in a single assembly pass (cells it leaves are cleared, the rest drawn at the new position). The title does its drawing from raster line 180, just below the letters, so it is done before the beam returns to them (worst frame 193 lines from line 180); the frame IRQ writes the fine scroll in the border.
  - **Rainbow sweep:** after the intro, title block colours cycle every 2 frames through a 16-entry colour table (e.g. 9, 2, 8, 10, 15, 7, 1, 1, 7, 15, 10, 8, 2, 9, 6, 6). Each block's colour index is `(row + phase) & 15`: horizontal colour bands that roll **vertically** through the letters (designer change after phase 7; diagonal bands looked speckled). Triangle cells take the colour of their row like blocks. Only colour RAM changes, and only for letter cells: keep a list of their screen offsets built when the title is drawn, so empty cells are never touched. **[TUNE]**
  - **Text:** "PRESS FIRE" (blinking about once per second) and "HIGH SCORE 000000", hi-res text from the HUD font (chars 0-63 are the ROM screen codes). Fire starts a new game (edge-triggered, so the fire press that ended the last game doesn't start one).
- **Attract pages** (designer addition after phase 8; not a self-playing demo): between games the title cycles through information pages. Implementation: `src/pages.p8`, `main.attract()`.
  - **Cycle:** TITLE → HOW TO PLAY → SCORING → TITLE → ..., TITLE and HOW TO PLAY 10 s each, SCORING 12 s, the most to read (designer: 6/6/8 s was too short) (`pages.TITLE_FRAMES`, `HOW_FRAMES`, `SCORING_FRAMES`). **[TUNE]** The title replays its smash-in intro each time it comes around (it counts its time from the frame counter, so a loop pass that ends early doesn't shorten it). After GAME OVER the cycle starts at the title. No sound.
  - **Fire starts a game from any page**, edge-triggered as on the title (every page reads the joystick each frame, so a held fire never counts as a new press). `main.attract()` seeds the RNG after that fire (`levelgen.seed()`, unchanged).
  - **Display:** HOW TO PLAY and SCORING use the game's multicolour mode (`video.set_game_mode()`: screen cleared, colour RAM set to the HUD colour), so tiles and sprites look as in play; text is in hi-res cells from the HUD font. Tiles are drawn with their normal chars and colours at any char position (`pages.put_tile()`). Leaving a page hides all sprites; the title switches back to hi-res with `video.set_title_mode()`.
  - **Text:** all page text is in string tables at the top of `pages.p8` (row, column, text), so the wording is easy to change. Lines stay within 40 columns.
  - **HOW TO PLAY:** title line (row 1), then lines with a graphic at the left (columns 1-4, text from column 4): player run, jump and fast-fall poses (sprites 0-2, centred on rows 4, 7 and 10) for LEFT/RIGHT RUN, FIRE JUMP - HOLD FOR HIGHER, DOWN IN AIR SMASH DOWN; an intact and a damaged brick tile side by side (row 13, text from column 6) for SMASH A BRICK TWICE TO BREAK IT; an enemy (sprite 3, rows 16-17) for LAND ON ENEMIES TO BONK THEM / SMASH THEM TO DESTROY THEM; treasure 0 (rows 20-21) for GRAB ALL 10 TREASURES / ENEMIES STEAL THEM - BONK THEM BACK! / BEAT THE CLOCK. Sprites are multicolour in their play colours.
  - **SCORING:** all 15 treasure tiles in 3 lines of 5 (rows 3, 7, 11; columns 3, 11, ..., 35), each value centred under it (from `score.treasure_points`). Then SMASH CHAIN 200 400 800 1600 3200 (values from `enemies.kill_points`, each in its popup colour from `popup.rank_color`), NO KILL BONUS 2500, TIME +60 PER LEVEL, HIT -10 SECONDS and HIGH SCORE (the session high score), on rows 16, 18 and 20.
  - **Raster split on SCORING:** the chain colours include light red (10) and orange (8), which a hi-res cell can't show in multicolour mode (colour RAM 8-15 makes a cell multicolour). So the page loop switches $D016 to hi-res character mode at raster line 170 (char row 15, empty, between the treasures and the text) and back to multicolour right after the frame IRQ (line 251, in the border). Polled in the page loop; nothing else runs there.
- **Pause**: Run/Stop toggles pause during PLAYING (edge-triggered, press again to resume). Everything freezes, including the timer; "PAUSED" is shown. Ignored during transitions.
- **LEVEL_COMPLETE**: enemies vanish. Non-floor tiles are erased in random order, ~8 tiles per frame (about 1 s). The player floats to the start.
  - Implementation (phase 7): all 220 non-floor cells in a random order (shuffled as it goes), 8 per frame, so the dissolve takes 28 frames (0.55 s); the state ends when the float has arrived too. The no-kill bonus is added as the dissolve starts.
  - **Bonus text:** from the start of the dissolve, centred hi-res text on the playfield, same style as READY?: "LEVEL COMPLETE" (char row 10), "NO KILL BONUS 2500" (row 12, only when no enemy was destroyed this level), "TIME +60" (row 12 or 14). The bonus is added (with a HUD flash) as its line appears; the +60 s at the end of the state. The dissolve redraws tiles under the text, so the text is rewritten after the dissolve step each frame (in the border, no flicker). At the end its tiles are restored and READY? replaces it.
  - The state lasts at least 100 frames (2 s) from the last treasure (`main.LEVEL_DONE_FRAMES`), so the text can be read; the timer stays paused. **[TUNE]**
- **LEVEL_START** ("READY?" pause), used for every level including the first:
  1. "READY?" appears, hi-res text centred on the playfield. The player sprite stays at the start point (floating pose), with no control. Timer paused.
  2. Generate the next level. Blocking is fine here: nothing animates except the frame IRQ. Then draw it, so the player can see the new layout during the rest of the pause. Place enemies (not yet active).
  3. The pause lasts 3 s from when READY? appeared, or until generation and drawing finish if that takes longer (worst case measured 2.4 s, so normally exactly 3 s). **[TUNE]**
  4. Remove the text. The player switches to `FALLING`, enemies start their 1 s warning flicker, the timer runs: PLAYING.
  - Implementation (phase 7): enemy sprites stay hidden during the pause and appear with the warning flicker when play starts. Joystick and keys are not read during the pause.
- **GAME_OVER**: show the final score and level reached; fire → TITLE.
  - Implementation (phase 7): "GAME OVER" and "HIGH SCORE" over the frozen playfield; score and level stay on the HUD row. Fire is accepted after 1 s, so a fire press from play doesn't skip the screen.
- **Session high score**: the best score since the program started, kept in RAM (lost on power-off). Updated at game over, shown on the title and game-over screens. A saved high-score list is backlog (see §14).

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

Run frame 0 doubles as the standing pose. Run and walk cycles advance by distance moved (player: next picture every 6 px, enemies every 5 px) and go back to frame 0 after 4 frames standing still; float alternates every 8 frames. **[TUNE]** Frames of one animation must stay together and in order in `sprites.txt` (the code uses `SPR_<SET>_0 + n`).

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
src/title.p8       title screen (block letters, intro, colour sweep)
src/pages.p8       attract pages after the title (HOW TO PLAY, SCORING), with all their text
src/video.p8       VIC bank setup, IRQ, tile drawing, HUD, sprite register writes
src/input.p8       joystick read and edge detection
src/actors.p8      shared physics and tile collision
src/player.p8      player states
src/enemies.p8     enemy movement, contact, respawn, treasure carry/drop
src/nav.p8         platform map and navigation AI
src/levelgen.p8    generation and validation
src/score.p8       BCD score, timer
src/sound.p8       SID sound effects (table, stepped by the frame IRQ)
src/popup.p8       score popups (sprites 6-7, digits drawn into their frames)
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
5a. **Enemies:** movement, simple AI, stomp, kill, chains, hits, float back, invulnerability.
5b. **Navigation AI:** platform map, route following, enemy roles.
6. **Treasure carrying:** pickup, drop, falling treasure, carrier fleeing.
7. **Game flow:** title, dissolve transition, difficulty scaling, respawn, game over.
8. **Art and polish:** real sprites and chars, animations, basic sound effects.

## 13. Open questions

None at the moment.

### Resolved
- Enemy climbing: enemy jump raised to 64 px, then 80 px (phase 5b); player jump 96 px. No stair ledges. Drilling away an enemy's route is allowed strategy.
- Stomp (landing on an enemy without fast-fall): 24 px bounce, no score, enemy survives, carried treasure drops.
- Air control: full, at run speed, except during fast-fall, which drops straight down.
- Timer runs during the post-hit float; the float is fast (4 px/f, < 1 s worst case).
- Unlimited bonks on the same enemy (1 s stun is the noted alternate). Jumping up into an enemy is a hit.
- Respawning enemies flicker harmlessly for 1 s before activating.
- Phase 5a decisions: down must be released after a kill before it fast-falls again; level-start enemies flicker like respawns; simple-AI rule 1 (walk to treasures) waits for pickup in phase 6.
- Phase 5b decisions: level generation rejects layouts where enemies can't climb from the floor to the top band (enemy route check, §7). Generation may take 2-3 s; no frame limit.
- Phase 5b playtest: enemies with no route go as close to the target as they can instead of wandering; enemy jump 80 px (climbs 4-row steps).
- 3 s pickup cooldown for an enemy that just lost a treasure.
- Pause on Run/Stop. Session high score in RAM.
- Fast-fall needs 8 px of fast-fall distance before it can damage a tile (no drill hop from standing).
- Bonks chain: a bonk's bounce can land on another enemy for another bonk. Bonks score nothing and leave the fast-fall kill chain unchanged: they neither advance it nor reset it (only landing on a tile resets it).
- Enemy AI: platform-map navigation with roles (chasers, ambusher, hunters), built in two phases (5a simple, 5b navigation).
- Carriers flee to a hideout far from the player. Side contact with a carrier hits the player; only a stomp or kill frees the treasure. No tiring mechanic.
- Drilling: destroying a damaged tile with a fast-fall keeps the player fast-falling through the hole.
- Graphics: multicolor first, kept switchable to hi-res via one constant.
- Treasure types: `min(14, (level - 1) + randrange(5))`.
- Carrying enemy: shown by a color change.
- Art: placeholder art by Claude, in editable text files converted at build time.
- Sound: left out until milestone 8, then basic SID effects only (no music). Each effect is a small table of SID settings (waveform, envelope, start pitch, pitch slide per frame, length), played on one voice and stepped once per frame by the frame IRQ. Effects: jump, land/damage tile, collect treasure, enemy kill, player hit, level complete.
  - Implementation (phase 8): `src/sound.p8`, SID voice 1; a new effect cuts the one playing. "Land/damage" sounds only when a fast-fall cracks or destroys a tile; plain landings are silent. Jump sounds only for a jump from the ground (not stomp bounces or kill launches). Values are in the table there. **[TUNE]**

## 14. Backlog

Ideas for after phase 8, not scheduled:
- Saved high-score list (to disk), with name entry.
- Title screen extras: every few seconds the player sprite fast-falls onto a random title letter, its blocks crack (damaged look) and repair after a moment; and/or a strip at the bottom where the player and an enemy (or a carrier) chase each other.
- Treasures enclosed by platforms, reachable only by drilling ("drill pockets", §7).
