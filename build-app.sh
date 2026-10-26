#!/bin/zsh
# Builds "HQ Voice Rec.app" into ./build and signs it ad hoc.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/HQ Voice Rec.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/HQVoiceRec"

if [[ ! -f build/AppIcon.icns ]]; then
    mkdir -p build
    swiftc -O scripts/make-icon.swift -o build/make-icon
    build/make-icon build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HQVoiceRec"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier se.william.hqvoicerec "$APP"
echo "Built $APP"
