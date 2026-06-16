# Dynamic DNS for Cloud DNS — design

## Goal

Keep the public DNS `A` record for `ndonet.nahueldallacamina.com.ar` pointed at
the home server's current public IPv4 address, automatically and unattended, on
the host. When the ISP-assigned public IP changes, the record follows it within
a few minutes.

This is a host-side service in the spirit of the existing `backup/` subsystem: a
single shell script driven by a `systemd --user` timer, replicable on a fresh
machine via `restore/bootstrap.sh`.

## Scope

- **In scope:** one IPv4 `A` record in GCP Cloud DNS, updated on change only.
- **Out of scope:** IPv6/`AAAA`, multiple records/zones, other DNS providers.

## Decisions (from brainstorming)

| Question | Decision |
|---|---|
| Execution | `systemd --user` timer + a single shell script (mirrors `backup/`) |
| GCP auth | Dedicated service account + JSON key file on the host, outside git |
| Records | IPv4 `A` only |
| DNS client | `gcloud` CLI (SA key activated in an isolated `CLOUDSDK_CONFIG`) |
| Config | Non-secret config in a committed file; `.env` stays secrets-only |

## Layout

```
dyndns/
  dyndns.sh                       # the updater (single, self-contained script)
  dyndns.conf                     # committed, non-secret config (sourced by the script)
systemd/
  home-server-dyndns.service      # oneshot → runs dyndns.sh
  home-server-dyndns.timer        # every 5 min (+ OnBootSec catch-up)
```

The script is **independent of the `backup/` subsystem** — it does not source
`backup/lib/common.sh` (that helper is coupled to git/commit/push logic). It
carries its own small `log`/`die`/`require_cmd` helpers. The duplication is a few
trivial lines and keeps the two subsystems as separate, well-bounded units.

## Configuration

`.env` stays **secrets-only** and gains **nothing** for dyndns — the only secret
is the SA key *file*, which lives on the host outside the repo. Non-secret config
is committed:

```sh
# dyndns/dyndns.conf — non-secret config for the Cloud DNS updater.
# Sourced by dyndns/dyndns.sh. No secrets here (the SA key FILE is the only
# secret and lives at DYNDNS_SA_KEY_FILE, outside the repo).
DYNDNS_PROJECT=nahueldallacamina-com-ar
DYNDNS_ZONE=                                     # managed-zone NAME (not the domain):
                                                 #   gcloud dns managed-zones list
DYNDNS_RECORD=ndonet.nahueldallacamina.com.ar.   # FQDN, trailing dot
DYNDNS_TTL=300
DYNDNS_SA_KEY_FILE=/home/nahuel/dyndns/sa-key.json   # path is not a secret; the file is
```

A path is not a secret, so the key-file *path* belongs in committed config; the
key *file* never enters git. `DYNDNS_ZONE` is the one value the operator fills in
(the Cloud DNS managed-zone resource name, distinct from the DNS domain).

## Behaviour — `dyndns.sh`

1. `set -euo pipefail`. Resolve script dir; source `dyndns.conf`. Validate that
   `DYNDNS_PROJECT`, `DYNDNS_ZONE`, `DYNDNS_RECORD`, `DYNDNS_SA_KEY_FILE` are set
   and the key file exists (`die` otherwise).
2. `require_cmd gcloud curl`.
3. **Isolate gcloud state:** `export CLOUDSDK_CONFIG="$dyndns_state_dir"` (a
   per-service config dir, e.g. `${XDG_STATE_HOME:-$HOME/.local/state}/home-server-dyndns`)
   and `gcloud auth activate-service-account --key-file="$DYNDNS_SA_KEY_FILE"`.
   This keeps the SA credentials out of the operator's default `gcloud` config.
4. **Concurrency guard:** `flock` a lockfile in the state dir so overlapping
   timer firings don't collide; exit quietly if another run holds it.
5. **Detect public IPv4:** `curl -fsS --max-time 10 https://api.ipify.org`, with a
   fallback to `https://checkip.amazonaws.com`. Trim whitespace; validate it is a
   dotted IPv4 (`die` if neither source yields a valid address).
6. **Read current record:** `gcloud dns record-sets list --zone="$DYNDNS_ZONE"
   --name="$DYNDNS_RECORD" --type=A --project="$DYNDNS_PROJECT"
   --format='value(rrdatas[0])'`.
7. **Compare:**
   - Equal → log "unchanged ($ip)" and exit 0 (quiet, idempotent).
   - Record absent → `gcloud dns record-sets create` with the IP + TTL.
   - Record present and different → `gcloud dns record-sets update` with the new
     IP + TTL.
8. Log the action taken. Any failure (no/invalid IP, auth failure, API error)
   → `die` with a non-zero exit so `systemctl --user status` surfaces it.
   "No change" is success.

### `--dry-run`

`dyndns.sh --dry-run` performs steps 1–6 and prints the intended change (or
"unchanged") **without** calling `create`/`update`. Mirrors `backup.sh --dry-run`.

## systemd units

`systemd/home-server-dyndns.service` (oneshot) and `home-server-dyndns.timer`,
following the existing `home-server-backup.*` conventions — including the
`__REPO_ROOT__` placeholder that `restore/bootstrap.sh` substitutes at install
time.

- Service: `Type=oneshot`, `WorkingDirectory=__REPO_ROOT__`,
  `ExecStart=/usr/bin/env bash __REPO_ROOT__/dyndns/dyndns.sh`,
  `After=network-online.target` / `Wants=network-online.target`.
- Timer: `OnBootSec=1min`, `OnUnitActiveSec=5min` (check shortly after boot, then
  every 5 minutes), `Persistent=true`, small `RandomizedDelaySec`.

## GCP service account (least privilege)

Already created by the operator. Recorded here for replication. The SA is granted
`roles/dns.admin` **on the managed zone** (not the project) with an IAM Condition
that limits `ResourceRecordSet` access to exactly the `A` record for the target,
while leaving `Change`/transaction and zone-read operations unconditioned (so
transactions still work):

```bash
PROJECT=nahueldallacamina-com-ar
ZONE=<managed-zone-name>                 # gcloud dns managed-zones list --project=$PROJECT
RECORD=ndonet.nahueldallacamina.com.ar.  # trailing dot
SA="dyndns-ndonet@${PROJECT}.iam.gserviceaccount.com"

gcloud iam service-accounts create dyndns-ndonet \
  --project="$PROJECT" --display-name="DynDNS updater for ndonet"

# set-iam-policy REPLACES the whole policy and needs the current etag, so fetch
# first, append our conditioned binding, then set it back. (dns managed-zones has
# no add-iam-policy-binding convenience command — only get/set-iam-policy.)
gcloud dns managed-zones get-iam-policy "$ZONE" \
  --project="$PROJECT" --format=json > /tmp/dyndns-policy.json

jq --arg sa "serviceAccount:${SA}" --arg rec "$RECORD" '
  .version = 3
  | .bindings += [{
      role: "roles/dns.admin",
      members: [$sa],
      condition: {
        title: "only-ndonet-A",
        expression: "(resource.type == \"dns.googleapis.com/ResourceRecordSet\" && resource.name.endsWith(\"/rrsets/\($rec)/A\")) || (resource.type != \"dns.googleapis.com/ResourceRecordSet\")"
      }
    }]
' /tmp/dyndns-policy.json > /tmp/dyndns-policy.new.json

gcloud dns managed-zones set-iam-policy "$ZONE" \
  --project="$PROJECT" --policy-file=/tmp/dyndns-policy.new.json

# Key for the host — the ONLY secret; store outside the repo and lock it down.
install -d -m 700 /home/nahuel/dyndns
gcloud iam service-accounts keys create /home/nahuel/dyndns/sa-key.json \
  --project="$PROJECT" --iam-account="$SA"
chmod 600 /home/nahuel/dyndns/sa-key.json
```

**Why zone-level + condition, not a project custom role:** a project-level grant
(even a custom role with only `dns.resourceRecordSets.*` + `dns.changes.*`) still
lets the SA write *every* record in *every* zone. Binding on the zone with the
per-rrset condition is the only way to get "this one record, nothing else."

**Verification:** after setup, confirm the SA can update the target record but is
denied on any *other* record (expect `PERMISSION_DENIED`).

## Restore integration

`restore/bootstrap.sh` gains a step that:

- Reminds the operator to create the SA + zone IAM binding (above) and place the
  key at `DYNDNS_SA_KEY_FILE`, and to set `DYNDNS_ZONE` in `dyndns/dyndns.conf`.
- Installs and enables `home-server-dyndns.{service,timer}` alongside the backup
  timer, substituting `__REPO_ROOT__` the same way.

No compose or network changes — this is not a container.

## Documentation

`AGENTS.md`: add a "Dynamic DNS" section, a table row, and notes in the systemd
and restore sections; reiterate that the SA key file is a secret never committed.

## Error handling summary

| Condition | Outcome |
|---|---|
| Public IP unfetchable / not valid IPv4 | `die`, non-zero exit |
| `gcloud` auth failure | `die`, non-zero exit |
| Cloud DNS API error | `die`, non-zero exit (propagated from gcloud) |
| Record already correct | log "unchanged", exit 0 |
| Concurrent run holds the lock | exit 0 quietly |

## Testing

No bash test framework exists in this repo, so testing is pragmatic and matches
the backup subsystem:

- `dyndns/dyndns.sh --dry-run` for safe verification (no writes).
- `bash -n` / `shellcheck` clean on the script.
- A manual real run on the host, confirming the record reflects the host IP and a
  second run reports "unchanged".
- The IAM negative check (a different record is `PERMISSION_DENIED`).

## YAGNI / non-goals

- No IPv6, no multi-record/zone support, no provider abstraction.
- No daemon/long-running process — the timer cadence is sufficient.
- No metrics/alerting beyond `systemctl --user status` surfacing failures.
