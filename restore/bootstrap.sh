#!/usr/bin/env bash
# Guided fresh-machine setup for the home server.
#
# Brings up the Docker services from compose/, then walks you through restoring
# Nginx Proxy Manager's configuration from the plaintext backups in backups/npm/.
# The secret bits that backups intentionally skip (TLS certificates, DNS provider
# API tokens, basic-auth passwords) are recreated interactively in the NPM UI;
# this script then wires the saved proxy/redirection/stream/dead hosts back up to
# them automatically. Finally it installs the systemd --user backup timer.
#
# Safe to re-run: restore steps create objects, so re-running may create
# duplicates — review the NPM UI if you run it twice.
#
# Usage: restore/bootstrap.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$HERE" rev-parse --show-toplevel)"
COMPOSE_FILE="$REPO_ROOT/compose/docker-compose.yml"
NPM_BACKUP_DIR="$REPO_ROOT/backups/npm"
NPM_API_URL="${NPM_API_URL:-http://127.0.0.1:81/api}"

c_blue=$'\033[1;34m'; c_green=$'\033[1;32m'; c_yellow=$'\033[1;33m'; c_reset=$'\033[0m'
step()  { printf '\n%s==> %s%s\n' "$c_blue" "$*" "$c_reset"; }
ok()    { printf '%s  ✓ %s%s\n' "$c_green" "$*" "$c_reset"; }
note()  { printf '%s  ! %s%s\n' "$c_yellow" "$*" "$c_reset"; }
die()   { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
pause() { read -r -p "$* " _ </dev/tty; }
ask()   { local a; read -r -p "$1 " a </dev/tty; printf '%s' "$a"; }

# --- 1. preconditions --------------------------------------------------------
step "Checking prerequisites"
for c in docker git jq curl gh; do
  command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"
done
docker compose version >/dev/null 2>&1 || die "'docker compose' plugin not available"
gh auth status >/dev/null 2>&1 || die "gh is not logged in — run: gh auth login"
ok "all required tools present and gh is authenticated"

# --- 2. .env -----------------------------------------------------------------
step "Checking .env"
if [ ! -f "$REPO_ROOT/.env" ]; then
  note ".env not found — creating from .env.example"
  cp "$REPO_ROOT/.env.example" "$REPO_ROOT/.env"
  note "Edit $REPO_ROOT/.env and set MSSQL_SA_PASSWORD (NPM creds can wait)."
  pause "Press Enter once you've set MSSQL_SA_PASSWORD..."
fi
set -a; . "$REPO_ROOT/.env"; set +a
ok ".env loaded"

# --- 3. NPM bind-mount dirs --------------------------------------------------
step "Ensuring NPM data directories exist"
for d in /home/nahuel/npm/data /home/nahuel/npm/letsencrypt; do
  if [ ! -d "$d" ]; then mkdir -p "$d"; ok "created $d"; else ok "$d exists"; fi
done

# --- 4. bring up services ----------------------------------------------------
step "Starting Docker services"
docker compose -f "$COMPOSE_FILE" up -d
ok "compose stack is up"

# --- 5. wait for NPM API -----------------------------------------------------
step "Waiting for the NPM API to come up"
for _ in $(seq 1 60); do
  if curl -fsS -m 3 "$NPM_API_URL/" >/dev/null 2>&1; then ok "NPM API is reachable"; break; fi
  sleep 2
done
curl -fsS -m 3 "$NPM_API_URL/" >/dev/null 2>&1 || die "NPM API never became reachable at $NPM_API_URL"

# --- 6. admin account --------------------------------------------------------
step "NPM admin account"
cat <<EOF
NPM ships with a default admin (admin@example.com / changeme) that must be
changed on first login. Open the admin UI, log in, and set your real admin
email + password now:

    ${NPM_API_URL%/api}    (admin UI on port 81)
EOF
pause "Press Enter once you've set the NPM admin credentials..."
if [ -z "${NPM_API_IDENTITY:-}" ] || [ "${NPM_API_IDENTITY:-}" = "admin@example.com" ]; then
  NPM_API_IDENTITY="$(ask 'NPM admin email:')"
  NPM_API_SECRET="$(ask 'NPM admin password:')"
  # Persist for the backup job.
  sed -i "s|^NPM_API_IDENTITY=.*|NPM_API_IDENTITY=$NPM_API_IDENTITY|" "$REPO_ROOT/.env"
  sed -i "s|^NPM_API_SECRET=.*|NPM_API_SECRET=$NPM_API_SECRET|"     "$REPO_ROOT/.env"
  ok "saved NPM credentials to .env"
fi

api_token() {
  curl -fsS -m 15 -X POST "$NPM_API_URL/tokens" -H 'Content-Type: application/json' \
    --data "$(jq -n --arg i "$NPM_API_IDENTITY" --arg s "$NPM_API_SECRET" '{identity:$i,secret:$s}')" \
    | jq -r '.token // empty'
}
TOKEN="$(api_token)"; [ -n "$TOKEN" ] || die "could not authenticate to NPM — check the credentials"
api_get()  { curl -fsS -m 30 "$NPM_API_URL/$1" -H "Authorization: Bearer $TOKEN"; }
api_post() { curl -fsS -m 30 -X POST "$NPM_API_URL/$1" -H "Authorization: Bearer $TOKEN" \
             -H 'Content-Type: application/json' --data "$2"; }
ok "authenticated to NPM API"

# --- 7. recreate secret-bearing objects (interactive), then map old->new ids -
# Certificates and access lists carry secrets we never back up, so the user
# recreates them in the UI. We then match saved records to the freshly created
# ones by natural key to remap the *_id references on the hosts.
declare -A CERT_MAP ACL_MAP

if [ -s "$NPM_BACKUP_DIR/certificates.json" ] && [ "$(jq 'length' "$NPM_BACKUP_DIR/certificates.json")" -gt 0 ]; then
  step "Recreate TLS certificates"
  note "Backups store certificate METADATA only (no keys/tokens). Recreate these in the NPM UI:"
  jq -r '.[] | "  - \(.nice_name)  [\(.provider)]  \(.domain_names|join(", "))"' "$NPM_BACKUP_DIR/certificates.json"
  note "For Let's Encrypt DNS certs you will need to re-enter the DNS provider API token."
  pause "Press Enter once all certificates exist in NPM..."
  live_certs="$(api_get nginx/certificates)"
  while IFS= read -r row; do
    old_id="$(jq -r '.id' <<<"$row")"
    key="$(jq -c '.domain_names|sort' <<<"$row")"
    new_id="$(jq -r --argjson k "$key" 'map(select((.domain_names|sort)==$k)) | (.[0].id // empty)' <<<"$live_certs")"
    [ -n "$new_id" ] && CERT_MAP[$old_id]="$new_id" && ok "cert $old_id -> $new_id ($key)" \
                     || note "no live cert matched saved cert $old_id ($key) — its hosts will restore without SSL"
  done < <(jq -c '.[]' "$NPM_BACKUP_DIR/certificates.json")
fi

if [ -s "$NPM_BACKUP_DIR/access_lists.json" ] && [ "$(jq 'length' "$NPM_BACKUP_DIR/access_lists.json")" -gt 0 ]; then
  step "Recreate access lists"
  note "Access lists store usernames + IP rules but NOT passwords. Recreate these in the NPM UI:"
  jq -r '.[] | "  - \(.name)  (users: \([.items[]?.username]|join(", ")))"' "$NPM_BACKUP_DIR/access_lists.json"
  pause "Press Enter once all access lists exist in NPM..."
  live_acls="$(api_get nginx/access-lists)"
  while IFS= read -r row; do
    old_id="$(jq -r '.id' <<<"$row")"; name="$(jq -r '.name' <<<"$row")"
    new_id="$(jq -r --arg n "$name" 'map(select(.name==$n)) | (.[0].id // empty)' <<<"$live_acls")"
    [ -n "$new_id" ] && ACL_MAP[$old_id]="$new_id" && ok "access list $old_id -> $new_id ($name)" \
                     || note "no live access list matched '$name'"
  done < <(jq -c '.[]' "$NPM_BACKUP_DIR/access_lists.json")
fi

# --- 8. restore hosts (automated, with id remapping) -------------------------
cert_map_json="{}"; for k in "${!CERT_MAP[@]}"; do cert_map_json="$(jq --arg k "$k" --arg v "${CERT_MAP[$k]}" '.[$k]=$v' <<<"$cert_map_json")"; done
acl_map_json="{}";  for k in "${!ACL_MAP[@]}";  do acl_map_json="$(jq --arg k "$k" --arg v "${ACL_MAP[$k]}" '.[$k]=$v' <<<"$acl_map_json")"; done

restore_hosts() {
  local endpoint="$1" file="$2" use_acl="${3:-no}"
  [ -s "$file" ] || return 0
  [ "$(jq 'length' "$file")" -gt 0 ] || return 0
  step "Restoring $endpoint"
  while IFS= read -r item; do
    # Remap certificate_id / access_list_id to the freshly created objects;
    # drop server-assigned / read-only fields before POSTing.
    payload="$(jq -c \
      --argjson certmap "$cert_map_json" --argjson aclmap "$acl_map_json" --arg useacl "$use_acl" '
      del(.id)
      | if (.certificate_id // 0) > 0
        then .certificate_id = (($certmap[(.certificate_id|tostring)] // "0")|tonumber) else . end
      | if ($useacl=="yes") and ((.access_list_id // 0) > 0)
        then .access_list_id = (($aclmap[(.access_list_id|tostring)] // "0")|tonumber) else . end
      ' <<<"$item")"
    name="$(jq -r '(.domain_names // [.incoming_port|tostring])|join(",")' <<<"$item")"
    if api_post "$endpoint" "$payload" >/dev/null 2>&1; then ok "restored $name"
    else note "failed to restore $name (create it manually in the UI)"; fi
  done < <(jq -c '.[]' "$file")
}

restore_hosts "nginx/proxy-hosts"       "$NPM_BACKUP_DIR/proxy_hosts.json"       yes
restore_hosts "nginx/redirection-hosts" "$NPM_BACKUP_DIR/redirection_hosts.json" no
restore_hosts "nginx/dead-hosts"        "$NPM_BACKUP_DIR/dead_hosts.json"        no
restore_hosts "nginx/streams"           "$NPM_BACKUP_DIR/streams.json"           no

# --- 9. install the backup timer ---------------------------------------------
step "Installing the systemd --user backup timer"
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
mkdir -p "$unit_dir"
for u in home-server-backup.service home-server-backup.timer; do
  sed "s|__REPO_ROOT__|$REPO_ROOT|g" "$REPO_ROOT/systemd/$u" >"$unit_dir/$u"
done
systemctl --user daemon-reload
systemctl --user enable --now home-server-backup.timer
ok "backup timer enabled"
note "For the timer to run while you're logged out, enable lingering:"
note "    sudo loginctl enable-linger $USER"
note "(see AGENTS.md for the keyring caveat with gh tokens in headless sessions)"

# --- 10. dynamic DNS (Cloud DNS) updater -------------------------------------
step "Setting up the dynamic DNS updater"
DYNDNS_CONF="$REPO_ROOT/dyndns/dyndns.conf"
# shellcheck source=/dev/null
[ -f "$DYNDNS_CONF" ] && . "$DYNDNS_CONF"
note "DynDNS keeps ${DYNDNS_RECORD:-the configured record} pointed at this host's public IP."
note "Prerequisites (see docs/superpowers/specs/2026-06-16-dyndns-cloud-dns-design.md):"
note "  1. Create the service account + zone IAM binding scoped to that one record."
note "  2. Set DYNDNS_ZONE in $DYNDNS_CONF."
note "  3. Place the SA key at ${DYNDNS_SA_KEY_FILE:-the configured path} (chmod 600)."

for u in home-server-dyndns.service home-server-dyndns.timer; do
  sed "s|__REPO_ROOT__|$REPO_ROOT|g" "$REPO_ROOT/systemd/$u" >"$unit_dir/$u"
done
systemctl --user daemon-reload

if [ -n "${DYNDNS_ZONE:-}" ] && [ -n "${DYNDNS_SA_KEY_FILE:-}" ] && [ -f "${DYNDNS_SA_KEY_FILE:-/nonexistent}" ]; then
  systemctl --user enable --now home-server-dyndns.timer
  ok "dyndns timer enabled"
  if "$REPO_ROOT/dyndns/dyndns.sh" --dry-run; then
    ok "dyndns dry-run succeeded"
  else
    note "dyndns dry-run reported a problem — check the config and SA key"
    note "until fixed, you can stop the timer with: systemctl --user disable --now home-server-dyndns.timer"
  fi
else
  note "dyndns not fully configured yet — units installed but timer NOT enabled."
  note "Once DYNDNS_ZONE is set and the SA key is in place, enable it with:"
  note "    systemctl --user enable --now home-server-dyndns.timer"
fi

step "Done"
ok "Services are up and NPM config restored. Run a backup now with:"
echo "    $REPO_ROOT/backup/backup.sh --dry-run"
