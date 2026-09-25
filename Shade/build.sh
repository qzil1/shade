#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Build in a fresh bundle: compilation failure leaves the previous build intact.
mkdir -p .build
SHADE_BUILD_DIR=$(mktemp -d "$PWD/.build/package.XXXXXX")
trap 'rm -rf "$SHADE_BUILD_DIR"' EXIT
SHADE_APP="$SHADE_BUILD_DIR/Shade.app"
mkdir -p "$SHADE_APP/Contents/MacOS" "$SHADE_APP/Contents/Resources"
cp Sources/Shade/Info.plist "$SHADE_APP/Contents/Info.plist"
cp Sources/Shade/AppIcon.icns "$SHADE_APP/Contents/Resources/"
SHADE_SDK=$(xcrun --sdk macosx --show-sdk-path)
read -r -a SHADE_ARCHS <<< "${ARCHS:-$(uname -m)}"
SHADE_BINARIES=()
for SHADE_ARCH in "${SHADE_ARCHS[@]}"; do
    case "$SHADE_ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $SHADE_ARCH" >&2; exit 1 ;; esac
    echo "Building Shade for $SHADE_ARCH (macOS 11+)..."
    swiftc -O -whole-module-optimization -sdk "$SHADE_SDK" -target "$SHADE_ARCH-apple-macosx11.0" \
        Sources/Shade/*.swift -o "$SHADE_BUILD_DIR/Shade-$SHADE_ARCH" \
        -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Sources/Shade/Info.plist \
        -framework Cocoa -framework Carbon -framework ServiceManagement
    SHADE_BINARIES+=("$SHADE_BUILD_DIR/Shade-$SHADE_ARCH")
done
if [ "${#SHADE_BINARIES[@]}" -gt 1 ]; then
    lipo -create "${SHADE_BINARIES[@]}" -output "$SHADE_APP/Contents/MacOS/Shade"
else
    cp "${SHADE_BINARIES[0]}" "$SHADE_APP/Contents/MacOS/Shade"
fi
xattr -cr "$SHADE_APP"
if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$SHADE_APP"
else
    codesign --force --sign - "$SHADE_APP"
fi
codesign --verify --strict "$SHADE_APP"
plutil -lint "$SHADE_APP/Contents/Info.plist"
# Only replace this script's generated output, after the new bundle is verified.
rm -rf "$PWD/Shade.app"
mv "$SHADE_APP" "$PWD/Shade.app"
echo "Built: $PWD/Shade.app"
echo "Run: open \"$PWD/Shade.app\""
echo "Developer ID notarization is a separate release step; the default build is locally signed."
