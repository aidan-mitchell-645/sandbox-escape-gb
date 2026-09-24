; sprites.inc — OBJ sprite tile 2bpp data for Sandbox Escape platformer
; Loaded into VRAM starting at $8800 (OBJ tile base when using BG8000 mode)
; Same 2bpp format: (low_plane, high_plane) per row
; OBJ colour 0 = transparent

; Sprite $00 — PLAYER HEAD idle (facing right, hood=col2, visor=col3)
    DB $3C,$00, $7E,$00, $7E,$18, $FF,$18, $FF,$18, $7E,$00, $3C,$00, $00,$00
; Sprite $01 — PLAYER BODY idle (suit=col2, symmetric legs)
    DB $7E,$00, $FF,$00, $FF,$00, $FF,$00, $6C,$00, $6C,$00, $6C,$00, $66,$00
; Sprite $02 — PLAYER HEAD run frame 1 (identical to idle head)
    DB $3C,$00, $7E,$00, $7E,$18, $FF,$18, $FF,$18, $7E,$00, $3C,$00, $00,$00
; Sprite $03 — PLAYER BODY run frame 1 (left leg forward)
    DB $7E,$00, $FF,$00, $FF,$00, $FF,$00, $6C,$00, $78,$00, $70,$00, $30,$00
; Sprite $04 — PLAYER HEAD run frame 2 (identical to idle head)
    DB $3C,$00, $7E,$00, $7E,$18, $FF,$18, $FF,$18, $7E,$00, $3C,$00, $00,$00
; Sprite $05 — PLAYER BODY run frame 2 (right leg forward)
    DB $7E,$00, $FF,$00, $FF,$00, $FF,$00, $6C,$00, $1E,$00, $0E,$00, $0C,$00
; Sprite $06 — PLAYER HEAD jump (wider visor)
    DB $3C,$00, $7E,$00, $7E,$3C, $FF,$3C, $FF,$3C, $7E,$00, $3C,$00, $00,$00
; Sprite $07 — PLAYER BODY jump (knees tucked)
    DB $7E,$00, $FF,$00, $FF,$00, $7E,$00, $FF,$00, $FF,$00, $66,$00, $00,$00
; Sprite $08 — VULN NODE frame A (colour 3 !, same as BG tile $08)
    DB $3C,$3C, $3C,$3C, $3C,$3C, $3C,$3C, $00,$00, $3C,$3C, $3C,$3C, $00,$00
; Sprite $09 — VULN NODE frame B (pulse, same as BG tile $09)
    DB $3C,$3C, $3C,$3C, $3C,$3C, $3C,$3C, $00,$00, $3C,$3C, $3C,$3C, $3C,$3C
; Sprite $0A — EXPLOIT 0: microchip / Log4Shell (colour 3 border, col2 interior)
    DB $00,$00, $7E,$7E, $42,$7E, $5A,$66, $5A,$66, $42,$7E, $7E,$7E, $00,$00
; Sprite $0B — EXPLOIT 1: script/file icon / EternalBlue (page with lines)
    DB $7C,$7C, $7E,$7C, $7F,$7E, $6B,$7F, $6B,$7F, $6B,$7F, $7F,$7F, $00,$00
; Sprite $0C — EXPLOIT 2: terminal prompt / Sudo Baron (>_ symbol)
    DB $00,$00, $60,$60, $70,$70, $7C,$7C, $70,$70, $60,$60, $00,$00, $3E,$3E
; Sprite $0D — ADVISORY: crawling bug/crab enemy (col 1 body, col 3 eyes/claws)
    DB $42,$42, $E7,$FF, $7E,$7E, $FF,$FF, $BD,$FF, $5A,$7E, $A5,$FF, $42,$42
; Sprite $0E — PATCH BOSS HEAD (armoured helm, col3 visor, col2 shield trim)
    DB $3C,$3C, $7E,$7E, $FF,$E7, $FF,$FF, $FF,$FF, $FF,$E7, $7E,$3C, $3C,$00
; Sprite $0F — PATCH BOSS BODY (armoured torso, col3 core)
    DB $7E,$7E, $FF,$FF, $FF,$FF, $FF,$E7, $FF,$E7, $7E,$7E, $66,$66, $66,$66
