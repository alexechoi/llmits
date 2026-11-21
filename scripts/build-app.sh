#!/usr/bin/env bash
# Builds "Claude Usage Bar.app" into ./build.
#   --install   also copy it to ~/Applications and (re)launch it
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Claude Usage Bar"
EXECUTABLE="ClaudeUsageBar"
APP="build/$APP_NAME.app"

swift build -c release --product "$EXECUTABLE"
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/"
cp Support/Info.plist "$APP/Contents/Info.plist"
# Ad-hoc signature: enough to run locally and to register as a login item.
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="$HOME/Applications/$APP_NAME.app"
  mkdir -p "$HOME/Applications"
  # Quit a running copy and wait for it to exit, or launching the new one can fail.
  pkill -x "$EXECUTABLE" 2>/dev/null || true
  for _ in {1..50}; do
    pgrep -x "$EXECUTABLE" >/dev/null || break
    sleep 0.1
  done
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  open "$DEST" 2>/dev/null || { sleep 1; open "$DEST"; }
  echo "Installed and launched $DEST"
fi
