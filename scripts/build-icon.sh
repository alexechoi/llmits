#!/usr/bin/env bash
# Compiles the app icon (Support/AppIcon.icon, made in Icon Composer) into Support/CompiledIcon,
# which scripts/build-app.sh copies into the app. Run it after changing the icon and commit the
# result, so building the app needs only Apple's Command Line Tools: compiling the icon needs
# the actool in Xcode 26 or later.
set -euo pipefail
cd "$(dirname "$0")/.."

MIN_MACOS="14.0"
OUT="Support/CompiledIcon"

if ! xcrun --find actool >/dev/null 2>&1; then
  echo "Compiling the icon needs Xcode 26 or later. If it's installed, select it with:" >&2
  echo "  sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
fi

work="$(/usr/bin/mktemp -d)"
trap 'rm -rf "${work:?}"' EXIT

# Assets.car holds the Liquid Glass icon for macOS 26 and later; AppIcon.icns is for earlier
# versions. Support/Info.plist already names both (CFBundleIconName and CFBundleIconFile).
xcrun actool "$PWD/Support/AppIcon.icon" --compile "$work" \
  --platform macosx --minimum-deployment-target "$MIN_MACOS" --app-icon AppIcon \
  --output-partial-info-plist "$work/icon-info.plist" --output-format human-readable-text

mkdir -p "$OUT"
cp "$work/Assets.car" "$work/AppIcon.icns" "$OUT/"
echo "Compiled the app icon into $OUT"
