#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
app="$PWD/dist/LocalTranslate.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/LocalTranslate" "$app/Contents/MacOS/LocalTranslate"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LocalTranslate</string>
<key>CFBundleIdentifier</key><string>jp.localtranslate.mac</string>
<key>CFBundleName</key><string>LocalTranslate</string>
<key>CFBundleDisplayName</key><string>LocalTranslate</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>27.2</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>PLaMo model © Preferred Networks. See model license and bundled engine licenses.</string>
</dict></plist>
PLIST
if [ ! -x "$app/Contents/Resources/engine/llama-server" ] || [ "${REBUILD_ENGINE:-0}" = 1 ]; then
  Scripts/package-engine.sh "$app/Contents/Resources/engine"
fi
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
