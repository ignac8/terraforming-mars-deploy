# Deployment

All deployment configuration for the VPS lives in this repo. It runs **two instances** of the game server behind one Caddy:

- **app** — the main instance, built from the `automa` branch
- **app-tournament** — the tournament practice instance, built from the `tournament` branch

Each instance has its own PostgreSQL container and volume. Caddy terminates
SSL for both domains.

## VPS layout

```
~/tm-deploy/                     this repo (compose, Caddyfile, update.sh, .env)
~/terraforming-mars/             automa checkout (source only)
~/terraforming-mars-tournament/  tournament checkout (source only)
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
```

`backup.sh` dumps both databases to `~/tm-backups/` and keeps 14 days
(`BACKUP_DIR` / `RETENTION_DAYS` env overrides).

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
  `MAIN_BRANCH`, `TOURNAMENT_BRANCH`, `DEPLOY_BRANCH`.
- The lock file is `/tmp/tm-deploy-update.lock`; build markers are
  `/tmp/tm-last-build-app` and `/tmp/tm-last-build-app-tournament`.
