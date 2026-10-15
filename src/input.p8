; Joystick in port 2, with edge detection.
; SCRIPTED = true replays the `script` table instead of reading $DC00 (self-testing only; keep false in builds for the designer).

input {
    const bool SCRIPTED = false

    ; joystick bits, 1 = active
    const ubyte UP = %00001
    const ubyte DOWN = %00010
    const ubyte LEFT = %00100
    const ubyte RIGHT = %01000
    const ubyte FIRE = %10000

    ubyte held          ; bits held this frame
    ubyte pressed       ; bits that went from released to held this frame (fire and down use this)
    ubyte prev

    ; (frames to hold, joystick bits) pairs. A 0 frame count ends the script; input is released after that.
    ; Self-tests may point `script` at their own table.
    ubyte[] default_script = [
        100, 0,
        0, 0
    ]
    uword script = &default_script
    ubyte script_pos = 0
    ubyte script_left = 0

    sub read() {
        ubyte joy
        if SCRIPTED
            joy = scripted()
        else
            joy = ~c64.CIA1PRA & %00011111
        pressed = joy & ~prev
        held = joy
        prev = joy
    }

    sub scripted() -> ubyte {
        while script_left == 0 {
            if @(script + script_pos) == 0
                return 0
            script_left = @(script + script_pos)
            script_pos += 2
        }
        script_left--
        return @(script + script_pos - 1)
    }
}
