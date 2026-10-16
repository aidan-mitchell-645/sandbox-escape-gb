; ===========================================================================
;  SANDBOX ESCAPE — Game Boy Color Platformer
;  Build 10
;
;  Architecture:
;   - VBlank interrupt + HALT for frame sync (ISR only raises a flag).
;   - Each frame begins with the VBlank-only work: OAM DMA, the VRAM write
;     queue, and dialog-panel streaming. Game logic never touches VRAM
;     while the LCD is on; it calls QueueTile instead.
;   - The current zone's tilemap is mirrored in WRAM (wZoneMap); collision
;     and pickup checks read the mirror, never VRAM.
;   - BG layer = world tilemap. Window layer = HUD (WY = 128), raised to
;     WY = 80 to show the dialog panel over gameplay.
;   - Sprites: player (2 OBJ, 8×16 effective), vuln nodes, exploit pickups,
;     advisories, boss.
;   - Physics: whole-pixel vertical motion; horizontal velocity in 1/16 px
;     with sub-pixel position. AABB tile collision.
;   - Level progress is saved to battery-backed cartridge RAM (MBC1).
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
DEF STATE_PATCHED EQU 6   ; "you've been patched" screen after losing all HP
DEF STATE_BOSS    EQU 7   ; boss fight vs Patch

; ---------------------------------------------------------------------------
; Constants — Joypad bits (wJoypad layout)
; ---------------------------------------------------------------------------
DEF PADB_A        EQU 0
DEF PADB_B        EQU 1
DEF PADB_SELECT   EQU 2
DEF PADB_START    EQU 3
DEF PADB_RIGHT    EQU 4
DEF PADB_LEFT     EQU 5
DEF PADB_UP       EQU 6
DEF PADB_DOWN     EQU 7

; ---------------------------------------------------------------------------
; Constants — Physics
; Vertical velocity is whole pixels per frame (signed byte).
; Horizontal velocity is in 1/16 px per frame (signed byte); the fractional
; part of X lives in wPXSub.
; ---------------------------------------------------------------------------
DEF GRAVITY       EQU 1
DEF JUMP_VY       EQU 246   ; -10 as unsigned byte (256-10)
DEF JUMP_CUT_VY   EQU 253   ; -3: rise speed cap once A is released (short hop)
DEF MAX_FALL      EQU 8     ; must match intYStep clamp (8px max per frame)
DEF RUN_MAX       EQU 24    ; 1.5 px/frame
DEF RUN_ACCEL     EQU 3
DEF GROUND_FRIC   EQU 4     ; also added when reversing direction
DEF AIR_FRIC      EQU 1
DEF COYOTE_FRAMES EQU 6     ; jump still allowed this long after leaving a ledge
DEF JUMP_BUF_FRAMES EQU 6   ; A pressed this long before landing still jumps

; ---------------------------------------------------------------------------
; Constants — Health / damage
; ---------------------------------------------------------------------------
DEF MAX_HEALTH    EQU 5
DEF INVULN_FRAMES EQU 90    ; blinking i-frames after a hit
DEF KNOCK_FRAMES  EQU 12    ; first part of i-frames where steering is ignored
DEF KNOCK_VX      EQU 32    ; 2 px/frame
DEF KNOCK_VY      EQU 251   ; -5
DEF SPAWN_GRACE   EQU 60    ; frames after a zone load before enemies can hit

; ---------------------------------------------------------------------------
; Constants — Zone / world
; ---------------------------------------------------------------------------
DEF ZONE_COLS     EQU 20
DEF ZONE_ROWS     EQU 16
DEF ZONE_SIZE     EQU ZONE_COLS * ZONE_ROWS   ; 320 bytes per zone
DEF MAX_VULNS     EQU 3
DEF NUM_LEVELS    EQU 5
DEF ALL_LEVELS    EQU (1 << NUM_LEVELS) - 1

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
DEF SPR_EXP_PICK  EQU $8A   ; exploit 0: microchip
DEF SPR_EXP_SCR   EQU $8B   ; exploit 1: script file
DEF SPR_EXP_TERM  EQU $8C   ; exploit 2: terminal prompt
DEF SPR_ADVISORY  EQU $8D   ; advisory enemy: crawling bug
DEF SPR_BOSS_HEAD EQU $8E   ; Patch boss head
DEF SPR_BOSS_BODY EQU $8F   ; Patch boss body

; BG gameplay tile indices — loaded at $8600 = BG tile $60+ in BG8000 mode
; (font occupies $8000-$85E0 = tiles $00-$5E)
DEF T_SPACE       EQU $00   ; font space (blank)
DEF T_VOID        EQU $60
DEF T_PLAT_MID    EQU $61
DEF T_PLAT_L      EQU $62
DEF T_PLAT_R      EQU $63
DEF T_WALL        EQU $64
DEF T_BG_DOT      EQU $65
DEF T_BG_HLINE    EQU $66
DEF T_BG_VLINE    EQU $67
DEF T_VULN_A      EQU $68
DEF T_VULN_B      EQU $69
DEF T_VULN_SCAN   EQU $6A
DEF T_VULN_EXP    EQU $6B
DEF T_EXPLOIT     EQU $6C
DEF T_HUD_BAR     EQU $6D
DEF T_BEAM_FULL   EQU $6E
DEF T_BEAM_FADE   EQU $6F
DEF T_DIGIT0      EQU "0" - $20  ; font tile for '0'

; OAM slot assignments
DEF OAM_PLAYER_HEAD EQU 0
DEF OAM_PLAYER_BODY EQU 1
DEF OAM_VULN0       EQU 2   ; 2-4
DEF OAM_EXP0        EQU 5   ; 5-7
DEF OAM_ADV0        EQU 8   ; 8-12
DEF MAX_ADVISORIES  EQU 5
DEF OAM_BOSS_HEAD   EQU 13
DEF BOSS_MAX_HP     EQU 3   ; hits to defeat Patch

; Scan beam
DEF SCAN_FRAMES     EQU 32  ; total frames a scan lasts
DEF SCAN_TILES      EQU 10  ; max beam length in tiles
DEF SCAN_REACH      EQU 20  ; px: how close to a vuln node a scan/exploit works

; LCD / window
;  TEXT = BG + window, no sprites (title, intro, map, full-screen messages)
;  PLAY = BG + window + sprites (platformer gameplay)
DEF LCD_TEXT        EQU LCDCF_ON | LCDCF_BG8000 | LCDCF_BGON | LCDCF_WINON | LCDCF_WIN9C00
DEF LCD_PLAY        EQU LCD_TEXT | LCDCF_OBJON
DEF WY_HIDDEN       EQU 144
DEF WY_HUD          EQU 128         ; window rows 0-1 = HUD
DEF WY_DIALOG       EQU 80          ; window rows 0-7 = HUD + dialog panel
DEF DLG_ROWS        EQU 6           ; dialog text rows (window rows 2-7)

; HUD digit positions in the window tilemap
DEF HUD_HP_ADDR     EQU $9C23
DEF HUD_VULNS_ADDR  EQU $9C2B
DEF HUD_EXP_ADDR    EQU $9C31

; VRAM write queue (entries of: addr lo, addr hi, tile)
DEF VQ_MAX          EQU 24

; Cartridge (MBC1)
DEF rROMB           EQU $2000
DEF rRAMG           EQU $0000
DEF RAMG_ENABLE     EQU $0A

; Music song IDs (stored in wMusicSong)
DEF SONG_OFF    EQU 0
DEF SONG_TITLE  EQU 1
DEF SONG_PLAY   EQU 2
DEF SONG_BOSS   EQU 3

; Note encoding: high nibble = octave (0-6), low nibble = semitone (0-11)
; Special: $FF = rest, $FE = tie (hold previous)
; Tempo: frames per row stored in song header

; Jump to MainLoop if a call above changed the game state (e.g. opened a
; dialog or finished the level), so the rest of this frame's update is skipped.
MACRO JP_UNLESS_STATE
    ld      a, [wGameState]
    cp      \1
    jp      nz, MainLoop
ENDM

; ---------------------------------------------------------------------------
; WRAM layout
; ---------------------------------------------------------------------------
SECTION "WRAM", WRAM0
wGameState:      DS 1
wIsGBC:          DS 1   ; A at boot: $11 = GBC
wFrame:          DS 1

; Player
wPX:             DS 1   ; player X pixel (screen space 0-152)
wPXSub:          DS 1   ; X fraction, 1/16 px (0-15)
wPY:             DS 1   ; player Y pixel (screen space 0-127)
wPVX:            DS 1   ; velocity X, signed, 1/16 px per frame
wPVY:            DS 1   ; velocity Y, signed, px per frame
wPFacing:        DS 1   ; 0=right 1=left
wPOnGround:      DS 1
wCoyote:         DS 1   ; frames left in which a ledge jump is still allowed
wJumpBuf:        DS 1   ; frames left on a buffered jump press
wInvuln:         DS 1   ; i-frames remaining after taking damage
wHealth:         DS 1
wPlayerDown:     DS 1   ; set when HP hits 0; handled at the top of the next frame
wSpawnGrace:     DS 1   ; frames after a zone load before enemies can hit

wZone:           DS 1   ; current zone

; Input
wJoypad:         DS 1
wJoypadPrev:     DS 1
wJoypadNew:      DS 1

; Level progress (bit N = vuln/exploit N)
wVulnScanned:    DS 1
wVulnExploited:  DS 1
wExploitSpawned: DS 1   ; exploit item is lying in the world
wExploitHeld:    DS 1   ; 0=none, N = exploit for vuln N-1

; Scan beam
wScanActive:     DS 1
wScanTimer:      DS 1
wScanVulnIdx:    DS 1
wScanDir:        DS 1   ; 0=right 1=left
wScanRow:        DS 1   ; beam tile row
wScanCol:        DS 1   ; tile col the beam starts next to (player centre)
wBeamLen:        DS 1   ; tiles drawn so far
wBeamMax:        DS 1   ; tiles before the beam hits something solid

; Dialog panel
wDlgRow:         DS 1   ; next row to stream; DLG_ROWS = panel fully drawn

wIntroPage:      DS 1

; Multi-level progress
wCurrentLevel:   DS 1   ; active level index (0-4)
wMapCursor:      DS 1   ; world map cursor (0-4)
wLevelComplete:  DS 1   ; bitmask bits 0-4 completed levels (saved)

; Per-level runtime state (populated by InitLevel from LevelTable)
wNumZones:       DS 1
wNumVulns:       DS 1
wLvlZoneTable:   DS 2   ; zone tilemap pointer table
wLvlAdjTable:    DS 2   ; zone adjacency table
wVulns:          DS MAX_VULNS * 3   ; zone, row, col per vuln node
wExps:           DS MAX_VULNS * 3   ; zone, row, col per exploit spawn
wVulnsEnd:
wLvlStartZone:   DS 1
wLvlStartX:      DS 1
wLvlStartY:      DS 1

; Advisories: X, Y, VX (1=right 255=left), Zone — 4 bytes each
wAdvCount:       DS 1
wAdv0X:          DS MAX_ADVISORIES * 4

; Boss
wBossX:          DS 1
wBossVX:         DS 1   ; 1=right 255=left
wBossHP:         DS 1
wBossHitTimer:   DS 1   ; flashes the boss after a hit
wKonamiStep:     DS 1   ; Konami code progress (0-9)

; Music
wMusicSong:      DS 1   ; current song: 0=off 1=title 2=play 3=boss
wMusicRow:       DS 1   ; current row in pattern
wMusicTick:      DS 1   ; tick-within-row counter
wMusicPatIdx:    DS 1   ; current pattern index in song order
wMusicTempoRel:  DS 1   ; frames per tick (set per song)

wVQCount:        DS 1   ; queued VRAM writes

wZoneMap:        DS ZONE_SIZE               ; WRAM mirror of the zone tilemap
wDlgBuf:         DS DLG_ROWS * ZONE_COLS    ; dialog panel tiles

SECTION "VRAMQueue", WRAM0, ALIGN[8]
wVQueue:         DS VQ_MAX * 3

; OAM shadow buffer (40 entries × 4 bytes)
SECTION "OAMBuf", WRAM0, ALIGN[8]
wOAMBuf:         DS 160

; ---------------------------------------------------------------------------
; Battery-backed save RAM
; ---------------------------------------------------------------------------
SECTION "SaveData", SRAM
sMagic:          DS 4
sLevelComplete:  DS 1
sChecksum:       DS 1   ; ~sLevelComplete


; ---------------------------------------------------------------------------
; RST / interrupt vectors $0000-$00FF — claim this space so the linker cannot
; place floating ROM sections here.
; ---------------------------------------------------------------------------
SECTION "RSTVectors", ROM0[$0000]
    DS $40, $00

SECTION "VBlankVector", ROM0[$0040]
VBlankHandler:
    push    af
    ld      a, 1
    ldh     [hVBlankFlag], a
    pop     af
    reti

SECTION "OtherVectors", ROM0[$0048]
    DS $100 - $48, $00

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
    DB $03                  ; $0147 cart type: MBC1 + RAM + battery
    DB $01                  ; $0148 ROM: 64KB (4 banks)
    DB $02                  ; $0149 RAM: 8KB
    DB $01                  ; $014A non-Japanese
    DB $33                  ; $014B old licensee
    DB $01                  ; $014C version
    DB $00                  ; $014D header checksum (rgbfix -v fills)
    DW $0000                ; $014E-$014F global checksum

; ---------------------------------------------------------------------------
; HRAM
; ---------------------------------------------------------------------------
SECTION "HRAM", HRAM
hGBCFlag:    DS 1           ; A at boot ($11=GBC $01=DMG)
hVBlankFlag: DS 1           ; set by the VBlank ISR
hDMA:        DS 12          ; OAM DMA routine copy

; ---------------------------------------------------------------------------
; Entry Point $0150
; ---------------------------------------------------------------------------
SECTION "EntryPoint", ROM0[$150]

EntryPoint:
    di
    ; Save GBC flag in HRAM before anything clobbers A
    ldh     [hGBCFlag], a
    ld      sp, $FFFE

    ; Turn LCD off — wait for VBlank first (interrupts are not running yet)
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
    call    ZeroMem

    ; Zero VRAM bank 1 ($8000-$9FFF) — GBC attribute map (palette/flip/bank)
    ; Must be zeroed or tiles use random palettes from boot ROM
    ld      a, 1
    ld      [rVBK], a
    ld      hl, $8000
    ld      bc, $2000
    call    ZeroMem
    xor     a
    ld      [rVBK], a

    ; Zero WRAM ($C000-$DFFF)
    ld      hl, $C000
    ld      bc, $2000
    call    ZeroMem

    ; Now WRAM is clean — restore GBC flag and init variables
    ldh     a, [hGBCFlag]
    ld      [wIsGBC], a
    ld      a, STATE_TITLE
    ld      [wGameState], a
    ld      a, MAX_HEALTH
    ld      [wHealth], a
    call    LoadSave

    ; Scroll = 0
    xor     a
    ld      [rSCX], a
    ld      [rSCY], a

    ; Window off-screen until gameplay
    ld      a, WY_HIDDEN
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
    ld      de, hDMA
    ld      b, DMARoutineEnd - DMARoutine
.copyDMA:
    ld      a, [hl+]
    ld      [de], a
    inc     de
    dec     b
    jr      nz, .copyDMA

    ; Load tile + font + sprite data into VRAM (LCD is OFF)
    call    LoadTileData

    ; Setup GBC colour palettes
    call    SetupPalettes

    ; Draw title screen into tilemap (turns the LCD on at the end)
    call    DrawTitleScreen

    ; Seed joypad
    call    ReadJoypad
    call    ReadJoypad

    ; Init audio hardware and start title music
    call    AudioInit
    ld      a, SONG_TITLE
    call    MusicPlay

    ; VBlank interrupt drives frame sync from here on
    ld      a, IEF_VBLANK
    ld      [rIE], a
    xor     a
    ld      [rIF], a
    ei

; ===========================================================================
;  Main Loop
; ===========================================================================
MainLoop:
    call    WaitVBlank
    ; --- VBlank-only work: keep this block short ---
    ld      a, HIGH(wOAMBuf)
    call    hDMA
    call    FlushVRAMQueue
    call    StreamDialogRow
    ; --- the rest of the frame can run during active display ---
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
    jp      UpdateWin

; ===========================================================================
;  WaitVBlank — sleep until the VBlank ISR fires.
;  Returns immediately if the LCD is off (no VBlank interrupts then).
; ===========================================================================
WaitVBlank:
    ld      a, [rLCDC]
    bit     7, a
    ret     z
    xor     a
    ldh     [hVBlankFlag], a
.wait:
    halt
    ldh     a, [hVBlankFlag]
    or      a
    jr      z, .wait
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

; ZeroMem — zero BC bytes at HL
ZeroMem:
    xor     a
    ld      [hl+], a
    dec     bc
    ld      a, b
    or      c
    jr      nz, ZeroMem
    ret

; ===========================================================================
;  VRAM write queue
;  Game logic runs outside VBlank, where VRAM is not reliably accessible, so
;  tile changes during gameplay are queued and written at the start of the
;  next VBlank by FlushVRAMQueue.
; ===========================================================================

; QueueTile — HL = VRAM address, A = tile. Preserves BC, DE, HL.
; Writes straight through when the LCD is off.
QueueTile:
    push    bc
    push    de
    ld      c, a
    ld      a, [rLCDC]
    bit     7, a
    jr      nz, .lcdOn
    ld      [hl], c
    jr      .done
.lcdOn:
    ld      a, [wVQCount]
    cp      VQ_MAX
    jr      c, .room
    ; Queue full — drain it in the next VBlank, then carry on
    push    hl
    call    WaitVBlank
    call    FlushVRAMQueue
    pop     hl
    xor     a
.room:
    ld      b, a
    inc     a
    ld      [wVQCount], a
    ld      a, b
    add     a, a
    add     a, b            ; slot * 3
    ld      e, a
    ld      d, HIGH(wVQueue)
    ld      a, l
    ld      [de], a
    inc     e
    ld      a, h
    ld      [de], a
    inc     e
    ld      a, c
    ld      [de], a
.done:
    pop     de
    pop     bc
    ret

; FlushVRAMQueue — call during VBlank only
FlushVRAMQueue:
    ld      a, [wVQCount]
    or      a
    ret     z
    ld      b, a
    ld      hl, wVQueue
.loop:
    ld      a, [hl+]
    ld      e, a
    ld      a, [hl+]
    ld      d, a
    ld      a, [hl+]
    ld      [de], a
    dec     b
    jr      nz, .loop
    xor     a
    ld      [wVQCount], a
    ret

; ===========================================================================
;  Tilemap addressing
; ===========================================================================

; GetTileAddr — D=row E=col → HL = BG map VRAM address. Clobbers BC.
GetTileAddr:
    ld      a, d
    ld      h, 0
    ld      l, a
    add     hl, hl
    add     hl, hl
    add     hl, hl
    add     hl, hl
    add     hl, hl          ; row * 32
    ld      a, e
    ld      b, 0
    ld      c, a
    add     hl, bc
    ld      bc, $9800
    add     hl, bc
    ret

; GetMapAddr — D=row E=col → HL = &wZoneMap[row*20 + col]. Clobbers BC.
GetMapAddr:
    ld      a, d
    ld      h, 0
    ld      l, a
    add     hl, hl
    add     hl, hl          ; row * 4
    ld      b, h
    ld      c, l
    add     hl, hl
    add     hl, hl          ; row * 16
    add     hl, bc          ; row * 20
    ld      a, e
    ld      b, 0
    ld      c, a
    add     hl, bc
    ld      bc, wZoneMap
    add     hl, bc
    ret

; GetTile — D=row E=col → A = tile ID. Preserves DE.
; Outside the zone: rows below are solid, columns past either side are open
; (the side passages lead off-screen).
GetTile:
    ld      a, d
    cp      ZONE_ROWS
    jr      nc, .below
    ld      a, e
    cp      ZONE_COLS
    jr      nc, .side
    push    bc
    call    GetMapAddr
    pop     bc
    ld      a, [hl]
    ret
.below:
    ld      a, T_WALL
    ret
.side:
    ld      a, T_VOID
    ret

; SetMapTile — D=row E=col A=tile. Updates the WRAM map and queues the
; matching VRAM write. Preserves DE.
SetMapTile:
    push    bc
    push    af
    call    GetMapAddr
    pop     af
    ld      [hl], a
    push    af
    call    GetTileAddr
    pop     af
    pop     bc
    jp      QueueTile

; IsSolid — A = tile ID → NZ if solid (platforms and walls), Z if passable.
IsSolid:
    sub     T_PLAT_MID
    cp      T_WALL - T_PLAT_MID + 1
    sbc     a, a            ; $FF if solid, $00 if not
    ret

; ===========================================================================
;  Index helpers for the per-vuln arrays
; ===========================================================================

; IndexToMask — A = 0-7 → A = 1 << A. Preserves BC, DE, HL.
IndexToMask:
    push    hl
    ld      hl, MaskTable
    add     a, l
    ld      l, a
    adc     a, h
    sub     l
    ld      h, a
    ld      a, [hl]
    pop     hl
    ret

MaskTable:
    DB $01, $02, $04, $08, $10, $20, $40, $80

; VulnPtr / ExpPtr — A = index → HL = &wVulns[A] / &wExps[A] (zone, row, col).
; Preserve BC, DE.
VulnPtr:
    ld      hl, wVulns
    jr      IndexTriple
ExpPtr:
    ld      hl, wExps
IndexTriple:
    push    bc
    ld      c, a
    add     a, a
    add     a, c
    ld      c, a
    ld      b, 0
    add     hl, bc
    pop     bc
    ret

; DistToCol — A = tile col → A = |wPX - col*8|. Clobbers D.
DistToCol:
    add     a, a
    add     a, a
    add     a, a
    ld      d, a
    ld      a, [wPX]
    sub     d
    ret     nc
    cpl
    inc     a
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
    ld      a, WY_HIDDEN
    ld      [rWY], a
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
    ; Offer to wipe the save only when there is one
    ld      a, [wLevelComplete]
    or      a
    jr      z, .noSave
    ld      hl, $9A00       ; row 16
    ld      de, StrTitleErase
    call    PrintStr
.noSave:
    call    LCDOn           ; BG + window, no sprites
    ret

UpdateTitle:
    ld      a, [wJoypadNew]
    bit     PADB_SELECT, a
    jr      z, .noErase
    ld      a, [wLevelComplete]
    or      a
    jp      z, MainLoop
    xor     a
    ld      [wLevelComplete], a
    call    WriteSave
    call    DrawTitleScreen
    jp      MainLoop
.noErase:
    bit     PADB_START, a
    jp      z, MainLoop
    ld      a, STATE_INTRO
    ld      [wGameState], a
    xor     a
    ld      [wIntroPage], a
    call    DrawIntroPage
    jp      MainLoop

; ===========================================================================
;  Save data — wLevelComplete in battery-backed cartridge RAM
; ===========================================================================
LoadSave:
    ld      a, RAMG_ENABLE
    ld      [rRAMG], a
    ld      hl, sMagic
    ld      de, SaveMagic
    ld      b, 4
.check:
    ld      a, [de]
    cp      [hl]
    jr      nz, .done       ; blank or foreign SRAM — keep defaults
    inc     hl
    inc     de
    dec     b
    jr      nz, .check
    ld      a, [sLevelComplete]
    ld      b, a
    cpl
    ld      c, a
    ld      a, [sChecksum]
    cp      c
    jr      nz, .done
    ld      a, b
    and     ALL_LEVELS
    ld      [wLevelComplete], a
.done:
    xor     a
    ld      [rRAMG], a
    ret

WriteSave:
    ld      a, RAMG_ENABLE
    ld      [rRAMG], a
    ld      hl, sMagic
    ld      de, SaveMagic
    ld      b, 4
.magic:
    ld      a, [de]
    ld      [hl+], a
    inc     de
    dec     b
    jr      nz, .magic
    ld      a, [wLevelComplete]
    ld      [sLevelComplete], a
    cpl
    ld      [sChecksum], a
    xor     a
    ld      [rRAMG], a
    ret

SaveMagic:
    DB "SE01"

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
;  LOAD ZONE — build the WRAM map for wZone, then copy it to VRAM $9800
; ===========================================================================
LoadZone:
    call    LCDOff          ; safe — checks bit 7 first, waits for VBlank
    ; DE = zone data pointer from the per-level zone table
    ld      a, [wLvlZoneTable]
    ld      l, a
    ld      a, [wLvlZoneTable + 1]
    ld      h, a
    ld      a, [wZone]
    add     a, a            ; *2 for DW entries
    ld      c, a
    ld      b, 0
    add     hl, bc
    ld      a, [hl+]
    ld      e, a
    ld      d, [hl]

    ; ROM zone data → WRAM mirror
    ld      hl, wZoneMap
    ld      bc, ZONE_SIZE
.copyMap:
    ld      a, [de]
    ld      [hl+], a
    inc     de
    dec     bc
    ld      a, b
    or      c
    jr      nz, .copyMap

    call    ApplyZoneOverlays

    ; WRAM mirror (20 cols × 16 rows) → VRAM tilemap (32 cols wide)
    ld      de, wZoneMap
    ld      hl, $9800
    ld      b, ZONE_ROWS
.copyRow:
    ld      c, ZONE_COLS
.copyTile:
    ld      a, [de]
    ld      [hl+], a
    inc     de
    dec     c
    jr      nz, .copyTile
    ld      a, l
    add     32 - ZONE_COLS
    ld      l, a
    jr      nc, .noCarry
    inc     h
.noCarry:
    dec     b
    jr      nz, .copyRow

    ; Anything still queued was aimed at the previous screen
    xor     a
    ld      [wVQCount], a
    ld      [wScanActive], a
    ld      [wBeamLen], a

    ; Write HUD to window tilemap $9C00 (VRAM write — LCD still OFF)
    call    UpdateHUD

    xor     a
    ld      [rSCX], a
    ld      [rSCY], a
    ld      a, WY_HUD
    ld      [rWY], a

    ld      a, SPAWN_GRACE
    ld      [wSpawnGrace], a

    call    LCDOnPlay       ; turn LCD back on with sprites enabled
    ret

; ---------------------------------------------------------------------------
;  ApplyZoneOverlays — stamp level progress onto wZoneMap: scanned and
;  exploited vuln nodes, and exploit pickups still lying in this zone.
; ---------------------------------------------------------------------------
ApplyZoneOverlays:
    ld      c, 0
.loop:
    ld      a, [wNumVulns]
    cp      c
    ret     z
    ; Vuln node state
    ld      a, c
    call    VulnPtr
    ld      a, [wZone]
    cp      [hl]
    jr      nz, .exploit
    inc     hl
    ld      a, [hl+]
    ld      d, a            ; row
    ld      e, [hl]         ; col
    ld      a, c
    call    IndexToMask
    ld      b, a
    ld      a, [wVulnExploited]
    and     b
    ld      a, T_VULN_EXP
    jr      nz, .stampVuln
    ld      a, [wVulnScanned]
    and     b
    jr      z, .exploit
    ld      a, T_VULN_SCAN
.stampVuln:
    push    bc
    push    af
    call    GetMapAddr
    pop     af
    ld      [hl], a
    pop     bc
.exploit:
    ; Spawned, uncollected exploit pickup
    ld      a, c
    call    IndexToMask
    ld      b, a
    ld      a, [wExploitSpawned]
    and     b
    jr      z, .next
    ld      a, c
    call    ExpPtr
    ld      a, [wZone]
    cp      [hl]
    jr      nz, .next
    inc     hl
    ld      a, [hl+]
    ld      d, a
    ld      e, [hl]
    push    bc
    call    GetMapAddr
    ld      [hl], T_EXPLOIT
    pop     bc
.next:
    inc     c
    jr      .loop

; ===========================================================================
;  UpdateHUD — draw the whole HUD into window tilemap $9C00 (LCD off only)
;  Row 0: "LN " + zone name     Row 1: HP:N VULNS:N EXP:N
; ===========================================================================
UpdateHUD:
    ld      hl, $9C00
    ld      [hl], "L" - $20
    inc     hl
    ld      a, [wCurrentLevel]
    inc     a                   ; display 1-based
    add     a, T_DIGIT0
    ld      [hl+], a
    ld      [hl], T_SPACE
    ; Zone name: LvlZoneNamesTable[level][zone]
    ld      a, [wCurrentLevel]
    add     a, a
    ld      c, a
    ld      b, 0
    ld      hl, LvlZoneNamesTable
    add     hl, bc
    ld      a, [hl+]
    ld      h, [hl]
    ld      l, a                ; HL = this level's zone name table
    ld      a, [wZone]
    add     a, a
    ld      c, a
    add     hl, bc
    ld      a, [hl+]
    ld      e, a
    ld      d, [hl]
    ld      hl, $9C03
    call    PrintStrDirect

    ; Row 1 — labels, then the digits
    ld      hl, $9C20
    ld      de, StrHudHP
    call    PrintStrDirect
    ld      hl, $9C24
    ld      de, StrHudVulns
    call    PrintStrDirect
    ld      hl, $9C2C
    ld      de, StrHudCarry
    call    PrintStrDirect
    ; fall through

; QueueHUDStats — refresh the HP / VULNS / EXP digits. Safe at any time.
; Preserves BC, DE.
QueueHUDStats:
    push    bc
    ld      a, [wHealth]
    add     a, T_DIGIT0
    ld      hl, HUD_HP_ADDR
    call    QueueTile
    ; popcount of exploited vulns
    ld      a, [wVulnExploited]
    ld      b, T_DIGIT0
.count:
    or      a
    jr      z, .counted
    srl     a
    jr      nc, .count
    inc     b
    jr      .count
.counted:
    ld      a, b
    ld      hl, HUD_VULNS_ADDR
    call    QueueTile
    ld      a, [wExploitHeld]
    add     a, T_DIGIT0
    ld      hl, HUD_EXP_ADDR
    call    QueueTile
    pop     bc
    ret

; ===========================================================================
;  MAIN PLAY UPDATE
; ===========================================================================
UpdatePlay:
    ld      a, [wPlayerDown]
    or      a
    jr      z, .alive
    call    DrawPatchedScreen
    jp      MainLoop
.alive:
    call    TickPlayerTimers
    call    UpdatePlayerInput       ; may open a dialog or finish the level
    JP_UNLESS_STATE STATE_PLAY
    call    UpdatePlayerPhysics
    call    UpdateScan              ; may open the scan dialog
    JP_UNLESS_STATE STATE_PLAY
    call    CheckPickup             ; may open the pickup dialog
    JP_UNLESS_STATE STATE_PLAY
    call    UpdateAdvisories
    call    CheckAdvisoryCollision
    call    UpdateOAM
    jp      MainLoop

; TickPlayerTimers — count down spawn grace and i-frames
TickPlayerTimers:
    ld      hl, wSpawnGrace
    ld      a, [hl]
    or      a
    jr      z, .graceDone
    dec     [hl]
.graceDone:
    ld      hl, wInvuln
    ld      a, [hl]
    or      a
    ret     z
    dec     [hl]
    ret

; ---------------------------------------------------------------------------
;  DamagePlayer — B = attacker X. Costs 1 HP, knocks the player away from
;  the attacker and starts i-frames. At 0 HP sets wPlayerDown.
; ---------------------------------------------------------------------------
DamagePlayer:
    ld      a, [wInvuln]
    or      a
    ret     nz
    ld      a, [wSpawnGrace]
    or      a
    ret     nz
    ld      a, [wHealth]
    dec     a
    ld      [wHealth], a
    jr      nz, .survived
    ld      a, 1
    ld      [wPlayerDown], a
    jp      QueueHUDStats
.survived:
    ld      a, INVULN_FRAMES
    ld      [wInvuln], a
    ld      a, KNOCK_VY
    ld      [wPVY], a
    xor     a
    ld      [wPOnGround], a
    ld      [wCoyote], a
    ld      a, [wPX]
    cp      b
    ld      a, KNOCK_VX             ; player right of attacker → push right
    jr      nc, .setVX
    ld      a, 256 - KNOCK_VX
.setVX:
    ld      [wPVX], a
    jp      QueueHUDStats

; ===========================================================================
;  UpdatePlayerInput — steering, jumping and the B action
; ===========================================================================
UpdatePlayerInput:
    ; Knockback: steering is ignored for the first frames after a hit
    ld      a, [wInvuln]
    cp      INVULN_FRAMES - KNOCK_FRAMES + 1
    jr      nc, .doneH

    ld      a, [wJoypad]
    bit     PADB_LEFT, a
    jr      nz, .left
    bit     PADB_RIGHT, a
    jr      nz, .right

    ; No steering — friction toward 0
    ld      b, AIR_FRIC
    ld      a, [wPOnGround]
    or      a
    jr      z, .friction
    ld      b, GROUND_FRIC
.friction:
    ld      a, [wPVX]
    or      a
    jr      z, .doneH
    bit     7, a
    jr      nz, .fricNeg
    sub     b
    jr      nc, .setVX
    xor     a
    jr      .setVX
.fricNeg:
    add     b
    jr      nc, .setVX              ; still negative
    xor     a                       ; crossed zero
    jr      .setVX

.left:
    ld      a, 1
    ld      [wPFacing], a
    ld      b, RUN_ACCEL
    ld      a, [wPVX]
    or      a
    jr      z, .applyLeft
    bit     7, a
    jr      nz, .applyLeft
    ld      b, RUN_ACCEL + GROUND_FRIC  ; moving right: brake harder
.applyLeft:
    sub     b
    bit     7, a
    jr      z, .setVX               ; still positive (braking)
    cp      256 - RUN_MAX
    jr      nc, .setVX
    ld      a, 256 - RUN_MAX
    jr      .setVX

.right:
    xor     a
    ld      [wPFacing], a
    ld      b, RUN_ACCEL
    ld      a, [wPVX]
    bit     7, a
    jr      z, .applyRight
    ld      b, RUN_ACCEL + GROUND_FRIC  ; moving left: brake harder
.applyRight:
    add     b
    bit     7, a
    jr      nz, .setVX              ; still negative (braking)
    cp      RUN_MAX + 1
    jr      c, .setVX
    ld      a, RUN_MAX
.setVX:
    ld      [wPVX], a
.doneH:

    ; Jump — A press is buffered for a few frames, and a ledge jump is
    ; still allowed for a few frames after walking off (coyote time)
    ld      a, [wJoypadNew]
    bit     PADB_A, a
    jr      z, .noNewJump
    ld      a, JUMP_BUF_FRAMES
    ld      [wJumpBuf], a
.noNewJump:
    ld      a, [wJumpBuf]
    or      a
    jr      z, .jumpDone
    ld      a, [wPOnGround]
    or      a
    jr      nz, .jump
    ld      a, [wCoyote]
    or      a
    jr      z, .jumpDone
.jump:
    ld      a, JUMP_VY
    ld      [wPVY], a
    xor     a
    ld      [wPOnGround], a
    ld      [wCoyote], a
    ld      [wJumpBuf], a
.jumpDone:
    ; Variable jump height: releasing A cuts the rise short
    ld      a, [wJoypad]
    bit     PADB_A, a
    jr      nz, .riseDone
    ld      a, [wPVY]
    cp      128
    jr      c, .riseDone            ; not rising
    cp      JUMP_CUT_VY
    jr      nc, .riseDone           ; already slow
    ld      a, JUMP_CUT_VY
    ld      [wPVY], a
.riseDone:

    ; B button — scan or exploit-use depending on context, grounded only
    ld      a, [wPOnGround]
    or      a
    ret     z
    ld      a, [wJoypadNew]
    bit     PADB_B, a
    ret     z
    ld      a, [wExploitHeld]
    or      a
    jp      z, TryScan
    jp      TryExploit

; ===========================================================================
;  UpdatePlayerPhysics — gravity, integrate, collide
; ===========================================================================
UpdatePlayerPhysics:
    ; Gravity — add each frame; clamp only positive (downward) velocity to MAX_FALL
    ld      a, [wPVY]
    add     GRAVITY
    cp      128
    jr      nc, .setVY      ; negative (upward) — no clamp needed
    cp      MAX_FALL + 1
    jr      c, .setVY
    ld      a, MAX_FALL
.setVY:
    ld      [wPVY], a

    ; Integrate Y — clamp step to 8px either way so tiles can't be skipped
    cp      128
    jr      nc, .intYNeg
    cp      9
    jr      c, .intYStep
    ld      a, 8
    jr      .intYStep
.intYNeg:
    cp      248
    jr      nc, .intYStep
    ld      a, 248
.intYStep:
    ld      b, a
    ld      a, [wPY]
    add     b
    ; Clamp Y to screen bottom — tile collision sets OnGround
    cp      120
    jr      c, .yOK
    ld      a, 120
    ld      b, a
    xor     a
    ld      [wPVY], a
    ld      a, b
.yOK:
    ; Ceiling — only clamp if NOT in the vertical passage gap (X 64-87)
    cp      8
    jr      nc, .yFloor
    push    af
    ld      a, [wPX]
    cp      64
    jr      c, .hardCeiling
    cp      88
    jr      nc, .hardCeiling
    pop     af
    jr      .yFloor
.hardCeiling:
    pop     af
    xor     a
    ld      [wPVY], a
    ld      a, 8
.yFloor:
    ld      [wPY], a
    call    CheckTileCollisionY

    ; Integrate X: HL = sign-extended VX (1/16 px) + fraction
    ld      a, [wPVX]
    ld      l, a
    rla
    sbc     a, a
    ld      h, a
    ld      a, [wPXSub]
    ld      c, a
    ld      b, 0
    add     hl, bc
    ld      a, l
    and     $0F
    ld      [wPXSub], a
    sra     h
    rr      l
    sra     h
    rr      l
    sra     h
    rr      l
    sra     h
    rr      l
    ld      b, l            ; B = whole-pixel step (signed)
    ld      a, [wPX]
    add     b
    bit     7, b            ; (leaves carry intact)
    jr      z, .movedRight
    jr      c, .xPos        ; moved left without passing X=0
    xor     a               ; would wrap past the left edge
    jr      .stopX
.movedRight:
    cp      153
    jr      c, .xPos
    ld      a, 152
.stopX:
    ld      b, a
    xor     a
    ld      [wPVX], a
    ld      [wPXSub], a
    ld      a, b
.xPos:
    ld      [wPX], a
    call    CheckTileCollisionX
    call    CheckZoneTransition

    ; Coyote timer refills on the ground and drains in the air
    ld      a, [wPOnGround]
    or      a
    jr      z, .inAir
    ld      a, COYOTE_FRAMES
    ld      [wCoyote], a
    jr      .jumpBuf
.inAir:
    ld      hl, wCoyote
    ld      a, [hl]
    or      a
    jr      z, .jumpBuf
    dec     [hl]
.jumpBuf:
    ld      hl, wJumpBuf
    ld      a, [hl]
    or      a
    ret     z
    dec     [hl]
    ret

; ===========================================================================
;  CheckTileCollisionY
;  Checks the tile under the player's feet (wPY+16, wPX+4).
;  If solid: snap player on top, zero VY, set OnGround.
; ===========================================================================
CheckTileCollisionY:
    ld      a, [wPY]
    add     16
    srl     a
    srl     a
    srl     a
    ld      d, a            ; D = tile row
    ld      a, [wPX]
    add     4
    srl     a
    srl     a
    srl     a
    ld      e, a            ; E = tile col
    call    GetTile
    call    IsSolid
    jr      z, .noFloor
    ld      a, d
    add     a, a
    add     a, a
    add     a, a            ; row * 8 = top of that tile
    sub     16              ; player Y = tile_top - 16
    ld      [wPY], a
    xor     a
    ld      [wPVY], a
    inc     a
    ld      [wPOnGround], a
    ret
.noFloor:
    ; Falling (VY > 0) means we're airborne
    ld      a, [wPVY]
    or      a
    ret     z
    cp      128
    ret     nc
    xor     a
    ld      [wPOnGround], a
    ret

; ===========================================================================
;  CheckTileCollisionX
;  Checks the tile beside the player's body (wPY+8) in the direction of
;  travel and snaps against walls.
; ===========================================================================
CheckTileCollisionX:
    ld      a, [wPY]
    add     8
    srl     a
    srl     a
    srl     a
    ld      d, a
    ld      a, [wPVX]
    or      a
    ret     z
    cp      128
    jr      nc, .checkLeft
    ; Moving right — tile at wPX+8
    ld      a, [wPX]
    add     8
    srl     a
    srl     a
    srl     a
    ld      e, a
    call    GetTile
    call    IsSolid
    ret     z
    ld      a, e
    add     a, a
    add     a, a
    add     a, a
    sub     8
    jr      .snap
.checkLeft:
    ; Moving left — tile at wPX-1
    ld      a, [wPX]
    or      a
    ret     z
    dec     a
    srl     a
    srl     a
    srl     a
    ld      e, a
    call    GetTile
    call    IsSolid
    ret     z
    ld      a, e
    inc     a
    add     a, a
    add     a, a
    add     a, a
.snap:
    ld      [wPX], a
    xor     a
    ld      [wPVX], a
    ld      [wPXSub], a
    ret

; ===========================================================================
;  CheckZoneTransition — if player walks off edge, load adjacent zone
; ===========================================================================
CheckZoneTransition:
    ld      a, [wGameState]
    cp      STATE_BOSS
    ret     z               ; the boss arena is sealed
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

; GetAdjHL — D = direction offset (0=right, 1=left, 2=down, 3=up)
; Returns the adjacent zone in A ($FF = none) from the level's adjacency table.
GetAdjHL:
    ld      a, [wLvlAdjTable]
    ld      l, a
    ld      a, [wLvlAdjTable + 1]
    ld      h, a
    ld      a, [wZone]
    add     a, a
    add     a, a            ; zone * 4
    add     a, d
    ld      c, a
    ld      b, 0
    add     hl, bc
    ld      a, [hl]
    ret

; EnterZone — A = zone, B = spawn X, C = spawn Y
EnterZone:
    ld      [wZone], a
    ld      a, b
    ld      [wPX], a
    ld      a, c
    ld      [wPY], a
    xor     a
    ld      [wPVX], a
    ld      [wPXSub], a
    ld      [wPVY], a
    jp      LoadZone

TransitionRight:
    ld      d, 0
    call    GetAdjHL
    cp      $FF
    ret     z
    ld      bc, (20 << 8) | 72  ; spawn just inside left opening
    jr      EnterZone

TransitionLeft:
    ld      d, 1
    call    GetAdjHL
    cp      $FF
    ret     z
    ld      bc, (132 << 8) | 72 ; spawn just inside right opening
    jr      EnterZone

TransitionDown:
    ld      d, 2
    call    GetAdjHL
    cp      $FF
    ret     z
    ld      bc, (48 << 8) | 16  ; spawn below top wall, left of gap
    jr      EnterZone

TransitionUp:
    ld      d, 3
    call    GetAdjHL
    cp      $FF
    ret     z
    ld      bc, (48 << 8) | 56  ; spawn above floor, left of gap
    jr      EnterZone

; ===========================================================================
;  SCANNING
;  B (grounded, empty-handed) near an unscanned vuln node fires the scan
;  beam in the facing direction. The beam is drawn over the BG one tile per
;  frame, stops at the first solid tile, and is restored from wZoneMap when
;  the scan ends. In the boss fight the beam damages PATCH.EXE on contact.
; ===========================================================================
DEF SCAN_BOSS EQU $FF       ; wScanVulnIdx value for the boss-fight scan

TryScan:
    ld      a, [wScanActive]
    or      a
    ret     nz
    ld      a, [wGameState]
    cp      STATE_BOSS
    jr      nz, .vulns
    ; Boss fight: only fire on (roughly) the boss's floor
    ld      a, [wPY]
    sub     BOSS_Y
    jr      nc, .vOK
    cpl
    inc     a
.vOK:
    cp      24
    ret     nc
    ld      a, SCAN_BOSS
    jr      BeginScan
.vulns:
    ld      c, 0
.loop:
    ld      a, [wNumVulns]
    cp      c
    ret     z
    ld      a, c
    call    VulnPtr
    ld      a, [wZone]
    cp      [hl]
    jr      nz, .next
    ld      a, c
    call    IndexToMask
    ld      b, a
    ld      a, [wVulnScanned]
    and     b
    jr      nz, .next
    inc     hl
    inc     hl
    ld      a, [hl]         ; col
    call    DistToCol
    cp      SCAN_REACH
    jr      nc, .next
    ld      a, c
    jr      BeginScan
.next:
    inc     c
    jr      .loop

; BeginScan — A = vuln index (or SCAN_BOSS)
BeginScan:
    ld      [wScanVulnIdx], a
    ld      a, SCAN_FRAMES
    ld      [wScanTimer], a
    ld      a, 1
    ld      [wScanActive], a
    xor     a
    ld      [wBeamLen], a
    ld      a, [wPFacing]
    ld      [wScanDir], a
    ; Beam runs along the player's body row, starting next to their centre
    ld      a, [wPY]
    add     8
    srl     a
    srl     a
    srl     a
    ld      [wScanRow], a
    ld      d, a
    ld      a, [wPX]
    add     4
    srl     a
    srl     a
    srl     a
    ld      [wScanCol], a
    ld      e, a
    ; Measure how far the beam can go before something solid
    ld      b, 0
.measure:
    call    StepBeamCol
    jr      c, .measured
    call    GetTile
    call    IsSolid
    jr      nz, .measured
    inc     b
    ld      a, b
    cp      SCAN_TILES
    jr      c, .measure
.measured:
    ld      a, b
    ld      [wBeamMax], a
    ret

; StepBeamCol — move E one tile in the scan direction; carry if off the zone
StepBeamCol:
    ld      a, [wScanDir]
    or      a
    jr      nz, .left
    inc     e
    ld      a, e
    cp      ZONE_COLS
    ccf
    ret
.left:
    ld      a, e
    or      a
    scf
    ret     z
    dec     e
    and     a               ; clear carry (A is non-zero)
    ret

; BeamTilePos — A = beam tile index → D = row, E = col. Clobbers B.
BeamTilePos:
    inc     a
    ld      b, a
    ld      a, [wScanRow]
    ld      d, a
    ld      a, [wScanDir]
    or      a
    ld      a, [wScanCol]
    jr      nz, .left
    add     b
    ld      e, a
    ret
.left:
    sub     b
    ld      e, a
    ret

; ===========================================================================
;  UpdateScan — advance the scan beam
; ===========================================================================
UpdateScan:
    ld      a, [wScanActive]
    or      a
    ret     z

    ; Grow the beam by one tile per frame up to its measured length
    ld      a, [wBeamMax]
    ld      c, a
    ld      a, [wBeamLen]
    cp      c
    jr      nc, .grown
    ld      c, a
    inc     a
    ld      [wBeamLen], a
    ld      a, c
    call    BeamTilePos
    call    GetTileAddr
    ld      a, T_BEAM_FULL
    call    QueueTile
.grown:
    ld      a, [wScanVulnIdx]
    cp      SCAN_BOSS
    jr      nz, .tick
    ; Boss fight: the beam has to actually touch PATCH.EXE
    call    BeamHitsBoss
    jr      nc, .tick
    call    EndScan
    jp      BossTakeScanHit
.tick:
    ld      hl, wScanTimer
    dec     [hl]
    ret     nz
    call    EndScan
    ld      a, [wScanVulnIdx]
    cp      SCAN_BOSS
    ret     z               ; boss scan missed

    ; Vuln scanned: mark it, spawn its exploit, tell the player
    call    IndexToMask
    ld      b, a
    ld      a, [wVulnScanned]
    or      b
    ld      [wVulnScanned], a
    ld      a, [wScanVulnIdx]
    ld      b, T_VULN_SCAN
    call    SetVulnTile
    ld      a, [wScanVulnIdx]
    call    SpawnExploit
    jp      ShowScanDialog

; EndScan — stop the scan and restore the tiles under the beam
EndScan:
    xor     a
    ld      [wScanActive], a
    ld      a, [wBeamLen]
    or      a
    ret     z
    ld      c, a
.restore:
    dec     c
    ld      a, c
    call    BeamTilePos
    push    bc
    call    GetMapAddr
    ld      a, [hl]
    push    af
    call    GetTileAddr
    pop     af
    pop     bc
    call    QueueTile
    ld      a, c
    or      a
    jr      nz, .restore
    ld      [wBeamLen], a
    ret

; BeamHitsBoss — carry if the drawn beam covers PATCH.EXE's tile
BeamHitsBoss:
    ld      a, [wBossHP]
    or      a
    ret     z
    ld      a, [wScanRow]
    cp      BOSS_Y / 8
    jr      nz, .miss
    ld      a, [wBeamLen]
    or      a
    jr      z, .miss
    ld      c, a
    ld      a, [wBossX]
    add     4
    srl     a
    srl     a
    srl     a
    ld      b, a            ; B = boss centre col
    ld      a, [wScanCol]
    ld      d, a
    ld      a, [wScanDir]
    or      a
    jr      nz, .left
    ld      a, b
    sub     d               ; tiles to the right of the start
    jr      .inRange
.left:
    ld      a, d
    sub     b               ; tiles to the left of the start
.inRange:
    ; hit if 1 <= distance <= beam length (negative wraps high → miss)
    or      a
    jr      z, .miss
    dec     a
    cp      c
    ret
.miss:
    and     a
    ret

; SetVulnTile — A = vuln index, B = tile. Updates the node's BG tile if it
; is in the current zone.
SetVulnTile:
    call    VulnPtr
    ld      a, [wZone]
    cp      [hl]
    ret     nz
    inc     hl
    ld      a, [hl+]
    ld      d, a
    ld      e, [hl]
    ld      a, b
    jp      SetMapTile

; SpawnExploit — A = vuln index. Marks the exploit as lying in the world and
; draws it if it spawned in the current zone.
SpawnExploit:
    ld      c, a
    call    IndexToMask
    ld      b, a
    ld      a, [wExploitSpawned]
    or      b
    ld      [wExploitSpawned], a
    ld      a, c
    call    ExpPtr
    ld      a, [wZone]
    cp      [hl]
    ret     nz
    inc     hl
    ld      a, [hl+]
    ld      d, a
    ld      e, [hl]
    ld      a, T_EXPLOIT
    jp      SetMapTile

; GetVulnStringPair — returns DE=name ptr, HL=desc ptr for wScanVulnIdx
; Table index = wCurrentLevel * 3 + vuln index
GetVulnStringPair:
    ld      a, [wScanVulnIdx]
    call    LevelVulnSlot
    add     a, a
    add     a, a            ; 4 bytes per entry (DW name, DW desc)
    ld      hl, LvlVulnNameTable
    ld      c, a
    ld      b, 0
    add     hl, bc
    ld      a, [hl+]
    ld      e, a
    ld      a, [hl+]
    ld      d, a
    ld      a, [hl+]
    ld      h, [hl]
    ld      l, a
    ret

; GetExpString — A = vuln index → DE = exploit tool name
GetExpString:
    call    LevelVulnSlot
    add     a, a            ; DW table
    ld      hl, LvlExpNameTable
    ld      c, a
    ld      b, 0
    add     hl, bc
    ld      a, [hl+]
    ld      e, a
    ld      d, [hl]
    ret

; LevelVulnSlot — A = vuln index → A = wCurrentLevel * MAX_VULNS + index
LevelVulnSlot:
    ld      b, a
    ld      a, [wCurrentLevel]
    ld      c, a
    add     a, a
    add     a, c
    add     a, b
    ret

; ===========================================================================
;  TryExploit — B at a scanned vuln node while holding its exploit
; ===========================================================================
TryExploit:
    ld      a, [wExploitHeld]
    or      a
    ret     z
    dec     a
    ld      c, a            ; C = vuln index this exploit is for
    call    VulnPtr
    ld      a, [wZone]
    cp      [hl]
    ret     nz
    ld      a, c
    call    IndexToMask
    ld      b, a            ; B = vuln bit
    ld      a, [wVulnScanned]
    and     b
    ret     z
    inc     hl
    inc     hl
    ld      a, [hl]
    call    DistToCol
    cp      SCAN_REACH
    ret     nc

    ld      a, [wVulnExploited]
    or      b
    ld      [wVulnExploited], a
    xor     a
    ld      [wExploitHeld], a
    push    bc
    ld      a, c
    ld      b, T_VULN_EXP
    call    SetVulnTile
    call    QueueHUDStats
    pop     bc

    ; Level complete once every vuln node is exploited
    ld      a, [wNumVulns]
    call    IndexToMask
    dec     a               ; (1 << numVulns) - 1
    ld      b, a
    ld      a, [wVulnExploited]
    cp      b
    jp      z, DrawWinScreen
    ld      a, c
    jp      ShowExploitDialog

; ===========================================================================
;  CheckPickup — auto-collect an exploit when the player's body touches it
; ===========================================================================
CheckPickup:
    ld      a, [wExploitHeld]
    or      a
    ret     nz              ; already holding one
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

    ; Which exploit is this? Match zone + position
    ld      c, 0
.loop:
    ld      a, [wNumVulns]
    cp      c
    ret     z
    ld      a, c
    call    IndexToMask
    ld      b, a
    ld      a, [wExploitSpawned]
    and     b
    jr      z, .next
    ld      a, c
    call    ExpPtr
    ld      a, [wZone]
    cp      [hl]
    jr      nz, .next
    inc     hl
    ld      a, [hl+]
    cp      d
    jr      nz, .next
    ld      a, [hl]
    cp      e
    jr      z, .collect
.next:
    inc     c
    jr      .loop
.collect:
    ; Clear the spawned bit so the pickup stays gone after the dialog
    ld      a, b
    cpl
    ld      b, a
    ld      a, [wExploitSpawned]
    and     b
    ld      [wExploitSpawned], a
    ld      a, c
    inc     a
    ld      [wExploitHeld], a
    push    bc
    ld      a, T_VOID
    call    SetMapTile
    call    QueueHUDStats
    pop     bc
    ld      a, c
    jp      ShowPickupDialog

; ===========================================================================
;  DIALOG PANEL
;  Dialogs are drawn into window rows 2-7 and revealed by lowering WY, so
;  the zone stays on screen behind them. wDlgBuf is filled by DialogLine and
;  streamed to VRAM one row per VBlank by StreamDialogRow.
; ===========================================================================

; DialogOpen — clear the panel buffer and enter STATE_DIALOG
DialogOpen:
    ld      a, STATE_DIALOG
    ld      [wGameState], a
    ld      a, DLG_ROWS     ; nothing to stream until DialogShow
    ld      [wDlgRow], a
    ld      hl, wDlgBuf
    ld      b, DLG_ROWS * ZONE_COLS
    xor     a
.clear:
    ld      [hl+], a
    dec     b
    jr      nz, .clear
    ; Hide sprites the panel will cover (OAM Y > WY_DIALOG + 8)
    ld      hl, wOAMBuf
    ld      b, 40
.hide:
    ld      a, [hl]
    cp      WY_DIALOG + 9
    jr      c, .keep
    xor     a
    ld      [hl], a
.keep:
    inc     l
    inc     l
    inc     l
    inc     l
    dec     b
    jr      nz, .hide
    ret

; DialogLine — B = panel row (0-5), DE = string. Clobbers C, HL.
DialogLine:
    ld      a, b
    add     a, a
    add     a, a
    ld      c, a
    add     a, a
    add     a, a
    add     a, c            ; row * 20
    ld      hl, wDlgBuf
    add     a, l
    ld      l, a
    adc     a, h
    sub     l
    ld      h, a
    ld      c, ZONE_COLS
.copy:
    ld      a, [de]
    or      a
    ret     z
    sub     $20
    ld      [hl+], a
    inc     de
    dec     c
    jr      nz, .copy
    ret

; DialogShow — start streaming the panel to the window
DialogShow:
    xor     a
    ld      [wDlgRow], a
    ret

; StreamDialogRow — VBlank only. Copies one panel row to window row 2+N;
; after the last row, raises the panel.
StreamDialogRow:
    ld      a, [wDlgRow]
    cp      DLG_ROWS
    ret     nc
    ld      b, a
    inc     a
    ld      [wDlgRow], a
    ; DE = wDlgBuf + row * 20
    ld      a, b
    add     a, a
    add     a, a
    ld      c, a
    add     a, a
    add     a, a
    add     a, c
    ld      hl, wDlgBuf
    add     a, l
    ld      e, a
    adc     a, h
    sub     e
    ld      d, a
    ; HL = $9C00 + (row + 2) * 32
    ld      a, b
    add     2
    swap    a               ; *16
    add     a, a            ; *32 (row + 2 <= 7, fits in a byte)
    ld      l, a
    ld      h, $9C
    ld      c, ZONE_COLS
.copy:
    ld      a, [de]
    ld      [hl+], a
    inc     de
    dec     c
    jr      nz, .copy
    ld      a, b
    cp      DLG_ROWS - 1
    ret     nz
    ld      a, WY_DIALOG
    ld      [rWY], a
    ret

; UpdateDialog — A closes the panel once it is fully drawn
UpdateDialog:
    ld      a, [wDlgRow]
    cp      DLG_ROWS
    jp      c, MainLoop
    ld      a, [wJoypadNew]
    bit     PADB_A, a
    jp      z, MainLoop
    ld      a, WY_HUD
    ld      [rWY], a
    ld      a, STATE_PLAY
    ld      [wGameState], a
    jp      MainLoop

ShowScanDialog:
    call    DialogOpen
    ld      b, 0
    ld      de, StrScanHit
    call    DialogLine
    call    GetVulnStringPair   ; DE = CVE id, HL = description
    push    hl
    ld      b, 1
    call    DialogLine
    pop     de
    ld      b, 2
    call    DialogLine
    ld      a, [wScanVulnIdx]
    call    GetExpString
    ld      b, 3
    call    DialogLine
    ld      b, 5
    ld      de, StrDismiss
    call    DialogLine
    jp      DialogShow

; ShowPickupDialog — A = vuln index the exploit belongs to
ShowPickupDialog:
    push    af
    call    DialogOpen
    ld      b, 0
    ld      de, StrPickedUp
    call    DialogLine
    pop     af
    call    GetExpString
    ld      b, 1
    call    DialogLine
    ld      b, 5
    ld      de, StrDismiss
    call    DialogLine
    jp      DialogShow

; ShowExploitDialog — A = vuln index that was exploited
ShowExploitDialog:
    push    af
    call    DialogOpen
    ld      b, 0
    ld      de, StrExploited
    call    DialogLine
    pop     af
    call    GetExpString
    ld      b, 1
    call    DialogLine
    ld      b, 5
    ld      de, StrDismiss
    call    DialogLine
    jp      DialogShow

; ===========================================================================
;  DrawWinScreen — mark level complete, save, go to map (or boss if all done)
; ===========================================================================
DrawWinScreen:
    ld      a, [wCurrentLevel]
    call    IndexToMask
    ld      b, a
    ld      a, [wLevelComplete]
    or      b
    ld      [wLevelComplete], a
    call    WriteSave
    ld      a, [wLevelComplete]
    cp      ALL_LEVELS
    jp      z, DrawBossScreen
    jp      DrawMapScreen

; DrawFinalWin — shown when boss is defeated
DrawFinalWin:
    ld      a, STATE_WIN
    ld      [wGameState], a
    ld      a, SONG_OFF
    call    MusicPlay
    call    LCDOff
    call    ClearBG
    ld      a, WY_HIDDEN
    ld      [rWY], a
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
    ld      hl, $9980
    ld      de, StrWinPrompt
    call    PrintStr
    call    LCDOn
    ret

; UpdateWin — Start returns to the title screen
UpdateWin:
    ld      a, [wJoypadNew]
    bit     PADB_START, a
    jp      z, MainLoop
    ld      a, STATE_TITLE
    ld      [wGameState], a
    call    DrawTitleScreen
    ld      a, SONG_TITLE
    call    MusicPlay
    jp      MainLoop

; ===========================================================================
;  InitLevel — A = level index (0-4)
;  Loads level data from LevelTable into WRAM, resets progress, loads the
;  start zone and starts the gameplay music.
; ===========================================================================
InitLevel:
    ld      [wCurrentLevel], a
    add     a, a
    ld      hl, LevelTable
    ld      c, a
    ld      b, 0
    add     hl, bc
    ld      a, [hl+]
    ld      h, [hl]
    ld      l, a            ; HL = LevelNData

    ld      a, [hl+]
    ld      [wNumZones], a
    ld      a, [hl+]
    ld      [wNumVulns], a
    ld      a, [hl+]
    ld      [wLvlZoneTable], a
    ld      a, [hl+]
    ld      [wLvlZoneTable + 1], a
    ld      a, [hl+]
    ld      [wLvlAdjTable], a
    ld      a, [hl+]
    ld      [wLvlAdjTable + 1], a

    ; Unused vuln/exploit slots stay zeroed
    push    hl
    ld      hl, wVulns
    ld      bc, wVulnsEnd - wVulns
    call    ZeroMem
    pop     hl
    ld      de, wVulns
    call    CopyVulnTriples
    ld      de, wExps
    call    CopyVulnTriples

    ld      a, [hl+]
    ld      [wLvlStartZone], a
    ld      a, [hl+]
    ld      [wLvlStartX], a
    ld      a, [hl]
    ld      [wLvlStartY], a

    ; Fresh gameplay state
    ld      a, STATE_PLAY
    ld      [wGameState], a
    ld      a, [wLvlStartX]
    ld      [wPX], a
    ld      a, [wLvlStartY]
    ld      [wPY], a
    ld      a, [wLvlStartZone]
    ld      [wZone], a
    xor     a
    ld      [wPXSub], a
    ld      [wPVX], a
    ld      [wPVY], a
    ld      [wPFacing], a
    ld      [wPOnGround], a
    ld      [wCoyote], a
    ld      [wJumpBuf], a
    ld      [wInvuln], a
    ld      [wPlayerDown], a
    ld      [wScanActive], a
    ld      [wVulnScanned], a
    ld      [wVulnExploited], a
    ld      [wExploitSpawned], a
    ld      [wExploitHeld], a
    ld      [wAdvCount], a
    ld      a, MAX_HEALTH
    ld      [wHealth], a
    call    InitAdvisories
    call    LoadZone
    ld      a, SONG_PLAY
    jp      MusicPlay

; CopyVulnTriples — copy wNumVulns × 3 bytes from HL to DE (advances HL)
CopyVulnTriples:
    ld      a, [wNumVulns]
    ld      b, a
    add     a, a
    add     a, b
    ld      b, a
.copy:
    ld      a, [hl+]
    ld      [de], a
    inc     de
    dec     b
    jr      nz, .copy
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
; ---------------------------------------------------------------------------
;  CheckAdvisoryCollision — damage the player if they overlap an advisory in
;  the current zone. Player box: (wPX, wPY) 8×16. Advisory box: (X, 64) 8×8.
; ---------------------------------------------------------------------------
CheckAdvisoryCollision:
    ld      a, [wAdvCount]
    or      a
    ret     z
    ld      b, a
    ld      hl, wAdv0X
.loop:
    ld      a, [hl+]        ; X
    ld      c, a
    inc     hl
    inc     hl
    ld      a, [hl+]        ; Zone (HL now at next struct)
    ld      d, a
    ld      a, [wZone]
    cp      d
    jr      nz, .next
    ; abs(playerX - advX) < 8
    ld      a, [wPX]
    sub     c
    jr      nc, .posH
    cpl
    inc     a
.posH:
    cp      8
    jr      nc, .next
    ; advisory Y is always 64; abs(playerY - 64) < 16
    ld      a, [wPY]
    sub     64
    jr      nc, .posV
    cpl
    inc     a
.posV:
    cp      16
    jr      nc, .next
    ld      b, c
    jp      DamagePlayer
.next:
    dec     b
    jr      nz, .loop
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
;  Shown when the player runs out of HP. A returns to the world map.
; ===========================================================================
DrawPatchedScreen:
    ld      a, [wGameState]
    cp      STATE_BOSS
    ld      de, StrPatched2
    jr      nz, .gotCause
    ld      de, StrPatched2Boss
.gotCause:
    push    de
    ld      a, STATE_PATCHED
    ld      [wGameState], a
    xor     a
    ld      [wPlayerDown], a
    call    LCDOff
    call    ClearBG
    ld      a, WY_HIDDEN
    ld      [rWY], a
    ld      hl, $9840
    ld      de, StrPatched1
    call    PrintStr
    pop     de
    ld      hl, $9880
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
    bit     PADB_A, a
    jp      z, MainLoop
    call    DrawMapScreen
    ld      a, SONG_TITLE
    call    MusicPlay
    jp      MainLoop

; ===========================================================================
;  Boss fight — PATCH
;  PATCH.EXE charges back and forth along the floor. Touching it costs HP;
;  three beam hits destroy it.
; ===========================================================================

; Boss Y is fixed at 80 (floor) — no WRAM field needed
DEF BOSS_Y EQU 80

DrawBossScreen:
    ; Borrow level 5's first zone as the arena
    ld      a, [wCurrentLevel]
    push    af
    ld      a, NUM_LEVELS - 1
    call    InitLevel
    pop     af
    ld      [wCurrentLevel], a
    ld      a, STATE_BOSS
    ld      [wGameState], a
    xor     a
    ld      [wAdvCount], a      ; no advisories during boss fight
    ld      [wBossHitTimer], a
    ld      [wKonamiStep], a
    ld      a, 120
    ld      [wBossX], a
    ld      a, 255
    ld      [wBossVX], a
    ld      a, BOSS_MAX_HP
    ld      [wBossHP], a
    ld      a, 16
    ld      [wPX], a
    ld      a, 72
    ld      [wPY], a
    ; Boss title over the top wall row
    call    LCDOff
    ld      hl, $9800
    ld      de, StrBossTitle
    call    PrintStr
    call    LCDOnPlay
    ld      a, SONG_BOSS
    jp      MusicPlay

UpdateBossScreen:
    ld      a, [wPlayerDown]
    or      a
    jr      z, .alive
    call    DrawPatchedScreen
    jp      MainLoop
.alive:
    call    TickPlayerTimers
    call    UpdatePlayerInput
    call    UpdatePlayerPhysics
    call    UpdateScan          ; may defeat the boss
    JP_UNLESS_STATE STATE_BOSS
    ld      hl, wBossHitTimer
    ld      a, [hl]
    or      a
    jr      z, .move
    dec     [hl]
.move:
    ld      a, [wBossX]
    ld      b, a
    ld      a, [wBossVX]
    add     b
    cp      137
    jr      nc, .bounceR
    cp      8
    jr      nc, .setX
    ld      a, 1
    ld      [wBossVX], a
    ld      a, 8
    jr      .setX
.bounceR:
    ld      a, 255
    ld      [wBossVX], a
    ld      a, 136
.setX:
    ld      [wBossX], a
    ; Contact: abs(playerX - bossX) < 6 AND abs(playerY - BOSS_Y) < 10
    ld      a, [wBossHP]
    or      a
    jr      z, .draw
    ld      a, [wBossX]
    ld      b, a
    ld      a, [wPX]
    sub     b
    jr      nc, .absH
    cpl
    inc     a
.absH:
    cp      6
    jr      nc, .draw
    ld      a, [wPY]
    sub     BOSS_Y
    jr      nc, .absV
    cpl
    inc     a
.absV:
    cp      10
    jr      nc, .draw
    call    DamagePlayer        ; B = boss X
.draw:
    call    UpdateOAM
    ld      a, [wBossHP]
    or      a
    jp      z, MainLoop
    ld      a, [wBossHitTimer]
    and     %00000010           ; flash after a hit
    jp      nz, MainLoop
    ld      hl, wOAMBuf + (OAM_BOSS_HEAD * 4)
    ld      a, BOSS_Y + 16
    ld      [hl+], a
    ld      a, [wBossX]
    add     8
    ld      [hl+], a
    ld      a, SPR_BOSS_HEAD
    ld      [hl+], a
    ld      [hl], $01
    jp      MainLoop

; BossTakeScanHit — one beam hit on PATCH.EXE
BossTakeScanHit:
    ld      a, [wBossHP]
    or      a
    ret     z
    dec     a
    ld      [wBossHP], a
    jp      z, DrawFinalWin
    ld      a, 24
    ld      [wBossHitTimer], a
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
    ld      a, WY_HIDDEN
    ld      [rWY], a
    xor     a
    ld      [wKonamiStep], a

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
    call    IndexToMask
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
    ld      hl, $9A20       ; row 17 (last visible row)
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

    ; Every level cleared: offer the boss fight
    ld      a, [wLevelComplete]
    cp      ALL_LEVELS
    jr      nz, .dm_done
    ld      hl, $9A00
    ld      de, StrMapBoss
    call    PrintStr
.dm_done:
    call    LCDOn
    ret

; MapCursorAddr — HL = VRAM address one row above the current map node
MapCursorAddr:
    ld      a, [wMapCursor]
    add     a, a
    ld      hl, MapNodePositions
    ld      c, a
    ld      b, 0
    add     hl, bc
    ld      a, [hl+]
    dec     a
    ld      d, a
    ld      e, [hl]
    jp      GetTileAddr

; DrawMapCursor / EraseMapCursor — work with the LCD on or off
DrawMapCursor:
    call    MapCursorAddr
    ld      a, T_WALL
    jp      QueueTile

EraseMapCursor:
    call    MapCursorAddr
    ld      a, T_SPACE
    jp      QueueTile

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

; CheckKonami — call each frame on the map screen. Returns carry when the
; sequence has just been completed.
CheckKonami:
    ld      a, [wJoypadNew]
    or      a
    ret     z               ; no new press (carry clear)
    ld      b, a
    ld      hl, KonamiSequence
    ld      a, [wKonamiStep]
    ld      e, a
    ld      d, 0
    add     hl, de
    ld      a, b
    cp      [hl]            ; exactly the expected button?
    jr      nz, .reset
    ld      a, e
    inc     a
    ld      [wKonamiStep], a
    cp      10
    jr      z, .complete
    and     a
    ret
.complete:
    xor     a
    ld      [wKonamiStep], a
    scf
    ret
.reset:
    ; A wrong press may still be the first step of a new attempt
    ld      a, [KonamiSequence]
    cp      b
    ld      a, 0
    jr      nz, .store
    inc     a
.store:
    ld      [wKonamiStep], a
    and     a
    ret

; ===========================================================================
;  UpdateMapScreen — runs each frame in STATE_MAP
; ===========================================================================
UpdateMapScreen:
    call    CheckKonami
    jr      nc, .noCheat
    call    DrawBossScreen
    jp      MainLoop
.noCheat:
    ld      a, [wJoypadNew]
    bit     PADB_START, a
    jr      z, .noStart
    ; All five levels cleared: Start faces PATCH.EXE
    ld      a, [wLevelComplete]
    cp      ALL_LEVELS
    jp      nz, MainLoop
    call    DrawBossScreen
    jp      MainLoop
.noStart:
    bit     PADB_LEFT, a
    jr      z, .noLeft
    call    EraseMapCursor
    ld      a, [wMapCursor]
    or      a
    jr      nz, .decCursor
    ld      a, NUM_LEVELS
.decCursor:
    dec     a
    jr      .moved
.noLeft:
    bit     PADB_RIGHT, a
    jr      z, .noRight
    call    EraseMapCursor
    ld      a, [wMapCursor]
    inc     a
    cp      NUM_LEVELS
    jr      c, .moved
    xor     a
.moved:
    ld      [wMapCursor], a
    call    DrawMapCursor
    jp      MainLoop
.noRight:
    bit     PADB_A, a
    jp      z, MainLoop
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

    ; Blink while invulnerable after a hit
    ld      a, [wInvuln]
    or      a
    jr      z, .visible
    ld      a, [wFrame]
    and     %00000100
    jr      z, .visible
    xor     a
    ld      [wOAMBuf + OAM_PLAYER_HEAD * 4], a
    ld      [wOAMBuf + OAM_PLAYER_BODY * 4], a
.visible:

    ; Vuln node sprites (pulse animation)
    call    UpdateVulnSprites

    ; Exploit pickup sprites
    call    UpdateExploitSprites

    ; Advisory enemy sprites
    call    UpdateAdvisorySprites
    ret


; UpdateVulnSprites — pulsing sprite on each unexploited vuln node in this zone
UpdateVulnSprites:
    ld      c, 0
.loop:
    ld      a, [wNumVulns]
    cp      c
    ret     z
    ld      a, c
    call    IndexToMask
    ld      b, a
    ld      a, [wVulnExploited]
    and     b
    jr      nz, .next
    ld      a, c
    call    VulnPtr
    ld      a, [wZone]
    cp      [hl]
    jr      nz, .next
    inc     hl
    ld      a, [hl+]
    ld      d, a            ; row
    ld      e, [hl]         ; col
    ld      b, SPR_VULN_A
    ld      a, [wFrame]
    and     %00001000
    jr      z, .gotTile
    ld      b, SPR_VULN_B
.gotTile:
    ld      a, c
    add     OAM_VULN0
    call    PutTileSprite
    ld      [hl], $01       ; OBJ palette 1
.next:
    inc     c
    jr      .loop

; UpdateExploitSprites — sprite on each spawned exploit pickup in this zone
UpdateExploitSprites:
    ld      c, 0
.loop:
    ld      a, [wNumVulns]
    cp      c
    ret     z
    ld      a, c
    call    IndexToMask
    ld      b, a
    ld      a, [wExploitSpawned]
    and     b
    jr      z, .next
    ld      a, c
    call    ExpPtr
    ld      a, [wZone]
    cp      [hl]
    jr      nz, .next
    inc     hl
    ld      a, [hl+]
    ld      d, a
    ld      e, [hl]
    ld      a, c
    add     SPR_EXP_PICK    ; one icon per exploit slot
    ld      b, a
    ld      a, c
    add     OAM_EXP0
    call    PutTileSprite
    ld      [hl], $02       ; OBJ palette 2
.next:
    inc     c
    jr      .loop

; PutTileSprite — A = OAM slot, B = tile, D = tile row, E = tile col.
; Writes Y, X, tile; returns HL at the attribute byte. Preserves C.
PutTileSprite:
    add     a, a
    add     a, a
    ld      l, a
    ld      h, HIGH(wOAMBuf)
    ld      a, d
    add     a, a
    add     a, a
    add     a, a
    add     16
    ld      [hl+], a
    ld      a, e
    add     a, a
    add     a, a
    add     a, a
    add     8
    ld      [hl+], a
    ld      a, b
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
    jp      ZeroMem

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
    ld      [rROMB], a
    ret

SwitchToBank1:
    ld      a, 1
    ld      [rROMB], a
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

