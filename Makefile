.PHONY: build test lint clean deps go-build go-test go-lint

ROOT := $(shell pwd)
GO_BIN := $(ROOT)/go/bin/persistent-term-pipe

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

build: go-build

test: go-build go-test

lint: go-lint
