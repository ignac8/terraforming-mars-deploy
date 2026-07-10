#!/bin/sh
# Auto-update script — invoked by cron every minute.
#
# Manages the whole VPS deployment:
#   1. Self-updates from origin/deploy (this branch).
#   2. Updates the source checkouts:
#        main       — origin/automa, with upstream/main auto-merged
#        tournament — origin/tournament, no upstream merge (kept stable by hand)
#   3. Refreshes Docker base images and rebuilds/recreates whatever changed.
#
# Self-locking: if another instance is running, exit silently. Safe to run
# manually without conflicting with the cron.

exec 9>/tmp/tm-deploy-update.lock
flock -n 9 || exit 0

DEPLOY_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
MAIN_CHECKOUT="${MAIN_CHECKOUT:-$DEPLOY_DIR/../terraforming-mars}"
TOURNAMENT_CHECKOUT="${TOURNAMENT_CHECKOUT:-$DEPLOY_DIR/../terraforming-mars-tournament}"
MAIN_BRANCH="${MAIN_BRANCH:-automa}"
TOURNAMENT_BRANCH="${TOURNAMENT_BRANCH:-tournament}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-deploy}"
LOG_PREFIX="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

# --- 1. Self-update ---------------------------------------------------------
if git -C "$DEPLOY_DIR" fetch -q origin "$DEPLOY_BRANCH" 2>&1; then
    if ! git -C "$DEPLOY_DIR" merge-base --is-ancestor "origin/$DEPLOY_BRANCH" HEAD 2>/dev/null; then
        echo "$LOG_PREFIX origin/$DEPLOY_BRANCH has new commits, resetting and restarting"
        git -C "$DEPLOY_DIR" reset --hard "origin/$DEPLOY_BRANCH"
        exec "$0" "$@"
    fi
else
    echo "$LOG_PREFIX ERROR: git fetch origin ($DEPLOY_BRANCH) failed"
fi

# --- 2. Source checkouts ----------------------------------------------------
# update_checkout <dir> <branch> <merge_upstream: yes|no>
# Echoes 1 when the checkout changed, 0 otherwise.
update_checkout() {
    changed=0
    if git -C "$1" fetch -q origin "$2" 2>&1; then
        if ! git -C "$1" merge-base --is-ancestor "origin/$2" HEAD 2>/dev/null; then
            echo "$LOG_PREFIX origin/$2 has new commits, resetting $1" >&2
            git -C "$1" reset --hard "origin/$2" >&2
            changed=1
        fi
    else
        echo "$LOG_PREFIX ERROR: git fetch origin ($2) failed in $1" >&2
    fi

    if [ "$3" = "yes" ]; then
        if git -C "$1" fetch -q upstream main 2>&1; then
            MERGE_BASE=$(git -C "$1" merge-base HEAD upstream/main)
            UPSTREAM_HEAD=$(git -C "$1" rev-parse upstream/main)
            if [ "$MERGE_BASE" != "$UPSTREAM_HEAD" ]; then
                echo "$LOG_PREFIX upstream/main has new commits, merging into $1" >&2
                if git -C "$1" -c user.email=updater@terraforming-mars -c user.name=updater merge upstream/main --no-edit >&2; then
                    changed=1
                else
                    echo "$LOG_PREFIX ERROR: merge conflict with upstream/main, aborting" >&2
                    git -C "$1" merge --abort >&2
                fi
            fi
        else
            echo "$LOG_PREFIX ERROR: git fetch upstream failed in $1" >&2
        fi
    fi
    echo "$changed"
}

MAIN_CHANGED=$(update_checkout "$MAIN_CHECKOUT" "$MAIN_BRANCH" yes)
TOURNAMENT_CHANGED=$(update_checkout "$TOURNAMENT_CHECKOUT" "$TOURNAMENT_BRANCH" no)

# --- 3. Base images ---------------------------------------------------------
# Pull base images referenced by the Dockerfiles' FROM lines and detect digest
# changes. Pulls only fetch image layer storage, not buildkit cache, so they're
# safe to run every minute. External bases are FROM targets containing `:` or
# `/` (excludes internal stage names). ARG NODE_VERSION is substituted from the
# Dockerfile default.
base_images() {
    NODE_VERSION=$(awk -F= '/^ARG NODE_VERSION=/ {print $2; exit}' "$1/Dockerfile")
    awk '/^FROM/ {print $2}' "$1/Dockerfile" | grep -E '[:/]' | sed "s/\${NODE_VERSION}/$NODE_VERSION/g"
}

BASE_CHANGED=0
BASES=$( (base_images "$MAIN_CHECKOUT"; base_images "$TOURNAMENT_CHECKOUT") | sort -u)
for img in $BASES; do
    BEFORE=$(docker image inspect -f '{{.Id}}' "$img" 2>/dev/null || echo none)
    docker pull -q "$img" >/dev/null 2>&1 || continue
    AFTER=$(docker image inspect -f '{{.Id}}' "$img" 2>/dev/null || echo none)
    if [ "$BEFORE" != "$AFTER" ]; then
        echo "$LOG_PREFIX base image $img updated"
        BASE_CHANGED=1
    fi
done

# --- 4. Build & recreate ----------------------------------------------------
# Build a locally-built service when its checkout changed, a base image was
# just updated, or its marker is missing / older than a week. The weekly
# fallback covers anything the digest-based detection silently misses.
needs_build() {
    marker="/tmp/tm-last-build-$1"
    if [ "$2" = "1" ] || [ "$BASE_CHANGED" = "1" ]; then
        return 0
    fi
    if [ ! -f "$marker" ] || [ $(($(date +%s) - $(stat -c %Y "$marker"))) -gt 604800 ]; then
        return 0
    fi
    return 1
}

cd "$DEPLOY_DIR" || exit 1
docker compose pull --quiet 2>&1
for service_and_flag in "app:$MAIN_CHANGED" "app-tournament:$TOURNAMENT_CHANGED"; do
    service=${service_and_flag%%:*}
    flag=${service_and_flag##*:}
    if needs_build "$service" "$flag"; then
        docker compose build --quiet "$service" 2>&1
        touch "/tmp/tm-last-build-$service"
    fi
done
docker compose up -d --remove-orphans 2>&1 | grep -vE 'Running$|Healthy$' || true

# Cap total build cache at 5 GB. Belt-and-suspenders: when build only runs on
# real changes, cache shouldn't grow much, but this prevents pathological growth.
docker builder prune -f --reserved-space 5gb 2>&1 | grep -vE '^Total:[[:space:]]*0B$' || true
