# Deployment

All deployment configuration for the VPS lives in this repo. It runs **two
instances** of the game server plus **housie** (the family task board) behind
one Caddy:

- **app** — the main instance, built from the `automa` branch
- **app-tournament** — the tournament practice instance, built from the `tournament` branch
- **housie** — private task board, built from `ignac8/housie` `main`

Each game instance has its own PostgreSQL container and volume; housie keeps
SQLite + attachment files on its own volume. Caddy terminates SSL for all
domains.

## VPS layout

```
~/tm-deploy/                     this repo (compose, Caddyfile, update.sh, .env)
~/terraforming-mars/             automa checkout (source only)
~/terraforming-mars-tournament/  tournament checkout (source only)
~/housie/                        housie checkout (source only)
~/housie-backups/                clone of ignac8/housie-backups (harvest target)
```

Containers (compose project pinned to `deploy` so the pre-existing volumes
`deploy_pgdata`, `deploy_caddy_data`, `deploy_caddy_config` keep working):

- `app` + `postgres` (networks: frontend, backend)
- `app-tournament` + `postgres-tournament` (networks: frontend, backend-tournament)
- `caddy` (ports 80/443, network: frontend)

## Auto-update

A host cron job runs `update.sh` every minute. It:

1. Self-updates from this repo (re-executes itself after a reset).
2. Resets the automa checkout to `origin/automa` and merges `upstream/main` into it.
3. Same for the tournament checkout with `origin/tournament`.
4. Pulls Docker base images, rebuilds `app`/`app-tournament` when their sources
   or bases changed (with a weekly fallback rebuild), and `docker compose up -d`.

Crontab entries (updates every minute, database backups nightly):

```
* * * * * ~/tm-deploy/update.sh >> ~/tm-update.log 2>&1
17 3 * * * ~/tm-deploy/backup.sh >> ~/tm-backup.log 2>&1
40 3 * * * ~/tm-deploy/housie-backup.sh >> ~/housie-backup.log 2>&1
```

`backup.sh` dumps both databases to `~/tm-backups/` and keeps 14 days
(`BACKUP_DIR` / `RETENTION_DAYS` env overrides).

`housie-backup.sh` harvests housie's own 03:20 in-app backups (SQLite
snapshot + JSON export + attachment files) into `~/housie-backups` and
pushes — git history is the timeline. **03:20/03:40 are coupled; move both
together.** Restore procedure: `docs/backup-restore.md` in the housie repo
(short version: stop container, drop the snapshot in as `housie.db`,
DELETE any stale `housie.db-wal`/`-shm`, `chown -R 1000:1000`, start).

## Fresh setup

1. Clone the three checkouts:
   ```bash
   git clone https://github.com/ignac8/terraforming-mars-deploy.git ~/tm-deploy
   git clone -b automa https://github.com/ignac8/terraforming-mars.git ~/terraforming-mars
   git -C ~/terraforming-mars remote add upstream https://github.com/terraforming-mars/terraforming-mars.git
   git clone -b tournament https://github.com/ignac8/terraforming-mars.git ~/terraforming-mars-tournament
   git -C ~/terraforming-mars-tournament remote add upstream https://github.com/terraforming-mars/terraforming-mars.git
   ```
2. `cp ~/tm-deploy/.env.example ~/tm-deploy/.env` and fill in domains, database
   credentials and server ids (`openssl rand -hex 16` makes good secrets).
3. Point DNS A records for both domains at the VPS. Caddy retries certificate
   issuance until DNS resolves, so ordering is flexible.
4. `cd ~/tm-deploy && docker compose up -d`
5. Add the crontab entry above.

Admin panels: `https://<DOMAIN>/admin?serverId=<SERVER_ID>` and
`https://<TOURNAMENT_DOMAIN>/admin?serverId=<TOURNAMENT_SERVER_ID>`.

## Notes

- Unfinished games are purged 10 days after creation by default; set
  `MAX_GAME_DAYS` / `TOURNAMENT_MAX_GAME_DAYS` in `.env` to change (the
  official server uses 7).
- `update.sh` env overrides: `MAIN_CHECKOUT`, `TOURNAMENT_CHECKOUT`,
  `HOUSIE_CHECKOUT`, `MAIN_BRANCH`, `TOURNAMENT_BRANCH`, `HOUSIE_BRANCH`,
  `DEPLOY_BRANCH`.
- The lock file is `/tmp/tm-deploy-update.lock`; build markers are
  `/tmp/tm-last-build-app`, `/tmp/tm-last-build-app-tournament` and
  `/tmp/tm-last-build-housie`.
- housie's `HOUSIE_DOMAIN` default (`housie.localhost`) is declared BOTH in
  compose and in the Caddyfile placeholder — a set-but-empty variable would
  otherwise defeat Caddy's fallback and swallow every request on the vhost.
- housie serves attachments only through its authenticated API; nothing from
  its volume is ever mounted into Caddy.
