#!/usr/bin/env python3
"""Compile Lua or script sources to LuaModule protobuf binaries."""

from __future__ import annotations

import argparse
import os
import re
import sys
from typing import Iterable

import google.protobuf.message
from google.protobuf import text_format  # noqa: F401 (imported for consistency)

# Ensure Defold-specific protobuf extensions are registered.
import ddf.ddf_extensions_pb2  # noqa: F401


def _add_pythonpath(entries: Iterable[str]) -> None:
    for entry in entries:
        if not entry:
            continue
        abs_entry = os.path.abspath(entry)
        if abs_entry not in sys.path:
            sys.path.insert(0, abs_entry)


def _scan_lua(script: str) -> list[str]:
    modules: list[str] = []
    rp1 = re.compile(r'require\s*?"(.*?)"$')
    rp2 = re.compile(r'require\s*?\(\s*?"(.*?)"\s*?\)$')
    for line in script.split('\n'):
        line = line.strip()
        m1 = rp1.match(line)
        m2 = rp2.match(line)
        if m1:
            modules.append(m1.group(1))
        elif m2:
            modules.append(m2.group(1))
    return modules


def _resolve_filename(out_path: str, src_path: str, content_root: str | None) -> str:
    if content_root:
        abs_root = os.path.abspath(content_root)
        abs_out = os.path.abspath(out_path)
        rel = os.path.relpath(abs_out, abs_root)
        base, _ = os.path.splitext(rel)
        _, ext = os.path.splitext(src_path)
        return base + ext
    return src_path


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--src', required=True, help='Input Lua/Script file')
    parser.add_argument('--out', required=True, help='Output binary file (.luac/.scriptc)')
    parser.add_argument('--content-root', default='', help='Root to compute relative source filenames')
    parser.add_argument('--pythonpath', action='append', default=[], help='Additional paths for module imports')
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    _add_pythonpath(args.pythonpath)

    try:
        import lua_ddf_pb2
    except ImportError as exc:  # Fail fast with clearer diagnostics
        print(f"Unable to import lua_ddf_pb2: {exc}", file=sys.stderr)
        return 1

    src_path = args.src
    out_path = args.out
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)

    with open(src_path, 'rb') as src_file:
        data = src_file.read()
    script_str = data.decode('utf-8', errors='ignore')

    modules = _scan_lua(script_str)

    lua_module = lua_ddf_pb2.LuaModule()
    lua_module.source.script = data
    lua_module.source.filename = _resolve_filename(out_path, src_path, args.content_root or None)

    for module_name in modules:
        module_file = f"/{module_name.replace('.', '/')}.lua"
        lua_module.modules.append(module_name)
        lua_module.resources.append(module_file + 'c')

    with open(out_path, 'wb') as out_file:
        out_file.write(lua_module.SerializeToString())

    return 0


if __name__ == '__main__':
    sys.exit(main())
