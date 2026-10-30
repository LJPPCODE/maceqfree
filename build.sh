#!/bin/bash
# Baut build/KlangEQ.app nur mit den Command Line Tools (kein Xcode nötig).
set -euo pipefail
cd "$(dirname "$0")"

APP=build/KlangEQ.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.2" \
    Sources/*.swift -o "$APP/Contents/MacOS/KlangEQ"

cp Info.plist "$APP/Contents/Info.plist"
cp -R Resources/ui "$APP/Contents/Resources/ui"
codesign --force --sign - "$APP"

echo "Fertig: $APP"
