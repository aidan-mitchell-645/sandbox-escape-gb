RGBASM  = rgbasm
RGBLINK = rgblink
RGBFIX  = rgbfix

SRCDIR  = src
BUILDDIR = build

ROM     = $(BUILDDIR)/sandbox-escape.gb
OBJ     = $(BUILDDIR)/main.o

INCLUDES = $(SRCDIR)/hardware.inc \
           $(SRCDIR)/font.inc \
           $(SRCDIR)/tiles.inc \
           $(SRCDIR)/sprites.inc \
           $(SRCDIR)/strings.inc \
           $(SRCDIR)/levels.inc

.PHONY: all clean

all: $(ROM)

$(BUILDDIR):
	mkdir -p $(BUILDDIR)

$(OBJ): $(SRCDIR)/main.asm $(INCLUDES) | $(BUILDDIR)
	$(RGBASM) -i $(SRCDIR)/ -o $@ $<

$(ROM): $(OBJ)
	$(RGBLINK) -o $@ $<
	$(RGBFIX) -v -p 0xFF -m MBC1 $@

clean:
	rm -rf $(BUILDDIR)
