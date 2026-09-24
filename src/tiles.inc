; tiles.inc — BG + HUD tile 2bpp data for Sandbox Escape platformer
; Format: each tile = 16 bytes, 8 rows × (low_plane, high_plane)
; Colour index = (high_bit<<1)|low_bit : 0=void 1=dark 2=mid 3=bright

; Tile $00 — VOID
    DB $00,$00, $00,$00, $00,$00, $00,$00, $00,$00, $00,$00, $00,$00, $00,$00
; Tile $01 — PLATFORM MID (circuit-board, top edge bright, fill dark)
    DB $FF,$FF, $FF,$FF, $00,$FF, $00,$FF, $FF,$00, $00,$FF, $00,$FF, $00,$FF
; Tile $02 — PLATFORM LEFT EDGE (col 0 forced colour 3)
    DB $FF,$FF, $FF,$FF, $80,$FF, $80,$FF, $FF,$80, $80,$FF, $80,$FF, $80,$FF
; Tile $03 — PLATFORM RIGHT EDGE (col 7 forced colour 3)
    DB $FF,$FF, $FF,$FF, $01,$FF, $01,$FF, $FF,$01, $01,$FF, $01,$FF, $01,$FF
; Tile $04 — WALL SOLID (colour 1 fill)
    DB $00,$FF, $00,$FF, $00,$FF, $00,$FF, $00,$FF, $00,$FF, $00,$FF, $00,$FF
; Tile $05 — BG GRID DOT (colour 1 centre dot)
    DB $00,$00, $00,$00, $00,$00, $18,$00, $18,$00, $00,$00, $00,$00, $00,$00
; Tile $06 — BG GRID LINE H (colour 1 horizontal at row 4)
    DB $00,$00, $00,$00, $00,$00, $00,$00, $FF,$00, $00,$00, $00,$00, $00,$00
; Tile $07 — BG GRID LINE V (colour 1 vertical at col 4)
    DB $08,$00, $08,$00, $08,$00, $08,$00, $08,$00, $08,$00, $08,$00, $08,$00
; Tile $08 — VULN NODE INACTIVE frame A (colour 3 ! icon)
    DB $3C,$3C, $3C,$3C, $3C,$3C, $3C,$3C, $00,$00, $3C,$3C, $3C,$3C, $00,$00
; Tile $09 — VULN NODE INACTIVE frame B (pulse — row 7 lit)
    DB $3C,$3C, $3C,$3C, $3C,$3C, $3C,$3C, $00,$00, $3C,$3C, $3C,$3C, $3C,$3C
; Tile $0A — VULN NODE SCANNED (eye icon, colour 2 inner)
    DB $00,$00, $3C,$00, $7E,$3C, $E7,$7E, $E7,$7E, $7E,$3C, $3C,$00, $00,$00
; Tile $0B — VULN NODE EXPLOITED (X broken, colour 3)
    DB $C3,$C3, $66,$66, $3C,$3C, $18,$18, $18,$18, $3C,$3C, $66,$66, $C3,$C3
; Tile $0C — EXPLOIT PICKUP (microchip, colour 3 border, colour 2 interior)
    DB $00,$00, $7E,$7E, $42,$7E, $5A,$66, $5A,$66, $42,$7E, $7E,$7E, $00,$00
; Tile $0D — HUD BAR SOLID (colour 1)
    DB $00,$FF, $00,$FF, $00,$FF, $00,$FF, $00,$FF, $00,$FF, $00,$FF, $00,$FF
; Tile $0E — SCAN BEAM SHORT (colour 3, 3px tall)
    DB $00,$00, $00,$00, $00,$00, $FF,$FF, $FF,$FF, $FF,$FF, $00,$00, $00,$00
; Tile $0F — SCAN BEAM FADE (checkerboard colour 3/2)
    DB $00,$00, $00,$00, $00,$00, $AA,$AA, $FF,$55, $AA,$AA, $00,$00, $00,$00
