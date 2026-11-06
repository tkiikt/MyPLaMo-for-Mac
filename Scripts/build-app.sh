#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
app="$PWD/dist/MyPLaMo for Mac.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Runtime"
cp "$binary_dir/LocalTranslate" "$app/Contents/MacOS/MyPLaMo"
cp Runtime/mlx_worker.py Runtime/requirements-mlx.lock "$app/Contents/Resources/Runtime/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MyPLaMo</string>
<key>CFBundleIdentifier</key><string>jp.localtranslate.mac</string>
<key>CFBundleName</key><string>MyPLaMo for Mac</string>
<key>CFBundleDisplayName</key><string>MyPLaMo for Mac</string>
<key>CFBundleIconFile</key><string>MyPLaMo</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>27.2</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>Built with PLaMo. PLaMo model © Preferred Networks. See model license and bundled runtime licenses.</string>
</dict></plist>
PLIST
if [ ! -x "$app/Contents/Resources/runtime/bin/python3" ]; then
  if [ ! -x .build/mlx-runtime/bin/python3 ]; then
    Scripts/package-mlx.sh "$PWD/.build/mlx-runtime"
  fi
  ditto .build/mlx-runtime "$app/Contents/Resources/runtime"
fi
if [ -f Resources/MyPLaMo.icns ]; then cp Resources/MyPLaMo.icns "$app/Contents/Resources/"; fi
cp LICENSE-MIT Resources/PLaMo-LICENSE-ja.txt "$app/Contents/Resources/"
if [ -f README.md ]; then cp README.md "$app/Contents/Resources/README.md"; fi
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
