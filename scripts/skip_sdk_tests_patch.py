#!/usr/bin/env python3
import pathlib
import sys

path = pathlib.Path('engine/sdk/src/test/wscript')
text = path.read_text(encoding='utf-8')

marker = 'from waflib import Options\n'
if marker not in text:
    text = text.replace('from waflib.TaskGen import feature, before, after\n',
                        'from waflib.TaskGen import feature, before, after\nfrom waflib import Options\n')

hook = 'def build(bld):\n'
if hook in text and 'Options.options.skip_build_tests' not in text:
    text = text.replace(hook, hook + '    if Options.options.skip_build_tests:\n        return\n')

path.write_text(text, encoding='utf-8')
