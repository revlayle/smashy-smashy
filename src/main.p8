; C64 platformer. Phase 5b: generated levels with tile damage, treasures, score, timer and enemies (navigation AI).

%import video
%import input
%import player
%import enemies
%import nav
%import score
%import levelgen
%zeropage basicsafe
%memtop $C000

main {
    ; Self-test readout on the HUD row instead of SCORE/TIME/LEVEL. Keep false in builds for the designer.
    ; x=box x  y=box y  s=state  p=highest y of the last air trip  l=y at last landing
    ; f=x at fast-fall start  g=x at last landing  e=frames with the box inside a solid tile  n=frame count
    const bool DEBUG_HUD = false

    ; Debug key: F1 generates a new level instantly (timer and score kept).
    const bool REGEN_KEY = true
    const ubyte KEY_F1 = 133

    ; Self-test: after each generation, HUD cols 0-1 = attempts in hex (+$80 = fallback layout),
    ; col 2 = level check result (0 = ok, see check_level), cols 38-39 = generation time in frames (hex).
    const bool GEN_STATS = false
    ; Self-test: generate SOAK_COUNT levels at startup, then freeze with the results on the HUD row (see soak()).
    const bool GEN_SOAK = false
    const ubyte SOAK_COUNT = 200

    ; Self-test: worst frame in raster lines, from the frame IRQ line (so the KERNAL IRQ counts) to the end of
    ; the HUD update, hex on HUD cols 37-39. Over 312 (PAL lines per frame) means a dropped frame; the jiffy
    ; clock (ticked by the frame IRQ) counts the whole frames that passed.
    const bool FRAME_STATS = false
    ; Self-test scenario (0 = off). Sets up enemies and the input script after each level load and shows a
    ; readout on char row 1 (see test_setup and test_hud). Needs input.SCRIPTED; 2-6 and 10-11 need
    ; levelgen.FORCE_FAIL, 7-8 (frame budget) need FRAME_STATS. 9 (link replay) needs neither.
    const ubyte TEST = 0
    const ubyte LINK_LEVELS = 20        ; TEST 9: levels to check
    const ubyte LINK_HOLES = 0          ; TEST 9: random platform tiles destroyed in each level before the check
    const bool LINK_MAX_SPEED = false   ; TEST 9: enemies at the level-11 speed cap instead of level 1
    const bool STEP_COMB = false        ; TEST 13: time the rebuild on a worst-case layout with many platforms

    ; Debug view: HUD row shows, per enemy, its platform and its target platform at the last decision
    ; (hex, "ff" = none) and its plan (0 stand, 1 walk to a spot, 2 wander, 3 walk off, 4 jump), then the
    ; number of finished map rebuilds.
    const bool NAV_DEBUG = false

    sub start() {
        video.init()
        video.draw_hud_labels()
        video.hud_level($01)
        score.new_game()
        levelgen.init()
        levelgen.seed()
        video.start_frame_irq()         ; first, so the jiffy clock counts frames while generating
        if GEN_SOAK
            soak()
        load_level()

        repeat {
            video.wait_frame()
            if FRAME_STATS
                frame_jiffy = cbm.TIME_LO
            input.read()
            player.update()
            enemies.update()
            enemies.contact()
            player.draw()
            enemies.draw()
            if DEBUG_HUD
                debug_hud()
            if NAV_DEBUG
                nav_debug()
            if REGEN_KEY and cbm.GETIN2() == KEY_F1
                load_level()
            if score.treasures_left == 0
                level_complete()
            else if score.tick()
                game_over()
            nav.idle_build()            ; last: map rebuild slices only use the time left in the frame
            if FRAME_STATS
                frame_stats()
            if TEST != 0
                test_hud()
        }
    }

    ; ---- frame budget self-test ----
    uword worst_lines
    ubyte frame_jiffy

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
        repeat cbm.TIME_LO - frame_jiffy
            lines += 312
        if lines > worst_lines {
            worst_lines = lines
            hex_digit(37, msb(worst_lines))
            hex_byte(38, lsb(worst_lines))
        }
    }

    sub load_level() {
        ubyte t0 = cbm.TIME_LO
        levelgen.generate(1)
        ubyte frames = cbm.TIME_LO - t0
        video.draw_level()
        score.new_level()
        player.init()
        player.draw()
        nav.new_level()
        enemies.new_level(1)
        enemies.place_all()
        enemies.draw()
        if TEST != 0
            test_setup()
        video.frame_ready = false       ; IRQs set it while loading; start the next frame on a fresh one
        if GEN_STATS {
            hex_byte(0, if levelgen.used_fallback levelgen.attempts | $80 else levelgen.attempts)
            hex_digit(2, check_level())
            hex_byte(38, frames)
        }
    }

    sub level_complete() {
        ; Placeholder: show the message for 2 s (timer paused), then generate a new level with more time.
        video.message(7, 13, sc:"level complete")
        repeat 100 {
            video.wait_frame()
            input.read()
        }
        load_level()
        score.add_time(score.LEVEL_TIME_BONUS)
    }

    sub game_over() {
        ; Placeholder: freeze with the message on screen.
        video.message(7, 15, sc:"game over")
        repeat {
            video.wait_frame()
        }
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
            ubyte t0 = cbm.TIME_LO
            levelgen.generate(1)
            ubyte frames = cbm.TIME_LO - t0
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
    ubyte[] script_walk = [40, 0, 40, input.RIGHT, 0, 0]
    ubyte[] script_jump = [10, 0, 30, input.FIRE, 0, 0]
    ubyte[] script_pass = [26, 0, 40, input.RIGHT, 0, 0]
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
        8, input.FIRE | input.DOWN, 20, 0, 8, input.FIRE | input.DOWN, 20, 0, 8, input.FIRE | input.DOWN, 20, 0,
        8, input.FIRE | input.DOWN, 20, 0, 8, input.FIRE | input.DOWN, 20, 0, 8, input.FIRE | input.DOWN, 20, 0,
        40, input.LEFT,
        8, input.FIRE | input.DOWN, 20, 0, 8, input.FIRE | input.DOWN, 20, 0, 8, input.FIRE | input.DOWN, 20, 0,
        8, input.FIRE | input.DOWN, 20, 0, 8, input.FIRE | input.DOWN, 20, 0, 8, input.FIRE | input.DOWN, 20, 0,
        30, input.FIRE | input.LEFT, 30, input.LEFT,
        8, input.FIRE | input.DOWN, 20, 0, 8, input.FIRE | input.DOWN, 20, 0, 8, input.FIRE | input.DOWN, 20, 0,
        8, input.FIRE | input.DOWN, 20, 0, 8, input.FIRE | input.DOWN, 20, 0, 8, input.FIRE | input.DOWN, 20, 0,
        30, input.FIRE | input.RIGHT, 120, input.RIGHT,
        8, input.FIRE | input.DOWN, 20, 0, 8, input.FIRE | input.DOWN, 20, 0, 8, input.FIRE | input.DOWN, 20, 0,
        8, input.FIRE | input.DOWN, 20, 0, 8, input.FIRE | input.DOWN, 20, 0, 8, input.FIRE | input.DOWN, 20, 0,
        30, input.FIRE | input.RIGHT, 60, input.RIGHT,
        8, input.FIRE | input.DOWN, 20, 0, 8, input.FIRE | input.DOWN, 20, 0, 8, input.FIRE | input.DOWN, 20, 0,
        8, input.FIRE | input.DOWN, 20, 0, 8, input.FIRE | input.DOWN, 20, 0, 8, input.FIRE | input.DOWN, 20, 0,
        120, input.LEFT, 30, input.FIRE | input.LEFT, 100, input.LEFT, 0, 0
    ]
    ubyte warn_overlap                  ; frames the player's box overlapped an enemy in WARNING
    ubyte enemy_inside

    sub test_setup() {
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
        for idx in 0 to levelgen.CELLS - 1 {
            if video.tiles[idx] >= video.T_TREASURE {
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
    ubyte[] script_drill = [30, 0, 75, input.LEFT | input.DOWN, 20, 0, 10, input.FIRE | input.DOWN, 0, 0]
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

    sub test_put(ubyte i, uword px, ubyte py, ubyte st) {
        actors.x[i] = px
        actors.y[i] = py
        actors.state[i] = st
        actors.vy[i] = 0
    }

    sub test_hud() {
        if TEST == 12 {
            ; no readout (it would take too long here): HUD cols 30-35 = map rebuilds, dropped frames
            player.invuln_timer = 8
            hex_byte(30, nav.rebuilds)
            hex_byte(33, video.late_frames)
            hex_byte(26, nav.slowest_build)
            return
        }
        if TEST == 10 or TEST == 11 {
            route_hud()
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
        hex_byte(30, nav.rebuilds)      ; HUD row: map rebuilds this level, dropped frames
        hex_byte(33, video.late_frames)
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
