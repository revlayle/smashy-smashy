; Smashy Smashy, a C64 platformer. Game flow (spec section 9): title, READY? pause, play, level complete
; dissolve, game over.

%import video
%import input
%import player
%import enemies
%import nav
%import score
%import levelgen
%import title
%import popup
%import pages
%zeropage basicsafe
%memtop $C000

main {
    ; Self-test readout on the HUD row instead of SCORE/TIME/LEVEL. Keep false in builds for the designer.
    ; x=box x  y=box y  s=state  p=highest y of the last air trip  l=y at last landing
    ; f=x at fast-fall start  g=x at last landing  e=frames with the box inside a solid tile  n=frame count
    const bool DEBUG_HUD = false

    ; Debug key: F1 generates a new level instantly (timer and score kept).
    const bool REGEN_KEY = false

    ; Self-test: after each generation, HUD cols 0-1 = attempts in hex (+$80 = fallback layout),
    ; col 2 = level check result (0 = ok, see check_level), cols 38-39 = generation time in frames (hex).
    const bool GEN_STATS = false
    ; Self-test: generate SOAK_COUNT levels at startup, then freeze with the results on the HUD row (see soak()).
    const bool GEN_SOAK = false
    const ubyte SOAK_COUNT = 200

    ; Self-test: worst frame in raster lines, from the frame IRQ line (so the KERNAL IRQ counts) to the end of
    ; the HUD update, hex on HUD cols 37-39. Over 312 (PAL lines per frame) means a dropped frame; the frame
    ; counter (ticked by the frame IRQ) counts the whole frames that passed.
    const bool FRAME_STATS = false
    ; Self-test scenario (0 = off). Sets up enemies and the input script after each level load and shows a
    ; readout on char row 1 (see test_setup and test_hud). Needs input.SCRIPTED; 2-6, 10-11, 15-21, 23-31 and 33 need
    ; levelgen.FORCE_FAIL, 7-8, 12, 20 and 30 (frame budget) need FRAME_STATS. 9 (link replay) needs neither.
    ; 22 (game flow) and 34 (attract pages) run the title screen; every other test skips it. 22 and 34 need
    ; neither FORCE_FAIL nor FRAME_STATS.
    const ubyte TEST = 0
    const bool SKIP_TITLE = TEST != 0 and TEST != 22 and TEST != 34
    const uword COMPLETE_AT = 0         ; any TEST: play frames until the level counts as complete (0 = off)
    const ubyte LINK_LEVELS = 20        ; TEST 9: levels to check
    const ubyte LINK_HOLES = 0          ; TEST 9: random platform tiles destroyed in each level before the check
    const bool LINK_MAX_SPEED = false   ; TEST 9: enemies at the level-11 speed cap instead of level 1
    const bool STEP_COMB = false        ; TEST 13: time the rebuild on a worst-case layout with many platforms
    const bool SHARE_SHORT = false      ; TEST 33: the platform is 3 tiles wide instead of 12
    const bool FLOW_ATTRACT = false     ; TEST 22: no fire on the title after the game over, so the pages cycle
    const ubyte ATTRACT_FIRE = 1        ; TEST 34: fire on page 1 (title, 3 s in), 2 (HOW TO PLAY, 5 s) or 3 (SCORING, 4 s)

    ; Debug view: HUD row shows, per enemy, its platform and its target platform at the last decision
    ; (hex, "ff" = none) and its plan (0 stand, 1 walk to a spot, 2 wander, 3 walk off, 4 jump), then the
    ; number of finished map rebuilds.
    const bool NAV_DEBUG = false

    ; Self-test: char row 1 cols 0-22 show, for each sprite frame in gen_assets order, 1 + the state of the
    ; last actor drawn with it (hex; 0 = not seen yet). Player states 0-5, enemy states 0-2 and 7 (warning).
    const bool POSE_STATS = false

    ; [TUNE]
    const ubyte READY_FRAMES = 150      ; READY? pause, 3 s
    const ubyte DISSOLVE_RATE = 8       ; tiles erased per frame at level complete
    const ubyte GAME_OVER_WAIT = 50     ; frames before fire returns to the title
    const ubyte MSG_ROW = 12            ; centre of the playfield
    const ubyte LEVEL_DONE_FRAMES = 100 ; level complete lasts at least 2 s, so its text can be read

    sub start() {
        video.init()
        sound.init()
        levelgen.init()
        title.init()
        popup.init()
        video.start_frame_irq()         ; first, so the frame counter counts while generating
        if GEN_SOAK
            soak()
        if SKIP_TITLE
            levelgen.seed()
        if TEST == 22
            input.script = if FLOW_ATTRACT &script_flow_end else &script_flow
        if TEST == 34 {
            when ATTRACT_FIRE {
                1 -> input.script = &script_fire_title
                2 -> input.script = &script_fire_how
                3 -> input.script = &script_fire_scoring
            }
        }

        repeat {
            if not SKIP_TITLE
                attract()               ; returns when fire is pressed, with the RNG seeded
            new_game()
            repeat {
                level_start()
                if not play()
                    break
                level_complete()
            }
            game_over()
        }
    }

    sub attract() {
        ; Title, HOW TO PLAY and SCORING in turn until fire starts a game from any of them; then seed the RNG.
        repeat {
            if title.run(pages.TITLE_FRAMES)
                break
            if pages.how_to_play()
                break
            if pages.scoring()
                break
        }
        levelgen.seed()
    }

    sub new_game() {
        video.set_game_mode()
        video.draw_hud_labels()
        score.new_game()
        ; empty playfield with the floor, the player at the start
        sys.memset(&video.tiles, levelgen.CELLS, video.T_EMPTY)
        sys.memset(&video.tiles + levelgen.CELLS, video.MAP_W, video.T_FLOOR)
        video.draw_level()
        player.init()
    }

    ubyte ready_frames                  ; self-test readout: length of the last READY? pause, generation time
    ubyte gen_frames

    sub level_start() {
        ; READY? for 3 s (spec section 9). The next level is generated and drawn meanwhile; the timer is paused.
        ubyte t0 = video.frames
        player.hold_at_start()
        player.draw()
        video.message(MSG_ROW, 17, sc:"ready?")
        load_level()
        gen_frames = video.frames - t0
        video.message(MSG_ROW, 17, sc:"ready?")
        while video.frames - t0 < READY_FRAMES {
        }
        ready_frames = video.frames - t0
        video.restore_tiles(MSG_ROW, 17, 6)
        player.init()                   ; falling from the start; the enemies' warning flicker starts now
        player.draw()
        if TEST != 0
            test_setup()
        video.frame_ready = false       ; start the first frame on a fresh one
    }

    sub play() -> bool {
        ; PLAYING. Returns true when the level is complete, false when the time has run out.
        play_frames = 0
        repeat {
            video.wait_frame()
            if FRAME_STATS
                frame_start = video.frames
            input.read()
            if input.pressed & input.STOP != 0
                pause()
            score.flash_step()
            player.update()
            enemies.update()
            enemies.contact()
            player.draw()
            enemies.draw()
            popup.update()
            if DEBUG_HUD
                debug_hud()
            if NAV_DEBUG
                nav_debug()
            if POSE_STATS
                pose_stats()
            if REGEN_KEY and input.pressed & input.F1 != 0 {
                load_level()
                player.init()
                player.draw()
                video.frame_ready = false
            }
            if TEST != 0
                test_frame()
            video.shake_step()
            if score.treasures_left == 0 {
                video.stop_shake()
                return true
            }
            if score.tick() {
                video.stop_shake()
                return false
            }
            nav.idle_build()            ; last: map rebuild slices only use the time left in the frame
            if FRAME_STATS
                frame_stats()
            if TEST != 0
                test_hud()
        }
    }

    sub pause() {
        ; Run/Stop again resumes. Everything is frozen meanwhile, the timer too.
        video.stop_shake()
        video.message(MSG_ROW, 17, sc:"paused")
        do {
            video.wait_frame()
            input.read()
        } until input.pressed & input.STOP != 0
        video.restore_tiles(MSG_ROW, 17, 6)
        player.show_target()
        input.pressed = 0               ; the resume press is not a game input
    }

    ubyte[assets.SPRITE_COUNT] pose_state

    sub pose_stats() {
        ubyte i
        for i in 0 to enemies.LAST {
            if video.spr_ena & (1 << i) != 0 {
                ubyte k = video.spr_ptr[i] - assets.SPR_PLAYER_RUN_R_0
                pose_state[k] = actors.state[i] + 1
                @(video.SCREEN + 40 + k) = hex_char(pose_state[k])
                @(video.COLOR_RAM + 40 + k) = video.COLOR_HUD
            }
        }
    }

    ; ---- frame budget self-test ----
    uword worst_lines
    ubyte frame_start

    sub raster_line() -> uword {
        ; 9-bit raster line ($D011 bit 7 is bit 8), re-read if the line changed between the two reads
        ubyte hi
        ubyte lo
        do {
            hi = c64.SCROLY & $80
            lo = c64.RASTER
        } until hi == c64.SCROLY & $80
        return mkword(hi >> 7, lo)
    }

    sub frame_stats() {
        uword now = raster_line()
        uword lines
        if now >= video.FRAME_IRQ_LINE
            lines = now - video.FRAME_IRQ_LINE
        else
            lines = now + 312 - video.FRAME_IRQ_LINE    ; PAL: 312 lines per frame
        repeat video.frames - frame_start
            lines += 312
        if lines > worst_lines {
            worst_lines = lines
            hex_digit(37, msb(worst_lines))
            hex_byte(38, lsb(worst_lines))
        }
    }

    sub load_level() {
        ; Generate and draw the level for score.level and place the enemies (shown once play starts).
        ubyte t0 = video.frames
        levelgen.generate(score.level)
        ubyte frames = video.frames - t0
        video.draw_level()
        score.new_level()
        nav.new_level()
        enemies.new_level(score.level)
        enemies.place_all()
        if GEN_STATS {
            hex_byte(0, if levelgen.used_fallback levelgen.attempts | $80 else levelgen.attempts)
            hex_digit(2, check_level())
            hex_byte(38, frames)
        }
    }

    ubyte[levelgen.CELLS] dissolve_order

    sub level_complete() {
        ; Enemies and popups vanish, the platforms dissolve in random order and the player floats back to the
        ; start, under the level-complete text (at least LEVEL_DONE_FRAMES). The timer is paused. Then the next
        ; level number and +60 s.
        ubyte i
        for i in enemies.FIRST to enemies.LAST
            video.hide_sprite(i)
        popup.clear()
        bool bonus = enemies.kills == 0
        if bonus
            score.add_points(score.NO_KILL_BONUS)
        sound.play(sound.LEVEL_DONE)
        player.start_float()
        for i in 0 to levelgen.CELLS - 1
            dissolve_order[i] = i
        ubyte n = 0                     ; cells done; the order is shuffled as it goes (Fisher-Yates)
        bool floating = true
        ubyte frames = 0
        while n != levelgen.CELLS or floating or frames < LEVEL_DONE_FRAMES {
            video.wait_frame()
            frames++
            score.flash_step()
            repeat DISSOLVE_RATE {
                if n == levelgen.CELLS
                    break
                ubyte j = n + levelgen.rand_below(levelgen.CELLS - n)
                ubyte idx = dissolve_order[j]
                dissolve_order[j] = dissolve_order[n]
                n++
                if video.tiles[idx] != video.T_EMPTY {
                    video.tiles[idx] = video.T_EMPTY
                    video.draw_tile(levelgen.cell_col[idx], levelgen.cell_row[idx])
                }
            }
            if floating {
                player.update()
                if actors.state[0] != player.FLOATING {
                    floating = false
                    player.hold_at_start()
                }
            }
            player.draw()
            done_text(bonus)            ; over the tiles the dissolve just drew (still in the border)
        }
        for i in 10 to 14 step 2
            video.restore_tiles(i, 11, 18)
        score.next_level()
    }

    sub done_text(bool bonus) {
        ; Centred lines from char row 10; the values match score.NO_KILL_BONUS and score.LEVEL_TIME_BONUS.
        video.message(10, 13, sc:"level complete")
        ubyte row = 12
        if bonus {
            video.message(12, 11, sc:"no kill bonus 2500")
            row = 14
        }
        video.message(row, 16, sc:"time +60")
    }

    sub game_over() {
        ; Final score and level stay on the HUD row. Fire (after a short wait) returns to the title.
        popup.clear()
        score.stop_flash()
        score.update_high()
        video.message(10, 15, sc:"game over")
        video.message(14, 11, sc:"high score")
        uword hs = video.SCREEN + 14 * 40 + 22
        video.put_digits(hs, score.high, 4)
        video.put_digits(hs + 4, 0, 2)
        sys.memset(hs + video.COLOR_RAM - video.SCREEN, 6, video.COLOR_HUD)
        repeat GAME_OVER_WAIT
            video.wait_frame()
        do {
            video.wait_frame()
            input.read()
        } until input.pressed & input.FIRE != 0
    }

    ; ---- level generator self-test ----
    sub check_level() -> ubyte {
        ; 0 = ok. 1 = floor row not full, 2 = spawn zone not clear, 3 = treasure not on a standing cell,
        ; 4 = treasure not reachable, 5 = two treasures closer than 3 tiles, 6 = not 10 treasures,
        ; 7 = treasure where the player lands from the spawn point.
        ubyte idx
        for idx in 220 to 239 {
            if video.tiles[idx] != video.T_FLOOR
                return 1
        }
        ubyte c
        ubyte r
        for c in levelgen.SPAWN_COL_L to levelgen.SPAWN_COL_R {
            if video.tiles[c] != video.T_EMPTY or video.tiles[c + video.MAP_W] != video.T_EMPTY
                return 2
        }
        ubyte n = 0
        for r in 0 to 10 {
            for c in 0 to video.MAP_W - 1 {
                idx = video.row_start[r] + c
                if video.tiles[idx] >= video.T_TREASURE {
                    if video.tiles[idx + video.MAP_W] - 1 >= 3
                        return 3
                    if levelgen.cell[idx] < levelgen.C_REACHED
                        return 4
                    if n == len(chk_col)
                        return 6
                    ubyte i
                    if n != 0 {
                        for i in 0 to n - 1 {
                            if abs_diff(c, chk_col[i]) < 3 and abs_diff(r, chk_row[i]) < 3
                                return 5
                        }
                    }
                    chk_col[n] = c
                    chk_row[n] = r
                    n++
                }
            }
        }
        if n != 10
            return 6
        idx = levelgen.START_COL_L
        while video.tiles[idx + video.MAP_W] - 1 >= 3 and video.tiles[idx + video.MAP_W + 1] - 1 >= 3
            idx += video.MAP_W
        if video.tiles[idx] >= video.T_TREASURE or video.tiles[idx + 1] >= video.T_TREASURE
            return 7
        return 0
    }
    ubyte[10] chk_col
    ubyte[10] chk_row

    sub abs_diff(ubyte a, ubyte b) -> ubyte {
        if a >= b
            return a - b
        return b - a
    }

    sub soak() {
        ; HUD row, all hex: cols 0-1 fallbacks, 3-4 most attempts without fallback, 6-7 check_level failures,
        ; 9-10 slowest generation in frames, 12-13 levels generated. The last level is drawn.
        ubyte fallbacks = 0
        ubyte most = 0
        ubyte fails = 0
        ubyte slowest = 0
        ubyte done = 0
        sys.memset(video.SCREEN, 40, video.CHAR_SPACE)
        repeat SOAK_COUNT {
            ubyte t0 = video.frames
            levelgen.generate(1)
            ubyte frames = video.frames - t0
            if levelgen.used_fallback
                fallbacks++
            else if levelgen.attempts > most
                most = levelgen.attempts
            if check_level() != 0
                fails++
            if frames > slowest
                slowest = frames
            done++
            hex_byte(0, fallbacks)
            hex_byte(3, most)
            hex_byte(6, fails)
            hex_byte(9, slowest)
            hex_byte(12, done)
        }
        video.draw_level()
        repeat {
        }
    }

    ; ---- self-test scenarios (TEST) ----
    ; Fallback layout: the player drops from the spawn point onto the row-5 platform (columns 4-15) and
    ; stands at y = 64. Row 10 is the floor's standing row (y = 160).
    ubyte[] script_kill = [10, input.DOWN, 15, 0, 60, input.DOWN, 0, 0]
    ubyte[] script_none = [0, 0]
    ubyte[] script_hop = [40, 0, 3, input.FIRE | input.DOWN, 47, 0, 4, input.FIRE, 20, input.DOWN, 30, 0,
                          4, input.FIRE, 20, input.DOWN, 0, 0]
    ubyte[] script_walk = [40, 0, 40, input.RIGHT, 0, 0]
    ubyte[] script_jump = [10, 0, 30, input.FIRE, 0, 0]
    ubyte[] script_pass = [26, 0, 40, input.RIGHT, 0, 0]
    ubyte[] script_nudge = [40, 0, 3, input.RIGHT, 60, 0, 1, input.RIGHT, 0, 0]
    ubyte[] script_cover = [40, 0, 11, input.RIGHT, 60, 0, 1, input.RIGHT, 0, 0]
    ubyte[] script_stress = [
        30, 0, 40, input.LEFT, 30, input.FIRE | input.LEFT, 20, input.RIGHT, 30, input.FIRE | input.RIGHT,
        10, input.RIGHT | input.DOWN, 40, input.RIGHT, 30, input.FIRE, 10, input.DOWN, 60, input.LEFT,
        30, input.FIRE | input.LEFT, 10, input.DOWN, 80, input.RIGHT, 30, input.FIRE, 20, input.LEFT,
        10, input.DOWN, 100, input.RIGHT, 30, input.FIRE | input.LEFT, 10, input.DOWN, 100, input.LEFT,
        30, input.FIRE | input.RIGHT, 10, input.DOWN, 120, input.RIGHT, 30, input.FIRE, 10, input.DOWN,
        120, input.LEFT, 30, input.FIRE, 10, input.DOWN, 120, input.RIGHT, 0, 0
    ]
    ubyte[] script_drill_stress = [
        30, 0,
        8, input.FIRE, 20, input.DOWN, 8, input.FIRE, 20, input.DOWN, 8, input.FIRE, 20, input.DOWN,
        8, input.FIRE, 20, input.DOWN, 8, input.FIRE, 20, input.DOWN, 8, input.FIRE, 20, input.DOWN,
        40, input.LEFT,
        8, input.FIRE, 20, input.DOWN, 8, input.FIRE, 20, input.DOWN, 8, input.FIRE, 20, input.DOWN,
        8, input.FIRE, 20, input.DOWN, 8, input.FIRE, 20, input.DOWN, 8, input.FIRE, 20, input.DOWN,
        30, input.FIRE | input.LEFT, 30, input.LEFT,
        8, input.FIRE, 20, input.DOWN, 8, input.FIRE, 20, input.DOWN, 8, input.FIRE, 20, input.DOWN,
        8, input.FIRE, 20, input.DOWN, 8, input.FIRE, 20, input.DOWN, 8, input.FIRE, 20, input.DOWN,
        30, input.FIRE | input.RIGHT, 120, input.RIGHT,
        8, input.FIRE, 20, input.DOWN, 8, input.FIRE, 20, input.DOWN, 8, input.FIRE, 20, input.DOWN,
        8, input.FIRE, 20, input.DOWN, 8, input.FIRE, 20, input.DOWN, 8, input.FIRE, 20, input.DOWN,
        30, input.FIRE | input.RIGHT, 60, input.RIGHT,
        8, input.FIRE, 20, input.DOWN, 8, input.FIRE, 20, input.DOWN, 8, input.FIRE, 20, input.DOWN,
        8, input.FIRE, 20, input.DOWN, 8, input.FIRE, 20, input.DOWN, 8, input.FIRE, 20, input.DOWN,
        120, input.LEFT, 30, input.FIRE | input.LEFT, 100, input.LEFT, 0, 0
    ]
    ubyte warn_overlap                  ; frames the player's box overlapped an enemy in WARNING
    uword hit_x                         ; TEST 25: player x when the first hit happened
    ubyte enemy_inside

    ; TEST 22 (game flow), as read by input.read() on the title, in play, while paused and at game over:
    ; title: fire after 120 frames. Level 1: Run/Stop after 40 play frames, again 150 frames later (pause);
    ; the level is completed at play frame 100. Level 2: the time is set to 3 s at play frame 10, so the game
    ; ends. Game over: fire. Title: fire after 150 frames, the second game starts.
    ubyte[] script_flow = [
        120, 0, 5, input.FIRE,
        40, 0, 2, input.STOP, 150, 0, 2, input.STOP,
        250, 0, 120, 0, 5, input.FIRE,
        150, 0, 5, input.FIRE,
        0, 0
    ]
    ubyte[] script_flow_end = [
        120, 0, 5, input.FIRE,
        40, 0, 2, input.STOP, 150, 0, 2, input.STOP,
        250, 0, 120, 0, 5, input.FIRE,
        0, 0
    ]
    ; TEST 34: frames from the start of the title (title 500, HOW TO PLAY 500, SCORING 600)
    ubyte[] script_fire_title = [150, 0, 5, input.FIRE, 0, 0]
    ubyte[] script_fire_how = [250, 0, 250, 0, 250, 0, 5, input.FIRE, 0, 0]
    ubyte[] script_fire_scoring = [250, 0, 250, 0, 250, 0, 250, 0, 200, 0, 5, input.FIRE, 0, 0]
    uword play_frames

    sub test_frame() {
        ; Runs every play frame (not while paused).
        play_frames++
        if COMPLETE_AT != 0 and play_frames == COMPLETE_AT
            score.treasures_left = 0
        if TEST == 24 {
            if play_frames == 80
                popup.show(0, 0, $15, popup.TREASURE)
            if play_frames == 90
                popup.show(319, 191, $32, 5)
        }
        if TEST == 31 {
            if play_frames == 60 {
                score.add_points($03)
                popup.show(160, 100, $03, popup.TREASURE)
            }
            if play_frames == 76 {
                score.add_points($04)
                popup.show(160, 100, $04, 2)
            }
            if play_frames == 200 {
                score.add_points($05)
                popup.show(60, 30, $05, popup.TREASURE)
            }
            if play_frames == 216 {
                score.add_points($16)
                popup.show(60, 30, $16, 4)
            }
        }
        if TEST == 22 {
            if score.level == 1 and play_frames == 100
                score.treasures_left = 0
            if score.level == 2 and play_frames == 10
                score.time = $0003
        }
    }

    sub flow_hud() {
        ; TEST 22, char row 1, hex: r=frames of the last READY? pause, g=its generation time, k=enemies
        ; destroyed this level, e=enemy 1-5 states (7 = warning), z=play frames this level, p=score.
        sys.memset(video.COLOR_RAM + 40, 40, video.COLOR_HUD)
        test_text(0, sc:"r")
        test_hex(1, ready_frames)
        test_text(4, sc:"g")
        test_hex(5, gen_frames)
        test_text(8, sc:"k")
        test_hex(9, enemies.kills)
        test_text(12, sc:"e")
        ubyte i
        for i in enemies.FIRST to enemies.LAST
            @(video.SCREEN + 40 + 12 + i) = hex_char(actors.state[i])
        test_text(19, sc:"z")
        test_hex(20, msb(play_frames))
        test_hex(22, lsb(play_frames))
        test_text(25, sc:"p")
        test_hex(26, msb(score.points))
        test_hex(28, lsb(score.points))
    }

    sub test_setup() {
        if TEST == 22 or TEST == 34
            return
        if TEST == 1 {
            spawn_soak()
            return
        }
        if TEST == 9 {
            link_soak()
            return
        }
        if TEST == 13 {
            step_timing()
            return
        }
        if TEST == 14 {
            climb_soak()
            return
        }
        ubyte idx
        bool budget = TEST == 7 or TEST == 8 or TEST == 12 or TEST == 20     ; these keep the treasures
        for idx in 0 to levelgen.CELLS - 1 {
            if not budget and video.tiles[idx] >= video.T_TREASURE {
                video.tiles[idx] = video.T_EMPTY    ; no treasure points in the score checks
                video.draw_tile(levelgen.cell_col[idx], levelgen.cell_row[idx])
            }
        }
        ubyte i
        for i in enemies.FIRST to enemies.LAST {
            actors.state[i] = enemies.DEAD
            enemies.respawn_timer[i] = 255
            enemies.timer_frames[i] = 50
        }
        enemies.frozen = true
        when TEST {
            2 -> {
                ; chain: fast-fall onto enemy 2 in the air, release down, fast-fall again onto enemy 1 on the
                ; platform. Both respawn 10 s after their kill.
                test_put(1, 154, 64, enemies.GROUNDED)
                test_put(2, 154, 20, enemies.GROUNDED)
                input.script = &script_kill
            }
            25 -> {
                ; hurt box: on the row-5 platform the player walks 3 frames right (x 154 -> 158) and stands with
                ; 3 px of sideways overlap of frozen enemy 1 (no hit), then 1 frame more (x 160, 5 px) -> hit.
                test_put(1, 167, 64, enemies.GROUNDED)
                input.script = &script_nudge
            }
            26 -> {
                ; attacks use the full box: like TEST 2, but the enemies overlap the falling player by only 2 px
                ; sideways (enemy 2 in the air to the left, enemy 1 on the platform to the right).
                test_put(1, 164, 64, enemies.GROUNDED)
                test_put(2, 144, 20, enemies.GROUNDED)
                input.script = &script_kill
            }
            27 -> {
                ; treasure coverage: a treasure at (11, 4). The player walks 11 frames right on the row-5 platform
                ; (x 154 -> 170, 6 px over the tile) and stands (not collected), then 1 frame more (x 172, 8 px).
                test_tile(11, 4, video.T_TREASURE + 0)
                input.script = &script_cover
            }
            24 -> {
                ; score popups: three treasures in the player's fall, collected within 8 frames of each other, so they
                ; merge into one popup (1800). The player falls centred in column 9 (from the spawn x it would cover
                ; no column by 8 px). test_frame() adds popups at two playfield corners 10 frames apart (clamping).
                actors.x[0] = 9 * 16 + 2
                test_tile(9, 1, video.T_TREASURE + 0)
                test_tile(9, 2, video.T_TREASURE + 4)
                test_tile(9, 3, video.T_TREASURE + 11)
                input.script = &script_none
            }
            28 -> {
                ; popup merge: fast-fall kill on a carrier (700) on the row-5 platform. A treasure (100) fills the
                ; carrier's cell, so the drop goes into (9, 3), which the player covers: it is collected a frame
                ; later -> one popup "900" in white. The 100 is collected after the bounce, as its own popup. The
                ; player falls centred in column 9 (as in TEST 24).
                actors.x[0] = 9 * 16 + 2
                test_put(1, 9 * 16 + 2, 64, enemies.GROUNDED)
                enemies.carrying[1] = 7
                test_tile(9, 4, video.T_TREASURE + 0)
                input.script = &script_down
            }
            29 -> {
                ; popup merge: fast-fall onto 3 overlapping enemies on the row-5 platform -> one popup "1400" in
                ; orange.
                test_put(1, 152, 64, enemies.GROUNDED)
                test_put(2, 154, 64, enemies.GROUNDED)
                test_put(3, 156, 64, enemies.GROUNDED)
                input.script = &script_down
            }
            30 -> {
                ; popup frame budget (FRAME_STATS): like 29, plus a treasure (1500) collected in the kill frame, so 4
                ; score events in one frame. All centred in column 9; the enemies are held at y 54, so the kill
                ; frame is the first one where the player covers the treasure at (9, 3) by 8 px.
                actors.x[0] = 9 * 16 + 2
                test_put(1, 9 * 16, 54, enemies.GROUNDED)
                test_put(2, 9 * 16 + 2, 54, enemies.GROUNDED)
                test_put(3, 9 * 16 + 4, 54, enemies.GROUNDED)
                test_tile(9, 3, video.T_TREASURE + 14)
                for i in 1 to 3
                    enemies.cooldown[i] = 255  ; they overlap the treasure: no pickup
                input.script = &script_down
            }
            32, 33 -> {
                ; carriers spread: enemies 1-3 carry from the start, the player waits on the floor at the far left.
                ; 32: on a generated level (no FORCE_FAIL). 33: the map is cleared to the floor and one platform
                ; on row 5, columns 4-15 (SHARE_SHORT: 4-6), the only hideout; the carriers start stacked on it.
                if TEST == 33 {
                    sys.memset(&video.tiles, levelgen.CELLS, video.T_EMPTY)
                    for idx in 4 to (if SHARE_SHORT 6 else 15)
                        video.tiles[video.row_start[5] + idx] = video.T_SOLID
                    video.draw_level()
                    nav.new_level()
                    for i in 1 to 3
                        test_put(i, 4 * 16 + 2, 64, enemies.GROUNDED)
                } else {
                    enemies.place_all()
                    for i in 4 to 5 {
                        actors.state[i] = enemies.DEAD
                        enemies.respawn_timer[i] = 255
                    }
                }
                for i in 1 to 3
                    enemies.carrying[i] = 1
                test_put(0, 2, 160, player.GROUNDED)
                enemies.frozen = false
                nav.no_mistakes = true
                input.script = &script_none
            }
            31 -> {
                ; popup stacking: test_frame() shows two popups 16 frames apart at the same spot (the second
                ; goes above), later two near the HUD row (the second goes below).
                input.script = &script_none
            }
            23 -> {
                ; minimum fast-fall distance: on the row-5 platform, a jump with down held (2 px rise) leaves the
                ; tile intact; a 10 px rise then fast-fall cracks it; the next one destroys it and drills on.
                input.script = &script_hop
            }
            3 -> {
                ; stomp: fall straight onto enemy 1 (frozen, so the player keeps bonking it)
                test_put(1, 154, 64, enemies.GROUNDED)
                input.script = &script_none
            }
            4 -> {
                ; walk right into enemy 1 on the platform
                test_put(1, 13 * 16 + 2, 64, enemies.GROUNDED)
                input.script = &script_walk
            }
            5 -> {
                ; player on the floor at column 7, enemy 1 in the air above; jump up into it
                actors.x[0] = 7 * 16 + 2
                actors.y[0] = 160
                actors.state[0] = player.GROUNDED
                test_put(1, 7 * 16 + 2, 120, enemies.GROUNDED)
                input.script = &script_jump
            }
            6 -> {
                ; enemy 1 starts its 1 s warning where the player lands; the player walks off it before it activates
                test_put(1, 154, 64, enemies.WARNING)
                enemies.timer_frames[1] = enemies.WARNING_FRAMES
                input.script = &script_pass
            }
            7 -> {
                ; live enemies and a scripted run around the level (frame budget)
                enemies.place_all()
                enemies.frozen = false
                input.script = &script_stress
            }
            8 -> {
                ; frame budget with respawns: like 7, but all enemies start dead and pick spots after 1 s
                enemies.place_all()
                enemies.frozen = false
                for i in enemies.FIRST to enemies.LAST {
                    actors.state[i] = enemies.DEAD
                    enemies.respawn_timer[i] = 1
                    enemies.timer_frames[i] = 50
                }
                input.script = &script_stress
            }
            12 -> {
                ; frame budget with map rebuilds: live enemies, the player drills down in several columns
                ; (kept invulnerable, so hits don't end the run)
                enemies.place_all()
                enemies.frozen = false
                input.script = &script_drill_stress
            }
            20 -> {
                ; frame budget with carriers: like 7, but every enemy starts carrying a treasure
                enemies.place_all()
                enemies.frozen = false
                for i in enemies.FIRST to enemies.LAST
                    enemies.carrying[i] = 1
                input.script = &script_stress
            }
            15 -> {
                ; pickup: one treasure on the row-4 platform at column 12. Enemy 4 (hunter) starts on that
                ; platform at column 5 and walks over it. The player waits on the floor at the far left.
                test_tile(12, 4, video.T_TREASURE + 4)
                nav.new_level()
                test_put(4, 5 * 16 + 2, 64, enemies.GROUNDED)
                test_put(0, 2, 160, player.GROUNDED)
                enemies.frozen = false
                nav.no_mistakes = true
                input.script = &script_none
            }
            16, 21 -> {
                ; stomp (16) or fast-fall kill (21) on a carrier held in the air at row 2, column 10. The drop
                ; falls from (10, 2) to the row-4 platform.
                test_put(1, 154, 32, enemies.GROUNDED)
                enemies.carrying[1] = 1
                input.script = if TEST == 16 &script_none else &script_down
            }
            17 -> {
                ; occupied drop cell: a carrier stands on a treasure at (10, 4). At frame 25 it drops its own
                ; treasure (as if stomped), which goes to (10, 3). At frame 100 the treasure at (10, 4) is removed
                ; (as if collected), so the dropped one falls into its place. The player waits on the floor.
                test_put(1, 154, 64, enemies.GROUNDED)
                enemies.carrying[1] = 1
                test_tile(10, 4, video.T_TREASURE + 9)
                test_put(0, 2, 160, player.GROUNDED)
                input.script = &script_none
            }
            18 -> {
                ; carrier flees: enemy 1 carries a treasure on the upper right platform (row 1, columns 13-18).
                ; The player climbs up to it (the TEST 10 route).
                test_put(1, 17 * 16 + 2, 16, enemies.GROUNDED)
                enemies.carrying[1] = 1
                enemies.frozen = false
                nav.no_mistakes = true
                track = 1
                input.script = &script_climb
            }
            19 -> {
                ; pickup cooldown: the player falls onto a frozen carrier on the row-4 platform, then drifts right
                ; during the bounce and walks away. The drop lands in the enemy's own cell, so it could take it
                ; back at once; the cooldown stops it for 3 s.
                test_put(1, 154, 64, enemies.GROUNDED)
                enemies.carrying[1] = 1
                input.script = &script_bonk_away
            }
            10 -> {
                ; chaser route: the player climbs to the upper right platform (row 1, columns 13-18) and waits.
                ; Enemy 1 (chaser) starts on the floor at column 2 after a 3 s warning.
                test_put(1, 2 * 16 + 2, 160, enemies.WARNING)
                enemies.timer_frames[1] = 150
                enemies.frozen = false
                nav.no_mistakes = true
                track = 1
                input.script = &script_climb
            }
            11 -> {
                ; route cut: a treasure on the row-4 platform at column 14. Enemy 4 (hunter) starts on the floor
                ; at column 18; its route goes up the left side through the take-off cell (3, 7). The player
                ; walks off the left end of the row-4 platform and drills tile (3, 8) away with two fast-falls,
                ; which cuts that route; the right side (columns 15-19, take-offs 14 and 16) remains.
                video.tiles[video.row_start[4] + 14] = video.T_TREASURE
                video.draw_tile(14, 4)
                nav.new_level()
                test_put(4, 18 * 16 + 2, 160, enemies.GROUNDED)
                enemies.frozen = false
                nav.no_mistakes = true
                track = 4
                input.script = &script_drill
            }
        }
        enemies.draw()
    }

    ; ---- TEST 9: replay every link of the platform map with the enemy physics ----
    sub link_soak() {
        ; For LINK_LEVELS levels, put enemy 1 at the far end of its platform from each link's take-off column,
        ; let nav carry the link out, and check that it lands on the link's target platform.
        ; Char row 1, hex: n=levels, l=links tested (4 digits), f=failures, t=timeouts (no landing in 600 frames),
        ; i=frames with the box inside a solid tile, k=frames for the slowest link.
        ; Row 2: first failure: level, from platform, link kind, take-off column, expected, landed on.
        ubyte n = 0
        uword tested = 0
        ubyte fails = 0
        ubyte timeouts = 0
        ubyte inside = 0
        uword slowest = 0
        if LINK_MAX_SPEED
            enemies.speed = enemies.MAX_SPEED
        ubyte i
        for i in enemies.FIRST to enemies.LAST {
            actors.state[i] = enemies.DEAD
            video.hide_sprite(i)
        }
        repeat LINK_LEVELS {
            if n != 0
                levelgen.generate(1)
            n++
            repeat LINK_HOLES {
                ; destroy a random platform tile (rows 1-9)
                repeat {
                    ubyte idx = levelgen.rand_below(levelgen.CELLS)
                    if idx >= video.MAP_W and video.tiles[idx] == video.T_SOLID {
                        video.tiles[idx] = video.T_EMPTY
                        break
                    }
                }
            }
            nav.new_level()
            ubyte p
            for p in 0 to nav.f_count - 1 {
                ubyte s = nav.plat_start[nav.fp + p]
                ubyte e = nav.plat_end[nav.fp + p]
                ubyte row = nav.plat_row[nav.fp + p]
                ubyte l = nav.plat_link[nav.fp + p]
                repeat nav.plat_nlinks[nav.fp + p] {
                    ubyte c = s
                    if nav.link_col[l] < (s + e) >> 1
                        c = e
                    test_put(1, ((c as uword) << 4) + 2, row << 4, enemies.GROUNDED)
                    actors.x_frac[1] = 0
                    actors.y_frac[1] = 0
                    enemies.walk_dir[1] = enemies.DIR_NONE
                    nav.take_link(1, l)
                    uword frames = 0
                    while nav.plan[1] != nav.PLAN_STAND and frames != 600 {
                        nav.steer(1)
                        enemies.move(1)
                        frames++
                        if box_inside(1)
                            inside++
                    }
                    if frames > slowest
                        slowest = frames
                    ubyte got = nav.platform_under(actors.x[1], actors.y[1], true)
                    if frames == 600
                        timeouts++
                    if got != nav.link_to[l] {
                        if fails == 0 {
                            ff[0] = n
                            ff[1] = p
                            ff[2] = nav.link_kind[l]
                            ff[3] = nav.link_col[l]
                            ff[4] = nav.link_to[l]
                            ff[5] = got
                        }
                        fails++
                    }
                    tested++
                    l++
                }
            }
        }
        actors.state[1] = enemies.DEAD
        video.draw_level()
        enemies.draw()
        video.hide_sprite(0)
        sys.memset(video.COLOR_RAM + 40, 80, video.COLOR_HUD)
        sys.memset(video.SCREEN + 40, 80, video.CHAR_SPACE)
        test_text(0, sc:"n")
        test_hex(1, n)
        test_text(4, sc:"l")
        test_hex(5, msb(tested))
        test_hex(7, lsb(tested))
        test_text(10, sc:"f")
        test_hex(11, fails)
        test_text(14, sc:"t")
        test_hex(15, timeouts)
        test_text(18, sc:"i")
        test_hex(19, inside)
        test_text(22, sc:"k")
        test_hex(23, msb(slowest))
        test_hex(25, lsb(slowest))
        for i in 0 to 5
            test_hex(40 + i * 3, ff[i])
        repeat {
        }
    }
    ubyte[6] ff                         ; TEST 9: first failure

    sub step_timing() {
        ; TEST 13: rebuild the map 20 times, one step per frame, and show the most raster lines one step of
        ; each stage took (rows, links, routes) and the platform count on char row 1.
        uword[4] worst = [0, 0, 0, 0]
        video.hide_sprite(0)
        if STEP_COMB {
            ; worst case: every other tile in rows 2, 3, 5, 6 and 8 (1-wide platforms, many links)
            sys.memset(&video.tiles, levelgen.CELLS, video.T_EMPTY)
            ubyte c
            for c in 0 to video.MAP_W - 1 step 2 {
                video.tiles[video.row_start[2] + c] = video.T_SOLID
                video.tiles[video.row_start[3] + c + 1] = video.T_SOLID
                video.tiles[video.row_start[5] + c] = video.T_SOLID
                video.tiles[video.row_start[6] + c + 1] = video.T_SOLID
                video.tiles[video.row_start[8] + c] = video.T_SOLID
            }
            video.draw_level()
        }
        repeat 20 {
            nav.tile_destroyed()
            while nav.stage != nav.ST_IDLE {
                ubyte st = nav.stage
                video.wait_frame()
                uword t0 = raster_line()
                void nav.build_step()
                uword t1 = raster_line()
                if t1 < t0
                    t1 += 312
                if t1 - t0 > worst[st]
                    worst[st] = t1 - t0
            }
        }
        sys.memset(video.COLOR_RAM + 40, 40, video.COLOR_HUD)
        ubyte k
        for k in 1 to 3 {
            test_hex(k * 6, msb(worst[k]))
            test_hex(k * 6 + 2, lsb(worst[k]))
        }
        test_hex(30, nav.f_count)
        repeat {
        }
    }

    uword cells_ok
    uword cells_all

    sub climb_soak() {
        ; TEST 14: over SOAK_COUNT generated levels, how far enemies can climb from the floor by the
        ; platform map's links. Char row 1, hex: n=levels, a=levels where the floor reaches every platform
        ; (row-0 platforms not counted), t=levels where it reaches the top band (standing row 3 or higher),
        ; s=levels where it reaches the player's start landing platform, m=band 2 (standing rows 4-6).
        ubyte n = 0
        ubyte all = 0
        ubyte top = 0
        ubyte start = 0
        ubyte mid = 0
        repeat SOAK_COUNT {
            levelgen.generate(1)
            nav.new_level()
            n++
            ubyte fl = nav.f_count - 1  ; the floor row is scanned last
            bool got_all = true
            bool got_top = false
            bool got_mid = false
            ubyte p
            for p in 0 to nav.f_count - 1 {
                ubyte r = nav.plat_row[nav.fp + p]
                if nav.hops(fl, p) == nav.NONE {
                    if r != 0
                        got_all = false
                } else {
                    if r <= 3
                        got_top = true
                    else if r <= 6
                        got_mid = true
                }
            }
            if got_all
                all++
            if got_top
                top++
            if got_mid
                mid++
            ; standing cells (of mapped platforms) that enemies on the floor can reach
            ubyte idx
            for idx in 0 to levelgen.CELLS - 1 {
                ubyte q = nav.platform_at(idx)
                if q != nav.NONE {
                    cells_all++
                    if nav.hops(fl, q) != nav.NONE
                        cells_ok++
                }
            }
            ubyte sp = nav.platform_under(player.START_X, 0, false)
            if sp != nav.NONE and nav.hops(fl, sp) != nav.NONE
                start++
        }
        video.draw_level()
        sys.memset(video.COLOR_RAM + 40, 40, video.COLOR_HUD)
        test_text(0, sc:"n")
        test_hex(1, n)
        test_text(4, sc:"a")
        test_hex(5, all)
        test_text(8, sc:"t")
        test_hex(9, top)
        test_text(12, sc:"s")
        test_hex(13, start)
        test_text(16, sc:"m")
        test_hex(17, mid)
        test_text(20, sc:"c")
        test_hex(21, msb(cells_ok))
        test_hex(23, lsb(cells_ok))
        test_hex(26, msb(cells_all))
        test_hex(28, lsb(cells_all))
        repeat {
        }
    }

    sub box_inside(ubyte i) -> bool {
        uword bx = actors.x[i]
        ubyte by = actors.y[i]
        return actors.solid_at(bx, by) or actors.solid_at(bx + actors.BOX_W - 1, by)
                or actors.solid_at(bx, by + actors.BOX_H - 1) or actors.solid_at(bx + actors.BOX_W - 1, by + actors.BOX_H - 1)
    }

    ; ---- TEST 10-11 readout: route history of enemy `track` ----
    ubyte[] script_climb = [30, 0, 26, input.RIGHT, 20, input.FIRE, 25, input.FIRE | input.RIGHT, 10, input.RIGHT, 0, 0]
    ubyte[] script_drill = [30, 0, 75, input.LEFT | input.DOWN, 20, 0, 8, input.FIRE, 20, input.DOWN, 0, 0]
    ubyte track
    ubyte[8] hist_plat
    ubyte hist_n
    ubyte[8] hist_col
    ubyte hist_cn
    ubyte last_takes
    uword test_frames
    uword reached_at                    ; frame when the tracked enemy first stood on its target platform

    sub route_hud() {
        ; Row 1: p=platforms the enemy stood on, in order (ids of the map in use at the time); c=take-off
        ; columns of the links it took (repeats of the same link left out). Row 2: r=map rebuilds,
        ; d/m/w=route decisions, mistakes, wanders, a=frame when it reached its target, s=player state and y,
        ; z=frame count, e=player platform and the enemy's target platform.
        test_frames++
        ubyte i = track
        if actors.state[i] == enemies.GROUNDED {
            ubyte p = nav.platform_under(actors.x[i], actors.y[i], true)
            if (hist_n == 0 or hist_plat[hist_n - 1] != p) and hist_n < len(hist_plat) {
                hist_plat[hist_n] = p
                hist_n++
            }
            if reached_at == 0 and p != nav.NONE and p == nav.dbg_target[i] and nav.dbg_plat[i] == p
                reached_at = test_frames
        }
        if nav.dbg_takes[i] != last_takes {
            last_takes = nav.dbg_takes[i]
            ubyte c = nav.link_col[nav.dbg_link[i]]
            if (hist_cn == 0 or hist_col[hist_cn - 1] != c) and hist_cn < len(hist_col) {
                hist_col[hist_cn] = c
                hist_cn++
            }
        }
        if test_frames == 1 {
            sys.memset(video.COLOR_RAM + 40, 80, video.COLOR_HUD)
            sys.memset(video.SCREEN + 40, 80, video.CHAR_SPACE)
        }
        test_text(0, sc:"p")
        for i in 0 to 7 {
            if i < hist_n
                test_hex(1 + i * 2, hist_plat[i])
        }
        test_text(18, sc:"c")
        for i in 0 to 7 {
            if i < hist_cn
                test_hex(19 + i * 2, hist_col[i])
        }
        test_text(40, sc:"r")
        test_hex(41, nav.rebuilds)
        test_text(44, sc:"d")
        test_hex(45, nav.n_routes)
        test_text(47, sc:"m")
        test_hex(48, nav.n_mistakes)
        test_text(50, sc:"w")
        test_hex(51, nav.n_wanders)
        test_text(54, sc:"a")
        test_hex(55, msb(reached_at))
        test_hex(57, lsb(reached_at))
        test_text(60, sc:"s")
        test_hex(61, actors.state[0])
        test_hex(63, actors.y[0])
        test_text(66, sc:"z")
        test_hex(67, msb(test_frames))
        test_hex(69, lsb(test_frames))
        test_text(72, sc:"e")
        test_hex(73, nav.platform_under(actors.x[0], actors.y[0], actors.state[0] == player.GROUNDED))
        test_hex(76, nav.dbg_target[track])
    }

    sub spawn_soak() {
        ; TEST 1: generate SOAK_COUNT levels and place the enemies on each. Char row 1, hex: n=levels,
        ; s=enemies not on a standing cell, d=closer than 8 to the player start, a=two enemies closer than 3,
        ; m=smallest player distance seen. The last level stays on screen.
        ubyte n = 0
        ubyte bad_stand = 0
        ubyte bad_dist = 0
        ubyte bad_space = 0
        ubyte min_dist = 255
        ubyte i
        ubyte j
        repeat SOAK_COUNT {
            levelgen.generate(1)
            player.init()
            enemies.place_all()
            n++
            for i in enemies.FIRST to enemies.LAST {
                ubyte c = enemies.col_of(i)
                ubyte r = actors.y[i] >> 4
                if actors.x[i] & 15 != 2 or actors.y[i] & 15 != 0 or not enemies.standing(video.row_start[r] + c)
                    bad_stand++
                ubyte d = abs_diff(c, 10) + r          ; player start cell: column 10, row 0
                if d < enemies.PLAYER_DIST
                    bad_dist++
                if d < min_dist
                    min_dist = d
                for j in i + 1 to enemies.LAST {
                    if abs_diff(c, enemies.col_of(j)) < 3 and abs_diff(r, actors.y[j] >> 4) < 3
                        bad_space++
                }
            }
        }
        video.draw_level()
        enemies.draw()
        sys.memset(video.COLOR_RAM + 40, 40, video.COLOR_HUD)
        test_text(0, sc:"n")
        test_hex(1, n)
        test_text(4, sc:"s")
        test_hex(5, bad_stand)
        test_text(8, sc:"d")
        test_hex(9, bad_dist)
        test_text(12, sc:"a")
        test_hex(13, bad_space)
        test_text(16, sc:"m")
        test_hex(17, min_dist)
        repeat {
        }
    }

    sub test_tile(ubyte col, ubyte row, ubyte t) {
        video.tiles[video.row_start[row] + col] = t
        video.draw_tile(col, row)
    }

    ; ---- TEST 15-21 readout: treasure carrying ----
    ubyte[] script_down = [60, input.DOWN, 0, 0]
    ubyte[] script_bonk_away = [19, 0, 40, input.RIGHT, 0, 0]
    uword carry_frames
    uword first_drop                    ; frame of the first drop
    uword retake                        ; frame of the first pickup after the first drop
    ubyte last_pickups
    ubyte max_hops                      ; TEST 18: most hops from the player's platform to the carrier's
    ubyte on_player_plat                ; TEST 18: frames the carrier stood on the player's platform

    sub carry_hud() {
        ; Row 1: c=carrying of enemies 1-5, d=drops, u=pickups, f=falling treasures, a=frame of the first drop,
        ; r=frame of the first pickup after it, z=frame count.
        ; Row 2: t=tiles at (10, 2), (10, 3), (10, 4), k=kills, b=bonks, p=score (BCD hundreds),
        ; n=enemy 1 cooldown, s=player state.
        ; TEST 18 adds to the route readout, row 3: c, d, u, f as above, h=hops from the player's platform to
        ; the carrier's, m=most seen, o=frames the carrier stood on the player's platform (player grounded),
        ; q=its hideout, e=its platform.
        carry_frames++
        if TEST == 17 {
            if carry_frames == 25
                enemies.drop(1)
            if carry_frames == 100
                test_tile(10, 4, video.T_EMPTY)
        }
        if enemies.n_drops != 0 and first_drop == 0
            first_drop = carry_frames
        if enemies.n_pickups != last_pickups {
            last_pickups = enemies.n_pickups
            if first_drop != 0 and retake == 0
                retake = carry_frames
        }
        ubyte base = 0
        if TEST == 18 {
            route_hud()
            base = 80
            ubyte e = nav.NONE
            if actors.state[1] == enemies.GROUNDED
                e = nav.platform_under(actors.x[1], actors.y[1], true)
            ubyte p = nav.platform_under(actors.x[0], actors.y[0], actors.state[0] == player.GROUNDED)
            ubyte h = nav.NONE
            if e != nav.NONE and p != nav.NONE {
                h = nav.hops(p, e)
                if h != nav.NONE and h > max_hops
                    max_hops = h
                if e == p and actors.state[0] == player.GROUNDED
                    on_player_plat++
            }
            test_text(base + 20, sc:"h")
            test_hex(base + 21, h)
            test_text(base + 24, sc:"m")
            test_hex(base + 25, max_hops)
            test_text(base + 28, sc:"o")
            test_hex(base + 29, on_player_plat)
            test_text(base + 32, sc:"q")
            test_hex(base + 33, nav.hideout[1])
            test_text(base + 36, sc:"e")
            test_hex(base + 37, e)
            sys.memset(video.COLOR_RAM + 40 + base, 40, video.COLOR_HUD)
        } else {
            sys.memset(video.COLOR_RAM + 40, 80, video.COLOR_HUD)
            if carry_frames == 1
                sys.memset(video.SCREEN + 40, 80, video.CHAR_SPACE)
        }
        test_text(base + 0, sc:"c")
        ubyte i
        for i in enemies.FIRST to enemies.LAST
            @(video.SCREEN + 40 + base + i) = hex_char(enemies.carrying[i])
        test_text(base + 7, sc:"d")
        test_hex(base + 8, enemies.n_drops)
        test_text(base + 11, sc:"u")
        test_hex(base + 12, enemies.n_pickups)
        test_text(base + 15, sc:"f")
        test_hex(base + 16, enemies.fall_count)
        if TEST == 18
            return
        test_text(19, sc:"a")
        test_hex(20, msb(first_drop))
        test_hex(22, lsb(first_drop))
        test_text(25, sc:"r")
        test_hex(26, msb(retake))
        test_hex(28, lsb(retake))
        test_text(31, sc:"z")
        test_hex(32, msb(carry_frames))
        test_hex(34, lsb(carry_frames))
        test_text(40, sc:"t")
        test_hex(41, video.tiles[video.row_start[2] + 10])
        test_hex(43, video.tiles[video.row_start[3] + 10])
        test_hex(45, video.tiles[video.row_start[4] + 10])
        test_text(48, sc:"k")
        test_hex(49, enemies.n_kills)
        test_text(52, sc:"b")
        test_hex(53, enemies.n_bonks)
        test_text(56, sc:"p")
        test_hex(57, msb(score.points))
        test_hex(59, lsb(score.points))
        test_text(62, sc:"n")
        test_hex(63, enemies.cooldown[1])
        test_text(66, sc:"s")
        test_hex(67, actors.state[0])
    }

    sub test_put(ubyte i, uword px, ubyte py, ubyte st) {
        actors.x[i] = px
        actors.y[i] = py
        actors.state[i] = st
        actors.vy[i] = 0
    }

    sub test_hud() {
        if TEST == 34
            return
        if TEST == 22 {
            flow_hud()
            return
        }
        if TEST == 12 or (FRAME_STATS and (TEST == 7 or TEST == 8 or TEST == 20 or TEST == 30)) {
            ; no readout (it would take too long here, and the next frame would start late): HUD cols 30-35 =
            ; map rebuilds, dropped frames, col 26 = slowest rebuild in frames. TEST 30: HUD col 0 = most score
            ; events in one frame, col 1 = most popup digit draws in one frame.
            if TEST == 12
                player.invuln_timer = 8
            if TEST == 30 {
                count_popups()
                hex_digit(0, most_shows)
                hex_digit(1, most_draws)
            }
            hex_byte(30, nav.rebuilds)
            hex_byte(33, video.late_frames)
            hex_byte(26, nav.slowest_build)
            return
        }
        if TEST == 10 or TEST == 11 {
            route_hud()
            return
        }
        if TEST >= 15 and TEST <= 21 and TEST != 20 {
            carry_hud()
            return
        }
        if TEST == 32 or TEST == 33 {
            spread_hud()
            return
        }
        ; char row 1: s=player state y=player y c=chain i=invuln frames k/b/h=kills, bonks, hits
        ; e=enemy 1-5 states (6 dead, 7 warning) w=frames the player overlapped a warning enemy
        ; cols 38-39: frames with an active enemy's box inside a solid tile
        ubyte i
        for i in enemies.FIRST to enemies.LAST {
            if actors.state[i] < enemies.DEAD {
                uword bx = actors.x[i]
                ubyte by = actors.y[i]
                if actors.solid_at(bx, by) or actors.solid_at(bx + actors.BOX_W - 1, by)
                        or actors.solid_at(bx, by + actors.BOX_H - 1) or actors.solid_at(bx + actors.BOX_W - 1, by + actors.BOX_H - 1)
                    enemy_inside++
            }
            if actors.state[i] == enemies.WARNING and actors.x[0] < actors.x[i] + actors.BOX_W and actors.x[i] < actors.x[0] + actors.BOX_W
                    and actors.y[0] < actors.y[i] + actors.BOX_H and actors.y[i] < actors.y[0] + actors.BOX_H
                warn_overlap++
        }
        sys.memset(video.COLOR_RAM + 40, 40, video.COLOR_HUD)
        test_text(0, sc:"s")
        test_hex(1, actors.state[0])
        test_text(4, sc:"y")
        test_hex(5, actors.y[0])
        test_text(8, sc:"c")
        test_hex(9, player.chain)
        test_text(12, sc:"i")
        test_hex(13, player.invuln_timer)
        test_text(16, sc:"k")
        test_hex(17, enemies.n_kills)
        test_text(20, sc:"b")
        test_hex(21, enemies.n_bonks)
        test_text(24, sc:"h")
        test_hex(25, enemies.n_hits)
        test_text(28, sc:"e")
        for i in enemies.FIRST to enemies.LAST
            @(video.SCREEN + 40 + 28 + i) = hex_char(actors.state[i])
        test_text(35, sc:"w")
        test_hex(36, warn_overlap)
        test_hex(38, enemy_inside)
        if TEST >= 25 and TEST <= 27 {
            ; char row 2: x=player x, a=player x at the first hit, t=tile at (11, 4)
            if enemies.n_hits != 0 and hit_x == 0
                hit_x = actors.x[0]
            sys.memset(video.COLOR_RAM + 80, 40, video.COLOR_HUD)
            test_text(40, sc:"x")
            test_hex(41, msb(actors.x[0]))
            test_hex(43, lsb(actors.x[0]))
            test_text(46, sc:"a")
            test_hex(47, msb(hit_x))
            test_hex(49, lsb(hit_x))
            test_text(52, sc:"t")
            test_hex(53, video.tiles[video.row_start[4] + 11])
        }
        if TEST >= 28 and TEST <= 31
            popup_hud()
        hex_byte(30, nav.rebuilds)      ; HUD row: map rebuilds this level, dropped frames
        hex_byte(33, video.late_frames)
    }

    ; ---- TEST 32-33 readout: carriers spread ----
    ubyte[4] last_hide
    ubyte[4] hide_changes
    uword stacked                       ; frames with two carriers on one platform less than 8 px apart

    sub spread_hud() {
        ; Row 1, per carrier 1-3 (from cols 0, 13, 26): e=its platform (ff = airborne), its hideout, number of
        ; hideout changes after play frame 250 (5 s), its x. Row 2: z=play frames, s=stacked frames after 250.
        ubyte i
        ubyte j
        ubyte[4] plat
        for i in 1 to 3 {
            plat[i] = nav.NONE
            if actors.state[i] == enemies.GROUNDED
                plat[i] = nav.platform_under(actors.x[i], actors.y[i], true)
            if play_frames > 250 and nav.hideout[i] != last_hide[i]
                hide_changes[i]++
            last_hide[i] = nav.hideout[i]
        }
        if play_frames > 250 {
            for i in 1 to 2 {
                for j in i + 1 to 3 {
                    if plat[i] != nav.NONE and plat[i] == plat[j] and abs_diff(lsb(actors.x[i] >> 1), lsb(actors.x[j] >> 1)) < 4
                        stacked++
                }
            }
        }
        if play_frames == 1
            sys.memset(video.SCREEN + 40, 80, video.CHAR_SPACE)
        sys.memset(video.COLOR_RAM + 40, 80, video.COLOR_HUD)
        ubyte col = 0
        for i in 1 to 3 {
            test_text(col, sc:"e")
            test_hex(col + 1, plat[i])
            test_hex(col + 3, nav.hideout[i])
            test_hex(col + 6, hide_changes[i])
            test_hex(col + 8, msb(actors.x[i]))
            test_hex(col + 10, lsb(actors.x[i]))
            col += 13
        }
        test_text(40, sc:"z")
        test_hex(41, msb(play_frames))
        test_hex(43, lsb(play_frames))
        test_text(46, sc:"s")
        test_hex(47, msb(stacked))
        test_hex(49, lsb(stacked))
    }

    ubyte popup_shows                   ; TEST 28-31
    ubyte popup_draws
    ubyte most_shows
    ubyte most_draws

    sub count_popups() {
        if popup.n_shows - popup_shows > most_shows
            most_shows = popup.n_shows - popup_shows
        if popup.n_draws - popup_draws > most_draws
            most_draws = popup.n_draws - popup_draws
        popup_shows = popup.n_shows
        popup_draws = popup.n_draws
    }

    sub popup_hud() {
        ; char row 2: v=popup values (slot 0, 1), r=ranks, y=sprite y, t=timers, m=most score events in one
        ; frame, d=most digit draws in one frame, z=play frames
        count_popups()
        sys.memset(video.COLOR_RAM + 80, 40, video.COLOR_HUD)
        test_text(40, sc:"v")
        test_hex(41, popup.value[0])
        test_hex(43, popup.value[1])
        test_text(46, sc:"r")
        test_hex(47, popup.rank[0] << 4 | popup.rank[1])
        test_text(50, sc:"y")
        test_hex(51, video.spr_y[popup.FIRST_SPRITE])
        test_hex(53, video.spr_y[popup.FIRST_SPRITE + 1])
        test_text(56, sc:"t")
        test_hex(57, popup.timer[0])
        test_hex(59, popup.timer[1])
        test_text(62, sc:"m")
        test_hex(63, most_shows)
        test_text(66, sc:"d")
        test_hex(67, most_draws)
        test_text(70, sc:"z")
        test_hex(71, msb(play_frames))
        test_hex(73, lsb(play_frames))
    }

    sub test_text(ubyte col, str text) {
        @(video.SCREEN + 40 + col) = text[0]
    }

    sub test_hex(ubyte col, ubyte value) {
        @(video.SCREEN + 40 + col) = hex_char(value >> 4)
        @(video.SCREEN + 41 + col) = hex_char(value & 15)
    }

    sub hex_char(ubyte n) -> ubyte {
        return if n < 10 n + 48 else n - 9
    }

    sub nav_debug() {
        ubyte i
        ubyte col = 0
        for i in enemies.FIRST to enemies.LAST {
            hex_byte(col, nav.dbg_plat[i])
            hex_byte(col + 2, nav.dbg_target[i])
            hex_digit(col + 4, nav.plan[i])
            @(video.SCREEN + col + 5) = video.CHAR_SPACE
            col += 6
        }
        sys.memset(video.SCREEN + col, 40 - col, video.CHAR_SPACE)
        hex_byte(38, nav.rebuilds)
    }

    ; ---- self-test readout ----
    ubyte dbg_frames
    ubyte dbg_peak = 255
    ubyte dbg_land_y
    uword dbg_ff_x
    uword dbg_land_x
    ubyte dbg_inside
    ubyte dbg_prev_state

    sub debug_hud() {
        ubyte st = actors.state[0]
        if st != player.GROUNDED and dbg_prev_state == player.GROUNDED
            dbg_peak = 255
        if st != player.GROUNDED and actors.y[0] < dbg_peak
            dbg_peak = actors.y[0]
        if st == player.FASTFALL and dbg_prev_state != player.FASTFALL
            dbg_ff_x = actors.x[0]
        if st == player.GROUNDED and dbg_prev_state != player.GROUNDED {
            dbg_land_y = actors.y[0]
            dbg_land_x = actors.x[0]
        }
        dbg_prev_state = st
        uword bx = actors.x[0]
        ubyte by = actors.y[0]
        if actors.solid_at(bx, by) or actors.solid_at(bx + actors.BOX_W - 1, by)
                or actors.solid_at(bx, by + actors.BOX_H - 1) or actors.solid_at(bx + actors.BOX_W - 1, by + actors.BOX_H - 1)
            dbg_inside++
        if dbg_frames == 0
            sys.memset(video.SCREEN, 40, video.CHAR_SPACE)
        dbg_frames++

        video.hud_text(0, sc:"x")
        hex_word(1, bx)
        video.hud_text(6, sc:"y")
        hex_byte(7, by)
        video.hud_text(10, sc:"s")
        hex_byte(11, st)
        video.hud_text(14, sc:"p")
        hex_byte(15, dbg_peak)
        video.hud_text(18, sc:"l")
        hex_byte(19, dbg_land_y)
        video.hud_text(22, sc:"f")
        hex_word(23, dbg_ff_x)
        video.hud_text(28, sc:"g")
        hex_word(29, dbg_land_x)
        video.hud_text(34, sc:"e")
        hex_byte(35, dbg_inside)
        video.hud_text(37, sc:"n")
        hex_byte(38, dbg_frames)
    }

    sub hex_byte(ubyte col, ubyte value) {
        hex_digit(col, value >> 4)
        hex_digit(col + 1, value & 15)
    }

    sub hex_word(ubyte col, uword value) {
        hex_byte(col, msb(value))
        hex_byte(col + 2, lsb(value))
    }

    sub hex_digit(ubyte col, ubyte n) {
        ; screen codes: '0'-'9' = 48-57, 'a'-'f' = 1-6
        @(video.SCREEN + col) = if n < 10 n + 48 else n - 9
    }
}
