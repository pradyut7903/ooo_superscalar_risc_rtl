#!/usr/bin/env python3
"""Convert imported RV32IM test .s files into imem/dmem hex images.

This is intentionally a small RV32IM assembler for the subset used by
external/RV32IM-OOO-Superscalar-CPU/testcode.  It supports labels, .text/data
sections, .word/.dword data, and the pseudo-instructions li/la/nop/j.

The project core halts when instruction memory returns INSTR_INVALID, so the
source repo's simulator-exit idioms are translated to ffffffff:
  * slti x0, x0, -256
  * self-looping beq x0, x0, <same pc>
"""

from __future__ import annotations

import argparse
import re
import shutil
from dataclasses import dataclass
from pathlib import Path


INSTR_INVALID = 0xFFFF_FFFF

REG_ALIAS = {
    "zero": 0,
    "ra": 1,
    "sp": 2,
    "gp": 3,
    "tp": 4,
    "t0": 5,
    "t1": 6,
    "t2": 7,
    "s0": 8,
    "fp": 8,
    "s1": 9,
    "a0": 10,
    "a1": 11,
    "a2": 12,
    "a3": 13,
    "a4": 14,
    "a5": 15,
    "a6": 16,
    "a7": 17,
    "s2": 18,
    "s3": 19,
    "s4": 20,
    "s5": 21,
    "s6": 22,
    "s7": 23,
    "s8": 24,
    "s9": 25,
    "s10": 26,
    "s11": 27,
    "t3": 28,
    "t4": 29,
    "t5": 30,
    "t6": 31,
}


@dataclass
class Item:
    section: str
    addr: int
    op: str
    args: list[str]
    source: str
    line_no: int


def strip_comment(line: str) -> str:
    return line.split("#", 1)[0].strip()


def tokenize_inst(text: str) -> tuple[str, list[str]]:
    text = text.replace(",", " ")
    parts = text.split()
    if not parts:
        return "", []
    return parts[0].lower(), parts[1:]


def parse_int(token: str) -> int:
    token = token.strip()
    if token.startswith("%"):
        raise ValueError(f"unsupported relocation expression {token}")
    return int(token, 0)


def reg(token: str) -> int:
    token = token.strip().lower()
    if token in REG_ALIAS:
        return REG_ALIAS[token]
    if re.fullmatch(r"x([0-9]|[12][0-9]|3[01])", token):
        return int(token[1:])
    raise ValueError(f"unknown register {token}")


def align(value: int, boundary: int) -> int:
    mask = boundary - 1
    return (value + mask) & ~mask


def sext_fit(value: int, bits: int) -> bool:
    lo = -(1 << (bits - 1))
    hi = (1 << (bits - 1)) - 1
    return lo <= value <= hi


def signed32(value: int) -> int:
    value &= 0xFFFF_FFFF
    return value - 0x1_0000_0000 if value & 0x8000_0000 else value


def hi_lo_imm(value: int) -> tuple[int, int]:
    value &= 0xFFFF_FFFF
    hi = (value + 0x800) >> 12
    lo = signed32(value - ((hi & 0xFFFFF) << 12))
    return hi & 0xFFFFF, lo


def inst_count(op: str, args: list[str]) -> int:
    if op == "la":
        return 2
    if op == "li":
        value = signed32(parse_int(args[1]))
        return 1 if sext_fit(value, 12) else 2
    if op in {"nop", "j"}:
        return 1
    return 1


def parse_mem_operand(token: str) -> tuple[int, int]:
    m = re.fullmatch(r"(.+)\(([^()]+)\)", token.replace(" ", ""))
    if not m:
        raise ValueError(f"bad memory operand {token}")
    return parse_int(m.group(1)), reg(m.group(2))


def eval_expr(expr: str, labels: dict[str, int]) -> int:
    expr = expr.strip()
    expr = re.sub(r"\s+", "", expr)
    if expr in labels:
        return labels[expr]
    m = re.fullmatch(r"([A-Za-z_.$][\w.$]*)([+-].+)", expr)
    if m:
        return labels[m.group(1)] + parse_int(m.group(2))
    if re.fullmatch(r"[+-]?(0x[0-9a-fA-F]+|\d+)", expr):
        return parse_int(expr)
    raise ValueError(f"unknown expression {expr}")


def encode_r(f7: int, rs2: int, rs1: int, f3: int, rd: int, opc: int = 0x33) -> int:
    return ((f7 & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | opc


def encode_i(imm: int, rs1: int, f3: int, rd: int, opc: int) -> int:
    if not sext_fit(imm, 12):
        raise ValueError(f"I immediate out of range: {imm}")
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | opc


def encode_s(imm: int, rs2: int, rs1: int, f3: int) -> int:
    if not sext_fit(imm, 12):
        raise ValueError(f"S immediate out of range: {imm}")
    imm &= 0xFFF
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 0x1F) << 7) | 0x23


def encode_b(offset: int, rs2: int, rs1: int, f3: int) -> int:
    if offset & 1 or not sext_fit(offset, 13):
        raise ValueError(f"B offset out of range/alignment: {offset}")
    imm = offset & 0x1FFF
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | 0x63


def encode_u(imm20: int, rd: int, opc: int) -> int:
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | opc


def encode_j(offset: int, rd: int) -> int:
    if offset & 1 or not sext_fit(offset, 21):
        raise ValueError(f"J offset out of range/alignment: {offset}")
    imm = offset & 0x1F_FFFF
    return (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12) | (rd << 7) | 0x6F


def assemble_inst(item: Item, labels: dict[str, int]) -> list[int]:
    op, args, pc = item.op, item.args, item.addr

    if op == "nop":
        # The RTL decoder treats illegal/zero encodings as UOP_NOP.  Encoding
        # RISC-V's canonical addi x0,x0,0 would currently allocate an rd-less
        # ALU op that never writes CDB, so use the local UOP_NOP form.
        return [0x0000_0000]
    if op == "mv":
        return [encode_i(0, reg(args[1]), 0, reg(args[0]), 0x13)]
    if op == "li":
        rd = reg(args[0])
        value = signed32(parse_int(args[1]))
        if sext_fit(value, 12):
            return [encode_i(value, 0, 0, rd, 0x13)]
        hi, lo = hi_lo_imm(value)
        return [encode_u(hi, rd, 0x37), encode_i(lo, rd, 0, rd, 0x13)]
    if op == "la":
        rd = reg(args[0])
        value = eval_expr("".join(args[1:]), labels)
        hi, lo = hi_lo_imm(value)
        return [encode_u(hi, rd, 0x37), encode_i(lo, rd, 0, rd, 0x13)]
    if op == "j":
        target = eval_expr(args[0], labels)
        return [encode_j(target - pc, 0)]

    r_ops = {
        "add": (0x00, 0x0), "sub": (0x20, 0x0), "sll": (0x00, 0x1),
        "slt": (0x00, 0x2), "sltu": (0x00, 0x3), "xor": (0x00, 0x4),
        "srl": (0x00, 0x5), "sra": (0x20, 0x5), "or": (0x00, 0x6),
        "and": (0x00, 0x7),
        "mul": (0x01, 0x0), "mulh": (0x01, 0x1), "mulhsu": (0x01, 0x2),
        "mulhu": (0x01, 0x3), "div": (0x01, 0x4), "divu": (0x01, 0x5),
        "rem": (0x01, 0x6), "remu": (0x01, 0x7),
    }
    if op in r_ops:
        rd, rs1, rs2 = reg(args[0]), reg(args[1]), reg(args[2])
        f7, f3 = r_ops[op]
        return [encode_r(f7, rs2, rs1, f3, rd)]

    i_ops = {
        "addi": (0x0, 0x13), "slti": (0x2, 0x13), "sltiu": (0x3, 0x13),
        "xori": (0x4, 0x13), "ori": (0x6, 0x13), "andi": (0x7, 0x13),
    }
    if op in i_ops:
        rd, rs1, imm = reg(args[0]), reg(args[1]), parse_int(args[2])
        # Source tests use this as a simulator exit.  Our fetch exits on invalid.
        if op == "slti" and rd == 0 and rs1 == 0 and imm == -256:
            return [encode_j(labels["__program_end"] - pc, 0)]
        f3, opc = i_ops[op]
        return [encode_i(imm, rs1, f3, rd, opc)]

    sh_ops = {"slli": (0x00, 0x1), "srli": (0x00, 0x5), "srai": (0x20, 0x5)}
    if op in sh_ops:
        rd, rs1, shamt = reg(args[0]), reg(args[1]), parse_int(args[2])
        f7, f3 = sh_ops[op]
        return [encode_i((f7 << 5) | (shamt & 0x1F), rs1, f3, rd, 0x13)]

    if op in {"lb", "lh", "lw", "lbu", "lhu"}:
        f3 = {"lb": 0, "lh": 1, "lw": 2, "lbu": 4, "lhu": 5}[op]
        if "(" in args[1]:
            imm, rs1 = parse_mem_operand(args[1])
        else:
            imm, rs1 = eval_expr("".join(args[1:]), labels), 0
        return [encode_i(imm, rs1, f3, reg(args[0]), 0x03)]

    if op in {"sb", "sh", "sw"}:
        f3 = {"sb": 0, "sh": 1, "sw": 2}[op]
        imm, rs1 = parse_mem_operand(args[1])
        return [encode_s(imm, reg(args[0]), rs1, f3)]

    if op in {"beq", "bne", "blt", "bge", "bltu", "bgeu"}:
        f3 = {"beq": 0, "bne": 1, "blt": 4, "bge": 5, "bltu": 6, "bgeu": 7}[op]
        rs1, rs2 = reg(args[0]), reg(args[1])
        target = eval_expr(args[2], labels)
        if op == "beq" and rs1 == 0 and rs2 == 0 and target == pc:
            return [INSTR_INVALID]
        return [encode_b(target - pc, rs2, rs1, f3)]

    if op in {"lui", "auipc"}:
        rd = reg(args[0])
        imm = parse_int(args[1])
        return [encode_u(imm, rd, 0x37 if op == "lui" else 0x17)]

    if op == "jal":
        if len(args) == 1:
            rd, label = 1, args[0]
        else:
            rd, label = reg(args[0]), args[1]
        return [encode_j(eval_expr(label, labels) - pc, rd)]

    if op == "jalr":
        rd, rs1, imm = reg(args[0]), reg(args[1]), parse_int(args[2])
        return [encode_i(imm, rs1, 0, rd, 0x67)]

    raise ValueError(f"{item.source}:{item.line_no}: unsupported op {op}")


def read_source(path: Path) -> list[tuple[int, str]]:
    return [(i, strip_comment(line)) for i, line in enumerate(path.read_text().splitlines(), 1)]


def collect_items(path: Path) -> tuple[list[Item], list[Item], dict[str, int]]:
    section = "text"
    pc = 0
    data_addr = 0
    text_items: list[Item] = []
    data_items: list[Item] = []
    labels: dict[str, int] = {}

    for line_no, line in read_source(path):
        if not line:
            continue

        while True:
            m = re.match(r"^\s*([A-Za-z_.$][\w.$]*):\s*(.*)$", line)
            if not m:
                break
            label, rest = m.group(1), m.group(2).strip()
            labels[label] = pc if section == "text" else data_addr
            line = rest
            if not line:
                break
        if not line:
            continue

        if line.startswith("."):
            op, args = tokenize_inst(line)
            if op == ".section":
                sec = " ".join(args).strip('"')
                section = "text" if sec == ".text" else "data"
            elif op in {".globl", ".global"}:
                pass
            elif op == ".align":
                boundary = 1 << parse_int(args[0])
                if section == "text":
                    pc = align(pc, boundary)
                else:
                    data_addr = align(data_addr, boundary)
            elif op in {".word", ".dword"}:
                if section == "text":
                    raise ValueError(f"{path}:{line_no}: data directive in text")
                data_items.append(Item(section, data_addr, op, args, path.name, line_no))
                raw = " ".join(args).replace(",", " ")
                nvals = max(1, len([tok for tok in raw.split() if tok]))
                data_addr += (4 if op == ".word" else 8) * nvals
            else:
                # Directives such as .option are not expected in this testcode.
                pass
            continue

        op, args = tokenize_inst(line)
        if not op:
            continue
        if section != "text":
            raise ValueError(f"{path}:{line_no}: instruction in data section: {line}")
        text_items.append(Item(section, pc, op, args, path.name, line_no))
        pc += 4 * inst_count(op, args)

    return text_items, data_items, labels


def assemble_file(src: Path, out_dir: Path) -> dict[str, object]:
    text_items, data_items, labels = collect_items(src)
    text_end = max((item.addr + 4 * inst_count(item.op, item.args)) for item in text_items)
    labels["__program_end"] = text_end

    imem: dict[int, int] = {}
    for item in text_items:
        words = assemble_inst(item, labels)
        for n, word in enumerate(words):
            imem[(item.addr // 4) + n] = word & 0xFFFF_FFFF

    dmem: dict[int, int] = {}
    for item in data_items:
        # Accept comma- and/or whitespace-separated immediates.
        raw = " ".join(item.args).replace(",", " ")
        values = [parse_int(tok) & 0xFFFF_FFFF for tok in raw.split() if tok]
        if item.op == ".word":
            for k, value in enumerate(values):
                dmem[(item.addr // 4) + k] = value
        elif item.op == ".dword":
            value = values[0] if values else 0
            dmem[item.addr // 4] = value & 0xFFFF_FFFF
            dmem[item.addr // 4 + 1] = (value >> 32) & 0xFFFF_FFFF

    stem = src.stem
    imem_path = out_dir / f"{stem}.imem.hex"
    dmem_path = out_dir / f"{stem}.dmem.hex"
    asm_path = out_dir / f"{stem}.s"

    shutil.copyfile(src, asm_path)

    max_i = max(imem.keys(), default=-1)
    imem_path.write_text("".join(f"{imem.get(i, INSTR_INVALID):08x}\n" for i in range(max_i + 1)))

    max_d = max(dmem.keys(), default=-1)
    dmem_path.write_text("".join(f"{dmem.get(i, 0):08x}\n" for i in range(max_d + 1)))

    return {
        "name": stem,
        "source": str(src),
        "imem": str(imem_path),
        "dmem": str(dmem_path),
        "text_words": max_i + 1,
        "data_words": max_d + 1,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--src", type=Path, required=True, help="source .s file or directory")
    parser.add_argument("--out", type=Path, required=True, help="output directory")
    args = parser.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    sources = sorted(args.src.glob("*.s")) if args.src.is_dir() else [args.src]
    manifest = []
    for src in sources:
        manifest.append(assemble_file(src, args.out))
        print(f"assembled {src.name}")

    lines = ["name,source,imem,dmem,text_words,data_words\n"]
    for row in manifest:
        lines.append(",".join(str(row[k]) for k in ["name", "source", "imem", "dmem", "text_words", "data_words"]) + "\n")
    (args.out / "manifest.csv").write_text("".join(lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
