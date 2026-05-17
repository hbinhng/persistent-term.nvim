.PHONY: test lua-test lua-lint clean deps

ROOT := $(shell pwd)
NVIM ?= nvim

deps:
	./tests/setup.sh

clean:
	rm -rf .deps

lua-test: deps
	$(NVIM) --headless -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/spec/ {minimal_init='tests/minimal_init.lua'}"

lua-lint:
	luacheck lua/ tests/
	stylua --check lua/ tests/

test: lua-test
