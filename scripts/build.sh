#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
swift build -c "$configuration"
app_bundle="$PWD/artifacts/Macfile.app"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp ".build/$configuration/Macfile" "$app_bundle/Contents/MacOS/Macfile"
cp Resources/Info.plist "$app_bundle/Contents/Info.plist"
swift scripts/make-icon.swift "$PWD/.build/Macfile.iconset"
iconutil -c icns .build/Macfile.iconset -o "$app_bundle/Contents/Resources/Macfile.icns"
codesign --force --deep --sign - "$app_bundle"
codesign --verify --deep --strict "$app_bundle"
printf '%s\n' "$app_bundle"
