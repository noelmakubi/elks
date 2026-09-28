#!/usr/bin/env bash
#
# Back up the three PostgreSQL databases and prune old dumps.
#
#   bash hosting/backup.sh              # dump, then prune anything older than 14 days
#   bash hosting/backup.sh --restore <service-a|service-b|service-c> <file.sql>
#
# The dump is a plain-text pg_dump of one database per service, taken from inside
# the running container, so no client tooling is needed on the host. Gzip'd.
#
# Suggested cron on the server (daily at 02:17, off the hour on purpose):
#   17 2 * * * /opt/elks/hosting/backup.sh >> /var/log/elks-backup.log 2>&1

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
COMPOSE_DIR="$REPO_ROOT/microservices"

BACKUP_DIR="${BACKUP_DIR:-/var/backups/elks}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

COMPOSE=(docker compose
  --project-name elks
  --env-file "$COMPOSE_DIR/.env"
  -f "$COMPOSE_DIR/docker-compose.yml"
  -f "$COMPOSE_DIR/docker-compose.prod.yml")

########################################
# Restore mode
########################################
if [[ "${1:-}" == "--restore" ]]; then
  svc="${2:-}"
  file="${3:-}"
  [[ -n "$svc" && -n "$file" ]] || die "usage: $0 --restore <service-a|service-b|service-c> <file.sql.gz>"
  [[ -f "$file" ]] || die "no such file: $file"

  case "$svc" in
    service-a) dbc=service-a-db; dbname_var=SERVICE_A_DB_NAME; user_var=SERVICE_A_DB_USER; pw_var=SERVICE_A_DB_PASSWORD ;;
    service-b) dbc=service-b-db; dbname_var=SERVICE_B_DB_NAME; dbuser_var=SERVICE_B_DB_USER; pw_var=SERVICE_B_DB_PASSWORD ;;
    service-c) dbc=service-c-db; dbname_var=SERVICE_C_DB_NAME; dbuser_var=SERVICE_C_DB_USER; pw_var=SERVICE_C_DB_PASSWORD ;;
    *) die "unknown service '$svc'" ;;
  esac

  # shellcheck disable=SC1091
  set -a; . "$COMPOSE_DIR/.env"; set +a
  dbname="${!dbname_var}"
  # Default the user var names to the conventional ones if not spelled above.
  dbuser_var="${dbuser_var:-SERVICE_${svc##service-}_DB_USER}"
  dbuser="${!dbuser_var}"
  dbpass="${!pw_var}"

  id=$("${COMPOSE[@]}" ps -q "$dbc")
  [[ -n "$id" ]] || die "container $dbc is not running"

  warn "about to overwrite the contents of database '$dbname' in $svc"
  read -r -p "  Type the database name to confirm: " confirm
  [[ "$confirm" == "$dbname" ]] || die "confirmation did not match; nothing was changed"

  log "restoring $file into $dbname"
  # Drop existing objects first so a restore into a populated database converges
  # instead of failing on duplicate rows. --clean is not available on psql when
  # the script arrives on stdin, so drop the schema by hand inside the same
  # transaction. One transaction means a failure leaves the database untouched
  # rather than half-restored.
  #
  # The dumps are pg_dump --format=custom, so they are restored with pg_restore,
  # not psql.
  gunzip -c "$file" | docker exec -i \
    -e PGPASSWORD="$dbpass" \
    "$id" pg_restore -U "$dbuser" -d "$dbname" \
      --clean --if-exists --no-owner --no-privileges \
      --single-transaction --exit-on-error
  log "restore complete; the application reconnects on its own"
  exit 0
fi

########################################
# Backup mode
########################################
command -v docker >/dev/null || die "docker is not installed"
[[ -f "$COMPOSE_DIR/.env" ]] || die "missing $COMPOSE_DIR/.env"

install -d -m 0750 "$BACKUP_DIR"
log "backing up to $BACKUP_DIR"

# timestamp on every file makes pruning by age a simple find -mtime.
stamp=$(date -u +%Y%m%dT%H%M%SZ)

dump() {
  local svc="$1" dbc="$2" name_var="$3" user_var="$4" pw_var="$5"
  local id out rc=0

  # shellcheck disable=SC1091
  set -a; . "$COMPOSE_DIR/.env"; set +a
  local dbname="${!name_var}" dbuser="${!user_var}" dbpass="${!pw_var}"

  id=$("${COMPOSE[@]}" ps -q "$dbc" 2>/dev/null || true)
  if [[ -z "$id" ]]; then
    warn "$svc: container $dbc is not running, skipping"
    return 1
  fi

  out="$BACKUP_DIR/${svc}-${stamp}.sql.gz"

  # pg_dump runs inside the container; gzip on the host. -Fc is the custom
  # archive format: it is smaller, and pg_restore can do a parallel restore.
  if docker exec -e PGPASSWORD="$dbpass" "$id" \
        pg_dump -U "$dbuser" -d "$dbname" --format=custom --no-owner --no-privileges \
     | gzip -9 > "$out"; then
    size=$(du -h "$out" | cut -f1)
    log "  $svc -> $(basename "$out") ($size)"
  else
    rc=1
    # Leave no truncated file behind that a later restore might pick up.
    rm -f "$out"
    warn "  $svc: pg_dump failed"
  fi
  return $rc
}

failed=0
dump service-a service-a-db SERVICE_A_DB_NAME SERVICE_A_DB_USER SERVICE_A_DB_PASSWORD || failed=1
dump service-b service-b-db SERVICE_B_DB_NAME SERVICE_B_DB_USER SERVICE_B_DB_PASSWORD || failed=1
dump service-c service-c-db SERVICE_C_DB_NAME SERVICE_C_DB_USER SERVICE_C_DB_PASSWORD || failed=1

########################################
# Prune
########################################
log "pruning dumps older than ${RETENTION_DAYS} days"
find "$BACKUP_DIR" -maxdepth 1 -name '*.sql.gz' -type f -mtime "+$RETENTION_DAYS" -print -delete

log "current dumps:"
ls -lh "$BACKUP_DIR" 2>/dev/null || true

if [[ "$failed" -ne 0 ]]; then
  die "one or more backups failed; do not rely on this run"
fi
log "backup complete"
