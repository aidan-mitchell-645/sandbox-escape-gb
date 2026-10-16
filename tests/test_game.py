#!/usr/bin/env python3
"""Headless regression tests for Sandbox Escape.

Usage: python3 tests/test_game.py build/sandbox-escape.gb [test_name ...]

Each test boots a fresh emulator, drives the game through real input where
practical, and pokes WRAM (by symbol) to set up scenarios quickly.
"""

import os
import sys
import traceback

sys.path.insert(0, os.path.dirname(__file__))
from harness import (BOSS, DIALOG, MAP, PATCHED, PLAY, TITLE, WIN, Game,  # noqa: E402
                     boot_to_map, enter_level, konami_to_boss)

ROM = None

# Tile IDs (mirror main.asm)
T_VOID, T_VULN_SCAN, T_VULN_EXP, T_EXPLOIT, T_BEAM_FULL = 0x60, 0x6A, 0x6B, 0x6C, 0x6E
ZONE_COLS, ZONE_ROWS = 20, 16
LCDC, LY, WY = 0xFF40, 0xFF44, 0xFF4A


def vram_tile(g, row, col):
    return g.pb.memory[0x9800 + row * 32 + col]


def map_tile(g, row, col):
    return g.pb.memory[g.addr("wZoneMap") + row * ZONE_COLS + col]


def vram_matches_map(g, rows=range(ZONE_ROWS)):
    bad = [(r, c, vram_tile(g, r, c), map_tile(g, r, c))
           for r in rows for c in range(ZONE_COLS)
           if vram_tile(g, r, c) != map_tile(g, r, c)]
    return bad


def place(g, x, y):
    """Teleport the player and let them settle onto the floor below."""
    g["wPX"], g["wPY"], g["wPVX"], g["wPVY"], g["wPXSub"] = x, y, 0, 0, 0
    for _ in range(30):
        g.tick()
        if g["wPOnGround"]:
            return
    raise AssertionError("player never landed at x=%d y=%d" % (x, y))


def goto_zone(g, path):
    """Walk through zone edges by teleporting onto them. path: 'R'/'L' steps."""
    for step in path:
        g["wSpawnGrace"] = 0
        g["wPX"] = 152 if step == "R" else 0
        g["wPVX"] = 0
        g.tick(3)


def check_vblank_writes(g):
    """Fail if the VRAM queue or dialog streamer runs outside VBlank."""
    violations = []

    def cb(_ctx):
        if g.pb.memory[LCDC] & 0x80 and g.pb.memory[LY] < 144:
            violations.append(g.pb.memory[LY])

    g.hook("FlushVRAMQueue.loop", cb)
    g.hook("StreamDialogRow.copy", cb)
    return violations


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_hud_visible():
    g = Game(ROM)
    enter_level(g, 0)
    assert g.pb.memory[WY] == 128, "HUD window should sit at WY=128"
    assert g.pb.memory[0x9C20] == ord("H") - 0x20, "HUD row 1 should start with 'HP:'"
    assert g.pb.memory[0x9C23] == ord("5") - 0x20, "HUD should show 5 HP"
    g.close()


def test_running_has_momentum_and_sub_pixels():
    g = Game(ROM)
    enter_level(g, 0)
    g.hold("right")
    g.tick(1)
    assert g["wPVX"] == 3, "first frame accelerates by RUN_ACCEL"
    g.tick(20)
    assert g["wPVX"] == 24, "top speed is 1.5 px/frame"
    g.release()
    g.tick(8)
    assert g["wPVX"] == 0, "ground friction stops the player"
    g.close()


def test_left_edge_does_not_wrap():
    g = Game(ROM)
    enter_level(g, 0)
    place(g, 16, 72)
    g["wPX"], g["wPVX"] = 1, 256 - 24
    g.tick(2)
    assert g["wPX"] == 0 and g["wZone"] == 0, "walking off the left edge must not wrap to X=152"
    g.close()


def test_variable_jump_height():
    def apex(frames_held):
        g = Game(ROM)
        enter_level(g, 0)
        place(g, 16, 72)
        g.hold("a")
        lowest = 255
        for frame in range(40):
            if frame == frames_held:
                g.release("a")
            g.tick()
            lowest = min(lowest, g["wPY"])
        g.close()
        return lowest

    tap, full = apex(1), apex(30)
    assert tap > full + 20, "a tap (apex y=%d) should jump lower than a hold (y=%d)" % (tap, full)


def test_coyote_time():
    g = Game(ROM)
    enter_level(g, 0)
    # Zone 0 floor (row 11) ends at col 7; run off the edge toward the gap
    place(g, 52, 72)
    g.hold("right")
    for _ in range(20):
        g.tick()
        if not g["wPOnGround"]:
            break
    assert not g["wPOnGround"], "player should have run off the ledge"
    g.release("right")
    g.tick(2)
    g.press("a", frames=1, after=0)
    assert g["wPVY"] >= 0xF0, "jump within coyote window should still fire (VY=%d)" % g["wPVY"]
    g.close()


def test_jump_buffer():
    g = Game(ROM)
    enter_level(g, 0)
    place(g, 16, 72)
    g["wPY"], g["wPVY"], g["wPOnGround"] = 66, 2, 0  # just above the floor, falling
    g.press("a", frames=1, after=0)
    for _ in range(8):
        g.tick()
        if g["wPVY"] >= 0xF0:
            break
    assert g["wPVY"] >= 0xF0, "A pressed just before landing should jump on landing"
    g.close()


def test_scan_beam_restores_tiles_and_marks_vuln():
    g = Game(ROM)
    violations = check_vblank_writes(g)
    enter_level(g, 0)
    # Level 0 vuln 0: zone 0, row 5, col 14 — stand on the row-6 platform
    place(g, 112, 24)
    g.press("b")
    beam_seen = False
    for _ in range(40):
        g.tick()
        if any(vram_tile(g, 5, c) == T_BEAM_FULL for c in range(ZONE_COLS)):
            beam_seen = True
        if g["wGameState"] == DIALOG:
            break
    assert beam_seen, "scan beam should be drawn"
    assert g["wGameState"] == DIALOG, "scan should open the dialog"
    assert g["wVulnScanned"] & 1 and g["wExploitSpawned"] & 1
    g.tick(10)
    assert g.pb.memory[LCDC] & 0x80, "dialog must not switch the LCD off"
    assert g.pb.memory[WY] == 80, "dialog panel should be raised"
    g.press("a")
    assert g["wGameState"] == PLAY and g.pb.memory[WY] == 128
    assert map_tile(g, 5, 14) == T_VULN_SCAN
    assert not vram_matches_map(g), "BG map should match wZoneMap after the beam clears"
    assert not violations, "VRAM written outside VBlank at LY=%s" % violations[:5]
    g.close()


def test_beam_never_overwrites_solid_tiles():
    g = Game(ROM)
    enter_level(g, 0)
    place(g, 112, 24)
    solid_before = [map_tile(g, 5, c) for c in range(ZONE_COLS)]
    g.press("b")
    for _ in range(12):
        g.tick()
    for c in range(ZONE_COLS):
        if 0x61 <= solid_before[c] <= 0x64:
            assert vram_tile(g, 5, c) == solid_before[c], "beam drew over solid tile at col %d" % c
    assert all(map_tile(g, 5, c) == solid_before[c] for c in range(ZONE_COLS)), \
        "beam must never touch the collision map"
    g.close()


def test_pickup_stays_collected():
    g = Game(ROM)
    violations = check_vblank_writes(g)
    enter_level(g, 1)
    # Level 1 exploit 1 lies in zone 0 at row 4, col 9 once spawned
    g["wExploitSpawned"] = 0b10
    goto_zone(g, "R")
    assert g["wZone"] == 1
    goto_zone(g, "L")
    assert g["wZone"] == 0 and map_tile(g, 4, 9) == T_EXPLOIT
    g["wPX"], g["wPY"], g["wPVY"] = 68, 24, 0
    g.tick(2)
    assert g["wGameState"] == DIALOG and g["wExploitHeld"] == 2
    g.tick(10)
    g.press("a")
    assert g["wGameState"] == PLAY
    assert map_tile(g, 4, 9) != T_EXPLOIT and vram_tile(g, 4, 9) != T_EXPLOIT
    assert g.pb.memory[0x9C31] == ord("2") - 0x20, "HUD EXP should show the held exploit"
    goto_zone(g, "R")
    goto_zone(g, "L")
    assert map_tile(g, 4, 9) != T_EXPLOIT, "collected exploit must not respawn on zone reload"
    assert not violations, "VRAM written outside VBlank at LY=%s" % violations[:5]
    g.close()


def test_advisory_costs_hp_then_patches():
    g = Game(ROM)
    enter_level(g, 2)  # level 3: advisories present
    g.tick(70)  # spawn grace
    hits = []
    for _ in range(600):
        if g["wGameState"] != PLAY:
            break
        # Stand on advisory 0 (zone 0) every frame
        g["wPX"], g["wPY"] = g["wAdv0X"], 64
        g.tick()
        if not hits or g["wHealth"] != hits[-1]:
            hits.append(g["wHealth"])
    assert hits[:5] == [4, 3, 2, 1, 0][:len(hits[:5])] and 4 in hits, "HP should drop one at a time: %s" % hits
    g.tick(2)
    assert g["wGameState"] == PATCHED, "0 HP should show the PATCHED screen"
    g.press("a")
    assert g["wGameState"] == MAP
    g.close()


def test_invulnerability_after_hit():
    g = Game(ROM)
    enter_level(g, 2)
    g.tick(70)
    g["wPX"], g["wPY"] = g["wAdv0X"], 64
    g.tick(2)
    assert g["wHealth"] == 4 and g["wInvuln"] > 0
    for _ in range(30):
        g["wPX"], g["wPY"] = g["wAdv0X"], 64
        g.tick()
    assert g["wHealth"] == 4, "i-frames should prevent repeated hits"
    g.close()


def test_boss_contact_damages_player():
    g = Game(ROM)
    konami_to_boss(g)
    g.tick(70)
    for _ in range(40):
        g["wPX"], g["wPY"] = g["wBossX"], 72
        g.tick()
        if g["wHealth"] < 5:
            break
    assert g["wHealth"] == 4, "touching PATCH.EXE mid-arena must hurt"
    assert 20 < g["wBossX"] < 130
    g.close()


def test_boss_beam_must_touch_boss():
    g = Game(ROM)
    konami_to_boss(g)
    place(g, 40, 72)
    # Facing away from the boss: the scan must miss
    g["wPFacing"] = 1
    g["wBossX"] = 80
    g.press("b", frames=1, after=0)
    assert g["wScanActive"], "boss scan should start"
    for _ in range(34):
        g["wBossX"], g["wBossVX"] = 80, 1
        g.tick()
    assert g["wBossHP"] == 3, "beam pointed away must not hit"
    # Facing the boss: hit
    g["wPFacing"] = 0
    g.press("b", frames=1, after=0)
    for _ in range(34):
        g["wBossX"], g["wBossVX"] = 80, 1
        g.tick()
        if g["wBossHP"] < 3:
            break
    assert g["wBossHP"] == 2, "beam reaching the boss should hit"
    g.close()


def test_boss_defeat_and_return_to_title():
    g = Game(ROM)
    violations = check_vblank_writes(g)
    konami_to_boss(g)
    place(g, 40, 72)
    for hit in range(3):
        g["wPFacing"] = 0
        g["wScanActive"] = 0
        g.press("b", frames=1, after=0)
        for _ in range(34):
            if g["wGameState"] != BOSS:
                break
            g["wBossX"], g["wBossVX"], g["wHealth"] = 80, 1, 5
            g.tick()
    assert g["wGameState"] == WIN, "three hits should defeat PATCH.EXE"
    assert not violations, "VRAM written outside VBlank at LY=%s" % violations[:5]
    g.press("start")
    assert g["wGameState"] == TITLE
    g.close()


def test_boss_arena_is_sealed():
    g = Game(ROM)
    konami_to_boss(g)
    g["wPX"], g["wPY"], g["wPVX"] = 151, 72, 24
    g.tick(5)
    assert g["wZone"] == 0 and g["wGameState"] == BOSS, "player must not leave the boss arena"
    g.close()


def test_konami_does_not_leak_stack():
    g = Game(ROM)
    boot_to_map(g)
    sp_before = max(g.pb.register_file.SP for _ in range(3) if g.tick() is None)
    for b in ("up", "up", "down", "down", "left", "right", "left", "right", "b", "a"):
        g.press(b)
    assert g.wait_state(BOSS)
    g.tick(5)
    sp_after = max(g.pb.register_file.SP for _ in range(3) if g.tick() is None)
    assert sp_before == sp_after, "stack pointer drifted: %04X -> %04X" % (sp_before, sp_after)
    assert g["wLevelComplete"] == 0, "cheat must not mark levels complete"
    g.close()


def test_map_cursor_moves_without_blanking():
    g = Game(ROM)
    boot_to_map(g)
    lcd_off = 0
    g.hold("right")
    for _ in range(3):
        g.tick()
        lcd_off += not (g.pb.memory[LCDC] & 0x80)
    g.release()
    g.tick(3)
    assert g["wMapCursor"] == 1
    assert lcd_off == 0, "moving the map cursor must not switch the LCD off"
    assert vram_tile(g, 3, 15) == 0x64 and vram_tile(g, 3, 4) == 0x00, "cursor should move to L2"
    g.close()


def finish_level_0(g):
    """Exploit level 0's last vuln (zone 4, row 5, col 8) with the other two done."""
    enter_level(g, 0)
    g["wVulnScanned"], g["wVulnExploited"], g["wExploitHeld"] = 0b111, 0b011, 3
    goto_zone(g, "RR")
    assert g["wZone"] == 4, "expected zone 4, got %d" % g["wZone"]
    place(g, 64, 16)
    g.press("b")
    assert g.wait_state(MAP, 60), "exploiting the last vuln should finish the level"


def test_save_persists_and_can_be_erased():
    g = Game(ROM)
    finish_level_0(g)
    assert g["wLevelComplete"] == 1
    ram = g.close()

    g = Game(ROM, ram=ram)
    g.tick(120)
    assert g["wLevelComplete"] == 1, "progress should load from cartridge RAM"
    assert g.pb.memory[0x9A00] == ord("[") - 0x20, "title should offer to erase the save"
    g.press("select")
    assert g["wLevelComplete"] == 0
    ram = g.close()

    g = Game(ROM, ram=ram)
    g.tick(120)
    assert g["wLevelComplete"] == 0, "erased save should stay erased"
    g.close()


def test_corrupt_save_is_ignored():
    ram = bytearray(8192)
    ram[0:6] = b"SE01" + bytes([0x1F, 0x00])  # bad checksum
    g = Game(ROM, ram=bytes(ram))
    g.tick(120)
    assert g["wLevelComplete"] == 0
    g.close()


def test_all_levels_cleared_offers_boss_from_map():
    ram = bytearray(8192)
    ram[0:6] = b"SE01" + bytes([0x1F, 0xE0])
    g = Game(ROM, ram=bytes(ram))
    boot_to_map(g)
    g.press("start")
    assert g.wait_state(BOSS, 30), "Start on the map should open the boss fight once all levels are cleared"
    g.close()


def test_runs_on_dmg():
    g = Game(ROM, cgb=False)
    enter_level(g, 0)
    g.hold("right")
    g.tick(30)
    g.release()
    assert g["wGameState"] == PLAY and g["wPX"] > 16
    g.close()


# ---------------------------------------------------------------------------

def main():
    global ROM
    ROM = sys.argv[1] if len(sys.argv) > 1 else "build/sandbox-escape.gb"
    wanted = set(sys.argv[2:])
    tests = [(n, f) for n, f in sorted(globals().items())
             if n.startswith("test_") and callable(f) and (not wanted or n in wanted)]
    failed = 0
    for name, fn in tests:
        try:
            fn()
            print("PASS", name)
        except Exception:
            failed += 1
            print("FAIL", name)
            traceback.print_exc()
    print("\n%d/%d passed" % (len(tests) - failed, len(tests)))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
