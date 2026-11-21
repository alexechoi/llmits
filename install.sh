#!/usr/bin/env bash
# Installs Claude Usage Bar by building it from source into ~/Applications.
#
#   Install:    curl -fsSL https://raw.githubusercontent.com/karannavani/claude-usage-bar/main/install.sh | bash
#   Uninstall:  curl -fsSL https://raw.githubusercontent.com/karannavani/claude-usage-bar/main/install.sh | bash -s -- --uninstall
#
# Run it from a clone (./install.sh) to install that checkout instead of downloading a fresh copy.
# Building locally means there's no unsigned download for Gatekeeper to block.
set -euo pipefail

REPO="https://github.com/karannavani/claude-usage-bar.git"
APP_NAME="Claude Usage Bar"
EXECUTABLE="ClaudeUsageBar"
DEST="$HOME/Applications/$APP_NAME.app"

step() { printf '\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
fail() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

if [[ "${1:-}" == "--uninstall" ]]; then
  step "Uninstalling $APP_NAME"
  pkill -x "$EXECUTABLE" 2>/dev/null || true
  rm -rf "$DEST"
  note "Removed $DEST"
  note "If you had turned on Launch at Login, also remove it in"
  note "System Settings → General → Login Items & Extensions."
  exit 0
fi

step "Checking requirements"

[[ "$(uname -s)" == "Darwin" ]] || fail "$APP_NAME only runs on macOS."
macos_version="$(sw_vers -productVersion)"
(( ${macos_version%%.*} >= 14 )) || fail "macOS 14 or later is required (this Mac has $macos_version)."

if ! xcode-select -p >/dev/null 2>&1; then
  note "Apple's Command Line Tools are needed to build the app."
  note "A dialog will open to install them. When it finishes, run this installer again."
  xcode-select --install >/dev/null 2>&1 || true
  exit 1
fi
swift_version="$(xcrun swift --version 2>/dev/null | sed -nE 's/.*Swift version ([0-9]+(\.[0-9]+)*).*/\1/p' | head -n 1)"
swift_major="${swift_version%%.*}"
if [[ -z "$swift_major" ]] || (( swift_major < 6 )); then
  fail "Swift 6 or later is required (found ${swift_version:-none}). Update Xcode or the Command Line Tools in Software Update, then try again."
fi
note "macOS $macos_version, Swift $swift_version"

if security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1 || [[ -f "$HOME/.claude/.credentials.json" ]]; then
  note "Found your Claude Code login"
else
  note "No Claude Code login found yet. The app will install, but shows nothing until you"
  note "install Claude Code and sign in (run 'claude', then /login)."
fi

# Use this checkout when run from a clone; otherwise download a fresh copy.
script_path="${BASH_SOURCE[0]:-}"
if [[ -f "$script_path" && -f "$(dirname "$script_path")/scripts/build-app.sh" ]]; then
  source_dir="$(cd "$(dirname "$script_path")" && pwd)"
else
  step "Downloading the source"
  work_dir="$(mktemp -d)"
  trap 'rm -rf "$work_dir"' EXIT
  git clone --quiet --depth 1 "$REPO" "$work_dir/claude-usage-bar"
  source_dir="$work_dir/claude-usage-bar"
fi

step "Building (about a minute the first time)"
build_log="$(mktemp -t claude-usage-bar-build)"
if ! "$source_dir/scripts/build-app.sh" --install >"$build_log" 2>&1; then
  tail -n 30 "$build_log" >&2
  fail "The build failed. Full log: $build_log"
fi

step "Done"
note "$APP_NAME is installed in ~/Applications and running."
note "Look for the ✳︎ ring in your menu bar; click it for every limit and when each resets."
note "To start it automatically, choose Launch at Login from its menu."
note "Can't see it? If you use Bartender or Ice, it may be in the hidden section."
