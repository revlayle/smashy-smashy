; Attract pages (spec section 9): HOW TO PLAY and SCORING, shown after the title between games. The game's
; multicolour mode so tiles and sprites look as in play, text in hi-res cells from the HUD font.
; All page text is in the tables below.

%import video
%import input
%import score
%import enemies
%import popup

pages {
    ; [TUNE] frames each page is shown
    const uword TITLE_FRAMES = 500
    const uword HOW_FRAMES = 500
    const uword SCORING_FRAMES = 600

    ; ---- HOW TO PLAY: text lines (char row, column, text) ----
    ubyte[] how_row = [1, 4, 4, 7, 7, 10, 10, 13, 16, 17, 20, 21, 22]
    ubyte[] how_col = [14, 4, 16, 4, 16, 4, 16, 6, 4, 4, 4, 4, 4]
    uword[] how_text = [
        sc:"how to play",
        sc:"left/right", sc:"run",
        sc:"fire", sc:"jump - hold for higher",
        sc:"down in air", sc:"smash down",
        sc:"smash a brick twice to break it",
        sc:"land on enemies to bonk them",
        sc:"smash them to destroy them",
        sc:"grab all 10 treasures",
        sc:"enemies steal them - bonk them back!",
        sc:"beat the clock"
    ]
    ; sprites 0-3 at column 1, art centred on the rows of the single lines, top-aligned with the enemy's two
    ubyte[] how_frame = [assets.SPR_PLAYER_RUN_R_0, assets.SPR_PLAYER_JUMP_R_0, assets.SPR_PLAYER_FASTFALL_0,
                         assets.SPR_ENEMY_WALK_R_0]
    ubyte[] how_spr_col = [video.PLAYER_COLOR, video.PLAYER_COLOR, video.PLAYER_COLOR, video.ENEMY_COLOR]
    ubyte[] how_spr_y = [4 * 8 - 4, 7 * 8 - 4, 10 * 8 - 4, 16 * 8]      ; screen pixel rows from char row 0
    const ubyte HOW_SPR_X = 8
    ; tiles: (char row, column, tile)
    ubyte[] how_tile_row = [13, 13, 20]
    ubyte[] how_tile_col = [1, 3, 1]
    ubyte[] how_tile = [video.T_SOLID, video.T_DAMAGED, video.T_TREASURE]

    ; ---- SCORING ----
    ubyte[] score_row = [1, 16, 18, 18, 20, 20]
    ubyte[] score_col = [16, 1, 1, 22, 1, 22]
    uword[] score_text = [
        sc:"scoring",
        sc:"smash chain",
        sc:"no kill bonus 2500", sc:"time +60 per level",
        sc:"hit -10 seconds", sc:"high score"
    ]
    const ubyte GRID_ROW = 3            ; first row of treasure tiles; 4 rows per line (tile, value, gap)
    const ubyte GRID_COL = 3            ; first column; 8 columns per treasure
    const ubyte CHAIN_ROW = 16
    const ubyte CHAIN_COL = 14
    const ubyte HIGH_ROW = 20
    const ubyte HIGH_COL = 33
    ; The chain colours (popup.rank_color) include 8 and 10, which a multicolour-mode cell can't show in
    ; hi-res. So the text rows below the treasures are shown in hi-res character mode: from this raster line
    ; (char row 15, empty) to the frame IRQ.
    const ubyte SPLIT_LINE = 50 + 15 * 8

    sub how_to_play() -> bool {
        ; Show HOW TO PLAY for HOW_FRAMES frames. True if fire was pressed.
        video.set_game_mode()
        ubyte i
        for i in 0 to len(how_row) - 1
            video.message(how_row[i], how_col[i], how_text[i])
        for i in 0 to len(how_tile) - 1
            put_tile(how_tile_row[i], how_tile_col[i], how_tile[i])
        for i in 0 to len(how_frame) - 1
            video.set_sprite(i, how_frame[i], how_spr_col[i], HOW_SPR_X, how_spr_y[i] - 8)
        return wait(HOW_FRAMES, false)
    }

    sub scoring() -> bool {
        ; Show SCORING for SCORING_FRAMES frames. True if fire was pressed.
        video.set_game_mode()
        ubyte i
        uword addr
        for i in 0 to len(score_row) - 1
            video.message(score_row[i], score_col[i], score_text[i])
        ; the 15 treasures in 3 lines of 5, each value centred under its tile
        ubyte row = GRID_ROW
        ubyte col = GRID_COL
        for i in 0 to 14 {
            put_tile(row, col, video.T_TREASURE + i)
            ubyte p = score.treasure_points[i]
            addr = video.SCREEN + ((row + 2) as uword) * 40 + col
            if p >= $10
                addr--
            void put_value(addr, p)
            col += 8
            if col > GRID_COL + 4 * 8 {
                col = GRID_COL
                row += 4
            }
        }
        ; chain values in the popup colours
        addr = video.SCREEN + CHAIN_ROW * 40 + CHAIN_COL
        for i in 0 to len(enemies.kill_points) - 1 {
            ubyte n = put_value(addr, enemies.kill_points[i])
            sys.memset(addr + video.COLOR_RAM - video.SCREEN, n, popup.rank_color[i + 1])
            addr += n + 1
        }
        addr = video.SCREEN + HIGH_ROW * 40 + HIGH_COL
        video.put_digits(addr, score.high, 4)
        video.put_digits(addr + 4, 0, 2)
        return wait(SCORING_FRAMES, true)
    }

    sub wait(uword frames, bool split) -> bool {
        ; Wait the given frames or until fire (true), then hide the page's sprites.
        ; split: hi-res character mode from SPLIT_LINE down, multicolour again from the frame IRQ.
        bool fire = false
        repeat frames {
            video.wait_frame()
            if split
                c64.SCROLX |= %00010000
            input.read()
            if input.pressed & input.FIRE != 0 {
                fire = true
                break
            }
            if split {
                while c64.RASTER != SPLIT_LINE {
                }
                c64.SCROLX &= %11101111
            }
        }
        video.spr_ena = 0
        return fire
    }

    sub put_tile(ubyte row, ubyte col, ubyte t) {
        ; A 2x2-char tile at any char position, with its normal chars and colour.
        ubyte ch = video.tile_char[t]
        ubyte co = video.tile_color[t]
        ^^ubyte @zp scr = video.SCREEN + (row as uword) * 40 + col
        scr[0] = ch
        scr[1] = ch + 1
        scr[40] = ch + 2
        scr[41] = ch + 3
        scr += video.COLOR_RAM - video.SCREEN
        scr[0] = co
        scr[1] = co
        scr[40] = co
        scr[41] = co
    }

    sub put_value(uword addr, ubyte bcd_hundreds) -> ubyte {
        ; Points given in BCD hundreds as 3 or 4 digits (no leading zero) at addr. Returns the width.
        ubyte n = 3
        if bcd_hundreds >= $10 {
            video.put_digits(addr, bcd_hundreds, 2)
            n = 4
        } else
            video.put_digits(addr, bcd_hundreds, 1)
        video.put_digits(addr + n - 2, 0, 2)
        return n
    }
}
