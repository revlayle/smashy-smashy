# Attract pages (pending change)

Designer-approved addition: between games, the title cycles through information pages. It's not a self-playing demo. When it's implemented, merge this into spec §9 (TITLE) and delete this file.

## Cycle

- **TITLE → HOW TO PLAY → SCORING → TITLE → ...**, each page shown for **6 s** (SCORING 8 s, the most to read). **[TUNE]**
- **Fire starts a game from any page.** Edge-triggered as on the title, so the fire that ended the last game doesn't start one. RNG seeding works as before.
- The title replays its smash-in intro each time it comes around.
- After GAME OVER the cycle starts at the title.
- No sound.

## Display

- TITLE keeps its hi-res character mode.
- HOW TO PLAY and SCORING use the game's **multicolour mode** so tiles look right, with text in hi-res cells (colour RAM 0-7), like the HUD. Switch modes and clear the screen and colour RAM between pages, and hide all sprites when leaving a page.
- Text uses the HUD font (ROM screen codes 0-63: uppercase letters, digits, punctuation).
- **All page text lives in string tables** in one place (e.g. `src/pages.p8`) so the wording is easy to change. Rough layouts below; exact columns are up to the implementer, checked by screenshot.

## Page 2: HOW TO PLAY

A title line, then short lines, each with a game graphic at the left: sprites for poses, tile chars for bricks and treasure.

```
              HOW TO PLAY

 [run]    LEFT/RIGHT  RUN
 [jump]   FIRE        JUMP - HOLD FOR HIGHER
 [smash]  DOWN IN AIR SMASH DOWN
 [brick][cracked]     SMASH A BRICK TWICE TO BREAK IT
 [enemy]  LAND ON ENEMIES TO BONK THEM
          SMASH THEM TO DESTROY THEM
 [chest]  GRAB ALL 10 TREASURES
          ENEMIES STEAL THEM - BONK THEM BACK!
          BEAT THE CLOCK
```

- **Sprites (4):** player run pose, jump pose, fast-fall pose, and an enemy. All multicolour as in play, at fixed positions next to their lines.
- **Tiles:** an intact brick and a damaged brick side by side, and one treasure, each a 2x2-char tile drawn with the normal tile chars and colours.
- Keep every text line within 40 columns, including the graphic's space.

## Page 3: SCORING

```
                SCORING
 [t1] [t2] [t3] [t4] [t5]
  100  200  300  400  500
 [t6] [t7] [t8] [t9] [t10]
  600  700  800  900 1000
 [t11][t12][t13][t14][t15]
 1100 1200 1300 1400 1500

 SMASH CHAIN  200 400 800 1600 3200
 NO KILL BONUS 2500   TIME +60 PER LEVEL
 HIT -10 SECONDS      HIGH SCORE 012300
```

- **All 15 treasure tiles** in 3 rows of 5, each with its value centred under it (hi-res text).
- **SMASH CHAIN values** use the popup chain colours (spec §8: white, light red, orange, red, red). Read them from the popup code's constants rather than copying them.
- **HIGH SCORE** shows the session high score.

## Done when

- [ ] Screenshots of each page: all text on screen, readable, nothing cut off; graphics next to the right lines; tile and sprite colours as in play.
- [ ] The cycle advances on time (screenshots at about 3, 9, 19 and 25 s after the title starts show TITLE, HOW TO PLAY, SCORING, TITLE), and the title intro replays.
- [ ] Fire on each page starts a game. Game mode, colours and sprites are correct in play, and no page sprite is left visible.
- [ ] After a game over, the cycle restarts at the title and SCORING shows the new high score.
- [ ] Gameplay worst frame unchanged (pages only run between games).
- [ ] All test switches off in the handed-over build.
