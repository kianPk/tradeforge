.PHONY: install build test test-v fmt clean demo

install:
	forge install

build:
	forge build

test:
	forge test -q

test-v:
	forge test -vvv

fmt:
	forge fmt

clean:
	forge clean

demo:
	@echo "Open docs/index.html via GitHub Pages after push"
