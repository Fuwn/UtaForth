.PHONY: all clean test hello bf

all: uta.com

uta.com: uta.asm
	nasm -f bin $< -o $@

clean:
	rm -f uta.com uta.lst

test: hello bf

hello: uta.com
	@python3 run.py uta.com hello.fth
	@echo

bf: uta.com
	@python3 run.py uta.com bf.fth
	@echo
