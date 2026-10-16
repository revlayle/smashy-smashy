# Collision tweaks (pending change)

Designer-approved gameplay tweak. When it's implemented, merge it into `docs/spec.md` (§4 collision boxes, §5 treasure rule, §6 contact) and delete this file.

## 1. Forgiving enemy hits

- The **hit** check (contact rule 3 in spec §6) uses a smaller player **hurt box**: the normal 12 x 16 player box inset **3 px left, 3 px right and 3 px at the top**, so 6 x 13. The bottom edge stays the same. The enemy box is unchanged. **[TUNE]**
- Result: the sprites must overlap by more than 3 px sideways (or from above) before the player is hit. Brushing an enemy and moving away is safe.
- **Kill (rule 1) and stomp/bonk (rule 2) keep using the full player box.** Attacking stays generous; only getting hurt becomes forgiving.
- Order unchanged: kill, then stomp, then hit. A frame where the full boxes overlap but the hurt box doesn't is simply no contact.

## 2. Treasure pickup needs coverage

- The player collects a treasure only when the player's box overlaps the treasure tile by **at least 8 px horizontally and at least 8 px vertically**, i.e. half the tile on each axis. **[TUNE]**
- This applies to resting and falling treasures alike.
- Drilling down through a treasure's column still collects it, because the box is centred in the hole.
- **Enemy pickup is unchanged** (any overlap), so carriers happen as often as before.

## Done when

- [ ] Scripted: the player walks into a frozen enemy and stops with 3 px of sideways overlap → no hit. Moves 2 px further → hit.
- [ ] Scripted: a fast-fall kill and a bonk where the boxes overlap by only 2 px sideways still count (full box for attacks).
- [ ] Scripted: the player stops with 6 px horizontal overlap of a treasure tile → not collected. Moves 2 px further (8 px) → collected.
- [ ] Rerun the regression tests TEST 2 (kill chain), TEST 4 (hit) and TEST 16/21 (drops after stomp or kill). Note any changed results, e.g. a dropped treasure that used to be collected at once now needing a step.
- [ ] All test switches off in the handed-over build.
