; BCD score, level timer and treasure count (spec section 8). The HUD is redrawn only when a value changes.

%import bcd
%import video

score {
    const uword START_TIME = $0060          ; BCD seconds
    const uword LEVEL_TIME_BONUS = $0060    ; BCD seconds added on level completion
    const ubyte TREASURES_PER_LEVEL = 10
    const ubyte FRAMES_PER_SECOND = 50
    const uword HIT_PENALTY = $0010         ; BCD seconds
    const ubyte NO_KILL_BONUS = $25         ; BCD hundreds, level completed without destroying an enemy

    const uword MAX_POINTS = $9999          ; BCD hundreds, shown as 999900

    ; HUD score flash on every score event [TUNE]. HUD cells are hi-res (colours 0-7).
    const ubyte FLASH_FRAMES = 8
    const ubyte FLASH_COLOR = 7             ; yellow: COLOR_HUD is white (1); use 1 if that changes
    ubyte flash_left

    uword points                            ; BCD, in units of 100 points (4 digits, shown with a fixed "00")
    uword time                              ; BCD seconds, 3 digits
    ubyte time_frames                       ; frames left in the current second
    ubyte treasures_left
    ubyte level                             ; 1-based
    ubyte level_bcd                         ; the same for the HUD
    uword high                              ; session high score, BCD hundreds

    ; treasure type t is worth t + 1 hundred points, as BCD
    ubyte[15] treasure_points = [$01, $02, $03, $04, $05, $06, $07, $08,
                                 $09, $10, $11, $12, $13, $14, $15]

    sub new_game() {
        points = 0
        time = START_TIME
        time_frames = FRAMES_PER_SECOND
        level = 1
        level_bcd = $01
        flash_left = 0
        video.hud_score(points)
        video.hud_time(time)
        video.hud_level(level_bcd)
    }

    sub next_level() {
        level++
        level_bcd = bcd.addub(level_bcd, 1)
        video.hud_level(level_bcd)
        add_time(LEVEL_TIME_BONUS)
    }

    sub update_high() {
        ; BCD values compare like plain numbers
        if points > high
            high = points
    }

    sub new_level() {
        treasures_left = TREASURES_PER_LEVEL
    }

    sub collect(ubyte t) {
        add_points(treasure_points[t])
        treasures_left--
    }

    sub add_points(ubyte bcd_hundreds) {
        ; Clamps at MAX_POINTS. The largest add is far below $9999, so a wrap always ends below the old value.
        uword new_points = bcd.adduw(points, bcd_hundreds)
        if new_points < points
            new_points = MAX_POINTS
        points = new_points
        video.hud_score(points)
        flash_left = FLASH_FRAMES
        sys.memset(video.COLOR_RAM + video.HUD_SCORE_COL, 6, FLASH_COLOR)
    }

    sub flash_step() {
        ; Once per frame, before anything can score.
        if flash_left != 0 {
            flash_left--
            if flash_left == 0
                sys.memset(video.COLOR_RAM + video.HUD_SCORE_COL, 6, video.COLOR_HUD)
        }
    }

    sub stop_flash() {
        flash_left = 1
        flash_step()
    }

    sub add_time(uword bcd_seconds) {
        time = bcd.adduw(time, bcd_seconds)
        video.hud_time(time)
    }

    sub lose_time(uword bcd_seconds) {
        ; Clamps at 0.
        if time < bcd_seconds
            time = 0
        else
            time = bcd.subuw(time, bcd_seconds)
        video.hud_time(time)
    }

    sub tick() -> bool {
        ; Count down one frame. Returns true when the time has run out.
        if time == 0
            return true                     ; a hit took the last seconds
        time_frames--
        if time_frames == 0 {
            time_frames = FRAMES_PER_SECOND
            time = bcd.subuw(time, 1)
            video.hud_time(time)
        }
        return time == 0
    }
}
