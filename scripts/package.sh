#!/usr/bin/env bash
# Builds a universal (arm64 + x86_64) macOS release and packs it into
# dist/agent-bar-<version>-macos-universal.tar.gz (+ .sha256).
#   scripts/package.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build-release"
VERSION="$(sed -n 's/^project(agent-bar VERSION \([0-9.]*\).*/\1/p' "$ROOT/CMakeLists.txt")"
NAME="agent-bar-$VERSION-macos-universal"
STAGE="$ROOT/dist/$NAME"

cmake -S "$ROOT" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0
cmake --build "$BUILD" -j
(cd "$BUILD" && ctest --output-on-failure)

rm -rf "$STAGE" "$ROOT/dist/$NAME.tar.gz"
mkdir -p "$STAGE"
for b in agent-status-hook agent-bar; do
  cp "$BUILD/bin/$b" "$STAGE/"
  codesign --force --sign - "$STAGE/$b"   # ad-hoc signature, required on Apple silicon
  lipo -info "$STAGE/$b"
done
cp "$ROOT/scripts/install.sh" "$ROOT/scripts/uninstall.sh" "$ROOT/README.md" "$ROOT/LICENSE" "$STAGE/"
tar -C "$ROOT/dist" -czf "$ROOT/dist/$NAME.tar.gz" "$NAME"
(cd "$ROOT/dist" && shasum -a 256 "$NAME.tar.gz" > "$NAME.tar.gz.sha256")
echo "dist/$NAME.tar.gz"
