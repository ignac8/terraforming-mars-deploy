#!/usr/bin/env bash
# Builds the standalone Android APK of Terraforming Mars.
#
# The APK carries the game server (bundled into one file), the client and its
# assets, and a Node.js runtime, so the game runs entirely on the phone with
# no network. See README.md for the layout and the prerequisites.
#
# Usage: android/build-apk.sh
#   MAIN_CHECKOUT          game checkout (default: ../terraforming-mars next to this repo)
#   SKIP_GAME_BUILD=1      reuse the checkout's existing build/ instead of npm ci + npm run build
#   ANDROID_ABIS           comma-separated ABIs (default: arm64-v8a; add x86_64 for an emulator)
#   ANDROID_KEYSTORE       signing keystore (default: android/keystore/release.jks, generated when missing)
#   ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD
set -euo pipefail

ANDROID_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
MAIN_CHECKOUT="${MAIN_CHECKOUT:-$ANDROID_DIR/../../terraforming-mars}"
ANDROID_ABIS="${ANDROID_ABIS:-arm64-v8a}"
PROJECT="$ANDROID_DIR/build/nodejs-project"
PROJECT_ZIP="$ANDROID_DIR/app/src/main/assets/nodejs-project.zip"
ESBUILD_VERSION=0.28.1
NDK_VERSION=27.2.12479018
CMAKE_VERSION=3.22.1

log() { printf '\n==> %s\n' "$*"; }
die() { echo "build-apk.sh: $*" >&2; exit 1; }

# --- Android SDK ------------------------------------------------------------
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
[ -n "$SDK" ] && [ -d "$SDK" ] || die "set ANDROID_HOME to an Android SDK (README.md lists the packages)"
export ANDROID_HOME="$SDK"

ensure_sdk_package() {
    local package="$1" dir="$2"
    if [ -d "$SDK/$dir" ]; then
        return
    fi
    local sdkmanager="$SDK/cmdline-tools/latest/bin/sdkmanager"
    [ -x "$sdkmanager" ] || die "$SDK/$dir is missing and there is no sdkmanager to install $package"
    log "Installing $package"
    yes | "$sdkmanager" --licenses > /dev/null 2>&1 || true
    "$sdkmanager" --install "$package"
}
ensure_sdk_package "platforms;android-35" "platforms/android-35"
ensure_sdk_package "build-tools;35.0.0" "build-tools/35.0.0"
ensure_sdk_package "ndk;$NDK_VERSION" "ndk/$NDK_VERSION"
ensure_sdk_package "cmake;$CMAKE_VERSION" "cmake/$CMAKE_VERSION"

# --- 1. Game build ----------------------------------------------------------
[ -d "$MAIN_CHECKOUT" ] || die "no game checkout at $MAIN_CHECKOUT (set MAIN_CHECKOUT)"
if [ -z "${SKIP_GAME_BUILD:-}" ]; then
    log "Building the game in $MAIN_CHECKOUT"
    (cd "$MAIN_CHECKOUT" && npm ci --no-audit --no-fund && npm run build)
fi
for f in build/src/server/server.js build/main.js.br build/vendors.js.br build/styles.css.br assets/index.html; do
    [ -f "$MAIN_CHECKOUT/$f" ] || die "$MAIN_CHECKOUT/$f is missing; run npm run build there"
done

# --- 2. nodejs-project: server bundle, client, assets -----------------------
log "Assembling $PROJECT"
rm -rf "$PROJECT"
mkdir -p "$PROJECT"

# One file with every dependency inlined: nodejs-mobile is Node 18, which
# cannot require() the ESM-only packages the server depends on.
(cd "$MAIN_CHECKOUT" && npx --yes "esbuild@$ESBUILD_VERSION" build/src/server/server.js \
    --bundle --platform=node --target=node18 --format=cjs --log-level=warning \
    --alias:pg="$ANDROID_DIR/nodejs-project/stubs/empty.js" \
    --alias:better-sqlite3="$ANDROID_DIR/nodejs-project/stubs/empty.js" \
    --outfile="$PROJECT/server.js")

cp "$ANDROID_DIR/nodejs-project/main.js" "$PROJECT/main.js"

# The client bundle and styles, without the compiled server and source maps.
cp -R "$MAIN_CHECKOUT/build/." "$PROJECT/build/"
rm -rf "$PROJECT/build/src"
find "$PROJECT/build" -name '*.map' -o -name '*.map.gz' -o -name '*.map.br' | xargs -r rm -f

cp -R "$MAIN_CHECKOUT/assets" "$PROJECT/assets"

# One zip asset, unpacked by ProjectInstaller on the phone. Loose asset files
# would not do: the Android asset merger strips ".gz" from asset names, so
# main.js and main.js.gz would collide.
mkdir -p "$(dirname "$PROJECT_ZIP")"
rm -f "$PROJECT_ZIP"
(cd "$PROJECT" && zip -qr -X "$PROJECT_ZIP" .)
du -sh "$PROJECT" "$PROJECT_ZIP"

# --- 3. Node runtime --------------------------------------------------------
"$ANDROID_DIR/fetch-libnode.sh"

# --- 4. Version and signing -------------------------------------------------
GAME_SHA=$(git -C "$MAIN_CHECKOUT" rev-parse --short HEAD 2>/dev/null || echo unknown)
VERSION_CODE=$(( $(date +%s) / 60 ))
VERSION_NAME="$(date -u +%Y.%m.%d)-$GAME_SHA"

export ANDROID_KEYSTORE="${ANDROID_KEYSTORE:-$ANDROID_DIR/keystore/release.jks}"
export ANDROID_KEYSTORE_PASSWORD="${ANDROID_KEYSTORE_PASSWORD:-terraforming}"
export ANDROID_KEY_ALIAS="${ANDROID_KEY_ALIAS:-terraforming-mars}"
export ANDROID_KEY_PASSWORD="${ANDROID_KEY_PASSWORD:-$ANDROID_KEYSTORE_PASSWORD}"
if [ ! -f "$ANDROID_KEYSTORE" ]; then
    log "Generating a signing key at $ANDROID_KEYSTORE"
    echo "Keep it: Android only installs an update over an app signed with the same key."
    mkdir -p "$(dirname "$ANDROID_KEYSTORE")"
    keytool -genkeypair -keystore "$ANDROID_KEYSTORE" -storepass "$ANDROID_KEYSTORE_PASSWORD" \
        -alias "$ANDROID_KEY_ALIAS" -keypass "$ANDROID_KEY_PASSWORD" \
        -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Terraforming Mars offline"
fi

# --- 5. APK -----------------------------------------------------------------
log "Building the APK ($ANDROID_ABIS, $VERSION_NAME, versionCode $VERSION_CODE)"
(cd "$ANDROID_DIR" && ./gradlew --no-daemon --quiet assembleRelease \
    -PtmAbis="$ANDROID_ABIS" -PtmVersionCode="$VERSION_CODE" -PtmVersionName="$VERSION_NAME")

OUT="$ANDROID_DIR/out"
mkdir -p "$OUT"
APK="$OUT/terraforming-mars-$VERSION_NAME.apk"
cp "$ANDROID_DIR/app/build/outputs/apk/release/app-release.apk" "$APK"
cp "$APK" "$OUT/terraforming-mars.apk"
log "APK: $APK"
ls -la "$APK"
