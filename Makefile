.PHONY: build test lint clean deps

deps:
	./tests/setup.sh

clean:
	rm -rf go/bin dist .deps

# Real targets are added in later tasks as code/tests land.
build:
	@echo "build: nothing to do yet (no Go sources)"

test:
	@echo "test: nothing to do yet"

lint:
	@echo "lint: nothing to do yet"
