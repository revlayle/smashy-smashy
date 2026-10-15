; BCD score, level timer and treasure count (spec section 8). The HUD is redrawn only when a value changes.

%import bcd
%import video

score {
    const uword START_TIME = $0060          ; BCD seconds
    const uword LEVEL_TIME_BONUS = $0060    ; BCD seconds added on level completion
    const ubyte TREASURES_PER_LEVEL = 10
    const ubyte FRAMES_PER_SECOND = 50

    long points                             ; BCD, 6 digits
    uword time                              ; BCD seconds, 3 digits
    ubyte time_frames                       ; frames left in the current second
    ubyte treasures_left

    ; treasure type t is worth (t + 1) * 100 points, as BCD
    uword[15] treasure_points = [$0100, $0200, $0300, $0400, $0500, $0600, $0700, $0800,
                                 $0900, $1000, $1100, $1200, $1300, $1400, $1500]

    sub new_game() {
        points = 0
        time = START_TIME
        time_frames = FRAMES_PER_SECOND
        video.hud_score(points)
        video.hud_time(time)
    }

    sub new_level() {
        treasures_left = TREASURES_PER_LEVEL
    }

    sub collect(ubyte t) {
        add_points(treasure_points[t])
        treasures_left--
    }

    sub add_points(uword bcd_points) {
        points = bcd.addl(points, bcd_points as long)
        video.hud_score(points)
    }

    sub add_time(uword bcd_seconds) {
        time = bcd.adduw(time, bcd_seconds)
        video.hud_time(time)
    }

    sub tick() -> bool {
        ; Count down one frame. Returns true when the time has run out.
        time_frames--
        if time_frames == 0 {
            time_frames = FRAMES_PER_SECOND
            time = bcd.subuw(time, 1)
            video.hud_time(time)
        }
        return time == 0
    }
}
