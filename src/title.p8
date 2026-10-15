; Title screen (spec section 9): SMASHY SMASHY in block letters with drop shadows, hi-res character mode.
; The letters smash in from above with a screen shake, then a rainbow colour sweep rolls over them.
; PRESS FIRE blinks under the title, with the session high score. Fire starts a game and seeds the RNG.

%import video
%import input
%import score
%import levelgen

title {
    ; Letter shapes: '#' = block, '.' = empty, rows separated by spaces, 5 rows each. Any width up to 5.
    str shape_s = "### #.. ### ..# ###"
    str shape_m = "#...# ##.## #.#.# #...# #...#"
    str shape_a = "### #.# ### #.# #.#"
    str shape_h = "#.# #.# ### #.# #.#"
    str shape_y = "#.# #.# .#. .#. .#."
    const ubyte SHAPES = 5
    const ubyte SH_S = 0
    const ubyte SH_M = 1
    const ubyte SH_A = 2
    const ubyte SH_H = 3
    const ubyte SH_Y = 4
    const ubyte LETTER_ROWS = 5

    ; The 12 letters in drop order. The bottom line drops first, so a falling letter never passes through
    ; a letter that has already landed.
    const ubyte LETTERS = 12
    ubyte[LETTERS] l_shape = [SH_S, SH_M, SH_A, SH_S, SH_H, SH_Y,   SH_S, SH_M, SH_A, SH_S, SH_H, SH_Y]
    ubyte[LETTERS] l_col = [11, 15, 21, 25, 29, 33,   4, 8, 14, 18, 22, 26]
    ubyte[LETTERS] l_row = [10, 10, 10, 10, 10, 10,   3, 3, 3, 3, 3, 3]
    byte[LETTERS] l_top                 ; current top row while falling (negative = above the screen)

    ; [TUNE]
    const ubyte SHADOW_COLOR = 11       ; dark grey, 1 char right and 1 char down
    const ubyte TEXT_COLOR = 1
    const ubyte DROP_GAP = 4            ; frames between letters starting to fall
    const byte START_TOP = -6           ; letter and shadow fully above the screen
    const ubyte SHAKE_FRAMES = 8
    const ubyte SHAKE_SCROLL = 5        ; $D011 fine scroll during a shake: 2 px below the normal 3
    const ubyte NORMAL_SCROLL = 3
    const ubyte WORK_LINE = 180         ; raster line just below the title letters: drawing starts here, so
                                        ; it is done before the beam comes back to them
    const ubyte SWEEP_FRAMES = 2        ; colour sweep step every 2 frames
    const ubyte BLINK_FRAMES = 25       ; PRESS FIRE on 25 frames, off 25
    ubyte[16] sweep = [9, 2, 8, 10, 15, 7, 1, 1, 7, 15, 10, 8, 2, 9, 6, 6]

    const ubyte FIRE_ROW = 19
    const ubyte FIRE_COL = 15
    const ubyte HIGH_ROW = 22
    const ubyte HIGH_COL = 11

    ubyte[SHAPES * LETTER_ROWS] masks   ; bit c set = block in column c
    ; Per shape, 8 rows of letter and shadow together (the shadow is 1 row lower and 1 column right):
    ; index i = row i - 1 of the 6-row box, so i = 0 and 7 are empty rows above and below it.
    ubyte[SHAPES * 8] row_l             ; letter cells
    ubyte[SHAPES * 8] row_s             ; shadow cells not covered by the letter
    ubyte[SHAPES * 8] row_a             ; either
    ubyte[SHAPES] widths
    uword[25] row_addr                  ; screen address of each char row
    uword[22] top_addr                  ; screen address of char row t (-6 to 15) at index t + 6, wrapping

    ; letter blocks after landing, for the sweep: colour RAM address and (column + row) & 15
    const ubyte MAX_BLOCKS = 200
    uword[MAX_BLOCKS] blk_addr
    ubyte[MAX_BLOCKS] blk_base
    ubyte blk_count

    ubyte phase                         ; sweep phase (0 during the intro)
    ubyte shake

    sub init() {
        ; Once at startup: parse the shapes and list the landed letters' blocks.
        uword a = video.SCREEN
        ubyte r
        for r in 0 to 24 {
            row_addr[r] = a
            a += 40
        }
        a = video.SCREEN - 6 * 40
        for r in 0 to len(top_addr) - 1 {
            top_addr[r] = a
            a += 40
        }
        parse(SH_S, shape_s)
        parse(SH_M, shape_m)
        parse(SH_A, shape_a)
        parse(SH_H, shape_h)
        parse(SH_Y, shape_y)
        ubyte sh
        ubyte i
        for sh in 0 to SHAPES - 1 {
            for i in 0 to 7 {
                ubyte j = i - 1         ; box row (255 for i = 0)
                ubyte lm = 0
                ubyte sm = 0
                if j < LETTER_ROWS
                    lm = masks[sh * LETTER_ROWS + j]
                if j >= 1 and j <= LETTER_ROWS
                    sm = masks[sh * LETTER_ROWS + j - 1] << 1
                row_l[sh * 8 + i] = lm
                row_s[sh * 8 + i] = sm & ~lm
                row_a[sh * 8 + i] = lm | sm
            }
        }
        blk_count = 0
        ubyte k
        for k in 0 to LETTERS - 1 {
            sh = l_shape[k]
            for r in 0 to LETTER_ROWS - 1 {
                ubyte m = masks[sh * LETTER_ROWS + r]
                ubyte row = l_row[k] + r
                ubyte col = l_col[k]
                while m != 0 {
                    if m & 1 != 0 and blk_count < MAX_BLOCKS {
                        blk_addr[blk_count] = row_addr[row] + col + video.COLOR_RAM - video.SCREEN
                        blk_base[blk_count] = (col + row) & 15
                        blk_count++
                    }
                    m >>= 1
                    col++
                }
            }
        }
    }

    sub parse(ubyte sh, str text) {
        ubyte i = 0
        ubyte r = 0
        ubyte c = 0
        ubyte w = 0
        while text[i] != 0 {
            when text[i] {
                '#' -> {
                    masks[sh * LETTER_ROWS + r] |= 1 << c
                    c++
                }
                '.' -> c++
                ' ' -> {
                    r++
                    c = 0
                }
            }
            if c > w
                w = c
            i++
        }
        widths[sh] = w
    }

    sub run() {
        ; Show the title until fire is pressed, then seed the RNG.
        video.set_title_mode()
        ubyte k
        for k in 0 to LETTERS - 1
            l_top[k] = START_TOP
        phase = 0
        shake = 0
        video.message(FIRE_ROW, FIRE_COL, sc:"press fire")
        video.message(HIGH_ROW, HIGH_COL, sc:"high score")
        uword hs = row_addr[HIGH_ROW] + HIGH_COL + 11
        video.put_digits(hs, score.high, 4)
        video.put_digits(hs + 4, 0, 2)
        sys.memset(hs + video.COLOR_RAM - video.SCREEN, 6, TEXT_COLOR)

        ubyte t = 0                     ; intro frame, stops counting once all letters are down
        ubyte landed = 0
        ubyte sweep_timer = SWEEP_FRAMES
        ubyte blink = 0
        repeat {
            ; once per frame, from the line below the letters (the frame IRQ sets the fine scroll in the border)
            while c64.RASTER != WORK_LINE {
            }
            if shake != 0
                shake--
            video.scroll_y = if shake & 1 != 0 SHAKE_SCROLL else NORMAL_SCROLL

            input.read()
            if input.pressed & input.FIRE != 0
                break

            if landed < LETTERS {
                ; the top line's letters first: the beam reaches them first
                for k in LETTERS - 1 downto 0 {
                    if t >= k * DROP_GAP and l_top[k] != (l_row[k] as byte) {
                        move_letter(k)
                        if l_top[k] == (l_row[k] as byte) {
                            landed++
                            shake = SHAKE_FRAMES
                        }
                    }
                }
                t++
            } else {
                sweep_timer--
                if sweep_timer == 0 {
                    sweep_timer = SWEEP_FRAMES
                    phase = (phase + 1) & 15
                    do_sweep()
                }
            }

            ; PRESS FIRE: colour on or off (background colour)
            if blink == 0
                sys.memset(row_addr[FIRE_ROW] + FIRE_COL + video.COLOR_RAM - video.SCREEN, 10, TEXT_COLOR)
            else if blink == BLINK_FRAMES
                sys.memset(row_addr[FIRE_ROW] + FIRE_COL + video.COLOR_RAM - video.SCREEN, 10, video.COLOR_BG)
            blink++
            if blink == BLINK_FRAMES * 2
                blink = 0
        }
        video.scroll_y = NORMAL_SCROLL
        levelgen.seed()
    }

    ; move_rows() arguments
    ubyte pl_skip                       ; rows above the screen, not drawn
    ubyte pl_base                       ; index of the letter's shape in row_l, row_s, row_a
    ubyte pl_cidx                       ; sweep index of the letter's top-left cell at the new position

    sub move_letter(ubyte k) {
        ; Move letter k (and its shadow) down one row in a single pass over the 7 rows involved, so a row is
        ; never seen half drawn: cells it leaves are cleared, the rest are drawn at the new position.
        byte top = l_top[k]
        pl_skip = 0
        if top < 0
            pl_skip = -top as ubyte
        pl_base = l_shape[k] * 8
        pl_cidx = (l_col[k] + (top as ubyte) + 1 + phase) & 15
        move_rows(top_addr[(top + 6) as ubyte] + l_col[k])
        l_top[k] = top + 1
    }

    asmsub move_rows(uword scr @AY) clobbers(A, X, Y) {
        ; scr = the letter's box at its old top row. For box row s = 0-6 from there, the old cells are
        ; row_a[pl_base + s + 1] and the new ones row_l/row_s[pl_base + s]. Rows s < pl_skip are skipped.
        %asm {{
_scr = P8ZP_SCRATCH_W1
_clr = P8ZP_SCRATCH_W2
_l = P8ZP_SCRATCH_B1
_s = P8ZP_SCRATCH_REG
            .section BSS
_row        .byte ?
_e          .byte ?
_cidx       .byte ?
            .send BSS
            sta  _scr
            sty  _scr+1
            sta  _clr
            tya
            clc
            adc  #>(p8b_video.p8c_COLOR_RAM - p8b_video.p8c_SCREEN)
            sta  _clr+1
            lda  #0
            sta  _row
            lda  p8v_pl_cidx
            sec
            sbc  #1                     ; row s of the old box is row s - 1 of the new one
            sta  _cidx
_rowloop
            lda  _row
            cmp  p8v_pl_skip
            bcc  _nextrow
            clc
            adc  p8v_pl_base
            tax
            lda  p8v_row_l,x
            sta  _l
            lda  p8v_row_s,x
            sta  _s
            ora  _l
            eor  #$ff
            and  p8v_row_a+1,x
            sta  _e                     ; old cells that stay empty now
            ldy  #0
_cell
            lda  _l
            ora  _s
            ora  _e
            beq  _nextrow
            lsr  _e
            bcc  +
            lda  #p8b_video.p8c_CHAR_SPACE
            sta  (_scr),y
+           lsr  _s
            bcc  +
            lda  #p8b_video.p8c_CHAR_BLOCK
            sta  (_scr),y
            lda  #p8c_SHADOW_COLOR
            sta  (_clr),y
+           lsr  _l
            bcc  +
            lda  #p8b_video.p8c_CHAR_BLOCK
            sta  (_scr),y
            tya
            clc
            adc  _cidx
            and  #15
            tax
            lda  p8v_sweep,x
            sta  (_clr),y
+           iny
            jmp  _cell
_nextrow
            inc  _cidx
            clc
            lda  _scr
            adc  #40
            sta  _scr
            sta  _clr
            bcc  +
            inc  _scr+1
            inc  _clr+1
+           inc  _row
            lda  _row
            cmp  #7
            bne  _rowloop
            rts
        }}
    }

    sub do_sweep() {
        ; Recolour the letter blocks only (shadows and empty cells are never touched).
        ubyte i
        for i in 0 to blk_count - 1
            @(blk_addr[i]) = sweep[(blk_base[i] + phase) & 15]
    }
}
