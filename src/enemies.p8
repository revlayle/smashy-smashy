; Enemies (spec section 6): 5 enemies on sprites 1-5 with the shared actor physics, contact with the player
; (kill, stomp, hit), respawning with a warning flicker, and treasure carrying (pickup, drop, falling treasures).
; The navigation AI (nav.p8) decides where to go.

%import actors
%import player
%import score
%import levelgen
%import video
%import nav

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
    const ubyte JUMP_HEIGHT = 80        ; px, at the player's rise speed
    const ubyte RESPAWN_SECS = 10       ; at level 1, -1 per level
    const ubyte MIN_RESPAWN_SECS = 3
    const ubyte WARNING_FRAMES = 50
    const ubyte PICKUP_COOLDOWN = 150   ; frames (3 s) an enemy that lost a treasure can't pick one up
    const ubyte FALL_MASK = 3           ; a dropped treasure falls one tile on frames where (frame & 3) == 0
    const ubyte DECIDE_MASK = 7         ; enemy i may decide on frames where (frame & 7) == i, so one per frame

    const ubyte PLAYER_DIST = 8         ; spawn at least this far from the player (Manhattan, tiles)
    const ubyte ENEMY_SPACING = 3       ; and this far from other enemies (|dcol| >= 3 or |drow| >= 3)
    const ubyte SPAWN_TRIES = 20
    const ubyte PICK_WORK = 4           ; spawn tries or fallback-scan cells per frame, shared by all enemies
                                        ; (only on frames without an AI decision, so the two never add up)

    ; set by the navigation AI, carried out by move()
    const ubyte DIR_NONE = 0
    const ubyte DIR_RIGHT = 1
    const ubyte DIR_LEFT = 2
    const ubyte EDGE_STOP = 0           ; stand still at a platform edge
    const ubyte EDGE_TURN = 1           ; turn around at a platform edge or a wall
    const ubyte EDGE_DROP = 2           ; walk off platform edges

    ubyte level
    ubyte speed                         ; walk speed this level
    ubyte respawn_secs                  ; respawn delay this level
    ubyte frame
    ubyte kills                         ; enemies destroyed this level (no-kill bonus)

    ubyte[actors.COUNT] walk_dir
    bool[actors.COUNT] goal_on          ; walk toward goal_x (never past it) instead of in walk_dir
    uword[actors.COUNT] goal_x
    ubyte[actors.COUNT] edge_mode
    bool[actors.COUNT] jump_req
    ubyte[actors.COUNT] rise_left
    ubyte[actors.COUNT] respawn_timer   ; seconds left while DEAD; at 0 the enemy is picking its spawn spot
    ubyte[actors.COUNT] timer_frames    ; frames left in the current second (DEAD) or of the warning (WARNING)
    ubyte[actors.COUNT] carrying        ; 0 = none, else 1 + treasure type
    ubyte[actors.COUNT] cooldown        ; frames until it may pick up a treasure again

    ; dropped treasures that haven't come to rest on a solid tile yet: tile map indices
    ubyte[levelgen.TREASURES] falling
    ubyte fall_count

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
    ubyte n_pickups
    ubyte n_drops

    sub new_level(ubyte lvl) {
        level = lvl
        kills = 0
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
        fall_count = 0
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
        carrying[i] = 0
        cooldown[i] = 0
        nav.reset(i)
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
        ; At most one enemy decides per frame. Frames without a decision do spawn picking.
        ubyte decider = frame & DECIDE_MASK
        if frozen or decider < FIRST or decider > LAST or actors.state[decider] != GROUNDED or nav.commit[decider] != 0
            decider = 0
        pick_work = 0
        if decider == 0
            pick_work = PICK_WORK

        ubyte i

        for i in FIRST to LAST {
            if cooldown[i] != 0
                cooldown[i]--
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
                        if i == decider
                            nav.decide(i)
                        nav.steer(i)
                        move(i)
                    }
                    if carrying[i] == 0 and cooldown[i] == 0
                        pick_up(i)
                }
            }
        }
        if frame & FALL_MASK == 0 and fall_count != 0
            fall_treasures()
    }

    ; ---- treasure carrying (spec section 6, treasure handling) ----
    sub pick_up(ubyte i) {
        ; Take the first treasure tile the box overlaps (up to 2 x 2 tiles).
        ubyte left = lsb(actors.x[i] >> 4)
        ubyte idx = video.row_start[actors.y[i] >> 4] + left
        bool two_cols = lsb((actors.x[i] + actors.BOX_W - 1) >> 4) != left
        if take(i, idx)
            return
        if two_cols and take(i, idx + 1)
            return
        if actors.y[i] & 15 != 0 {
            idx += video.MAP_W
            if take(i, idx)
                return
            if two_cols
                void take(i, idx + 1)
        }
    }

    sub take(ubyte i, ubyte idx) -> bool {
        ubyte t = video.tiles[idx]
        if t < video.T_TREASURE
            return false
        carrying[i] = t - video.T_TREASURE + 1
        nav.hideout[i] = nav.NONE       ; pick a hideout at the next decision
        video.tiles[idx] = video.T_EMPTY
        video.draw_tile(levelgen.cell_col[idx], levelgen.cell_row[idx])
        n_pickups++
        return true
    }

    sub drop(ubyte i) {
        ; Lose the carried treasure (stomp or kill): it goes into the tile at the box centre, or the nearest empty
        ; tile above it, and falls from there (fall_treasures).
        if carrying[i] == 0
            return
        ubyte t = video.T_TREASURE + carrying[i] - 1
        carrying[i] = 0
        cooldown[i] = PICKUP_COOLDOWN
        n_drops++
        ubyte idx = video.row_start[(actors.y[i] + actors.BOX_H / 2) >> 4] + col_of(i)
        while video.tiles[idx] != video.T_EMPTY {
            if idx < video.MAP_W {
                ; the whole column above is taken: the first empty tile of the map instead
                idx = 0
                while video.tiles[idx] != video.T_EMPTY
                    idx++
                break
            }
            idx -= video.MAP_W
        }
        video.tiles[idx] = t
        video.draw_tile(levelgen.cell_col[idx], levelgen.cell_row[idx])
        if fall_count < len(falling) {
            falling[fall_count] = idx
            fall_count++
        }
    }

    sub fall_treasures() {
        ; Move each dropped treasure one tile down into an empty tile. One resting on a solid tile is done
        ; (the hunters may target it from now on); one above another treasure waits until that cell is empty.
        ; A treasure taken while falling (by the player or an enemy) leaves the list.
        ubyte k = fall_count
        while k != 0 {
            k--
            ubyte idx = falling[k]
            ubyte t = video.tiles[idx]
            bool done = t < video.T_TREASURE
            if not done {
                ubyte below = video.tiles[idx + video.MAP_W]
                if below == video.T_EMPTY {
                    video.tiles[idx] = video.T_EMPTY
                    video.draw_tile(levelgen.cell_col[idx], levelgen.cell_row[idx])
                    idx += video.MAP_W
                    video.tiles[idx] = t
                    video.draw_tile(levelgen.cell_col[idx], levelgen.cell_row[idx])
                    falling[k] = idx
                } else if below - 1 < 3 {
                    nav.treasure_settled(idx)
                    done = true
                }
            }
            if done {
                fall_count--
                falling[k] = falling[fall_count]
            }
        }
    }

    ; ---- movement: the player's physics minus fast-fall ----
    sub move(ubyte i) {
        ubyte st = actors.state[i]
        ubyte d
        bool blocked
        uword room

        ; horizontal: toward the goal and never past it, or in walk_dir
        if goal_on[i] {
            uword gx = goal_x[i]
            uword ex = actors.x[i]
            if ex < gx {
                set_dir(i, DIR_RIGHT)
                room = gx - ex
            } else if ex > gx {
                set_dir(i, DIR_LEFT)
                room = ex - gx
            } else
                walk_dir[i] = DIR_NONE
        }
        if walk_dir[i] != DIR_NONE {
            d = actors.advance(actors.x_frac[i], speed)
            actors.x_frac[i] = actors.new_frac
            if goal_on[i] and room < d
                d = lsb(room)
            if st == GROUNDED and edge_mode[i] != EDGE_DROP and at_edge(i, d) {
                if edge_mode[i] == EDGE_TURN
                    turn(i)
            } else {
                if walk_dir[i] == DIR_RIGHT
                    blocked = actors.move_right(i, d)
                else
                    blocked = actors.move_left(i, d)
                if blocked and edge_mode[i] == EDGE_TURN
                    turn(i)
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
                drop(i)
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
        kills++
        drop(i)
        actors.state[i] = DEAD
        respawn_timer[i] = respawn_secs
        timer_frames[i] = score.FRAMES_PER_SECOND
        score.add_points(kill_points[player.chain])
        if player.chain < len(kill_points) - 1
            player.chain++
        player.launch_from_kill()
        video.shake(video.SHAKE_SMASH)
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
            ubyte color = if carrying[i] != 0 video.ENEMY_CARRY_COLOR else video.ENEMY_COLOR
            video.set_sprite(i, spr, color, actors.x[i] - actors.BOX_INSET, actors.y[i])
        }
    }
}
