#!/usr/bin/env python3

import sys
from unicorn import Uc, UC_ARCH_X86, UC_MODE_16, UC_HOOK_INTR
from unicorn.x86_const import (
    UC_X86_REG_CS,
    UC_X86_REG_DS,
    UC_X86_REG_ES,
    UC_X86_REG_SS,
    UC_X86_REG_AX,
    UC_X86_REG_BX,
    UC_X86_REG_CX,
    UC_X86_REG_DX,
    UC_X86_REG_SP,
    UC_X86_REG_BP,
    UC_X86_REG_IP,
)

MEMORY_SIZE = 0x100000

com_path = sys.argv[1] if len(sys.argv) > 1 else "uta.com"
source_path = sys.argv[2] if len(sys.argv) > 2 else None

with open(com_path, "rb") as file:
    com_bytes = file.read()

if source_path is None:
    stdin_bytes = sys.stdin.buffer.read()
else:
    with open(source_path, "rb") as file:
        stdin_bytes = file.read()

stdin_position = 0
mu = Uc(UC_ARCH_X86, UC_MODE_16)

mu.mem_map(0, MEMORY_SIZE)
mu.mem_write(0x100, com_bytes)

for segment_register in (UC_X86_REG_CS, UC_X86_REG_DS, UC_X86_REG_ES, UC_X86_REG_SS):
    mu.reg_write(segment_register, 0)

mu.reg_write(UC_X86_REG_SP, 0xFFFE)
mu.reg_write(UC_X86_REG_BP, 0)
mu.reg_write(UC_X86_REG_IP, 0x100)

exit_code = 0


def on_interrupt(_engine, interrupt_number, _user_data):
    global stdin_position, exit_code

    if interrupt_number == 0x20:
        mu.emu_stop()

        return

    if interrupt_number == 0x29:
        al = mu.reg_read(UC_X86_REG_AX) & 0xFF

        sys.stdout.buffer.write(bytes([al]))
        sys.stdout.buffer.flush()

        return

    if interrupt_number != 0x21:
        sys.stderr.write(f"unhandled interrupt: {interrupt_number:#x}\n")
        mu.emu_stop()

        return

    ax = mu.reg_read(UC_X86_REG_AX)
    ah = (ax >> 8) & 0xFF
    al = ax & 0xFF

    if ah == 0x4C:
        exit_code = al

        mu.emu_stop()
    elif ah == 0x02:
        dl = mu.reg_read(UC_X86_REG_DX) & 0xFF

        sys.stdout.buffer.write(bytes([dl]))
        sys.stdout.buffer.flush()
    elif ah in (0x07, 0x08, 0x01):
        if stdin_position < len(stdin_bytes):
            character = stdin_bytes[stdin_position]
            stdin_position += 1
        else:
            character = 0

        mu.reg_write(UC_X86_REG_AX, (ax & 0xFF00) | character)
    elif ah == 0x3F:
        bx = mu.reg_read(UC_X86_REG_BX)
        cx = mu.reg_read(UC_X86_REG_CX)
        dx = mu.reg_read(UC_X86_REG_DX)

        if bx == 0:
            chunk = stdin_bytes[stdin_position : stdin_position + cx]
            stdin_position += len(chunk)

            mu.mem_write(dx, chunk)
            mu.reg_write(UC_X86_REG_AX, len(chunk))
        else:
            mu.reg_write(UC_X86_REG_AX, 0)
    else:
        sys.stderr.write(f"unhandled DOS call AH={ah:#x}\n")
        mu.emu_stop()


mu.hook_add(UC_HOOK_INTR, on_interrupt)

try:
    mu.emu_start(0x100, MEMORY_SIZE)
except Exception as error:
    ip = mu.reg_read(UC_X86_REG_IP)

    sys.stderr.write(f"\nemulation error at IP={ip:#x}: {error}\n")

    raise

sys.exit(exit_code)
