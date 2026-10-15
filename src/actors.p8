; Shared actor state and physics (spec section 4). Index 0 = player, 1-5 = enemies.
; Positions are the top-left of the 12x16 collision box in playfield pixels, plus a 1/16 px fraction.
; Tiles only ever become less solid (solid -> damaged -> gone; treasures don't block), so a box that is clear
; now can only meet a wall, floor or ceiling when its leading edge enters a new tile column or row. The move
; routines skip the tile checks when it doesn't (moves are under 16 px, so at most one boundary is crossed).

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
        if ((lsb(x[i]) + BOX_W - 1) & 15) + d < 16 {
            x[i] += d                   ; leading edge stays in its tile column
            return false
        }
        uword right = x[i] + BOX_W - 1 + d
        if right > 319 {
            x[i] = 320 - BOX_W
            return true
        }
        if side_blocked(right, y[i]) {
            x[i] = (right & $fff0) - BOX_W
            return true
        }
        x[i] += d
        return false
    }

    sub move_left(ubyte i, ubyte d) -> bool {
        if (lsb(x[i]) & 15) >= d {
            x[i] -= d                   ; leading edge stays in its tile column
            return false
        }
        if x[i] < d {
            x[i] = 0
            return true
        }
        uword left = x[i] - d
        if side_blocked(left, y[i]) {
            x[i] = (left & $fff0) + 16
            return true
        }
        x[i] = left
        return false
    }

    sub side_blocked(uword px, ubyte py) -> bool {
        ; Box side at column px, rows py to py + BOX_H - 1. A tile-aligned box covers one row.
        if solid_at(px, py)
            return true
        return (py & 15) != 0 and solid_at(px, py + BOX_H - 1)
    }

    sub level_blocked(ubyte i, ubyte py) -> bool {
        ; Box edge (top or bottom) at row py, columns x to x + BOX_W - 1. Both corners may be in one column.
        if solid_at(x[i], py)
            return true
        return (lsb(x[i]) & 15) > 16 - BOX_W and solid_at(x[i] + BOX_W - 1, py)
    }

    sub move_down(ubyte i, ubyte d) -> bool {
        ; Move d px (< 16) down. Returns true on landing; the box then rests on the tile top.
        if ((y[i] + BOX_H - 1) & 15) + d < 16 {
            y[i] += d                   ; bottom edge stays in its tile row
            return false
        }
        ubyte bottom = y[i] + BOX_H - 1 + d
        if level_blocked(i, bottom) {
            y[i] = (bottom & $f0) - BOX_H
            return true
        }
        y[i] += d
        return false
    }

    sub move_up(ubyte i, ubyte d) -> bool {
        ; Returns true when the head hits a tile or the top of the playfield.
        if (y[i] & 15) >= d {
            y[i] -= d                   ; top edge stays in its tile row (row 0 included: y >= d)
            return false
        }
        if y[i] < d {
            y[i] = 0
            return true
        }
        ubyte top = y[i] - d
        if level_blocked(i, top) {
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
        return level_blocked(i, below)
    }
}
