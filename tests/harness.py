"""Headless PyBoy harness for Sandbox Escape tests.

Reads the linker's .sym file so tests address WRAM by label, not by
hard-coded address.
"""

import io
import os

from pyboy import PyBoy

BUTTONS = ("a", "b", "start", "select", "up", "down", "left", "right")


def load_symbols(sym_path):
    syms = {}
    with open(sym_path) as f:
        for line in f:
            line = line.split(";", 1)[0].strip()
            if not line:
                continue
            addr, name = line.split()
            bank, off = addr.split(":")
            syms[name] = (int(bank, 16), int(off, 16))
    return syms


class Game:
    def __init__(self, rom_path, sym_path=None, cgb=True, ram=None):
        """ram: cartridge RAM image to boot with (default: blank, so a stray
        .ram file next to the ROM never leaks into a test)."""
        sym_path = sym_path or os.path.splitext(rom_path)[0] + ".sym"
        self.sym = load_symbols(sym_path)
        ram_file = io.BytesIO(ram if ram is not None else bytes(8192))
        self.pb = PyBoy(rom_path, window="null", sound_emulated=False, cgb=cgb,
                        ram_file=ram_file)
        self.pb.set_emulation_speed(0)
        self.held = set()

    def close(self):
        """Stop the emulator and return the cartridge RAM image."""
        out = io.BytesIO()
        self.pb.stop(save=True, ram_file=out)
        return out.getvalue()

    def hook(self, name, callback):
        bank, addr = self.sym[name]
        self.pb.hook_register(bank, addr, callback, None)

    # --- memory -----------------------------------------------------------
    def addr(self, name):
        return self.sym[name][1]

    def __getitem__(self, name):
        return self.pb.memory[self.addr(name)]

    def __setitem__(self, name, value):
        self.pb.memory[self.addr(name)] = value & 0xFF

    def const(self, name):
        return self.sym[name][1]

    # --- time / input -----------------------------------------------------
    def tick(self, frames=1):
        for _ in range(frames):
            self.pb.tick(1, False)

    def hold(self, *buttons):
        for b in buttons:
            if b not in self.held:
                self.pb.button_press(b)
                self.held.add(b)

    def release(self, *buttons):
        for b in buttons or tuple(self.held):
            if b in self.held:
                self.pb.button_release(b)
                self.held.discard(b)

    def press(self, button, frames=2, after=4):
        self.hold(button)
        self.tick(frames)
        self.release(button)
        self.tick(after)

    def wait_state(self, state, limit=600):
        for _ in range(limit):
            if self["wGameState"] == state:
                return True
            self.tick()
        return False

    def screenshot(self, path):
        self.pb.tick(1, True)
        self.pb.screen.image.save(path)


# Game state values (mirror STATE_* in main.asm)
TITLE, INTRO, PLAY, DIALOG, WIN, MAP, PATCHED, BOSS = range(8)


def boot_to_map(g):
    # The CGB boot ROM animation runs for ~60 frames before the game starts.
    for _ in range(300):
        g.tick()
        if g["wFrame"] > 10:
            break
    g.press("start")
    assert g.wait_state(INTRO), "title did not advance to intro"
    for _ in range(3):
        g.press("a")
    assert g.wait_state(MAP), "intro did not reach world map"


def enter_level(g, level):
    boot_to_map(g)
    for _ in range(level):
        g.press("right")
    g.press("a")
    assert g.wait_state(PLAY), "level did not start"
    g.tick(5)


def konami_to_boss(g):
    boot_to_map(g)
    for b in ("up", "up", "down", "down", "left", "right", "left", "right", "b", "a"):
        g.press(b)
    assert g.wait_state(BOSS), "Konami code did not open boss fight"
    g.tick(5)
