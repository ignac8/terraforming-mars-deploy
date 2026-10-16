#!/bin/sh
# Builds the offline Android APK (the automa-android branch, see android/README.md
# there) and publishes it where Caddy serves it: https://$DOMAIN/android/, behind
# basic auth.
#
# update.sh keeps the android checkout on origin/automa-android with origin/automa
# merged in, and starts this script in the background every minute. Most minutes
# it only compares the checkout's HEAD with the last build and exits. A build:
#   - runs in the tm-apk-builder image (android/Dockerfile), capped at 2 CPUs and
#     4 GB so the game servers keep the rest of the box;
#   - works on its own clone of the checkout, so update.sh can move the checkout
#     mid-build;
#   - is published only when apksigner shows the release key's certificate, so a
#     throwaway-signed APK (which a phone refuses as an update) never goes out.
# A failed build is not retried until the checkout moves again.
#
# Everything lives under ANDROID_WORK (default ~/tm-android):
#   build/                 the clone the container builds in
#   cache/                 gradle, npm and nodejs-mobile downloads, kept across builds
#   apk/                   what Caddy serves: terraforming-mars.apk, the last few
#                          versioned APKs, version.txt
#   keystore/release.jks   the signing key, copied in by hand (README)
#   state/                 built / failed (commit of the last of each), last-build.log
#
# By hand: ~/tm-deploy/android-build.sh   (FORCE=1 rebuilds the same commit;
# ANDROID_BUILD_USER=0:0 on a rootless docker, where root in the container is you)

exec 8>/tmp/tm-android-build.lock
flock -n 8 || exit 0

DEPLOY_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ANDROID_CHECKOUT="${ANDROID_CHECKOUT:-$DEPLOY_DIR/../terraforming-mars-android}"
ANDROID_BRANCH="${ANDROID_BRANCH:-automa-android}"
ANDROID_WORK="${ANDROID_WORK:-$DEPLOY_DIR/../tm-android}"
ANDROID_KEYSTORE="${ANDROID_KEYSTORE:-$ANDROID_WORK/keystore/release.jks}"
# SHA-256 of release.jks's certificate (lower case, no colons).
APK_CERT_SHA256="${APK_CERT_SHA256:-cbb56f1cfa75615d791782712b38fdfa4e8df855ed103365dc71ca915dedd2a6}"
ANDROID_BUILD_USER="${ANDROID_BUILD_USER:-$(id -u):$(id -g)}"
IMAGE=tm-apk-builder

log() { echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') $*"; }

[ -d "$ANDROID_CHECKOUT/.git" ] || exit 0   # update.sh clones it
HEAD=$(git -C "$ANDROID_CHECKOUT" rev-parse HEAD) || exit 1
mkdir -p "$ANDROID_WORK/state" "$ANDROID_WORK/cache/home" "$ANDROID_WORK/apk"
ANDROID_WORK=$(CDPATH='' cd -- "$ANDROID_WORK" && pwd)
STATE="$ANDROID_WORK/state"
BUILD="$ANDROID_WORK/build"
if [ -z "$FORCE" ]; then
    [ "$HEAD" = "$(cat "$STATE/built" 2>/dev/null)" ] && exit 0
    [ "$HEAD" = "$(cat "$STATE/failed" 2>/dev/null)" ] && exit 0
fi

BUILD_LOG="$STATE/last-build.log"
: > "$BUILD_LOG"
fail() {
    log "ERROR: APK build of $(echo "$HEAD" | cut -c1-9) failed: $*; see $BUILD_LOG"
    echo "$HEAD" > "$STATE/failed"
    exit 1
}

[ -f "$ANDROID_KEYSTORE" ] || fail "no signing key at $ANDROID_KEYSTORE"

# The image, rebuilt only when android/Dockerfile changes.
DOCKERFILE_SHA=$(sha256sum "$DEPLOY_DIR/android/Dockerfile" | cut -c1-16)
if [ "$(docker image inspect -f '{{index .Config.Labels "tm.dockerfile"}}' "$IMAGE" 2>/dev/null)" != "$DOCKERFILE_SHA" ]; then
    log "building the $IMAGE image"
    docker build -q --label "tm.dockerfile=$DOCKERFILE_SHA" -t "$IMAGE" "$DEPLOY_DIR/android" >> "$BUILD_LOG" 2>&1 \
        || fail "docker build of $IMAGE"
fi

# The clone: the checkout's branch, which update.sh keeps at its HEAD.
if [ ! -d "$BUILD/.git" ]; then
    rm -rf "$BUILD"
    git clone -q --no-checkout "$ANDROID_CHECKOUT" "$BUILD" >> "$BUILD_LOG" 2>&1 || fail "git clone"
fi
git -C "$BUILD" fetch -q --no-tags origin "$ANDROID_BRANCH" >> "$BUILD_LOG" 2>&1 || fail "git fetch"
# The checkout may have moved since HEAD was read; build and stamp what was fetched.
HEAD=$(git -C "$BUILD" rev-parse FETCH_HEAD)
git -C "$BUILD" checkout -qf --detach "$HEAD" >> "$BUILD_LOG" 2>&1 || fail "git checkout"
git -C "$BUILD" clean -qffdx >> "$BUILD_LOG" 2>&1

# Passwords and alias default to build-apk.sh's own defaults; .env overrides them.
# Only these keys reach the container, never the rest of .env.
for key in ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD; do
    value=$(grep -E "^$key=" "$DEPLOY_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2- | sed -e "s/^['\"]//" -e "s/['\"]\$//")
    [ -n "$value" ] && export "$key=$value"
done

builder() {
    docker run --rm --user "$ANDROID_BUILD_USER" --cpus 2 --memory 4g --cpu-shares 256 \
        -v "$BUILD:/work" -v "$ANDROID_WORK/cache:/cache" \
        -v "$(dirname "$ANDROID_KEYSTORE"):/keystore:ro" \
        -e ANDROID_KEYSTORE="/keystore/$(basename "$ANDROID_KEYSTORE")" \
        -e ANDROID_KEYSTORE_PASSWORD -e ANDROID_KEY_ALIAS -e ANDROID_KEY_PASSWORD \
        "$IMAGE" "$@"
}

log "building the APK at $(git -C "$BUILD" log -1 --format='%h %s' | cut -c1-100)"
START=$(date +%s)
builder android/build-apk.sh >> "$BUILD_LOG" 2>&1 || fail "android/build-apk.sh"

APK=$(ls -t "$BUILD"/android/out/terraforming-mars-*.apk 2>/dev/null | head -1)
[ -n "$APK" ] || fail "no APK in android/out"
NAME=$(basename "$APK")
CERT=$(builder apksigner verify --print-certs "android/out/$NAME" 2>> "$BUILD_LOG" \
    | sed -n 's/.*certificate SHA-256 digest: //p' | head -1)
[ "$CERT" = "$APK_CERT_SHA256" ] || fail "$NAME is signed with ${CERT:-no certificate}, not the release key"

# Publish: copy next to the target, then rename, so a download never sees half a file.
cp "$APK" "$STATE/$NAME.part" && mv "$STATE/$NAME.part" "$ANDROID_WORK/apk/$NAME"
cp "$APK" "$STATE/latest.part" && mv "$STATE/latest.part" "$ANDROID_WORK/apk/terraforming-mars.apk"
VERSION=${NAME%.apk}
echo "${VERSION#terraforming-mars-} $HEAD" > "$STATE/version.part" && mv "$STATE/version.part" "$ANDROID_WORK/apk/version.txt"
ls -t "$ANDROID_WORK"/apk/terraforming-mars-*.apk | tail -n +4 | xargs -r rm -f

echo "$HEAD" > "$STATE/built"
rm -f "$STATE/failed"
touch /tmp/tm-last-build-apk
log "published $NAME ($(du -h "$APK" | cut -f1)) in $(( ($(date +%s) - START) / 60 ))m"
