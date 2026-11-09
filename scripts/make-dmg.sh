#!/bin/zsh
# Packages WakeWave.app into a compressed DMG with an Applications shortcut for drag-to-install.
#   scripts/make-dmg.sh path/to/WakeWave.app WakeWave.dmg
set -e
APP=$1 OUT=$2
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/WakeWave.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname WakeWave -srcfolder "$STAGE" -format UDZO -ov "$OUT" >/dev/null
echo "Packaged $OUT"
