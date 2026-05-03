#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build/server-cmake}"
BUILD_TYPE="${BUILD_TYPE:-Release}"
RUN_TESTS=0
CLEAN=0

detect_jobs() {
    if command -v nproc >/dev/null 2>&1; then
        nproc
    elif command -v sysctl >/dev/null 2>&1; then
        sysctl -n hw.ncpu
    else
        echo 4
    fi
}

JOBS="${JOBS:-$(detect_jobs)}"

usage() {
    cat <<USAGE
Usage: ./build_server.sh [options]

Configure and build the Linux HIDMI server with CMake.

Options:
  --build-dir PATH       CMake build directory. Default: build/server-cmake.
  --build-type TYPE      CMake build type. Default: Release.
  --jobs N              Parallel build jobs. Default: detected CPU count.
  --test                Run hidmi_tests after building.
  --clean               Remove the build directory before configuring.
  -h, --help            Show this help.

Environment overrides:
  BUILD_DIR, BUILD_TYPE, JOBS
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-dir)
            BUILD_DIR="${2:?missing value for --build-dir}"
            shift 2
            ;;
        --build-type)
            BUILD_TYPE="${2:?missing value for --build-type}"
            shift 2
            ;;
        --jobs)
            JOBS="${2:?missing value for --jobs}"
            shift 2
            ;;
        --test)
            RUN_TESTS=1
            shift
            ;;
        --clean)
            CLEAN=1
            shift
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

command -v cmake >/dev/null 2>&1 || {
    echo "cmake was not found. Install CMake before building the server." >&2
    exit 1
}

if [[ "$CLEAN" -eq 1 ]]; then
    rm -rf "$BUILD_DIR"
fi

cmake \
    -S "$ROOT_DIR/server" \
    -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE"

cmake --build "$BUILD_DIR" --parallel "$JOBS"

if [[ "$RUN_TESTS" -eq 1 ]]; then
    "$BUILD_DIR/hidmi_tests"
fi

echo "Built server binary: $BUILD_DIR/hidmi"
