#!/bin/zsh
# Builds the app and packages a DMG (with an Applications shortcut) and a zip into ./dist.
# usage: scripts/release.sh <version>
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${1:?usage: scripts/release.sh <version>}
NAME="HQ-Voice-Rec-$VERSION-arm64"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
./build-app.sh

rm -rf dist && mkdir -p dist/stage
ditto "build/HQ Voice Rec.app" "dist/stage/HQ Voice Rec.app"
ln -s /Applications dist/stage/Applications
hdiutil create -volname "HQ Voice Rec" -srcfolder dist/stage -ov -format UDZO -fs HFS+ "dist/$NAME.dmg" >/dev/null
ditto -c -k --keepParent "build/HQ Voice Rec.app" "dist/$NAME.zip"
rm -rf dist/stage

cd dist && shasum -a 256 "$NAME.dmg" "$NAME.zip" | tee SHA256SUMS.txt
