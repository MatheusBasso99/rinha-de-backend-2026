# Build orchestration. We need picohttpparser compiled to a static .o
# *before* `crystal build` (or `crystal spec`) runs, because src/picohttp.cr
# uses `@[Link(ldflags: "#{__DIR__}/ext/picohttpparser/picohttpparser.o")]`
# to embed the object directly into the final static binary.

CC      ?= cc
CFLAGS  ?= -O3 -fPIC -fno-stack-protector -DNDEBUG

PICO_DIR := src/ext/picohttpparser
PICO_OBJ := $(PICO_DIR)/picohttpparser.o
PICO_SRC := $(PICO_DIR)/picohttpparser.c
PICO_HDR := $(PICO_DIR)/picohttpparser.h

.PHONY: all build release spec clean run

all: build

build: $(PICO_OBJ)
	crystal build src/main.cr -o rinha_de_backend

release: $(PICO_OBJ)
	crystal build --release --no-debug -o rinha_de_backend src/main.cr

spec: $(PICO_OBJ)
	crystal spec

run: build
	./rinha_de_backend

clean:
	rm -f $(PICO_OBJ) rinha_de_backend

$(PICO_OBJ): $(PICO_SRC) $(PICO_HDR)
	$(CC) $(CFLAGS) -c $(PICO_SRC) -o $(PICO_OBJ)
