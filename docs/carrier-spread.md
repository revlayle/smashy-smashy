# Carriers spread out (pending change)

Designer-approved AI tweak to the carrier role (spec §6, `nav.find_hideout`).

**Problem:** every carrier uses the same hideout rule with the same tie-breaks, so they all pick the same platform and then the same end of it. Carriers end up moving together in one pile, and one dive kills them all. Clustering should be something the player engineers, not the default.

When it's implemented, merge this into spec §6 (Carrier) and delete this file.

## Rules

1. **Claims:** each carrier stores its chosen hideout platform (`hideout[i]`, 255 = none; cleared when it loses the treasure, dies or the map is rebuilt). When picking, platforms claimed by another carrier are skipped. Only if no unclaimed candidate is reachable may it share a claimed platform.
2. **Near-best choice:** candidates are the unclaimed reachable platforms whose `hops` from the player's platform is at least (best − 1). The existing rules still apply on top: dead ends lose to platforms with more than one outgoing link, and no first link onto the player's platform. Pick one of the candidates at random (`rand_below`-style, no multiply).
3. **Keep the current hideout** if it is still a candidate, i.e. unclaimed by others and within 1 hop of the best. This avoids flip-flopping between hideouts on the 32-frame re-plan. Pick again only when it no longer qualifies, or on the "player within 5 tiles / on the carrier's platform" trigger, which must pick the best-distance candidates (best hops only) so the escape stays sharp.
4. **Spread when sharing:** if a carrier's hideout is shared anyway, the carrier with the higher slot number waits at the platform's opposite end from the other carrier, or at the middle if the platform is shorter than 4 tiles. One carrier per platform end.
5. **Arriving on a shared platform:** a carrier whose hideout turns out to hold another carrier (e.g. after a map rebuild) re-plans at its next decision.

**[TUNE]** the near-best margin (1 hop).

## Done when

- [ ] Scripted: 3 enemies made carriers at once (test switch), player waiting in a corner → after 5 s, the 3 carriers are on 3 different platforms (readout of each carrier's platform and hideout).
- [ ] Scripted: same with only 1 valid hideout area (fallback layout or a small test map) → shared hideout, carriers at different ends, not stacked.
- [ ] A carrier's hideout doesn't change between two re-plans while the player stays far away (no flip-flopping; readout over 10 s).
- [ ] Rerun TEST 18 (carrier flees when approached): still flees.
- [ ] Worst frame (`FRAME_STATS`, TEST 7/8/12/20, plus TEST 20 with all carriers) still under 312 lines, 0 dropped frames.
- [ ] All test switches off in the handed-over build.
