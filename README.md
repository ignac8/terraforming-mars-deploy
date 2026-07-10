# Deployment

All deployment configuration for the VPS lives on this orphan `deploy` branch.
It runs **two instances** of the game server behind one Caddy:

- **app** — the main instance, built from the `automa` branch
- **app-tournament** — the tournament practice instance, built from the `tournament` branch

Each instance has its own PostgreSQL container and volume. Caddy terminates
SSL for both domains.

## VPS layout

```
~/tm-deploy/                     this branch (compose, Caddyfile, update.sh, .env)
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

1. Self-updates from `origin/deploy` (re-executes itself after a reset).
2. Resets the automa checkout to `origin/automa` and merges `upstream/main` into it.
3. Resets the tournament checkout to `origin/tournament`. **No upstream merge** —
   that branch is updated deliberately, by hand.
4. Pulls Docker base images, rebuilds `app`/`app-tournament` when their sources
   or bases changed (with a weekly fallback rebuild), and `docker compose up -d`.

Crontab entry:

```
* * * * * ~/tm-deploy/update.sh >> ~/tm-update.log 2>&1
```

## Fresh setup

1. Clone the three checkouts:
   ```bash
   git clone -b deploy https://github.com/ignac8/terraforming-mars.git ~/tm-deploy
   git clone -b automa https://github.com/ignac8/terraforming-mars.git ~/terraforming-mars
   git -C ~/terraforming-mars remote add upstream https://github.com/terraforming-mars/terraforming-mars.git
   git clone -b tournament https://github.com/ignac8/terraforming-mars.git ~/terraforming-mars-tournament
   ```
2. `cp ~/tm-deploy/.env.example ~/tm-deploy/.env` and fill in domains, database
   credentials and server ids (`openssl rand -hex 16` makes good secrets).
3. Point DNS A records for both domains at the VPS. Caddy retries certificate
   issuance until DNS resolves, so ordering is flexible.
4. `cd ~/tm-deploy && docker compose up -d`
5. Add the crontab entry above.

Admin panels: `https://<DOMAIN>/admin?serverId=<SERVER_ID>` and
`https://<TOURNAMENT_DOMAIN>/admin?serverId=<TOURNAMENT_SERVER_ID>`.

## Migration from the old single-instance setup

The old setup ran everything from `~/terraforming-mars/deploy/` with the compose
project name implicitly `deploy`. Order matters: the old cron hard-resets the
automa checkout every minute, so the automa commit that removes `deploy/` must
be pushed **last**.

1. **Push branches** (`deploy`, `tournament`) — invisible to the running setup.
2. **On the VPS:**
   ```bash
   git clone -b deploy https://github.com/ignac8/terraforming-mars.git ~/tm-deploy
   git clone -b tournament https://github.com/ignac8/terraforming-mars.git ~/terraforming-mars-tournament
   cp ~/terraforming-mars/deploy/.env ~/tm-deploy/.env   # then add the TOURNAMENT_* values
   crontab -e   # swap the update.sh path to ~/tm-deploy/update.sh
   cd ~/tm-deploy && docker compose up -d
   ```
   The pinned project name reuses the existing volumes: the database and the
   SSL certificates survive; containers are recreated. Verify both sites load
   and the main instance still has its games, then delete the stale
   `~/terraforming-mars/deploy/.env`.
3. **Push the automa commit that removes `deploy/`.** From then on the automa
   checkout is source-only.

If step 3 ever lands before step 2, nothing burns down: containers keep
running, only the old auto-update pipeline stops until step 2 completes.

## Notes

- Unfinished games are purged 10 days after creation by default; set
  `MAX_GAME_DAYS` / `TOURNAMENT_MAX_GAME_DAYS` in `.env` to change (the
  official server uses 7).
- `update.sh` env overrides: `MAIN_CHECKOUT`, `TOURNAMENT_CHECKOUT`,
  `MAIN_BRANCH`, `TOURNAMENT_BRANCH`, `DEPLOY_BRANCH`.
- The lock file is `/tmp/tm-deploy-update.lock`; build markers are
  `/tmp/tm-last-build-app` and `/tmp/tm-last-build-app-tournament`.
