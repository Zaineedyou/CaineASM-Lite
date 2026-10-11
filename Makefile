# CaineASM Lite - NASM x86-64 / Linux
NASM    ?= nasm
CC      ?= gcc
SRC     := util json net state ai bot gateway main
OBJ     := $(patsubst %,build/%.o,$(SRC))
# libcurl is linked by its runtime soname so the -dev package is not required
LDLIBS  ?= -l:libcurl.so.4 -pthread

all: caine

build/%.o: src/%.asm src/defs.inc
	@mkdir -p build
	$(NASM) -f elf64 -g -F dwarf -I src/ $< -o $@

caine: $(OBJ)
	$(CC) -o $@ $(OBJ) $(LDLIBS) -Wl,-z,noexecstack

clean:
	rm -rf build caine

.PHONY: all clean
