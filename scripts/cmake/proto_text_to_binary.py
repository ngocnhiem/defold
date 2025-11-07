#!/usr/bin/env python3
"""Convert a text-format protobuf message into binary form.

This script mirrors the behaviour of the Waf proto_compile_task helper used by
the Defold build system. It imports the generated *_ddf_pb2 module, parses the
text input, optionally validates resource references, applies an optional
transform, and serialises the message to the requested binary file.
"""

from __future__ import annotations

import argparse
import importlib
import inspect
import os
import sys
from typing import Iterable, Optional

import google.protobuf.message
import google.protobuf.text_format
from google.protobuf.descriptor import FieldDescriptor

# Ensure Defold-specific protobuf extensions are registered.
import ddf.ddf_extensions_pb2  # noqa: F401


def _add_pythonpath(entries: Iterable[str]) -> None:
    for entry in entries:
        if not entry:
            continue
        abs_entry = os.path.abspath(entry)
        if abs_entry not in sys.path:
            sys.path.insert(0, abs_entry)


def _load_message(module_name: str, message_name: str):
    module = importlib.import_module(module_name)
    obj = module
    for token in message_name.split('.'):  # Supports nested messages
        obj = getattr(obj, token)
    return obj()


def _is_resource(field_desc: FieldDescriptor) -> bool:
    for option_desc, value in field_desc.GetOptions().ListFields():
        if option_desc.name == 'resource' and value:
            return True
    return False


def _validate_resource_files(message_obj, content_root: str) -> None:
    if not content_root:
        return

    descriptor = message_obj.DESCRIPTOR
    for field in descriptor.fields:
        value = getattr(message_obj, field.name)

        if field.type == FieldDescriptor.TYPE_MESSAGE:
            if field.label == FieldDescriptor.LABEL_REPEATED:
                for item in value:
                    _validate_resource_files(item, content_root)
            else:
                if hasattr(value, 'ByteSize') and value.ByteSize() == 0:
                    continue
                _validate_resource_files(value, content_root)
            continue

        if not _is_resource(field):
            continue

        items = value if field.label == FieldDescriptor.LABEL_REPEATED else [value]
        for item in items:
            if field.label == FieldDescriptor.LABEL_OPTIONAL and not item:
                continue
            if not item.startswith('/'):
                raise FileNotFoundError(f'resource path is not absolute "{item}"')
            fs_path = os.path.join(content_root, item[1:])
            if not os.path.exists(fs_path):
                raise FileNotFoundError(f'is missing dependent resource file "{item}"')


class _GeneratorStub:
    def __init__(self, content_root: str):
        self.content_root = content_root


class _TaskStub:
    def __init__(self, content_root: str):
        self.generator = _GeneratorStub(content_root)


def _apply_transform(transform: Optional[str], message_obj, content_root: str):
    if not transform:
        return message_obj

    if ':' in transform:
        module_name, fn_name = transform.rsplit(':', 1)
    elif '.' in transform:
        module_name, fn_name = transform.rsplit('.', 1)
    else:
        raise ValueError(f"Transform '{transform}' must be MODULE:FUNCTION or MODULE.FUNCTION")

    module = importlib.import_module(module_name)
    func = getattr(module, fn_name)

    try:
        signature = inspect.signature(func)
        param_count = len(signature.parameters)
    except (TypeError, ValueError):  # Built-ins may not expose signature
        param_count = 0

    if param_count >= 2:
        task_stub = _TaskStub(content_root)
        result = func(task_stub, message_obj)
    else:
        result = func(message_obj)
    return message_obj if result is None else result


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--src', required=True, help='Input protobuf text file')
    parser.add_argument('--out', required=True, help='Output binary file')
    parser.add_argument('--module', required=True, help='Generated *_pb2 module to import')
    parser.add_argument('--message', required=True, help='Fully-qualified protobuf message class name')
    parser.add_argument('--content-root', default='', help='Root for validating resource() annotations')
    parser.add_argument('--transform', help='Optional MODULE:FUNCTION applied to the message before serialisation')
    parser.add_argument('--pythonpath', action='append', default=[], help='Additional paths to prepend to sys.path')
    return parser.parse_args()


def main() -> int:
    args = _parse_args()

    # Ensure repository root and optional python paths are on sys.path
    defold_home = os.environ.get('DEFOLD_HOME')
    if defold_home:
        _add_pythonpath([defold_home])
    _add_pythonpath(args.pythonpath)

    try:
        message_obj = _load_message(args.module, args.message)
        with open(args.src, 'r', encoding='utf-8') as src_file:
            google.protobuf.text_format.Merge(src_file.read(), message_obj)

        _validate_resource_files(message_obj, args.content_root)
        message_obj = _apply_transform(args.transform, message_obj, args.content_root)

        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        with open(args.out, 'wb') as out_file:
            out_file.write(message_obj.SerializeToString())
        return 0
    except (google.protobuf.text_format.ParseError, google.protobuf.message.EncodeError) as err:
        print(f"{args.src}: {err}", file=sys.stderr)
    except FileNotFoundError as err:
        print(f"{args.src}: {err}", file=sys.stderr)
    except Exception as err:
        print(f"{args.src}: {err}", file=sys.stderr)
    return 1


if __name__ == '__main__':
    sys.exit(main())
