#!/bin/bash
set -euo pipefail

SCHEME="ProcessManagerBar"
CONFIGURATION="Release"
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
DERIVED_DATA="$REPO_ROOT/.build"

xcodebuild \
    -project "$REPO_ROOT/ProcessManagerBar.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    -destination 'platform=macOS' \
    build

BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$SCHEME.app"

if [ ! -d "$BUILT_APP" ]; then
    echo "error: built app not found at $BUILT_APP" >&2
    exit 1
fi

rm -rf "$REPO_ROOT/$SCHEME.app"
cp -R "$BUILT_APP" "$REPO_ROOT/$SCHEME.app"

echo "copied $SCHEME.app to $REPO_ROOT"
make process-manager pmctl
