#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_PLUGIN="$ROOT/build/protobuf-tools/swift-protobuf/.build/release/protoc-gen-swift"

mkdir -p \
  "$ROOT/client/macos/HIDMI/Generated" \
  "$ROOT/devtools/generated"

if [[ ! -x "$SWIFT_PLUGIN" ]]; then
  mkdir -p "$ROOT/build/protobuf-tools"
  if [[ ! -d "$ROOT/build/protobuf-tools/swift-protobuf" ]]; then
    git clone --depth 1 --branch 1.37.0 https://github.com/apple/swift-protobuf.git "$ROOT/build/protobuf-tools/swift-protobuf"
  fi
  swift build --package-path "$ROOT/build/protobuf-tools/swift-protobuf" -c release --product protoc-gen-swift
fi

find "$ROOT/client/macos/HIDMI/Generated" "$ROOT/devtools/generated" \
  -type f \( -name '*.pb.swift' -o -name '*_pb2.py' \) -delete

PROTO_FILES=()
while IFS= read -r file; do
  PROTO_FILES+=("$file")
done < <(find "$ROOT/proto" -maxdepth 1 -name '*.proto' -print | sort)

protoc \
  -I "$ROOT/proto" \
  --plugin="protoc-gen-swift=$SWIFT_PLUGIN" \
  --swift_out="$ROOT/client/macos/HIDMI/Generated" \
  --python_out="$ROOT/devtools/generated" \
  "${PROTO_FILES[@]}"
