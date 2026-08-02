#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Optional stable signing identity (keeps macOS folder-access grants across
# rebuilds): export MACFOLDERS_SIGN_IDENTITY="Apple Development: ..."
SIGN_ARGS=()
if [ -n "${MACFOLDERS_SIGN_IDENTITY:-}" ]; then
  SIGN_ARGS=(CODE_SIGN_IDENTITY="${MACFOLDERS_SIGN_IDENTITY}" CODE_SIGN_STYLE=Manual)
fi
xcodegen generate
mkdir -p build
LOG=build/install-build.log
# `clean build`, not `build`: xcodegen regenerates the project each run, which
# can leave xcodebuild's incremental state stale — silently shipping a binary
# missing just-changed files. A clean build trades ~30s for correctness.
if ! xcodebuild ${SIGN_ARGS[@]:+"${SIGN_ARGS[@]}"} -project MacFolders.xcodeproj -scheme MacFolders -configuration Release \
    -derivedDataPath build clean build > "$LOG" 2>&1; then
  tail -40 "$LOG"
  exit 1
fi
rm -rf /Applications/MacFolders.app
ditto build/Build/Products/Release/MacFolders.app /Applications/MacFolders.app
echo "Installed /Applications/MacFolders.app"
