# DynDNS for Cloud DNS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a host-side dynamic-DNS updater that keeps the Cloud DNS `A` record for `ndonet.nahueldallacamina.com.ar` pointed at the home server's current public IPv4.

**Architecture:** A single self-contained bash script (`dyndns/dyndns.sh`) reads non-secret config from a committed file (`dyndns/dyndns.conf`), authenticates to GCP with a service-account key (the only secret, kept off-repo), detects the public IP, and creates/updates the record via `gcloud` only when it changed. A `systemd --user` timer runs it every 5 minutes. `restore/bootstrap.sh` installs the timer on a fresh machine. Mirrors the existing `backup/` + `systemd/` conventions.

**Tech Stack:** bash, `gcloud` CLI, `curl`, `flock`, systemd `--user` units.

**Testing note:** This repo has no bash test framework (consistent with the `backup/` subsystem). Verification per task is `bash -n` (syntax), `shellcheck` when available, and `dyndns.sh --dry-run`. The sandbox has no GCP credentials or network to Cloud DNS, so a *real* record update is verified by the operator on the host — the plan calls this out where relevant and never claims sandbox-side success for it.

---

### Task 1: Non-secret config file

**Files:**
- Create: `dyndns/dyndns.conf`

- [ ] **Step 1: Create the config file**

```sh
# dyndns/dyndns.conf — non-secret config for the Cloud DNS dynamic-DNS updater.
# Sourced by dyndns/dyndns.sh. Committed to git ON PURPOSE: nothing here is a
# secret. The only secret is the service-account key FILE referenced by
# DYNDNS_SA_KEY_FILE, which lives on the host outside this repo and is never
# committed. (.env stays secrets-only and gains nothing for dyndns.)

# GCP project that owns the Cloud DNS managed zone.
DYNDNS_PROJECT=nahueldallacamina-com-ar

# Cloud DNS managed-zone NAME (the resource id, NOT the DNS domain).
# Find it with: gcloud dns managed-zones list --project="$DYNDNS_PROJECT"
DYNDNS_ZONE=

# Fully-qualified record to keep current, WITH the trailing dot.
DYNDNS_RECORD=ndonet.nahueldallacamina.com.ar.

# TTL (seconds) applied when the record is created/updated.
DYNDNS_TTL=300

# Path on the host to the service-account JSON key. The path is not a secret;
# the file is — keep it outside the repo, chmod 600.
DYNDNS_SA_KEY_FILE=/home/nahuel/dyndns/sa-key.json
```

- [ ] **Step 2: Commit**

```bash
git add dyndns/dyndns.conf
git commit -m "dyndns: add non-secret Cloud DNS config file"
```

---

### Task 2: The updater script

**Files:**
- Create: `dyndns/dyndns.sh`

- [ ] **Step 1: Create the script**

```bash
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
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x dyndns/dyndns.sh`

- [ ] **Step 3: Syntax + lint check**

Run: `bash -n dyndns/dyndns.sh && command -v shellcheck >/dev/null && shellcheck dyndns/dyndns.sh || echo "shellcheck not installed — skipped"`
Expected: no syntax errors; shellcheck clean (or skipped).

- [ ] **Step 4: Verify config validation fires (no GCP needed)**

Run: `./dyndns/dyndns.sh --dry-run; echo "exit=$?"`
Expected: dies early. `DYNDNS_ZONE` is empty in the committed conf, so it dies with `set DYNDNS_ZONE (managed-zone name) in dyndns.conf` and `exit=1` — before it ever needs `gcloud` or the SA key. (Confirms validation works without touching GCP. A real update is verified on the host in Task 6.)

- [ ] **Step 5: Commit**

```bash
git add dyndns/dyndns.sh
git commit -m "dyndns: add Cloud DNS updater script"
```

---

### Task 3: systemd units

**Files:**
- Create: `systemd/home-server-dyndns.service`
- Create: `systemd/home-server-dyndns.timer`

- [ ] **Step 1: Create the service unit**

```ini
[Unit]
Description=Home-server dynamic DNS update (point the configured Cloud DNS A record at the host's public IP)
Documentation=https://github.com/nahudalla/home-server
# Needs outbound network (public-IP lookup + Cloud DNS API).
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
# __REPO_ROOT__ is substituted by restore/bootstrap.sh at install time.
WorkingDirectory=__REPO_ROOT__
ExecStart=/usr/bin/env bash __REPO_ROOT__/dyndns/dyndns.sh
# Surface failures in `systemctl --user status`.
TimeoutStartSec=120
```

- [ ] **Step 2: Create the timer unit**

```ini
[Unit]
Description=Periodic home-server dynamic DNS update
Documentation=https://github.com/nahudalla/home-server

[Timer]
# Check shortly after boot, then every 5 minutes.
OnBootSec=1min
OnUnitActiveSec=5min
# Catch up a missed run after the machine was off.
Persistent=true
# Avoid firing exactly on the minute boundary.
RandomizedDelaySec=30s

[Install]
WantedBy=timers.target
```

- [ ] **Step 3: Validate the unit files parse**

Run: `command -v systemd-analyze >/dev/null && systemd-analyze verify --user systemd/home-server-dyndns.service 2>&1 | grep -v __REPO_ROOT__ || echo "systemd-analyze unavailable or template placeholder present — skipped"`
Expected: no parse errors other than the `__REPO_ROOT__` placeholder path (which is substituted at install time). If `systemd-analyze` is unavailable, skipped.

- [ ] **Step 4: Commit**

```bash
git add systemd/home-server-dyndns.service systemd/home-server-dyndns.timer
git commit -m "dyndns: add systemd --user service + timer units"
```

---

### Task 4: Install the dyndns timer in restore/bootstrap.sh

**Files:**
- Modify: `restore/bootstrap.sh` (insert a new section after the backup-timer block, before the final `step "Done"` at line ~181)

- [ ] **Step 1: Insert the dyndns setup section**

Find this block near the end (the backup-timer install, currently ending around line 179):

```bash
systemctl --user enable --now home-server-backup.timer
ok "backup timer enabled"
note "For the timer to run while you're logged out, enable lingering:"
note "    sudo loginctl enable-linger $USER"
note "(see AGENTS.md for the keyring caveat with gh tokens in headless sessions)"
```

Immediately AFTER that block (and before `step "Done"`), insert:

```bash
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
  fi
else
  note "dyndns not fully configured yet — units installed but timer NOT enabled."
  note "Once DYNDNS_ZONE is set and the SA key is in place, enable it with:"
  note "    systemctl --user enable --now home-server-dyndns.timer"
fi
```

Note: `unit_dir` is defined in the backup-timer section above and is in scope here.

- [ ] **Step 2: Syntax + lint check**

Run: `bash -n restore/bootstrap.sh && command -v shellcheck >/dev/null && shellcheck restore/bootstrap.sh || echo "shellcheck not installed — skipped"`
Expected: no syntax errors; shellcheck clean (or skipped). Pre-existing shellcheck warnings unrelated to this change may remain — do not fix unrelated lines.

- [ ] **Step 3: Commit**

```bash
git add restore/bootstrap.sh
git commit -m "restore: install + enable the dyndns timer in bootstrap"
```

---

### Task 5: Documentation (AGENTS.md)

**Files:**
- Modify: `AGENTS.md` (the "What lives here" table, and a new section)

- [ ] **Step 1: Add rows to the "What lives here" table**

In the table under `## What lives here`, after the `backups/<service>/` row, add these two rows:

```markdown
| `dyndns/dyndns.sh` | Dynamic DNS updater: points a Cloud DNS A record at the host's public IP |
| `dyndns/dyndns.conf` | Non-secret DynDNS config (committed; the secret is the off-repo SA key file) |
```

- [ ] **Step 2: Add a "Dynamic DNS" section**

After the entire `## Backups` section (just before `## Restore (new machine)`), insert:

```markdown
## Dynamic DNS (Cloud DNS)

`dyndns/dyndns.sh` keeps a single IPv4 `A` record (`ndonet.nahueldallacamina.com.ar`
by default) pointed at the host's current public IP, via GCP Cloud DNS. A
`systemd --user` timer (`home-server-dyndns.timer`) runs it every 5 minutes; it
only calls Cloud DNS when the public IP actually changed.

- **Config (non-secret, committed):** `dyndns/dyndns.conf` — project, managed-zone
  name, record FQDN, TTL, and the *path* to the SA key. `.env` is untouched:
  dyndns adds no secrets to it.
- **The one secret:** the service-account JSON key *file* at `DYNDNS_SA_KEY_FILE`,
  kept on the host outside this repo (chmod 600), never committed.
- **Auth:** the script activates the SA in an isolated `CLOUDSDK_CONFIG` under
  `$XDG_STATE_HOME/home-server-dyndns`, so it never disturbs your interactive
  `gcloud` login.
- **Least privilege:** the SA is granted `roles/dns.admin` *on the managed zone*
  with an IAM Condition restricting `ResourceRecordSet` writes to exactly that one
  `A` record. Full recipe + rationale in
  `docs/superpowers/specs/2026-06-16-dyndns-cloud-dns-design.md`.

Run manually:

\`\`\`bash
dyndns/dyndns.sh --dry-run   # detect + report the intended change, write nothing
dyndns/dyndns.sh             # create/update the record if the public IP changed
\`\`\`

If `DYNDNS_ZONE` is unset or the SA key is missing, the script exits non-zero with
a clear message and `restore/bootstrap.sh` installs the units but leaves the timer
disabled until you finish setup.
```

(Note: write the three backticks literally — the `\`\`\`` shown above is escaped only for this plan.)

- [ ] **Step 3: Mention dyndns in the systemd note**

The `## Backups` text references a "daily `systemd --user` timer". No change needed there. But verify the `restore/bootstrap.sh` description in `## Restore (new machine)` still reads correctly; it ends with "installs the backup timer." Update that sentence to:

```markdown
the saved hosts/streams with their `*_id` references remapped → installs the
backup **and dynamic-DNS** timers.
```

- [ ] **Step 4: Commit**

```bash
git add AGENTS.md
git commit -m "docs: document the dynamic DNS updater in AGENTS.md"
```

---

### Task 6: Final verification + handoff notes

**Files:** none (verification only)

- [ ] **Step 1: Whole-tree syntax/lint sweep**

Run:
```bash
bash -n dyndns/dyndns.sh restore/bootstrap.sh
command -v shellcheck >/dev/null && shellcheck dyndns/dyndns.sh || echo "shellcheck skipped"
```
Expected: no syntax errors; shellcheck clean on `dyndns/dyndns.sh` (or skipped).

- [ ] **Step 2: Confirm git tree is clean and review the diff**

Run: `git status --short && git log --oneline -6`
Expected: clean working tree; the dyndns commits present.

- [ ] **Step 3: Record host-side verification steps (NOT runnable in the sandbox)**

These are for the operator to run on the host (the sandbox has no GCP creds/network to Cloud DNS). Document them in the PR body:

1. Set `DYNDNS_ZONE` in `dyndns/dyndns.conf`; ensure the SA key is at `DYNDNS_SA_KEY_FILE` (chmod 600).
2. `dyndns/dyndns.sh --dry-run` → prints the intended change (or "unchanged").
3. `dyndns/dyndns.sh` → creates/updates the record; a second run logs `unchanged`.
4. Confirm `dig +short ndonet.nahueldallacamina.com.ar` matches the host's public IP.
5. IAM negative check: with this SA, attempting to modify a *different* record returns `PERMISSION_DENIED`.
6. `systemctl --user status home-server-dyndns.timer` shows it active.

---

## Notes for the implementer

- DRY: the script deliberately does **not** reuse `backup/lib/common.sh` — that helper is coupled to git/commit/push. The ~8 lines of `log`/`die`/`require_cmd` are duplicated on purpose to keep dyndns an independent unit.
- YAGNI: IPv4 `A` only. No IPv6/`AAAA`, no multi-record/zone, no provider abstraction, no daemon.
- Follow existing conventions: `__REPO_ROOT__` placeholder in units, `--dry-run` flag parity with `backup.sh`, `note`/`ok`/`step` helpers in `bootstrap.sh`.
