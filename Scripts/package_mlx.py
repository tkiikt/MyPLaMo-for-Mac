import os
import pathlib
import shutil
import subprocess
import sys
import sysconfig

root = pathlib.Path(__file__).resolve().parents[1]
dest = pathlib.Path(sys.argv[1]).resolve()
if dest.exists():
    raise SystemExit('Runtime output already exists. Use a fresh path to avoid mixing dependency versions.')
version = f'{sys.version_info.major}.{sys.version_info.minor}'
base = pathlib.Path(sys.base_prefix).resolve()
(dest / 'bin').mkdir(parents=True)
(dest / 'lib').mkdir()
ignore = shutil.ignore_patterns('__pycache__', '*.pyc', 'test', 'tests', 'idlelib', 'tkinter', 'ensurepip')
shutil.copytree(base / 'lib' / f'python{version}', dest / 'lib' / f'python{version}', ignore=shutil.ignore_patterns('__pycache__', '*.pyc', 'test', 'tests', 'idlelib', 'tkinter', 'ensurepip', 'site-packages'), symlinks=False)
site = dest / 'lib' / f'python{version}' / 'site-packages'
shutil.copytree(root / '.venv/lib' / f'python{version}' / 'site-packages', site, dirs_exist_ok=True, ignore=ignore, symlinks=False)
shutil.copy2(base / 'Resources/Python.app/Contents/MacOS/Python', dest / 'bin/python3')
python_library = base / 'Python'
shutil.copy2(python_library, dest / 'lib' / f'libpython{version}.dylib')

magic = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}
def macho(path):
    if not path.is_file(): return False
    with path.open('rb') as f: return f.read(4) in magic

def dependencies(path):
    out = subprocess.check_output(['otool', '-L', str(path)], text=True)
    ids = subprocess.check_output(['otool', '-D', str(path)], text=True).splitlines()
    return [line.strip().split(' (compatibility')[0] for line in out.splitlines() if line.startswith('\t') and line.strip().split(' (compatibility')[0] not in ids]

pending = [p for p in dest.rglob('*') if macho(p)]
known = {str(python_library): dest / 'lib' / f'libpython{version}.dylib'}
processed = []
while pending:
    binary = pending.pop()
    binary.chmod(binary.stat().st_mode | 0o200)
    for dep in dependencies(binary):
        if dep.startswith(('/System/', '/usr/lib/', '@')): continue
        source = pathlib.Path(dep).resolve()
        if source == python_library: target = known[str(python_library)]
        elif str(source) in known: target = known[str(source)]
        else:
            if not source.is_file(): raise RuntimeError(f'Missing dependency {dep}')
            target = dest / 'lib' / source.name
            if target.exists(): raise RuntimeError(f'Colliding dependency {target}')
            shutil.copy2(source, target); known[str(source)] = target; pending.append(target)
        relative = os.path.relpath(target, binary.parent)
        subprocess.run(['install_name_tool', '-change', dep, '@loader_path/' + relative, str(binary)], check=True, capture_output=True)
    if binary.suffix == '.dylib' or any(not line.endswith(':') for line in subprocess.check_output(['otool', '-D', str(binary)], text=True).splitlines()[1:]):
        subprocess.run(['install_name_tool', '-id', '@loader_path/' + binary.name, str(binary)], check=True, capture_output=True)
    processed.append(binary)
for binary in processed:
    subprocess.run(['codesign', '--force', '--sign', '-', str(binary)], check=True, capture_output=True)
licenses = dest / 'Licenses'
licenses.mkdir()
for prefix in [base, *base.parents]:
    for name in ['LICENSE', 'LICENSE.txt']:
        if (prefix / name).is_file(): shutil.copy2(prefix / name, licenses / 'Python-LICENSE.txt')
for source in known:
    source_path = pathlib.Path(source)
    for parent in source_path.parents:
        if parent.parent.parent == pathlib.Path('/opt/homebrew/Cellar'):
            for pattern in ['LICENSE*', 'COPYING*', 'AUTHORS*']:
                for license_file in parent.glob(pattern):
                    if license_file.is_file(): shutil.copy2(license_file, licenses / (parent.parent.name + '-' + license_file.name))
            break
shutil.copy2(root / 'Runtime/requirements-mlx.lock', licenses / 'requirements-mlx.lock')
(licenses / 'README.txt').write_text('Python and MLX dependencies retain their licenses in lib/python' + version + '/site-packages/*dist-info/licenses and METADATA.\n')
print(f'Bundled {len(processed)} Mach-O files in {dest}')
