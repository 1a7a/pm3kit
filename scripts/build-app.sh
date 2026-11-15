#!/bin/bash
# Build pm3-kit in Release and install it to ~/Applications.
# Usage: scripts/build-app.sh [install-dir]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="${1:-$HOME/Applications}"
DERIVED="$REPO_ROOT/build"
APP_NAME="pm3kit.app"

cd "$REPO_ROOT"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen not found. Install it with: brew install xcodegen" >&2
    exit 1
fi

echo "==> Regenerating the Xcode project from project.yml"
xcodegen generate >/dev/null

echo "==> Running tests"
xcodebuild test \
    -project pm3kit.xcodeproj \
    -scheme pm3kit \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED" \
    -quiet

echo "==> Building Release"
xcodebuild build \
    -project pm3kit.xcodeproj \
    -scheme pm3kit \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    -quiet

BUILT="$DERIVED/Build/Products/Release/$APP_NAME"
[ -d "$BUILT" ] || { echo "Build produced no app at $BUILT" >&2; exit 1; }

# A sandboxed build cannot launch pm3 or reach USB, so refuse to ship one.
if codesign -d --entitlements - "$BUILT" 2>&1 | grep -q "app-sandbox"; then
    echo "Refusing to install: the build carries the App Sandbox entitlement." >&2
    echo "Check ENABLE_APP_SANDBOX in project.yml." >&2
    exit 1
fi

echo "==> Installing to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
rm -rf "${INSTALL_DIR:?}/$APP_NAME"
cp -R "$BUILT" "$INSTALL_DIR/"

echo
echo "Installed $INSTALL_DIR/$APP_NAME"
echo "Open it with: open '$INSTALL_DIR/$APP_NAME'"
