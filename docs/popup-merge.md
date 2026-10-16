# Score popup merging and stacking (pending change)

Designer-approved tweak to the score popups (spec §8, `src/popup.p8`). Problem: score events in quick succession (a kill plus the carried treasure, or 3 overlapping enemies killed at once) start popups on top of each other, and with only 2 slots one gets replaced, so the numbers are unreadable. When it's implemented, merge this into spec §8 and delete this file.

## 1. Merge rapid events

- If a score event happens within **8 frames** of the most recent event of the newest still-visible popup, it doesn't start a new popup. Instead:
  - add its points to that popup's value and redraw its digits with the total (largest possible: 6200 from a 5-kill chain + 1500 treasure = 7700, still 4 digits);
  - restart that popup's life timer (full 50 frames, rising continues from where it is);
  - its colour becomes the highest-ranked colour so far: kill chain colours rank by chain step, above treasure yellow.
- The 8-frame window counts from the popup's **latest** merged event, so a quick burst keeps merging.
- **[TUNE]** `MERGE_FRAMES = 8`.

## 2. Stack separate popups

- When a new popup starts (not merged) while the other slot's popup is visible and the two would overlap or be closer than 2 px vertically (horizontal distance < 24 px), start the new one **directly above** the existing one: its y = the existing popup's current y − 9 px (7 px digit height + 2 px gap).
- Clamp to the playfield as before. If stacking above would go into the HUD row, stack below instead (existing y + 9).
- **[TUNE]** `STACK_GAP = 9`.

## Done when

- [ ] Scripted: kill a carrier with a fast-fall and collect its dropped treasure within 8 frames → one popup showing the sum (e.g. 200 + 700 = 900) in the kill colour.
- [ ] Scripted: a fast-fall onto 3 overlapping enemies → one popup "1400" in the third chain colour.
- [ ] Scripted: two score events about 20 frames apart near the same spot → two popups, the second directly above the first, both readable in a screenshot.
- [ ] HUD score still flashes on every event, and the score total is unchanged versus the old behaviour.
- [ ] Worst frame (`FRAME_STATS`, TEST 7/8/12/20) still under 312 lines, 0 dropped frames.
- [ ] All test switches off in the handed-over build.
