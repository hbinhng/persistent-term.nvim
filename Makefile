.PHONY: build test lint clean deps go-build go-test go-lint lua-test lua-lint

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
