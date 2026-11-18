#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
SCRATCH="$ROOT/.build"
INSTALLED="$HOME/Applications/Workspace Helper.app"

swift test --scratch-path "$SCRATCH"
swift build -c release --scratch-path "$SCRATCH"
BIN="$(swift build -c release --show-bin-path --scratch-path "$SCRATCH")/WorkspaceHelper"

ICON="$SCRATCH/AppIcon.icns"
swiftc -O -framework AppKit -o "$SCRATCH/make-icon" "$ROOT/make-icon.swift"
"$SCRATCH/make-icon" "$ICON"

STAGE="$(mktemp -d)/Workspace Helper.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/WorkspaceHelper"
chmod +x "$STAGE/Contents/MacOS/WorkspaceHelper"
cp "$ROOT/Info.plist" "$STAGE/Contents/Info.plist"
cp "$ICON" "$STAGE/Contents/Resources/AppIcon.icns"
plutil -lint "$STAGE/Contents/Info.plist" >/dev/null

install_app() {
  local dest="$1"
  rm -rf "$dest"
  mkdir -p "$(dirname "$dest")"
  ditto "$STAGE" "$dest"
  codesign --force --sign - "$dest/Contents/MacOS/WorkspaceHelper"
  codesign --force --sign - "$dest"
  xattr -cr "$dest" || true
}

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
for old in \
  "$HOME/Applications/工作區幫手.app" \
  "$REPO/dist/工作區幫手.app"
do
  if [[ -d "$old" && "$old" != "$INSTALLED" ]]; then
    "$LSREGISTER" -u "$old" || true
    rm -rf "$old"
  fi
done
rmdir "$REPO/dist" 2>/dev/null || true

install_app "$INSTALLED"
"$LSREGISTER" -f "$INSTALLED"
mdimport "$INSTALLED" || true
echo "$INSTALLED"
