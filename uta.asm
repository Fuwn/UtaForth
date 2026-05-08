; UtaForth - 16-bit indirect-threaded Forth as a DOS .COM file
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
; so a 0 byte serves as the EOF sentinel, and we never store/read a length.

BITS 16
ORG 0x100

F_IMMEDIATE       equ 0x80
INPUT_BUFFER      equ 0xC000
INPUT_BUFFER_SIZE equ 0x2000
RETURN_STACK_TOP  equ 0xE000

start:
  mov bp, RETURN_STACK_TOP
  cld

  ; BX is already 0 at .COM entry (and in Unicorn) -> stdin.
  mov ah, 0x3F
  mov cx, INPUT_BUFFER_SIZE
  mov dx, INPUT_BUFFER
  int 0x21

main_loop:
  call parse_word
  jcxz done

  mov di, [s_latest]
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
  mov di, bx
  repe cmpsb
  pop cx
  pop di
  je found
.next:
  mov di, [di]
  jmp .scan

found:
  add cx, di
  add cx, 3

  test byte [di+2], F_IMMEDIATE
  jnz .execute
  cmp word [s_state], 0
  jne .execute

  mov di, [s_here]
  mov ax, cx
  stosw
  mov [s_here], di
  jmp main_loop
.execute:
  mov [trampoline], cx
  mov si, trampoline
  jmp NEXT

done:
  int 0x20

NEXT:
  lodsw
  xchg ax, bx
  jmp [bx]

; DOCOL: code address used by every colon definition's CFA cell.
; When NEXT jumps here, BX holds the CFA cell address; the body
; starts immediately after it.
docol:
  dec bp
  dec bp
  mov [bp], si
  lea si, [bx+2]
  jmp NEXT

; Returns: BX = name address, CX = length (CX=0 => EOF).
parse_word:
  mov di, [s_in]
  xor cx, cx
.skip:
  mov al, [di]
  test al, al
  jz .done
  inc di
  cmp al, ' '
  jbe .skip
  lea bx, [di-1]
.scan:
  mov al, [di]
  inc di
  cmp al, ' '
  ja .scan
  dec di
  mov cx, di
  sub cx, bx
.done:
  mov [s_in], di
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

; The outer interpreter executes a single word by parking its CFA
; in trampoline[0], then setting SI to trampoline and jumping to NEXT. After
; that word finishes, NEXT loads bye_cfa, whose code-field jumps
; back into the interpreter loop.
trampoline: dw 0
            dw bye_cfa
bye_cfa:    dw main_loop

; Dictionary entry layout:
;   +0 link         (2 bytes)
;   +2 flags|length (1 byte; bit 7 = immediate)
;   +3 name         (length bytes)
;   +3+length CFA   (2 bytes; value is the code address)
;   +5+length body  (colon definitions only)

header_at:
  dw 0
  db 1, '@'
cfa_at:
  dw $+2
  pop bx
  push word [bx]
  jmp NEXT

header_store:
  dw header_at
  db 1, '!'
cfa_store:
  dw $+2
  pop bx
  pop word [bx]
  jmp NEXT

header_spat:
  dw header_store
  db 3, 'sp@'
cfa_spat:
  dw $+2
  push sp ; 286+ pushes old SP
  jmp NEXT

header_rpat:
  dw header_spat
  db 3, 'rp@'
cfa_rpat:
  dw $+2
  push bp
  jmp NEXT

header_zhash:
  dw header_rpat
  db 2, '0#'
cfa_zhash:
  dw $+2
  pop ax
  neg ax
  sbb ax, ax
  push ax
  jmp NEXT

header_plus:
  dw header_zhash
  db 1, '+'
cfa_plus:
  dw $+2
  pop ax
  pop bx
  add ax, bx
  push ax
  jmp NEXT

header_nand:
  dw header_plus
  db 4, 'nand'
cfa_nand:
  dw $+2
  pop ax
  pop bx
  and ax, bx
  not ax
  push ax
  jmp NEXT

header_exit:
  dw header_nand
  db 4, 'exit'
cfa_exit:
  dw $+2
  mov si, [bp]
  inc bp
  inc bp
  jmp NEXT

header_key:
  dw header_exit
  db 3, 'key'
cfa_key:
  dw $+2
  mov ah, 8
  int 0x21
  xor ah, ah
  push ax
  jmp NEXT

header_emit:
  dw header_key
  db 4, 'emit'
cfa_emit:
  dw $+2
  pop ax
  int 0x29 ; DOS fast console output (AL -> stdout)
  jmp NEXT

header_sat:
  dw header_emit
  db 2, 's@'
cfa_sat:
  dw $+2
  mov ax, state_struct
  push ax
  jmp NEXT

header_colon:
  dw header_sat
  db 1, ':'
cfa_colon:
  dw $+2
  call parse_word
  mov di, [s_here]
  mov ax, [s_latest]
  mov [s_latest], di
  stosw
  mov al, cl
  stosb

  push si
  mov si, bx
  rep movsb
  pop si

  mov ax, docol
  stosw
  mov [s_here], di
  mov [s_state], cl ; CX is 0 after rep movsb -> compile mode
  jmp NEXT

header_semi:
  dw header_colon
  db F_IMMEDIATE|1, ';'
cfa_semi:
  dw $+2
  mov ax, cfa_exit
  mov di, [s_here]
  stosw
  mov [s_here], di
  inc byte [s_state] ; the ; word is only legal in compile mode (state=0 -> 1)
  jmp NEXT

last_primitive equ header_semi

heap_start:
