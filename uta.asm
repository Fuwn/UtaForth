; UtaForth - 16-bit direct-threaded Forth as a DOS .COM file
;
; Build: nasm -f bin uta.asm -o uta.com
; Run:   python3 run.py uta.com bf.fth
;
; Register convention while Forth is executing:
;   SI             = Forth IP (next compiled cell)
;   SP             = data stack
;   BP             = return stack
;   AX/BX/CX/DX/DI = scratch
;
; The outer interpreter (between Forth dispatches) freely uses CALL/RET
; on SP because pushes are always balanced by pops, leaving the user's
; data stack contents undisturbed.
;
; Memory layout: input buffer at 0xC000 is read once at startup;
; BP starts there too, so the return stack grows below the input buffer;
; the heap grows up from HEAP_BASE = 0xEA8B, ABOVE the buffer end
; (0xE000), toward the data stack descending from 0xFFFE; whatever bytes
; the OS doesn't fill stay zero (Unicorn/freshly-booted DOS behavior),
; so a 0 byte serves as the EOF sentinel, and we never store/read a
; length.
;
; The state struct (s@ returns its address) is overlaid on the run-once
; startup code; see the comments at `start`. Layout, hard-coded by the
; .fth bootstrap:
;   +0 state  (0=compile, nonzero=execute)
;   +2 >in    (pointer into input buffer)
;   +4 latest (most-recent dictionary entry)
;   +6 here   (next free byte)

BITS 16
ORG 0x100

F_IMMEDIATE       equ 0x80
INPUT_BUFFER      equ 0xC000
INPUT_BUFFER_SIZE equ 0x2000
; Sign bit set, so the dispatcher can tell colon bodies from primitives.
; 0x8B 0xEA is also the encoding of `mov bp, dx`: the s_here data bytes
; below double as that instruction, which is why no explicit mov exists.
HEAP_BASE         equ 0xEA8B

start:
  ; The state struct's eight bytes are carved out of the run-once startup
  ; instructions: state overlays [0x20][0xBA] (mov cx's immediate high
  ; byte + mov dx's opcode), >in overlays mov dx's 0xC000 immediate, and
  ; latest+here are literal data that execute as live code: header_exit,
  ; the chain head, is pinned at 0x1A8, so the latest bytes A8 01 decode
  ; as `test al, 1` (flags only -- benign on real DOS regardless of
  ; entry state), and the HEAP_BASE bytes 8B EA decode as `mov bp, dx`
  ; -- the return-stack init rides for free inside the struct.
  ; Initial state is 0xBA20 -- nonzero = execute mode, per contract; the
  ; first `:` word-writes state (mov [bx], cx) and cleans the high byte.
  mov ah, 0x3F
  mov cx, INPUT_BUFFER_SIZE
state_struct equ $ - 1
  mov dx, INPUT_BUFFER
  dw header_exit ; s_latest; executes as test al, 1 (benign)
  dw HEAP_BASE   ; s_here = 0xEA8B; executes as mov bp, dx
  int 0x21

  mov bx, state_struct

; Startup falls through into compile_and_loop, harmlessly compiling one
; garbage cell (AX = bytes read) at HEAP_BASE; here just starts 2 higher.
; In exchange, compile_and_loop falls into main_loop with no jmp.
; No pad: main_loop lands on 0x118, matching the terminator's fused jmp
; rel8 (see main_loop_cell below).
compile_and_loop:
  mov di, [bx+6]
  stosw
  mov [bx+6], di

main_loop:
  call parse_word

  ; Walk the dictionary chain. lodsw fetches each candidate's link (AX is
  ; dead here; DF=0) and leaves SI on the flags byte; the link is pushed
  ; before the length test, so both miss paths share one pop straight into
  ; DI and loop, and a match pops it as a dead value. lodsb then fetches
  ; flags|length and leaves SI on the name for cmpsb (clobbering SI here is
  ; fine: parse_word self-heals it via the xchg with >in). A name match
  ; falls through to found.
  mov di, [bx+4]
.scan:
  test di, di
  jz main_loop
  mov si, di
  lodsw
  push ax
  lodsb
  xor al, cl
  test al, 0x7F
  jne .miss

  push cx
  mov di, dx
  repe cmpsb
  pop cx
.miss:
  pop di
  jne .scan

found:
  ; SI = CFA (cmpsb advanced past the matched name). The shared xchg
  ; (AX<->SI, so AX=CFA) is hoisted above the branch; xchg leaves flags
  ; untouched, so jz still tests the or result.
  or al, [bx]
  xchg ax, si
  jz compile_and_loop

execute_word:
  mov si, main_loop_cell
  jmp dispatch

; Dictionary entry layout:
;   +0        link         (2 bytes)
;   +2        flags|length (1 byte; bit 7 = immediate)
;   +3        name         (length bytes)
;   +3+length CFA          (direct code; a colon's CFA is its body itself)
;
; Physical order is independent of chain order (set by the dw links).
; Pinned placements (check the listing after any edit):
;  - header_store's fused `jmp NEXT` must assemble with rel8 0x18 so
;    that rel8 plus '@''s length byte 0x01 right after it read as the
;    word 0x0118 = main_loop; main_loop_cell equ header_at+1 names that
;    pair. Both bytes are immutable at runtime.
;  - header_exit, the chain head (s_latest), must land at 0x1A8 so the
;    overlaid latest field in the startup executes harmlessly on real
;    DOS too (see start).
;  - header_colon must land at 0x1C3, the target of ';''s ret-fused
;    link (see header_semi).
;  - header_rpat is a fused header: its link low byte is cfa_spat's
;    `jmp NEXT` rel8 (0x4C), so rp@'s chain successor must be the entry
;    at 0x14C -- header_spat lands exactly there; only the 0x01 high
;    byte is emitted.
;  - header_store is fused the same way off cfa_semi's jmp
;    compile_and_loop rel8 (0x90), so !'s chain successor must be the
;    entry at 0x190 -- header_sat lands exactly there.
;  - header_zhash is fused off cfa_exit's jmp NEXT rel8 (0xEB), so 0#'s
;    chain successor must be the entry at 0x1EB -- header_nand lands
;    exactly there.
;  - cfa_exit shares cfa_semi's 0x1xx page for the mov al trick.
;  - done must stay in rel8 range of parse_word's jz.

header_emit:
  dw header_rpat
  db 4, 'emit'
cfa_emit:
  pop ax
  int 0x29 ; DOS fast console output (AL -> stdout)
  jmp NEXT

header_spat:
  dw header_semi
  db 3, 'sp@'
cfa_spat:
  push sp ; 286+ pushes old SP
  jmp NEXT

; Fused link: low byte is cfa_spat's jmp NEXT rel8 above (0x4C) pointing
; at sp@, high byte is the emitted 0x01.
header_rpat equ $ - 1
  db 0x01
  db 3, 'rp@'
cfa_rpat:
  push bp
  jmp NEXT

; Returns: DX = name address, CX = length. EOF exits through done.
parse_word:
  xchg si, [bx+2]
  xor cx, cx
.skip:
  mov dx, si
  lodsb
  test al, al
  jz done
  cmp al, ' '
  jbe .skip
.scan:
  inc cx
  lodsb
  cmp al, ' '
  ja .scan
  dec si
.done:
  xchg si, [bx+2]

; header_semi starts ON parse_word's ret: the 0xC3 ret byte doubles as
; the low byte of ';''s link field, so with the emitted 0x01 the link
; reads C3 01 = 0x01C3 -- ';''s chain successor must be the entry at
; 0x1C3; header_colon is silently pinned there by the block order below
; (check the listing after any edit). The ret still executes normally;
; the scan only ever reads it as data.
header_semi:
  ret
  db 0x01 ; link high byte; with the ret it spells dw header_colon
  db F_IMMEDIATE|1, ';'
cfa_semi:
  mov al, cfa_exit
  inc byte [bx] ; the ; word is only legal in compile mode (state=0 -> 1)
  jmp compile_and_loop

; Fused link: low byte is cfa_semi's jmp compile_and_loop rel8 above
; (0x90) pointing at s@, high byte is the emitted 0x01.
header_store equ $ - 1
  db 0x01
  db 1, '!'
cfa_store:
  pop di
  pop word [di]

; The '@' entry terminates the dictionary chain, and its 2-byte link
; field physically overlaps cfa_store's trailing `jmp NEXT` (bytes
; EB 18, read as a link of 0x18EB). That address lies between the
; program image and the return stack's reach, memory nothing ever
; writes, so the flags byte there is 0 (never matches a 1..127-length
; word) and its own link reads as 0, ending the scan exactly like an
; explicit `dw 0` would.
header_at:
  jmp NEXT
  db 1, '@'
cfa_at:
  pop di
  push word [di]
  jmp NEXT

; store's jmp rel8 (0x18) and '@''s length byte (0x01) read as the word
; 0x0118 = main_loop, so NEXT returns the interpreter to the main loop
; without a dedicated `dw main_loop` cell.
main_loop_cell equ header_at + 1

; Pinned at 0x190, the target of !'s fused link.
header_sat:
  dw header_emit
  db 2, 's@'
cfa_sat:
  push bx
  jmp NEXT

; + ends the sat..pushax gap: its code falls straight into pushax, which
; pushes the sum -- the trailing `jmp pushax` is saved.
header_plus:
  dw header_store
  db 1, '+'
cfa_plus:
  pop ax
  pop di
  add ax, di

; cfa_plus and NEXT are a fall-through chain: cfa_plus drops into
; pushax, pushax drops into NEXT.
;
; Threading: a compiled cell is either a primitive's code address (below
; 0x8000, sign clear) or a colon body in the heap (HEAP_BASE and up, sign
; set), so the dispatcher's sign test replaces both docol and the per-word
; `call docol` prologue.
pushax:
  push ax
NEXT:
  lodsw
dispatch:
  or ax, ax
  js docol
  jmp ax

; The chain head, pinned at 0x1A8 (see start).
header_exit:
  dw header_plus
  db 4, 'exit'
cfa_exit:
  mov si, [bp]
  inc bp
  inc bp
  jmp NEXT

; Fused link: low byte is cfa_exit's jmp NEXT rel8 above (0xEB) pointing
; at nand, high byte is the emitted 0x01.
header_zhash equ $ - 1
  db 0x01
  db 2, '0#'
cfa_zhash:
  pop ax
  neg ax
  sbb ax, ax
  jmp pushax

; EOF stop: a clean DOS exit, in rel8 range of parse_word's jz.
done:
  int 0x20

; Pinned at 0x1C3, the target of ';''s ret-fused link (see header_semi).
header_colon:
  dw header_zhash
  db 1, ':'
cfa_colon:
  call parse_word
  mov di, [bx+6]
  mov ax, di
  xchg ax, [bx+4]
  stosw
  mov al, cl
  stosb

  push si
  mov si, dx
  rep movsb
  pop si

  mov [bx+6], di
  mov [bx], cx ; CX is 0 after rep movsb -> compile mode (word write
               ; also scrubs the startup-dirty high byte of state)
  jmp NEXT

docol:
  dec bp
  dec bp
  mov [bp], si
  xchg ax, si
  jmp NEXT

; Pinned at 0x1EB, the target of 0#'s fused link.
header_nand:
  dw header_key
  db 4, 'nand'
cfa_nand:
  pop ax
  pop di
  and ax, di
  not ax
  jmp pushax

header_key:
  dw header_at
  db 3, 'key'
cfa_key:
  mov ah, 8
  int 0x21
  cbw
  jmp pushax
