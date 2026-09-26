# Deployment

All deployment configuration for the VPS lives in this repo. It runs **two
instances** of the game server plus **housie** (the family task board) behind
one Caddy:

- **app** — the main instance, built from the `automa` branch
- **app-tournament** — the tournament practice instance, built from the `tournament` branch
- **housie** — private task board, built from `ignac8/housie` `main`
- **showdown** — an upstream Pokemon Showdown server at the commit pokebot pins, for the arena
- **arena** — pokebot's Platinum bot, built from `ignac8/pokebot` `main` (private; deploy key)

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
~/pokebot/                       pokebot checkout (source only)
```

Containers (compose project pinned to `deploy` so the pre-existing volumes
`deploy_pgdata`, `deploy_caddy_data`, `deploy_caddy_config` keep working):

- `app` + `postgres` (networks: frontend, backend)
- `app-tournament` + `postgres-tournament` (networks: frontend, backend-tournament)
- `housie` (volume `housie_data`, network: frontend)
- `showdown` (127.0.0.1:8000, networks: frontend, backend-arena) + `arena` (network: backend-arena)
- `caddy` (ports 80/443, network: frontend)

## Auto-update

A host cron job runs `update.sh` every minute. It:

1. Self-updates from this repo (re-executes itself after a reset).
2. Resets the automa checkout to `origin/automa` and merges `upstream/main` into it.
3. Same for the tournament checkout with `origin/tournament`.
4. Resets the pokebot checkout to `origin/main`, no upstream merge (same
   pattern as housie).
5. Pulls Docker base images, rebuilds `app`/`app-tournament` when their sources
   or bases changed (with a weekly fallback rebuild), `arena` when its
   checkout changed, `showdown` when its Dockerfile changed, and
   `docker compose up -d`.

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
When the attachment set nears **~2 GB**, move attachments off the git
harvest to restic + Backblaze B2 — the prepared runbook (bucket, `.env`
keys, cron line) is in the same `docs/backup-restore.md`.

## Health check

`~/tm-deploy/health.sh` is the manual "is everything fine" command. It is
read-only and runs the same with or without sudo (only the OOM-kill check
needs the kernel log, so either the adm group or sudo). It checks the host (load, memory, disk, reboot
pending, failed units, OOM kills, ports 80/443 open and 8000 loopback-only),
every compose service's state and health, the public endpoints through Caddy
with certificate expiry judged against Caddy's renewal window, the update
cron (crontab lines, last run, `~/tm-update.log` errors, build markers,
each checkout in sync with origin), both Postgres instances, the nightly
dumps and the housie harvest, the arena's recent games and Caddy's TLS
errors. Every check is `ok`, `WARN` or `FAIL`, the summary at the end repeats
the non-ok ones, and the exit code is non-zero when anything failed.

For "was it slow earlier?" the Performance section reads today's `sar` history
(busiest 10 minutes, peak load, lowest available memory, steal) and each game
server's `/api/metrics`: the longest event-loop stall, which is the lag every
player on that instance feels, and how many database operations took over 1 s
or 2.5 s since the container started. The stall figure covers the time since
the app started or since the last health.sh run, whichever is later, because
prom-client resets it on every read of `/api/metrics`. The metrics are fetched
from inside each container, so `SERVER_ID` never leaves it. Pending apt
updates are `ok` with the next unattended-upgrades run named, and a merge
conflict stops counting as a warning once every checkout has `upstream/main`.

## Fresh setup

1. Clone the checkouts:
   ```bash
   git clone https://github.com/ignac8/terraforming-mars-deploy.git ~/tm-deploy
   git clone -b automa https://github.com/ignac8/terraforming-mars.git ~/terraforming-mars
   git -C ~/terraforming-mars remote add upstream https://github.com/terraforming-mars/terraforming-mars.git
   git clone -b tournament https://github.com/ignac8/terraforming-mars.git ~/terraforming-mars-tournament
   git -C ~/terraforming-mars-tournament remote add upstream https://github.com/terraforming-mars/terraforming-mars.git
   git clone github-housie:ignac8/housie.git ~/housie
   git clone github-housie-backups:ignac8/housie-backups.git ~/housie-backups
   git clone github-pokebot:ignac8/pokebot.git ~/pokebot
   ```
   The last three are private and use the deploy-key host aliases
   (`github-housie` read-only, `github-housie-backups` read-write) from
   `~/.ssh/config` — key setup is in the housie repo's `docs/deploy.md`.
   `github-pokebot` (read-only) is a third alias, set up the same way as
   `github-housie`.
2. `cp ~/tm-deploy/.env.example ~/tm-deploy/.env` and fill in domains, database
   credentials and server ids (`openssl rand -hex 16` makes good secrets).
3. Point DNS A records for all domains, `pokemon.zerko.it` included, at the
   VPS. Caddy retries certificate issuance until DNS resolves, so ordering is
   flexible.
4. `cd ~/tm-deploy && docker compose up -d`
5. Add the crontab entry above.

Admin panels: `https://<DOMAIN>/admin?serverId=<SERVER_ID>` and
`https://<TOURNAMENT_DOMAIN>/admin?serverId=<TOURNAMENT_SERVER_ID>`.

## Playing Platinum

The arena is pokebot's Platinum bot on a Gen 5 OU server at `ARENA_DOMAIN`
(`pokemon.zerko.it`). Open `https://play.pokemonshowdown.com/~~pokemon.zerko.it`
-- the hosted client redirects to `https://pokemon-zerko-it.psim.us/` and connects
to this server over 443. Choose a name (no password: the server runs without login
security, like the game instances it sits beside), import a Gen 5 team in the
teambuilder, and challenge `Platinum` in `[Gen 5] OU`. Platinum plays a fresh team
every game and one game at a time.

Results: `docker logs arena` prints one line per finished game with the team seed.
`.env` keys: `ARENA_DOMAIN` (default `pokemon.zerko.it`, so nothing is needed for the
production host), `ARENA_BOT_NAME` (default `Platinum`),
`ARENA_CHALLENGERS` (comma-separated names to accept from; empty means anyone).

If the hosted client cannot reach the server, the tunnel door is
`ssh -L 8000:localhost:8000 <vps>` and then `https://localhost.psim.us/`.

## Notes

- Unfinished games are purged 10 days after creation by default; set
  `MAX_GAME_DAYS` / `TOURNAMENT_MAX_GAME_DAYS` in `.env` to change (the
  official server uses 7).
- `update.sh` env overrides: `MAIN_CHECKOUT`, `TOURNAMENT_CHECKOUT`,
  `HOUSIE_CHECKOUT`, `POKEBOT_CHECKOUT`, `MAIN_BRANCH`, `TOURNAMENT_BRANCH`,
  `HOUSIE_BRANCH`, `POKEBOT_BRANCH`, `DEPLOY_BRANCH`.
- The lock file is `/tmp/tm-deploy-update.lock`; build markers are
  `/tmp/tm-last-build-app`, `/tmp/tm-last-build-app-tournament`,
  `/tmp/tm-last-build-housie`, `/tmp/tm-last-build-arena` and
  `/tmp/tm-last-build-showdown`.
- housie's `HOUSIE_DOMAIN` default (`housie.localhost`) is declared BOTH in
  compose and in the Caddyfile placeholder — a set-but-empty variable would
  otherwise defeat Caddy's fallback and swallow every request on the vhost.
  `ARENA_DOMAIN` (`pokemon.zerko.it` — the production name itself, so the
  vhost needs no `.env` entry) follows the same pattern for the same reason.
- housie serves attachments only through its authenticated API; nothing from
  its volume is ever mounted into Caddy.
