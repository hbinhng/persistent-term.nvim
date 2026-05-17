.PHONY: build test lint clean deps go-build go-test go-lint lua-test lua-lint release

ROOT := $(shell pwd)
GO_BIN := $(ROOT)/go/bin/persistent-term-pipe
NVIM ?= nvim

deps:
	./tests/setup.sh

clean:
	rm -rf go/bin dist .deps

go-build:
	mkdir -p go/bin
	cd go && go build -o bin/persistent-term-pipe .

go-test:
	cd go && go test -race ./...

go-lint:
	cd go && go vet ./...
	cd go && gofmt -l . | (! grep .)

lua-test: deps
	$(NVIM) --headless -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/spec/ {minimal_init='tests/minimal_init.lua'}"

lua-lint:
	luacheck lua/ tests/
	stylua --check lua/ tests/

build: go-build

test: go-build go-test lua-test

lint: go-lint lua-lint

release:
	mkdir -p dist
	@for combo in linux/amd64 linux/arm64 darwin/amd64 darwin/arm64; do \
		os=$${combo%/*}; arch=$${combo#*/}; \
		out="dist/persistent-term-pipe-$$os-$$arch"; \
		echo "building $$out"; \
		(cd go && GOOS=$$os GOARCH=$$arch CGO_ENABLED=0 go build -trimpath -o ../$$out .); \
		sha256sum $$out | awk '{print $$1}' > $$out.sha256; \
	done
	@ls -la dist/
