#!/usr/bin/env bash
# Backup module: Nginx Proxy Manager.
#
# Module contract (see ../../AGENTS.md):
#   - set SERVICE_NAME
#   - define backup(), writing plaintext files under "$BACKUPS_DIR/$SERVICE_NAME/"
#   - never write secrets (private keys, API tokens, password material)
# The orchestrator sources this file in a subshell and calls backup().

SERVICE_NAME="npm"

NPM_API_URL="${NPM_API_URL:-http://127.0.0.1:81/api}"

# Obtain a short-lived API token from NPM admin credentials.
_npm_token() {
  [ -n "${NPM_API_IDENTITY:-}" ] || die "NPM_API_IDENTITY not set (see .env.example)"
  [ -n "${NPM_API_SECRET:-}" ]   || die "NPM_API_SECRET not set (see .env.example)"
  local resp token
  resp="$(curl -fsS -m 15 -X POST "$NPM_API_URL/tokens" \
    -H 'Content-Type: application/json' \
    --data "$(jq -n --arg i "$NPM_API_IDENTITY" --arg s "$NPM_API_SECRET" \
      '{identity:$i, secret:$s}')")" \
    || die "NPM auth request failed — is NPM reachable at $NPM_API_URL ?"
  token="$(jq -r '.token // empty' <<<"$resp")"
  [ -n "$token" ] || die "NPM auth rejected — check NPM_API_IDENTITY/NPM_API_SECRET"
  printf '%s' "$token"
}

# GET an endpoint, run it through a jq filter, and write stable, key-sorted JSON.
# Stable output (sorted keys + sorted array) keeps git diffs meaningful.
_npm_export() {
  local token="$1" endpoint="$2" outfile="$3" filter="$4"
  local body
  body="$(curl -fsS -m 30 "$NPM_API_URL/$endpoint" \
    -H "Authorization: Bearer $token")" \
    || die "NPM GET /$endpoint failed"
  jq -S "$filter" <<<"$body" >"$outfile" \
    || die "failed to transform /$endpoint"
  log "  wrote ${outfile#"$BACKUPS_DIR"/}"
}

backup() {
  require_cmd curl jq
  local out="$BACKUPS_DIR/$SERVICE_NAME"
  mkdir -p "$out"

  log "authenticating to NPM API at $NPM_API_URL"
  local token; token="$(_npm_token)"

  # Drop instance-specific / churny fields and any expanded sub-objects so the
  # snapshot is portable and diff-friendly. Keep *_id references for restore.
  local host_filter='
    map(
      del(.created_on, .modified_on, .owner, .owner_user_id, .certificate, .access_list)
      | if has("meta") and (.meta|type=="object")
        then .meta |= del(.nginx_online, .nginx_err) else . end
    ) | sort_by(.id)'

  _npm_export "$token" "nginx/proxy-hosts"       "$out/proxy_hosts.json"       "$host_filter"
  _npm_export "$token" "nginx/redirection-hosts" "$out/redirection_hosts.json" "$host_filter"
  _npm_export "$token" "nginx/dead-hosts"        "$out/dead_hosts.json"        "$host_filter"
  _npm_export "$token" "nginx/streams"           "$out/streams.json"           "$host_filter"

  # Certificates: metadata only. Strip key material and DNS provider tokens.
  _npm_export "$token" "nginx/certificates" "$out/certificates.json" '
    map(
      del(.created_on, .modified_on, .owner, .owner_user_id)
      | if has("meta") and (.meta|type=="object")
        then .meta |= del(.dns_provider_credentials, .certificate, .certificate_key) else . end
    ) | sort_by(.id)'

  # Access lists with their clients/items, but never the basic-auth passwords.
  _npm_export "$token" "nginx/access-lists?expand=clients,items" "$out/access_lists.json" '
    map(
      del(.created_on, .modified_on, .owner, .owner_user_id, .proxy_host_count)
      | if has("items")   and (.items|type=="array")
        then .items   |= map(del(.created_on, .modified_on, .id, .access_list_id, .password, .hint)) else . end
      | if has("clients") and (.clients|type=="array")
        then .clients |= map(del(.created_on, .modified_on, .id, .access_list_id)) else . end
    ) | sort_by(.id)'

  # Global settings (default site, etc.) — not secret.
  _npm_export "$token" "settings" "$out/settings.json" \
    'map(del(.created_on, .modified_on)) | sort_by(.id)'

  log "NPM config exported to ${out#"$REPO_ROOT"/}/"
}
