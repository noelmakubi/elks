#!/usr/bin/env bash
#
# Build and (re)deploy the elks stack on this host.
#
#   bash hosting/deploy.sh              # build images, recreate, health-check
#   bash hosting/deploy.sh --pull-only  # pull prebuilt images instead of building
#   bash hosting/deploy.sh --no-wait    # start and return without health checks
#
# This is what CI calls over SSH. It is safe to re-run: compose is declarative,
# so unchanged services are left alone.

set -Eeuo pipefail

########################################
# Locate the repo no matter where we are invoked from
########################################
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
COMPOSE_DIR="$REPO_ROOT/microservices"

readonly REPO_ROOT COMPOSE_DIR

# Two -f files: the shared dev compose plus the production overlay.
COMPOSE=(docker compose
  --project-name elks
  --env-file "$COMPOSE_DIR/.env"
  -f "$COMPOSE_DIR/docker-compose.yml"
  -f "$COMPOSE_DIR/docker-compose.prod.yml")

########################################
# Flags
########################################
PULL_ONLY=0
WAIT=1
for arg in "$@"; do
  case "$arg" in
    --pull-only) PULL_ONLY=1 ;;
    --no-wait)   WAIT=0 ;;
    -h|--help)   sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

########################################
# Logging helpers
########################################
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

trap 'die "deploy failed on line $LINENO"' ERR

########################################
# Preconditions
########################################
command -v docker >/dev/null || die "docker is not installed; run hosting/bootstrap.sh first"
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
docker info >/dev/null 2>&1 || die "cannot talk to the docker daemon (not in the docker group, or the daemon is down)"

[[ -f "$COMPOSE_DIR/.env" ]] \
  || die "missing $COMPOSE_DIR/.env. Copy .env.example and set the three DB passwords."

# Catch an unset required variable before compose fails with a wall of text.
# shellcheck disable=SC1091
set -a; . "$COMPOSE_DIR/.env"; set +a
for var in SERVICE_A_DB_PASSWORD SERVICE_B_DB_PASSWORD SERVICE_C_DB_PASSWORD; do
  val="${!var:-}"
  [[ -n "$val" ]] || die "$var is empty in .env"
  [[ "$val" != change_me* ]] \
    || die "$var still has its 'change_me_*' placeholder value; generate a real one"
done

readonly IMAGE_TAG="${IMAGE_TAG:-$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo local)}"
export IMAGE_TAG

# The services run as uid 1000 and write to bind-mounted log dirs. Make sure
# those exist and are writable or every service will crash-loop on startup.
log "preparing log directories"
for svc in service-a service-b service-c; do
  dir="$COMPOSE_DIR/$svc/logs"
  mkdir -p "$dir"
  # Only widen if needed; a correct owner is left alone.
  if [[ ! -w "$dir" ]]; then
    log "fixing ownership on $dir"
    sudo chown -R 1000:1000 "$dir"
    sudo chmod 0750 "$dir"
  fi
done

########################################
# Tag the commit being deployed
########################################
if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$REPO_ROOT" rev-parse HEAD > "$COMPOSE_DIR/.deployed-commit" 2>/dev/null || true
fi

########################################
# Back up the current configuration for rollback
########################################
if [[ -f "$COMPOSE_DIR/.env" && ! -f "$COMPOSE_DIR/.env.previous" ]]; then
  cp -p "$COMPOSE_DIR/.env" "$COMPOSE_DIR/.env.previous"
fi

########################################
# Build or pull
########################################
if [[ "$PULL_ONLY" -eq 1 ]]; then
  log "pulling images tagged $IMAGE_TAG"
  "${COMPOSE[@]}" pull --ignore-buildable
else
  log "building images (tag $IMAGE_TAG)"
  # BuildKit gives better layer caching and parallel output.
  export DOCKER_BUILDKIT=1
  "${COMPOSE[@]}" build --pull
fi

########################################
# Recreate
########################################
# --remove-orphans clears containers left behind by a renamed or deleted service.
# Without --no-deps, a dependency restart would cascade; that is what we want when
# a schema changed, but it also means a short window where a service is down.
log "recreating containers"
"${COMPOSE[@]}" up -d --remove-orphans

########################################
# Health checks
########################################
if [[ "$WAIT" -eq 0 ]]; then
  log "skipping health checks (--no-wait)"
  exit 0
fi

log "waiting for health checks (timeout ${HEALTH_TIMEOUT:-180}s)"
deadline=$(( SECONDS + ${HEALTH_TIMEOUT:-180} ))
all_healthy=0

while (( SECONDS < deadline )); do
  # `docker compose ps --format json` prints one JSON object per line on recent
  # versions, and an array on older ones. `jq -s` normalises either into a list.
  # A service with no healthcheck reports Health == "" and is not counted as
  # pending, so only services that actually declare one can block the deploy.
  pending=$("${COMPOSE[@]}" ps --format json 2>/dev/null \
    | jq -s '[.[] | select(.Health != "" and .Health != "healthy")] | length' 2>/dev/null \
    || echo 1)

  if [[ "$pending" == "0" ]]; then
    all_healthy=1
    break
  fi

  printf '\r  waiting on %s container(s)... %ss elapsed' "$pending" "$SECONDS"
  sleep 5
done
echo

if [[ "$all_healthy" -eq 1 ]]; then
  log "all containers report healthy"
else
  warn "not every container became healthy in time; current state:"
  "${COMPOSE[@]}" ps
  echo
  warn "recent logs from the unhealthy services:"
  for svc in ui service-a service-b service-c service-a-db service-b-db service-c-db; do
    id=$("${COMPOSE[@]}" ps -q "$svc" 2>/dev/null || true)
    [[ -n "$id" ]] || continue
    state=$(docker inspect -f '{{.State.Health.Status}}' "$id" 2>/dev/null || echo unknown)
    [[ "$state" == "healthy" ]] && continue
    echo "--- $svc ($state) ---"
    docker logs --tail 40 "$id" 2>&1 || true
  done
  die "deploy did not come up healthy. The previously running containers were left in place only if compose had already replaced them; check the output above."
fi

########################################
# End-to-end smoke test through the proxy
########################################
# Container health is necessary but not sufficient: confirm the dashboard and
# each API path are actually reachable through the internal nginx.
UI_PORT="${UI_PORT:-8080}"
log "smoke testing through the proxy on 127.0.0.1:$UI_PORT"

smoke() {
  local path="$1" expect="$2"
  local code
  code=$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:${UI_PORT}${path}" 2>/dev/null || echo 000)
  if [[ "$code" == "$expect" ]]; then
    log "  ok   $path -> $code"
  else
    warn "  FAIL $path -> $code (expected $expect)"
    return 1
  fi
}

rc=0
smoke "/healthz"                      "200" || rc=1
smoke "/api/service-a/health"         "200" || rc=1
smoke "/api/service-b/health"         "200" || rc=1
smoke "/api/service-c/health"         "200" || rc=1
# A database still initialising answers 200 with status "degraded", which is
# expected right after a cold start; the collections are the real test.
smoke "/api/service-a/users"          "200" || rc=1
smoke "/api/service-b/orders"         "200" || rc=1
smoke "/api/service-c/notifications"  "200" || rc=1

if [[ "$rc" -ne 0 ]]; then
  die "smoke test failed; the stack is up but not serving correctly"
fi

########################################
# Report
########################################
log "deploy complete"
"${COMPOSE[@]}" ps --format 'table {{.Name}}\t{{.Status}}\t{{.Ports}}'
echo
log "dashboard: http://127.0.0.1:${UI_PORT} (behind the host nginx on :80/:443)"
log "to follow logs:  cd $COMPOSE_DIR && docker compose -f docker-compose.yml -f docker-compose.prod.yml logs -f"
log "to roll back:    bash $REPO_ROOT/hosting/rollback.sh"
