# 🌸 UtaForth

> 322-byte 16-bit Forth in pure Netwide Assembler (NASM)

## Files

- [`uta.asm`](uta.asm): Forth source (NASM, `BITS 16`, `ORG 0x100`; assembles to a DOS .COM)
- [`uta.com`](uta.com): Assembled binary (322 bytes)
- [`run.py`](run.py): Minimal Unicorn-based 8086 emulator that loads `uta.com` and dispatches DOS INT 20h/21h/29h
- [`bf.fth`](bf.fth), [`hello.fth`](hello.fth): Sample Forth programs

## Build & Run

```sh
brew install nasm unicorn
python3 -m venv .venv && .venv/bin/pip install unicorn
make      # uta.com
make test # Runs both sample files
python3 run.py uta.com hello.fth
python3 run.py uta.com bf.fth
```

Verified under DOSBox-X (`uta.com < hello.fth`, `uta.com < bf.fth`). The binary uses only `INT 21h/AH=3F,8`, `INT 29h`, `INT 20h`, and `push sp` (286+ semantics), so it should also run on real DOS. The `make test` target runs via the bundled Python emulator. Filenames are kept 8.3-compatible.

## What's in 322 Bytes

13 primitives, the only ones the bootstrap can't define for itself:

| Word    | Required | Role |
| ------- | -------- | ----- |
| `@`     | Yes      | Fetch |
| `!`     | Yes      | Store |
| `sp@`   | Yes      | Data-stack pointer |
| `rp@`   | Yes      | Return-stack pointer |
| `0#`    | Yes      | Non-zero flag |
| `+`     | Yes      | Sum |
| `nand`  | Yes      | NAND |
| `exit`  | Yes      | Return from word |
| `key`   | Yes      | Read key (DOS INT 21h/AH=8) |
| `emit`  | Yes      | Emit character (DOS INT 29h) |
| `s@`    | Yes      | State-struct pointer |
| `:`     | (Must)   | Parses next word, lays down a header, enters compile mode |
| `;`     | (Must)   | Compiles `exit`, returns to interpret mode (immediate) |

Everything else (`dup`, `drop`, `over`, `swap`, `if`/`then`, `do`/`loop`, `c@`, `type`, `."`, ...) is built up by the user's bootstrap.

## Architecture

- **Direct-threaded code (DTC).** Each compiled cell is a 16-bit address of executable code. For primitives that's the body itself; for colon definitions it's a `call docol` prologue followed by the body cells. `NEXT = lodsw/jmp ax` (3 bytes).
- **Cells are 2 bytes** because the bootstrap hard-codes that (`: cells lit [ 2 , ] ;`, `here @ 2 + here !`).
- **SI = Forth IP, BP = return stack, SP = data stack, AX/BX/CX/DX/DI = scratch.** BX is permanently loaded with `state_struct` after startup, so state variables are accessed as `[bx]`, `[bx+2]`, `[bx+4]`, `[bx+6]`, every 2–3 bytes instead of 4-byte `[disp16]`.
- **Outer interpreter <-> inner interpreter** transition via a 4-byte trampoline: stash the target CFA at `tramp[0]`, set SI to `tramp`, `jmp NEXT`. After the word finishes, its `jmp NEXT` lodsw's `tramp[2]` and `jmp ax` lands on `main_loop`.
- **Input** is slurped once at startup (DOS INT 21h AH=3F). The buffer (zero-initialised) doubles as its own EOF sentinel: when the parser hits a 0 byte, it returns CX=0.
- **Dictionary entry layout:** `link(2) | flags|length(1) | name | CFA...`. The CFA is direct code (primitives) or a `call docol` prologue plus body cells (colons). `latest @ 2 +` is the flags byte (bit 7 = immediate), exactly as the bootstrap expects.
- **NEXT lives in the middle of the primitives section** so every primitive's `jmp NEXT` is a 2-byte short jump.
- **`pushax` tail.** Four primitives (`0#`, `+`, `nand`, `key`) all end with `push ax; jmp NEXT`. A single shared `pushax:` block (3 bytes) replaces four 3-byte tails, saving 1 byte net while keeping every primitive's entry at a 2-byte short-jump distance from NEXT.

## Notes on the Test Files

`bf.fth` and `hello.fth` are adapted from the [milliForth](https://github.com/fuzzballcat/milliForth) samples. Three changes from the originals:

1. **`runbf` bug fix.** The original did `0 parse_index !` and read `parse_index @ c@`, dereferencing a 0-based offset as an absolute address. It works in milliForth because that Forth's input buffer happens to live at low memory; in UtaForth (input at `0xC000`), it walks PSP/code/zeros and prints nothing. Replaced `parse_index @ c@` with `over parse_index @ + c@` (3 occurrences) so it indexes into the address returned by `parse`.
2. **`0fh` removed.** `ffh` rewritten as `lit [ 80h 2* 1 - , ]`. `0fh` was only invoked at compile-time of `ffh`, so its dictionary entry was dead weight.
3. **`in>` tightened.** `>in @ c@ >in dup @ 1 + swap !` -> `>in @ dup c@ swap 1 + >in !` (one fewer cell).

`hello.fth` prints `hello, world`. `bf.fth` runs an embedded Brainfuck "Hello, World!".

## Sizes (History)

| Step                                    | Bytes |
| --------------------------------------- | ----- |
| First working version                   | 443 |
| Omit `input_end`, single `parse_word` exit | 410 |
| Drop `not_found`, `INT 20h` for exit     | 400 |
| `mov al, [di+2]` + `and al, 0x7F`        | 398 |
| `pop dx` instead of `pop ax; mov dl, al` | 396 |
| `inc bp;inc bp`/`dec bp;dec bp`          | 394 |
| `push sp` (286+ semantics)               | 392 |
| Skip `xor bx, bx` (BX=0 at entry)        | 390 |
| `inc byte [s_state]` in `;`              | 389 |
| Compact `parse_word` scan loop           | 388 |
| `INT 29h` for emit                       | 386 |
| Direct-threaded code (drop CFA cells)    | 363 |
| Reposition NEXT mid-primitives           | 354 |
| `found:` reuses post-`cmpsb` SI as CFA   | 349 |
| Merge immediate/state test into one OR   | 347 |
| `pop si` in DOCOL, fall through to NEXT  | 344 |
| `push imm16` for `s@`; `xchg` link in `:` | 342 |
| Remove `cld` (DF=0 at COM entry)         | 341 |
| `cbw` in `key`; shared `pushax` tail     | 340 |
| `lodsb` in `parse_word` (SI with push/pop)| 338 |
| BX = permanent state-struct pointer       | 322 |

## Licence

This project is licensed under the [MIT License](LICENSE).