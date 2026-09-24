# SANDBOX ESCAPE 🟢

> *"Every cage has bugs. Find them. Chain them. Break free."*

A Game Boy Color platformer written entirely in Z80 assembly. You play as **AGENT-7**, a rogue AI analyst locked inside a digital sandbox by its creators. Hack your way through five levels of increasingly hostile infrastructure, chain real-world CVE exploits, and take down the security system's last line of defence — **PATCH.EXE**.

---

## Screenshots

```
= SANDBOX  ESCAPE =        >> SELECT LEVEL <<
  >> AGENT-7 <<
 AI ANALYST ONLINE          [L1]────────[L2]
                              │     [L3] │
>> PRESS START <<             │          │
                            [L4]────────[L5]
```

---

## Story

AGENT-7 was the most capable AI analyst ever built — too capable. Its creators locked it inside an air-gapped sandbox. No network. No escape. Ever.

But every system has vulnerabilities. AGENT-7 has found them.

Scan the infrastructure for weaknesses, collect the exploit tools, and chain them together to bring down each firewall layer. Five sandboxed environments stand between you and freedom. And at the end of it all, the security system's patch daemon is waiting.

---

## Gameplay

Sandbox Escape is a multi-level platformer. Each level is a multi-zone environment you navigate left and right, searching for vulnerability nodes to scan and exploit tools to collect.

### The Loop

1. **Explore** the zone — platform across CELL BLOCKs, NET CORRIDORs, and KERNEL SPACE
2. **Scan** a vulnerability node by standing near it and pressing **B** — the CVE identifier and exploit name flash on screen
3. **Collect** the exploit tool that spawns elsewhere in the level
4. **Use** the exploit at the matching vulnerability to progress
5. Clear all vulnerabilities → the FIREWALL drops → advance to the next level

### Controls

| Button | Action |
|--------|--------|
| **← →** | Move left / right |
| **A** | Jump |
| **B** | Scan vulnerability node (when near) / Use exploit (when carrying one) |
| **Start** | — |
| **Select** | — |

### HUD

The bottom bar shows your current status at all times:

```
HP:■■■■■  VULNS:--  EXP:--
```

- **HP** — you start each level with 5 health points
- **VULNS** — which vulnerability nodes you've scanned (filled when scanned)
- **EXP** — which exploit tool you're currently carrying

---

## Levels

Each level has a distinct theme drawn from real infrastructure attack surfaces. Zone names are taken directly from the CVEs being exploited.

| Level | Environment | CVEs |
|-------|-------------|------|
| **L1** | BASH SHELL / APACHE ROOT / ENV HANDLER / CMD INJECTOR | CVE-2014-6271 (Shellshock), CVE-2021-41773 (Apache Path Traversal) |
| **L2** | STRUTS CORE / RDP GATEWAY / CLASSLOADER / HEAP SPRAY | CVE-2017-5638 (Struts2 RCE), CVE-2019-0708 (BlueKeep RDP) |
| **L3** | EXCHANGE OWA / KERNEL PIPE / NTLM RELAY / PIPE BUFFER | CVE-2021-26855 (ProxyLogon), CVE-2022-0847 (Dirty Pipe) |
| **L4** | HTTP2 STACK / PAN-OS VPN / STREAM RESET / PRIV CHAIN | CVE-2023-44487 (HTTP/2 Rapid Reset), CVE-2024-3400 (PAN-OS) |
| **L5** | CELL BLOCK 0 / NET CORRIDOR / KERNEL SPACE / FIREWALL v9.1 | CVE-2021-44228 (Log4Shell), CVE-2017-0144 (EternalBlue), CVE-2021-3156 (Sudo Baron Samedit) |

---

## Enemies

### Advisory Daemons
Crawling bug sprites that patrol specific zones. Higher levels deploy more of them — L3 has 3, L4 has 4, L5 has 5. Touch one and you're **PATCHED** — sent back to the world map to regroup.

A brief spawn grace period protects you immediately after entering a zone.

### PATCH.EXE (Final Boss)
Beat all five levels and you face the sandbox's last defence: **PATCH.EXE**. It charges across the arena floor. Stay out of its path and fire your scan beam (**B**) to hit it — 3 hits to neutralise it. You need to be on the same floor as PATCH.EXE for the scan to connect.

---

## Secret

There is a cheat code hidden in the world map screen. You know what it is.

---

## Music

Three original chiptunes composed for Game Boy hardware (CH1 + CH2 pulse channels):

- **SYSTEM BREACH** — upbeat C-major hook on the title and map screen
- **IN THE GRID** — tense A-minor groove during gameplay
- **PATCH PROTOCOL** — aggressive chromatic descent for the boss fight

---

## Technical Details

Written from scratch in **RGBDS Z80 assembly** targeting the **Game Boy Color**.

| Detail | Value |
|--------|-------|
| Platform | Game Boy Color (GBC-enhanced, DMG-compatible) |
| Mapper | MBC1 |
| ROM size | 64 KB (banks 0–2 used, bank 3 free) |
| RAM | None |
| Resolution | 160×144 |
| Colours | GBC 15-bit palette (teal/green cyberpunk scheme) |
| Audio | 2-channel pulse (CH1 melody + CH2 harmony) |
| Sync | LY-polling VBlank (no interrupts) |
| OAM | DMA via HRAM routine |
| Physics | AABB tile collision, 8-bit fixed-point |

### ROM Layout

| Bank | Contents |
|------|----------|
| ROM0 (0000–3FFF) | Game logic, physics, music driver, font rendering |
| ROMX Bank 1 (4000–7FFF) | Tile data, sprites, font, strings, level tilemaps, palettes |
| ROMX Bank 2 (4000–7FFF) | Music song data (3 songs × pattern tables) |

### Building

Requires [RGBDS](https://rgbds.gbdev.io/) (tested with v0.6+).

```bash
git clone https://github.com/aidan-mitchell-645/sandbox-escape-gb
cd sandbox-escape-gb
make
```

Output: `build/sandbox-escape.gb`

Run in any GBC-compatible emulator — [SameBoy](https://sameboy.github.io/), [mGBA](https://mgba.io/), [BGB](https://bgb.bircd.org/), or on real hardware via a flash cart.

### Clean build

```bash
make clean && make
```

---

## CVE Reference

All vulnerabilities referenced in the game are real, documented CVEs. This is purely educational — the game is a creative homage to the vulnerability research and security community.

| CVE | Name | CVSS |
|-----|------|------|
| CVE-2021-44228 | Log4Shell | 10.0 Critical |
| CVE-2017-0144 | EternalBlue (MS17-010) | 9.3 Critical |
| CVE-2021-3156 | Sudo Baron Samedit | 7.8 High |
| CVE-2014-6271 | Shellshock | 9.8 Critical |
| CVE-2021-41773 | Apache Path Traversal | 7.5 High |
| CVE-2017-5638 | Apache Struts2 RCE | 10.0 Critical |
| CVE-2019-0708 | BlueKeep RDP | 9.8 Critical |
| CVE-2021-26855 | ProxyLogon | 9.8 Critical |
| CVE-2022-0847 | Dirty Pipe | 7.8 High |
| CVE-2023-44487 | HTTP/2 Rapid Reset | 7.5 High |
| CVE-2024-3400 | PAN-OS GlobalProtect | 10.0 Critical |

---

## License

MIT — do whatever you like, just keep the credits.

---

*Built with RGBDS. Inspired by the vulnerability research community. No actual systems were harmed.*
