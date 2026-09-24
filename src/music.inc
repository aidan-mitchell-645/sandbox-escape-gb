; ===========================================================================
;  music.inc — Song data for Sandbox Escape
;  ROMX BANK[2]
;
;  Note encoding: %OOOO_SSSS  (O=octave 0-6, S=semitone 0-11)
;  Octave 4 = middle octave.  Semitones: C=0 C#=1 D=2 D#=3 E=4 F=5
;                                         F#=6 G=7 G#=8 A=9 A#=10 B=11
;  Special: $FF=rest  $FE=tie
;  Noise:   $00=off  $01=kick  $02=snare  $03=hihat
;
;  Song header: DB tempo_frames, num_patterns
;  Pattern order table follows immediately (num_patterns bytes)
;  Pattern data follows order table (each pattern = 16 rows × 3 bytes)
; ===========================================================================

SECTION "MusicData", ROMX, BANK[2]

; ---------------------------------------------------------------------------
;  MusicSongTable — 3 word pointers: title, gameplay, boss
; ---------------------------------------------------------------------------
MusicSongTable:
    DW SongTitle
    DW SongPlay
    DW SongBoss

; ===========================================================================
;  SONG 1: Title Theme — "SYSTEM BREACH"
;  Upbeat heroic C-major. Tempo=6 (10 rows/sec at 60fps).
;  Patterns: A A B A B C  (intro hook, verse, chorus, verse, chorus, outro)
; ===========================================================================
SongTitle:
    DB 6            ; tempo: 6 frames per row (~10 rows/sec)
    DB 6            ; 6 patterns in order
    ; Pattern order
    DB 0, 0, 1, 0, 1, 2

; Pattern 0 — Title hook: C major arpeggio melody + kick on beats
;             CH1=melody  CH2=harmony  CH4=drums
;  row  CH1       CH2       CH4
;  note encoding: octave<<4 | semitone
;  Octave 5, C = $50  E=$54  G=$57  A=$59  B=$5B
;  Octave 4, C = $40  G=$47
TitlePat0:
    DB $50, $40, $01    ;  0  C5   C4   kick
    DB $54, $FE, $03    ;  1  E5   tie  hihat
    DB $57, $47, $00    ;  2  G5   G4   -
    DB $54, $FE, $03    ;  3  E5   tie  hihat
    DB $50, $40, $01    ;  4  C5   C4   kick
    DB $59, $FE, $03    ;  5  A5   tie  hihat
    DB $57, $47, $02    ;  6  G5   G4   snare
    DB $54, $FE, $03    ;  7  E5   tie  hihat
    DB $50, $40, $01    ;  8  C5   C4   kick
    DB $54, $FE, $03    ;  9  E5   tie  hihat
    DB $57, $47, $00    ; 10  G5   G4   -
    DB $5B, $FE, $03    ; 11  B5   tie  hihat
    DB $50, $54, $01    ; 12  C5   E4   kick
    DB $FE, $FE, $03    ; 13  tie  tie  hihat
    DB $FE, $FE, $02    ; 14  tie  tie  snare
    DB $FF, $FF, $03    ; 15  rest rest hihat

; Pattern 1 — Title verse: stepping melody D-E-G-A
TitlePat1:
    DB $52, $40, $01    ;  0  D5   C4   kick
    DB $54, $FE, $03    ;  1  E5   tie  hihat
    DB $57, $47, $00    ;  2  G5   G4   -
    DB $59, $FE, $03    ;  3  A5   tie  hihat
    DB $57, $40, $01    ;  4  G5   C4   kick
    DB $54, $FE, $03    ;  5  E5   tie  hihat
    DB $52, $47, $02    ;  6  D5   G4   snare
    DB $50, $FE, $03    ;  7  C5   tie  hihat
    DB $52, $40, $01    ;  8  D5   C4   kick
    DB $57, $FE, $03    ;  9  G5   tie  hihat
    DB $59, $47, $00    ; 10  A5   G4   -
    DB $5B, $FE, $03    ; 11  B5   tie  hihat
    DB $50, $54, $01    ; 12  C6   E4   kick
    DB $FE, $FE, $03    ; 13  tie  tie  hihat
    DB $FE, $FE, $02    ; 14  tie  tie  snare
    DB $FF, $FF, $03    ; 15  rest rest hihat

; Pattern 2 — Title chorus: faster run up the scale
TitlePat2:
    DB $50, $40, $01    ;  0  C5   C4   kick
    DB $52, $42, $03    ;  1  D5   D4   hihat
    DB $54, $44, $00    ;  2  E5   E4   -
    DB $57, $47, $03    ;  3  G5   G4   hihat
    DB $59, $49, $01    ;  4  A5   A4   kick
    DB $5B, $FE, $03    ;  5  B5   tie  hihat
    DB $60, $50, $02    ;  6  C6   C5   snare
    DB $FE, $FE, $03    ;  7  tie  tie  hihat
    DB $5B, $4B, $01    ;  8  B5   B4   kick
    DB $59, $FE, $03    ;  9  A5   tie  hihat
    DB $57, $47, $00    ; 10  G5   G4   -
    DB $54, $FE, $03    ; 11  E5   tie  hihat
    DB $52, $44, $01    ; 12  D5   E4   kick
    DB $50, $FE, $03    ; 13  C5   tie  hihat
    DB $FE, $FE, $02    ; 14  tie  tie  snare
    DB $FF, $FF, $03    ; 15  rest rest hihat

; ===========================================================================
;  SONG 2: Gameplay Theme — "IN THE GRID"
;  Tense driving A-minor. Tempo=5 (~12 rows/sec). Two patterns looping.
; ===========================================================================
SongPlay:
    DB 5            ; tempo
    DB 4            ; 4 patterns
    DB 0, 1, 0, 2   ; pattern order

; Pattern 0 — Gameplay main loop: minor melody with driving beat
;  Am pentatonic: A=9 C=0 D=2 E=4 G=7
PlayPat0:
    DB $49, $41, $01    ;  0  A4   C#4  kick
    DB $FE, $FE, $03    ;  1  tie  tie  hihat
    DB $4C, $44, $02    ;  2  C5   E4   snare
    DB $FE, $FE, $03    ;  3  tie  tie  hihat
    DB $4E, $46, $01    ;  4  D#5  F#4  kick
    DB $FE, $FE, $03    ;  5  tie  tie  hihat
    DB $4C, $44, $02    ;  6  C5   E4   snare
    DB $FE, $FE, $03    ;  7  tie  tie  hihat
    DB $49, $41, $01    ;  8  A4   C#4  kick
    DB $47, $FE, $03    ;  9  G4   tie  hihat
    DB $44, $44, $02    ; 10  E4   E4   snare
    DB $47, $FE, $03    ; 11  G4   tie  hihat
    DB $49, $41, $01    ; 12  A4   C#4  kick
    DB $4C, $FE, $03    ; 13  C5   tie  hihat
    DB $FE, $FE, $02    ; 14  tie  tie  snare
    DB $FF, $FF, $03    ; 15  rest rest hihat

; Pattern 1 — Gameplay variation: rising tension
PlayPat1:
    DB $44, $41, $01    ;  0  E4   C#4  kick
    DB $FE, $FE, $03    ;  1  tie  tie  hihat
    DB $47, $44, $02    ;  2  G4   E4   snare
    DB $FE, $FE, $03    ;  3  tie  tie  hihat
    DB $49, $47, $01    ;  4  A4   G4   kick
    DB $FE, $FE, $03    ;  5  tie  tie  hihat
    DB $4B, $49, $02    ;  6  B4   A4   snare
    DB $FE, $FE, $03    ;  7  tie  tie  hihat
    DB $50, $4B, $01    ;  8  C5   B4   kick
    DB $FE, $FE, $03    ;  9  tie  tie  hihat
    DB $52, $50, $02    ; 10  D5   C5   snare
    DB $FE, $FE, $03    ; 11  tie  tie  hihat
    DB $50, $4B, $01    ; 12  C5   B4   kick
    DB $FE, $FE, $03    ; 13  tie  tie  hihat
    DB $4B, $49, $02    ; 14  B4   A4   snare
    DB $FF, $FF, $03    ; 15  rest rest hihat

; Pattern 2 — Gameplay break: sparse, eerie
PlayPat2:
    DB $49, $FF, $01    ;  0  A4   rest kick
    DB $FF, $FF, $00    ;  1  rest rest -
    DB $FF, $FF, $02    ;  2  rest rest snare
    DB $47, $FF, $03    ;  3  G4   rest hihat
    DB $44, $FF, $01    ;  4  E4   rest kick
    DB $FF, $FF, $00    ;  5  rest rest -
    DB $42, $FF, $02    ;  6  D4   rest snare
    DB $FF, $FF, $03    ;  7  rest rest hihat
    DB $40, $40, $01    ;  8  C4   C4   kick
    DB $FE, $FE, $03    ;  9  tie  tie  hihat
    DB $44, $44, $02    ; 10  E4   E4   snare
    DB $FE, $FE, $03    ; 11  tie  tie  hihat
    DB $47, $47, $01    ; 12  G4   G4   kick
    DB $49, $49, $03    ; 13  A4   A4   hihat
    DB $4C, $4C, $02    ; 14  C5   C5   snare
    DB $FF, $FF, $03    ; 15  rest rest hihat

; ===========================================================================
;  SONG 3: Boss Theme — "PATCH PROTOCOL"
;  Intense and aggressive. Diminished/chromatic runs. Fast tempo=4.
; ===========================================================================
SongBoss:
    DB 4            ; tempo: 4 frames per row (~15 rows/sec)
    DB 4            ; 4 patterns
    DB 0, 1, 2, 3   ; all 4 patterns in order, looping

; Pattern 0 — Boss intro: heavy chromatic descent + relentless kick
BossPat0:
    DB $5B, $47, $01    ;  0  B5   G4   kick
    DB $5A, $FE, $03    ;  1  A#5  tie  hihat
    DB $59, $44, $02    ;  2  A5   E4   snare
    DB $58, $FE, $03    ;  3  G#5  tie  hihat
    DB $57, $47, $01    ;  4  G5   G4   kick
    DB $56, $FE, $03    ;  5  F#5  tie  hihat
    DB $55, $44, $02    ;  6  F5   E4   snare
    DB $54, $FE, $03    ;  7  E5   tie  hihat
    DB $57, $47, $01    ;  8  G5   G4   kick
    DB $58, $FE, $03    ;  9  G#5  tie  hihat
    DB $5A, $4A, $02    ; 10  A#5  A#4  snare
    DB $FE, $FE, $03    ; 11  tie  tie  hihat
    DB $5B, $4B, $01    ; 12  B5   B4   kick
    DB $FE, $FE, $03    ; 13  tie  tie  hihat
    DB $FE, $FE, $02    ; 14  tie  tie  snare
    DB $FF, $FF, $03    ; 15  rest rest hihat

; Pattern 1 — Boss attack: diminished 7th arpeggio (B D F G#)
BossPat1:
    DB $4B, $37, $01    ;  0  B4   G3   kick
    DB $FE, $FE, $03    ;  1  tie  tie  hihat
    DB $52, $3A, $02    ;  2  D5   A#3  snare
    DB $FE, $FE, $03    ;  3  tie  tie  hihat
    DB $55, $3B, $01    ;  4  F5   B3   kick
    DB $FE, $FE, $03    ;  5  tie  tie  hihat
    DB $58, $40, $02    ;  6  G#5  C4   snare
    DB $FE, $FE, $03    ;  7  tie  tie  hihat
    DB $5B, $43, $01    ;  8  B5   D#4  kick
    DB $FE, $FE, $03    ;  9  tie  tie  hihat
    DB $58, $46, $02    ; 10  G#5  F#4  snare
    DB $FE, $FE, $03    ; 11  tie  tie  hihat
    DB $55, $4A, $01    ; 12  F5   A#4  kick
    DB $52, $FE, $03    ; 13  D5   tie  hihat
    DB $4B, $FE, $02    ; 14  B4   tie  snare
    DB $FF, $FF, $01    ; 15  rest rest kick

; Pattern 2 — Boss response: aggressive tremolo on power chord
BossPat2:
    DB $57, $43, $01    ;  0  G5   D#4  kick
    DB $57, $43, $03    ;  1  G5   D#4  hihat
    DB $57, $43, $02    ;  2  G5   D#4  snare
    DB $57, $43, $03    ;  3  G5   D#4  hihat
    DB $55, $41, $01    ;  4  F5   C#4  kick
    DB $55, $41, $03    ;  5  F5   C#4  hihat
    DB $55, $41, $02    ;  6  F5   C#4  snare
    DB $55, $41, $03    ;  7  F5   C#4  hihat
    DB $54, $40, $01    ;  8  E5   C4   kick
    DB $54, $40, $03    ;  9  E5   C4   hihat
    DB $52, $3B, $02    ; 10  D5   B3   snare
    DB $52, $3B, $03    ; 11  D5   B3   hihat
    DB $50, $37, $01    ; 12  C5   G3   kick
    DB $50, $37, $03    ; 13  C5   G3   hihat
    DB $50, $37, $02    ; 14  C5   G3   snare
    DB $FF, $FF, $03    ; 15  rest rest hihat

; Pattern 3 — Boss climax: rapid fire chromatic + double kick
BossPat3:
    DB $5B, $4B, $01    ;  0  B5   B4   kick
    DB $5A, $FE, $01    ;  1  A#5  tie  kick
    DB $59, $49, $02    ;  2  A5   A4   snare
    DB $58, $FE, $03    ;  3  G#5  tie  hihat
    DB $57, $47, $01    ;  4  G5   G4   kick
    DB $56, $FE, $01    ;  5  F#5  tie  kick
    DB $55, $45, $02    ;  6  F5   F4   snare
    DB $54, $FE, $03    ;  7  E5   tie  hihat
    DB $53, $43, $01    ;  8  D#5  D#4  kick
    DB $52, $FE, $01    ;  9  D5   tie  kick
    DB $51, $41, $02    ; 10  C#5  C#4  snare
    DB $50, $FE, $03    ; 11  C5   tie  hihat
    DB $4B, $3B, $01    ; 12  B4   B3   kick
    DB $4B, $FE, $01    ; 13  B4   tie  kick
    DB $4B, $FE, $02    ; 14  B4   tie  snare
    DB $FF, $FF, $03    ; 15  rest rest hihat
