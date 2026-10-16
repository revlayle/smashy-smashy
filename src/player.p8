; Player states and movement (spec section 5). Run, jump, fall, fast-fall with tile damage, treasure pickup,
; kill launch, stomp bounce, and the float back to the start after a hit.

%import actors
%import input
%import score
%import nav
%import sound

player {
    const ubyte GROUNDED = 0
    const ubyte RISING = 1
    const ubyte FALLING = 2
    const ubyte FASTFALL = 3
    const ubyte LAUNCHED = 4            ; rising after a kill or stomp: no fire control, air control
    const ubyte FLOATING = 5            ; flying back to the start after a hit

    ; [TUNE] speeds in 1/16 px per frame
    const ubyte RUN_SPEED = 24
    const ubyte RISE_SPEED = 40
    const ubyte JUMP_HEIGHT = 96        ; px
    const ubyte GRAVITY = 4
    const ubyte MAX_FALL = 64
    const ubyte FASTFALL_SPEED = 96
    const ubyte KILL_LAUNCH = 32        ; px
    const ubyte BOUNCE = 24             ; px
    const ubyte FLOAT_SPEED = 4         ; px per frame along the longer axis
    const ubyte INVULN_FRAMES = 100
    const ubyte FF_MIN_DIST = 8         ; px of fast-fall before it can damage a tile
    const ubyte TREASURE_COVER = 8      ; px the box must cover a treasure tile on each axis to collect it

    ; [TUNE] animation
    const ubyte RUN_STEP = 6            ; px moved per run picture (4 pictures)
    const ubyte FLOAT_SHIFT = 3         ; float pictures change every 2^n frames

    const uword START_X = 152 + actors.BOX_INSET    ; sprite at px 152 (tile column 9.5)
    const ubyte START_Y = 0

    ubyte rise_left                     ; px of jump height (or launch) left
    ubyte chain                         ; fast-fall kills this airborne trip (index into the kill points)
    ubyte invuln_timer                  ; frames
    bool down_lock                      ; after a kill, down must be released before it fast-falls again
    ubyte ff_start_y                    ; box y when the current fast-fall started

    ; float back to the start: Bresenham line, one pixel step at a time
    ubyte float_dx
    ubyte float_dy
    word float_err
    bool float_left

    const ubyte NO_TARGET = 255
    ubyte target_idx = NO_TARGET        ; tile map index of the highlighted fast-fall target
    ubyte target_col
    ubyte target_row

    sub init() {
        actors.x[0] = START_X
        actors.y[0] = START_Y
        actors.x_frac[0] = 0
        actors.y_frac[0] = 0
        actors.vy[0] = 0
        actors.state[0] = FALLING
        actors.facing[0] = actors.FACE_RIGHT
        target_idx = NO_TARGET
        chain = 0
        invuln_timer = 0
        down_lock = false
    }

    sub update() {
        ubyte st = actors.state[0]
        ubyte d

        if invuln_timer != 0
            invuln_timer--
        if st == FLOATING {
            float_step()
            update_target()
            return
        }
        if input.held & input.DOWN == 0
            down_lock = false

        ; horizontal: full air control, except fast-fall drops straight down
        if st != FASTFALL {
            if input.held & input.LEFT != 0 {
                actors.facing[0] = actors.FACE_LEFT
                d = actors.advance(actors.x_frac[0], RUN_SPEED)
                actors.x_frac[0] = actors.new_frac
                void actors.move_left(0, d)
            } else if input.held & input.RIGHT != 0 {
                actors.facing[0] = actors.FACE_RIGHT
                d = actors.advance(actors.x_frac[0], RUN_SPEED)
                actors.x_frac[0] = actors.new_frac
                void actors.move_right(0, d)
            }
        }

        ; state changes from input and ground
        when st {
            GROUNDED -> {
                if input.pressed & input.FIRE != 0 {
                    st = RISING
                    rise_left = JUMP_HEIGHT
                    actors.y_frac[0] = 0
                    sound.play(sound.JUMP)
                } else if not actors.on_ground(0) {
                    st = FALLING
                    actors.vy[0] = 0
                }
            }
            RISING -> {
                if input.held & input.DOWN != 0 {
                    st = FASTFALL
                    ff_start_y = actors.y[0]
                } else if input.held & input.FIRE == 0 {
                    st = FALLING
                    actors.vy[0] = 0
                }
            }
            FALLING, LAUNCHED -> {
                if input.held & input.DOWN != 0 and not down_lock {
                    st = FASTFALL
                    ff_start_y = actors.y[0]
                }
            }
        }

        ; vertical movement
        when st {
            RISING, LAUNCHED -> {
                d = actors.advance(actors.y_frac[0], RISE_SPEED)
                actors.y_frac[0] = actors.new_frac
                if d > rise_left
                    d = rise_left
                rise_left -= d
                if actors.move_up(0, d) or rise_left == 0 {
                    st = FALLING
                    actors.vy[0] = 0
                }
            }
            FALLING, FASTFALL -> {
                if st == FASTFALL
                    actors.vy[0] = FASTFALL_SPEED as byte
                else {
                    actors.vy[0] += GRAVITY as byte
                    if actors.vy[0] > (MAX_FALL as byte)
                        actors.vy[0] = MAX_FALL as byte
                }
                d = actors.advance(actors.y_frac[0], actors.vy[0] as ubyte)
                actors.y_frac[0] = actors.new_frac
                if actors.move_down(0, d) {
                    ; A fast-fall that destroys a damaged tile keeps falling through the hole. One shorter than
                    ; FF_MIN_DIST lands like a normal fall (no drill hop from standing).
                    if st != FASTFALL or actors.y[0] - ff_start_y < FF_MIN_DIST or not damage_below() {
                        st = GROUNDED
                        actors.vy[0] = 0
                        actors.y_frac[0] = 0
                        chain = 0
                        down_lock = false
                    }
                }
            }
        }

        actors.state[0] = st
        collect_treasures()
        update_target()
    }

    sub update_target() {
        ; In the air, highlight the tile a fast-fall from here would damage: find the row where a straight drop
        ; stops (first solid tile under either box edge), then take the tile under the box centre in that row.
        ; Nothing is highlighted when that tile is the floor or empty (the drop would land on an edge).
        ubyte new_idx = NO_TARGET
        ubyte col
        ubyte row
        if actors.state[0] != GROUNDED and actors.state[0] != FLOATING {
            ubyte left = lsb(actors.x[0] >> 4)
            ubyte right = lsb((actors.x[0] + actors.BOX_W - 1) >> 4)
            col = lsb((actors.x[0] + actors.BOX_W / 2) >> 4)
            row = ((actors.y[0] + actors.BOX_H - 1) >> 4) + 1
            while video.tiles[video.row_start[row] + left] - 1 >= 3 and video.tiles[video.row_start[row] + right] - 1 >= 3
                row++                   ; row 11 is floor, so this stops
            ubyte idx = video.row_start[row] + col
            ubyte t = video.tiles[idx]
            if t == video.T_SOLID or t == video.T_DAMAGED
                new_idx = idx
        }
        if new_idx == target_idx
            return
        if target_idx != NO_TARGET
            video.draw_tile(target_col, target_row)
        target_idx = new_idx
        target_col = col
        target_row = row
        if new_idx != NO_TARGET
            video.highlight_tile(col, row)
    }

    sub damage_below() -> bool {
        ; Fast-fall landing: damage the tile under the box centre (solid -> damaged -> gone).
        ; Returns true when the tile was destroyed. The floor and non-solid tiles are left alone.
        ubyte col = lsb((actors.x[0] + actors.BOX_W / 2) >> 4)
        ubyte row = (actors.y[0] + actors.BOX_H) >> 4
        ubyte idx = video.row_start[row] + col
        when video.tiles[idx] {
            video.T_SOLID -> video.tiles[idx] = video.T_DAMAGED
            video.T_DAMAGED -> video.tiles[idx] = video.T_EMPTY
            else -> return false
        }
        video.draw_tile(col, row)
        if idx == target_idx
            target_idx = NO_TARGET      ; the redraw removed the highlight
        sound.play(sound.DAMAGE)
        if video.tiles[idx] != video.T_EMPTY {
            video.shake(video.SHAKE_CRACK)
            return false                ; was solid, now damaged: normal landing
        }
        video.shake(video.SHAKE_SMASH)
        ; destroyed: the enemies' platform map changes. Centre the box over the hole so the fast-fall continues.
        nav.tile_destroyed()
        actors.x[0] = (col as uword << 4) + (16 - actors.BOX_W) / 2
        actors.x_frac[0] = 0
        return true
    }

    sub collect_treasures() {
        ; Collect the treasure tiles the box covers by at least TREASURE_COVER px on both axes. The 12 px wide
        ; box covers at most one column that much; the 16 px high box covers one row, or two at 8 px into a tile.
        ubyte col = lsb(actors.x[0] >> 4)
        ubyte xo = lsb(actors.x[0]) & 15
        if xo > 16 - TREASURE_COVER {
            if xo < 16 + TREASURE_COVER - actors.BOX_W
                return
            col++
        }
        ubyte row = actors.y[0] >> 4
        ubyte yo = actors.y[0] & 15
        if yo <= 16 - TREASURE_COVER
            check_treasure(col, row)
        if yo >= TREASURE_COVER
            check_treasure(col, row + 1)
    }

    sub check_treasure(ubyte col, ubyte row) {
        ubyte idx = video.row_start[row] + col
        ubyte t = video.tiles[idx]
        if t >= video.T_TREASURE {
            video.tiles[idx] = video.T_EMPTY
            video.draw_tile(col, row)
            score.collect(t - video.T_TREASURE)
            popup.show(((col as uword) << 4) + 8, (row << 4) + 8, score.treasure_points[t - video.T_TREASURE], popup.TREASURE)
            sound.play(sound.COLLECT)
        }
    }

    sub launch(ubyte height) {
        actors.state[0] = LAUNCHED
        rise_left = height
        actors.vy[0] = 0
        actors.y_frac[0] = 0
    }

    sub launch_from_kill() {
        launch(KILL_LAUNCH)
        down_lock = true
    }

    sub bounce(ubyte enemy_y) {
        ; Stomp: put the box on top of the enemy, then bounce.
        void actors.move_up(0, actors.y[0] + actors.BOX_H - enemy_y)
        launch(BOUNCE)
    }

    sub hit() {
        ; Lose time, then float back to the start.
        score.lose_time(score.HIT_PENALTY)
        sound.play(sound.HIT)
        start_float()
    }

    sub start_float() {
        ; Float in a straight line to the start point (ignoring tiles, enemies and input).
        actors.state[0] = FLOATING
        actors.vy[0] = 0
        actors.x_frac[0] = 0
        actors.y_frac[0] = 0
        float_left = actors.x[0] > START_X
        if float_left
            float_dx = lsb(actors.x[0] - START_X)
        else
            float_dx = lsb(START_X - actors.x[0])
        float_dy = actors.y[0] - START_Y        ; the start is at the top, so the float goes up
        float_err = (float_dx as word) - (float_dy as word)
    }

    sub float_step() {
        ; FLOAT_SPEED single-pixel steps along the line; each moves the longer axis by 1 px.
        word e2
        repeat FLOAT_SPEED {
            if actors.x[0] == START_X and actors.y[0] == START_Y {
                actors.state[0] = FALLING
                invuln_timer = INVULN_FRAMES
                return
            }
            e2 = float_err << 1
            if e2 > -(float_dy as word) {
                float_err -= float_dy as word
                if float_left
                    actors.x[0]--
                else
                    actors.x[0]++
            }
            if e2 < (float_dx as word) {
                float_err += float_dx as word
                actors.y[0]--
            }
        }
    }

    sub hold_at_start() {
        ; At the start point in the float pose, with no control (level transitions). init() ends it.
        actors.x[0] = START_X
        actors.y[0] = START_Y
        actors.state[0] = FLOATING
        invuln_timer = 0
    }

    sub show_target() {
        ; Highlight the fast-fall target again after something redrew its tile (a message).
        if target_idx != NO_TARGET
            video.highlight_tile(target_col, target_row)
    }

    sub draw() {
        if invuln_timer & 4 != 0 {
            video.hide_sprite(0)
            return
        }
        ubyte frame
        bool left = actors.facing[0] == actors.FACE_LEFT
        when actors.state[0] {
            GROUNDED -> {
                frame = if left assets.SPR_PLAYER_RUN_L_0 else assets.SPR_PLAYER_RUN_R_0
                frame += actors.walk_anim(0, 4, RUN_STEP)
            }
            RISING, LAUNCHED -> frame = if left assets.SPR_PLAYER_JUMP_L_0 else assets.SPR_PLAYER_JUMP_R_0
            FALLING -> frame = if left assets.SPR_PLAYER_FALL_L_0 else assets.SPR_PLAYER_FALL_R_0
            FASTFALL -> frame = assets.SPR_PLAYER_FASTFALL_0
            else -> frame = assets.SPR_PLAYER_FLOAT_0 + ((video.frames >> FLOAT_SHIFT) & 1)
        }
        video.set_sprite(0, frame, video.PLAYER_COLOR, actors.x[0] - actors.BOX_INSET, actors.y[0])
    }
}
