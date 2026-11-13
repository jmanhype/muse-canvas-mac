#!/bin/bash
# Bundles the MuseBar menu bar app into MuseBar.app (LSUIElement — menu bar
# only, no Dock icon) and symlinks the CLI as `muse` for /usr/local/bin-style
# installs. Usage: scripts/bundle-app.sh [output-dir]   (default: .build/apps)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-Release}"
OUT=".build/apps"
APP="$OUT/MuseBar.app"

swift build -c "$CONFIG"
BIN_DIR=".build/${CONFIG}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MuseBar" "$APP/Contents/MacOS/MuseBar"
cp "$BIN_DIR/muse" "$APP/Contents/MacOS/muse-cli"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>MuseBar</string>
  <key>CFBundleIdentifier</key><string>dev.musecanvas.musebar</string>
  <key>CFBundleName</key><string>MuseBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
EOF

echo "built $APP"
echo "install CLI (optional):   ln -s \"$(cd "$(dirname "$APP")" && pwd)/MuseBar.app/Contents/MacOS/muse-cli\" /usr/local/bin/muse"
echo "run the menu bar app:     open $APP"
