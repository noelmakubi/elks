#!/usr/bin/env bash
#
# Roll the stack back to the previous commit.
#
#   bash hosting/rollback.sh              # go back one commit and redeploy
#   bash hosting/rollback.sh <sha>        # deploy a specific commit
#   bash hosting/rollback.sh --config-only  # restore the previous .env and restart
#
# Rolls back code, not data. Database volumes are left alone on purpose: a
# schema migration run by the newer code is not undone by restoring old code.
# If a deploy included a destructive migration, restore from a pg_dump instead.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
COMPOSE_DIR="$REPO_ROOT/microservices"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

CONFIG_ONLY=0
TARGET=""
for arg in "$@"; do
  case "$arg" in
    --config-only) CONFIG_ONLY=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) TARGET="$arg" ;;
  esac
done

git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 \
  || die "not a git checkout; nothing to roll back to"

current=$(git -C "$REPO_ROOT" rev-parse --short HEAD)

########################################
# Restore the previous .env, if we have one
########################################
if [[ "$CONFIG_ONLY" -eq 1 ]]; then
  [[ -f "$COMPOSE_DIR/.env.previous" ]] || die "no $COMPOSE_DIR/.env.previous to restore"
  log "restoring the previous .env"
  cp -p "$COMPOSE_DIR/.env.previous" "$COMPOSE_DIR/.env"
  log "restarting with the restored configuration"
  exec "$REPO_ROOT/hosting/deploy.sh" --no-wait
fi

########################################
# Move the working tree
########################################
if [[ -n "$TARGET" ]]; then
  log "rolling back to $TARGET (currently $current)"
  git -C "$REPO_ROOT" rev-parse --verify "$TARGET^{commit}" >/dev/null 2>&1 \
    || die "$TARGET is not a commit in this repository"
else
  # HEAD~1, but never past the first commit.
  previous=$(git -C "$REPO_ROOT" rev-parse --verify HEAD~1 2>/dev/null) \
    || die "no parent commit to roll back to"
  TARGET="$previous"
  log "rolling back one commit: $current -> $(git -C "$REPO_ROOT" rev-parse --short "$previous")"
fi

# Refuse to roll back onto a detached HEAD without saying so; the next deploy
# should be able to move forward again.
git -C "$REPO_ROOT" checkout --quiet "$TARGET" \
  || die "git checkout failed; resolve the working tree by hand first"

log "deploying $(git -C "$REPO_ROOT" rev-parse --short HEAD)"
exec "$REPO_ROOT/hosting/deploy.sh"
