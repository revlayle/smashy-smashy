; C64 platformer. Phase 4: generated levels with tile damage, treasures, score and timer.

%import video
%import input
%import player
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
            input.read()
            player.update()
            player.draw()
            if DEBUG_HUD
                debug_hud()
            if REGEN_KEY and cbm.GETIN2() == KEY_F1
                load_level()
            if score.treasures_left == 0
                level_complete()
            else if score.tick()
                game_over()
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
