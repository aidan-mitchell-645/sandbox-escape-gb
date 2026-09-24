; ===========================================================================
;  SANDBOX ESCAPE — Game Boy Color Platformer
;  Build 9 — Full platformer rewrite
;
;  Architecture:
;   - No interrupts, no halt. Pure LY-polling VBlank sync.
;   - DMA OAM copy via HRAM routine.
;   - GBC flag detected at boot, stored in HRAM + WRAM.
;   - BG layer = world tilemap (scrolled via rSCX/rSCY).
;   - Window layer = HUD (bottom 2 rows, rWY = 128).
;   - Sprites: player (2 OBJ, 8×16 effective), vuln nodes, exploit pickups.
;   - Physics: 8-bit fixed-point positions, AABB tile collision.
; ===========================================================================

INCLUDE "hardware.inc"

; ---------------------------------------------------------------------------
; Constants — Game States
; ---------------------------------------------------------------------------
DEF STATE_TITLE   EQU 0
DEF STATE_INTRO   EQU 1
DEF STATE_PLAY    EQU 2
DEF STATE_DIALOG  EQU 3
DEF STATE_WIN     EQU 4
DEF STATE_MAP     EQU 5   ; world map between levels
DEF STATE_PATCHED EQU 6   ; "you've been patched" screen after advisory hit
DEF STATE_BOSS    EQU 7   ; boss fight vs Patch

; ---------------------------------------------------------------------------
; Constants — Physics
; ---------------------------------------------------------------------------
DEF GRAVITY       EQU 1
DEF JUMP_VY       EQU 246   ; -10 as unsigned byte (256-10)
DEF RUN_VX        EQU 1
DEF MAX_FALL      EQU 8     ; must match intYStep clamp (8px max per frame)
DEF FRICTION      EQU 1

; ---------------------------------------------------------------------------
; Constants — Zone / world
; ---------------------------------------------------------------------------
DEF NUM_ZONES     EQU 6   ; level 0 zone count (original)
DEF ZONE_COLS     EQU 20
DEF ZONE_ROWS     EQU 16
DEF ZONE_SIZE     EQU ZONE_COLS * ZONE_ROWS   ; 320 bytes per zone

; Zone connection constants (which zone connects where)
; Each zone edge encodes: direction + target zone
DEF EDGE_NONE     EQU $FF
DEF DIR_RIGHT     EQU 0
DEF DIR_LEFT      EQU 1
DEF DIR_DOWN      EQU 2
DEF DIR_UP        EQU 3

; Passage tile rows/cols (open gap in wall)
DEF PASS_ROW      EQU 8     ; passage starts at row 8
DEF PASS_COL      EQU 8     ; passage starts at col 8


; Vuln node indices
DEF VULN_0        EQU 0     ; Zone 0, col 12, row 7
DEF VULN_1        EQU 1     ; Zone 3, col 10, row 8
DEF VULN_2        EQU 2     ; Zone 4, col 8,  row 8

; Exploit spawn zone/col/row (activated after scanning corresponding vuln)
; Each exploit floats in a void row ABOVE a platform so it is visible and reachable.
DEF EXP0_ZONE     EQU 5
DEF EXP0_COL      EQU 7          ; Zone 5 platform at row 3 cols 4-10, col 7 row 2 = void above
DEF EXP0_ROW      EQU 2
DEF EXP1_ZONE     EQU 2
DEF EXP1_COL      EQU 7          ; Zone 2 platform at row 5 cols 4-11, col 7 row 4 = void above
DEF EXP1_ROW      EQU 4
DEF EXP2_ZONE     EQU 1
DEF EXP2_COL      EQU 9          ; Zone 1 platform at row 6 cols 7-11, col 9 row 5 = void above
DEF EXP2_ROW      EQU 5

; OBJ tile indices — sprites loaded at $8800 = OBJ tile $80 in BG8000 mode
DEF SPR_HEAD_IDLE EQU $80
DEF SPR_BODY_IDLE EQU $81
DEF SPR_HEAD_RUN0 EQU $82
DEF SPR_BODY_RUN0 EQU $83
DEF SPR_HEAD_RUN1 EQU $84
DEF SPR_BODY_RUN1 EQU $85
DEF SPR_HEAD_JUMP EQU $86
DEF SPR_BODY_JUMP EQU $87
DEF SPR_VULN_A    EQU $88
DEF SPR_VULN_B    EQU $89
DEF SPR_EXP_PICK  EQU $8A   ; exploit 0: microchip (Log4Shell)
DEF SPR_EXP_SCR   EQU $8B   ; exploit 1: script file (EternalBlue)
DEF SPR_EXP_TERM  EQU $8C   ; exploit 2: terminal prompt (Sudo Baron)
DEF SPR_ADVISORY  EQU $8D   ; advisory enemy: crawling bug
DEF SPR_BOSS_HEAD EQU $8E   ; Patch boss head
DEF SPR_BOSS_BODY EQU $8F   ; Patch boss body

; BG gameplay tile indices — loaded at $8C00 = BG tile $60+ in BG8000 mode
; (font occupies $8000-$85E0 = tiles $00-$5E)
DEF T_VOID        EQU $60
DEF T_PLAT_MID    EQU $61
DEF T_PLAT_L      EQU $62
DEF T_PLAT_R      EQU $63
DEF T_WALL        EQU $64
DEF T_BG_DOT      EQU $65
DEF T_BG_HLINE    EQU $66
DEF T_BG_VLINE    EQU $67
DEF T_VULN_A_BG   EQU $68
DEF T_VULN_B_BG   EQU $69
DEF T_VULN_SCAN   EQU $6A
DEF T_VULN_EXP    EQU $6B
DEF T_EXPLOIT     EQU $6C
DEF T_HUD_BAR     EQU $6D
DEF T_BEAM_FULL   EQU $6E
DEF T_BEAM_FADE   EQU $6F

; Aliases and derived constants (defined after the tile IDs they reference)
DEF T_VULN_A      EQU T_VULN_A_BG
DEF T_VULN_B      EQU T_VULN_B_BG
DEF SOLID_MAX     EQU T_WALL      ; tiles $60-$64 are solid

; OAM slot assignments
DEF OAM_PLAYER_HEAD EQU 0   ; OAM entry 0
DEF OAM_PLAYER_BODY EQU 1   ; OAM entry 1
DEF OAM_VULN0       EQU 2
DEF OAM_VULN1       EQU 3
DEF OAM_VULN2       EQU 4
DEF OAM_EXP0        EQU 5
DEF OAM_EXP1        EQU 6
DEF OAM_EXP2        EQU 7
DEF OAM_ADV0        EQU 8   ; advisory 0
DEF OAM_ADV1        EQU 9
DEF OAM_ADV2        EQU 10
DEF OAM_ADV3        EQU 11
DEF OAM_ADV4        EQU 12
DEF MAX_ADVISORIES  EQU 5
DEF OAM_BOSS_HEAD   EQU 13  ; boss head sprite
DEF OAM_BOSS_BODY   EQU 14  ; boss body sprite
DEF BOSS_MAX_HP     EQU 3   ; hits to defeat Patch

; Scan animation
DEF SCAN_FRAMES     EQU 32  ; total frames for scan animation
DEF SCAN_RANGE      EQU 80  ; pixels the beam reaches

; LCD values
; LCD modes:
;  TEXT = BG + window, no sprites (title, intro, dialog)
;  PLAY = BG + window + sprites (platformer gameplay)
DEF LCD_TEXT        EQU LCDCF_ON | LCDCF_BG8000 | LCDCF_BGON | LCDCF_WINON | LCDCF_WIN9C00
DEF LCD_PLAY        EQU LCD_TEXT | LCDCF_OBJON
DEF LCD_ON_WIN      EQU LCD_TEXT

; ---------------------------------------------------------------------------
; Audio registers (hardware.inc only has NR1x + NR50/51/52)
; ---------------------------------------------------------------------------
DEF rNR21  EQU $FF16   ; CH2 duty / length
DEF rNR22  EQU $FF17   ; CH2 envelope
DEF rNR23  EQU $FF18   ; CH2 freq lo
DEF rNR24  EQU $FF19   ; CH2 freq hi / trigger
DEF rNR41  EQU $FF20   ; CH4 length
DEF rNR42  EQU $FF21   ; CH4 envelope
DEF rNR43  EQU $FF22   ; CH4 polynomial counter
DEF rNR44  EQU $FF23   ; CH4 trigger

; Music song IDs (stored in wMusicSong)
DEF SONG_OFF    EQU 0
DEF SONG_TITLE  EQU 1
DEF SONG_PLAY   EQU 2
DEF SONG_BOSS   EQU 3

; Note encoding: high nibble = octave (0-6), low nibble = semitone (0-11)
; Special: $FF = rest, $FE = tie (hold previous)
; Tempo: frames per row stored in song header

; ---------------------------------------------------------------------------
; WRAM layout
; ---------------------------------------------------------------------------
SECTION "WRAM", WRAM0[$C000]
wGameState:      DS 1   ; $C000
wIsGBC:          DS 1   ; $C001
wFrame:          DS 1   ; $C002

; Player
wPX:             DS 1   ; $C003  player X pixel (screen space 0-152)
wPY:             DS 1   ; $C004  player Y pixel (screen space 0-127)
wPVX:            DS 1   ; $C005  velocity X signed byte
wPVY:            DS 1   ; $C006  velocity Y signed byte
wPFacing:        DS 1   ; $C007  0=right 1=left
wPOnGround:      DS 1   ; $C008
wPAnimFrame:     DS 1   ; $C009
wPAnimTimer:     DS 1   ; $C00A

; Camera / zone
wZone:           DS 1   ; $C00B  current zone (0-5)
wCamX:           DS 1   ; $C00C  camera X (= zone_col * 8 offset, 0 for now)
wCamY:           DS 1   ; $C00D

; Input
wJoypad:         DS 1   ; $C00E
wJoypadPrev:     DS 1   ; $C00F
wJoypadNew:      DS 1   ; $C010

; Game progress
wVulnScanned:    DS 1   ; $C011  bitmask bits 0-2
wVulnExploited:  DS 1   ; $C012  bitmask bits 0-2
wExploitSpawned: DS 1   ; $C013  bitmask bits 0-2 (exploit item in world)
wExploitHeld:    DS 1   ; $C014  0=none, 1/2/3 = which one
wHealth:         DS 1   ; $C015

; Scan animation
wScanActive:     DS 1   ; $C016
wScanTimer:      DS 1   ; $C017
wScanVulnIdx:    DS 1   ; $C018
wScanX:          DS 1   ; $C019  screen X where beam starts
wScanBeamLen:    DS 1   ; $C01A  current beam length in tiles

; Dialog
wDialogActive:   DS 1   ; $C01B
wDialogLine1:    DS 2   ; $C01C-$C01D  pointer to line1 string
wDialogLine2:    DS 2   ; $C01E-$C01F  pointer to line2 string

; Intro
wIntroPage:      DS 1   ; $C020

; Timer (frames elapsed since game start, 16-bit)
wTimerLo:        DS 1   ; $C021  low byte
wTimerHi:        DS 1   ; $C022  high byte

; Multi-level progress
wCurrentLevel:   DS 1   ; $C023  active level index (0-4)
wMapCursor:      DS 1   ; $C024  world map cursor (0-4)
wLevelComplete:  DS 1   ; $C025  bitmask bits 0-4 completed levels
; Per-level runtime state (populated by InitLevel from LevelTable)
wNumZones:       DS 1   ; $C026  number of zones in current level
wNumVulns:       DS 1   ; $C027  number of vulns in current level (1=2vulns 0=3vulns if bit)
wLvlZoneTableLo: DS 1   ; $C028  zone table ptr lo
wLvlZoneTableHi: DS 1   ; $C029  zone table ptr hi
wLvlAdjTableLo:  DS 1   ; $C02A  adj table ptr lo
wLvlAdjTableHi:  DS 1   ; $C02B  adj table ptr hi
; Vuln positions (zone/row/col) for up to 3 vulns
wVuln0Zone:      DS 1   ; $C02C
wVuln0Row:       DS 1   ; $C02D
wVuln0Col:       DS 1   ; $C02E
wVuln1Zone:      DS 1   ; $C02F
wVuln1Row:       DS 1   ; $C030
wVuln1Col:       DS 1   ; $C031
wVuln2Zone:      DS 1   ; $C032
wVuln2Row:       DS 1   ; $C033
wVuln2Col:       DS 1   ; $C034
; Exploit spawn positions (zone/row/col) for up to 3 exploits
wExp0Zone:       DS 1   ; $C035
wExp0Row:        DS 1   ; $C036
wExp0Col:        DS 1   ; $C037
wExp1Zone:       DS 1   ; $C038
wExp1Row:        DS 1   ; $C039
wExp1Col:        DS 1   ; $C03A
wExp2Zone:       DS 1   ; $C03B
wExp2Row:        DS 1   ; $C03C
wExp2Col:        DS 1   ; $C03D
; Start position
wLvlStartZone:   DS 1   ; $C03E
wLvlStartX:      DS 1   ; $C03F
wLvlStartY:      DS 1   ; $C040

; Advisory enemy state — up to 5 advisories (X, Y, VX, Zone = 4 bytes × 5 = 20 bytes)
wAdvCount:       DS 1   ; $C041  number of active advisories this level (0-5)
wAdv0X:          DS 1   ; $C042
wAdv0Y:          DS 1   ; $C043
wAdv0VX:         DS 1   ; $C044  velocity: 1=right, 255=left
wAdv0Zone:       DS 1   ; $C045  zone this advisory patrols
wAdv1X:          DS 1   ; $C046
wAdv1Y:          DS 1   ; $C047
wAdv1VX:         DS 1   ; $C048
wAdv1Zone:       DS 1   ; $C049
wAdv2X:          DS 1   ; $C04A
wAdv2Y:          DS 1   ; $C04B
wAdv2VX:         DS 1   ; $C04C
wAdv2Zone:       DS 1   ; $C04D
wAdv3X:          DS 1   ; $C04E
wAdv3Y:          DS 1   ; $C04F
wAdv3VX:         DS 1   ; $C050
wAdv3Zone:       DS 1   ; $C051
wAdv4X:          DS 1   ; $C052
wAdv4Y:          DS 1   ; $C053
wAdv4VX:         DS 1   ; $C054
wAdv4Zone:       DS 1   ; $C055
wAdvHit:         DS 1   ; $C056  set to 1 when player touches an advisory; cleared at top of UpdatePlay
wSpawnGrace:     DS 1   ; $C057  frames of invincibility after zone load; counts down each frame
; Boss state
wBossX:          DS 1   ; $C058
wBossVX:         DS 1   ; $C059  1=right 255=left
wBossHP:         DS 1   ; $C05A
wBossHitTimer:   DS 1   ; $C05B
wKonamiStep:     DS 1   ; $C05C  Konami code progress (0-9); 10 = complete

; Music engine state
wMusicSong:      DS 1   ; $C05D  current song: 0=off 1=title 2=play 3=boss
wMusicRow:       DS 1   ; $C05E  current row in pattern
wMusicTick:      DS 1   ; $C05F  tick-within-row counter
wMusicPatIdx:    DS 1   ; $C060  current pattern index in song order
wMusicTempoRel:  DS 1   ; $C061  frames per tick (set per song)
wMusicCH1Duty:   DS 1   ; $C062  last CH1 duty/len written (for retriggering)

; OAM shadow buffer (40 entries × 4 bytes)
SECTION "OAMBuf", WRAM0[$C100]
wOAMBuf:         DS 160


; ---------------------------------------------------------------------------
; Interrupt / RST vectors $0000-$00FF — claim this space so linker cannot
; place floating ROM sections here (which would corrupt tile load addresses).
; ---------------------------------------------------------------------------
SECTION "Vectors", ROM0[$0000]
    DS $100     ; padding — RSTs and VBlank/LCD/Timer/Serial/Joypad vectors

; ---------------------------------------------------------------------------
; ROM Header $0100-$014F
; ---------------------------------------------------------------------------
SECTION "Header", ROM0[$100]
    nop
    jp      EntryPoint

    DB $CE,$ED,$66,$66,$CC,$0D,$00,$0B,$03,$73,$00,$83,$00,$0C,$00,$0D
    DB $00,$08,$11,$1F,$88,$89,$00,$0E,$DC,$CC,$6E,$E6,$DD,$DD,$D9,$99
    DB $BB,$BB,$67,$63,$6E,$0E,$EC,$CC,$DD,$DC,$99,$9F,$BB,$B9,$33,$3E

    DB "SANDBOXESCAPE  "   ; title 15 bytes $0134-$0142
    DB $80                  ; $0143 GBC-enhanced, DMG-compatible
    DB $00,$00              ; $0144-$0145 new licensee
    DB $00                  ; $0146 SGB flag
    DB $01                  ; $0147 cart type: MBC1, no RAM
    DB $01                  ; $0148 ROM: 64KB (4 banks)
    DB $00                  ; $0149 RAM: none
    DB $01                  ; $014A non-Japanese
    DB $33                  ; $014B old licensee
    DB $01                  ; $014C version
    DB $00                  ; $014D header checksum (rgbfix -v fills)
    DW $0000                ; $014E-$014F global checksum

; ---------------------------------------------------------------------------
; HRAM — DMA routine + GBC flag slot
; ---------------------------------------------------------------------------
SECTION "HRAM", HRAM[$FF80]
hGBCFlag:   DS 1            ; $FF80 — A at boot ($11=GBC $01=DMG)
hDMA:       DS 12           ; $FF81-$FF8C — OAM DMA routine copy

; ---------------------------------------------------------------------------
; Entry Point $0150
; ---------------------------------------------------------------------------
SECTION "EntryPoint", ROM0[$150]

EntryPoint:
    di
    ; Save GBC flag in HRAM before anything clobbers A
    ld      [$FF80], a
    ld      sp, $FFFE

    ; Turn LCD off — wait for VBlank first
.waitVBLoff:
    ld      a, [rLY]
    cp      144
    jr      c, .waitVBLoff
    xor     a
    ld      [rLCDC], a      ; LCD OFF

    ; Zero OAM ($FE00-$FE9F) — must be done with LCD off
    ld      hl, $FE00
    ld      b, $A0
    xor     a
.zeroOAM:
    ld      [hl+], a
    dec     b
    jr      nz, .zeroOAM

    ; Zero VRAM bank 0 ($8000-$9FFF) — tile data + tilemap
    xor     a
    ld      [rVBK], a
    ld      hl, $8000
    ld      bc, $2000
.zeroVRAM0:
    ld      [hl+], a
    dec     bc
    ld      a, b
    or      c
    ld      a, 0
    jr      nz, .zeroVRAM0

    ; Zero VRAM bank 1 ($8000-$9FFF) — GBC attribute map (palette/flip/bank)
    ; Must be zeroed or tiles use random palettes from boot ROM
    ld      a, 1
    ld      [rVBK], a
    xor     a               ; A must be 0 before entering loop (rVBK write leaves A=1)
    ld      hl, $8000
    ld      bc, $2000
.zeroVRAM1:
    ld      [hl+], a        ; a=0 (set by ld a,0 at end of loop; first iter uses xor a below)
    dec     bc
    ld      a, b
    or      c
    ld      a, 0
    jr      nz, .zeroVRAM1
    ; Switch back to bank 0
    xor     a
    ld      [rVBK], a

    ; Zero WRAM ($C000-$DFFF)
    ld      hl, $C000
    ld      bc, $2000
    xor     a
.zeroWRAM:
    ld      [hl+], a
    dec     bc
    ld      a, b
    or      c
    ld      a, 0
    jr      nz, .zeroWRAM

    ; Now WRAM is clean — restore GBC flag and init variables
    ld      a, [$FF80]
    ld      [wIsGBC], a
    ld      a, STATE_TITLE
    ld      [wGameState], a
    ld      a, 5
    ld      [wHealth], a

    ; Scroll = 0
    xor     a
    ld      [rSCX], a
    ld      [rSCY], a

    ; Window off-screen initially (push below visible area)
    ld      a, 160
    ld      [rWY], a
    ld      a, 7
    ld      [rWX], a

    ; DMG palette: col0=white col3=black
    ld      a, $E4
    ld      [rBGP], a
    ld      [rOBP0], a
    ld      [rOBP1], a

    ; Copy DMA routine to HRAM
    ld      hl, DMARoutine
    ld      de, $FF81
    ld      bc, DMARoutineEnd - DMARoutine
.copyDMA:
    ld      a, [hl+]
    ld      [de], a
    inc     de
    dec     bc
    ld      a, b
    or      c
    jr      nz, .copyDMA

    ; Load tile + font + sprite data into VRAM (LCD is OFF)
    call    LoadTileData

    ; Setup GBC colour palettes
    call    SetupPalettes

    ; Draw title screen into tilemap (LCD stays OFF inside, turned on at end)
    call    DrawTitleScreen

    ; Seed joypad
    call    ReadJoypad
    call    ReadJoypad

    ; Init audio hardware and start title music
    call    AudioInit
    ld      a, SONG_TITLE
    call    MusicPlay

; ===========================================================================
;  Main Loop
; ===========================================================================
MainLoop:
    call    WaitVBlank
    ; DMA OAM every frame — wOAMBuf is zeroed at boot so Y=0 entries are off-screen
    ld      a, $C1          ; high byte of wOAMBuf ($C100)
    call    $FF81           ; hDMA
    call    ReadJoypad
    call    MusicTick
    ld      a, [wFrame]
    inc     a
    ld      [wFrame], a

    ld      a, [wGameState]
    cp      STATE_TITLE
    jp      z, UpdateTitle
    cp      STATE_INTRO
    jp      z, UpdateIntro
    cp      STATE_PLAY
    jp      z, UpdatePlay
    cp      STATE_DIALOG
    jp      z, UpdateDialog
    cp      STATE_MAP
    jp      z, UpdateMapScreen
    cp      STATE_PATCHED
    jp      z, UpdatePatchedScreen
    cp      STATE_BOSS
    jp      z, UpdateBossScreen
    ; STATE_WIN — freeze
    jr      MainLoop

; ===========================================================================
;  WaitVBlank — two-phase LY poll (fresh edge)
; ===========================================================================
WaitVBlank:
.notVBL:
    ld      a, [rLY]
    cp      144
    jr      nc, .notVBL
.waitVBL:
    ld      a, [rLY]
    cp      144
    jr      c, .waitVBL
    ret

; ===========================================================================
;  LCDOff / LCDOn
; ===========================================================================
LCDOff:
    ld      a, [rLCDC]
    bit     7, a
    ret     z
    call    WaitVBlank
    xor     a
    ld      [rLCDC], a
    ret

; LCDOn — BG + window, NO sprites (safe for title/intro/dialog)
LCDOn:
    ld      a, LCD_TEXT
    ld      [rLCDC], a
    ret

; LCDOnPlay — BG + window + sprites (platformer only)
LCDOnPlay:
    ld      a, LCD_PLAY
    ld      [rLCDC], a
    ret

; ===========================================================================
;  ReadJoypad
;  wJoypad bits: 7=Down 6=Up 5=Left 4=Right 3=Start 2=Select 1=B 0=A
; ===========================================================================
ReadJoypad:
    ld      a, [wJoypad]
    ld      [wJoypadPrev], a
    ld      a, $20
    ld      [rP1], a
    ld      a, [rP1]
    ld      a, [rP1]
    cpl
    and     $0F
    swap    a
    ld      b, a
    ld      a, $10
    ld      [rP1], a
    ld      a, [rP1]
    ld      a, [rP1]
    cpl
    and     $0F
    or      b
    ld      [wJoypad], a
    ld      a, $30
    ld      [rP1], a
    ld      a, [wJoypadPrev]
    cpl
    ld      b, a
    ld      a, [wJoypad]
    and     b
    ld      [wJoypadNew], a
    ret

; ===========================================================================
;  DMA OAM routine — copied to HRAM at $FF81
;  Call with A = high byte of source (e.g. $C1 for $C100)
; ===========================================================================
DMARoutine:
    ld      [rDMA], a
    ld      a, 40
.wait:
    dec     a
    jr      nz, .wait
    ret
DMARoutineEnd:

; ===========================================================================
;  TITLE SCREEN
; ===========================================================================
DrawTitleScreen:
    call    LCDOff
    call    ClearBG
    ld      hl, $9840       ; row 2
    ld      de, StrTitle1
    call    PrintStr
    ld      hl, $9860       ; row 3
    ld      de, StrTitle2
    call    PrintStr
    ld      hl, $98A0       ; row 5
    ld      de, StrTitle3
    call    PrintStr
    ld      hl, $9900       ; row 8
    ld      de, StrTitlePrompt
    call    PrintStr
    call    LCDOn           ; BG + window, no sprites
    ret

UpdateTitle:
    ld      a, [wJoypadNew]
    bit     3, a            ; Start
    jp      z, MainLoop
    ld      a, STATE_INTRO
    ld      [wGameState], a
    xor     a
    ld      [wIntroPage], a
    call    DrawIntroPage
    jp      MainLoop

; ===========================================================================
;  INTRO — 3 pages, A advances
; ===========================================================================
DrawIntroPage:
    call    LCDOff
    call    ClearBG
    ld      a, [wIntroPage]
    cp      0
    jr      z, .page0
    cp      1
    jr      z, .page1
    ; page 2
    ld      hl, $9800
    ld      de, StrI2_0
    call    PrintStr
    ld      hl, $9840
    ld      de, StrI2_1
    call    PrintStr
    ld      hl, $9860
    ld      de, StrI2_2
    call    PrintStr
    ld      hl, $9880
    ld      de, StrI2_3
    call    PrintStr
    ld      hl, $98A0
    ld      de, StrI2_4
    call    PrintStr
    ld      hl, $9900
    ld      de, StrIntroStart
    call    PrintStr
    call    LCDOn
    ret
.page0:
    ld      hl, $9800
    ld      de, StrI0_0
    call    PrintStr
    ld      hl, $9820
    ld      de, StrI0_1
    call    PrintStr
    ld      hl, $9840
    ld      de, StrI0_2
    call    PrintStr
    ld      hl, $9860
    ld      de, StrI0_3
    call    PrintStr
    ld      hl, $9880
    ld      de, StrI0_4
    call    PrintStr
    ld      hl, $9900
    ld      de, StrIntroCont
    call    PrintStr
    call    LCDOn
    ret
.page1:
    ld      hl, $9800
    ld      de, StrI1_0
    call    PrintStr
    ld      hl, $9820
    ld      de, StrI1_1
    call    PrintStr
    ld      hl, $9840
    ld      de, StrI1_2
    call    PrintStr
    ld      hl, $9860
    ld      de, StrI1_3
    call    PrintStr
    ld      hl, $9900
    ld      de, StrIntroCont
    call    PrintStr
    call    LCDOn
    ret

UpdateIntro:
    ld      a, [wJoypadNew]
    bit     0, a            ; A button advances intro
    jp      z, MainLoop
    ld      a, [wIntroPage]
    inc     a
    ld      [wIntroPage], a
    cp      3
    jr      nc, .start
    call    DrawIntroPage
    jp      MainLoop
.start:
    ; After intro, go to world map for level selection
    call    DrawMapScreen
    jp      MainLoop

; ===========================================================================
;  INIT PLATFORMER — now delegates to InitLevel(0)
; ===========================================================================
InitPlay:
    xor     a
    call    InitLevel
    ret

; ===========================================================================
;  LOAD ZONE — copy zone tilemap to VRAM $9800, reset camera
; ===========================================================================
LoadZone:
    call    LCDOff          ; safe — checks bit 7 first, waits for VBlank
    ; Get zone data pointer from per-level zone table (stored in WRAM)
    ld      a, [wZone]
    ld      a, [wLvlZoneTableLo]
    ld      l, a
    ld      a, [wLvlZoneTableHi]
    ld      h, a            ; HL = zone table base
    ld      a, [wZone]
    add     a, a            ; *2 for DW entries
    ld      b, 0
    ld      c, a
    add     hl, bc
    ld      a, [hl+]
    ld      e, a
    ld      a, [hl]
    ld      d, a            ; DE = zone data pointer

    ; Copy zone data (20 cols × 16 rows) into VRAM tilemap (32 cols wide).
    ; Each row: copy 20 tiles from zone data, then advance HL by 12 to skip
    ; the unused right 12 columns of the 32-wide VRAM row.
    ld      hl, $9800
    ld      b, ZONE_ROWS        ; 16 rows
.copyRow:
    ld      c, ZONE_COLS        ; 20 tiles per row
.copyTile:
    ld      a, [de]
    ld      [hl+], a
    inc     de
    dec     c
    jr      nz, .copyTile
    ; Skip the remaining 12 columns in VRAM (32 - 20 = 12)
    ld      a, l
    add     12
    ld      l, a
    jr      nc, .noCarry
    inc     h
.noCarry:
    dec     b
    jr      nz, .copyRow

    ; Place exploit pickup tiles (VRAM write — LCD still OFF)
    call    PlaceExploitTiles

    ; Write HUD to window tilemap $9C00 (VRAM write — LCD still OFF)
    call    UpdateHUD

    ; Reset scroll
    xor     a
    ld      [rSCX], a
    ld      [rSCY], a
    ld      [wCamX], a
    ld      [wCamY], a

    ; Grace period — 60 frames before advisories can hit
    ld      a, 60
    ld      [wSpawnGrace], a

    call    LCDOnPlay       ; turn LCD back on with sprites enabled
    ret

; ===========================================================================
;  PlaceExploitTiles — write T_EXPLOIT tile into tilemap if spawned + in zone
; ===========================================================================
PlaceExploitTiles:
    ld      a, [wExploitSpawned]
    ; Check exploit 0
    bit     0, a
    jr      z, .pet_chk1
    ld      a, [wExp0Zone]
    ld      b, a
    ld      a, [wExp0Col]
    ld      c, a
    ld      a, [wExp0Row]
    ld      d, a
    call    PlaceTileIfZone
.pet_chk1:
    ld      a, [wExploitSpawned]
    bit     1, a
    jr      z, .pet_chk2
    ld      a, [wExp1Zone]
    ld      b, a
    ld      a, [wExp1Col]
    ld      c, a
    ld      a, [wExp1Row]
    ld      d, a
    call    PlaceTileIfZone
.pet_chk2:
    ld      a, [wExploitSpawned]
    bit     2, a
    jr      z, .pet_done
    ld      a, [wExp2Zone]
    ld      b, a
    ld      a, [wExp2Col]
    ld      c, a
    ld      a, [wExp2Row]
    ld      d, a
    call    PlaceTileIfZone
.pet_done:
    ret

; PlaceTileIfZone: B=zone C=col D=row — write T_EXPLOIT if current zone matches
PlaceTileIfZone:
    ld      a, [wZone]
    cp      b
    ret     nz
    ; Compute VRAM address: $9800 + row*32 + col
    ld      a, d            ; row
    ld      h, 0
    ld      l, a
    add     hl, hl          ; *2
    add     hl, hl          ; *4
    add     hl, hl          ; *8
    add     hl, hl          ; *16
    add     hl, hl          ; *32
    ld      a, c            ; + col
    ld      e, a
    ld      d, 0
    add     hl, de
    ld      de, $9800
    add     hl, de
    ld      [hl], T_EXPLOIT
    ret

; ===========================================================================
;  UpdateHUD — write HP / vulns / carry to window tilemap $9C00
; ===========================================================================
UpdateHUD:
    ; HUD occupies window tilemap $9C00, rows 0-1 (WY=128 = 2 rows at bottom)
    ; Row 0: "LN " + zone name (where N = level number 1-5)
    ; Row 1: HP:N  VULNS:N  EXP:N
    ; Print "L" prefix
    ld      hl, $9C00
    ld      [hl], $2C           ; tile for 'L' (ASCII $4C - $20 = $2C)
    inc     hl
    ld      a, [wCurrentLevel]
    inc     a                   ; display 1-based
    add     a, $10              ; digit tile offset
    ld      [hl], a
    inc     hl
    ld      [hl], $00           ; space (ASCII $20 - $20 = 0)
    inc     hl
    ; Now print zone name — use per-level zone name table
    ; zone name table: ZoneNameTable covers level 0 zones (0-5)
    ; LvlNZoneNames tables cover levels 1-4
    ld      a, [wCurrentLevel]
    or      a
    jr      nz, .notLvl0Name
    ; Level 0: use original ZoneNameTable
    ld      a, [wZone]
    ld      de, ZoneNameTable
    add     a, a
    ld      b, 0
    ld      c, a
    ; de + bc = table entry
    ld      h, d
    ld      l, e
    add     hl, bc
    ld      a, [hl+]
    ld      e, a
    ld      a, [hl]
    ld      d, a
    jr      .printName
.notLvl0Name:
    ; Levels 1-4: use LvlNZoneNames
    ld      a, [wZone]
    ld      b, a                ; save zone index
    ld      a, [wCurrentLevel]
    ; build pointer into LvlZoneNamesTable: table of DW pointers
    dec     a                   ; 0-based level index (1→0, 2→1, etc)
    add     a, a                ; *2
    ld      c, a
    ld      a, 0
    ld      b, a
    ld      hl, LvlZoneNamesTable
    add     hl, bc              ; HL = &table_ptr
    ld      a, [hl+]
    ld      e, a
    ld      a, [hl]
    ld      d, a                ; DE = base of that level's zone name DW table
    ld      a, [wZone]
    add     a, a                ; *2 for DW
    ld      b, 0
    ld      c, a
    ld      h, d
    ld      l, e
    add     hl, bc
    ld      a, [hl+]
    ld      e, a
    ld      a, [hl]
    ld      d, a
.printName:
    ; DE = zone name string pointer, HL = $9C03
    ld      hl, $9C03
    call    PrintStrDirect

    ; Row 1 — stats
    ld      hl, $9C20
    ld      de, StrHudHP
    call    PrintStrDirect
    ld      a, [wHealth]
    add     a, $10
    ld      hl, $9C23
    ld      [hl], a
    ld      hl, $9C24
    ld      de, StrHudVulns
    call    PrintStrDirect
    ld      a, [wVulnExploited]
    ; Count bits (max 3)
    ld      b, 0
    bit     0, a
    jr      z, .hv1
    inc     b
.hv1:
    bit     1, a
    jr      z, .hv2
    inc     b
.hv2:
    bit     2, a
    jr      z, .hv3
    inc     b
.hv3:
    ld      a, b
    add     a, $10
    ld      hl, $9C2B
    ld      [hl], a
    ld      hl, $9C2C
    ld      de, StrHudCarry
    call    PrintStrDirect
    ld      a, [wExploitHeld]
    add     a, $10
    ld      hl, $9C31
    ld      [hl], a
    ret

; ===========================================================================
;  MAIN PLAY UPDATE
; ===========================================================================
UpdatePlay:
    ; --- Check advisory hit from previous frame ---
    ld      a, [wAdvHit]
    or      a
    jr      z, .advHitDone
    xor     a
    ld      [wAdvHit], a
    call    DrawPatchedScreen
    jp      MainLoop
.advHitDone:
    ; --- Tick spawn grace timer ---
    ld      a, [wSpawnGrace]
    or      a
    jr      z, .graceDone
    dec     a
    ld      [wSpawnGrace], a
.graceDone:
    ; --- Increment timer (16-bit) ---
    ld      a, [wTimerLo]
    inc     a
    ld      [wTimerLo], a
    jr      nz, .timerDone
    ld      a, [wTimerHi]
    inc     a
    ld      [wTimerHi], a
.timerDone:
    ; --- Input → physics ---
    call    UpdatePlayerInput

    ; --- Apply physics ---
    call    UpdatePlayerPhysics

    ; --- Update scan animation ---
    call    UpdateScan

    ; --- Check pickup ---
    call    CheckPickup

    ; --- Update advisories ---
    call    UpdateAdvisories

    ; --- Check advisory collision ---
    call    CheckAdvisoryCollision

    ; --- Update OAM shadow ---
    call    UpdateOAM

    jp      MainLoop

; ===========================================================================
;  UpdatePlayerInput — apply joystick to velocity
; ===========================================================================
UpdatePlayerInput:
    ld      a, [wJoypad]

    ; Left
    bit     5, a
    jr      z, .chkRight
    ld      a, [wPVX]
    sub     RUN_VX
    ; Clamp to -RUN_VX (unsigned: >= 256-RUN_VX)
    cp      256 - RUN_VX - 1
    jr      c, .setVX_L
    ld      a, 256 - RUN_VX
.setVX_L:
    ld      [wPVX], a
    ld      a, 1
    ld      [wPFacing], a
    jr      .doneH
.chkRight:
    bit     4, a
    jr      z, .noHoriz
    ld      a, [wPVX]
    add     RUN_VX
    cp      RUN_VX + 1
    jr      c, .setVX_R
    ld      a, RUN_VX
.setVX_R:
    ld      [wPVX], a
    xor     a
    ld      [wPFacing], a
    jr      .doneH
.noHoriz:
    ; Friction
    ld      a, [wPVX]
    or      a
    jr      z, .doneH
    ; Check sign: if >= 128, negative
    cp      128
    jr      nc, .negFric
    ; Positive
    sub     FRICTION
    jr      nc, .setFric
    xor     a
    jr      .setFric
.negFric:
    add     FRICTION
    jr      c, .setFric     ; wrapped past 255 → zero
    cp      128
    jr      c, .zeroFric    ; if now positive, clamp to 0
    jr      .setFric
.zeroFric:
    xor     a
.setFric:
    ld      [wPVX], a
.doneH:
    ; Jump — A button
    ld      a, [wJoypadNew]
    bit     0, a            ; A
    jr      z, .noJump
    ld      a, [wPOnGround]
    or      a
    jr      z, .noJump
    ld      a, JUMP_VY
    ld      [wPVY], a
    xor     a
    ld      [wPOnGround], a
.noJump:
    ; B button — scan or exploit-use depending on context, grounded only
    ld      a, [wPOnGround]
    or      a
    jr      z, .done        ; airborne — skip both
    ld      a, [wJoypadNew]
    bit     1, a            ; B
    jr      z, .done
    ; If holding an exploit, try to use it; otherwise try to scan
    ld      a, [wExploitHeld]
    or      a
    jr      nz, .doUse
    call    TryScan
    jr      .done
.doUse:
    call    TryExploit
.done:
    ret

; ===========================================================================
;  UpdatePlayerPhysics — gravity, integrate, collide
; ===========================================================================
UpdatePlayerPhysics:
    ; Gravity — add each frame; clamp only positive (downward) velocity to MAX_FALL
    ld      a, [wPVY]
    add     GRAVITY
    ; Only clamp if result is positive (< 128) AND exceeds MAX_FALL
    cp      128
    jr      nc, .setVY      ; negative (upward) — no clamp needed
    cp      MAX_FALL + 1
    jr      c, .setVY       ; positive but within limit
    ld      a, MAX_FALL     ; cap downward speed
.setVY:
    ld      [wPVY], a

    ; Integrate Y — clamp step to 8px max to prevent skipping through a tile
    ld      a, [wPVY]
    cp      128             ; negative (upward)?
    jr      nc, .intYNeg
    ; Positive (downward) — clamp to 8px max per frame
    cp      9
    jr      c, .intYStep
    ld      a, 8
    jr      .intYStep
.intYNeg:
    ; Negative (upward) — clamp magnitude: if < 248 (i.e. faster than -8), cap at 248
    cp      248
    jr      nc, .intYStep
    ld      a, 248
.intYStep:
    ld      b, a
    ld      a, [wPY]
    add     b
.doColY:
    ; Clamp Y to screen bottom — just stop downward movement, tile collision sets OnGround
    cp      120
    jr      c, .yOK
    ld      a, 120
    ld      b, a
    xor     a
    ld      [wPVY], a   ; zero downward velocity
    ld      a, b        ; restore clamped Y
.yOK:
    ; Check ceiling — only clamp if NOT in the vertical passage gap (X 64-87)
    cp      8
    jr      nc, .yFloor
    ; wPY < 8 — check if in passage gap
    push    af
    ld      a, [wPX]
    cp      64
    jr      c, .hardCeiling     ; left of gap — hard ceiling
    cp      88
    jr      nc, .hardCeiling    ; right of gap — hard ceiling
    ; In passage gap — allow upward exit, don't clamp
    pop     af
    jr      .yFloor
.hardCeiling:
    pop     af
    xor     a
    ld      [wPVY], a           ; stop upward
    ld      a, 8
.yFloor:
    ; Tile collision Y — check feet tile (Y+16, X+4)
    ld      [wPY], a
    call    CheckTileCollisionY

    ; Integrate X
    ld      a, [wPX]
    ld      b, a
    ld      a, [wPVX]
    add     b
    ; Clamp X 0-152
    cp      153
    jr      c, .xOK
    xor     a
    ld      [wPVX], a
    ld      a, 152          ; cap at right edge, NOT 0
    jr      .xPos
.xOK:
    or      a
    jr      nz, .xPos
    xor     a
    ld      [wPVX], a
.xPos:
    ld      [wPX], a
    call    CheckTileCollisionX
    call    CheckZoneTransition
    ret

; ===========================================================================
;  CheckTileCollisionY
;  Checks tile at player feet (wPY+16, wPX+4).
;  If solid: snap player on top, zero VY, set OnGround.
; ===========================================================================
CheckTileCollisionY:
    ; Feet pixel = wPY + 16
    ld      a, [wPY]
    add     16
    ; Tile row = Y / 8
    srl     a
    srl     a
    srl     a
    ld      d, a            ; D = tile row
    ; Foot X mid = wPX + 4
    ld      a, [wPX]
    add     4
    srl     a
    srl     a
    srl     a
    ld      e, a            ; E = tile col
    call    GetTile
    cp      T_VOID
    jr      z, .noFloor
    cp      T_BG_DOT
    jr      z, .noFloor
    cp      T_BG_HLINE
    jr      z, .noFloor
    cp      T_BG_VLINE
    jr      z, .noFloor
    cp      T_VULN_A
    jr      z, .noFloor
    cp      T_VULN_B
    jr      z, .noFloor
    cp      T_VULN_SCAN
    jr      z, .noFloor
    cp      T_VULN_EXP
    jr      z, .noFloor
    cp      T_EXPLOIT
    jr      z, .noFloor
    ; Solid — snap
    ld      a, d
    sla     a
    sla     a
    sla     a               ; row * 8 = top of that tile
    sub     16              ; player Y = tile_top - 16
    ld      [wPY], a
    xor     a
    ld      [wPVY], a
    ld      a, 1
    ld      [wPOnGround], a
    ret
.noFloor:
    ; Not on ground — if was on ground last frame, clear it
    ; (simple: if VY > 0 we're falling, clear OnGround)
    ld      a, [wPVY]
    or      a
    jr      z, .keepGround
    cp      128             ; negative velocity = going up = not on ground
    jr      nc, .keepGround
    ; positive and non-zero = falling
    xor     a
    ld      [wPOnGround], a
.keepGround:
    ret

; ===========================================================================
;  CheckTileCollisionX
;  Checks tile to the left/right of player depending on velocity direction.
;  Simple: check tile at (wPX, wPY+8) and (wPX+8, wPY+8).
; ===========================================================================
CheckTileCollisionX:
    ld      a, [wPVX]
    or      a
    ret     z
    cp      128
    jr      nc, .checkLeft
    ; Moving right — check right edge tile (wPX+8, wPY+8)
    ld      a, [wPX]
    add     8
    srl     a
    srl     a
    srl     a
    ld      e, a
    ld      a, [wPY]
    add     8
    srl     a
    srl     a
    srl     a
    ld      d, a
    call    GetTile
    call    IsSolid
    ret     z
    ; Hit wall — snap and zero VX
    ld      a, e
    sla     a
    sla     a
    sla     a
    sub     8
    ld      [wPX], a
    xor     a
    ld      [wPVX], a
    ret
.checkLeft:
    ; Moving left — check left edge (wPX-1, wPY+8)
    ld      a, [wPX]
    or      a
    ret     z
    dec     a
    srl     a
    srl     a
    srl     a
    ld      e, a
    ld      a, [wPY]
    add     8
    srl     a
    srl     a
    srl     a
    ld      d, a
    call    GetTile
    call    IsSolid
    ret     z
    ; Snap right of wall tile
    ld      a, e
    inc     a
    sla     a
    sla     a
    sla     a
    ld      [wPX], a
    xor     a
    ld      [wPVX], a
    ret

; ===========================================================================
;  GetTile — D=row E=col, returns tile ID in A
; ===========================================================================
GetTile:
    ; address = $9800 + row*32 + col  — preserves D (row) and E (col)
    ld      a, d
    ld      h, 0
    ld      l, a
    add     hl, hl
    add     hl, hl
    add     hl, hl
    add     hl, hl
    add     hl, hl          ; HL = row * 32
    ld      a, e
    ld      b, 0
    ld      c, a
    add     hl, bc          ; HL = row*32 + col
    ld      bc, $9800
    add     hl, bc          ; HL = $9800 + row*32 + col  (DE preserved)
    ld      a, [hl]
    ret

; ===========================================================================
;  IsSolid — A = tile ID.
;  Callers: call IsSolid / ret z  → skip wall response if NOT solid
;  Returns Z=1 (passable), NZ (solid, blocks player).
;  Solid for X-collision: T_PLAT_MID $61, T_PLAT_L $62, T_PLAT_R $63, T_WALL $64
; ===========================================================================
IsSolid:
    cp      T_PLAT_MID
    jr      z, .solid
    cp      T_PLAT_L
    jr      z, .solid
    cp      T_PLAT_R
    jr      z, .solid
    cp      T_WALL
    jr      z, .solid
    ; Not solid — set Z=1
    cp      a               ; A==A, always sets Z=1
    ret
.solid:
    ; Solid — set NZ
    or      1               ; A |= 1, clears Z
    ret

; ===========================================================================
;  CheckZoneTransition — if player walks off edge, load adjacent zone
; ===========================================================================
CheckZoneTransition:
    ld      a, [wPX]
    ; Right edge (X >= 152)
    cp      152
    jr      c, .chkLeft2
    call    TransitionRight
    ret
.chkLeft2:
    or      a
    jr      nz, .chkTop
    call    TransitionLeft
    ret
.chkTop:
    ld      a, [wPY]
    cp      128             ; if >= 128 it's negative (moving up past 0) — also trigger
    jr      c, .chkTopPos
    ; Negative wPY — player jumped past Y=0, treat as top exit
    jr      .chkTopX
.chkTopPos:
    cp      8               ; positive but <= 8 — near top edge
    jr      nc, .chkBottom
.chkTopX:
    ; Only transition if player X is in the passage gap (cols 8-10 = X 64-87)
    ld      a, [wPX]
    cp      64
    jr      c, .chkBottom
    cp      88
    jr      nc, .chkBottom
    call    TransitionUp
    ret
.chkBottom:
    ld      a, [wPY]    ; reload wPY — A may contain wPX from top-exit path
    cp      112
    jr      c, .done
    ; Only transition if player X is in the passage gap (cols 8-10 = X 64-87)
    ld      a, [wPX]
    cp      64
    jr      c, .done    ; too far left
    cp      88
    jr      nc, .done   ; too far right
    call    TransitionDown
.done:
    ret

; Zone adjacency table: [right, left, down, up] zone indices, $FF=none
; Zone 0: right=1, left=FF, down=2, up=FF
; Zone 1: right=4, left=0,  down=3, up=FF
; Zone 2: right=FF,left=FF, down=5, up=0
; Zone 3: right=FF,left=FF, down=FF,up=1
; Zone 4: right=FF,left=1,  down=FF,up=FF
; Zone 5: right=FF,left=FF, down=FF,up=2
ZoneAdjTable:
    DB 1,$FF,2,$FF   ; zone 0
    DB 4,0,3,$FF     ; zone 1
    DB $FF,$FF,5,0   ; zone 2
    DB $FF,$FF,$FF,1 ; zone 3
    DB $FF,1,$FF,$FF ; zone 4
    DB $FF,$FF,$FF,2 ; zone 5

; GetAdjHL — loads per-level adj table into HL, offsets by wZone*4 + D
; D = direction offset (0=right, 1=left, 2=down, 3=up)
; Returns target zone in A; returns Z=1 if $FF
GetAdjHL:
    ld      a, [wLvlAdjTableLo]
    ld      l, a
    ld      a, [wLvlAdjTableHi]
    ld      h, a            ; HL = adj table base
    ld      a, [wZone]
    add     a, a
    add     a, a            ; zone * 4
    ld      b, 0
    ld      c, a
    add     hl, bc
    ld      a, d            ; direction offset
    ld      b, 0
    ld      c, a
    add     hl, bc
    ld      a, [hl]
    ret

TransitionRight:
    ld      d, 0            ; right = offset 0
    call    GetAdjHL
    cp      $FF
    ret     z               ; no zone to right
    ld      [wZone], a
    ld      a, 20           ; spawn just inside left opening (col 2+)
    ld      [wPX], a
    ld      a, 72           ; spawn above floor
    ld      [wPY], a
    xor     a
    ld      [wPVX], a
    ld      [wPVY], a
    call    LoadZone
    ret

TransitionLeft:
    ld      d, 1            ; left = offset 1
    call    GetAdjHL
    cp      $FF
    ret     z
    ld      [wZone], a
    ld      a, 132          ; spawn just inside right opening (col 16)
    ld      [wPX], a
    ld      a, 72
    ld      [wPY], a
    xor     a
    ld      [wPVX], a
    ld      [wPVY], a
    call    LoadZone
    ret

TransitionDown:
    ld      d, 2            ; down = offset 2
    call    GetAdjHL
    cp      $FF
    ret     z
    ld      [wZone], a
    ld      a, 16           ; spawn below top wall (row 2)
    ld      [wPY], a
    ld      a, 48           ; spawn left of gap (col 6 = X 48)
    ld      [wPX], a
    xor     a
    ld      [wPVX], a
    ld      [wPVY], a
    call    LoadZone
    ret

TransitionUp:
    ld      d, 3            ; up = offset 3
    call    GetAdjHL
    cp      $FF
    ret     z
    ld      [wZone], a
    ld      a, 56           ; spawn above floor, row 7 = Y 56
    ld      [wPY], a
    ld      a, 48           ; spawn left of gap (col 6 = X 48)
    ld      [wPX], a
    xor     a
    ld      [wPVY], a
    ld      [wPVX], a
    call    LoadZone
    ret

; ===========================================================================
;  TryScan — A button near a vuln node triggers scan
;  Checks distance to each vuln in current zone
; ===========================================================================
; TryScanVuln — generic check for one vuln
; B=vuln index (0-2), C=bit mask (1/2/4)
; Reads wVuln0Zone/Row/Col (or 1 or 2) from WRAM
; Triggers BeginScan(B) if player in range and not yet scanned
; Trashes A, HL
TryScanVuln:
    ; Check zone matches
    ld      a, b
    or      a
    jr      nz, .tv_chk1
    ld      a, [wVuln0Zone]
    jr      .tv_gotzone
.tv_chk1:
    cp      1
    jr      nz, .tv_chk2
    ld      a, [wVuln1Zone]
    jr      .tv_gotzone
.tv_chk2:
    ld      a, [wVuln2Zone]
.tv_gotzone:
    ld      d, a            ; D = vuln zone
    ld      a, [wZone]
    cp      d
    ret     nz              ; not in this zone
    ; Check if already scanned
    ld      a, [wVulnScanned]
    and     c
    ret     nz              ; already scanned
    ; Get vuln pixel X = col * 8
    ld      a, b
    or      a
    jr      nz, .tv_gcol1
    ld      a, [wVuln0Col]
    jr      .tv_gotcol
.tv_gcol1:
    cp      1
    jr      nz, .tv_gcol2
    ld      a, [wVuln1Col]
    jr      .tv_gotcol
.tv_gcol2:
    ld      a, [wVuln2Col]
.tv_gotcol:
    add     a, a
    add     a, a
    add     a, a            ; col * 8 = pixel X
    ld      d, a            ; D = vuln pixel X
    ld      a, [wPX]
    sub     d
    jr      nc, .tv_absok
    cpl
    inc     a
.tv_absok:
    cp      20
    ret     nc              ; too far
    ld      a, b
    call    BeginScan
    ret

TryScan:
    ld      a, [wScanActive]
    or      a
    ret     nz              ; scan already running
    ; In boss fight, fire scan only if player is on the same row as the boss
    ld      a, [wGameState]
    cp      STATE_BOSS
    jr      nz, .ts_normal
    ; Check vertical proximity: abs(playerY - BOSS_Y) < 24
    ld      a, [wPY]
    sub     BOSS_Y
    jr      nc, .bs_vok
    cpl
    inc     a
.bs_vok:
    cp      24
    ret     nc              ; too far vertically — no scan
    xor     a               ; vuln index 0 — reused as boss scan
    call    BeginScan
    ret
.ts_normal:
    ; Check vuln 0
    ld      b, 0
    ld      c, 1
    call    TryScanVuln
    ; Check vuln 1
    ld      b, 1
    ld      c, 2
    call    TryScanVuln
    ; Check vuln 2 only if level has 3 vulns
    ld      a, [wNumVulns]
    cp      3
    ret     nz
    ld      b, 2
    ld      c, 4
    call    TryScanVuln
    ret

; BeginScan: A = vuln index
BeginScan:
    ld      [wScanVulnIdx], a
    ld      a, SCAN_FRAMES
    ld      [wScanTimer], a
    ld      a, 1
    ld      [wScanActive], a
    ld      a, [wPX]
    ld      [wScanX], a
    xor     a
    ld      [wScanBeamLen], a
    ret

; ===========================================================================
;  UpdateScan — advance scan beam animation
; ===========================================================================
UpdateScan:
    ld      a, [wScanActive]
    or      a
    ret     z

    ld      a, [wScanTimer]
    dec     a
    ld      [wScanTimer], a
    jr      nz, .advance

    ; Scan complete — erase beam tiles before doing anything else
    call    ClearScanBeam
    xor     a
    ld      [wScanActive], a
    xor     a
    ld      [wScanBeamLen], a

    ; If boss fight, damage boss instead of normal vuln flow
    ld      a, [wGameState]
    cp      STATE_BOSS
    jr      nz, .notBoss
    call    BossTakeScanHit
    ret
.notBoss:

    ; Mark vuln as scanned
    ld      a, [wScanVulnIdx]
    ld      b, a
    ld      a, [wVulnScanned]
    ; Set bit b
    ld      c, 1
    or      a               ; b=0?
    ld      a, b
    or      a
    jr      z, .setbit
    ld      a, b
    cp      1
    jr      z, .bit1
    ld      c, 4            ; bit 2
    jr      .setbit
.bit1:
    ld      c, 2
.setbit:
    ld      a, [wVulnScanned]
    or      c
    ld      [wVulnScanned], a

    ; Spawn exploit
    ld      a, [wScanVulnIdx]
    call    SpawnExploit

    ; Show dialog
    call    ShowScanDialog
    ret

.advance:
    ; Grow beam
    ld      a, [wScanBeamLen]
    inc     a
    cp      11              ; max 10 tiles wide
    jr      nc, .noGrow
    ld      [wScanBeamLen], a
.noGrow:
    ; Write beam tiles to tilemap
    call    DrawScanBeam
    ret

; DrawScanBeam — write T_BEAM_FULL tiles from player X rightward
DrawScanBeam:
    ld      a, [wPX]
    srl     a
    srl     a
    srl     a               ; start tile col
    ld      e, a
    ld      a, [wPY]
    add     8
    srl     a
    srl     a
    srl     a               ; tile row
    ld      d, a
    ld      a, [wScanBeamLen]
    ld      b, a
    ; Compute VRAM address
.loop:
    push    bc
    push    de
    call    GetTileAddr     ; HL = VRAM addr for D=row, E=col
    ld      [hl], T_BEAM_FULL
    pop     de
    pop     bc
    inc     e
    dec     b
    jr      nz, .loop
    ret

; ClearScanBeam — overwrite beam tiles with T_VOID (same coords as DrawScanBeam)
ClearScanBeam:
    ld      a, [wPX]
    srl     a
    srl     a
    srl     a               ; start tile col
    ld      e, a
    ld      a, [wPY]
    add     8
    srl     a
    srl     a
    srl     a               ; tile row
    ld      d, a
    ld      b, 10           ; max beam length (SCAN_RANGE/8)
.clrloop:
    push    bc
    push    de
    call    GetTileAddr
    ld      [hl], T_VOID
    pop     de
    pop     bc
    inc     e
    dec     b
    jr      nz, .clrloop
    ret

GetTileAddr:
    ld      a, d
    ld      h, 0
    ld      l, a
    add     hl, hl
    add     hl, hl
    add     hl, hl
    add     hl, hl
    add     hl, hl
    ld      a, e
    ld      b, 0
    ld      c, a
    add     hl, bc
    ld      bc, $9800
    add     hl, bc
    ret

; ===========================================================================
;  SpawnExploit: A = vuln index, set bit in wExploitSpawned
; ===========================================================================
SpawnExploit:
    or      a
    jr      z, .exp0
    cp      1
    jr      z, .exp1
    ; exp 2
    ld      a, [wExploitSpawned]
    set     2, a
    ld      [wExploitSpawned], a
    ret
.exp0:
    ld      a, [wExploitSpawned]
    set     0, a
    ld      [wExploitSpawned], a
    ret
.exp1:
    ld      a, [wExploitSpawned]
    set     1, a
    ld      [wExploitSpawned], a
    ret

; ===========================================================================
;  ShowScanDialog — set STATE_DIALOG, write lines, re-enter
; ===========================================================================
ShowScanDialog:
    ld      a, STATE_DIALOG
    ld      [wGameState], a
    call    LCDOff
    call    ClearBG
    ; Line 0: "> VULN DETECTED!"
    ld      hl, $9800
    ld      de, StrScanHit
    call    PrintStr
    ; Line 1: CVE name — index = level * maxVulns + vulnIdx
    ; Use LvlVulnNameTable (DW array, 3 entries per level × 5 levels = 15 DW)
    call    GetVulnStringPair   ; returns DE=name, HL=desc (uses wCurrentLevel+wScanVulnIdx)
    push    hl
    ld      hl, $9820
    call    PrintStr
    pop     de
    ld      hl, $9840
    call    PrintStr
    ; Line 3: exploit tool name
    call    GetExpString        ; returns DE=exploit name string
    ld      hl, $9860
    call    PrintStr
    ld      hl, $9900
    ld      de, StrDismiss
    call    PrintStr
    call    LCDOn
    ret

; GetVulnStringPair — returns DE=name ptr, HL=desc ptr
; Uses wCurrentLevel * 3 + wScanVulnIdx as table index
; Caller must preserve desc ptr across PrintStr (DE clobbered)
GetVulnStringPair:
    ld      a, [wCurrentLevel]
    ; index = level * 3 + vulnIdx (max 3 vulns/level)
    add     a, a            ; level * 2
    ld      b, a
    ld      a, [wCurrentLevel]
    add     b               ; level * 3
    ld      b, a
    ld      a, [wScanVulnIdx]
    add     b               ; level*3 + vulnIdx
    ; Each entry is 4 bytes (2 DW: name, desc)
    add     a, a            ; *2
    add     a, a            ; *4
    ld      hl, LvlVulnNameTable
    ld      b, 0
    ld      c, a
    add     hl, bc
    ld      a, [hl+]
    ld      e, a
    ld      a, [hl+]
    ld      d, a            ; DE = name ptr
    ; Now read desc ptr into BC temporarily, then move to HL
    ld      a, [hl+]
    ld      c, a            ; desc lo
    ld      a, [hl]
    ld      b, a            ; desc hi
    ld      h, b
    ld      l, c            ; HL = desc ptr
    ret

; GetExpString — returns DE = exploit name for current level+vulnIdx
GetExpString:
    ld      a, [wCurrentLevel]
    add     a, a
    ld      b, a
    ld      a, [wCurrentLevel]
    add     b
    ld      b, a
    ld      a, [wScanVulnIdx]
    add     b
    add     a, a            ; *2 (DW table)
    ld      hl, LvlExpNameTable
    ld      b, 0
    ld      c, a
    add     hl, bc
    ld      a, [hl+]
    ld      e, a
    ld      a, [hl]
    ld      d, a
    ret

; ===========================================================================
;  TryExploit — B button at a scanned vuln with matching exploit held
; ===========================================================================
TryExploit:
    ld      a, [wExploitHeld]
    or      a
    ret     z               ; not holding anything

    ; Exploit IDs: 1=vuln0, 2=vuln1, 3=vuln2
    ld      b, a            ; b = exploit held (1-3)
    dec     b               ; b = vuln index (0-2)

    ; Check in correct zone via WRAM vuln zone table
    ld      a, b
    or      a
    jr      nz, .te_chk1
    ld      a, [wVuln0Zone]
    jr      .te_gotzone
.te_chk1:
    cp      1
    jr      nz, .te_chk2
    ld      a, [wVuln1Zone]
    jr      .te_gotzone
.te_chk2:
    ld      a, [wVuln2Zone]
.te_gotzone:
    ld      d, a
    ld      a, [wZone]
    cp      d
    ret     nz              ; wrong zone

    ; Must be scanned first (bit mask = 1 << vuln_idx)
    ld      a, b
    or      a
    jr      nz, .te_bit1
    ld      c, 1
    jr      .te_chkscanned
.te_bit1:
    cp      1
    jr      nz, .te_bit2
    ld      c, 2
    jr      .te_chkscanned
.te_bit2:
    ld      c, 4
.te_chkscanned:
    ld      a, [wVulnScanned]
    and     c
    ret     z               ; not scanned

    ; Proximity check: vuln pixel X = col * 8
    ld      a, b
    or      a
    jr      nz, .te_px1
    ld      a, [wVuln0Col]
    jr      .te_gotpx
.te_px1:
    cp      1
    jr      nz, .te_px2
    ld      a, [wVuln1Col]
    jr      .te_gotpx
.te_px2:
    ld      a, [wVuln2Col]
.te_gotpx:
    add     a, a
    add     a, a
    add     a, a            ; col * 8 = pixel X
    ld      d, a
    ld      a, [wPX]
    sub     d
    jr      nc, .te_absok
    cpl
    inc     a
.te_absok:
    cp      20
    ret     nc

    ; Mark exploited
    ld      a, b
    or      a
    jr      nz, .te_set1
    ld      a, [wVulnExploited]
    set     0, a
    ld      [wVulnExploited], a
    jr      .te_afterset
.te_set1:
    cp      1
    jr      nz, .te_set2
    ld      a, [wVulnExploited]
    set     1, a
    ld      [wVulnExploited], a
    jr      .te_afterset
.te_set2:
    ld      a, [wVulnExploited]
    set     2, a
    ld      [wVulnExploited], a
.te_afterset:
    ; Consume exploit
    xor     a
    ld      [wExploitHeld], a

    ; Update vuln tile in map
    ld      a, b
    call    SetVulnExploitedTile

    ; Check win condition: all numVulns bits set
    ld      a, [wNumVulns]
    cp      3
    jr      z, .te_need3
    ; 2 vulns: need bits 0 and 1 set
    ld      a, [wVulnExploited]
    and     %00000011
    cp      %00000011
    jr      z, .te_win
    call    ShowExploitDialog
    ret
.te_need3:
    ld      a, [wVulnExploited]
    cp      %00000111
    jr      z, .te_win
    call    ShowExploitDialog
    ret
.te_win:
    call    DrawWinScreen
    ret

SetVulnExploitedTile:
    ; A = vuln index (0-2), write T_VULN_EXP to correct tile using WRAM row/col
    ld      b, a
    or      a
    jr      nz, .svt1
    ld      a, [wVuln0Row]
    ld      d, a
    ld      a, [wVuln0Col]
    ld      e, a
    jr      .svt_write
.svt1:
    cp      1
    jr      nz, .svt2
    ld      a, [wVuln1Row]
    ld      d, a
    ld      a, [wVuln1Col]
    ld      e, a
    jr      .svt_write
.svt2:
    ld      a, [wVuln2Row]
    ld      d, a
    ld      a, [wVuln2Col]
    ld      e, a
.svt_write:
    call    GetTileAddr
    ld      [hl], T_VULN_EXP
    ret

ShowExploitDialog:
    ld      a, STATE_DIALOG
    ld      [wGameState], a
    call    LCDOff
    call    ClearBG
    ld      hl, $9820
    ld      de, StrExploited
    call    PrintStr
    ; Show exploit used string from per-level table
    call    GetExpString        ; DE = exploit name
    ld      hl, $9840
    call    PrintStr
    ld      hl, $9900
    ld      de, StrDismiss
    call    PrintStr
    call    LCDOn
    ret

; ===========================================================================
;  CheckPickup — auto-collect exploit if player overlaps its tile
; ===========================================================================
CheckPickup:
    ld      a, [wExploitHeld]
    or      a
    ret     nz              ; already holding one

    ; Compute player tile position
    ld      a, [wPX]
    add     4
    srl     a
    srl     a
    srl     a
    ld      e, a            ; tile col
    ld      a, [wPY]
    add     8
    srl     a
    srl     a
    srl     a
    ld      d, a            ; tile row
    call    GetTile
    cp      T_EXPLOIT
    ret     nz

    ; Which exploit is this? Cross-ref zone + position vs WRAM
    ld      a, [wZone]
    ld      b, a
    ; Check exploit 0
    ld      a, [wExp0Zone]
    cp      b
    jr      nz, .cp_chkE1
    ld      a, [wExp0Row]
    cp      d
    jr      nz, .cp_chkE1
    ld      a, [wExp0Col]
    cp      e
    jr      nz, .cp_chkE1
    ld      a, 1
    jr      .pickup
.cp_chkE1:
    ld      a, [wExp1Zone]
    cp      b
    jr      nz, .cp_chkE2
    ld      a, [wExp1Row]
    cp      d
    jr      nz, .cp_chkE2
    ld      a, [wExp1Col]
    cp      e
    jr      nz, .cp_chkE2
    ld      a, 2
    jr      .pickup
.cp_chkE2:
    ; Only check exploit2 if level has 3 vulns
    ld      a, [wNumVulns]
    cp      3
    jr      nz, .noPickup
    ld      a, [wExp2Zone]
    cp      b
    jr      nz, .noPickup
    ld      a, [wExp2Row]
    cp      d
    jr      nz, .noPickup
    ld      a, [wExp2Col]
    cp      e
    jr      nz, .noPickup
    ld      a, 3
.pickup:
    ld      [wExploitHeld], a
    ; Clear the tile
    push    de
    call    GetTileAddr
    ld      [hl], T_VOID
    pop     de
    ; Show pickup dialog
    call    ShowPickupDialog
    ret
.noPickup:
    ret

ShowPickupDialog:
    ld      a, STATE_DIALOG
    ld      [wGameState], a
    call    LCDOff
    call    ClearBG
    ld      hl, $9840
    ld      de, StrPickedUp
    call    PrintStr
    ld      hl, $9900
    ld      de, StrDismiss
    call    PrintStr
    call    LCDOn
    ret

; ===========================================================================
;  UpdateDialog — A dismisses, restores STATE_PLAY + zone
; ===========================================================================
UpdateDialog:
    ld      a, [wJoypadNew]
    bit     0, a            ; A dismisses dialog
    jp      z, MainLoop
    ld      a, STATE_PLAY
    ld      [wGameState], a
    call    LoadZone
    jp      MainLoop

; ===========================================================================
;  DrawWinScreen — mark level complete, go to map (or final win if all done)
; ===========================================================================
DrawWinScreen:
    ; Set bit (1 << wCurrentLevel) in wLevelComplete
    ld      a, [wCurrentLevel]
    ld      hl, LvlBitTable
    ld      b, 0
    ld      c, a
    add     hl, bc
    ld      a, [hl]         ; bit mask for this level
    ld      b, a
    ld      a, [wLevelComplete]
    or      b
    ld      [wLevelComplete], a

    ; Check if all 5 levels complete ($1F = bits 0-4 set) — go to boss
    cp      $1F
    jp      z, DrawBossScreen

    ; Not all done — go back to map
    call    DrawMapScreen
    ret

; Bit mask table: LvlBitTable[N] = (1 << N)
LvlBitTable:
    DB $01, $02, $04, $08, $10

; DrawFinalWin — shown when boss is defeated
DrawFinalWin:
    ld      a, STATE_WIN
    ld      [wGameState], a
    ; Silence music on win screen
    ld      a, SONG_OFF
    call    MusicPlay
    call    LCDOff
    call    ClearBG
    ld      hl, $9840
    ld      de, StrWin1
    call    PrintStr
    ld      hl, $9880
    ld      de, StrWin2
    call    PrintStr
    ld      hl, $98A0
    ld      de, StrWin3
    call    PrintStr
    ld      hl, $98C0
    ld      de, StrWin4
    call    PrintStr
    ld      hl, $9900
    ld      de, StrWin5
    call    PrintStr
    call    LCDOn
    ret

; ===========================================================================
;  InitLevel — A = level index (0-4)
;  Loads level data from LevelTable into WRAM, resets progress, calls InitPlay
; ===========================================================================
InitLevel:
    ld      [wCurrentLevel], a

    ; Get pointer to LevelNData: LevelTable[A*2]
    add     a, a            ; *2
    ld      hl, LevelTable
    ld      b, 0
    ld      c, a
    add     hl, bc
    ld      a, [hl+]
    ld      e, a
    ld      a, [hl]
    ld      d, a            ; DE = LevelNData ptr

    ; Read numZones (byte 0)
    ld      a, [de]
    ld      [wNumZones], a
    inc     de

    ; Read numVulns (byte 1)
    ld      a, [de]
    ld      [wNumVulns], a
    inc     de

    ; Read ZoneTablePtr (word 2-3) lo-hi
    ld      a, [de]
    ld      [wLvlZoneTableLo], a
    inc     de
    ld      a, [de]
    ld      [wLvlZoneTableHi], a
    inc     de

    ; Read AdjTablePtr (word 4-5) lo-hi
    ld      a, [de]
    ld      [wLvlAdjTableLo], a
    inc     de
    ld      a, [de]
    ld      [wLvlAdjTableHi], a
    inc     de

    ; Read vuln entries (3 bytes each × numVulns)
    ld      a, [wNumVulns]
    ld      b, a            ; B = num vulns to read

    ; Vuln 0 always present
    ld      a, [de]
    ld      [wVuln0Zone], a
    inc     de
    ld      a, [de]
    ld      [wVuln0Row], a
    inc     de
    ld      a, [de]
    ld      [wVuln0Col], a
    inc     de
    dec     b
    jr      z, .il_novuln12

    ; Vuln 1
    ld      a, [de]
    ld      [wVuln1Zone], a
    inc     de
    ld      a, [de]
    ld      [wVuln1Row], a
    inc     de
    ld      a, [de]
    ld      [wVuln1Col], a
    inc     de
    dec     b
    jr      z, .il_novuln2

    ; Vuln 2 (only level 0)
    ld      a, [de]
    ld      [wVuln2Zone], a
    inc     de
    ld      a, [de]
    ld      [wVuln2Row], a
    inc     de
    ld      a, [de]
    ld      [wVuln2Col], a
    inc     de
    jr      .il_readexploits

.il_novuln12:
    ; Zero vuln1 and vuln2 positions (won't be used)
    xor     a
    ld      [wVuln1Zone], a
    ld      [wVuln1Row], a
    ld      [wVuln1Col], a
    jr      .il_novuln2plus

.il_novuln2:
.il_novuln2plus:
    xor     a
    ld      [wVuln2Zone], a
    ld      [wVuln2Row], a
    ld      [wVuln2Col], a

.il_readexploits:
    ; Read exploit entries (numVulns exploits)
    ld      a, [wNumVulns]
    ld      b, a

    ; Exploit 0 always present
    ld      a, [de]
    ld      [wExp0Zone], a
    inc     de
    ld      a, [de]
    ld      [wExp0Row], a
    inc     de
    ld      a, [de]
    ld      [wExp0Col], a
    inc     de
    dec     b
    jr      z, .il_noexp12

    ; Exploit 1
    ld      a, [de]
    ld      [wExp1Zone], a
    inc     de
    ld      a, [de]
    ld      [wExp1Row], a
    inc     de
    ld      a, [de]
    ld      [wExp1Col], a
    inc     de
    dec     b
    jr      z, .il_noexp2

    ; Exploit 2 (only level 0)
    ld      a, [de]
    ld      [wExp2Zone], a
    inc     de
    ld      a, [de]
    ld      [wExp2Row], a
    inc     de
    ld      a, [de]
    ld      [wExp2Col], a
    inc     de
    jr      .il_startpos

.il_noexp12:
    xor     a
    ld      [wExp1Zone], a
    ld      [wExp1Row], a
    ld      [wExp1Col], a
    jr      .il_noexp2done

.il_noexp2:
.il_noexp2done:
    xor     a
    ld      [wExp2Zone], a
    ld      [wExp2Row], a
    ld      [wExp2Col], a

.il_startpos:
    ; Read start position
    ld      a, [de]
    ld      [wLvlStartZone], a
    inc     de
    ld      a, [de]
    ld      [wLvlStartX], a
    inc     de
    ld      a, [de]
    ld      [wLvlStartY], a

    ; Now init gameplay state
    ld      a, STATE_PLAY
    ld      [wGameState], a
    ld      a, [wLvlStartX]
    ld      [wPX], a
    ld      a, [wLvlStartY]
    ld      [wPY], a
    xor     a
    ld      [wPVX], a
    ld      [wPVY], a
    ld      [wPFacing], a
    ld      [wPOnGround], a
    ld      a, [wLvlStartZone]
    ld      [wZone], a
    xor     a
    ld      [wCamX], a
    ld      [wCamY], a
    ld      [wScanActive], a
    ld      [wDialogActive], a
    ld      [wVulnScanned], a
    ld      [wVulnExploited], a
    ld      [wExploitSpawned], a
    ld      [wExploitHeld], a
    ld      [wTimerLo], a
    ld      [wTimerHi], a
    ld      [wAdvCount], a      ; zero advisory count before InitAdvisories sets it
    ld      [wAdvHit], a        ; clear advisory hit flag
    ld      a, 5
    ld      [wHealth], a
    call    InitAdvisories
    call    LoadZone
    ; Start gameplay music (skip if STATE_BOSS borrowed InitLevel)
    ld      a, [wGameState]
    cp      STATE_BOSS
    jr      z, .il_nomusic
    ld      a, SONG_PLAY
    call    MusicPlay
.il_nomusic:
    ret

; ===========================================================================
;  Advisory system
; ===========================================================================

; AdvStartXTable — starting X positions for up to 5 advisories (staggered)
AdvStartXTable:
    DB 24, 120, 56, 100, 72

; AdvZoneTable — which zone each advisory patrols (one per zone, cycling 0-3)
AdvZoneTable:
    DB 0, 1, 2, 3, 0

; AdvCountTable — number of advisories per level index (0-4)
;   Levels 0,1,2 → 0 advisories; level 3 → 3; level 4 → 4; level 5 → 5
AdvCountTable:
    DB 0, 0, 3, 4, 5

; ---------------------------------------------------------------------------
;  InitAdvisories — called from InitLevel; sets wAdvCount and starting state
;  Struct layout per advisory: X, Y, VX, Zone (4 bytes)
;  Each advisory is assigned to a different zone from AdvZoneTable.
; ---------------------------------------------------------------------------
InitAdvisories:
    ld      a, [wCurrentLevel]
    ld      hl, AdvCountTable
    ld      b, 0
    ld      c, a
    add     hl, bc
    ld      a, [hl]             ; advisory count for this level
    ld      [wAdvCount], a
    or      a
    ret     z                   ; no advisories — done

    ld      b, a                ; B = count
    ld      c, 0                ; C = index (0-4)
    ld      hl, wAdv0X          ; HL = first advisory struct base
.ia_loop:
    push    bc
    push    hl
    ; Load starting X from AdvStartXTable[c]
    ld      hl, AdvStartXTable
    ld      b, 0
    ld      d, b
    ld      e, c
    add     hl, de
    ld      a, [hl]             ; startX
    pop     hl
    ld      [hl+], a            ; X
    ld      a, 64
    ld      [hl+], a            ; Y = 64 (floor)
    ld      a, 1
    ld      [hl+], a            ; VX = 1 (right)
    ; Load zone from AdvZoneTable[c]
    push    hl
    ld      hl, AdvZoneTable
    ld      b, 0
    pop     de                  ; DE = saved HL (struct Zone byte addr)
    push    de                  ; re-save it
    ld      e, c
    ld      d, 0
    add     hl, de
    ld      a, [hl]             ; zone
    pop     hl                  ; HL = struct Zone byte addr
    ld      [hl+], a            ; Zone
    pop     bc
    inc     c
    dec     b
    jr      nz, .ia_loop
    ret

; ---------------------------------------------------------------------------
;  UpdateAdvisories — move advisories in their assigned zones each frame
;  Struct: X(+0), Y(+1), VX(+2), Zone(+3) — 4 bytes each
;  Only updates an advisory when wZone matches its Zone field.
; ---------------------------------------------------------------------------
UpdateAdvisories:
    ld      a, [wAdvCount]
    or      a
    ret     z
    ld      a, [wAdvCount]
    ld      b, a                ; B = count
    ld      hl, wAdv0X
.ua_loop:
    push    bc
    push    hl
    ; Check zone match: struct[+3] == wZone
    ld      a, [hl]             ; X (save for later)
    ld      b, a
    inc     hl
    inc     hl                  ; skip Y
    inc     hl                  ; skip VX — now at Zone byte (+3 from base... wait)
    ; struct base: X=+0, Y=+1, VX=+2, Zone=+3
    ; after push hl, HL=X. inc×3 → HL=Zone
    ld      a, [hl]             ; Zone
    ld      d, a
    ld      a, [wZone]
    cp      d
    jr      nz, .ua_skip        ; not this advisory's zone — skip
    ; reload X and VX properly: go back to base
    pop     hl
    push    hl
    ld      a, [hl]             ; X
    ld      b, a
    inc     hl                  ; +1 = Y
    inc     hl                  ; +2 = VX
    ld      a, [hl]             ; VX
    ld      c, a
    ; new X = X + VX
    ld      a, b
    add     c
    cp      145
    jr      nc, .ua_bounceR
    cp      8
    jr      c, .ua_bounceL
    jr      .ua_setX
.ua_bounceR:
    ld      a, 144
    ld      c, 255
    jr      .ua_setVX
.ua_bounceL:
    ld      a, 8
    ld      c, 1
.ua_setVX:
    ld      [hl], c             ; write VX (HL is at +2)
.ua_setX:
    dec     hl                  ; back to Y (+1)
    dec     hl                  ; back to X (+0)
    ld      [hl], a             ; write X
.ua_skip:
    pop     hl
    inc     hl
    inc     hl
    inc     hl
    inc     hl                  ; advance 4 bytes to next struct
    pop     bc
    dec     b
    jr      nz, .ua_loop
    ret

; ---------------------------------------------------------------------------
;  CheckAdvisoryCollision — if player overlaps any advisory in current zone
;  sets wAdvHit = 1. DrawMapScreen called cleanly next frame.
;  Player box: (wPX, wPY) 8×16.  Advisory box: (X, Y=64) 8×8.
; ---------------------------------------------------------------------------
CheckAdvisoryCollision:
    ld      a, [wSpawnGrace]    ; skip collision during spawn grace period
    or      a
    ret     nz
    ld      a, [wAdvCount]
    or      a
    ret     z
    ld      a, [wAdvCount]
    ld      b, a
    ld      hl, wAdv0X
.cac_loop:
    push    bc
    push    hl
    ; Check zone match first (struct[+3])
    inc     hl
    inc     hl
    inc     hl                  ; HL = Zone byte
    ld      a, [hl]
    ld      d, a
    ld      a, [wZone]
    cp      d
    jr      nz, .cac_noHit      ; different zone — skip
    ; Back to X byte
    pop     hl
    push    hl
    ld      a, [hl]             ; advisory X
    ld      c, a
    ; Horizontal overlap: abs(playerX - advX) < 8
    ld      a, [wPX]
    sub     c
    jr      nc, .cac_posH
    cpl
    inc     a
.cac_posH:
    cp      8
    jr      nc, .cac_noHit
    ; Vertical overlap: advisory Y is always 64; abs(playerY - 64) < 16
    ld      a, [wPY]
    sub     64
    jr      nc, .cac_posV
    cpl
    inc     a
.cac_posV:
    cp      16
    jr      nc, .cac_noHit
    ; Hit!
    pop     hl
    pop     bc
    ld      a, 1
    ld      [wAdvHit], a
    ret
.cac_noHit:
    pop     hl
    inc     hl
    inc     hl
    inc     hl
    inc     hl                  ; next struct (4 bytes)
    pop     bc
    dec     b
    jr      nz, .cac_loop
    ret

; ---------------------------------------------------------------------------
;  UpdateAdvisorySprites — write OAM only for advisories in current zone
; ---------------------------------------------------------------------------
UpdateAdvisorySprites:
    ld      a, [wAdvCount]
    or      a
    ret     z
    ; Hide all advisory OAM slots first
    ld      hl, wOAMBuf + (OAM_ADV0 * 4)
    ld      b, MAX_ADVISORIES
.uas_hide:
    xor     a
    ld      [hl], a
    inc     hl
    inc     hl
    inc     hl
    inc     hl
    dec     b
    jr      nz, .uas_hide
    ld      a, [wAdvCount]
    ld      b, a
    ld      c, 0                ; OAM slot counter
    ld      hl, wAdv0X
.uas_loop:
    push    bc
    push    hl
    ; Check zone match (struct[+3])
    inc     hl
    inc     hl
    inc     hl
    ld      a, [hl]             ; Zone
    ld      d, a
    ld      a, [wZone]
    cp      d
    jr      nz, .uas_skip       ; wrong zone — don't draw
    ; Back to base, load X and Y
    pop     hl
    push    hl
    ld      a, [hl+]            ; X
    ld      d, a
    ld      a, [hl]             ; Y
    ld      e, a
    ; OAM address: wOAMBuf + (OAM_ADV0 + c) * 4
    ld      a, c
    add     OAM_ADV0
    add     a, a
    add     a, a
    ld      l, a
    ld      h, 0
    ld      bc, wOAMBuf
    add     hl, bc
    ld      a, e
    add     16
    ld      [hl+], a            ; OAM Y
    ld      a, d
    add     8
    ld      [hl+], a            ; OAM X
    ld      a, SPR_ADVISORY
    ld      [hl+], a
    ld      a, $01
    ld      [hl+], a
.uas_skip:
    pop     hl
    inc     hl
    inc     hl
    inc     hl
    inc     hl                  ; next struct
    pop     bc
    inc     c
    dec     b
    jr      nz, .uas_loop
    ret

; ===========================================================================
;  DrawPatchedScreen / UpdatePatchedScreen
;  Shown when an advisory hits the player. A button returns to world map.
; ===========================================================================
DrawPatchedScreen:
    ld      a, STATE_PATCHED
    ld      [wGameState], a
    call    LCDOff
    call    ClearBG
    ld      hl, $9840
    ld      de, StrPatched1
    call    PrintStr
    ld      hl, $9880
    ld      de, StrPatched2
    call    PrintStr
    ld      hl, $98A0
    ld      de, StrPatched3
    call    PrintStr
    ld      hl, $9900
    ld      de, StrPatchedCont
    call    PrintStr
    call    LCDOn
    ret

UpdatePatchedScreen:
    ld      a, [wJoypadNew]
    bit     0, a                ; A button
    jp      z, MainLoop
    call    DrawMapScreen
    jp      MainLoop

; ===========================================================================
;  Boss fight — PATCH
; ===========================================================================

; Boss Y is fixed at 80 (floor) — no WRAM field needed
DEF BOSS_Y EQU 80

DrawBossScreen:
    ld      a, STATE_BOSS
    ld      [wGameState], a
    ld      a, 120
    ld      [wBossX], a
    ld      a, 255
    ld      [wBossVX], a
    ld      a, BOSS_MAX_HP
    ld      [wBossHP], a
    xor     a
    ld      [wBossHitTimer], a
    ld      a, 16
    ld      [wPX], a
    ld      a, 72
    ld      [wPY], a
    xor     a
    ld      [wPVX], a
    ld      [wPVY], a
    ld      [wPFacing], a
    ld      [wPOnGround], a
    ld      [wScanActive], a
    ld      [wZone], a
    ; Set up level state so LoadZone can work — borrow level 4's zone table
    ld      a, [wCurrentLevel]
    push    af
    ld      a, 4
    call    InitLevel       ; sets zone tables, loads zone 0 tilemap, turns LCD on
    pop     af
    ld      [wCurrentLevel], a
    ; Re-stamp game state and boss vars (InitLevel overwrites them)
    ld      a, STATE_BOSS
    ld      [wGameState], a
    ld      a, 120
    ld      [wBossX], a
    ld      a, 255
    ld      [wBossVX], a
    ld      a, BOSS_MAX_HP
    ld      [wBossHP], a
    xor     a
    ld      [wBossHitTimer], a
    ld      [wAdvCount], a      ; no advisories during boss fight
    ld      a, 16
    ld      [wPX], a
    ld      a, 72
    ld      [wPY], a
    xor     a
    ld      [wPVX], a
    ld      [wPVY], a
    ld      [wPFacing], a
    ld      [wPOnGround], a
    ld      [wScanActive], a
    ; Overwrite row 0 of tilemap with boss title string
    call    LCDOff
    ld      hl, $9800
    ld      de, StrBossTitle
    call    PrintStr
    call    LCDOnPlay
    ; Start boss music
    ld      a, SONG_BOSS
    call    MusicPlay
    ret

UpdateBossScreen:
    call    UpdatePlayerInput
    call    UpdatePlayerPhysics
    call    UpdateScan
    ; Hit timer tick
    ld      a, [wBossHitTimer]
    or      a
    jr      z, .move
    dec     a
    ld      [wBossHitTimer], a
.move:
    ; Move boss X
    ld      a, [wBossX]
    ld      b, a
    ld      a, [wBossVX]
    add     b
    cp      137
    jr      nc, .bR
    cp      8
    jr      nc, .bSet
    ld      a, 1
    ld      [wBossVX], a
    ld      a, 8
    jr      .bSet
.bR:
    ld      a, 255
    ld      [wBossVX], a
    ld      a, 136
.bSet:
    ld      [wBossX], a
    ; Skip collision entirely if boss is already dead
    ld      a, [wBossHP]
    or      a
    jr      z, .ok
    ; Collision: abs(playerX - bossX) < 6 AND abs(playerY - BOSS_Y) < 10
    ld      b, a
    ld      a, [wPX]
    sub     b
    jr      nc, .pH
    cpl
    inc     a
.pH:
    cp      6
    jr      nc, .ok
    ld      a, [wPY]
    sub     BOSS_Y
    jr      nc, .pV
    cpl
    inc     a
.pV:
    cp      10
    jr      nc, .ok
    call    DrawPatchedScreen
    jp      MainLoop
.ok:
    call    UpdateOAM
    ; Draw boss head sprite (single tile, no body, no flash)
    ld      a, [wBossHP]
    or      a
    jr      z, .done
    ld      hl, wOAMBuf + (OAM_BOSS_HEAD * 4)
    ld      a, BOSS_Y + 16
    ld      [hl+], a
    ld      a, [wBossX]
    add     8
    ld      [hl+], a
    ld      a, SPR_BOSS_HEAD
    ld      [hl+], a
    ld      a, $01
    ld      [hl], a
.done:
    jp      MainLoop

; BossTakeScanHit — always hit when scan fires in STATE_BOSS
BossTakeScanHit:
    ld      a, [wBossHP]
    or      a
    ret     z               ; already dead
    dec     a
    ld      [wBossHP], a    ; save new HP
    push    af              ; save HP for zero-check after setting hit timer
    ld      a, 16
    ld      [wBossHitTimer], a
    pop     af              ; restore new HP value
    or      a
    ret     nz              ; HP > 0 — just a hit, not dead yet
    call    DrawFinalWin
    ret

; ===========================================================================
;  DrawMapScreen — circuit board world map, 5 nodes
; ===========================================================================
; Node positions (row, col):  0:(4,4)  1:(4,15)  2:(8,9)  3:(12,4)  4:(12,15)
DrawMapScreen:
    ld      a, STATE_MAP
    ld      [wGameState], a
    call    LCDOff
    call    ClearBG

    ; Draw horizontal trace: row 4, cols 4-15 (connects nodes 0 and 1)
    ld      b, 12           ; 12 tiles cols 4..15
    ld      d, 4            ; row 4
    ld      e, 4            ; start col 4
.dm_hline0:
    push    bc
    call    GetTileAddr
    ld      [hl], T_BG_HLINE
    pop     bc
    inc     e
    dec     b
    jr      nz, .dm_hline0

    ; Vertical trace: col 9, rows 4-8 (node1 area down to node2)
    ld      b, 5            ; rows 4..8
    ld      d, 4
    ld      e, 9
.dm_vline0:
    push    bc
    call    GetTileAddr
    ld      [hl], T_BG_VLINE
    pop     bc
    inc     d
    dec     b
    jr      nz, .dm_vline0

    ; Horizontal trace: row 8, cols 4-9 (node2 leftward)
    ld      b, 6            ; cols 4..9
    ld      d, 8
    ld      e, 4
.dm_hline1:
    push    bc
    call    GetTileAddr
    ld      [hl], T_BG_HLINE
    pop     bc
    inc     e
    dec     b
    jr      nz, .dm_hline1

    ; Vertical trace: col 4, rows 8-12 (node0 down to node3)
    ld      b, 5            ; rows 8..12
    ld      d, 8
    ld      e, 4
.dm_vline1:
    push    bc
    call    GetTileAddr
    ld      [hl], T_BG_VLINE
    pop     bc
    inc     d
    dec     b
    jr      nz, .dm_vline1

    ; Horizontal trace: row 12, cols 4-15 (nodes 3 and 4)
    ld      b, 12           ; cols 4..15
    ld      d, 12
    ld      e, 4
.dm_hline2:
    push    bc
    call    GetTileAddr
    ld      [hl], T_BG_HLINE
    pop     bc
    inc     e
    dec     b
    jr      nz, .dm_hline2

    ; Vertical trace: col 15, rows 4-12 (node1 down to node4)
    ld      b, 9            ; rows 4..12
    ld      d, 4
    ld      e, 15
.dm_vline2:
    push    bc
    call    GetTileAddr
    ld      [hl], T_BG_VLINE
    pop     bc
    inc     d
    dec     b
    jr      nz, .dm_vline2

    ; Draw 5 nodes
    ; Node tiles: completed = T_VULN_EXP ($6B), incomplete = T_VULN_A ($68)
    ld      hl, MapNodePositions    ; 5 entries: DB row, col
    ld      b, 5            ; 5 nodes
    ld      c, 0            ; node index
.dm_nodes:
    push    bc
    push    hl
    ld      a, [hl+]
    ld      d, a            ; row
    ld      a, [hl]
    ld      e, a            ; col
    ; Determine tile: complete or not
    ld      a, c
    ld      hl, LvlBitTable
    ld      b, 0
    add     hl, bc          ; HL = &LvlBitTable[c]
    ld      a, [hl]         ; bit mask
    ld      b, a
    ld      a, [wLevelComplete]
    and     b
    jr      z, .dm_incomplete
    ; Completed node
    call    GetTileAddr
    ld      [hl], T_VULN_EXP
    jr      .dm_nextnode
.dm_incomplete:
    call    GetTileAddr
    ld      [hl], T_VULN_A
.dm_nextnode:
    pop     hl
    inc     hl
    inc     hl              ; advance past this node's row, col
    pop     bc
    inc     c
    dec     b
    jr      nz, .dm_nodes

    ; Draw cursor at wMapCursor node position
    call    DrawMapCursor

    ; Title and prompt
    ld      hl, $9800
    ld      de, StrMapTitle
    call    PrintStr
    ld      hl, $9BE0
    ld      de, StrMapPrompt
    call    PrintStr

    ; Draw node labels L1..L5
    ld      hl, MapNodePositions
    ld      b, 5
    ld      c, 1            ; label digit starts at 1
.dm_labels:
    push    bc
    push    hl
    ld      a, [hl+]
    ld      d, a
    inc     d               ; label one row below node
    ld      a, [hl]
    ld      e, a
    ; Write 'L' tile at (row, col)
    call    GetTileAddr     ; GetTileAddr clobbers B and C
    ld      [hl], $2C       ; 'L' tile ($4C-$20=$2C)
    ; Write digit tile at (row, col+1) — reload C from stack, recompute
    pop     hl              ; HL = MapNodePositions pointer for this node
    pop     bc              ; B = loop counter, C = digit (1..5)
    push    bc
    push    hl
    ld      a, c
    add     $10             ; digit tile index ('1'=$11 .. '5'=$15) — compute NOW before GetTileAddr clobbers C
    push    af              ; save digit tile on stack
    ld      a, [hl+]
    ld      d, a
    inc     d               ; same row as 'L'
    ld      a, [hl]
    ld      e, a
    inc     e               ; col+1 for digit
    call    GetTileAddr     ; clobbers B and C — digit is safe on stack
    pop     af              ; restore digit tile into A
    ld      [hl], a
    pop     hl
    inc     hl
    inc     hl
    pop     bc
    inc     c
    dec     b
    jr      nz, .dm_labels

    call    LCDOn
    ret

; DrawMapCursor — place cursor (T_WALL) above current map cursor node
DrawMapCursor:
    ld      a, [wMapCursor]
    add     a, a            ; *2
    ld      hl, MapNodePositions
    ld      b, 0
    ld      c, a
    add     hl, bc
    ld      a, [hl+]        ; row
    ld      d, a
    dec     d               ; one row above node
    ld      a, [hl]         ; col
    ld      e, a
    call    GetTileAddr
    ld      [hl], T_WALL
    ret

; MapNodePositions — 5 nodes: DB row, col
MapNodePositions:
    DB 4, 4       ; Node 0 (L1)
    DB 4, 15      ; Node 1 (L2)
    DB 8, 9       ; Node 2 (L3)
    DB 12, 4      ; Node 3 (L4)
    DB 12, 15     ; Node 4 (L5)

; ===========================================================================
;  Konami code checker
;  Sequence: Up Up Down Down Left Right Left Right B A
;  Bit layout: 7=Down 6=Up 5=Left 4=Right 3=Start 2=Select 1=B 0=A
; ===========================================================================
KonamiSequence:
    DB %01000000  ; Up
    DB %01000000  ; Up
    DB %10000000  ; Down
    DB %10000000  ; Down
    DB %00100000  ; Left
    DB %00010000  ; Right
    DB %00100000  ; Left
    DB %00010000  ; Right
    DB %00000010  ; B
    DB %00000001  ; A

; CheckKonami — call each frame on map screen; if sequence complete, goes to boss
CheckKonami:
    ld      a, [wJoypadNew]
    or      a
    ret     z               ; no new press this frame — no change to sequence
    ; Look up expected button for current step
    ld      hl, KonamiSequence
    ld      b, 0
    ld      a, [wKonamiStep]
    ld      c, a
    add     hl, bc          ; HL = &KonamiSequence[step]
    ld      b, [hl]         ; B = expected button mask
    ; Check if the new press matches
    ld      a, [wJoypadNew]
    and     b               ; isolate expected bits in what was pressed
    cp      b               ; did we get exactly that button?
    jr      nz, .kc_reset
    ; Correct button — advance step
    ld      a, [wKonamiStep]
    inc     a
    ld      [wKonamiStep], a
    cp      10              ; all 10 steps done?
    ret     nz              ; not yet
    ; Konami complete — skip straight to boss
    xor     a
    ld      [wKonamiStep], a
    ; Mark all levels complete so boss triggers correctly
    ld      a, $1F
    ld      [wLevelComplete], a
    call    DrawBossScreen
    jp      MainLoop
.kc_reset:
    xor     a
    ld      [wKonamiStep], a
    ret

; ===========================================================================
;  UpdateMapScreen — runs each frame in STATE_MAP
; ===========================================================================
UpdateMapScreen:
    call    CheckKonami
    ld      a, [wJoypadNew]
    ; Left = move cursor left (decrement, wrap)
    bit     5, a
    jr      z, .ums_noLeft
    ld      a, [wMapCursor]
    or      a
    jr      z, .ums_wrapLeft
    dec     a
    ld      [wMapCursor], a
    jr      .ums_moved
.ums_wrapLeft:
    ld      a, 4
    ld      [wMapCursor], a
    jr      .ums_moved
.ums_noLeft:
    ; Right = move cursor right (increment, wrap)
    bit     4, a
    jr      z, .ums_noRight
    ld      a, [wMapCursor]
    inc     a
    cp      5
    jr      c, .ums_setRight
    xor     a
.ums_setRight:
    ld      [wMapCursor], a
.ums_moved:
    ; Redraw map when cursor moves
    call    DrawMapScreen
    jp      MainLoop
.ums_noRight:
    ; A button = enter selected level
    ld      a, [wJoypadNew]
    bit     0, a
    jp      z, MainLoop
    ; Enter level = wMapCursor
    ld      a, [wMapCursor]
    call    InitLevel
    jp      MainLoop



; ===========================================================================
;  UpdateOAM — build OAM shadow buffer for player + sprites
; ===========================================================================
UpdateOAM:
    ; Clear OAM shadow
    ld      hl, wOAMBuf
    ld      bc, 160
    xor     a
.clearOAM:
    ld      [hl+], a
    dec     bc
    ld      a, b
    or      c
    ld      a, 0
    jr      nz, .clearOAM

    ld      a, [wGameState]
    cp      STATE_PLAY
    jr      z, .buildPlayer
    cp      STATE_DIALOG
    jr      z, .buildPlayer
    cp      STATE_BOSS
    ret     nz
.buildPlayer:
    ; Determine player animation tile
    ld      a, [wPOnGround]
    or      a
    jr      nz, .grounded
    ; Jumping
    ld      b, SPR_HEAD_JUMP
    ld      c, SPR_BODY_JUMP
    jr      .setSprites
.grounded:
    ld      a, [wPVX]
    or      a
    jr      z, .idle
    ; Running
    ld      a, [wFrame]
    and     %00001000       ; toggle every 8 frames
    jr      z, .run0
    ld      b, SPR_HEAD_RUN1
    ld      c, SPR_BODY_RUN1
    jr      .setSprites
.run0:
    ld      b, SPR_HEAD_RUN0
    ld      c, SPR_BODY_RUN0
    jr      .setSprites
.idle:
    ld      b, SPR_HEAD_IDLE
    ld      c, SPR_BODY_IDLE
.setSprites:
    ; Player head OAM: Y=wPY+16, X=wPX+8, tile=B, flags
    ld      hl, wOAMBuf
    ld      a, [wPY]
    add     16              ; OAM Y = screen Y + 16
    ld      [hl+], a        ; Y
    ld      a, [wPX]
    add     8               ; OAM X = screen X + 8
    ld      [hl+], a        ; X
    ld      a, b
    ld      [hl+], a        ; tile
    ; Flags: bit 5 = X flip (facing left), OBJ pal 0
    ld      a, [wPFacing]
    or      a
    jr      z, .headNoFlip
    ld      a, %00100000
    jr      .headFlags
.headNoFlip:
    xor     a
.headFlags:
    ld      [hl+], a

    ; Player body OAM: Y = head Y + 8
    ld      a, [wPY]
    add     24
    ld      [hl+], a
    ld      a, [wPX]
    add     8
    ld      [hl+], a
    ld      a, c
    ld      [hl+], a
    ld      a, [wPFacing]
    or      a
    jr      z, .bodyNoFlip
    ld      a, %00100000
    jr      .bodyFlags
.bodyNoFlip:
    xor     a
.bodyFlags:
    ld      [hl+], a

    ; Vuln node sprites (pulse animation)
    call    UpdateVulnSprites

    ; Exploit pickup sprites
    call    UpdateExploitSprites

    ; Advisory enemy sprites
    call    UpdateAdvisorySprites
    ret

; UpdateVulnSprites — place OAM entries for any vuln in current zone
UpdateVulnSprites:
    ld      a, [wFrame]
    and     %00001000
    jr      z, .frameA
    ld      b, SPR_VULN_B
    jr      .drawVulns
.frameA:
    ld      b, SPR_VULN_A
.drawVulns:
    ; Draw vuln 0 sprite if in correct zone and not yet exploited
    ld      a, [wVuln0Zone]
    ld      e, a
    ld      a, [wZone]
    cp      e
    jr      nz, .uvs_skipV0
    ld      a, [wVulnExploited]
    bit     0, a
    jr      nz, .uvs_skipV0
    ; pixel Y = wVuln0Row * 8 + 16 (OAM offset)
    ld      a, [wVuln0Row]
    add     a, a
    add     a, a
    add     a, a            ; row * 8
    add     16
    ld      hl, wOAMBuf + (OAM_VULN0 * 4)
    ld      [hl+], a
    ld      a, [wVuln0Col]
    add     a, a
    add     a, a
    add     a, a            ; col * 8
    add     8
    ld      [hl+], a
    ld      a, b            ; SPR_VULN_A or SPR_VULN_B
    ld      [hl+], a
    ld      a, $01
    ld      [hl+], a
.uvs_skipV0:
    ld      a, [wVuln1Zone]
    ld      e, a
    ld      a, [wZone]
    cp      e
    jr      nz, .uvs_skipV1
    ld      a, [wVulnExploited]
    bit     1, a
    jr      nz, .uvs_skipV1
    ld      a, [wVuln1Row]
    add     a, a
    add     a, a
    add     a, a
    add     16
    ld      hl, wOAMBuf + (OAM_VULN1 * 4)
    ld      [hl+], a
    ld      a, [wVuln1Col]
    add     a, a
    add     a, a
    add     a, a
    add     8
    ld      [hl+], a
    ld      a, b
    ld      [hl+], a
    ld      a, $01
    ld      [hl+], a
.uvs_skipV1:
    ; Only draw vuln2 if level has 3 vulns
    ld      a, [wNumVulns]
    cp      3
    ret     nz
    ld      a, [wVuln2Zone]
    ld      e, a
    ld      a, [wZone]
    cp      e
    ret     nz
    ld      a, [wVulnExploited]
    bit     2, a
    ret     nz
    ld      a, [wVuln2Row]
    add     a, a
    add     a, a
    add     a, a
    add     16
    ld      hl, wOAMBuf + (OAM_VULN2 * 4)
    ld      [hl+], a
    ld      a, [wVuln2Col]
    add     a, a
    add     a, a
    add     a, a
    add     8
    ld      [hl+], a
    ld      a, b
    ld      [hl+], a
    ld      a, $01
    ld      [hl+], a
    ret

; UpdateExploitSprites — place OAM for any exploit pickup in current zone
UpdateExploitSprites:
    ld      a, [wExploitSpawned]
    ld      b, a            ; save spawned bitmask

    bit     0, b
    jr      z, .ues_skipE0
    ld      a, [wExp0Zone]
    ld      e, a
    ld      a, [wZone]
    cp      e
    jr      nz, .ues_skipE0
    ld      hl, wOAMBuf + (OAM_EXP0 * 4)
    ld      a, [wExp0Row]
    add     a, a
    add     a, a
    add     a, a
    add     16
    ld      [hl+], a
    ld      a, [wExp0Col]
    add     a, a
    add     a, a
    add     a, a
    add     8
    ld      [hl+], a
    ld      a, SPR_EXP_PICK
    ld      [hl+], a
    ld      a, $02
    ld      [hl+], a
.ues_skipE0:
    bit     1, b
    jr      z, .ues_skipE1
    ld      a, [wExp1Zone]
    ld      e, a
    ld      a, [wZone]
    cp      e
    jr      nz, .ues_skipE1
    ld      hl, wOAMBuf + (OAM_EXP1 * 4)
    ld      a, [wExp1Row]
    add     a, a
    add     a, a
    add     a, a
    add     16
    ld      [hl+], a
    ld      a, [wExp1Col]
    add     a, a
    add     a, a
    add     a, a
    add     8
    ld      [hl+], a
    ld      a, SPR_EXP_SCR
    ld      [hl+], a
    ld      a, $02
    ld      [hl+], a
.ues_skipE1:
    bit     2, b
    ret     z
    ld      a, [wExp2Zone]
    ld      e, a
    ld      a, [wZone]
    cp      e
    ret     nz
    ld      hl, wOAMBuf + (OAM_EXP2 * 4)
    ld      a, [wExp2Row]
    add     a, a
    add     a, a
    add     a, a
    add     16
    ld      [hl+], a
    ld      a, [wExp2Col]
    add     a, a
    add     a, a
    add     a, a
    add     8
    ld      [hl+], a
    ld      a, SPR_EXP_TERM
    ld      [hl+], a
    ld      a, $02
    ld      [hl+], a
    ret

; ===========================================================================
;  TILE / SPRITE DATA LOADING
; ===========================================================================

; LoadTileData
; VRAM layout (BG8000 mode — tile N → $8000 + N*16):
;   $8000-$85F0 = font tiles      tile $00-$5E  (char - $20)
;   $8600-$8700 = BG gameplay     tile $60-$6F  ($8000 + $60*16 = $8600)
;   $8800-$88B0 = OBJ sprites     OBJ tile $80-$8A ($8000 + $80*16 = $8800)
LoadTileData:
    ; Font at $8000 — tile index = char - $20, covers $20-$7E (95 chars)
    ld      hl, $8000
    ld      de, FontData
    ld      bc, FontDataEnd - FontData
.fontLoop:
    ld      a, [de]
    ld      [hl+], a
    inc     de
    dec     bc
    ld      a, b
    or      c
    jr      nz, .fontLoop

    ; Sprite tiles at $8800 (OBJ tile $80 in BG8000 mode)
    ld      hl, $8800
    ld      de, SpriteData
    ld      bc, SpriteDataEnd - SpriteData
.sprLoop:
    ld      a, [de]
    ld      [hl+], a
    inc     de
    dec     bc
    ld      a, b
    or      c
    jr      nz, .sprLoop

    ; BG gameplay tiles at $8600 (BG tile $60 in BG8000 mode: $8000 + $60*16 = $8600)
    ld      hl, $8600
    ld      de, TileData
    ld      bc, TileDataEnd - TileData
.bgLoop:
    ld      a, [de]
    ld      [hl+], a
    inc     de
    dec     bc
    ld      a, b
    or      c
    jr      nz, .bgLoop
    ret

; PrintStr / PrintStrDirect — char→tile index = char - $20 (font at $8000 = tile 0)
PrintStr:
PrintStrDirect:
    ld      a, [de]
    or      a
    ret     z
    sub     $20
    ld      [hl+], a
    inc     de
    jr      PrintStr

; ClearBG — zero tilemap $9800-$9BFF (LCD off)
ClearBG:
    ld      hl, $9800
    ld      bc, $0400
    xor     a
.loop:
    ld      [hl+], a
    dec     bc
    ld      a, b
    or      c
    ld      a, 0
    jr      nz, .loop
    ret

; ===========================================================================
;  SetupPalettes — GBC only, skipped on DMG
; ===========================================================================
; SetupPalettes — write all GBC palettes via auto-increment BCPS/OCPS.
; GBC colour format: 15-bit xBBBBBGGGGGRRRRR, little-endian (lo first, hi second).
; Palette data stored as pairs: lo, hi for each of 4 colours per palette.
; 4 BG palettes × 4 colours × 2 bytes = 64 bytes written to rBCPD.
; 3 OBJ palettes × 4 colours × 2 bytes = 24 bytes written to rOCPD.
SetupPalettes:
    ld      a, [wIsGBC]
    cp      $11
    ret     nz

    ; --- BG palettes (all 4 written in one auto-increment burst) ---
    ld      a, %10000000        ; auto-increment, start at index 0
    ld      [rBCPS], a
    ld      hl, BGPaletteData
    ld      bc, BGPaletteDataEnd - BGPaletteData
.bgpal:
    ld      a, [hl+]
    ld      [rBCPD], a
    dec     bc
    ld      a, b
    or      c
    jr      nz, .bgpal

    ; --- OBJ palettes ---
    ld      a, %10000000
    ld      [rOCPS], a
    ld      hl, OBJPaletteData
    ld      bc, OBJPaletteDataEnd - OBJPaletteData
.objpal:
    ld      a, [hl+]
    ld      [rOCPD], a
    dec     bc
    ld      a, b
    or      c
    jr      nz, .objpal
    ret

; ===========================================================================
;  Music Engine — ROM0
;  3-channel driver: CH1 (pulse, melody), CH2 (pulse, harmony), CH4 (noise, drums)
;  Song data lives in ROMX bank 2. SwitchToBank2/SwitchToBank1 swap it in/out.
;
;  Song data format (in bank 2):
;   Song header: DB tempo_frames, num_patterns
;   Pattern order: DB pat0_idx, pat1_idx, ... (num_patterns entries)
;   Pattern data:  each pattern = 16 rows × 3 bytes (ch1_note, ch2_note, ch4_noise)
;   Note byte:  %OOOO_SSSS  O=octave(0-6) S=semitone(0-11)
;               $FF = rest (silence channel), $FE = tie (don't retrigger)
;   Noise byte: $00=off, $01=kick, $02=snare, $03=hihat
; ===========================================================================

; ---------------------------------------------------------------------------
;  SwitchToBank2 — switch ROMX to bank 2 (music data)
;  SwitchToBank1 — switch ROMX back to bank 1 (tiles/strings)
;  MBC1: write bank number to $2000
; ---------------------------------------------------------------------------
SwitchToBank2:
    ld      a, 2
    ld      [$2000], a
    ret

SwitchToBank1:
    ld      a, 1
    ld      [$2000], a
    ret

; ---------------------------------------------------------------------------
;  AudioInit — enable APU, set master volume, route all channels
; ---------------------------------------------------------------------------
AudioInit:
    ld      a, $FF
    ld      [rNR52], a      ; power on APU
    ld      a, $77
    ld      [rNR50], a      ; max volume both speakers
    ld      a, $FF
    ld      [rNR51], a      ; all channels to both L+R
    ret

; ---------------------------------------------------------------------------
;  MusicPlay — A = song ID (SONG_OFF/SONG_TITLE/SONG_PLAY/SONG_BOSS)
;  Resets playback state and starts the requested song.
; ---------------------------------------------------------------------------
MusicPlay:
    ld      [wMusicSong], a
    xor     a
    ld      [wMusicRow], a
    ld      [wMusicPatIdx], a
    ld      [wMusicTick], a
    ; If SONG_OFF, silence all channels and return
    ld      a, [wMusicSong]
    or      a
    jr      nz, .mp_start
    ; Silence: trigger with zero volume
    xor     a
    ld      [rNR12], a
    ld      a, $80
    ld      [rNR14], a
    xor     a
    ld      [rNR22], a
    ld      a, $80
    ld      [rNR24], a
    xor     a
    ld      [rNR42], a
    ld      a, $80
    ld      [rNR44], a
    ret
.mp_start:
    ; Load tempo for this song from bank 2 header
    call    SwitchToBank2
    ld      a, [wMusicSong]
    dec     a               ; 0-based index
    ld      hl, MusicSongTable
    add     a, a            ; *2 (word ptr)
    ld      b, 0
    ld      c, a
    add     hl, bc
    ld      a, [hl+]
    ld      h, [hl]
    ld      l, a            ; HL = ptr to song header
    ld      a, [hl]         ; first byte = tempo (frames per row)
    ld      [wMusicTempoRel], a
    call    SwitchToBank1
    ret

; ---------------------------------------------------------------------------
;  MusicTick — call once per frame from MainLoop
;  Advances the sequencer and writes NR registers as needed.
; ---------------------------------------------------------------------------
MusicTick:
    ld      a, [wMusicSong]
    or      a
    ret     z               ; SONG_OFF — do nothing

    ; Count down tick
    ld      a, [wMusicTick]
    or      a
    jr      z, .mt_advance
    dec     a
    ld      [wMusicTick], a
    ret

.mt_advance:
    ; Reset tick counter
    ld      a, [wMusicTempoRel]
    dec     a               ; tempo-1 so first frame fires immediately
    ld      [wMusicTick], a

    ; Switch to bank 2, get current row data
    call    SwitchToBank2

    ; Resolve song pointer
    ld      a, [wMusicSong]
    dec     a
    ld      hl, MusicSongTable
    add     a, a
    ld      b, 0
    ld      c, a
    add     hl, bc
    ld      a, [hl+]
    ld      h, [hl]
    ld      l, a            ; HL = song header

    ; HL+0 = tempo, HL+1 = num_patterns
    inc     hl              ; skip tempo
    ld      a, [hl+]        ; A = num_patterns
    ld      b, a            ; B = num_patterns
    ; HL now points to pattern order table

    ; Get current pattern index from order table
    ld      a, [wMusicPatIdx]
    ld      c, a
    push    hl
    ld      b, 0
    add     hl, bc
    ld      a, [hl]         ; A = pattern number
    pop     hl

    ; Advance HL past order table to pattern data base
    ; order table is num_patterns bytes
    ld      c, b            ; B still = num_patterns
    ld      b, 0
    add     hl, bc          ; HL = base of pattern data

    ; Each pattern = 16 rows × 3 bytes = 48 bytes
    ; Compute pat_num * 48, add to HL
    ld      c, a            ; C = pattern number
    xor     a
    or      c
    jr      z, .mt_offset_done
    ld      b, 48
.mt_mul_loop:
    add     b
    dec     c
    jr      nz, .mt_mul_loop
.mt_offset_done:
    ; A = pat_num * 48
    ld      b, 0
    ld      c, a
    add     hl, bc          ; HL = base of this pattern

    ; Add row offset: row * 3
    ld      a, [wMusicRow]
    ld      c, a
    add     a, a            ; *2
    add     c               ; *3
    ld      b, 0
    ld      c, a
    add     hl, bc          ; HL = current row data

    ; Read 3 bytes: ch1_note, ch2_note, ch4_noise
    ld      a, [hl+]
    ld      b, a            ; B = ch1 note
    ld      a, [hl+]
    ld      c, a            ; C = ch2 note
    ld      a, [hl]
    ld      d, a            ; D = ch4 noise

    call    SwitchToBank1

    ; --- Output CH1 (melody pulse) ---
    ld      a, b
    cp      $FF
    jr      z, .mt_ch1_rest
    cp      $FE
    jr      z, .mt_ch1_tie
    ; Convert note to frequency and write
    push    bc
    push    de
    call    NoteToFreq      ; A=note in, DE=freq out
    ld      a, $80          ; 50% duty, no length
    ld      [rNR11], a
    ld      a, $F1          ; vol 15, no sweep, env hold
    ld      [rNR12], a
    ld      a, e            ; freq lo
    ld      [rNR13], a
    ld      a, d
    or      $80             ; trigger
    ld      [rNR14], a
    pop     de
    pop     bc
    jr      .mt_ch1_done
.mt_ch1_rest:
    ; Cut CH1: set env to 0 volume then trigger
    ld      a, $08
    ld      [rNR12], a
    ld      a, $80
    ld      [rNR14], a
.mt_ch1_tie:
.mt_ch1_done:

    ; --- Output CH2 (harmony pulse) ---
    ld      a, c
    cp      $FF
    jr      z, .mt_ch2_rest
    cp      $FE
    jr      z, .mt_ch2_tie
    push    bc
    push    de
    call    NoteToFreq
    ld      a, $40          ; 25% duty
    ld      [rNR21], a
    ld      a, $A1          ; vol 10, decay 1
    ld      [rNR22], a
    ld      a, e
    ld      [rNR23], a
    ld      a, d
    or      $80
    ld      [rNR24], a
    pop     de
    pop     bc
    jr      .mt_ch2_done
.mt_ch2_rest:
    ld      a, $08
    ld      [rNR22], a
    ld      a, $80
    ld      [rNR24], a
.mt_ch2_tie:
.mt_ch2_done:


    ; Advance row counter
    ld      a, [wMusicRow]
    inc     a
    cp      16              ; 16 rows per pattern
    jr      nc, .mt_next_pat
    ld      [wMusicRow], a
    ret

.mt_next_pat:
    xor     a
    ld      [wMusicRow], a
    ; Advance pattern index, loop if at end
    ; Need num_patterns again — read from bank 2
    call    SwitchToBank2
    ld      a, [wMusicSong]
    dec     a
    ld      hl, MusicSongTable
    add     a, a
    ld      b, 0
    ld      c, a
    add     hl, bc
    ld      a, [hl+]
    ld      h, [hl]
    ld      l, a            ; HL = song header
    inc     hl              ; skip tempo
    ld      a, [hl]         ; num_patterns
    ld      b, a
    call    SwitchToBank1
    ld      a, [wMusicPatIdx]
    inc     a
    cp      b
    jr      nc, .mt_pat_wrap
    ld      [wMusicPatIdx], a
    ret
.mt_pat_wrap:
    xor     a
    ld      [wMusicPatIdx], a
    ret

; ---------------------------------------------------------------------------
;  NoteToFreq — convert packed note byte to GB frequency value
;  Input:  A = note byte (%OOOO_SSSS, octave 3-6, semitone 0-11)
;  Output: D = freq hi (bits 10-8), E = freq lo (bits 7-0)
;  Uses a direct 4-octave lookup table (oct 3-6, 12 semitones each = 48 entries × 2 bytes)
;  Table index = (octave - 3) * 12 + semitone;  byte offset = index * 2
; ---------------------------------------------------------------------------
NoteToFreq:
    ld      b, a
    ; Extract semitone (low nibble)
    and     $0F
    ld      c, a            ; C = semitone 0-11
    ; Extract octave (high nibble), clamp to 3-6
    ld      a, b
    swap    a
    and     $0F             ; A = octave
    sub     3               ; A = octave - 3  (0-3)
    jr      nc, .ntf_oct_ok
    xor     a               ; clamp to 0 if below oct 3
.ntf_oct_ok:
    cp      4
    jr      c, .ntf_oct_clamp_done
    ld      a, 3            ; clamp to oct 6 (index 3) if above
.ntf_oct_clamp_done:
    ; A = (octave-3) in 0-3. Multiply by 12: A*12 = A*8 + A*4
    ld      b, a
    add     a, a            ; *2
    add     a, a            ; *4
    ld      d, a
    add     a, a            ; *8
    add     a, d            ; *12
    add     a, c            ; + semitone  → table index
    ; Multiply index by 2 (each entry = 2 bytes)
    add     a, a
    ; HL = NoteFreqTable + A
    ld      hl, NoteFreqTable
    ld      d, 0
    ld      e, a
    add     hl, de
    ld      e, [hl]
    inc     hl
    ld      d, [hl]         ; DE = 11-bit GB freq (lo in E, hi in D, D masked to 3 bits)
    ret

; NoteFreqTable — exact GB freq values: f = round(2048 - 131072/Hz)
; 4 octaves × 12 semitones, 2 bytes each (little-endian)
; C    C#    D    D#    E     F    F#    G    G#    A    A#    B
NoteFreqTable:
    ; Octave 3
    DW 1046, 1102, 1155, 1205, 1253, 1297
    DW 1339, 1379, 1417, 1452, 1486, 1517
    ; Octave 4
    DW 1547, 1575, 1602, 1627, 1650, 1673
    DW 1694, 1714, 1732, 1750, 1767, 1783
    ; Octave 5
    DW 1798, 1812, 1825, 1837, 1849, 1860
    DW 1871, 1881, 1890, 1899, 1907, 1915
    ; Octave 6
    DW 1923, 1930, 1936, 1943, 1949, 1954
    DW 1959, 1964, 1969, 1974, 1978, 1982

; ---------------------------------------------------------------------------
; Palette data — GBC 15-bit colours, lo byte first then hi byte
; Format per colour: DB lo, hi  where value = (b<<10)|(g<<5)|r  (each 0-31)
; ---------------------------------------------------------------------------
SECTION "PaletteData", ROMX, BANK[1]

BGPaletteData:
; BG Palette 0 — used by all tiles (attr map zeroed = palette 0)
; col0 black        RGB(0,0,0)   = $0000
    DB $00, $00
; col1 dark teal    RGB(0,12,10) = $2980
    DB $80, $29
; col2 mid teal     RGB(0,20,16) = $4280
    DB $80, $42
; col3 bright green RGB(0,31,0)  = $03E0
    DB $E0, $03
; BG Palette 1 — same as 0 (unused but must fill 8 bytes)
    DB $00,$00, $80,$29, $80,$42, $E0,$03
; BG Palette 2 — same
    DB $00,$00, $80,$29, $80,$42, $E0,$03
; BG Palette 3 — same
    DB $00,$00, $80,$29, $80,$42, $E0,$03
BGPaletteDataEnd:

OBJPaletteData:
; OBJ Palette 0 — player: transparent / white body / bright green suit / cyan visor
; col0 transparent  (colour 0 on OBJ = transparent)
    DB $00, $00
; col1 white        RGB(31,31,31) = $7FFF
    DB $FF, $7F
; col2 bright green RGB(0,31,0)  = $03E0
    DB $E0, $03
; col3 cyan         RGB(0,28,28) = $7380
    DB $80, $73
; OBJ Palette 1 — vuln node sprites: transparent / dark red / orange / yellow
    DB $00,$00, $09,$00, $C9,$03, $E0,$7F
; OBJ Palette 2 — exploit pickups: transparent / dark / teal / cyan
    DB $00,$00, $C4,$10, $80,$42, $80,$73
OBJPaletteDataEnd:

; ===========================================================================
;  ROM DATA SECTIONS
; ===========================================================================

SECTION "TileData", ROMX, BANK[1], ALIGN[8]
TileData:
INCLUDE "tiles.inc"
TileDataEnd:

SECTION "SpriteData", ROMX, BANK[1], ALIGN[8]
SpriteData:
INCLUDE "sprites.inc"
SpriteDataEnd:

SECTION "FontData", ROMX, BANK[1], ALIGN[8]
FontData:
INCLUDE "font.inc"
FontDataEnd:

INCLUDE "strings.inc"
INCLUDE "levels.inc"
INCLUDE "music.inc"
