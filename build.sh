#!/bin/zsh
# Builds WakeWave.app into ~/Applications (or into $APP_DEST if set) and signs it ad hoc.
set -e
cd "$(dirname "$0")"

DEST=${APP_DEST:-$HOME/Applications}
APP="$DEST/WakeWave.app"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -target "$(uname -m)-apple-macos13.0" -o "$APP/Contents/MacOS/WakeWave" WakeWave.swift

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
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
</dict>
</plist>
EOF

codesign --force -s - "$APP"
echo "Built $APP"
