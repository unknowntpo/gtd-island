#!/bin/bash
# Build GTD Island, install it to ~/Applications, and start it.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product GTDIsland >/dev/null

APP="$HOME/Applications/GTD Island.app"
mkdir -p "$APP/Contents/MacOS" "$HOME/.gtd-island"
cp .build/release/GTDIsland "$APP/Contents/MacOS/GTDIsland"
cp scripts/refresh.py "$HOME/.gtd-island/refresh.py"
cp scripts/route.py "$HOME/.gtd-island/route.py"
VENV="$HOME/.gtd-island/venv"
[ -x "$VENV/bin/python" ] || uv venv --quiet --python 3.12 "$VENV"
uv pip install --quiet --python "$VENV/bin/python" onnxruntime tokenizers numpy
[ -f "$HOME/.gtd-island/models/multilingual-e5-small/model_O4.onnx" ] || echo "warning: routing model is missing; the 找 session tab will show an error"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>GTD Island</string>
<key>CFBundleIdentifier</key><string>dev.unknowntpo.gtd-island</string>
<key>CFBundleExecutable</key><string>GTDIsland</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
pkill -x GTDIsland 2>/dev/null || true
sleep 0.5
open "$APP"
echo "installed: $APP"
