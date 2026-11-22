#!/usr/bin/env bash
# Builds LLMits.app into ./build.
#   --install   also copy it to ~/Applications and (re)launch it
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="LLMits"
EXECUTABLE="LLMits"
APP="build/$APP_NAME.app"
MIN_MACOS="14.0"
# The app's name before it was renamed, so an install replaces it rather than sitting beside it.
OLD_APP_NAME="Claude Usage Bar"
OLD_EXECUTABLE="ClaudeUsageBar"

# The app icon is compiled ahead of time; check for it before spending a minute on the build.
# ("error:" makes install.sh show this line.)
[[ -f Support/CompiledIcon/Assets.car && -f Support/CompiledIcon/AppIcon.icns ]] ||
  { echo "error: Support/CompiledIcon is missing; run scripts/build-icon.sh (needs Xcode 26 or later)." >&2; exit 1; }

# Build with the toolchain `xcrun` picks, the same one install.sh checks.
xcrun swift build -c release --product "$EXECUTABLE"
BIN_DIR="$(xcrun swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/Logos/*.svg "$APP/Contents/Resources/"

# The Liquid Glass app icon (Assets.car for macOS 26 and later, AppIcon.icns before that),
# compiled ahead of time by scripts/build-icon.sh, as compiling it needs Xcode.
cp Support/CompiledIcon/Assets.car Support/CompiledIcon/AppIcon.icns "$APP/Contents/Resources/"

# SwiftPM can stamp the binary as built against the oldest SDK it supports, and macOS uses that
# stamp to decide which modern behaviours the app gets. Record the SDK it was really built with.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
xcrun vtool -set-build-version macos "$MIN_MACOS" "$SDK_VERSION" -replace \
  -output "$APP/Contents/MacOS/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"

# Ad-hoc signature: enough to run locally and to register as a login item.
codesign --force --sign - "$APP"
echo "Built $APP"

# Quits a running copy and waits for it to exit (forcing it after five seconds).
quit_app() {
  local name="$1"
  pkill -x "$name" 2>/dev/null || return 0
  for _ in {1..50}; do
    pgrep -x "$name" >/dev/null || return 0
    sleep 0.1
  done
  pkill -9 -x "$name" 2>/dev/null || true
  sleep 0.5
  ! pgrep -x "$name" >/dev/null
}

if [[ "${1:-}" == "--install" ]]; then
  DEST="$HOME/Applications/$APP_NAME.app"
  mkdir -p "$HOME/Applications"

  quit_app "$EXECUTABLE" || { echo "Couldn't quit the running $APP_NAME; quit it and try again." >&2; exit 1; }
  # Replace the app it used to be, and its settings.
  if [[ -d "$HOME/Applications/$OLD_APP_NAME.app" ]] || pgrep -x "$OLD_EXECUTABLE" >/dev/null; then
    quit_app "$OLD_EXECUTABLE" || true
    rm -rf "$HOME/Applications/$OLD_APP_NAME.app"
    defaults delete io.github.karannavani.claude-usage-bar >/dev/null 2>&1 || true
    echo "Replaced $OLD_APP_NAME, the app's old name. If it started at login, turn on Launch at Login again from LLMits's menu."
  fi

  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "Installed $DEST"
  # A launch failure isn't a failed install: the app is in place either way.
  if open "$DEST" 2>/dev/null || { sleep 1; open "$DEST" 2>/dev/null; }; then
    echo "Launched $APP_NAME"
  else
    echo "Warning: couldn't launch $APP_NAME automatically; open it from ~/Applications." >&2
  fi
fi
