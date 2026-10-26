#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
OUTPUT_DIR="$PROJECT_DIR/dist"
if [[ $# -ge 1 ]]; then OUTPUT_DIR="$1"; fi
APP_DIR="$OUTPUT_DIR/Capture.app"
/usr/bin/python3 "$PROJECT_DIR/scripts/signing.py" check "$APP_DIR"
swift build -c release -Xswiftc -file-prefix-map -Xswiftc "$PROJECT_DIR=." -Xswiftc -debug-prefix-map -Xswiftc "$PROJECT_DIR=." -Xswiftc -file-compilation-dir -Xswiftc .
BIN_DIR="$(swift build -c release --show-bin-path)"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/Capture" "$APP_DIR/Contents/MacOS/Capture"
# Remove linker debug-map object paths before signing the distributed executable.
/usr/bin/strip -S "$APP_DIR/Contents/MacOS/Capture"
cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
# Existing developers keep their pinned identity; a public build can explicitly select the generic ID.
CAPTURE_BUILD_ID="$(/usr/bin/python3 "$PROJECT_DIR/scripts/signing.py" bundle-id)"
/usr/bin/python3 - "$APP_DIR/Contents/Info.plist" "$CAPTURE_BUILD_ID" <<'PYINFO'
import plistlib, sys
from pathlib import Path
path = Path(sys.argv[1]); info = plistlib.loads(path.read_bytes())
old = info["CFBundleIdentifier"]; new = sys.argv[2]
def replace(value):
    if isinstance(value, str): return value.replace(old, new)
    if isinstance(value, list): return [replace(v) for v in value]
    if isinstance(value, dict): return {k: replace(v) for k, v in value.items()}
    return value
path.write_bytes(plistlib.dumps(replace(info)))
PYINFO
if [[ ! -f "$APP_DIR/Contents/Resources/Capture.icns" ]]; then
    swift scripts/make-icon.swift "$PROJECT_DIR/.build/Capture.iconset"
    /usr/bin/iconutil -c icns "$PROJECT_DIR/.build/Capture.iconset" -o "$APP_DIR/Contents/Resources/Capture.icns"
fi
/usr/bin/python3 "$PROJECT_DIR/scripts/signing.py" sign "$APP_DIR"
printf 'Built: %s\n' "$APP_DIR"
