# Score feedback (pending change)

Designer-approved addition. Implement after the title screen rework. When it's done, merge this into `docs/spec.md` (§8 scoring, §9 level complete, §3 memory map for the popup sprite frames) and delete this file.

## Goal

Show the player how many points each action earned, where the action happened.

## 1. Score popups (sprites 6 and 7)

- **Trigger:** every score event during play.
  - Treasure collected: the treasure's value, 100-1500.
  - Fast-fall kill: the chain value, 200, 400, 800, 1600 or 3200.
- **Look:** the value as digits (no "+", no trailing text) in a **hi-res** sprite. Clear the sprite's bit in `$D01C` for sprites 6 and 7; the player and enemies stay multicolour.
  - Digits from a small 5x7 font (5 px wide + 1 px gap). 4 digits = 23 px, which fits the 24 px sprite. Centre 3-digit values.
  - The digit font is a 10-entry table (7 bytes each) in code. A popup's 4 rows of digits are drawn into its sprite frame when the event happens (OR the glyph bits into the 3 bytes per row), never per frame.
- **Colour:**
  - Treasure: yellow (7).
  - Kill: by chain step: 1st white (1), 2nd light red (10), 3rd orange (8), 4th and 5th red (2). **[TUNE]**
- **Position:**
  - Starts centred on the event: the treasure tile's centre, or the killed enemy's box centre.
  - Clamped so the whole sprite stays inside the playfield, below the HUD row and inside the side borders.
  - The screen shake offset is applied like for other sprites (the frame IRQ already does that).
- **Motion:** rises 1 px every 2 frames for 50 frames (25 px total). Visible for the first 40 frames, then blinks (2 frames on, 2 off) for the last 10, then the sprite is disabled. **[TUNE]**
- **Two slots:** sprites 6 and 7. A new popup takes a free slot, otherwise the slot with the oldest popup. Each slot has its own sprite frame (2 frames from the free sprite slots, see the asset memory map), so drawing one popup never changes the other.
- **Priority:** lower sprite numbers draw on top, so a popup passes behind the player or an enemy. Accepted; it rises away quickly.
- **Pause, level complete, game over:** popups freeze while paused. They're removed when a level completes and at game over.

## 2. HUD score flash

- On every score event, the score digits on the HUD (6 digits including the fixed "00") switch to white (1) for 8 frames, then back to the normal HUD colour. Colour RAM only.
- A new event restarts the 8 frames.
- HUD cells are hi-res, so colours 0-7 only. If the HUD colour is already white, use yellow (7) for the flash instead. **[TUNE]**

## 3. Level-complete bonus text

During `LEVEL_COMPLETE` (after the last treasure), centred hi-res text on the playfield. Same style as READY?, and it restores the tiles underneath when removed:

```
LEVEL COMPLETE
NO KILL BONUS 2500      (only when the bonus applies)
TIME +60
```

- Shown from the start of the dissolve until READY? replaces it.
- Make the level-complete phase last at least 2 s (100 frames) from the last treasure, so the text can be read even though the dissolve itself only takes ~0.55 s. The timer stays paused, as for the rest of `LEVEL_COMPLETE`. **[TUNE]**
- The bonus is added to the score at the moment its line appears, with a HUD flash.

## Done when

- [ ] Screenshot: a treasure pickup shows the right value in yellow at the treasure's spot, and a second screenshot 0.5 s later shows it higher.
- [ ] Scripted kill chain (TEST 2: kill, bonk, kill) shows 200 in white, then 400 in light red. Two popups can be visible at once.
- [ ] A third quick score event reuses the oldest slot, and no popup ever shows another's digits.
- [ ] Popup near the top or a side edge stays fully on the playfield (clamping).
- [ ] HUD score digits flash on a score event and return to the normal colour.
- [ ] Level complete shows LEVEL COMPLETE, TIME +60, and NO KILL BONUS 2500 only when no enemy was killed. The text stays at least 2 s, and the tiles under it are restored afterwards.
- [ ] Worst frame (`FRAME_STATS`, TEST 7/8/12/20) still under 312 lines with 0 dropped frames. Note the numbers.
- [ ] All test switches off in the handed-over build.
