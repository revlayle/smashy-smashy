; Player states and movement (spec section 5). Run, jump, fall, fast-fall with tile damage, treasure pickup.

%import actors
%import input
%import score

player {
    const ubyte GROUNDED = 0
    const ubyte RISING = 1
    const ubyte FALLING = 2
    const ubyte FASTFALL = 3

    ; [TUNE] speeds in 1/16 px per frame
    const ubyte RUN_SPEED = 24
    const ubyte RISE_SPEED = 40
    const ubyte JUMP_HEIGHT = 96        ; px
    const ubyte GRAVITY = 4
    const ubyte MAX_FALL = 64
    const ubyte FASTFALL_SPEED = 96

    const uword START_X = 152 + actors.BOX_INSET    ; sprite at px 152 (tile column 9.5)
    const ubyte START_Y = 0

    ubyte rise_left                     ; px of jump height left

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
    }

    sub update() {
        ubyte st = actors.state[0]
        ubyte d

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
                } else if not actors.on_ground(0) {
                    st = FALLING
                    actors.vy[0] = 0
                }
            }
            RISING -> {
                if input.held & input.DOWN != 0
                    st = FASTFALL
                else if input.held & input.FIRE == 0 {
                    st = FALLING
                    actors.vy[0] = 0
                }
            }
            FALLING -> {
                if input.held & input.DOWN != 0
                    st = FASTFALL
            }
        }

        ; vertical movement
        when st {
            RISING -> {
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
                    ; a fast-fall that destroys a damaged tile keeps falling through the hole
                    if st != FASTFALL or not damage_below() {
                        st = GROUNDED
                        actors.vy[0] = 0
                        actors.y_frac[0] = 0
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
        if actors.state[0] != GROUNDED {
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
        if video.tiles[idx] != video.T_EMPTY
            return false                ; was solid, now damaged: normal landing
        ; destroyed: centre the box over the hole so the fast-fall continues through it
        actors.x[0] = (col as uword << 4) + (16 - actors.BOX_W) / 2
        actors.x_frac[0] = 0
        return true
    }

    sub collect_treasures() {
        ; Collect every treasure tile the box overlaps (up to 2 x 2 tiles).
        ubyte left = lsb(actors.x[0] >> 4)
        ubyte right = lsb((actors.x[0] + actors.BOX_W - 1) >> 4)
        ubyte top = actors.y[0] >> 4
        ubyte bottom = (actors.y[0] + actors.BOX_H - 1) >> 4
        check_treasure(left, top)
        check_treasure(right, top)
        check_treasure(left, bottom)
        check_treasure(right, bottom)
    }

    sub check_treasure(ubyte col, ubyte row) {
        ubyte idx = video.row_start[row] + col
        ubyte t = video.tiles[idx]
        if t >= video.T_TREASURE {
            video.tiles[idx] = video.T_EMPTY
            video.draw_tile(col, row)
            score.collect(t - video.T_TREASURE)
        }
    }

    sub draw() {
        ubyte frame
        bool left = actors.facing[0] == actors.FACE_LEFT
        when actors.state[0] {
            GROUNDED -> frame = if left assets.SPR_PLAYER_RUN_L_0 else assets.SPR_PLAYER_RUN_R_0
            RISING -> frame = if left assets.SPR_PLAYER_JUMP_L_0 else assets.SPR_PLAYER_JUMP_R_0
            FALLING -> frame = if left assets.SPR_PLAYER_FALL_L_0 else assets.SPR_PLAYER_FALL_R_0
            else -> frame = assets.SPR_PLAYER_FASTFALL_0
        }
        video.set_sprite(0, frame, video.PLAYER_COLOR, actors.x[0] - actors.BOX_INSET, actors.y[0])
    }
}
