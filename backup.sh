#!/bin/sh
# Daily database dumps for both instances — invoked by cron:
#   17 3 * * * ~/tm-deploy/backup.sh >> ~/tm-backup.log 2>&1
# Dumps land in $BACKUP_DIR (default ~/tm-backups) and are kept RETENTION_DAYS days.

DEPLOY_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
BACKUP_DIR="${BACKUP_DIR:-$HOME/tm-backups}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"

. "$DEPLOY_DIR/.env"
mkdir -p "$BACKUP_DIR"
STAMP=$(date -u +%Y%m%d)

docker exec deploy-postgres-1 pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" | gzip > "$BACKUP_DIR/main-$STAMP.sql.gz"
docker exec deploy-postgres-tournament-1 pg_dump -U "$TOURNAMENT_POSTGRES_USER" "$TOURNAMENT_POSTGRES_DB" | gzip > "$BACKUP_DIR/tournament-$STAMP.sql.gz"

find "$BACKUP_DIR" -name "*.sql.gz" -mtime +"$RETENTION_DAYS" -delete
