#!/bin/zsh
# Builds AgentDot.app into ./build and signs it.
# Usage: ./build.sh            (release build)
#        ./build.sh --install  (also copies to /Applications and launches it)
set -euo pipefail
cd "$(dirname "$0")"

NAME=AgentDot
APP=build/$NAME.app
LOG=$(swift build -c release 2>&1) || { print -r -- "$LOG"; echo "Build failed"; exit 1; }
print -r -- "$LOG" | grep -vE '^\[[0-9]+[^]]*/[^]]*[0-9]+\]' || true
BIN=$(swift build -c release --show-bin-path)/$NAME

# The icon is drawn in code; make it once if the iconset isn't there yet.
[[ -d Resources/AppIcon.iconset ]] || swift Scripts/make_icon.swift

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# Sign with a stable identity when there is one (so macOS keeps the notification permission
# across rebuilds); otherwise ad-hoc, for people building from source without a certificate.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x $NAME 2>/dev/null || true
    rm -rf /Applications/$NAME.app
    cp -R "$APP" /Applications/
    open /Applications/$NAME.app
    echo "Installed to /Applications and launched"
fi
