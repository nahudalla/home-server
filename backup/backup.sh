#!/usr/bin/env bash
# Home-server config backup orchestrator.
#
# Runs each service backup module (backup/services/*.sh), then commits and
# pushes any changes under backups/ to GitHub. Designed to be invoked by the
# systemd --user timer, but is safe to run by hand.
#
# Usage:
#   backup.sh [options] [service ...]
#
# Options:
#   --dry-run    Export config and show the diff, but do not commit or push.
#   --no-push    Commit locally but do not push to origin.
#   -h, --help   Show this help.
#
# With no service names, every module in backup/services/ runs. Otherwise only
# the named modules run (e.g. `backup.sh npm`).
#
# Environment overrides: DRY_RUN=1, NO_PUSH=1 (same as the flags).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'; }

services=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --no-push) NO_PUSH=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *)  services+=("$1") ;;
  esac
  shift
done

require_cmd git jq curl
load_env

# Default to every module in services/ when none were named.
if [ "${#services[@]}" -eq 0 ]; then
  for f in "$SERVICES_DIR"/*.sh; do
    [ -e "$f" ] || die "no backup modules found in $SERVICES_DIR"
    services+=("$(basename "$f" .sh)")
  done
fi

# Sync before writing anything (only when we intend to push), so the later push
# can't be rejected as non-fast-forward. Skipped for --dry-run / --no-push.
if [ "${DRY_RUN:-0}" != "1" ] && [ "${NO_PUSH:-0}" != "1" ]; then
  sync_with_remote
fi

ran=()
for svc in "${services[@]}"; do
  module="$SERVICES_DIR/$svc.sh"
  [ -f "$module" ] || die "no such backup module: $svc ($module)"
  log "=== backing up: $svc ==="
  # Subshell isolates each module's SERVICE_NAME / helpers from the others.
  (
    # shellcheck source=/dev/null
    . "$module"
    [ "$(type -t backup)" = "function" ] || die "module $svc defines no backup()"
    backup
  )
  ran+=("$svc")
done

commit_and_push "backup: ${ran[*]} $(date +%Y-%m-%dT%H:%M)"
log "done."
