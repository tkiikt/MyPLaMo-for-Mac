#!/usr/bin/env python3
"""Build a Finder drag-install DMG from the complete ZIP distribution."""
from pathlib import Path
import subprocess
import tempfile
import dmgbuild
root = Path(__file__).resolve().parents[1]
archive = root / 'dist/MyPLaMo-for-Mac-arm64.zip'
output = root / 'dist/MyPLaMo-for-Mac-arm64.dmg'
with tempfile.TemporaryDirectory(prefix='myplamo-dmg-') as temp:
    stage = Path(temp)
    subprocess.run(['ditto', '-x', '-k', str(archive), str(stage)], check=True)
    source = stage / 'MyPLaMo for Mac'
    app = source / 'MyPLaMo for Mac.app'
    docs = stage / '使い方とライセンス'
    docs.mkdir()
    for item in source.iterdir():
        if item != app:
            item.rename(docs / item.name)
    readme = docs / 'README.md'
    content = readme.read_text().replace('1. 同梱の「MyPLaMo for Mac.app」をアプリケーションフォルダなどに移動します。', '1. DMG内の「MyPLaMo for Mac.app」を、右側の「アプリケーション」へドラッグします。').replace('2. アプリを起動します。', '2. コピー完了後、DMGを取り出し、アプリケーションフォルダからアプリを起動します。').replace('このZIP', 'このDMG')
    readme.write_text(content)
    (docs / 'README.txt').write_text(content)
    p = docs / 'THIRD-PARTY-NOTICES.md'
    p.write_text(p.read_text().replace('このZIP', 'このDMG'))
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    pending = stage / 'MyPLaMo.pending.dmg'
    dmgbuild.build_dmg(str(pending), 'MyPLaMo for Mac', settings={
        'format': 'UDZO', 'filesystem': 'HFS+',
        'files': [str(app), str(docs)],
        'symlinks': {'Applications': '/Applications'},
        'icon_locations': {'MyPLaMo for Mac.app': (170, 190), 'Applications': (510, 190), '使い方とライセンス': (340, 340)},
        'background': str(root / 'Distribution/dmg-background.png'),
        'window_rect': ((200, 200), (680, 520)),
        'default_view': 'icon-view', 'icon_size': 80, 'text_size': 13,
        'show_toolbar': False, 'show_status_bar': False, 'show_sidebar': False,
        'show_pathbar': False, 'show_tab_view': False,
    })
    subprocess.run(['hdiutil', 'verify', str(pending)], check=True)
    mount = stage / 'verify'
    mount.mkdir()
    subprocess.run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', str(mount), str(pending)], check=True, stdout=subprocess.DEVNULL)
    try:
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(mount / app.name)], check=True)
        assert (mount / 'Applications').is_symlink()
        assert (mount / 'Applications').resolve() == Path('/Applications')
        assert (mount / docs.name / 'Licenses/PACKAGES.txt').is_file()
    finally:
        subprocess.run(['hdiutil', 'detach', str(mount)], check=True, stdout=subprocess.DEVNULL)
    pending.replace(output)
print(output)
