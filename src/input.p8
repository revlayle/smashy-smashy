; Joystick in port 2 and the Run/Stop and F1 keys (read from the keyboard matrix), with edge detection.
; SCRIPTED = true replays the `script` table instead of reading $DC00 (self-testing only; keep false in builds for the designer).

input {
    const bool SCRIPTED = false

    ; joystick bits, 1 = active
    const ubyte UP = %00001
    const ubyte DOWN = %00010
    const ubyte LEFT = %00100
    const ubyte RIGHT = %01000
    const ubyte FIRE = %10000
    ; keys, in the same bit set
    const ubyte STOP = %0100000         ; Run/Stop
    const ubyte F1 = %1000000

    ubyte held          ; bits held this frame
    ubyte pressed       ; bits that went from released to held this frame (fire, down and the keys use this)
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
        else {
            joy = ~c64.CIA1PRA & %00011111
            ; Keyboard matrix: a 0 on a port A bit selects a row, port B shows its keys (0 = down).
            ; Run/Stop is row 7 bit 7, F1 row 0 bit 4. The KERNAL IRQ doesn't run, so nothing else scans.
            c64.CIA1PRA = %01111111
            if c64.CIA1PRB & %10000000 == 0
                joy |= STOP
            c64.CIA1PRA = %11111110
            if c64.CIA1PRB & %00010000 == 0
                joy |= F1
            c64.CIA1PRA = $FF
        }
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
