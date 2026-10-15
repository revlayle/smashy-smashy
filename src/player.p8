; Player states and movement (spec section 5). Phase 2: run, jump, fall, fast-fall. No tile damage yet.

%import actors
%import input

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

    sub init() {
        actors.x[0] = START_X
        actors.y[0] = START_Y
        actors.x_frac[0] = 0
        actors.y_frac[0] = 0
        actors.vy[0] = 0
        actors.state[0] = FALLING
        actors.facing[0] = actors.FACE_RIGHT
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
                    st = GROUNDED
                    actors.vy[0] = 0
                    actors.y_frac[0] = 0
                }
            }
        }

        actors.state[0] = st
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
