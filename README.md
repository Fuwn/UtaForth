# 🌸 UtaForth

> 263-byte 16-bit Forth in pure Netwide Assembler (NASM)

## Files

- [`uta.asm`](uta.asm): Forth source (NASM, `BITS 16`, `ORG 0x100`; assembles to a DOS .COM)
- [`uta.com`](uta.com): Assembled binary (263 bytes)
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

The binary uses only `INT 21h/AH=3F,8`, `INT 29h`, `INT 20h`, and `push sp` (286+ semantics), and assumes only the entry-state conventions the 286-byte build already relied on (BX=0 at .COM entry, DF=0, freshly-booted RAM reading as zero for the EOF sentinel and the chain terminator), so it should run on real DOS as that build did. A 7-byte-smaller emulator-only build exists in history (commit `c8ce7a9`, 256 bytes): it traded `key`'s AH=8 for a CFA-derived AH=1 (echoes on real DOS), the `INT 20h` exit for an executed `0xCC` link byte, the exact `CX=0x2000` read for an entry-state assumption, and a flags-only chain-head overlay for a stray memory write. The `make test` target runs via the bundled Python emulator. Filenames are kept 8.3-compatible.

## What's in 263 Bytes

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

- **Sign-bit dispatch threading.** Each compiled cell is a 16-bit address: a primitive's code sits in the image (well below 0x8000, sign clear), a colon body lives in the heap at `HEAP_BASE = 0xEA8B` and up (sign set). `NEXT = lodsw` into a dispatcher that tests the sign — `jns`/`jmp ax` runs a primitive, negative pushes IP and enters the body directly. The sign test replaces both `docol` as a called routine and the 3-byte `call docol` prologue every colon definition used to carry, and with it the old constraint that `docol` land on an address ending in `0xEA`.
- **Cells are 2 bytes** because the bootstrap hard-codes that (`: cells lit [ 2 , ] ;`, `here @ 2 + here !`).
- **SI = Forth IP, BP = return stack, SP = data stack, AX/BX/CX/DX/DI = scratch.** BX is permanently loaded with `state_struct` after startup, so state variables are accessed as `[bx]`, `[bx+2]`, `[bx+4]`, `[bx+6]`, every 2-3 bytes instead of 4-byte `[disp16]`.
- **The state struct is overlaid on the run-once startup code.** `state`'s initial bytes are `mov cx`'s immediate high byte plus `mov dx`'s opcode (nonzero = execute mode; the first `:` word-writes state and scrubs the dirty high byte), `>in`'s initial `0xC000` *is* `mov dx`'s immediate, and the `latest`/`here` initial values are data bytes that execute harmlessly on the way into the read call — `latest` (the chain head at `0x1A8`) decodes as a flags-only `test al, 1`, and `here`'s value `0xEA8B` decodes as `mov bp, dx`, initialising the return stack for free.
- **Outer interpreter <-> inner interpreter** transition: `xchg ax, si` puts the CFA in AX, SI is parked on `main_loop_cell`, and the dispatcher runs the word; its terminating `jmp NEXT` lodsw's that cell and lands back on `main_loop`. The cell itself costs nothing: it is `!`'s trailing `jmp NEXT` rel8 byte followed by `@`'s length byte, which happen to spell `main_loop`'s address.
- **Input** is slurped once at startup (DOS INT 21h AH=3F). The buffer (zero-initialised) doubles as its own EOF sentinel: when the parser hits a 0 byte, it exits through INT 20h.
- **Dictionary entry layout:** `link(2) | flags|length(1) | name | CFA...`. The CFA is direct code for both primitives and colons (a colon's CFA is its heap body). `latest @ 2 +` is the flags byte (bit 7 = immediate), exactly as the bootstrap expects.
- **Fused headers.** Physical block order is independent of dictionary-chain order (the `dw` links set the chain), and four headers exploit that: their link's low byte *is* the preceding block's last code byte (`rp@`, `!`, and `0#` ride `jmp` rel8 displacements; `;` rides `parse_word`'s `ret`), with only the `0x01` high byte actually emitted. Each fusion pins the chain successor to a fixed `0x01xx` address, so the blocks are arranged by a constraint solve; the source lists every pin. The chain terminator is fused too: `@`'s link field overlaps `!`'s trailing `jmp NEXT` (`EB 18`), a "link" pointing at never-written zero memory that reads as length 0 and link 0.
- **`pushax` tail and fall-through chain.** `0#`, `+`, `nand`, and `key` all end by pushing AX; they share one `pushax:` block that falls through into NEXT, `+`'s code falls straight into `pushax`, and `!` falls into `@`'s fused `jmp NEXT`.

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
| `xchg` for SI round-trip in `parse_word`  | 319 |
| `mov dx, si` inside parse_word skip loop  | 318 |
| `;` jumps to shared compile-and-loop tail | 312 |
| `cfa_key` -> `pushax` -> NEXT fall-through | 310 |
| `jmp ax` directly, drop trampoline stash cell | 304 |
| Relocate `header_semi` for rel8 jump       | 303 |
| Reuse matched header flag in lookup        | 298 |
| Count parse length during scan             | 295 |
| `s@` before DOCOL; reuse `docol - 2` low byte | 293 |
| EOF exits in `parse_word`; keep DOCOL layout | 291 |
| `;` reuses CFA high byte; rebalance DOCOL layout | 290 |
| BP starts at `INPUT_BUFFER`; rebalance DOCOL layout | 289 |
| Pseudo-entry scan + hoisted found `xchg`; reorder `:`/`nand` round DOCOL | 286 |
| Sign-bit dispatch: colon CFA = heap body, DOCOL prologue emitter deleted | 283 |
| Dictionary scan reworked round one shared link-pop miss path | 280 |
| `compile_and_loop` hoisted above `main_loop`, fall-through | 278 |
| Chain-terminator `dw 0` overlapped onto `nand`'s `jmp pushax` | 276 |
| `main_loop_cell` fused from a rel8 byte + `@`'s length byte | 274 |
| `mov ch` loads the read size (CL=0 at entry)             | 272 |
| State struct overlaid on run-once startup code           | 269 |
| Three jmp-rel8/link-low-byte header fusions              | 267 |
| `key` reuses AH=0x01 from its own CFA address            | 265 |
| `int3` EOF stop replaces `INT 20h`                       | 264 |
| `lodsw` fetches links in the dictionary scan             | 263 |
| `parse_word`'s `ret` doubles as `;`'s link low byte      | 262 |
| `here`'s initial value doubles as `mov bp, dx`           | 260 |
| `parse_word` relocated; `nand`'s link fused              | 259 |
| `+` falls into `pushax`; `key`'s link re-fused           | 258 |
| EOF stop rides `0#`'s rel8 (`0xCC`); sixth header fusion | 256 |
| Restore real DOS: AH=8 `key`, INT 20h exit, full CX, flags-only chain head | 263 |

## Licence

This project is licensed under the [MIT License](LICENSE).