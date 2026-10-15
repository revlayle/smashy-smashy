; C64 platformer. Phase 3: hand-made test level with tile damage, treasures, score and timer.

%import video
%import input
%import player
%import score
%zeropage basicsafe
%memtop $C000

main {
    ; Self-test readout on the HUD row instead of SCORE/TIME/LEVEL. Keep false in builds for the designer.
    ; x=box x  y=box y  s=state  p=highest y of the last air trip  l=y at last landing
    ; f=x at fast-fall start  g=x at last landing  e=frames with the box inside a solid tile  n=frame count
    const bool DEBUG_HUD = false

    ; Test level with every tile type.
    ;   . empty  # solid  % damaged  = floor  a-o treasures 0-14
    ;   r0  ....................
    ;   r1  ..a.b..........c.d..
    ;   r2  .#####%.......%####.
    ;   r3  ....................
    ;   r4  ......e.f.g.h.......
    ;   r5  ...#####%%%%%###....
    ;   r6  ....................
    ;   r7  .i.j............k.l.
    ;   r8  ####%..........%####
    ;   r9  ......m...n...o.....
    ;   r10 ....######%%####....
    ;   r11 ====================
    ubyte[240] test_level = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 16, 0, 17, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 18, 0, 19, 0, 0,
        0, 1, 1, 1, 1, 1, 2, 0, 0, 0, 0, 0, 0, 0, 2, 1, 1, 1, 1, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 20, 0, 21, 0, 22, 0, 23, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 1, 1, 1, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 24, 0, 25, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 26, 0, 27, 0,
        1, 1, 1, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 1, 1, 1, 1,
        0, 0, 0, 0, 0, 0, 28, 0, 0, 0, 29, 0, 0, 0, 30, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 2, 2, 1, 1, 1, 1, 0, 0, 0, 0,
        3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3
    ]

    sub start() {
        video.init()
        video.draw_hud_labels()
        video.hud_level($01)
        score.new_game()
        load_level()
        video.start_frame_irq()

        repeat {
            video.wait_frame()
            input.read()
            player.update()
            player.draw()
            if DEBUG_HUD
                debug_hud()
            if score.treasures_left == 0
                level_complete()
            else if score.tick()
                game_over()
        }
    }

    sub load_level() {
        sys.memcopy(&test_level, &video.tiles, len(test_level))
        video.draw_level()
        score.new_level()
        player.init()
        player.draw()
    }

    sub level_complete() {
        ; Placeholder: show the message for 2 s (timer paused), then reload the test level with more time.
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
