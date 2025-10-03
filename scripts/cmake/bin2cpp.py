#!/usr/bin/env python3

"""
bin2cpp.py

Convert a binary file into a pair of C/C++ files that embed the data:
 - <output_header>: declares extern unsigned char <SYM>[] and extern uint32_t <SYM>_SIZE
 - <output_cpp>: defines unsigned char DM_ALIGNED(16) <SYM>[] = { 0x.. } and uint32_t <SYM>_SIZE

Symbol derivation mirrors build_tools/waf_dynamo.py:embed_build:
  basename(input).upper(), with '.', '-', replaced by '_' and '@' to 'at'

Usage:
  bin2cpp.py --input <path> --out-h <path> --out-cpp <path> [--symbol NAME]
"""

import argparse
import os
import sys


def derive_symbol(path: str) -> str:
    base = os.path.basename(path)
    sym = base.upper()
    sym = sym.replace('.', '_').replace('-', '_').replace('@', 'at')
    return sym


def to_hex_list(data: bytes) -> str:
    # Format as comma-separated hex bytes with line breaks after every 4 bytes
    parts = []
    for i, b in enumerate(data):
        parts.append(f"0x{b:02x}, ")
        if i > 0 and i % 4 == 0:
            parts.append("\n    ")
    return ''.join(parts)


def main(argv=None) -> int:
    p = argparse.ArgumentParser()
    p.add_argument('--input', required=True, help='Input file (binary)')
    p.add_argument('--out-h', required=True, dest='out_h', help='Output header path (.h)')
    p.add_argument('--out-cpp', required=True, dest='out_cpp', help='Output C++ path (.cpp)')
    p.add_argument('--symbol', default=None, help='Override symbol name')
    args = p.parse_args(argv)

    in_path = os.path.abspath(args.input)
    out_h = os.path.abspath(args.out_h)
    out_cpp = os.path.abspath(args.out_cpp)
    sym = args.symbol or derive_symbol(in_path)

    # Ensure output directories exist
    os.makedirs(os.path.dirname(out_h), exist_ok=True)
    os.makedirs(os.path.dirname(out_cpp), exist_ok=True)

    with open(in_path, 'rb') as f:
        data = f.read()

    # Write .cpp
    with open(out_cpp, 'w', encoding='utf-8') as fcpp:
        fcpp.write('#include <stdint.h>\n')
        fcpp.write('#include "dlib/align.h"\n')
        fcpp.write(f"unsigned char DM_ALIGNED(16) {sym}[] =\n")
        fcpp.write('{\n    ')
        fcpp.write(to_hex_list(data))
        fcpp.write('\n};\n')
        fcpp.write(f'uint32_t {sym}_SIZE = sizeof({sym});\n')

    # Write .h
    with open(out_h, 'w', encoding='utf-8') as fh:
        fh.write(f'extern unsigned char {sym}[];\n')
        fh.write(f'extern uint32_t {sym}_SIZE;\n')

    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as e:
        print(f"bin2cpp.py: error: {e}", file=sys.stderr)
        sys.exit(1)

