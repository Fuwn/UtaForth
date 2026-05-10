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
; whatever bytes the OS doesn't fill stay zero (Unicorn/DOS behavior),
; so a 0 byte serves as the EOF sentinel, and we never store/read a length

BITS 16
ORG 0x100

F_IMMEDIATE       equ 0x80
INPUT_BUFFER      equ 0xC000
INPUT_BUFFER_SIZE equ 0x2000
RETURN_STACK_TOP  equ 0xE000

start:
  mov bp, RETURN_STACK_TOP

  ; BX is already 0 at .COM entry (and in Unicorn) -> stdin.
  mov ah, 0x3F
  mov cx, INPUT_BUFFER_SIZE
  mov dx, INPUT_BUFFER
  int 0x21

  mov bx, state_struct

main_loop:
  call parse_word
  jcxz done

  mov di, [bx+4]
.scan:
  test di, di
  jz main_loop
  mov al, [di+2]
  and al, 0x7F
  cmp al, cl
  jne .next

  push di
  push cx
  lea si, [di+3]
  mov di, dx
  repe cmpsb
  pop cx
  pop di
  je found
.next:
  mov di, [di]
  jmp .scan

found:
  ; SI = CFA address (cmpsb advanced past the matched name)
  mov al, [di+2]
  and al, F_IMMEDIATE
  or al, [bx]
  jnz execute_word

  xchg ax, si
compile_and_loop:
  mov di, [bx+6]
  stosw
  mov [bx+6], di
  jmp main_loop

execute_word:
  xchg ax, si
  mov si, main_loop_cell
  jmp ax

done:
  int 0x20

; Returns: DX = name address, CX = length (CX=0 => EOF).
parse_word:
  xchg si, [bx+2]
  xor cx, cx
.skip:
  mov dx, si
  lodsb
  test al, al
  jz .done
  cmp al, ' '
  jbe .skip
.scan:
  lodsb
  cmp al, ' '
  ja .scan
  dec si
  mov cx, si
  sub cx, dx
.done:
  xchg si, [bx+2]
  ret

; State struct: s@ returns the address of state_struct.
;   +0 state  (0=compile, 1=execute)
;   +2 >in    (pointer into input buffer)
;   +4 latest (most-recent dictionary entry)
;   +6 here   (next free byte)
state_struct:
s_state:  dw 1
s_in:     dw INPUT_BUFFER
s_latest: dw last_primitive
s_here:   dw heap_start

main_loop_cell: dw main_loop

; Dictionary entry layout:
;   +0        link         (2 bytes)
;   +2        flags|length (1 byte; bit 7 = immediate)
;   +3        name         (length bytes)
;   +3+length CFA          (direct code; colons begin with `call docol`)

header_at:
  dw 0
  db 1, '@'
cfa_at:
  pop di
  push word [di]
  jmp NEXT

header_store:
  dw header_at
  db 1, '!'
cfa_store:
  pop di
  pop word [di]
  jmp NEXT

header_spat:
  dw header_store
  db 3, 'sp@'
cfa_spat:
  push sp ; 286+ pushes old SP
  jmp NEXT

header_rpat:
  dw header_spat
  db 3, 'rp@'
cfa_rpat:
  push bp
  jmp NEXT

header_zhash:
  dw header_rpat
  db 2, '0#'
cfa_zhash:
  pop ax
  neg ax
  sbb ax, ax
  jmp pushax

header_plus:
  dw header_zhash
  db 1, '+'
cfa_plus:
  pop ax
  pop di
  add ax, di
  jmp pushax

header_nand:
  dw header_plus
  db 4, 'nand'
cfa_nand:
  pop ax
  pop di
  and ax, di
  not ax
  jmp pushax

header_exit:
  dw header_nand
  db 4, 'exit'
cfa_exit:
  mov si, [bp]
  inc bp
  inc bp
  jmp NEXT

header_key:
  dw header_exit
  db 3, 'key'
cfa_key:
  mov ah, 8
  int 0x21
  cbw

; cfa_key, pushax, and NEXT are a fall-through chain: cfa_key drops into
; pushax, pushax drops into NEXT.
pushax:
  push ax
NEXT:
  lodsw
  jmp ax

; DOCOL is invoked by every colon definition's `call docol` prologue.
; The CALL has pushed the body start onto SP (briefly polluting the data
; stack); we save the current IP to the return stack, then `pop si` lifts
; the body off SP.
docol:
  dec bp
  dec bp
  mov [bp], si
  pop si
  jmp NEXT

header_emit:
  dw header_key
  db 4, 'emit'
cfa_emit:
  pop ax
  int 0x29 ; DOS fast console output (AL -> stdout)
  jmp NEXT

header_sat:
  dw header_emit
  db 2, 's@'
cfa_sat:
  push bx
  jmp NEXT

header_colon:
  dw header_sat
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

  mov al, 0xE8     ; CALL rel16: emit `call docol` as the colon prologue
  stosb
  mov ax, docol - 2
  sub ax, di
  stosw

  mov [bx+6], di
  mov [bx], cl ; CX is 0 after rep movsb -> compile mode
  jmp NEXT

header_semi:
  dw header_colon
  db F_IMMEDIATE|1, ';'
cfa_semi:
  mov ax, cfa_exit
  inc byte [bx] ; the ; word is only legal in compile mode (state=0 -> 1)
  jmp compile_and_loop

last_primitive equ header_semi

heap_start:
