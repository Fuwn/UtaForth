.PHONY: all clean test hello bf

PYTHON := $(if $(wildcard .venv/bin/python3),.venv/bin/python3,python3)

all: uta.com

uta.com: uta.asm
	nasm -f bin $< -o $@

clean:
	rm -f uta.com uta.lst

test: hello bf

hello: uta.com
	@$(PYTHON) run.py uta.com hello.fth
	@echo

bf: uta.com
	@$(PYTHON) run.py uta.com bf.fth
	@echo
