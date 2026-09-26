#!/usr/bin/env bash
# Manual health check for the VPS and everything update.sh deploys on it:
#   ~/tm-deploy/health.sh
# Read-only: starts nothing, changes nothing. Prints ok / WARN / FAIL per check, a
# summary at the end, and exits non-zero when anything FAILed. Works the same with
# and without sudo: the operator is whoever owns this directory (mzerko), so the
# logs, backups and crontab are theirs even when sudo has pointed HOME at /root,
# and git runs as them through runuser so root never writes into their checkouts
# (each runuser call leaves a PAM session line in auth.log, its only trace). sudo
# buys one thing: the kernel log, where OOM kills show up. Any other user is refused.
# Checkout locations and branches honour the same env overrides as update.sh;
# BACKUP_DIR and BACKUP_REPO the same as backup.sh and housie-backup.sh; APT_STAMPS
# points the apt check at another /var/lib/apt/periodic (for trying it on fixtures).
exec </dev/null
export GIT_PAGER=cat PAGER=cat SYSTEMD_PAGER=cat LC_ALL=C GIT_OPTIONAL_LOCKS=0
DEPLOY_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
D=$DEPLOY_DIR; ENVF=$D/.env; PROJECT=deploy
OWNER=$(stat -c %U "$DEPLOY_DIR" 2>/dev/null); OWNER=${OWNER:-$(id -un)}
OWNER_HOME=$(getent passwd "$OWNER" 2>/dev/null | cut -d: -f6); OWNER_HOME=${OWNER_HOME:-$HOME}
if [ "$(id -un)" != "$OWNER" ] && [ "$(id -u)" = 0 ]; then
  gitc(){ runuser -u "$OWNER" -- git "$@"; }
  cronlist(){ crontab -l -u "$OWNER"; }
else
  gitc(){ git "$@"; }
  cronlist(){ crontab -l; }
fi
if [ "$(id -un)" != "$OWNER" ] && [ "$(id -u)" != 0 ]; then
  echo "health.sh: $DEPLOY_DIR is owned by $OWNER — run it as $OWNER or with sudo" >&2; exit 2
fi
MAIN_CHECKOUT="${MAIN_CHECKOUT:-$DEPLOY_DIR/../terraforming-mars}"
TOURNAMENT_CHECKOUT="${TOURNAMENT_CHECKOUT:-$DEPLOY_DIR/../terraforming-mars-tournament}"
HOUSIE_CHECKOUT="${HOUSIE_CHECKOUT:-$DEPLOY_DIR/../housie}"
POKEBOT_CHECKOUT="${POKEBOT_CHECKOUT:-$DEPLOY_DIR/../pokebot}"
MAIN_BRANCH="${MAIN_BRANCH:-automa}"
TOURNAMENT_BRANCH="${TOURNAMENT_BRANCH:-tournament}"
HOUSIE_BRANCH="${HOUSIE_BRANCH:-main}"
POKEBOT_BRANCH="${POKEBOT_BRANCH:-main}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-main}"
BACKUP_DIR="${BACKUP_DIR:-$OWNER_HOME/tm-backups}"
BACKUP_REPO="${BACKUP_REPO:-$OWNER_HOME/housie-backups}"
APT_STAMPS="${APT_STAMPS:-/var/lib/apt/periodic}"
R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
[ -t 1 ] || R= G= Y= B= N=
FAILS=(); WARNS=()
ok(){ echo "  ${G}ok${N}   $*"; }
warn(){ echo "  ${Y}WARN${N} $*"; WARNS+=("$*"); }
fail(){ echo "  ${R}FAIL${N} $*"; FAILS+=("$*"); }
info(){ echo "       $*"; }
hdr(){ echo; echo "${B}== $* ==${N}"; }
envv(){ grep -E "^$1=" "$ENVF" 2>/dev/null | head -1 | cut -d= -f2- | sed -e "s/^['\"]//" -e "s/['\"]\$//"; }
age(){ local m; m=$(stat -c %Y "$1" 2>/dev/null) || m=0; echo $(( $(date +%s) - m )); }
hum(){ local s=$1; if ((s<0)); then echo "${s}s"; elif ((s<120)); then echo "${s}s"; elif ((s<7200)); then echo "$((s/60))m"; elif ((s<172800)); then echo "$((s/3600))h"; else echo "$((s/86400))d $(( (s%86400)/3600 ))h"; fi; }
has(){ command -v "$1" >/dev/null 2>&1; }
dk(){ timeout 60 docker "$@"; }   # a wedged daemon must not hang the check
cid_of(){ dk ps -aq --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=$1" 2>/dev/null | head -1; }

# ---------------------------------------------------------------- system ----
hdr "System · $(hostname) · $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
info "$(uptime | sed 's/^ *//')"
load1=$(cut -d' ' -f1 /proc/loadavg); cores=$(nproc)
if awk -v l="$load1" -v c="$cores" 'BEGIN{exit !(l > c)}'; then warn "load $load1 on $cores cores"; else ok "load $load1 on $cores cores"; fi
memav=$(free | awk '/^Mem:/ {printf "%d", $7*100/$2}')
if ((memav < 10)); then fail "memory: only ${memav}% available"; elif ((memav < 20)); then warn "memory: ${memav}% available"; else ok "memory: ${memav}% available"; fi
free -h | sed 's/^/       /'
swapinfo=$(free | awk '/^Swap:/ {if ($2==0) print "no swap"; else printf "swap %d%% used of %d MiB", $3*100/$2, $2/1024}')
info "$swapinfo"
dfroot=$(df -P / | awk 'NR==2 {print $5}' | tr -d %)
if ((dfroot >= 90)); then fail "disk / ${dfroot}% full"; elif ((dfroot >= 80)); then warn "disk / ${dfroot}% full"; else ok "disk / ${dfroot}% full"; fi
inodes=$(df -iP / | awk 'NR==2 {print $5}' | tr -d %)
if [[ "$inodes" =~ ^[0-9]+$ ]]; then ((inodes >= 80)) && warn "inodes / ${inodes}% used" || ok "inodes / ${inodes}% used"; else info "inodes / not reported ($inodes)"; fi
df -hP / 2>/dev/null | sed 's/^/       /'
if [ -f /var/run/reboot-required ]; then warn "reboot required: $(tr '\n' ' ' </var/run/reboot-required.pkgs 2>/dev/null)"; else ok "no reboot required"; fi
if has systemctl; then
  failed=$(systemctl --failed --no-legend --no-pager 2>/dev/null)
  if [ -n "$failed" ]; then fail "failed systemd units: $(echo "$failed" | awk '{print $1}' | tr '\n' ' ')"; else ok "no failed systemd units"; fi
fi
if has timedatectl; then
  ntp=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
  [ "$ntp" = yes ] && ok "clock NTP-synchronized" || warn "clock not NTP-synchronized ($ntp)"
fi
if has apt-get; then
  # what would really install: apt-get -s leaves out phased updates, which unattended-upgrades
  # defers on purpose. Pending is normal between the list refresh (apt-daily) and the next
  # install run (apt-daily-upgrade); it is stuck only if an install run has happened since the
  # lists were last refreshed and left the packages there
  pend=$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst ')
  auto=$(apt-config dump APT::Periodic::Unattended-Upgrade 2>/dev/null | grep -oE '"[0-9]+"' | tr -d '"')
  next=$(systemctl show apt-daily-upgrade.timer -p NextElapseUSecRealtime --value 2>/dev/null)
  nexts=$(date -d "$next" +%s 2>/dev/null)
  if ((pend == 0)); then ok "apt: nothing upgradable"
  elif [ "${auto:-0}" = 0 ] || [ -z "$nexts" ]; then warn "$pend apt packages upgradable and unattended-upgrades is off"
  elif [ "$APT_STAMPS/upgrade-stamp" -nt "$APT_STAMPS/update-success-stamp" ]; then
    warn "$pend apt packages upgradable that the last unattended run ($(hum "$(age "$APT_STAMPS/upgrade-stamp")") ago) left in place: held, not from an allowed origin, or the run failed (see /var/log/unattended-upgrades/)"
  else ok "apt: $pend packages upgradable, unattended-upgrades installs them at $next (in $(hum $((nexts - $(date +%s)))))"; fi
fi
if has journalctl; then
  klog=$(journalctl -k --no-pager --since=-24h 2>&1)
  if grep -qiE 'not seeing messages|insufficient permissions|No journal files' <<<"$klog"; then
    if [ "$(id -u)" = 0 ]; then warn "kernel log not readable even as root (no journal?) — OOM kills invisible"
    else warn "kernel log not readable as $(id -un) (needs the adm group, or run with sudo) — OOM kills invisible"; fi
  else
    ooms=$(grep -ciE 'out of memory|oom-kill|oom_reaper' <<<"$klog")
    ((ooms > 0)) && fail "kernel log: $ooms OOM lines in 24h" || ok "kernel log: no OOM kills in 24h"
  fi
fi
if has ss; then
  for p in 80 443; do ss -ltnH "sport = :$p" 2>/dev/null | grep -q . && ok "port $p listening" || fail "port $p NOT listening"; done
  sd=$(ss -ltnH 'sport = :8000' 2>/dev/null | awk '{print $4}' | sort -u | tr '\n' ' ')
  if [ -z "$sd" ]; then warn "port 8000 (showdown tunnel door) not listening"
  elif grep -qE '(0\.0\.0\.0|\*|\[::\]):8000' <<<"$sd"; then fail "port 8000 bound publicly ($sd) — should be 127.0.0.1 only"
  else ok "port 8000 bound to $sd"; fi
fi
info "top by memory:"
ps -eo pid,user,pcpu,pmem,rss,etimes,comm --sort=-rss 2>/dev/null | head -6 | sed 's/^/       /'

# ---------------------------------------------------------------- docker ----
hdr "Docker"
DOCKER_OK=0
if ! has docker; then fail "docker not installed / not in PATH"
elif ! timeout 30 docker info >/dev/null 2>&1; then fail "docker daemon unreachable or not answering within 30s (is $(id -un) in the docker group?)"
else
  DOCKER_OK=1
  ok "docker $(dk info -f '{{.ServerVersion}}') · $(dk info -f '{{.ContainersRunning}}/{{.Containers}}') containers running · root $(dk info -f '{{.DockerRootDir}}')"
  droot=$(dk info -f '{{.DockerRootDir}}')
  dfd=$(df -P "$droot" 2>/dev/null | awk 'NR==2 {print $5}' | tr -d %)
  if [ -n "$dfd" ]; then ((dfd >= 85)) && warn "disk under $droot ${dfd}% full" || ok "disk under $droot ${dfd}% full"; fi
  dk system df 2>/dev/null | sed 's/^/       /'
  echo
  ( cd "$D" 2>/dev/null && dk compose ps -a 2>/dev/null ) | sed 's/^/       /'
  echo
  for svc in caddy app postgres app-tournament postgres-tournament housie showdown arena; do
    cid=$(cid_of "$svc")
    if [ -z "$cid" ]; then fail "$svc: no container in compose project '$PROJECT'"; continue; fi
    read -r name st health rc oom started <<<"$(dk inspect -f '{{.Name}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}} {{.RestartCount}} {{.State.OOMKilled}} {{.State.StartedAt}}' "$cid" 2>/dev/null)"
    name=${name#/}; up=$(( $(date +%s) - $(date -d "$started" +%s 2>/dev/null || echo 0) ))
    msg="$svc ($name) $st/$health · up $(hum $up) · restarts=$rc"
    if [ "$st" != running ]; then fail "$msg"
    elif [ "$health" = unhealthy ]; then fail "$msg"
    elif [ "$health" = starting ]; then warn "$msg"
    elif [ "$oom" = true ]; then warn "$msg · OOM-killed"
    elif ((rc > 0)); then warn "$msg"
    elif ((up < 600)); then ok "$msg · started <10 min ago (a deploy just landed?)"
    else ok "$msg"; fi
  done
  echo
  info "live usage:"
  dk stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}' 2>/dev/null | sed 's/^/       /'
  echo
  info "error-ish log lines per container, last 24h (informational; TM/postgres log some by design):"
  for c in $(dk ps -a --filter "label=com.docker.compose.project=$PROJECT" --format '{{.Names}}' 2>/dev/null | sort); do
    lines=$(dk logs --since 24h "$c" 2>&1 | grep -iE '\b(error|exception|fatal|panic)\b')
    n=$(grep -c . <<<"$lines")
    printf '       %-30s %s\n' "$c" "$n"
    [ "$n" -gt 0 ] && tail -2 <<<"$lines" | cut -c1-200 | sed 's/^/         │ /'
  done
fi

# -------------------------------------------------------------- endpoints ----
hdr "Endpoints (public, through Caddy + TLS)"
[ -f "$ENVF" ] || fail "$ENVF missing — domains unknown, endpoint checks will be skipped"
DOMAIN=$(envv DOMAIN); TDOMAIN=$(envv TOURNAMENT_DOMAIN)
HDOMAIN=$(envv HOUSIE_DOMAIN); HDOMAIN=${HDOMAIN:-housie.localhost}
ADOMAIN=$(envv ARENA_DOMAIN); ADOMAIN=${ADOMAIN:-pokemon.zerko.it}
TMPB=$(mktemp); trap 'rm -f "$TMPB"' EXIT
probe(){ # label url expected-body-regex
  local out err code t ip
  : >"$TMPB"
  out=$(curl -sS --max-time 20 -o "$TMPB" -w '\n%{http_code} %{time_total} %{remote_ip}' "$2" 2>&1)
  read -r code t ip <<<"$(tail -1 <<<"$out")"; err=$(head -n -1 <<<"$out" | tr '\n' ' ')
  if [ "$code" = 200 ] && grep -qiE "$3" "$TMPB"; then ok "$1  $2 → 200 in ${t}s ($ip)"; return 0
  elif [ "$code" = 200 ]; then fail "$1  $2 → 200 but body lacks /$3/"; return 1
  else fail "$1  $2 → ${code:-000} $err$(tr -d '\n' <"$TMPB" | cut -c1-120)"; return 1; fi
}
redirect(){ local c; c=$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' "http://$1/" 2>/dev/null); [[ "$c" =~ ^30[1278]$ ]] && ok "http://$1 → $c redirect to https" || warn "http://$1 → ${c:-000} (expected 308 redirect)"; }
if [ -n "$DOMAIN" ]; then probe "main game  " "https://$DOMAIN/" '<html'; redirect "$DOMAIN"; fi
if [ -n "$TDOMAIN" ]; then probe "tournament " "https://$TDOMAIN/" '<html'; redirect "$TDOMAIN"; fi
if probe "housie     " "https://$HDOMAIN/health" '"status" *: *"ok"'; then
  HOUSIE_HEALTH=$(cat "$TMPB"); info "housie /health: $HOUSIE_HEALTH"
fi
probe "showdown   " "https://$ADOMAIN/showdown/info" 'websocket'
probe "showdown   " "http://127.0.0.1:8000/showdown/info" 'websocket'
rm -f "$TMPB"
echo
if has openssl; then
  for d in $DOMAIN $TDOMAIN $HDOMAIN $ADOMAIN; do
    [ "$d" = housie.localhost ] && continue
    dates=$(echo | timeout 15 openssl s_client -servername "$d" -connect "$d:443" 2>/dev/null | openssl x509 -noout -dates 2>/dev/null)
    nb=$(sed -n 's/^notBefore=//p' <<<"$dates"); na=$(sed -n 's/^notAfter=//p' <<<"$dates")
    if [ -z "$na" ]; then fail "TLS $d: could not read certificate"; continue; fi
    now=$(date +%s); nbs=$(date -d "$nb" +%s); nas=$(date -d "$na" +%s)
    life=$(( (nas - nbs) / 86400 )); left=$(( (nas - now) / 86400 ))
    # Caddy renews once a third of the lifetime is left; still unrenewed 3 days past that = renewal failing
    floor=3; slack=3; if ((life < 10)); then floor=1; slack=0; fi   # a 6-day cert is renewed at 2 days left
    if ((left < floor)); then fail "TLS $d expires in ${left}d ($na)"
    elif ((left < life / 3 - slack)); then warn "TLS $d expires in ${left}d of ${life}d — Caddy should have renewed by now (check caddy logs)"
    else ok "TLS $d expires in ${left}d (${life}d cert, $na)"; fi
  done
fi

# ------------------------------------------------------------ auto-update ----
hdr "Auto-update (cron every minute → update.sh)"
cronl=$(cronlist 2>/dev/null)
n=$(grep -cE '^[^#].*tm-deploy/(update|backup|housie-backup)\.sh' <<<"$cronl")
((n >= 3)) && ok "crontab has $n tm-deploy entries" || fail "crontab has $n of 3 expected tm-deploy entries"
grep -E 'tm-deploy' <<<"$cronl" | sed 's/^/       /'
if [ -e /tmp/tm-deploy-update.lock ]; then
  a=$(age /tmp/tm-deploy-update.lock)
  ((a < 180)) && ok "update.sh last started $(hum $a) ago" || fail "update.sh last started $(hum $a) ago — cron not running?"
else fail "no /tmp/tm-deploy-update.lock — update.sh has never run since boot"; fi
upid=$(pgrep -of '^(/usr)?(/bin/)?(ba)?sh (-c )?.*tm-deploy/update\.sh' 2>/dev/null)   # the script or cron's sh -c, not an editor on it
if [ -n "$upid" ]; then
  et=$(ps -o etimes= -p "$upid" 2>/dev/null | tr -d ' ')
  ((et > 900)) && warn "update.sh running for $(hum "${et:-0}") (pid $upid) — stuck build?" || info "update.sh currently running ($(hum "${et:-0}"), pid $upid)"
fi
if [ -f "$OWNER_HOME/tm-update.log" ]; then
  # update.sh stamps its own lines "YYYY-MM-DD HH:MM:SS UTC" but only for a reset, a merge, a fetch
  # error or a base-image change; docker's output carries no stamp. A quiet minute writes nothing,
  # so a line count is not a time window: one transient fetch error would stay a WARN for months.
  # Unstamped lines are attributed to the stamped line before them, except the block after the
  # LAST stamp, which is as new as the file's mtime: a failed weekly-fallback rebuild or a compose
  # pull/up failing every minute writes exactly that block and no stamp at all.
  since=$(date -u -d '3 days ago' '+%Y-%m-%d %H:%M:%S')
  tailok=$(( $(age "$OWNER_HOME/tm-update.log") < 259200 ))
  recent=$(awk -v since="$since" -v tailok="$tailok" '
    /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9] UTC/ { keep = (substr($0, 1, 19) >= since); n = 0; if (keep) print; next }
    { if (keep) print; else buf[++n] = $0 }
    END { if (!keep && tailok) for (i = 1; i <= n; i++) print buf[i] }' "$OWNER_HOME/tm-update.log")
  errlines=$(grep -E 'ERROR|failed to solve|Error response' <<<"$recent"); errs=$(grep -c . <<<"$errlines")
  ((errs > 0)) && warn "$errs ERROR lines in ~/tm-update.log in the last 3 days" || ok "no ERROR in ~/tm-update.log in the last 3 days"
  info "~/tm-update.log ($(du -h "$OWNER_HOME/tm-update.log" | cut -f1)), last 12 lines:"
  tail -n 12 "$OWNER_HOME/tm-update.log" | cut -c1-200 | sed 's/^/         │ /'
  ((errs > 0)) && { info "last ERROR lines:"; tail -3 <<<"$errlines" | cut -c1-200 | sed 's/^/         │ /'; }
else warn "~/tm-update.log missing"; fi
echo
for s in app app-tournament housie arena showdown; do
  m=/tmp/tm-last-build-$s
  [ -f "$m" ] && info "$s last image build $(hum "$(age "$m")") ago" || warn "$s: no build marker $m (rebuild pending or /tmp cleared by a reboot)"
done
echo
chk(){ # dir branch [upstream]
  local d=$1 b=$2 up=$3 head rem dirty last msg
  d=$(CDPATH='' cd -- "$d" 2>/dev/null && pwd) || { fail "$(basename "$1"): no directory at $1"; return; }
  [ -d "$d/.git" ] || { fail "$(basename "$d"): no git checkout at $d"; return; }
  head=$(gitc -C "$d" rev-parse --short HEAD 2>/dev/null)
  rem=$(gitc -C "$d" rev-parse --short "origin/$b" 2>/dev/null)
  dirty=$(gitc -C "$d" status --porcelain --untracked-files=no 2>/dev/null | wc -l)
  last=$(gitc -C "$d" log -1 --format='%cd %s' --date=format:'%Y-%m-%d %H:%M' 2>/dev/null | cut -c1-90)
  msg="$(basename "$d") @ $head · origin/$b $rem · $last"
  if [ -z "$rem" ]; then warn "$msg · no origin/$b ref (never fetched? wrong *_BRANCH override?)"
  elif ! gitc -C "$d" merge-base --is-ancestor "origin/$b" HEAD 2>/dev/null; then warn "$msg · BEHIND origin/$b (cron should have reset it)"
  elif ((dirty > 0)); then warn "$msg · $dirty locally modified tracked files (not what git has)"
  else ok "$msg"; fi
  if [ -n "$up" ] && gitc -C "$d" rev-parse -q --verify upstream/main >/dev/null 2>&1; then
    gitc -C "$d" merge-base --is-ancestor upstream/main HEAD 2>/dev/null || warn "$(basename "$d"): upstream/main not merged in (merge conflict? see ~/tm-update.log)"
  fi
}
chk "$D" "$DEPLOY_BRANCH"
chk "$MAIN_CHECKOUT" "$MAIN_BRANCH" yes
chk "$TOURNAMENT_CHECKOUT" "$TOURNAMENT_BRANCH" yes
chk "$HOUSIE_CHECKOUT" "$HOUSIE_BRANCH"
chk "$POKEBOT_CHECKOUT" "$POKEBOT_BRANCH"
if ((DOCKER_OK)); then
  # running image vs checkout HEAD. A fully cached rebuild keeps the OLD image timestamp, so a
  # docs-only commit legitimately leaves HEAD newer than the image: informational, not a warning.
  # A real build failure shows up as ERROR/failed-to-solve in ~/tm-update.log above.
  for pair in "app:$MAIN_CHECKOUT" "app-tournament:$TOURNAMENT_CHECKOUT" "housie:$HOUSIE_CHECKOUT" "arena:$POKEBOT_CHECKOUT"; do
    svc=${pair%%:*}; dir=${pair#*:}
    cid=$(cid_of "$svc"); [ -n "$cid" ] && [ -d "$dir/.git" ] || continue
    img=$(dk inspect -f '{{.Image}}' "$cid" 2>/dev/null)
    created=$(dk inspect -f '{{.Created}}' "$img" 2>/dev/null)
    cts=$(date -d "$created" +%s 2>/dev/null); hts=$(gitc -C "$dir" log -1 --format=%ct 2>/dev/null)
    [ -n "$cts" ] && [ -n "$hts" ] || continue
    if ((hts > cts)); then info "$svc: image built $(hum $(( $(date +%s) - cts ))) ago, checkout HEAD committed $(hum $(( $(date +%s) - hts ))) ago — fine if that commit touched no built files, otherwise the build failed (see log errors above)"
    else ok "$svc: running image built $(hum $(( $(date +%s) - cts ))) ago, after the checkout's HEAD commit"; fi
  done
fi

# -------------------------------------------------------------- databases ----
hdr "Databases"
if ((DOCKER_OK)); then
  pgcheck(){ # label service user db
    local cid; cid=$(cid_of "$2")
    [ -n "$cid" ] || { fail "$1: no $2 container"; return; }
    if dk exec "$cid" pg_isready -q -U "$3" -d "$4" 2>/dev/null; then
      local size games lastsave
      size=$(dk exec "$cid" psql -U "$3" -d "$4" -tAc "select pg_size_pretty(pg_database_size(current_database()))" 2>/dev/null)
      games=$(dk exec "$cid" psql -U "$3" -d "$4" -tAc "select string_agg(status||'='||n, ', ') from (select status, count(*) n from game group by status order by n desc) s" 2>/dev/null)
      lastsave=$(dk exec "$cid" psql -U "$3" -d "$4" -tAc "select coalesce(extract(epoch from now()-max(created_time))::int, -1) from games" 2>/dev/null)
      if [ "${lastsave:--1}" -ge 0 ] 2>/dev/null; then lastsave="$(hum "$lastsave") ago"; else lastsave=never; fi
      ok "$1 postgres ready · db ${size:-?} · games: ${games:-none} · last save $lastsave"
    else fail "$1 postgres ($2) not ready"; fi
  }
  pgcheck "main      " postgres "$(envv POSTGRES_USER)" "$(envv POSTGRES_DB)"
  pgcheck "tournament" postgres-tournament "$(envv TOURNAMENT_POSTGRES_USER)" "$(envv TOURNAMENT_POSTGRES_DB)"
  hc=$(cid_of housie)
  if [ -n "$hc" ]; then
    info "housie /data: $(dk exec "$hc" sh -c 'du -sh /data /data/attachments /data/backups 2>/dev/null | tr "\n" " "' 2>/dev/null)"
    info "housie in-container backups (newest first): $(dk exec "$hc" sh -c 'ls -1t /data/backups 2>/dev/null | head -3 | tr "\n" " "' 2>/dev/null)"
  fi
else info "skipped (no docker)"; fi

# ---------------------------------------------------------------- backups ----
hdr "Backups"
bdir=$BACKUP_DIR
if [ -d "$bdir" ]; then
  for inst in main tournament; do
    newest=$(ls -t "$bdir"/$inst-*.sql.gz 2>/dev/null | head -1)
    if [ -z "$newest" ]; then fail "no $inst-*.sql.gz dumps in $bdir"; continue; fi
    a=$(age "$newest"); sz=$(stat -c %s "$newest")
    if ((a > 93600)); then fail "$inst dump: newest is $(hum $a) old ($(basename "$newest"))"
    elif ((sz < 1024)); then fail "$inst dump: $(basename "$newest") is only ${sz} bytes — pg_dump failed?"
    else ok "$inst dump: $(basename "$newest") $(hum $a) ago, $(numfmt --to=iec "$sz" 2>/dev/null || echo "${sz}B")"; fi
  done
  info "$bdir: $(ls "$bdir"/*.sql.gz 2>/dev/null | wc -l) dumps, $(du -sh "$bdir" 2>/dev/null | cut -f1) total (retention 14d)"
else fail "$bdir missing — backup.sh has never run?"; fi
if [ -f "$OWNER_HOME/tm-backup.log" ]; then
  n=$(grep -c . "$OWNER_HOME/tm-backup.log"); la=$(age "$OWNER_HOME/tm-backup.log")
  if ((n > 0 && la < 259200)); then warn "~/tm-backup.log written $(hum "$la") ago, $n lines (pg_dump only writes there on errors); last 3:"; tail -3 "$OWNER_HOME/tm-backup.log" | cut -c1-200 | sed 's/^/         │ /'
  elif ((n > 0)); then info "~/tm-backup.log has $n old lines, last written $(hum "$la") ago (truncate it to clear)"
  else ok "~/tm-backup.log empty (no pg_dump errors)"; fi
fi
echo
hb=$BACKUP_REPO
if [ -d "$hb/.git" ]; then
  lastc=$(gitc -C "$hb" log -1 --format=%ct 2>/dev/null); a=$(( $(date +%s) - ${lastc:-0} ))
  subj=$(gitc -C "$hb" log -1 --format=%s 2>/dev/null)
  ((a > 93600)) && fail "housie-backups: last commit $(hum $a) ago ($subj)" || ok "housie-backups: last commit $(hum $a) ago ($subj)"
  unp=$(gitc -C "$hb" rev-list --count origin/main..HEAD 2>/dev/null); dirty=$(gitc -C "$hb" status --porcelain 2>/dev/null | wc -l)
  if [ -z "$unp" ]; then warn "housie-backups: no origin/main ref — cannot tell whether it is pushed"
  elif ((unp > 0)); then fail "housie-backups: $unp commit(s) not pushed to GitHub"
  else ok "housie-backups: everything pushed"; fi
  ((dirty > 0)) && warn "housie-backups: $dirty uncommitted files (harvest commit failed?)"
  att=$(du -sh "$hb/attachments" 2>/dev/null | cut -f1); dbsz=$(stat -c %s "$hb/housie.db" 2>/dev/null | numfmt --to=iec 2>/dev/null)
  info "housie-backups: ${att:-0} attachments (move to restic/B2 near ~2 GB), housie.db ${dbsz:-missing}"
else fail "$hb is not a git clone"; fi
if [ -f "$OWNER_HOME/housie-backup.log" ]; then
  last=$(tail -1 "$OWNER_HOME/housie-backup.log")
  grep -qE 'ERROR|WARNING' <<<"$(tail -3 "$OWNER_HOME/housie-backup.log")" && warn "~/housie-backup.log recent: $last" || info "~/housie-backup.log last: $last"
fi
if [ -n "$HOUSIE_HEALTH" ]; then
  lb=$(grep -oE '"lastBackupAt" *: *("[^"]*"|null)' <<<"$HOUSIE_HEALTH" | sed -E 's/^"lastBackupAt" *: *//; s/"//g')
  if [ "$lb" = null ] || [ -z "$lb" ]; then info "housie lastBackupAt=null — normal until the first 03:20 after a container restart"
  else
    a=$(( $(date +%s) - $(date -d "$lb" +%s 2>/dev/null || echo 0) ))
    ((a > 93600)) && warn "housie in-app backup last ran $(hum $a) ago ($lb)" || ok "housie in-app backup last ran $(hum $a) ago ($lb)"
  fi
fi

# ------------------------------------------------------------------ arena ----
hdr "Arena (Platinum on Showdown)"
if ((DOCKER_OK)) && [ -n "$(cid_of arena)" ]; then
  alog=$(dk logs arena 2>&1)
  start=$(grep 'accepting challenges' <<<"$alog" | tail -1)
  [ -n "$start" ] && ok "$(cut -c1-160 <<<"$start")" || warn "arena has not logged its 'accepting challenges' startup line"
  g24=$(dk logs --since 24h arena 2>&1 | grep -cE ' vs .*: (won|lost|tie) in [0-9]+ turns')
  gall=$(grep -cE ' vs .*: (won|lost|tie) in [0-9]+ turns' <<<"$alog")
  info "games finished: $g24 in the last 24h, $gall in the current log"
  info "last 4 arena log lines:"; tail -4 <<<"$alog" | cut -c1-200 | sed 's/^/         │ /'
  info "last 3 showdown log lines:"; dk logs --tail 3 showdown 2>&1 | cut -c1-200 | sed 's/^/         │ /'
else info "skipped (no docker / no arena container)"; fi

# ------------------------------------------------------------------ caddy ----
hdr "Caddy"
cc=$( ((DOCKER_OK)) && cid_of caddy )
if [ -n "$cc" ]; then
  cerr=$(dk logs --since 24h "$cc" 2>&1 | grep '"level":"error"')
  n=$(grep -c . <<<"$cerr"); tls=$(grep -ciE '"logger":"tls|acme|certificate' <<<"$cerr")
  if ((tls > 0)); then fail "caddy: $tls TLS/ACME error lines in 24h ($n errors total)"
  elif ((n > 20)); then warn "caddy: $n error lines in 24h"
  else ok "caddy: $n error lines in 24h, none about TLS"; fi
  ((n > 0)) && tail -3 <<<"$cerr" | cut -c1-220 | sed 's/^/         │ /'
else info "skipped (no docker / no caddy container)"; fi

# ---------------------------------------------------------------- summary ----
hdr "Summary"
if ((${#FAILS[@]} == 0 && ${#WARNS[@]} == 0)); then echo "  ${G}all green${N}"; fi
for w in "${WARNS[@]}"; do echo "  ${Y}WARN${N} $w"; done
for f in "${FAILS[@]}"; do echo "  ${R}FAIL${N} $f"; done
echo "  ${#FAILS[@]} fail · ${#WARNS[@]} warn"
((${#FAILS[@]} == 0))
