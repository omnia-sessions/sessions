#!/bin/sh
# Builds tool/sessions-hook as one universal (arm64 + x86_64) macOS 13+ binary from src/*.swift.
# Needs Xcode or the Command Line Tools on the build machine only; users need nothing.
set -eu
cd "$(dirname "$0")"
# Uses the Xcode that xcode-select points to, or DEVELOPER_DIR when it is set.
# An Xcode kept in ~/Downloads is picked up too, when xcode-select points elsewhere.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d "$HOME/Downloads/Xcode.app/Contents/Developer" ]; then
  export DEVELOPER_DIR="$HOME/Downloads/Xcode.app/Contents/Developer"
fi
mkdir -p build tool
for arch in arm64 x86_64; do
  nice -n 10 xcrun swiftc -O -swift-version 5 -target "$arch-apple-macos13" src/*.swift -o "build/sessions-hook-$arch"
done
lipo -create -output tool/sessions-hook build/sessions-hook-arm64 build/sessions-hook-x86_64
strip -x tool/sessions-hook
codesign --force --sign - tool/sessions-hook
lipo -info tool/sessions-hook
