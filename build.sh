#!/bin/sh
# Builds tool/sessions-hook as one universal (arm64 + x86_64) macOS 13+ binary from src/*.swift, and writes its
# SHA-256 to tool/sessions-hook.sha256. Needs Xcode on the build machine only; users need nothing.
#
# The committed binary is built with Xcode 26.3 (Swift 6.2.4). With that Xcode the result is the same byte for byte
# from any folder: -file-prefix-map keeps the folder's path out of the binary.
# DEVELOPER_DIR picks the Xcode. When it is not set and the selected developer folder is not Swift 6.2.4, an Xcode
# 26.3 in /Applications, ~/Applications or ~/Downloads is used if there is one. Another Swift version (the Command
# Line Tools, say) builds a file that works the same but differs in its bytes; the script then says so.
set -eu
cd -P "$(dirname "$0")"
here=$(pwd -P)
want="Apple Swift version 6.2.4 "
if [ -z "${DEVELOPER_DIR:-}" ] && ! xcrun swiftc --version 2>/dev/null | grep -qF "$want"; then
  for app in /Applications/Xcode.app /Applications/Xcode-26.3.app /Applications/Xcode_26.3.app \
             "$HOME/Applications/Xcode.app" "$HOME/Downloads/Xcode.app"; do
    if [ -d "$app/Contents/Developer" ] &&
       env DEVELOPER_DIR="$app/Contents/Developer" xcrun swiftc --version 2>/dev/null | grep -qF "$want"; then
      DEVELOPER_DIR="$app/Contents/Developer"
      export DEVELOPER_DIR
      break
    fi
  done
fi
swift=$(xcrun swiftc --version 2>/dev/null | head -n 1)
echo "Swift: $swift"
case "$swift" in
  *"$want"*) ;;
  *) echo "Note: this is not Swift 6.2.4 (Xcode 26.3), so tool/sessions-hook will not match the committed file byte for byte." ;;
esac
mkdir -p build tool
for arch in arm64 x86_64; do
  nice -n 10 xcrun swiftc -O -swift-version 5 -file-prefix-map "$here=." -target "$arch-apple-macos13" src/*.swift \
    -o "build/sessions-hook-$arch"
done
lipo -create -output tool/sessions-hook build/sessions-hook-arm64 build/sessions-hook-x86_64
strip -x tool/sessions-hook
codesign --force --sign - tool/sessions-hook
lipo -info tool/sessions-hook
shasum -a 256 tool/sessions-hook | tee tool/sessions-hook.sha256
