; Sound effects (spec section 13): SID voice 1, one effect at a time, table-driven. play() only leaves a
; request; the frame IRQ calls step(), which starts it and then slides the pitch once per frame.
; A new effect cuts off the one playing.

sound {
    const ubyte JUMP = 0
    const ubyte DAMAGE = 1              ; fast-fall cracks or destroys a tile
    const ubyte COLLECT = 2             ; treasure
    const ubyte KILL = 3                ; fast-fall kills an enemy
    const ubyte HIT = 4                 ; the player is hit
    const ubyte LEVEL_DONE = 5

    ; [TUNE] one column per effect, in the order above. Waveform bits (the gate, bit 0, is added by step()):
    ; $10 triangle, $20 saw, $40 pulse, $80 noise. Pitch = SID frequency value (PAL: Hz * 17.03), slide = added per frame (signed).
    ; The gate opens at the start and closes after `length` frames, then the release (SR low nibble) runs.
    ubyte[] @shared wave = [$40, $80, $40, $20, $20, $40]
    ubyte[] @shared ad = [$00, $00, $00, $00, $00, $00]
    ubyte[] @shared sr = [$A2, $A3, $A3, $A4, $A5, $A6]
    uword[] @shared pitch = [$0C00, $0800, $3000, $3800, $1400, $0800]
    word[] @shared slide = [$0100, -$0040, $0400, -$0280, -$0060, $0060]
    ubyte[] @shared length = [10, 8, 6, 14, 25, 50]

    const uword PULSE_WIDTH = $0800     ; 50% square for the pulse effects

    ubyte @shared request               ; 1 + effect, taken by the next step()
    ubyte @shared left                  ; frames until the gate closes, 0 = nothing playing
    ubyte @shared cur_wave
    uword @shared cur_pitch
    word @shared cur_slide

    sub init() {
        c64.PW1 = PULSE_WIDTH
        c64.CR1 = 0
        c64.MVOL = 15                   ; no filters, full volume
    }

    sub play(ubyte effect) {
        request = effect + 1
    }

    asmsub step() clobbers(A, X) {
        ; In the frame IRQ.
        %asm {{
            ldx  p8b_sound.p8v_request
            beq  _run
            lda  #0
            sta  p8b_sound.p8v_request
            dex
            sta  c64.CR1                ; gate off first, so the new effect's envelope starts again
            lda  p8b_sound.p8v_ad,x
            sta  c64.AD1
            lda  p8b_sound.p8v_sr,x
            sta  c64.SR1
            lda  p8b_sound.p8v_pitch_lsb,x
            sta  p8b_sound.p8v_cur_pitch
            lda  p8b_sound.p8v_pitch_msb,x
            sta  p8b_sound.p8v_cur_pitch+1
            lda  p8b_sound.p8v_slide_lsb,x
            sta  p8b_sound.p8v_cur_slide
            lda  p8b_sound.p8v_slide_msb,x
            sta  p8b_sound.p8v_cur_slide+1
            lda  p8b_sound.p8v_length,x
            sta  p8b_sound.p8v_left
            lda  p8b_sound.p8v_wave,x
            sta  p8b_sound.p8v_cur_wave
            ora  #1
            sta  c64.CR1
            jmp  _pitch
_run
            lda  p8b_sound.p8v_left
            beq  _done
            dec  p8b_sound.p8v_left
            bne  _slide
            lda  p8b_sound.p8v_cur_wave ; last frame: gate off, release
            sta  c64.CR1
            rts
_slide
            clc
            lda  p8b_sound.p8v_cur_pitch
            adc  p8b_sound.p8v_cur_slide
            sta  p8b_sound.p8v_cur_pitch
            lda  p8b_sound.p8v_cur_pitch+1
            adc  p8b_sound.p8v_cur_slide+1
            sta  p8b_sound.p8v_cur_pitch+1
_pitch
            lda  p8b_sound.p8v_cur_pitch
            sta  c64.FREQLO1
            lda  p8b_sound.p8v_cur_pitch+1
            sta  c64.FREQHI1
_done
            rts
        }}
    }
}
