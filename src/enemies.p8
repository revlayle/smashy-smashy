; Enemies (spec section 6): 5 enemies on sprites 1-5 with the shared actor physics, the simple AI,
; contact with the player (kill, stomp, hit) and respawning with a warning flicker.

%import actors
%import player
%import score
%import levelgen
%import video

enemies {
    const ubyte FIRST = 1
    const ubyte LAST = 5

    ; states in actors.state[1-5]
    const ubyte GROUNDED = player.GROUNDED
    const ubyte RISING = player.RISING
    const ubyte FALLING = player.FALLING
    const ubyte DEAD = 6                ; destroyed, waiting to respawn; not shown
    const ubyte WARNING = 7             ; flickering at its spawn spot: doesn't move, no contact at all

    ; [TUNE]
    const ubyte BASE_SPEED = 12         ; 1/16 px per frame at level 1, +1 per level
    const ubyte MAX_SPEED = 22
    const ubyte JUMP_HEIGHT = 64        ; px, at the player's rise speed
    const ubyte RESPAWN_SECS = 10       ; at level 1, -1 per level
    const ubyte MIN_RESPAWN_SECS = 3
    const ubyte WARNING_FRAMES = 50
    const ubyte DECIDE_MASK = 7         ; enemy i decides on frames where (frame & 7) == i, so one per frame

    const ubyte PLAYER_DIST = 8         ; spawn at least this far from the player (Manhattan, tiles)
    const ubyte ENEMY_SPACING = 3       ; and this far from other enemies (|dcol| >= 3 or |drow| >= 3)
    const ubyte SPAWN_TRIES = 20
    const ubyte PICK_WORK = 4           ; spawn tries or fallback-scan cells per frame, shared by all enemies
                                        ; (only on frames without an AI decision, so the two never add up)

    ; set by ai_decide(), carried out by move()
    const ubyte DIR_NONE = 0
    const ubyte DIR_RIGHT = 1
    const ubyte DIR_LEFT = 2
    const ubyte EDGE_STOP = 0           ; stand still at a platform edge
    const ubyte EDGE_TURN = 1           ; turn around at a platform edge
    const ubyte EDGE_DROP = 2           ; walk off platform edges

    ubyte speed                         ; walk speed this level
    ubyte respawn_secs                  ; respawn delay this level
    ubyte frame

    ubyte[actors.COUNT] walk_dir
    ubyte[actors.COUNT] edge_mode
    bool[actors.COUNT] jump_req
    ubyte[actors.COUNT] rise_left
    ubyte[actors.COUNT] respawn_timer   ; seconds left while DEAD; at 0 the enemy is picking its spawn spot
    ubyte[actors.COUNT] timer_frames    ; frames left in the current second (DEAD) or of the warning (WARNING)

    ; standing cells of the level (empty, solid tile below), listed at level start for spawn picks
    ubyte[levelgen.CELLS] spots
    ubyte spot_count

    ; kill points by chain, BCD hundreds
    ubyte[5] kill_points = [$02, $04, $08, $16, $32]

    ; self-test only
    bool frozen                         ; enemies neither decide nor move
    ubyte n_kills
    ubyte n_bonks
    ubyte n_hits

    sub new_level(ubyte level) {
        ; speed = min(12 + (level - 1), 22), respawn = max(10 - (level - 1), 3) s
        speed = MAX_SPEED
        if level <= MAX_SPEED - BASE_SPEED
            speed = BASE_SPEED - 1 + level
        respawn_secs = MIN_RESPAWN_SECS
        if level <= RESPAWN_SECS - MIN_RESPAWN_SECS
            respawn_secs = RESPAWN_SECS + 1 - level
    }

    sub place_all() {
        ; Level start: list the standing cells, then spawn all enemies (with the warning flicker).
        ; Call after the level is generated and the player is at the start.
        ubyte idx
        spot_count = 0
        for idx in 0 to levelgen.CELLS - 1 {
            if video.tiles[idx] == video.T_EMPTY and video.tiles[idx + video.MAP_W] - 1 < 3 {
                spots[spot_count] = idx
                spot_count++
            }
        }
        ubyte i
        for i in FIRST to LAST {
            actors.state[i] = DEAD      ; not counted for spacing until placed
            video.hide_sprite(i)
        }
        for i in FIRST to LAST {
            start_pick(i)
            do {
                pick_work = 255
            } until pick(i)
        }
    }

    sub place(ubyte i, ubyte idx) {
        actors.x[i] = (levelgen.cell_col[idx] as uword << 4) + (16 - actors.BOX_W) / 2
        actors.y[i] = levelgen.cell_row[idx] << 4
        actors.x_frac[i] = 0
        actors.y_frac[i] = 0
        actors.vy[i] = 0
        actors.state[i] = WARNING
        timer_frames[i] = WARNING_FRAMES
        walk_dir[i] = DIR_NONE
        edge_mode[i] = EDGE_STOP
        jump_req[i] = false
    }

    ; Spawn spot picking, spread over frames: each random try or fallback-scan cell costs one unit of
    ; pick_work, and update() hands out PICK_WORK units per frame.
    ubyte pick_work
    ubyte[actors.COUNT] pick_tries      ; random tries left
    ubyte[actors.COUNT] pick_n          ; fallback scan position in spots
    ubyte[actors.COUNT] pick_best
    ubyte[actors.COUNT] pick_best_score
    ubyte pcol                          ; player's cell
    ubyte prow

    sub start_pick(ubyte i) {
        respawn_timer[i] = 0
        pick_tries[i] = SPAWN_TRIES
        pick_n[i] = 0
        pick_best[i] = spots[0]
        pick_best_score[i] = 0
    }

    sub pick(ubyte i) -> bool {
        ; Continue picking a spawn spot for enemy i while pick_work lasts. Returns true when it was placed.
        ; A spot is a standing cell, still empty with a solid tile below, at least PLAYER_DIST from the player
        ; and ENEMY_SPACING from the other enemies. Up to SPAWN_TRIES random picks, then the farthest valid one
        ; (preferring cells that keep the spacing; row 10 always has standing cells).
        pcol = lsb((actors.x[0] + actors.BOX_W / 2) >> 4)
        prow = (actors.y[0] + actors.BOX_H / 2) >> 4
        ubyte idx
        ubyte s
        while pick_work != 0 {
            pick_work--
            if pick_tries[i] != 0 {
                pick_tries[i]--
                idx = spots[levelgen.rand_below(spot_count)]
                if standing(idx) and dist(idx) >= PLAYER_DIST and spaced(idx, i) {
                    place(i, idx)
                    return true
                }
            } else {
                idx = spots[pick_n[i]]
                if standing(idx) {
                    s = dist(idx)
                    if spaced(idx, i)
                        s += 64
                    if s > pick_best_score[i] {
                        pick_best_score[i] = s
                        pick_best[i] = idx
                    }
                }
                pick_n[i]++
                if pick_n[i] == spot_count {
                    place(i, pick_best[i])
                    return true
                }
            }
        }
        return false
    }

    sub standing(ubyte idx) -> bool {
        return video.tiles[idx] == video.T_EMPTY and video.tiles[idx + video.MAP_W] - 1 < 3
    }

    sub dist(ubyte idx) -> ubyte {
        return abs_diff(levelgen.cell_col[idx], pcol) + abs_diff(levelgen.cell_row[idx], prow)
    }

    sub spaced(ubyte idx, ubyte i) -> bool {
        ubyte c = levelgen.cell_col[idx]
        ubyte r = levelgen.cell_row[idx]
        ubyte j
        for j in FIRST to LAST {
            if j != i and actors.state[j] != DEAD {
                if abs_diff(c, col_of(j)) < ENEMY_SPACING and abs_diff(r, actors.y[j] >> 4) < ENEMY_SPACING
                    return false
            }
        }
        return true
    }

    sub col_of(ubyte i) -> ubyte {
        ; column under the box centre
        return lsb((actors.x[i] + actors.BOX_W / 2) >> 4)
    }

    sub abs_diff(ubyte a, ubyte b) -> ubyte {
        if a >= b
            return a - b
        return b - a
    }

    sub update() {
        frame++
        ubyte i = frame & DECIDE_MASK
        pick_work = PICK_WORK
        if i >= FIRST and i <= LAST and actors.state[i] < DEAD and not frozen
            pick_work = 0               ; an enemy decides this frame

        for i in FIRST to LAST {
            when actors.state[i] {
                DEAD -> {
                    if respawn_timer[i] == 0
                        void pick(i)
                    else {
                        timer_frames[i]--
                        if timer_frames[i] == 0 {
                            timer_frames[i] = score.FRAMES_PER_SECOND
                            respawn_timer[i]--
                            if respawn_timer[i] == 0
                                start_pick(i)
                        }
                    }
                }
                WARNING -> {
                    timer_frames[i]--
                    if timer_frames[i] == 0
                        actors.state[i] = FALLING   ; settles onto its tile on the next move
                }
                else -> {
                    if not frozen {
                        if frame & DECIDE_MASK == i
                            ai_decide(i)
                        move(i)
                    }
                }
            }
        }
    }

    ; ---- movement: the player's physics minus fast-fall ----
    sub move(ubyte i) {
        ubyte st = actors.state[i]
        ubyte d
        bool blocked

        ; horizontal
        if walk_dir[i] != DIR_NONE {
            d = actors.advance(actors.x_frac[i], speed)
            actors.x_frac[i] = actors.new_frac
            if st == GROUNDED and edge_mode[i] != EDGE_DROP and at_edge(i, d) {
                if edge_mode[i] == EDGE_TURN
                    turn(i)
            } else {
                if walk_dir[i] == DIR_RIGHT
                    blocked = actors.move_right(i, d)
                else
                    blocked = actors.move_left(i, d)
                if blocked and st == GROUNDED
                    wall_ahead(i)
            }
        }

        ; vertical
        when st {
            GROUNDED -> {
                if jump_req[i] {
                    st = RISING
                    rise_left[i] = JUMP_HEIGHT
                    actors.y_frac[i] = 0
                } else if not actors.on_ground(i) {
                    st = FALLING
                    actors.vy[i] = 0
                }
            }
        }
        jump_req[i] = false
        when st {
            RISING -> {
                d = actors.advance(actors.y_frac[i], player.RISE_SPEED)
                actors.y_frac[i] = actors.new_frac
                if d > rise_left[i]
                    d = rise_left[i]
                rise_left[i] -= d
                if actors.move_up(i, d) or rise_left[i] == 0 {
                    st = FALLING
                    actors.vy[i] = 0
                }
            }
            FALLING -> {
                actors.vy[i] += player.GRAVITY as byte
                if actors.vy[i] > (player.MAX_FALL as byte)
                    actors.vy[i] = player.MAX_FALL as byte
                d = actors.advance(actors.y_frac[i], actors.vy[i] as ubyte)
                actors.y_frac[i] = actors.new_frac
                if actors.move_down(i, d) {
                    st = GROUNDED
                    actors.vy[i] = 0
                    actors.y_frac[i] = 0
                }
            }
        }
        actors.state[i] = st
    }

    sub at_edge(ubyte i, ubyte d) -> bool {
        ; True when moving d px would put the leading bottom corner over a tile with nothing to stand on.
        ; Only possible when the corner enters a new tile column (see actors: tiles never become solid).
        uword lead
        if walk_dir[i] == DIR_RIGHT {
            if ((lsb(actors.x[i]) + actors.BOX_W - 1) & 15) + d < 16
                return false
            lead = actors.x[i] + actors.BOX_W - 1 + d
            if lead > 319
                return false            ; the screen edge stops it as a wall
        } else {
            if (lsb(actors.x[i]) & 15) >= d or actors.x[i] < d
                return false
            lead = actors.x[i] - d
        }
        return not actors.solid_at(lead, actors.y[i] + actors.BOX_H)
    }

    sub wall_ahead(ubyte i) {
        ; Rule 3: blocked by a wall while grounded. Jump if the step is at most 3 tiles high and the rise is
        ; clear, otherwise turn around. The screen edge is too high.
        ubyte wall_col
        if walk_dir[i] == DIR_RIGHT {
            if actors.x[i] + actors.BOX_W >= 320 {
                turn(i)
                return
            }
            wall_col = lsb((actors.x[i] + actors.BOX_W) >> 4)
        } else {
            if actors.x[i] == 0 {
                turn(i)
                return
            }
            wall_col = lsb((actors.x[i] - 1) >> 4)
        }
        ubyte row = actors.y[i] >> 4
        ubyte h = 0
        while h <= 3 and row >= h and video.tiles[video.row_start[row - h] + wall_col] - 1 < 3
            h++
        if h > 3 or row < h {
            turn(i)
            return
        }
        ubyte k
        for k in 1 to h {
            ubyte top = actors.y[i] - (k << 4)
            if actors.solid_at(actors.x[i], top) or actors.solid_at(actors.x[i] + actors.BOX_W - 1, top) {
                turn(i)
                return
            }
        }
        jump_req[i] = true
    }

    sub turn(ubyte i) {
        if walk_dir[i] == DIR_RIGHT
            set_dir(i, DIR_LEFT)
        else if walk_dir[i] == DIR_LEFT
            set_dir(i, DIR_RIGHT)
    }

    sub set_dir(ubyte i, ubyte dir) {
        walk_dir[i] = dir
        if dir == DIR_RIGHT
            actors.facing[i] = actors.FACE_RIGHT
        else if dir == DIR_LEFT
            actors.facing[i] = actors.FACE_LEFT
    }

    ; ---- simple AI (spec section 6, phase 5a). Phase 5b replaces ai_decide(). ----
    sub ai_decide(ubyte i) {
        ; Sets walk_dir, edge_mode and jump_req. Rule 1 (walk to treasures) waits for phase 6 (pickup).
        ; Rule 3 (walls) is handled by move(). Decisions are made only on the ground.
        if actors.state[i] != GROUNDED
            return
        ubyte toward = DIR_NONE
        uword px = actors.x[0]          ; locals: prog8c 12.3.4 miscompiles x[0] > x[i] + 4 (split word array)
        uword ex = actors.x[i]
        if px > ex + 4
            toward = DIR_RIGHT
        else if px + 4 < ex
            toward = DIR_LEFT
        ubyte ahead = toward
        if ahead == DIR_NONE
            ahead = if actors.facing[i] == actors.FACE_LEFT DIR_LEFT else DIR_RIGHT

        ubyte p_row = (actors.y[0] + actors.BOX_H - 1) >> 4   ; row of the player's box bottom
        ubyte e_row = actors.y[i] >> 4
        if p_row == e_row {
            ; same row: walk toward the player, stop at edges
            set_dir(i, toward)
            edge_mode[i] = EDGE_STOP
        } else if p_row > e_row {
            ; player lower: walk toward the player and walk off edges
            set_dir(i, ahead)
            edge_mode[i] = EDGE_DROP
        } else {
            ; player higher: jump onto a platform 1-3 tiles up within 2 columns ahead, else wander
            if jump_spot(i, ahead) {
                set_dir(i, ahead)
                edge_mode[i] = EDGE_STOP
                jump_req[i] = true
            } else if walk_dir[i] != DIR_NONE and jump_spot(i, walk_dir[i]) {
                edge_mode[i] = EDGE_STOP
                jump_req[i] = true
            } else {
                if walk_dir[i] == DIR_NONE or edge_mode[i] != EDGE_TURN
                    set_dir(i, nearest_end(i))
                edge_mode[i] = EDGE_TURN
            }
        }
    }

    sub jump_spot(ubyte i, ubyte dir) -> bool {
        ; A solid tile k = 1-3 rows above the enemy's standing surface, 1-2 columns ahead, with an empty cell on
        ; top of it, and the enemy's own rise k rows up clear. Works on tile map indices (the enemy is grounded,
        ; so its box is tile-aligned vertically).
        ubyte lc = lsb(actors.x[i] >> 4)                    ; columns under the box's left and right edges
        ubyte rc = lsb((actors.x[i] + actors.BOX_W - 1) >> 4)
        ubyte col = col_of(i)
        ubyte c1 = NO_COL                                   ; the two columns ahead
        ubyte c2 = NO_COL
        if dir == DIR_RIGHT {
            if col < video.MAP_W - 1
                c1 = col + 1
            if col < video.MAP_W - 2
                c2 = col + 2
        } else {
            if col >= 1
                c1 = col - 1
            if col >= 2
                c2 = col - 2
        }
        ubyte row = actors.y[i] >> 4
        ubyte up = video.row_start[row]                     ; index of column 0 in row - k
        ubyte below                                         ; and in row + 1 - k
        repeat 3 {
            if up == 0
                return false                                ; top row reached
            below = up
            up -= video.MAP_W
            if video.tiles[up + lc] - 1 < 3 or video.tiles[up + rc] - 1 < 3
                return false                                ; rise blocked
            if c1 != NO_COL and video.tiles[below + c1] - 1 < 3 and video.tiles[up + c1] - 1 >= 3
                return true
            if c2 != NO_COL and video.tiles[below + c2] - 1 < 3 and video.tiles[up + c2] - 1 >= 3
                return true
        }
        return false
    }
    const ubyte NO_COL = 255

    sub nearest_end(ubyte i) -> ubyte {
        ; Direction of the nearer end of the platform the enemy stands on.
        ubyte col = col_of(i)
        ubyte start = video.row_start[actors.y[i] >> 4] + col
        ubyte p = start
        ubyte c = col
        ubyte left = 0
        while c != 0 and video.tiles[p - 1] - 1 >= 3 and video.tiles[p - 1 + video.MAP_W] - 1 < 3 {
            c--
            p--
            left++
        }
        p = start
        c = col
        ubyte right = 0
        while c != video.MAP_W - 1 and video.tiles[p + 1] - 1 >= 3 and video.tiles[p + 1 + video.MAP_W] - 1 < 3 {
            c++
            p++
            right++
        }
        if left < right
            return DIR_LEFT
        return DIR_RIGHT
    }

    ; ---- contact with the player (spec section 6), after both have moved ----
    sub contact() {
        ; Checked in order: fast-fall kill, stomp, hit. The player's state from before this check is used for
        ; every enemy, so one fast-fall can kill (or one fall stomp) two overlapping enemies in the same frame.
        ubyte pst = actors.state[0]
        if pst == player.FLOATING
            return
        ubyte pbottom = actors.y[0] + actors.BOX_H - 1
        ubyte i
        for i in FIRST to LAST {
            if actors.state[i] >= DEAD
                continue
            if actors.x[0] >= actors.x[i] + actors.BOX_W or actors.x[i] >= actors.x[0] + actors.BOX_W
                continue
            if actors.y[0] >= actors.y[i] + actors.BOX_H or actors.y[i] >= actors.y[0] + actors.BOX_H
                continue
            bool top_half = pbottom >= actors.y[i] and pbottom < actors.y[i] + actors.BOX_H / 2
            if top_half and pst == player.FASTFALL
                kill(i)
            else if top_half and pst == player.FALLING {
                n_bonks++
                player.bounce(actors.y[i])
            } else if player.invuln_timer == 0 {
                n_hits++
                player.hit()
                return
            }
        }
    }

    sub kill(ubyte i) {
        n_kills++
        actors.state[i] = DEAD
        respawn_timer[i] = respawn_secs
        timer_frames[i] = score.FRAMES_PER_SECOND
        score.add_points(kill_points[player.chain])
        if player.chain < len(kill_points) - 1
            player.chain++
        player.launch_from_kill()
    }

    sub draw() {
        ubyte i
        ubyte spr
        for i in FIRST to LAST {
            ubyte st = actors.state[i]
            if st == DEAD or (st == WARNING and timer_frames[i] & 4 != 0) {
                video.hide_sprite(i)
                continue
            }
            bool left = actors.facing[i] == actors.FACE_LEFT
            if st == GROUNDED or st == WARNING
                spr = if left assets.SPR_ENEMY_WALK_L_0 else assets.SPR_ENEMY_WALK_R_0
            else
                spr = if left assets.SPR_ENEMY_AIR_L_0 else assets.SPR_ENEMY_AIR_R_0
            video.set_sprite(i, spr, video.ENEMY_COLOR, actors.x[i] - actors.BOX_INSET, actors.y[i])
        }
    }
}
