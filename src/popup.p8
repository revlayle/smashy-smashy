; Score popups (spec section 8): the points of a score event as hi-res digits in sprites 6 and 7, rising from
; where it happened. Each slot has its own sprite frame; the digits are drawn into it once, at the event.

%import video

popup {
    const ubyte SLOTS = 2
    const ubyte FIRST_SPRITE = 6
    const ubyte FRAME_0 = 253                   ; sprite frames 253-254, one per slot (spec section 3)
    &ubyte[SLOTS * 64] frame_data = video.SCREEN + (FRAME_0 as uword) * 64
    ubyte[SLOTS] slot_bit = [1 << FIRST_SPRITE, 1 << (FIRST_SPRITE + 1)]
    const ubyte BLANK = 10                      ; font entry with no pixels

    ; [TUNE]
    const ubyte LIFE = 50                       ; frames; rises 1 px every 2 frames
    const ubyte BLINK_AT = 10                   ; the last frames blink, 2 on and 2 off
    const ubyte TREASURE_COLOR = 7
    ubyte[5] kill_color = [1, 10, 8, 2, 2]      ; by chain step

    const ubyte RISE = LIFE / 2
    const uword MAX_X = 320 - 24                ; the whole sprite stays on the playfield
    const ubyte MAX_Y = 192 - 21

    ubyte[SLOTS] timer                          ; frames left, 0 = free

    ; 5x7 digits 0-9 and a blank, one byte per row, pixels in bits 4-0
    ubyte[77] font = [
        $0E, $11, $11, $11, $11, $11, $0E,      ; 0
        $04, $0C, $04, $04, $04, $04, $0E,      ; 1
        $0E, $11, $01, $02, $04, $08, $1F,      ; 2
        $1F, $02, $04, $02, $01, $11, $0E,      ; 3
        $02, $06, $0A, $12, $1F, $02, $02,      ; 4
        $1F, $10, $1E, $01, $01, $11, $0E,      ; 5
        $06, $08, $10, $1E, $11, $11, $0E,      ; 6
        $1F, $01, $02, $04, $08, $08, $08,      ; 7
        $0E, $11, $11, $0E, $11, $11, $0E,      ; 8
        $0E, $11, $11, $0F, $01, $02, $0C,      ; 9
        $00, $00, $00, $00, $00, $00, $00       ; blank
    ]
    ; A row of 4 digits is 24 bits: digit k at bit offset 6 * k from the left. Digits 2 and 3 are always "00".
    ; Built by init() so a row is two table lookups: byte 0 = d0 << 3 | d1 >> 3, byte 1 = d1 << 5 | "0" >> 1,
    ; byte 2 = "0" << 7 | "0" << 1.
    ubyte[77] font_shl3
    ubyte[77] font_shr3
    ubyte[77] font_shl5
    ubyte[7] zeros_1
    ubyte[7] zeros_2

    sub init() {
        ubyte i
        for i in 0 to len(font) - 1 {
            font_shl3[i] = font[i] << 3
            font_shr3[i] = font[i] >> 3
            font_shl5[i] = font[i] << 5
        }
        for i in 0 to 6 {
            zeros_1[i] = font[i] >> 1
            zeros_2[i] = font[i] << 7 | font[i] << 1
        }
        sys.memset(&frame_data, len(frame_data), 0)     ; the digits only ever write rows 0-6
        clear()
    }

    sub clear() {
        timer[0] = 0
        timer[1] = 0
        video.spr_ena &= ~(slot_bit[0] | slot_bit[1])
    }

    sub show(uword cx, ubyte cy, ubyte value, ubyte col) {
        ; value: BCD hundreds ($01-$99), shown as 3 or 4 digits centred on (cx, cy), playfield coordinates.
        ; Takes a free slot, else the oldest (least time left).
        ubyte s = 0
        if timer[0] != 0 and (timer[1] == 0 or timer[1] < timer[0])
            s = 1
        c64.SPENA &= ~slot_bit[s]               ; a reused slot must not show the new digits at the old spot

        ; 4 digits fill sprite px 0-22; 3 digits get a blank first digit and fill px 6-22
        ubyte d0 = value >> 4
        ubyte half = 12
        if d0 == 0 {
            d0 = BLANK
            half = 14
        }
        uword x = 0
        if cx > half
            x = cx - half
        if x > MAX_X
            x = MAX_X
        ubyte y = RISE                          ; low enough that the rise ends below the HUD row
        if cy > RISE + 3
            y = cy - 3
        if y > MAX_Y
            y = MAX_Y
        timer[s] = LIFE
        video.set_sprite(FIRST_SPRITE + s, FRAME_0 + s, col, x, y)

        ubyte f0 = (d0 << 3) - d0               ; font index: digit * 7
        ubyte d1 = value & 15
        ubyte f1 = (d1 << 3) - d1
        ; Assembly, unrolled per row and slot (about 230 cycles): Y = f0, X = f1, the row is in the table offsets.
        %asm {{
            stx  P8ZP_SCRATCH_REG
            ldy  p8v_f0
            ldx  p8v_f1
            lda  p8v_s
            bne  _slot1
            .for _r := 0, _r < 7, _r += 1
            lda  p8b_popup.p8v_font_shl3+_r,y
            ora  p8b_popup.p8v_font_shr3+_r,x
            sta  p8b_popup.p8v_frame_data+_r*3
            lda  p8b_popup.p8v_font_shl5+_r,x
            ora  p8b_popup.p8v_zeros_1+_r
            sta  p8b_popup.p8v_frame_data+_r*3+1
            lda  p8b_popup.p8v_zeros_2+_r
            sta  p8b_popup.p8v_frame_data+_r*3+2
            .endfor
            jmp  _done
_slot1
            .for _r := 0, _r < 7, _r += 1
            lda  p8b_popup.p8v_font_shl3+_r,y
            ora  p8b_popup.p8v_font_shr3+_r,x
            sta  p8b_popup.p8v_frame_data+64+_r*3
            lda  p8b_popup.p8v_font_shl5+_r,x
            ora  p8b_popup.p8v_zeros_1+_r
            sta  p8b_popup.p8v_frame_data+64+_r*3+1
            lda  p8b_popup.p8v_zeros_2+_r
            sta  p8b_popup.p8v_frame_data+64+_r*3+2
            .endfor
_done
            ldx  P8ZP_SCRATCH_REG
        }}
    }

    sub update() {
        ; Once per play frame. show() set the sprite up; this moves it up and blinks it.
        ubyte s
        for s in 0 to SLOTS - 1 {
            if timer[s] == 0
                continue
            timer[s]--
            if timer[s] & 1 == 0
                video.spr_y[FIRST_SPRITE + s]--
            if timer[s] == 0 or (timer[s] < BLINK_AT and timer[s] & 2 != 0)
                video.spr_ena &= ~slot_bit[s]
            else
                video.spr_ena |= slot_bit[s]
        }
    }
}
