; Navigation AI (spec section 6, phase 5b): platform map, routes between platforms, enemy roles.
; The map is built after level generation. When a tile is destroyed it is rebuilt into a second table set in
; slices (build_step()) run at the end of frames with time left (idle_build()), and swapped in when complete;
; decisions use the front set meanwhile.
; decide() picks what to do (table lookups only); steer() carries it out every frame by setting the enemy's
; goal x, edge mode and jump request for enemies.move().

%import math
%import video
%import actors
%import levelgen
%import player
%import enemies

nav {
    const ubyte MAX_PLAT = 32
    const ubyte MAX_LINKS = 128         ; per set; 127 usable, so a global link index is never NONE
    const ubyte NONE = 255
    const ubyte OVERFLOW = 254          ; inside a run of standing cells past MAX_PLAT (not mapped)
    const ubyte CELLS = levelgen.CELLS
    const ubyte MAX_JUMP_ROWS = 4       ; enemy jump links reach platforms 1-4 rows higher (80 px jump)

    ; link kinds: bit 0 = goes right, bit 1 = jump (rise in the take-off column, then 1 column sideways)
    const ubyte WALK_LEFT = 0
    const ubyte WALK_RIGHT = 1
    const ubyte JUMP_LEFT = 2
    const ubyte JUMP_RIGHT = 3

    ; ---- two table sets: the front one is used by the AI, the back one is being built ----
    ; Per-platform and per-link arrays hold both sets (index + set offset). Link indices stored in the
    ; tables include the set offset. Platform ids are 0-31 in both sets.
    ubyte[MAX_PLAT * 2] plat_row        ; row of the standing cells
    ubyte[MAX_PLAT * 2] plat_start      ; first and last column
    ubyte[MAX_PLAT * 2] plat_end
    ubyte[MAX_PLAT * 2] plat_link       ; first outgoing link (global index); walk-offs come first
    ubyte[MAX_PLAT * 2] plat_nlinks
    ubyte[MAX_LINKS * 2] link_col       ; take-off column: the empty cell past the end (walk-off) or the
                                        ; cell on the platform to rise from (jump)
    ubyte[MAX_LINKS * 2] link_kind
    ubyte[MAX_LINKS * 2] link_to
    uword pof_mem = memory("nav_platform_of", CELLS * 2, 0)
    uword next_mem = memory("nav_next_link", MAX_PLAT * MAX_PLAT * 2, 0)
    uword hops_mem = memory("nav_hops", MAX_PLAT * MAX_PLAT * 2, 0)

    ubyte front                         ; 0 or 1
    uword f_pof                         ; platform_of[CELLS] (NONE = not a mapped standing cell)
    uword f_next                        ; next_link[P * 32 + Q]
    uword f_hops                        ; hops[P * 32 + Q]
    ubyte fp                            ; set offset into the plat_* arrays
    ubyte f_count                       ; platforms
    uword b_pof
    uword b_next
    uword b_hops
    ubyte bp
    ubyte bl                            ; set offset into the link_* arrays
    ubyte b_count
    ubyte b_links

    ; ---- rebuild state ----
    const ubyte ST_IDLE = 0
    const ubyte ST_ROWS = 1             ; one row of the tile map per step
    const ubyte ST_LINKS = 2            ; one platform's links per step
    const ubyte ST_ROUTES = 3           ; BFS from each platform, ROUTE_WORK queue entries and links per step
    const ubyte ROUTE_WORK = 24
    ubyte stage
    ubyte pos
    ubyte[video.MAP_H] row_first        ; first platform id of each row (ids are given in row order)
    ubyte rebuilds                      ; time-sliced rebuilds finished this level (self-test readout)
    ubyte build_frames                  ; frames since the rebuild started
    ubyte slowest_build                 ; most frames a finished rebuild took (self-test readout)

    ; ---- treasures for the hunters: tile map indices, listed at level start ----
    ubyte[levelgen.TREASURES] tr_cell
    ubyte tr_count

    ; ---- per enemy (index 1-5) ----
    const ubyte CHASER = 0
    const ubyte AMBUSHER = 1
    const ubyte HUNTER = 2
    ubyte[actors.COUNT] role = [CHASER, CHASER, CHASER, AMBUSHER, HUNTER, HUNTER]

    const ubyte PLAN_STAND = 0
    const ubyte PLAN_GOTO = 1           ; walk to goal x on this platform
    const ubyte PLAN_WANDER = 2         ; walk, turning at edges and walls
    const ubyte PLAN_WALKOFF = 3        ; link: walk past the platform end and fall straight down
    const ubyte PLAN_JUMP = 4           ; link: walk to the take-off column, rise, move sideways onto the target
    const ubyte COMMIT_FRAMES = 60      ; a link not finished by then is re-decided
    ubyte[actors.COUNT] plan
    bool[actors.COUNT] airborne         ; the link's take-off has happened
    ubyte[actors.COUNT] commit          ; frames left; no decisions while non-zero
    uword[actors.COUNT] land_x          ; jump: goal x once the box is above the target's tiles
    ubyte[actors.COUNT] land_y          ; jump: box y at or above which the sideways move starts

    ; self-test and debug readout
    bool no_mistakes
    ubyte[actors.COUNT] dbg_plat        ; platform at the last decision
    ubyte[actors.COUNT] dbg_target      ; target platform at the last decision
    ubyte[actors.COUNT] dbg_link        ; last link taken (global index)
    ubyte[actors.COUNT] dbg_takes       ; links taken
    ubyte n_routes                      ; decisions that took the planned link
    ubyte n_mistakes
    ubyte n_wanders

    sub new_level() {
        ; Build the platform map at once (level load, outside the frame budget) and list the treasures.
        start_build()
        while build_step() {
        }
        rebuilds = 0
        tr_count = 0
        ubyte idx
        for idx in 0 to CELLS - 1 {
            if video.tiles[idx] >= video.T_TREASURE and tr_count < len(tr_cell) {
                tr_cell[tr_count] = idx
                tr_count++
            }
        }
    }

    const ubyte TOP_BAND_ROW = 2        ; standing rows 0-2 are the top band (platform tiles in rows 1-3)

    sub enemies_reach_top() -> bool {
        ; Level generation check (spec section 7): true when an enemy on the floor can reach a platform in the
        ; top band by the map's links. Builds rows and links into the back set and one BFS from the floor, and
        ; leaves no rebuild running; new_level() builds the real map afterwards.
        start_build()
        while stage != ST_ROUTES
            void build_step()
        stage = ST_IDLE
        ubyte fl = @(b_pof + video.row_start[video.MAP_H - 2])  ; the floor's standing row (row 10)
        if fl == NONE
            return false                ; over MAX_PLAT platforms before row 10
        while not routes_from(fl) {
        }
        ^^ubyte @zp hrow = b_hops + ((fl as uword) << 5)
        ubyte p = 0
        while p != b_count and plat_row[bp + p] <= TOP_BAND_ROW {
            if hrow[p] != NONE
                return true
            p++
        }
        return false
    }

    sub tile_destroyed() {
        ; (Re)start a time-sliced rebuild into the back set. A rebuild in progress starts over.
        start_build()
    }

    ; ---- platform map build ----
    sub start_build() {
        if front == 0 {
            b_pof = pof_mem + CELLS
            b_next = next_mem + MAX_PLAT * MAX_PLAT
            b_hops = hops_mem + MAX_PLAT * MAX_PLAT
            bp = MAX_PLAT
            bl = MAX_LINKS
        } else {
            b_pof = pof_mem
            b_next = next_mem
            b_hops = hops_mem
            bp = 0
            bl = 0
        }
        b_count = 0
        b_links = 0
        stage = ST_ROWS
        pos = 0
        bfs_started = false
        build_frames = 0
    }

    sub build_step() -> bool {
        ; Do one slice of the build. Returns true while the build is still running.
        when stage {
            ST_ROWS -> {
                row_first[pos] = b_count
                scan_row(pos)
                pos++
                if pos == video.MAP_H - 1 {
                    row_first[pos] = b_count
                    stage = ST_LINKS
                    pos = 0
                }
            }
            ST_LINKS -> {
                make_links(pos)
                pos++
                if pos == b_count {
                    stage = ST_ROUTES
                    pos = 0
                }
            }
            ST_ROUTES -> {
                if not routes_from(pos)
                    return true
                pos++
                if pos == b_count {
                    swap_sets()
                    stage = ST_IDLE
                    rebuilds++
                    if build_frames > slowest_build
                        slowest_build = build_frames
                }
            }
            else -> return false
        }
        return true
    }

    ; A slice takes up to about 70 raster lines (measured, also with the 32-platform maximum). Slices only start
    ; while the frame update is less than this many lines past the frame IRQ, so a frame stays under 260.
    const ubyte BUILD_START_LINES = 185

    sub idle_build() {
        ; Rebuild slices in the time left at the end of the frame update.
        if stage != ST_IDLE
            build_frames++
        while stage != ST_IDLE and not video.frame_ready and video.frame_lines() < BUILD_START_LINES
            void build_step()
    }

    sub swap_sets() {
        front ^= 1
        f_pof = b_pof
        f_next = b_next
        f_hops = b_hops
        fp = bp
        f_count = b_count
    }

    sub scan_row(ubyte row) {
        ; Platforms are maximal runs of standing cells (not solid, solid tile below) on one row.
        ; Assembly: this runs for every row of every map build and of the level generator's check.
        ubyte idx0 = video.row_start[row]
        ubyte @shared run                   ; id of the current run, NONE outside one, OVERFLOW past MAX_PLAT
        ubyte @shared save_x
        %asm {{
            lda  p8b_nav.p8v_b_pof
            clc
            adc  p8v_idx0
            sta  P8ZP_SCRATCH_W2
            lda  p8b_nav.p8v_b_pof+1
            adc  #0
            sta  P8ZP_SCRATCH_W2+1
            ldx  p8v_idx0               ; tile map index
            ldy  #0                     ; column
            lda  #255
            sta  p8v_run
_loop
            ; tiles 1-3 are solid: (t - 1) < 3
            lda  p8b_video.p8v_tiles,x
            sec
            sbc  #1
            cmp  #3
            bcc  _not_standing
            lda  p8b_video.p8v_tiles+20,x
            sec
            sbc  #1
            cmp  #3
            bcs  _not_standing
            lda  p8v_run
            cmp  #255
            bne  _in_run
            ; a new run: next platform id, or OVERFLOW (254) when the table is full
            lda  #254
            sta  p8v_run
            lda  p8b_nav.p8v_b_count
            cmp  #32
            bcs  _in_run
            sta  p8v_run
            inc  p8b_nav.p8v_b_count
            clc
            adc  p8b_nav.p8v_bp
            stx  p8v_save_x
            tax
            lda  p8v_row
            sta  p8b_nav.p8v_plat_row,x
            tya
            sta  p8b_nav.p8v_plat_start,x
            ldx  p8v_save_x
_in_run
            lda  p8v_run
            cmp  #254
            beq  _no_id
            clc
            adc  p8b_nav.p8v_bp
            stx  p8v_save_x
            tax
            tya
            sta  p8b_nav.p8v_plat_end,x
            ldx  p8v_save_x
            lda  p8v_run
            jmp  _store
_not_standing
            lda  #255
            sta  p8v_run
_no_id
            lda  #255
_store
            sta  (P8ZP_SCRATCH_W2),y
            inx
            iny
            cpy  #20
            bne  _loop
        }}
    }

    sub make_links(ubyte p) {
        ubyte row = plat_row[bp + p]
        ubyte s = plat_start[bp + p]
        ubyte e = plat_end[bp + p]
        ubyte first = b_links
        plat_link[bp + p] = bl + first
        ubyte rs = video.row_start[row]

        ; walk off either end
        if s != 0
            walk_off(rs + s - 1, s - 1, WALK_LEFT)
        if e != video.MAP_W - 1
            walk_off(rs + e + 1, e + 1, WALK_RIGHT)

        ; jump up to a platform 1-4 rows higher. Take-off column: just past the target's end, on this platform.
        ; Ids are given in row order, so the candidates are the ids from row_first[row - 4] up to row_first[row].
        ; Row 0 targets are left out: they need headroom above them (see jump_clear).
        if row >= 2 {
            ubyte q = row_first[1]
            if row > MAX_JUMP_ROWS + 1
                q = row_first[row - MAX_JUMP_ROWS]
            while q != row_first[row] {
                ubyte qr = plat_row[bp + q]
                ubyte t = plat_start[bp + q]
                if t != 0 {
                    t--
                    if t >= s and t <= e and jump_clear(t, row, qr, t + 1)
                        add_link(t, JUMP_RIGHT, q)
                }
                t = plat_end[bp + q]
                if t != video.MAP_W - 1 {
                    t++
                    if t >= s and t <= e and jump_clear(t, row, qr, t - 1)
                        add_link(t, JUMP_LEFT, q)
                }
                q++
            }
        }
        plat_nlinks[bp + p] = b_links - first
    }

    sub walk_off(ubyte idx, ubyte col, ubyte kind) {
        ; From the cell past a platform end (idx), if it is not a wall, fall straight down to a standing cell.
        if video.tiles[idx] - 1 < 3
            return
        while video.tiles[idx + video.MAP_W] - 1 >= 3
            idx += video.MAP_W          ; row 11 is floor, so this stops
        ubyte q = @(b_pof + idx)
        if q != NONE
            add_link(col, kind, q)
    }

    sub jump_clear(ubyte t, ubyte row, ubyte qr, ubyte land) -> bool {
        ; The rise in column t from `row` up to one row above the target row qr must be clear, and so must the
        ; cell above the target's end column (`land`). That headroom row gives the enemy time to move sideways
        ; onto the target before it drops back below the target's tiles.
        ubyte idx = video.row_start[row] + t
        repeat row - qr + 1 {
            idx -= video.MAP_W
            if video.tiles[idx] - 1 < 3
                return false
        }
        return video.tiles[video.row_start[qr - 1] + land] - 1 >= 3
    }

    sub add_link(ubyte col, ubyte kind, ubyte q) {
        if b_links == MAX_LINKS - 1
            return                      ; table full: extra links are dropped
        ubyte l = bl + b_links
        link_col[l] = col
        link_kind[l] = kind
        link_to[l] = q
        b_links++
    }

    ; BFS state, kept between slices
    ubyte[MAX_PLAT] bfs_queue
    bool bfs_started
    ubyte bfs_head
    ubyte bfs_tail
    ubyte bfs_l                         ; next link of the platform being expanded
    ubyte bfs_left                      ; its links left
    ubyte bfs_h                         ; hops to its targets
    ubyte bfs_first                     ; first link of the route to it (NONE for the source)

    sub routes_from(ubyte src) -> bool {
        ; BFS over the links from platform src: hops and the first link of a shortest route to each platform.
        ; Does at most ROUTE_WORK queue entries and links per call. Returns true when src is finished.
        uword off = (src as uword) << 5
        ^^ubyte @zp hrow = b_hops + off
        ^^ubyte @zp nrow = b_next + off
        if not bfs_started {
            sys.memset(hrow, MAX_PLAT, NONE)
            sys.memset(nrow, MAX_PLAT, NONE)
            hrow[src] = 0
            bfs_queue[0] = src
            bfs_head = 0
            bfs_tail = 1
            bfs_left = 0
            bfs_started = true
        }
        repeat ROUTE_WORK {
            if bfs_left == 0 {
                if bfs_head == bfs_tail {
                    bfs_started = false
                    return true
                }
                ubyte p = bfs_queue[bfs_head]
                bfs_head++
                bfs_h = hrow[p] + 1
                bfs_first = nrow[p]
                bfs_l = plat_link[bp + p]
                bfs_left = plat_nlinks[bp + p]
            } else {
                ubyte q = link_to[bfs_l]
                if hrow[q] == NONE {
                    hrow[q] = bfs_h
                    nrow[q] = if bfs_first == NONE bfs_l else bfs_first
                    bfs_queue[bfs_tail] = q
                    bfs_tail++
                }
                bfs_l++
                bfs_left--
            }
        }
        return false
    }

    ; ---- lookups in the front set ----
    sub platform_at(ubyte idx) -> ubyte {
        return @(f_pof + idx)
    }

    sub next_link(ubyte p, ubyte q) -> ubyte {
        return @(f_next + ((p as uword) << 5) + q)
    }

    sub hops(ubyte p, ubyte q) -> ubyte {
        return @(f_hops + ((p as uword) << 5) + q)
    }

    sub platform_under(uword bx, ubyte by, bool grounded) -> ubyte {
        ; The platform under a box. Grounded: the cell under the box centre, else under either box edge.
        ; Airborne: the first standing cell straight down from the box centre.
        ubyte row = (by + actors.BOX_H - 1) >> 4
        if row >= video.MAP_H - 1
            return NONE
        ubyte rs = video.row_start[row]
        ubyte idx = rs + lsb((bx + actors.BOX_W / 2) >> 4)
        ubyte p = @(f_pof + idx)
        if p != NONE
            return p
        if grounded {
            p = @(f_pof + rs + lsb(bx >> 4))
            if p != NONE
                return p
            return @(f_pof + rs + lsb((bx + actors.BOX_W - 1) >> 4))
        }
        repeat {
            idx += video.MAP_W
            if idx >= CELLS
                return NONE
            p = @(f_pof + idx)
            if p != NONE
                return p
        }
    }

    ; ---- decisions ----
    sub decide(ubyte i) {
        ; Called on the enemy's decision frame while it is grounded and not committed to a link.
        uword px = actors.x[0]
        ubyte e = platform_under(actors.x[i], actors.y[i], true)
        ubyte t = platform_under(px, actors.y[0], actors.state[0] == player.GROUNDED)
        uword tx = px
        when role[i] {
            AMBUSHER -> {
                ; the end of the player's platform in the player's facing direction (airborne: landing platform)
                if t != NONE and actors.state[0] == player.GROUNDED {
                    if actors.facing[0] == actors.FACE_LEFT
                        tx = (plat_start[fp + t] as uword) << 4
                    else
                        tx = ((plat_end[fp + t] as uword) << 4) + 16 - actors.BOX_W
                }
            }
            HUNTER -> {
                ; the nearest platform (by hops) with a free treasure, else the player's platform
                if e != NONE {
                    ubyte best = NONE
                    ubyte k = 0
                    while k != tr_count {
                        ubyte idx = tr_cell[k]
                        k++
                        if video.tiles[idx] >= video.T_TREASURE {
                            ubyte q = @(f_pof + idx)
                            if q != NONE {
                                ubyte h = hops(e, q)
                                if h < best {
                                    best = h
                                    t = q
                                    tx = ((levelgen.cell_col[idx] as uword) << 4) + (16 - actors.BOX_W) / 2
                                }
                            }
                        }
                    }
                }
            }
        }
        dbg_plat[i] = e
        dbg_target[i] = t
        if e == NONE or t == NONE {
            wander(i)
            return
        }
        if e == t {
            go_to(i, e, tx)
            return
        }
        ubyte l = next_link(e, t)
        if l == NONE {
            ; no route: head for the reachable platform nearest the target, and wait there
            ubyte near = nearest_reachable(e, t)
            if near == e {
                go_to(i, e, tx)
                return
            }
            l = next_link(e, near)
        }
        if not no_mistakes and math.rnd() & 63 < mistake_rate() {
            l = plat_link[fp + e] + levelgen.rand_below(plat_nlinks[fp + e])
            n_mistakes++
        } else
            n_routes++
        take_link(i, l)
    }

    sub nearest_reachable(ubyte e, ubyte t) -> ubyte {
        ; The platform reachable from e (e included) nearest to platform t: rows apart plus the column gap
        ; between them (0 when they overlap). Ties go to fewer hops.
        ^^ubyte @zp hrow = f_hops + ((e as uword) << 5)
        ubyte t_row = plat_row[fp + t]
        ubyte t_start = plat_start[fp + t]
        ubyte t_end = plat_end[fp + t]
        ubyte best = e
        ubyte best_dist = 255
        ubyte best_hops = 255
        ubyte q
        for q in 0 to f_count - 1 {
            ubyte h = hrow[q]
            if h != NONE {
                ubyte d = abs_diff(plat_row[fp + q], t_row)
                if plat_end[fp + q] < t_start
                    d += t_start - plat_end[fp + q]
                else if plat_start[fp + q] > t_end
                    d += plat_start[fp + q] - t_end
                if d < best_dist or (d == best_dist and h < best_hops) {
                    best = q
                    best_dist = d
                    best_hops = h
                }
            }
        }
        return best
    }

    sub abs_diff(ubyte a, ubyte b) -> ubyte {
        if a >= b
            return a - b
        return b - a
    }

    sub mistake_rate() -> ubyte {
        ; max(16 - level, 4) in 64
        if enemies.level >= 12
            return 4
        return 16 - enemies.level
    }

    sub go_to(ubyte i, ubyte p, uword tx) {
        ; Walk to tx, kept on platform p.
        uword lo = (plat_start[fp + p] as uword) << 4
        uword hi = ((plat_end[fp + p] as uword) << 4) + 16 - actors.BOX_W
        if tx < lo
            tx = lo
        else if tx > hi
            tx = hi
        plan[i] = PLAN_GOTO
        enemies.goal_on[i] = true
        enemies.goal_x[i] = tx
        enemies.edge_mode[i] = enemies.EDGE_STOP
    }

    sub wander(ubyte i) {
        n_wanders++
        enemies.goal_on[i] = false
        enemies.edge_mode[i] = enemies.EDGE_TURN
        if plan[i] != PLAN_WANDER or enemies.walk_dir[i] == enemies.DIR_NONE
            enemies.set_dir(i, enemies.DIR_RIGHT + levelgen.rand_below(2))
        plan[i] = PLAN_WANDER
    }

    sub take_link(ubyte i, ubyte l) {
        dbg_link[i] = l
        dbg_takes[i]++
        ubyte kind = link_kind[l]
        uword cx = ((link_col[l] as uword) << 4) + (16 - actors.BOX_W) / 2   ; box centred in the column
        commit[i] = COMMIT_FRAMES
        airborne[i] = false
        enemies.goal_on[i] = true
        enemies.goal_x[i] = cx
        if kind & 2 == 0 {
            plan[i] = PLAN_WALKOFF
            enemies.edge_mode[i] = enemies.EDGE_DROP
        } else {
            plan[i] = PLAN_JUMP
            enemies.edge_mode[i] = enemies.EDGE_STOP
            if kind & 1 != 0
                land_x[i] = cx + 16
            else
                land_x[i] = cx - 16
            land_y[i] = plat_row[fp + link_to[l]] << 4
        }
    }

    sub reset(ubyte i) {
        ; At spawn: stand until the first decision.
        plan[i] = PLAN_STAND
        commit[i] = 0
        enemies.goal_on[i] = false
    }

    ; ---- carrying out a plan, every frame ----
    sub steer(ubyte i) {
        if commit[i] != 0
            commit[i]--
        ubyte st = actors.state[i]
        when plan[i] {
            PLAN_JUMP -> {
                if not airborne[i] {
                    uword ex = actors.x[i]
                    if st == player.GROUNDED and ex == enemies.goal_x[i] {
                        enemies.jump_req[i] = true
                        airborne[i] = true
                    }
                } else if st == player.GROUNDED
                    link_done(i)
                else if actors.y[i] <= land_y[i]
                    enemies.goal_x[i] = land_x[i]
            }
            PLAN_WALKOFF -> {
                if not airborne[i] {
                    if st != player.GROUNDED
                        airborne[i] = true
                } else if st == player.GROUNDED
                    link_done(i)
            }
        }
    }

    sub link_done(ubyte i) {
        ; Landed: stand until the next decision.
        plan[i] = PLAN_STAND
        commit[i] = 0
        enemies.goal_on[i] = true
        enemies.goal_x[i] = actors.x[i]
    }
}
