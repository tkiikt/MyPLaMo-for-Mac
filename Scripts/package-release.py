#!/usr/bin/env python3
"""Package the built app with standalone user documentation and notices."""
from pathlib import Path
from email.parser import Parser
import shutil
import subprocess
import tempfile
import zipfile

root = Path(__file__).resolve().parents[1]
app = root / 'dist/MyPLaMo for Mac.app'
runtime = app / 'Contents/Resources/runtime'
site = runtime / 'lib/python3.13/site-packages'
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
output = root / 'dist/MyPLaMo-for-Mac-arm64.zip'
with tempfile.TemporaryDirectory(prefix='myplamo-release-') as temporary:
    stage = Path(temporary) / 'MyPLaMo for Mac'
    stage.mkdir()
    subprocess.run(['ditto', str(app), str(stage / app.name)], check=True)
    shutil.copy2(root / 'Distribution/README.md', stage / 'README.md')
    shutil.copy2(root / 'Distribution/README.md', stage / 'README.txt')
    shutil.copy2(root / 'Distribution/THIRD-PARTY-NOTICES.md', stage / 'THIRD-PARTY-NOTICES.md')
    shutil.copy2(root / 'chrome/README.md', stage / 'Chrome拡張の使い方.md')
    shutil.copy2(root / 'LICENSE-MIT', stage / 'LICENSE.txt')
    shutil.copy2(root / 'Resources/PLaMo-MODEL-LICENSE.md', stage / 'PLaMo-MODEL-LICENSE.md')
    # The standalone extension guide uses the same MIT text under this name.
    shutil.copy2(root / 'LICENSE-MIT', stage / 'LICENSE-MIT')
    licenses = stage / 'Licenses'
    shutil.copytree(root / 'Distribution/Licenses', licenses)
    shutil.copytree(runtime / 'Licenses', licenses / 'Runtime')
    inventory = []
    for dist in sorted(site.glob('*.dist-info')):
        metadata = Parser().parsestr((dist / 'METADATA').read_text())
        destination = licenses / 'Python-Packages' / dist.name
        destination.mkdir(parents=True)
        copied = []
        for file in sorted(dist.rglob('*')):
            if not file.is_file(): continue
            relative = file.relative_to(dist)
            if (relative.parts[0] in ('licenses', 'sboms') or
                file.name == 'METADATA' or
                file.name.lower().startswith(('license','licence','copying','copyright','notice','authors'))):
                target = destination / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(file, target)
                copied.append(str(relative))
        # Also retain notices shipped inside the importable package trees.
        inventory.append(f"{metadata['Name']} {metadata['Version']}\n  Python-Packages/{dist.name}/\n  " + ', '.join(copied))
    for file in sorted(site.rglob('*')):
        if not file.is_file() or any(p.endswith('.dist-info') for p in file.relative_to(site).parts): continue
        if file.name.lower().startswith(('license','licence','copying','copyright','notice','authors')):
            target = licenses / 'Package-Notices' / file.relative_to(site)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(file, target)
    (licenses / 'PACKAGES.txt').write_text('\n\n'.join(inventory) + '\n')
    archive = root / 'dist/MyPLaMo-for-Mac-arm64.pending.zip'
    subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(stage), str(archive)], check=True)
    with zipfile.ZipFile(archive) as z:
        assert z.testzip() is None, 'Archive integrity failure'
        prefix = 'MyPLaMo for Mac/'
        for required in ['README.md', 'README.txt', 'LICENSE.txt', 'THIRD-PARTY-NOTICES.md',
                         'PLaMo-MODEL-LICENSE.md',
                         'Licenses/PACKAGES.txt', 'MyPLaMo for Mac.app/Contents/MacOS/MyPLaMo']:
            assert prefix + required in z.namelist(), required
        assert not any(name.endswith(('.safetensors', '.gguf')) for name in z.namelist()), 'Model unexpectedly bundled'
        print(f'Verified {len(inventory)} package notice directories; {len(z.namelist())} archive entries')
    archive.replace(output)
print(output)
