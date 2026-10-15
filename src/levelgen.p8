; Level generation and validation (spec section 7): shelf bands of jittered platforms, a reachability BFS
; over standing cells, treasure placement, retries and a fixed fallback layout.

%import math
%import video

levelgen {
    const ubyte MAX_ATTEMPTS = 10
    const ubyte MIN_REACHABLE = 30
    const ubyte TREASURES = 10
    const ubyte TREASURE_SPACING = 3    ; min distance between treasures: |dcol| >= 3 or |drow| >= 3
    const ubyte MAX_JUMP_UP = 5         ; tiles
    const ubyte MAX_JUMP_SIDE = 3       ; columns
    const ubyte SPAWN_COL_L = 8         ; spawn zone: columns 8-11, rows 0-1, kept clear
    const ubyte SPAWN_COL_R = 11
    const ubyte START_COL_L = 9         ; columns under the player's box at the start (x 154-165)
    const ubyte CELLS = 220             ; tile rows 0-10 (row 11 is the floor)

    ; Self-test only (keep false): every attempt fails, so generate() always ends with the fallback layout.
    const bool FORCE_FAIL = false

    ubyte attempts                      ; attempts made by the last generate()
    bool used_fallback

    ; ---- platform segments, up to 4 per band ----
    const ubyte BANDS = 3
    const ubyte MAX_SEGS = 4
    ubyte[BANDS] band_base = [2, 5, 8]
    ubyte[BANDS] seg_count
    ubyte[BANDS * MAX_SEGS] seg_start
    ubyte[BANDS * MAX_SEGS] seg_end     ; inclusive
    ubyte[BANDS * MAX_SEGS] seg_row
    ubyte[MAX_SEGS] seg_len
    ubyte[MAX_SEGS + 1] gap_extra       ; extra tiles before each segment, and after the last

    ; ---- BFS over standing cells (tile map index 0-219) ----
    const ubyte C_NONE = 0              ; solid, or nothing to stand on
    const ubyte C_STAND = 1             ; empty with a solid tile below, not reached (yet)
    const ubyte C_REACHED = 2           ; reachable standing cell, free for a treasure
    const ubyte C_BLOCKED = 3           ; reachable, but in the spawn zone or too close to a treasure
    ubyte[CELLS] cell
    ubyte[CELLS] cell_col               ; tile map index -> column and row (filled by init)
    ubyte[CELLS] cell_row
    ubyte[CELLS] queue                  ; reachable cells in BFS order, `reached` of them
    ubyte[video.MAP_H - 1] row_stand    ; standing cells per row (a jump only lands in rows that have some)
    ubyte reached
    ubyte start_cells                   ; queue[0] (and queue[1]): where the player lands from the spawn point
    ubyte tr_count
    ubyte[6] strides = [7, 11, 13, 17, 19, 23]  ; primes below MIN_REACHABLE, for the treasure walk

    ; Fallback layout, as segments per band: (start, end, row). Used after MAX_ATTEMPTS failures.
    ubyte[BANDS] fb_count = [2, 1, 2]
    ubyte[BANDS * MAX_SEGS] fb_start = [1, 13, 0, 0,   4, 0, 0, 0,   0, 15, 0, 0]
    ubyte[BANDS * MAX_SEGS] fb_end = [6, 18, 0, 0,   15, 0, 0, 0,   4, 19, 0, 0]
    ubyte[BANDS * MAX_SEGS] fb_row = [2, 2, 0, 0,   5, 0, 0, 0,   8, 8, 0, 0]

    sub init() {
        ubyte idx = 0
        ubyte r
        ubyte c
        for r in 0 to video.MAP_H - 2 {
            for c in 0 to video.MAP_W - 1 {
                cell_col[idx] = c
                cell_row[idx] = r
                idx++
            }
        }
    }

    sub seed() {
        ; Placeholder until the title screen (phase 7) seeds on the fire press.
        cx16.r0 = mkword(c64.RASTER, c64.CIA1TAH)
        math.rndseed(mkword(c64.CIA1TAL, c64.RASTER), cx16.r0)
    }

    sub rand_below(ubyte n) -> ubyte {
        ; Random 0 to n-1 (n >= 1). Masks math.rnd() and retries out-of-range values: under 2 tries on
        ; average, and much faster than math.randrange(), which does a 16-bit multiply.
        ubyte mask = 255
        if n <= 2
            mask = 1
        else if n <= 4
            mask = 3
        else if n <= 8
            mask = 7
        else if n <= 16
            mask = 15
        else if n <= 32
            mask = 31
        else if n <= 64
            mask = 63
        else if n <= 128
            mask = 127
        repeat {
            ubyte r = math.rnd() & mask
            if r < n
                return r
        }
    }

    sub generate(ubyte level) {
        ; Fill video.tiles with a new level for `level` (1-based). Does not draw it. Needs init() once.
        used_fallback = false
        attempts = 0
        repeat MAX_ATTEMPTS {
            attempts++
            make_layout()
            if not bands_connected()
                continue
            if not explore()
                continue
            if not place_treasures(level)
                continue
            if not FORCE_FAIL
                return
        }
        used_fallback = true
        sys.memcopy(&fb_count, &seg_count, len(seg_count))
        sys.memcopy(&fb_start, &seg_start, len(seg_start))
        sys.memcopy(&fb_end, &seg_end, len(seg_end))
        sys.memcopy(&fb_row, &seg_row, len(seg_row))
        fill_tiles()
        void explore()
        void place_treasures(level)
    }

    sub make_layout() {
        ubyte band
        for band in 0 to BANDS - 1
            make_band(band)
        fill_tiles()
    }

    sub fill_tiles() {
        ; Tile map from the segment lists: empty, platforms, full floor row.
        sys.memset(&video.tiles, CELLS, video.T_EMPTY)
        sys.memset(&video.tiles + CELLS, video.MAP_W, video.T_FLOOR)
        ubyte band
        for band in 0 to BANDS - 1 {
            ubyte i = band * MAX_SEGS
            repeat seg_count[band] {
                sys.memset(&video.tiles + video.row_start[seg_row[i]] + seg_start[i], seg_end[i] - seg_start[i] + 1, video.T_SOLID)
                i++
            }
        }
    }

    sub make_band(ubyte band) {
        ; 2-4 segments, 3-8 tiles long, at least 2 tiles apart, each jittered +-1 row from the band's base row.
        ubyte n = 2 + rand_below(3)
        ubyte s
        byte free = video.MAP_W as byte - 2 * (n as byte - 1)
        for s in 0 to n - 1 {
            seg_len[s] = 3 + rand_below(6)
            free -= seg_len[s] as byte
        }
        s = rand_below(n)
        while free < 0 {
            ; too long for the row: shorten segments in turn, from a random one
            if seg_len[s] > 3 {
                seg_len[s]--
                free++
            }
            s++
            if s == n
                s = 0
        }
        sys.memset(&gap_extra, len(gap_extra), 0)
        while free > 0 {
            gap_extra[rand_below(n + 1)]++
            free--
        }

        seg_count[band] = n
        ubyte base = band_base[band]
        ubyte i = band * MAX_SEGS
        ubyte col = gap_extra[0]
        for s in 0 to n - 1 {
            ubyte last = col + seg_len[s] - 1
            ubyte row = base - 1 + rand_below(3)
            if row < 2 and col <= SPAWN_COL_R and last >= SPAWN_COL_L
                row = 2                 ; keep the spawn zone clear
            seg_start[i] = col
            seg_end[i] = last
            seg_row[i] = row
            col = last + 3 + gap_extra[s + 1]
            i++
        }
    }

    sub bands_connected() -> bool {
        ; Each band needs a platform 1-3 rows above, and within 3 columns of, a platform in the band below
        ; (the floor for the bottom band), so enemies can climb.
        ubyte band
        for band in 0 to BANDS - 1 {
            if not band_connected(band)
                return false
        }
        return true
    }

    sub band_connected(ubyte band) -> bool {
        ubyte i = band * MAX_SEGS
        ubyte j
        repeat seg_count[band] {
            if band == BANDS - 1 {
                if seg_row[i] >= video.MAP_H - 4
                    return true         ; 3 or fewer rows above the floor
            } else {
                j = (band + 1) * MAX_SEGS
                repeat seg_count[band + 1] {
                    if seg_row[j] - seg_row[i] <= 3 and seg_start[j] <= seg_end[i] + 3 and seg_start[i] <= seg_end[j] + 3
                        return true
                    j++
                }
            }
            i++
        }
        return false
    }

    sub explore() -> bool {
        ; BFS from where the player lands below the spawn point. Marks the reachable standing cells C_REACHED
        ; and lists them in queue. Edges: walk left/right, walk off an edge and fall straight down, jump up to
        ; 5 rows up (or across on the same row) landing within 3 columns. A jump rises straight up in the start
        ; column, then moves sideways along the top row of the rise; every cell on that path must be empty.
        ; Returns true when at least MIN_REACHABLE cells are reachable.

        ; standing cells: all of row 10 (platforms are in rows 1-9), and the empty cells on top of each segment
        ubyte idx
        sys.memset(&cell, CELLS - video.MAP_W, C_NONE)
        sys.memset(&cell + CELLS - video.MAP_W, video.MAP_W, C_STAND)
        sys.memset(&row_stand, len(row_stand), 0)
        row_stand[video.MAP_H - 2] = video.MAP_W
        ubyte band
        for band in 0 to BANDS - 1 {
            ubyte i = band * MAX_SEGS
            repeat seg_count[band] {
                ubyte r = seg_row[i] - 1
                idx = video.row_start[r] + seg_start[i]
                repeat seg_end[i] - seg_start[i] + 1 {
                    if video.tiles[idx] == video.T_EMPTY {
                        cell[idx] = C_STAND
                        row_stand[r]++
                    }
                    idx++
                }
                i++
            }
        }
        reached = 0

        ; the player's box spans columns 9 and 10 while it drops from the spawn point
        idx = START_COL_L
        while cell[idx] == C_NONE and cell[idx + 1] == C_NONE
            idx += video.MAP_W          ; the spawn zone is clear and row 10 always stands, so this stops
        if cell[idx] == C_STAND
            reach(idx)
        if cell[idx + 1] == C_STAND
            reach(idx + 1)
        start_cells = reached

        ubyte head = 0
        ubyte p
        ubyte c
        ubyte cc
        ubyte k
        ubyte top
        ubyte rr
        bool left_covered
        bool right_covered
        ubyte rise
        while head < reached {
            idx = queue[head]
            head++
            c = cell_col[idx]

            ; walk, or walk off the edge and fall straight down
            if c != 0 {
                p = idx - 1
                if video.tiles[p] == video.T_EMPTY {
                    while cell[p] == C_NONE
                        p += video.MAP_W
                    if cell[p] == C_STAND
                        reach(p)
                }
            }
            if c != video.MAP_W - 1 {
                p = idx + 1
                if video.tiles[p] == video.T_EMPTY {
                    while cell[p] == C_NONE
                        p += video.MAP_W
                    if cell[p] == C_STAND
                        reach(p)
                }
            }

            ; jump: rise k rows in this column, then move up to 3 columns sideways along that row.
            ; A side is skipped while the neighbour cell on that side is a standing cell whose own column is
            ; clear as high: it is reached by walking, and its jump covers the same targets.
            ; Rows without standing cells are skipped too (except k = 1, which also lands across gaps).
            left_covered = c != 0 and cell[idx - 1] != C_NONE
            right_covered = c != video.MAP_W - 1 and cell[idx + 1] != C_NONE
            rr = cell_row[idx]
            top = rr
            if top > MAX_JUMP_UP
                top = MAX_JUMP_UP
            rise = idx
            k = 1
            while k <= top {
                rise -= video.MAP_W
                if video.tiles[rise] != video.T_EMPTY
                    break
                rr--
                if video.tiles[rise + 1] != video.T_EMPTY
                    right_covered = false
                if video.tiles[rise - 1] != video.T_EMPTY
                    left_covered = false
                if k != 1 and row_stand[rr] == 0 {
                    k++
                    continue
                }
                if not right_covered {
                    cc = c
                    p = rise
                    repeat MAX_JUMP_SIDE {
                        cc++
                        if cc == video.MAP_W
                            break
                        p++
                        if video.tiles[p] != video.T_EMPTY
                            break
                        if cell[p] == C_STAND
                            reach(p)
                        if k == 1 {
                            if cell[p + video.MAP_W] == C_STAND
                                reach(p + video.MAP_W)   ; across a gap on the same row
                        }
                    }
                }
                if not left_covered {
                    cc = c
                    p = rise
                    repeat MAX_JUMP_SIDE {
                        if cc == 0
                            break
                        cc--
                        p--
                        if video.tiles[p] != video.T_EMPTY
                            break
                        if cell[p] == C_STAND
                            reach(p)
                        if k == 1 {
                            if cell[p + video.MAP_W] == C_STAND
                                reach(p + video.MAP_W)
                        }
                    }
                }
                k++
            }
        }
        return reached >= MIN_REACHABLE
    }

    sub reach(ubyte idx) {
        cell[idx] = C_REACHED
        queue[reached] = idx
        reached++
    }

    sub place_treasures(ubyte level) -> bool {
        ; 10 treasures on reachable standing cells outside the spawn zone and off the start landing cells
        ; (the player would collect those on arrival), spaced TREASURE_SPACING apart.
        ; Walks the reachable list from a random start with a random prime stride (this visits every cell
        ; unless the stride divides `reached`), then a plain scan fills any that are missing.
        ubyte i
        for i in SPAWN_COL_L to SPAWN_COL_R {
            if cell[i] == C_REACHED
                cell[i] = C_BLOCKED
            if cell[i + video.MAP_W] == C_REACHED
                cell[i + video.MAP_W] = C_BLOCKED
        }
        cell[queue[0]] = C_BLOCKED
        cell[queue[start_cells - 1]] = C_BLOCKED
        tr_count = 0
        ubyte q = rand_below(reached)
        ubyte stride = strides[rand_below(len(strides))]
        repeat reached {
            if cell[queue[q]] == C_REACHED {
                put_treasure(queue[q], level)
                if tr_count == TREASURES
                    return true
            }
            q += stride
            if q >= reached
                q -= reached
        }
        for q in 0 to reached - 1 {
            if cell[queue[q]] == C_REACHED {
                put_treasure(queue[q], level)
                if tr_count == TREASURES
                    return true
            }
        }
        return false
    }

    sub put_treasure(ubyte idx, ubyte level) {
        tr_count++
        ; type = min(14, (level - 1) + randrange(5))
        ubyte t = level - 1 + rand_below(5)
        if t > 14
            t = 14
        video.tiles[idx] = video.T_TREASURE + t

        ; block every cell less than TREASURE_SPACING rows and columns away, this one included
        const ubyte RADIUS = TREASURE_SPACING - 1
        ubyte r = cell_row[idx]
        ubyte c = cell_col[idx]
        ubyte r0 = 0
        ubyte r1 = r + RADIUS
        ubyte c0 = 0
        ubyte c1 = c + RADIUS
        if r >= RADIUS
            r0 = r - RADIUS
        if r1 > video.MAP_H - 2
            r1 = video.MAP_H - 2
        if c >= RADIUS
            c0 = c - RADIUS
        if c1 > video.MAP_W - 1
            c1 = video.MAP_W - 1
        ubyte rr
        for rr in r0 to r1 {
            ubyte p = video.row_start[rr] + c0
            repeat c1 - c0 + 1 {
                if cell[p] == C_REACHED
                    cell[p] = C_BLOCKED
                p++
            }
        }
    }
}
