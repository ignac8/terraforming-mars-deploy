#!/bin/sh
# Harvest housie's in-app backups into the private housie-backups repo — cron:
#   40 3 * * * ~/tm-deploy/housie-backup.sh >> ~/housie-backup.log 2>&1
# The in-app job runs at 03:20 — the two schedules are COUPLED; move both together.
#
# Stable filenames on purpose: git history IS the timeline, and
# `git log -p housie-export.json` stays a readable diary of the board.
# Deliberately no `set -e`: a missing snapshot must not abort the attachment sync.

BACKUP_REPO="${BACKUP_REPO:-$HOME/housie-backups}"
CONTAINER="${CONTAINER:-housie}"
STAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

if [ ! -d "$BACKUP_REPO/.git" ]; then
    echo "$STAMP ERROR: $BACKUP_REPO is not a git clone — bootstrap it first (see README)"
    exit 1
fi

latest() {
    docker exec "$CONTAINER" sh -c "cd /data/backups 2>/dev/null && ls -1 $1 2>/dev/null | sort | tail -1"
}

SNAP=$(latest 'housie-*.db')
EXPORT=$(latest 'export-*.json')

if [ -n "$SNAP" ]; then
    docker exec "$CONTAINER" cat "/data/backups/$SNAP" > "$BACKUP_REPO/housie.db"
else
    echo "$STAMP WARNING: no snapshot in the container yet"
fi

if [ -n "$EXPORT" ]; then
    docker exec "$CONTAINER" cat "/data/backups/$EXPORT" > "$BACKUP_REPO/housie-export.json"
else
    echo "$STAMP WARNING: no export in the container yet"
fi

rm -rf "$BACKUP_REPO/attachments"
docker exec "$CONTAINER" tar -cf - -C /data attachments 2>/dev/null | tar -xf - -C "$BACKUP_REPO" \
    || echo "$STAMP WARNING: attachment sync failed (no attachments yet?)"

cd "$BACKUP_REPO" || exit 1
git add -A
if git diff --cached --quiet; then
    echo "$STAMP nothing changed since the last harvest"
else
    git -c user.email=backup@housie.zerko.it -c user.name="housie backup" \
        commit -q -m "backup $STAMP"
    git push -q origin main || echo "$STAMP ERROR: git push failed"
    echo "$STAMP harvested $SNAP + $EXPORT + attachments"
fi
