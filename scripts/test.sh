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
LOG=build/test.log
if ! xcodebuild ${SIGN_ARGS[@]:+"${SIGN_ARGS[@]}"} -project MacFolders.xcodeproj -scheme MacFolders -destination 'platform=macOS' \
    -derivedDataPath build test > "$LOG" 2>&1; then
  grep -E "error:|Failing tests|failed" "$LOG" | head -40 || tail -40 "$LOG"
  exit 1
fi
grep -E "Test Suite 'All tests' (passed|failed)" "$LOG" | tail -2
