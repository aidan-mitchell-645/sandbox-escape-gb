RGBASM  = rgbasm
RGBLINK = rgblink
RGBFIX  = rgbfix

SRCDIR  = src
BUILDDIR = build

ROM     = $(BUILDDIR)/sandbox-escape.gb
SYM     = $(BUILDDIR)/sandbox-escape.sym
MAP     = $(BUILDDIR)/sandbox-escape.map
OBJ     = $(BUILDDIR)/main.o

INCLUDES = $(SRCDIR)/hardware.inc \
           $(SRCDIR)/font.inc \
           $(SRCDIR)/tiles.inc \
           $(SRCDIR)/sprites.inc \
           $(SRCDIR)/strings.inc \
           $(SRCDIR)/levels.inc \
           $(SRCDIR)/music.inc

.PHONY: all clean test

all: $(ROM)

$(BUILDDIR):
	mkdir -p $(BUILDDIR)

$(OBJ): $(SRCDIR)/main.asm $(INCLUDES) | $(BUILDDIR)
	$(RGBASM) -i $(SRCDIR)/ -o $@ $<

$(ROM): $(OBJ)
	$(RGBLINK) -n $(SYM) -m $(MAP) -o $@ $<
	$(RGBFIX) -v -p 0xFF -m MBC1+RAM+BATTERY -r 2 $@

clean:
	rm -rf $(BUILDDIR)

test: $(ROM)
	python3 tests/test_game.py $(ROM)
