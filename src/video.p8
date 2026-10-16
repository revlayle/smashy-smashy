; VIC setup (bank 3), charset and sprite upload, tile map drawing, HUD, sprite shadows and the frame IRQ.
; Never use txt.* routines: they are hard-wired to the $0400 screen.

%import gen_assets
%import sound

video {
    ; Multicolor or hi-res art. tools/gfx.py reads this line and checks the art files against it.
    const bool MULTICOLOR = true

    ; ---- all colors ----
    const ubyte COLOR_BORDER = 0
    const ubyte COLOR_BG = 0            ; $D021, art symbol '.' in tiles
    const ubyte COLOR_CHAR_MC1 = 11     ; $D022, art symbol '2' in tiles
    const ubyte COLOR_CHAR_MC2 = 15     ; $D023, art symbol '3' in tiles
    const ubyte COLOR_SPR_MC1 = 10      ; $D025, art symbol '2' in sprites
    const ubyte COLOR_SPR_MC2 = 11      ; $D026, art symbol '3' in sprites
    const ubyte COLOR_HUD = 1           ; hi-res text, must be 0-7
    const ubyte PLAYER_COLOR = 14       ; art symbol '1' in player sprites
    const ubyte ENEMY_COLOR = 2
    const ubyte ENEMY_CARRY_COLOR = 7
    const ubyte TARGET_COLOR = 1        ; fast-fall target tile highlight, must be 0-7
    ; tile colors come from assets/tiles.txt (assets.TILE_*_COLOR)

    ; ---- memory (spec section 3) ----
    const uword SCREEN = $C000
    const uword SPRITE_PTRS = $C3F8
    const uword COLOR_RAM = $D800
    const uword CHARSET = $E000
    const uword SPRITE_DATA = $E800
    const ubyte HUD_FONT_CHARS = 64     ; ROM screen codes 0-63: @, A-Z, space, digits, punctuation
    const ubyte CHAR_SPACE = 32
    const ubyte CHAR_BLOCK = 255        ; solid 8x8 block (title letters), set up by init()
    ; title letter corner triangles (chars 251-254), named by the filled corner like the numpad: 7 = upper left
    const ubyte CHAR_TRI_7 = 251
    const ubyte CHAR_TRI_9 = 252
    const ubyte CHAR_TRI_1 = 253
    const ubyte CHAR_TRI_3 = 254
    ; Each half includes the diagonal pixels, the same rule for all four, so diagonals line up across cells.
    ubyte[32] tri_chars = [
        $FF, $FE, $FC, $F8, $F0, $E0, $C0, $80,     ; 7: pixel x + row <= 7
        $FF, $7F, $3F, $1F, $0F, $07, $03, $01,     ; 9: x >= row
        $80, $C0, $E0, $F0, $F8, $FC, $FE, $FF,     ; 1: x <= row
        $01, $03, $07, $0F, $1F, $3F, $7F, $FF      ; 3: x + row >= 7
    ]

    ; ---- tile map (spec section 4) ----
    const ubyte MAP_W = 20
    const ubyte MAP_H = 12
    const ubyte T_EMPTY = 0
    const ubyte T_SOLID = 1
    const ubyte T_DAMAGED = 2
    const ubyte T_FLOOR = 3
    const ubyte T_TREASURE = 16         ; 16 + type (0-14)

    &ubyte[MAP_W * MAP_H] tiles = $C400
    ubyte[MAP_H] row_start = [0, 20, 40, 60, 80, 100, 120, 140, 160, 180, 200, 220]
    ; screen address of the top-left char of tile column 0 in each tile row (char row 1 + 2*row)
    uword[MAP_H] tile_row_addr = [SCREEN + 40, SCREEN + 120, SCREEN + 200, SCREEN + 280,
                                  SCREEN + 360, SCREEN + 440, SCREEN + 520, SCREEN + 600,
                                  SCREEN + 680, SCREEN + 760, SCREEN + 840, SCREEN + 920]

    ; tile value -> top-left char and color RAM value. Values 4-15 are unused and draw as empty.
    ubyte[31] tile_char = [
        assets.TILE_EMPTY_TL, assets.TILE_SOLID_TL, assets.TILE_DAMAGED_TL, assets.TILE_FLOOR_TL,
        assets.TILE_EMPTY_TL, assets.TILE_EMPTY_TL, assets.TILE_EMPTY_TL, assets.TILE_EMPTY_TL,
        assets.TILE_EMPTY_TL, assets.TILE_EMPTY_TL, assets.TILE_EMPTY_TL, assets.TILE_EMPTY_TL,
        assets.TILE_EMPTY_TL, assets.TILE_EMPTY_TL, assets.TILE_EMPTY_TL, assets.TILE_EMPTY_TL,
        assets.TILE_TREASURE_0_TL, assets.TILE_TREASURE_1_TL, assets.TILE_TREASURE_2_TL,
        assets.TILE_TREASURE_3_TL, assets.TILE_TREASURE_4_TL, assets.TILE_TREASURE_5_TL,
        assets.TILE_TREASURE_6_TL, assets.TILE_TREASURE_7_TL, assets.TILE_TREASURE_8_TL,
        assets.TILE_TREASURE_9_TL, assets.TILE_TREASURE_10_TL, assets.TILE_TREASURE_11_TL,
        assets.TILE_TREASURE_12_TL, assets.TILE_TREASURE_13_TL, assets.TILE_TREASURE_14_TL
    ]
    ubyte[31] tile_color = [
        assets.TILE_EMPTY_COLOR, assets.TILE_SOLID_COLOR, assets.TILE_DAMAGED_COLOR, assets.TILE_FLOOR_COLOR,
        assets.TILE_EMPTY_COLOR, assets.TILE_EMPTY_COLOR, assets.TILE_EMPTY_COLOR, assets.TILE_EMPTY_COLOR,
        assets.TILE_EMPTY_COLOR, assets.TILE_EMPTY_COLOR, assets.TILE_EMPTY_COLOR, assets.TILE_EMPTY_COLOR,
        assets.TILE_EMPTY_COLOR, assets.TILE_EMPTY_COLOR, assets.TILE_EMPTY_COLOR, assets.TILE_EMPTY_COLOR,
        assets.TILE_TREASURE_0_COLOR, assets.TILE_TREASURE_1_COLOR, assets.TILE_TREASURE_2_COLOR,
        assets.TILE_TREASURE_3_COLOR, assets.TILE_TREASURE_4_COLOR, assets.TILE_TREASURE_5_COLOR,
        assets.TILE_TREASURE_6_COLOR, assets.TILE_TREASURE_7_COLOR, assets.TILE_TREASURE_8_COLOR,
        assets.TILE_TREASURE_9_COLOR, assets.TILE_TREASURE_10_COLOR, assets.TILE_TREASURE_11_COLOR,
        assets.TILE_TREASURE_12_COLOR, assets.TILE_TREASURE_13_COLOR, assets.TILE_TREASURE_14_COLOR
    ]

    ; ---- HUD layout (char row 0): "SCORE 000000   TIME 060   LEVEL 01" ----
    const ubyte HUD_SCORE_COL = 9
    const ubyte HUD_TIME_COL = 23
    const ubyte HUD_LEVEL_COL = 35

    sub init() {
        c64.SPENA = 0
        sys.memset(SCREEN, 1000, CHAR_SPACE)
        sys.memset(COLOR_RAM, 1000, COLOR_HUD)

        ; HUD font from the character ROM. With CHAREN=0 the ROM replaces I/O at $D000, so no IRQs meanwhile.
        sys.set_irqd()
        c64.banks(%010)
        sys.memcopy($D000, CHARSET, (HUD_FONT_CHARS as uword) * 8)
        c64.banks(%110)
        sys.clear_irqd()

        ; CPU writes to $E000-$FFFF reach the RAM under the KERNAL ROM
        sys.memcopy(&chars_bin, CHARSET + (assets.TILE_FIRST_CHAR as uword) * 8, (assets.TILE_COUNT as uword) * 32)
        sys.memcopy(&sprites_bin, SPRITE_DATA, (assets.SPRITE_COUNT as uword) * 64)
        sys.memset(CHARSET + (CHAR_BLOCK as uword) * 8, 8, $FF)
        sys.memcopy(&tri_chars, CHARSET + (CHAR_TRI_7 as uword) * 8, len(tri_chars))

        if MULTICOLOR {
            ubyte i
            for i in 0 to len(tile_color) - 1
                tile_color[i] |= 8
        }

        ; VIC bank 3: $DD00 bits 0-1 = %00. Screen at +$0000, charset at +$2000.
        c64.CIA2DDRA |= %00000011
        c64.CIA2PRA &= %11111100
        c64.VMCSB = $08
        cbm.HIBASE = $C0

        if MULTICOLOR {
            c64.SCROLX |= %00010000
            c64.SPMC = %00111111        ; sprites 6-7 (score popups) are hi-res
        } else {
            c64.SCROLX &= %11101111
            c64.SPMC = 0
        }
        c64.EXTCOL = COLOR_BORDER
        c64.BGCOL0 = COLOR_BG
        c64.BGCOL1 = COLOR_CHAR_MC1
        c64.BGCOL2 = COLOR_CHAR_MC2
        c64.SPMC0 = COLOR_SPR_MC1
        c64.SPMC1 = COLOR_SPR_MC2
    }

    sub set_title_mode() {
        ; Blank screen in hi-res character mode (all 16 colours per cell), no sprites.
        spr_ena = 0
        sys.memset(SCREEN, 1000, CHAR_SPACE)
        c64.SCROLX &= %11101111
    }

    sub set_game_mode() {
        ; Blank screen in the game's character mode. Sprites come back as the game draws them.
        ; Colour RAM too: the title leaves letter colours (multicolour values) where the HUD goes.
        sys.memset(SCREEN, 1000, CHAR_SPACE)
        sys.memset(COLOR_RAM, 1000, COLOR_HUD)
        if MULTICOLOR
            c64.SCROLX |= %00010000
    }

    sub draw_tile(ubyte col, ubyte row) {
        ubyte t = tiles[row_start[row] + col]
        ubyte ch = tile_char[t]
        ubyte co = tile_color[t]
        ^^ubyte @zp scr = tile_row_addr[row] + (col << 1)
        scr[0] = ch
        scr[1] = ch + 1
        scr[40] = ch + 2
        scr[41] = ch + 3
        scr += COLOR_RAM - SCREEN
        scr[0] = co
        scr[1] = co
        scr[40] = co
        scr[41] = co
    }

    sub highlight_tile(ubyte col, ubyte row) {
        ; Recolor a drawn tile with TARGET_COLOR. draw_tile() restores its own color.
        ubyte co = TARGET_COLOR
        if MULTICOLOR
            co |= 8
        ^^ubyte @zp scr = tile_row_addr[row] + (col << 1) + COLOR_RAM - SCREEN
        scr[0] = co
        scr[1] = co
        scr[40] = co
        scr[41] = co
    }

    sub draw_level() {
        ubyte row
        ubyte col
        for row in 0 to MAP_H - 1 {
            for col in 0 to MAP_W - 1
                draw_tile(col, row)
        }
    }

    sub hud_text(ubyte col, str text) {
        ^^ubyte @zp scr = SCREEN + col
        ubyte i = 0
        while text[i] != 0 {
            scr[i] = text[i]
            i++
        }
    }

    sub hud_digits(ubyte col, uword bcd, ubyte digits) {
        put_digits(SCREEN + col, bcd, digits)
    }

    sub put_digits(uword addr, uword bcd, ubyte digits) {
        ; Print the low `digits` BCD nibbles of bcd, most significant first, starting at screen address addr.
        ; Only digits that differ from what is on screen are written.
        ^^ubyte @zp scr = addr + digits - 1
        ubyte ch
        repeat digits {
            ch = '0' as ubyte + (lsb(bcd) & 15)
            if @(scr) != ch
                @(scr) = ch
            bcd >>= 4
            scr--
        }
    }

    sub message(ubyte row, ubyte col, str text) {
        ; Hi-res text over the playfield. draw_level() or restore_tiles() erases it.
        ^^ubyte @zp scr = SCREEN + (row as uword) * 40 + col
        ubyte i = 0
        while text[i] != 0 {
            scr[i] = text[i]
            i++
        }
        sys.memset(scr + COLOR_RAM - SCREEN, i, COLOR_HUD)
    }

    sub restore_tiles(ubyte row, ubyte col, ubyte n) {
        ; Redraw the tiles under n chars of a message at char row 1-24, starting at col.
        ubyte trow = (row - 1) >> 1
        ubyte tcol
        for tcol in col >> 1 to (col + n - 1) >> 1
            draw_tile(tcol, trow)
    }

    sub draw_hud_labels() {
        hud_text(3, sc:"score")
        hud_text(18, sc:"time")
        hud_text(29, sc:"level")
    }

    sub hud_score(uword bcd_hundreds) {
        hud_digits(HUD_SCORE_COL, bcd_hundreds, 4)
        hud_digits(HUD_SCORE_COL + 4, 0, 2)
    }

    sub hud_time(uword bcd) {
        hud_digits(HUD_TIME_COL, bcd, 3)
    }

    sub hud_level(ubyte bcd) {
        hud_digits(HUD_LEVEL_COL, bcd, 2)
    }

    ; ---- sprites and frame IRQ (spec section 1) ----
    ; Game code writes these shadows; the frame IRQ copies them to the VIC at the start of the next frame.
    const uword FRAME_IRQ_LINE = 251    ; first line of the bottom border (PAL)
    ubyte[8] spr_ptr
    ubyte[8] spr_col
    ubyte[8] spr_x
    ubyte[8] spr_y
    ubyte spr_msb
    ubyte spr_ena
    bool frame_ready
    ubyte scroll_y = 3                  ; vertical fine scroll ($D011 bits 0-2), set by the frame IRQ (shakes)
    ubyte spr_dy                        ; added to every sprite's y by the frame IRQ, so sprites shake with the screen

    ; ---- gameplay screen shake [TUNE] ----
    const ubyte NORMAL_SCROLL = 3
    const ubyte SHAKE_PX = 2            ; the screen and sprites drop this far on alternate frames
    const ubyte SHAKE_CRACK = 4         ; frames: fast-fall cracks a tile
    const ubyte SHAKE_SMASH = 8         ; frames: fast-fall destroys a tile, or kills an enemy
    ubyte shake_left

    sub shake(ubyte frames) {
        ; Start a shake, or restart it if this one is longer than what is left (shakes don't stack).
        if frames > shake_left
            shake_left = frames
    }

    sub shake_step() {
        ; Once per play frame.
        if shake_left != 0
            shake_left--
        if shake_left & 1 != 0 {
            scroll_y = NORMAL_SCROLL + SHAKE_PX
            spr_dy = SHAKE_PX
        } else {
            scroll_y = NORMAL_SCROLL
            spr_dy = 0
        }
    }

    sub stop_shake() {
        shake_left = 0
        shake_step()
    }
    ubyte frames                        ; counts frame IRQs (replaces the KERNAL jiffy clock)

    sub start_frame_irq() {
        sys.set_rasterirq(&frame_irq, FRAME_IRQ_LINE)
    }

    sub frame_irq() -> bool {
        ; Runs in the IRQ: no virtual registers, nothing slow.
        ; Unrolled copy of the 8 sprites' pointer, color, x and y (lda/sta pairs, about 300 cycles).
        ; y gets spr_dy added (screen shake).
        %asm {{
            .for _n := 0, _n < 8, _n += 1
            lda  p8b_video.p8v_spr_ptr+_n
            sta  p8b_video.p8c_SPRITE_PTRS+_n
            lda  p8b_video.p8v_spr_col+_n
            sta  c64.SPCOL+_n
            lda  p8b_video.p8v_spr_x+_n
            sta  c64.SPXY+_n*2
            lda  p8b_video.p8v_spr_y+_n
            clc
            adc  p8b_video.p8v_spr_dy
            sta  c64.SPXY+_n*2+1
            .endfor
        }}
        c64.MSIGX = spr_msb
        c64.SPENA = spr_ena
        c64.SCROLY = (c64.SCROLY & %01111000) | scroll_y   ; bit 7 (raster compare bit 8) stays 0
        sound.step()
        frame_ready = true
        frames++
        return false                    ; no KERNAL IRQ: the game reads the keyboard matrix itself
    }

    sub frame_lines() -> ubyte {
        ; Raster lines since the frame IRQ line (0-255; later lines read as 255). Only meaningful while the
        ; update hasn't run past the next frame IRQ (frame_ready still false).
        ubyte hi
        ubyte lo
        do {
            hi = c64.SCROLY & $80
            lo = c64.RASTER
        } until hi == c64.SCROLY & $80
        const ubyte IRQ_LINE = lsb(FRAME_IRQ_LINE)
        const ubyte TO_WRAP = 312 - FRAME_IRQ_LINE  ; lines from the IRQ line to line 0
        const ubyte TO_256 = 256 - FRAME_IRQ_LINE
        if hi != 0
            return lo + TO_256                      ; lines 256-311
        if lo >= IRQ_LINE
            return lo - IRQ_LINE
        if lo >= 255 - TO_WRAP
            return 255
        return lo + TO_WRAP                         ; lines 0-250 of the next screen
    }

    ubyte late_frames                   ; self-test: updates that ran past the next frame IRQ (dropped frames)

    sub wait_frame() {
        if frame_ready
            late_frames++
        while not frame_ready {
        }
        frame_ready = false
    }

    sub set_sprite(ubyte n, ubyte frame, ubyte color, uword px, ubyte py) {
        ; Playfield coordinates of the sprite's top-left -> hardware position (spec section 2).
        ; px may be slightly negative (wrapped uword); the +24 brings it back into range.
        ubyte bit = 1 << n
        spr_ptr[n] = frame
        spr_col[n] = color
        uword sx = px + 24
        spr_x[n] = lsb(sx)
        spr_y[n] = py + 50 + 8
        if msb(sx) != 0
            spr_msb |= bit
        else
            spr_msb &= ~bit
        spr_ena |= bit
    }

    sub hide_sprite(ubyte n) {
        spr_ena &= ~(1 << n)
    }

chars_bin:
    %asmbinary "build/chars.bin"
sprites_bin:
    %asmbinary "build/sprites.bin"
}
