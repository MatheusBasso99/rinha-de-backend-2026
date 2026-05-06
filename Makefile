# Build orchestration. The HTTP parser is now 100% Crystal
# (`src/http_parser.cr`), so there is no extra C compilation step —
# `crystal build` is the whole pipeline.
#
# Binaries:
#   - rinha_de_backend : the API server (single-threaded hot path).
#   - rinha_lb         : legacy Crystal LB over Unix Domain Sockets,
#                        built with -Dpreview_mt -Dexecution_context to
#                        unlock Fiber::ExecutionContext::Parallel. The
#                        production LB is now HAProxy (see haproxy.cfg
#                        and the `lb` service in docker-compose.yml);
#                        this target is kept for reference / fallback
#                        and the binary is no longer the prod entrypoint.

.PHONY: all build release lb lb-release spec clean run

all: build lb

build:
	crystal build src/main.cr -o rinha_de_backend

release:
	crystal build --release --no-debug --mcpu=haswell -o rinha_de_backend src/main.cr

lb:
	crystal build -Dpreview_mt -Dexecution_context src/lb_main.cr -o rinha_lb

lb-release:
	crystal build --release --no-debug --mcpu=haswell -Dpreview_mt -Dexecution_context -o rinha_lb src/lb_main.cr

spec:
	crystal spec

run: build
	./rinha_de_backend

clean:
	rm -f rinha_de_backend rinha_lb
