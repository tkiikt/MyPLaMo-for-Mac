#!/bin/bash
# Bundle the installed Homebrew engine without retaining Homebrew library paths.
# Usage: Scripts/package-engine.sh path/to/App.app/Contents/Resources/Engine
set -euo pipefail
destination="${1:?Specify an engine output directory}"
llama_prefix="$(brew --prefix llama.cpp)"
ggml_prefix="$(brew --prefix ggml)"
openssl_prefix="$(brew --prefix openssl@4)"
omp_prefix="$(brew --prefix libomp)"
python3 - "$destination" "$llama_prefix" "$ggml_prefix" "$openssl_prefix" "$omp_prefix" <<'PY'
import pathlib, shutil, subprocess, sys

dest = pathlib.Path(sys.argv[1]).resolve()
prefixes = [pathlib.Path(p) for p in sys.argv[2:]]
dest.mkdir(parents=True, exist_ok=True)
search = [p / 'lib' for p in prefixes]
pending = [prefixes[0] / 'bin/llama-server', *sorted((prefixes[1] / 'libexec').glob('*.so'))]
processed = {}

def dependencies(path):
    output = subprocess.check_output(['otool', '-L', str(path)], text=True)
    return [line.strip().split(' (compatibility')[0] for line in output.splitlines()[1:]]

while pending:
    source = pending.pop(0)
    name = source.name
    if name in processed:
        continue
    target = dest / name
    shutil.copy2(source, target)
    target.chmod(target.stat().st_mode | 0o200)
    # Homebrew's ggml searches its build-time backend directory before the
    # executable directory. Disable only that exact C string in our copy so
    # this bundle always uses its adjacent backends, even on the build Mac.
    if name.startswith('libggml.'):
        old = str((prefixes[1] / 'libexec').resolve()).encode() + b'\0'
        new = b'/__localtranslate_no_external_ggml\0'
        data = target.read_bytes()
        if old not in data or len(new) > len(old):
            raise RuntimeError('ggml backend directory changed; review packaging before continuing')
        target.write_bytes(data.replace(old, new.ljust(len(old), b'\0')))
    deps = dependencies(source)
    processed[name] = deps
    for dep in deps:
        if dep.startswith(('/usr/lib/', '/System/')):
            continue
        candidate = pathlib.Path(dep)
        if dep.startswith('@'):
            candidate = next((p / candidate.name for p in search if (p / candidate.name).exists()), None)
        if candidate is None or not candidate.exists():
            raise RuntimeError(f'Cannot resolve {dep} required by {source}')
        if candidate.name != name:
            pending.append(candidate)

for name, deps in processed.items():
    target = dest / name
    for dep in deps:
        if dep.startswith(('/usr/lib/', '/System/')):
            continue
        subprocess.run(['install_name_tool', '-change', dep, '@loader_path/' + pathlib.Path(dep).name, str(target)], check=True)
    if name.endswith('.dylib'):
        subprocess.run(['install_name_tool', '-id', '@loader_path/' + name, str(target)], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(target)], check=True, capture_output=True)

licenses = dest / 'Licenses'
licenses.mkdir(exist_ok=True)
for prefix in prefixes:
    license_file = prefix / 'LICENSE'
    if not license_file.exists():
        license_file = prefix / 'LICENSE.txt'
    if license_file.exists():
        shutil.copy2(license_file, licenses / (prefix.name + '.txt'))
print(f'Bundled {len(processed)} engine binaries in {dest}')
PY
"$destination/llama-server" --version
