# Build orchestration. The HTTP parser is now 100% Crystal
# (`src/http_parser.cr`), so there is no extra C compilation step —
# `crystal build` is the whole pipeline.

.PHONY: all build release spec clean run

all: build

build:
	crystal build src/main.cr -o rinha_de_backend

release:
	crystal build --release --no-debug -o rinha_de_backend src/main.cr

spec:
	crystal spec

run: build
	./rinha_de_backend

clean:
	rm -f rinha_de_backend
