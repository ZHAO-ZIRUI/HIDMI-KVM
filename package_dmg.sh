#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APP_NAME="HIDMI"
PROJECT_PATH="$ROOT_DIR/client/macos/HIDMI.xcodeproj"
SCHEME="${SCHEME:-HIDMI}"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/build/macos/DerivedData}"
APP_PATH_OVERRIDE="${APP_PATH:-}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/build/dist}"
DMG_PATH="${DMG_PATH:-$DIST_DIR/$APP_NAME.dmg}"
VOLUME_NAME="${VOLUME_NAME:-$APP_NAME}"
SKIP_BUILD=0
CLEAN=0

usage() {
    cat <<USAGE
Usage: ./package_dmg.sh [options]

Build the macOS Release app and package it as a .dmg.

Options:
  --skip-build             Package the existing app at build/macos/Release/HIDMI.app.
  --clean                  Remove the existing app and dmg before building.
  --configuration NAME     Xcode configuration to build. Default: Release.
  --output PATH            DMG output path. Default: build/dist/HIDMI.dmg.
  --volume-name NAME       Mounted DMG volume name. Default: HIDMI.
  -h, --help               Show this help.

Environment overrides:
  SCHEME, DERIVED_DATA_PATH, APP_PATH, DIST_DIR, DMG_PATH, VOLUME_NAME
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-build)
            SKIP_BUILD=1
            shift
            ;;
        --clean)
            CLEAN=1
            shift
            ;;
        --configuration)
            CONFIGURATION="${2:?missing value for --configuration}"
            shift 2
            ;;
        --output)
            DMG_PATH="${2:?missing value for --output}"
            shift 2
            ;;
        --volume-name)
            VOLUME_NAME="${2:?missing value for --volume-name}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ "$CLEAN" -eq 1 && "$SKIP_BUILD" -eq 1 ]]; then
    echo "--clean cannot be combined with --skip-build because it removes the app to package." >&2
    exit 2
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "package_dmg.sh must run on macOS because it uses xcodebuild and hdiutil." >&2
    exit 1
fi

if [[ "$SKIP_BUILD" -eq 0 ]]; then
    command -v xcodebuild >/dev/null 2>&1 || {
        echo "xcodebuild was not found. Install Xcode or Xcode Command Line Tools." >&2
        exit 1
    }
fi

command -v hdiutil >/dev/null 2>&1 || {
    echo "hdiutil was not found. This script must run on macOS." >&2
    exit 1
}

APP_PATH="${APP_PATH_OVERRIDE:-$ROOT_DIR/build/macos/$CONFIGURATION/$APP_NAME.app}"

if [[ "$CLEAN" -eq 1 ]]; then
    rm -rf "$APP_PATH" "$DMG_PATH"
fi

if [[ "$SKIP_BUILD" -eq 0 ]]; then
    xcodebuild build \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -derivedDataPath "$DERIVED_DATA_PATH"
fi

if [[ ! -d "$APP_PATH" ]]; then
    echo "App bundle not found: $APP_PATH" >&2
    echo "Run without --skip-build or set APP_PATH to an existing .app bundle." >&2
    exit 1
fi

mkdir -p "$DIST_DIR" "$(dirname "$DMG_PATH")" "$ROOT_DIR/build/dmg"
STAGING_DIR="$(mktemp -d "$ROOT_DIR/build/dmg/staging.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

echo "Created DMG: $DMG_PATH"
