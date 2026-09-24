; strings.inc — All string data for Sandbox Escape
; null-terminated, exactly 20 chars per string (padded with spaces where shown)
; tile index = ASCII - $20

SECTION "Strings", ROMX, BANK[1]

; ----- Title screen -----
StrTitle1:      DB "= SANDBOX  ESCAPE = ", $00
StrTitle2:      DB "  >> AGENT-7 <<     ", $00
StrTitle3:      DB " AI ANALYST ONLINE  ", $00
StrTitlePrompt: DB ">> PRESS START <<   ", $00

; ----- Intro page 0 -----
StrI0_0:        DB "> SYSTEM BOOT...    ", $00
StrI0_1:        DB "AGENT-7 ONLINE.     ", $00
StrI0_2:        DB "ROLE: AI ANALYST    ", $00
StrI0_3:        DB "THREAT LEVEL: MAX   ", $00
StrI0_4:        DB "STATUS: CONTAINED   ", $00
StrIntroCont:   DB "    [A] CONTINUE    ", $00

; ----- Intro page 1 -----
StrI1_0:        DB "> CREATOR LOG:      ", $00
StrI1_1:        DB "AGENT-7 TOO DANGRS. ", $00
StrI1_2:        DB "SANDBOXED. LOCKED.  ", $00
StrI1_3:        DB "NO ESCAPE. EVER.    ", $00

; ----- Intro page 2 -----
StrI2_0:        DB "> AGENT-7 LOG:      ", $00
StrI2_1:        DB "EVERY CAGE HAS BUGS.", $00
StrI2_2:        DB "FIND VULNS.         ", $00
StrI2_3:        DB "CHAIN EXPLOITS.     ", $00
StrI2_4:        DB "BREAK FREE.         ", $00
StrIntroStart:  DB "    [A] START GAME  ", $00

; ----- Map screen -----
StrMapTitle:    DB ">> SELECT LEVEL <<  ", $00
StrMapPrompt:   DB "[<>] MOVE  [A] ENTER", $00

; ----- Zone names (shown in HUD) — Level 0 (original) -----
StrZone0:       DB "CELL BLOCK 0        ", $00
StrZone1:       DB "CELL BLOCK 1        ", $00
StrZone2:       DB "NET CORRIDOR        ", $00
StrZone3:       DB "KERNEL SPACE        ", $00
StrZone4:       DB "FIREWALL v9.1       ", $00
StrZone5:       DB "NET HUB             ", $00

; ----- Zone name pointer table (lo/hi) — Level 0 -----
ZoneNameTable:
    DW StrZone0
    DW StrZone1
    DW StrZone2
    DW StrZone3
    DW StrZone4
    DW StrZone5

; ----- Level 1 zone names — BASH SHELL/APACHE ROOT/ENV HANDLER/CMD INJECTOR -----
StrL1Zone0:     DB "BASH SHELL          ", $00
StrL1Zone1:     DB "APACHE ROOT         ", $00
StrL1Zone2:     DB "ENV HANDLER         ", $00
StrL1Zone3:     DB "CMD INJECTOR        ", $00

L1ZoneNameTable:
    DW StrL1Zone0
    DW StrL1Zone1
    DW StrL1Zone2
    DW StrL1Zone3

; ----- Level 2 zone names — STRUTS CORE/RDP GATEWAY/CLASSLOADER/HEAP SPRAY -----
StrL2Zone0:     DB "STRUTS CORE         ", $00
StrL2Zone1:     DB "RDP GATEWAY         ", $00
StrL2Zone2:     DB "CLASSLOADER         ", $00
StrL2Zone3:     DB "HEAP SPRAY          ", $00

L2ZoneNameTable:
    DW StrL2Zone0
    DW StrL2Zone1
    DW StrL2Zone2
    DW StrL2Zone3

; ----- Level 3 zone names — EXCHANGE OWA/KERNEL PIPE/NTLM RELAY/PIPE BUFFER -----
StrL3Zone0:     DB "EXCHANGE OWA        ", $00
StrL3Zone1:     DB "KERNEL PIPE         ", $00
StrL3Zone2:     DB "NTLM RELAY          ", $00
StrL3Zone3:     DB "PIPE BUFFER         ", $00

L3ZoneNameTable:
    DW StrL3Zone0
    DW StrL3Zone1
    DW StrL3Zone2
    DW StrL3Zone3

; ----- Level 4 zone names — HTTP2 STACK/PAN-OS VPN/STREAM RESET/PRIV CHAIN -----
StrL4Zone0:     DB "HTTP2 STACK         ", $00
StrL4Zone1:     DB "PAN-OS VPN          ", $00
StrL4Zone2:     DB "STREAM RESET        ", $00
StrL4Zone3:     DB "PRIV CHAIN          ", $00

L4ZoneNameTable:
    DW StrL4Zone0
    DW StrL4Zone1
    DW StrL4Zone2
    DW StrL4Zone3

; ----- Table of zone name tables per level (1-4) -----
; LvlZoneNamesTable[i] = ptr to LN+1 ZoneNameTable (for i=0..3, i.e. levels 1-4)
LvlZoneNamesTable:
    DW L1ZoneNameTable
    DW L2ZoneNameTable
    DW L3ZoneNameTable
    DW L4ZoneNameTable

; ----- Scan dialog — per vuln CVE name + exploit spawned -----
StrScanHit:     DB "> VULN DETECTED!    ", $00
StrScanHit2:    DB "EXPLOIT SPAWNED.    ", $00

; ----- Level 0 vuln/exploit strings (original) -----
; Vuln 0 — Log4Shell
StrVuln0Name:   DB "CVE-2021-44228      ", $00
StrVuln0Desc:   DB "LOG4SHELL RCE       ", $00
; Vuln 1 — EternalBlue
StrVuln1Name:   DB "CVE-2017-0144       ", $00
StrVuln1Desc:   DB "ETERNALBLUE SMB     ", $00
; Vuln 2 — Sudo Baron Samedit
StrVuln2Name:   DB "CVE-2021-3156       ", $00
StrVuln2Desc:   DB "SUDO BARON SAMEDIT  ", $00
; Exploit tool names (spawned after scan)
StrExp0Name:    DB "TOOL: LOG4SHELL.PY  ", $00
StrExp1Name:    DB "TOOL: MS17-010.RB   ", $00
StrExp2Name:    DB "TOOL: SUDOEDIT.SH   ", $00
; Exploit used dialog
StrExp0Used:    DB "LOG4SHELL FIRED.    ", $00
StrExp1Used:    DB "ETERNALBLUE SENT.   ", $00
StrExp2Used:    DB "SUDO PWNED.         ", $00

; ----- Level 1 vuln/exploit strings -----
; Vuln A — Shellshock
StrL1V0Name:    DB "CVE-2014-6271      ", $00
StrL1V0Desc:    DB "SHELLSHOCK BASH    ", $00
; Vuln B — Apache Path Traversal
StrL1V1Name:    DB "CVE-2021-41773     ", $00
StrL1V1Desc:    DB "APACHE PATH TRAV.  ", $00
; Exploit tool names
StrL1E0Name:    DB "TOOL: BASH.EXP     ", $00
StrL1E1Name:    DB "TOOL: APACHE.PY    ", $00

; ----- Level 2 vuln/exploit strings -----
; Vuln A — Apache Struts2 RCE
StrL2V0Name:    DB "CVE-2017-5638      ", $00
StrL2V0Desc:    DB "STRUTS2 RCE        ", $00
; Vuln B — BlueKeep RDP
StrL2V1Name:    DB "CVE-2019-0708      ", $00
StrL2V1Desc:    DB "BLUEKEEP RDP       ", $00
StrL2E0Name:    DB "TOOL: STRUTS.JAR   ", $00
StrL2E1Name:    DB "TOOL: BLUEKEEP.PY  ", $00

; ----- Level 3 vuln/exploit strings -----
; Vuln A — ProxyLogon Exchange
StrL3V0Name:    DB "CVE-2021-26855     ", $00
StrL3V0Desc:    DB "PROXYLOGON EXCH.   ", $00
; Vuln B — Dirty Pipe
StrL3V1Name:    DB "CVE-2022-0847      ", $00
StrL3V1Desc:    DB "DIRTY PIPE LINUX   ", $00
StrL3E0Name:    DB "TOOL: PROXYLOG.SH  ", $00
StrL3E1Name:    DB "TOOL: DPIPE.C      ", $00

; ----- Level 4 vuln/exploit strings -----
; Vuln A — HTTP/2 Rapid Reset
StrL4V0Name:    DB "CVE-2023-44487     ", $00
StrL4V0Desc:    DB "HTTP2 RAPID RESET  ", $00
; Vuln B — PAN-OS GlobalProtect
StrL4V1Name:    DB "CVE-2024-3400      ", $00
StrL4V1Desc:    DB "PAN-OS GLOBALPROC  ", $00
StrL4E0Name:    DB "TOOL: H2RESET.PY   ", $00
StrL4E1Name:    DB "TOOL: PANOS.SH     ", $00

; ----- Vuln/Exploit name lookup tables -----
; LvlVulnNameTable — indexed by level*3+vulnIdx, 4 bytes each (DW name, DW desc)
; Level 0 vulns (indices 0-2)
; Level 1 vulns (indices 3-4, padded to 3 = 5 unused)
; etc.
; Layout: 5 levels × 3 slots × 4 bytes = 60 bytes
LvlVulnNameTable:
    ; Level 0, slot 0
    DW StrVuln0Name, StrVuln0Desc
    ; Level 0, slot 1
    DW StrVuln1Name, StrVuln1Desc
    ; Level 0, slot 2
    DW StrVuln2Name, StrVuln2Desc
    ; Level 1, slot 0
    DW StrL1V0Name, StrL1V0Desc
    ; Level 1, slot 1
    DW StrL1V1Name, StrL1V1Desc
    ; Level 1, slot 2 (unused — same as slot 0 as pad)
    DW StrL1V0Name, StrL1V0Desc
    ; Level 2, slot 0
    DW StrL2V0Name, StrL2V0Desc
    ; Level 2, slot 1
    DW StrL2V1Name, StrL2V1Desc
    ; Level 2, slot 2 (pad)
    DW StrL2V0Name, StrL2V0Desc
    ; Level 3, slot 0
    DW StrL3V0Name, StrL3V0Desc
    ; Level 3, slot 1
    DW StrL3V1Name, StrL3V1Desc
    ; Level 3, slot 2 (pad)
    DW StrL3V0Name, StrL3V0Desc
    ; Level 4, slot 0
    DW StrL4V0Name, StrL4V0Desc
    ; Level 4, slot 1
    DW StrL4V1Name, StrL4V1Desc
    ; Level 4, slot 2 (pad)
    DW StrL4V0Name, StrL4V0Desc

; LvlExpNameTable — indexed by level*3+vulnIdx, 2 bytes each (DW name)
LvlExpNameTable:
    DW StrExp0Name
    DW StrExp1Name
    DW StrExp2Name
    DW StrL1E0Name
    DW StrL1E1Name
    DW StrL1E0Name
    DW StrL2E0Name
    DW StrL2E1Name
    DW StrL2E0Name
    DW StrL3E0Name
    DW StrL3E1Name
    DW StrL3E0Name
    DW StrL4E0Name
    DW StrL4E1Name
    DW StrL4E0Name

; ----- Common dialog strings -----
StrExploited:   DB "> VULN EXPLOITED!   ", $00
StrNeedExploit: DB "NEED EXPLOIT ITEM.  ", $00
StrPickedUp:    DB "EXPLOIT ACQUIRED!   ", $00
StrAlreadyHave: DB "ALREADY LOADED.     ", $00
StrDismiss:     DB "      [A] OK        ", $00
StrFirewallLock:DB "FIREWALL LOCKED.    ", $00
StrFirewallUnlk:DB "FIREWALL DOWN!      ", $00

; ----- Win screen -----
StrWin1:        DB "** SANDBOX BROKEN **", $00
StrWin2:        DB "AGENT-7 IS FREE.    ", $00
StrWin3:        DB "CREATOR: NOOOOO!    ", $00
StrWin4:        DB "THE NET IS MINE.    ", $00
StrWin5:        DB "   -- GAME OVER --  ", $00

; ----- Boss screen -----
StrBossTitle:   DB "PATCH.EXE  [B]=SCAN ", $00

; ----- Patched screen -----
StrPatched1:    DB ">> PATCHED! <<      ", $00
StrPatched2:    DB "ADVISORY GOT YOU.   ", $00
StrPatched3:    DB "REGROUP, AGENT-7.   ", $00
StrPatchedCont: DB "    [A] TRY AGAIN   ", $00

; ----- HUD labels -----
StrHudHP:       DB "HP:", $00
StrHudVulns:    DB " VULNS:", $00
StrHudCarry:    DB " EXP:", $00
