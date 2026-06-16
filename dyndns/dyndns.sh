#!/usr/bin/env bash
# Dynamic DNS updater for GCP Cloud DNS.
#
# Keeps a single IPv4 A record pointed at this host's current public IP. Driven
# by a systemd --user timer (systemd/home-server-dyndns.*), but safe to run by
# hand. Idempotent: it only calls Cloud DNS when the public IP actually changed.
#
# Non-secret config lives in dyndns.conf next to this script. The ONLY secret is
# the service-account key FILE referenced by DYNDNS_SA_KEY_FILE, kept on the host
# outside this repo and never committed.
#
# Usage:
#   dyndns.sh            create/update the record if the public IP changed
#   dyndns.sh --dry-run  detect + report the intended change, write nothing
#   dyndns.sh -h|--help  show this help
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- logging (self-contained; intentionally NOT shared with backup/lib, which
# --- is coupled to git/commit/push logic) ------------------------------------
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { printf '[%s] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }
require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
}

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'; }

# --- args --------------------------------------------------------------------
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

# --- config ------------------------------------------------------------------
CONF="$HERE/dyndns.conf"
[ -f "$CONF" ] || die "config not found: $CONF"
# shellcheck source=/dev/null
. "$CONF"

: "${DYNDNS_PROJECT:?set DYNDNS_PROJECT in dyndns.conf}"
: "${DYNDNS_ZONE:?set DYNDNS_ZONE (managed-zone name) in dyndns.conf}"
: "${DYNDNS_RECORD:?set DYNDNS_RECORD in dyndns.conf}"
: "${DYNDNS_TTL:=300}"
: "${DYNDNS_SA_KEY_FILE:?set DYNDNS_SA_KEY_FILE in dyndns.conf}"
[ -f "$DYNDNS_SA_KEY_FILE" ] || die "SA key file not found: $DYNDNS_SA_KEY_FILE"

require_cmd gcloud curl flock

# --- isolated gcloud state + single-run lock ---------------------------------
# Keep the SA credentials out of the operator's default gcloud config.
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/home-server-dyndns"
mkdir -p "$STATE_DIR"
export CLOUDSDK_CONFIG="$STATE_DIR/gcloud"

# Serialize timer firings; bail quietly if another run already holds the lock.
exec 9>"$STATE_DIR/lock"
flock -n 9 || { log "another run is in progress — skipping"; exit 0; }

# --- detect current public IPv4 ----------------------------------------------
is_ipv4() {
  local ip="$1" o IFS=.
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  for o in $ip; do [ "$((10#$o))" -le 255 ] || return 1; done
  return 0
}

public_ip() {
  local ip svc
  for svc in https://api.ipify.org https://checkip.amazonaws.com; do
    ip="$(curl -fsS --max-time 10 "$svc" 2>/dev/null | tr -d '[:space:]')" || continue
    if is_ipv4 "$ip"; then printf '%s' "$ip"; return 0; fi
  done
  return 1
}

IP="$(public_ip)" || die "could not determine a valid public IPv4 address"
log "public IP: $IP"

# --- authenticate (service account, isolated config) -------------------------
gcloud auth activate-service-account --key-file="$DYNDNS_SA_KEY_FILE" --quiet \
  >/dev/null 2>&1 || die "gcloud failed to activate the service account"

# --- read current record value -----------------------------------------------
current="$(gcloud dns record-sets list \
  --project="$DYNDNS_PROJECT" --zone="$DYNDNS_ZONE" \
  --name="$DYNDNS_RECORD" --type=A \
  --format='value(rrdatas[0])' 2>/dev/null || true)"

if [ "$current" = "$IP" ]; then
  log "unchanged ($IP) — nothing to do"
  exit 0
fi

if [ -z "$current" ]; then
  action="create"; log "no existing A record — will create $DYNDNS_RECORD -> $IP"
else
  action="update"; log "A record changed: $current -> $IP"
fi

if [ "$DRY_RUN" = "1" ]; then
  log "DRY_RUN=1 — would $action $DYNDNS_RECORD A $IP (ttl $DYNDNS_TTL); no change made"
  exit 0
fi

# create and update take the same flags; both replace the record's rrdatas.
gcloud dns record-sets "$action" "$DYNDNS_RECORD" \
  --project="$DYNDNS_PROJECT" --zone="$DYNDNS_ZONE" \
  --type=A --ttl="$DYNDNS_TTL" --rrdatas="$IP" --quiet \
  || die "gcloud failed to $action the record"

log "${action}d $DYNDNS_RECORD -> $IP (ttl $DYNDNS_TTL)"
