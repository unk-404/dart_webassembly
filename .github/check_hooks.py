"""Compiles the build hooks of every package in the dependency graph.

`dart analyze` does not look at build hooks - they are compiled, not analysed -
so a dependency that is allowed to drop too low slips through it.  With the
lowest allowed dependencies, `platform` 3.0.0 used `Platform.packageRoot`, which
current SDKs removed, and ffigen's hook stopped compiling.

CI runs this after `dart pub downgrade`, which is what pana does before it
scores a release.  Locally:

    dart pub downgrade --no-example
    python .github/check_hooks.py
    dart pub upgrade
"""

import json
import os
import subprocess
import sys
import tempfile

config = json.load(open('.dart_tool/package_config.json'))

hooks = []
for package in config['packages']:
    root = package['rootUri']
    if root.startswith('file://'):
        root = root[len('file://'):]
    elif not os.path.isabs(root):
        root = os.path.normpath(os.path.join('.dart_tool', root))
    # A file URI on Windows is /C:/..., which is not a usable local path.
    if os.name == 'nt' and root[:1] == '/' and root[2:3] == ':':
        root = root[1:]
    hook = os.path.join(root, 'hook', 'build.dart')
    if os.path.exists(hook):
        hooks.append((package['name'], hook))

print('compiling the build hooks of:', ', '.join(name for name, _ in hooks))

failed = []
for name, hook in hooks:
    result = subprocess.run(
        ['dart', 'compile', 'kernel',
         '--packages=.dart_tool/package_config.json',
         '--output=' + os.path.join(tempfile.gettempdir(), 'hook.dill'), hook],
        capture_output=True, text=True,
        # Windows ships `dart.bat`, which CreateProcess cannot run directly.
        shell=(os.name == 'nt'))
    if result.returncode != 0:
        failed.append(name)
        print(f'{name}/hook/build.dart does not compile: '
              f'{result.stderr.strip()[-500:]}')

sys.exit(1 if failed else 0)
