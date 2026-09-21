#!/usr/bin/env bash
# Downloads the prebuilt nodejs-mobile runtime (libnode.so per ABI plus the
# Node headers) into app/libnode/, where CMakeLists.txt expects it.
#
# The zip is cached in .cache/ (override with NODEJS_MOBILE_CACHE) and its
# checksum is verified before unpacking. Nothing happens when the requested
# version is already unpacked.
set -euo pipefail

NODEJS_MOBILE_VERSION="${NODEJS_MOBILE_VERSION:-18.20.4}"
NODEJS_MOBILE_SHA256="${NODEJS_MOBILE_SHA256:-bd7321eaa1a7602fbe0bb87302df2d79d87835cf4363fbdd17c350dbb485c2af}"

ANDROID_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
CACHE="${NODEJS_MOBILE_CACHE:-$ANDROID_DIR/.cache}"
DEST="$ANDROID_DIR/app/libnode"
ZIP="$CACHE/nodejs-mobile-v$NODEJS_MOBILE_VERSION-android.zip"
URL="https://github.com/nodejs-mobile/nodejs-mobile/releases/download/v$NODEJS_MOBILE_VERSION/nodejs-mobile-v$NODEJS_MOBILE_VERSION-android.zip"

if [ -f "$DEST/.version" ] && [ "$(cat "$DEST/.version")" = "$NODEJS_MOBILE_VERSION" ]; then
    echo "nodejs-mobile v$NODEJS_MOBILE_VERSION already unpacked in $DEST"
    exit 0
fi

mkdir -p "$CACHE"
if [ ! -f "$ZIP" ]; then
    echo "Downloading $URL"
    curl -fsSL --retry 3 -o "$ZIP.part" "$URL"
    mv "$ZIP.part" "$ZIP"
fi

echo "$NODEJS_MOBILE_SHA256  $ZIP" | sha256sum -c -

rm -rf "$DEST"
mkdir -p "$DEST"
unzip -q "$ZIP" -d "$DEST"
echo "$NODEJS_MOBILE_VERSION" > "$DEST/.version"
echo "Unpacked nodejs-mobile v$NODEJS_MOBILE_VERSION into $DEST"
