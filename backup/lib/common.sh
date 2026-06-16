#!/usr/bin/env bash
# Shared helpers for the backup system. Sourced by backup.sh and modules.
# Not meant to be executed directly.

# --- logging -----------------------------------------------------------------
log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
warn() { printf '[%s] WARN: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
}

# --- repo layout -------------------------------------------------------------
# REPO_ROOT is the git checkout root; BACKUPS_DIR is where modules write.
_resolve_repo_root() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # backup/lib
  git -C "$here" rev-parse --show-toplevel 2>/dev/null || die "not inside a git checkout"
}
REPO_ROOT="$(_resolve_repo_root)"
BACKUPS_DIR="$REPO_ROOT/backups"
SERVICES_DIR="$REPO_ROOT/backup/services"

# --- env ---------------------------------------------------------------------
# Load REPO_ROOT/.env (KEY=VALUE) into the environment if present. Real secrets
# never live in git; .env is gitignored.
load_env() {
  local env_file="$REPO_ROOT/.env"
  [ -f "$env_file" ] || return 0
  set -a
  # shellcheck disable=SC1090
  . "$env_file"
  set +a
}

# --- git sync ----------------------------------------------------------------
# Fast-forward the current branch to its origin counterpart over HTTPS (gh
# credential helper) BEFORE we write any backup files, so the later push can't
# be rejected as non-fast-forward after main advanced on GitHub (e.g. a merged
# PR). Read-only fetch + ff-only merge; never rewrites local history. On any
# problem it warns and continues — a stale local branch shouldn't block a backup
# (the push will surface a real divergence).
# Must run with a clean working tree (call before exporting).
sync_with_remote() {
  command -v gh >/dev/null 2>&1 || { warn "gh not found — skipping pre-sync"; return 0; }
  local https_url branch
  https_url="$(cd "$REPO_ROOT" && gh repo view --json url -q .url 2>/dev/null)" || true
  [ -n "$https_url" ] || { warn "could not resolve GitHub URL — skipping pre-sync"; return 0; }
  branch="$(git -C "$REPO_ROOT" symbolic-ref --short HEAD)"
  if ! git -C "$REPO_ROOT" \
        -c credential.helper= -c 'credential.helper=!gh auth git-credential' \
        fetch "${https_url}.git" "$branch" >/dev/null 2>&1; then
    warn "pre-sync fetch failed — continuing with local state"
    return 0
  fi
  if git -C "$REPO_ROOT" merge-base --is-ancestor HEAD FETCH_HEAD 2>/dev/null; then
    git -C "$REPO_ROOT" merge --ff-only FETCH_HEAD >/dev/null 2>&1 \
      && log "synced $branch with origin (fast-forwarded)" \
      || warn "fast-forward failed — continuing with local state"
  elif ! git -C "$REPO_ROOT" merge-base --is-ancestor FETCH_HEAD HEAD 2>/dev/null; then
    warn "local $branch has diverged from origin/$branch — resolve manually; the push will likely be rejected"
  fi
  # else: HEAD is ahead of origin (local commits not yet pushed) — nothing to do.
}

# --- git commit + push -------------------------------------------------------
# Stage backups/, and if anything changed commit and push to origin over HTTPS
# using gh as the credential helper (no SSH, no token on the command line).
# Honors DRY_RUN=1 (export only) and NO_PUSH=1 (commit locally, skip push).
commit_and_push() {
  local message="$1"
  git -C "$REPO_ROOT" add -A "$BACKUPS_DIR"

  if git -C "$REPO_ROOT" diff --cached --quiet -- "$BACKUPS_DIR"; then
    log "no config changes — nothing to commit"
    return 0
  fi

  # Secret tripwire. Field-level stripping can't catch secrets embedded in
  # free-text config (e.g. a Bearer token inside an nginx advanced_config block),
  # so refuse to commit if the added lines contain a high-confidence secret.
  # Patterns are deliberately narrow to avoid false positives on normal config.
  if git -C "$REPO_ROOT" diff --cached -- "$BACKUPS_DIR" | grep -E '^\+' \
       | grep -Eiq 'BEGIN [A-Z ]*PRIVATE KEY|Bearer [A-Za-z0-9._-]{20,}|(secret|api[_-]?key|token|password)[\"'\'' ]*[:=][\"'\'' ]*[A-Za-z0-9._-]{16,}'; then
    git -C "$REPO_ROOT" reset -q -- "$BACKUPS_DIR"
    die "possible secret detected in staged backup — aborting (nothing committed). Inspect with: git -C $REPO_ROOT diff -- backups/ ; see AGENTS.md (embedded secrets)."
  fi

  if [ "${DRY_RUN:-0}" = "1" ]; then
    log "DRY_RUN=1 — changes detected but not committing. Diff:"
    git -C "$REPO_ROOT" --no-pager diff --cached --stat -- "$BACKUPS_DIR" >&2
    git -C "$REPO_ROOT" reset -q -- "$BACKUPS_DIR"
    return 0
  fi

  git -C "$REPO_ROOT" commit -q -m "$message" -- "$BACKUPS_DIR"
  log "committed: $message"

  if [ "${NO_PUSH:-0}" = "1" ]; then
    log "NO_PUSH=1 — skipping push"
    return 0
  fi

  require_cmd gh
  gh auth token >/dev/null 2>&1 || die "gh has no usable token (locked keyring?). See AGENTS.md."
  local branch https_url
  branch="$(git -C "$REPO_ROOT" symbolic-ref --short HEAD)"
  # Push to the explicit HTTPS URL (not the named remote, which may be SSH) so
  # gh's credential helper applies and we never touch the 1Password SSH agent.
  https_url="$(cd "$REPO_ROOT" && gh repo view --json url -q .url 2>/dev/null)"
  [ -n "$https_url" ] || die "could not resolve the GitHub HTTPS URL via gh"
  git -C "$REPO_ROOT" \
    -c credential.helper= \
    -c 'credential.helper=!gh auth git-credential' \
    push "${https_url}.git" "HEAD:$branch"
  log "pushed to ${https_url} ($branch)"
}
