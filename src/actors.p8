; Shared actor state and physics (spec section 4). Index 0 = player, 1-5 = enemies.
; Positions are the top-left of the 12x16 collision box in playfield pixels, plus a 1/16 px fraction.

%import video

actors {
    const ubyte COUNT = 6
    const ubyte BOX_W = 12
    const ubyte BOX_H = 16
    const ubyte BOX_INSET = 2           ; box left edge is this far right of the sprite's left edge

    const ubyte FACE_RIGHT = 0
    const ubyte FACE_LEFT = 1

    uword[COUNT] x
    ubyte[COUNT] y
    ubyte[COUNT] x_frac
    ubyte[COUNT] y_frac
    byte[COUNT] vy                      ; 1/16 px per frame, + = down
    ubyte[COUNT] state
    ubyte[COUNT] facing
    ubyte[COUNT] anim_frame
    ubyte[COUNT] anim_timer

    ubyte new_frac                      ; second result of advance()

    sub advance(ubyte frac, ubyte speed) -> ubyte {
        ; Add an unsigned speed (1/16 px) to a fraction. Returns whole pixels moved; the new fraction is in new_frac.
        ubyte s = frac + speed
        new_frac = s & 15
        return s >> 4
    }

    sub solid_at(uword px, ubyte py) -> bool {
        ; Tiles 1-3 (solid, damaged, floor) block. Callers keep px in 0-319 and py in 0-191.
        ubyte t = video.tiles[video.row_start[py >> 4] + lsb(px >> 4)]
        return t - 1 < 3
    }

    sub move_right(ubyte i, ubyte d) -> bool {
        ; Move d px (< 16) right. Returns true when stopped by a wall or the screen edge.
        uword right = x[i] + BOX_W - 1 + d
        if right > 319 {
            x[i] = 320 - BOX_W
            return true
        }
        if solid_at(right, y[i]) or solid_at(right, y[i] + BOX_H - 1) {
            x[i] = (right & $fff0) - BOX_W
            return true
        }
        x[i] += d
        return false
    }

    sub move_left(ubyte i, ubyte d) -> bool {
        if x[i] < d {
            x[i] = 0
            return true
        }
        uword left = x[i] - d
        if solid_at(left, y[i]) or solid_at(left, y[i] + BOX_H - 1) {
            x[i] = (left & $fff0) + 16
            return true
        }
        x[i] = left
        return false
    }

    sub move_down(ubyte i, ubyte d) -> bool {
        ; Move d px (< 16) down. Returns true on landing; the box then rests on the tile top.
        ubyte bottom = y[i] + BOX_H - 1 + d
        if solid_at(x[i], bottom) or solid_at(x[i] + BOX_W - 1, bottom) {
            y[i] = (bottom & $f0) - BOX_H
            return true
        }
        y[i] += d
        return false
    }

    sub move_up(ubyte i, ubyte d) -> bool {
        ; Returns true when the head hits a tile or the top of the playfield.
        if y[i] < d {
            y[i] = 0
            return true
        }
        ubyte top = y[i] - d
        if solid_at(x[i], top) or solid_at(x[i] + BOX_W - 1, top) {
            y[i] = (top & $f0) + 16
            return true
        }
        y[i] = top
        return false
    }

    sub on_ground(ubyte i) -> bool {
        ubyte below = y[i] + BOX_H
        if below & 15 != 0
            return false
        return solid_at(x[i], below) or solid_at(x[i] + BOX_W - 1, below)
    }
}
