#!/bin/zsh
# Builds WakeWave.app into ~/Applications (or into $APP_DEST if set) and signs it ad hoc.
#   VERSION=1.2.0 ./build.sh         release version (default "dev": dev builds never self-update)
#   ARCHS="arm64 x86_64" ./build.sh  universal app (default: this Mac's architecture)
set -e
cd "$(dirname "$0")"

VERSION=${VERSION:-dev}
ARCHS=${ARCHS:-$(uname -m)}
DEST=${APP_DEST:-$HOME/Applications}
APP="$DEST/WakeWave.app"
BIN=$(mktemp -d)
trap 'rm -rf "$BIN"' EXIT
mkdir -p "$APP/Contents/MacOS"

for arch in ${=ARCHS}; do
    swiftc -O -target "$arch-apple-macos13.0" -o "$BIN/$arch" WakeWave.swift
done
lipo -create -output "$APP/Contents/MacOS/WakeWave" "$BIN"/*

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>WakeWave</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.janmejayspurohit.wakewave</string>
    <key>CFBundleExecutable</key>
    <string>WakeWave</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
</dict>
</plist>
EOF

codesign --force -s - "$APP"
echo "Built $APP ($VERSION, $ARCHS)"
