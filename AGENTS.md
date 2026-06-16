# home-server — maintainer & agent guide

This repo is the source of truth for replicating the home server's setup on a new
machine, plus a periodic backup of selected service configuration committed back
to GitHub. Read this before changing anything here.

## What lives here

| Path | Purpose |
|---|---|
| `compose/docker-compose.yml` | All managed Docker services + networks (single source of truth) |
| `.env.example` / `.env` | Secrets template / real secrets (`.env` is gitignored) |
| `backup/backup.sh` | Backup orchestrator (run modules → commit → push) |
| `backup/lib/common.sh` | Shared helpers (logging, env, git commit/push) |
| `backup/services/*.sh` | One backup module per service (`npm.sh` today) |
| `backups/<service>/` | Committed plaintext config snapshots |
| `systemd/*.{service,timer}` | `--user` units that run the daily backup |
| `restore/bootstrap.sh` | Guided fresh-machine setup + config restore |
| `docs/superpowers/specs/` | Design specs |

## Services managed by `compose/docker-compose.yml`

- **nginx-proxy-manager** — public reverse proxy. Admin UI + REST API on `:81`.
  Config persists in the host bind mounts `/home/nahuel/npm/{data,letsencrypt}`.
- **postgres:18** — development database. `trust` auth, `127.0.0.1:5432`. **Data is
  not durable** and is not backed up.
- **mssql 2022** — development database. SA password from `.env`. **Data is not
  durable** and is not backed up.

### Networks (this repo owns them)

`npm-net` (172.16.204.0/24), `postgres-net` (172.16.201.0/24), `mssql-net`
(172.16.203.0/24) are declared with **pinned names** so they are created exactly,
not as `home-server_*`. The sibling `../ai-agents` repo attaches its sandbox
containers to `npm-net`/`postgres-net` and idempotently `docker network create`s
`npm-net`. **Bring this compose stack up before ai-agents launches sandboxes** so
the networks exist with the right subnets first. `ai-agents-mcp` (172.16.200.0/24)
is owned by ai-agents and is not managed here.

## Backups

`backup/backup.sh` runs each module in `backup/services/`, then commits any change
under `backups/` and pushes to `origin` over **HTTPS using `gh` as the git
credential helper** (no SSH — the SSH agent is 1Password and needs manual
approval). A daily `systemd --user` timer drives it.

What is and isn't captured (NPM):

- **Captured (plaintext JSON):** proxy / redirection / dead hosts, streams,
  access lists (usernames + IP rules), certificate **metadata**, settings.
- **Never captured (secrets):** TLS private keys, DNS provider API tokens
  (`meta.dns_provider_credentials`), basic-auth passwords, user password hashes,
  NPM's `keys.json`. These are recreated interactively by `restore/bootstrap.sh`.

### Embedded secrets in free-text fields

Field-level stripping cannot catch a secret pasted *inside* a free-text config
field — e.g. a `Bearer <token>` inside an nginx `advanced_config` block. As a
safety net, `commit_and_push` runs a **secret tripwire**: it aborts the commit
(nothing is committed or pushed) if the staged diff contains a high-confidence
secret (private-key blocks, `Bearer <token>`, `secret/api_key/token/password`
assignments). Patterns live in `backup/lib/common.sh` and are intentionally
narrow to avoid false positives. If it trips: remove or externalize the secret in
NPM (don't store live tokens in `advanced_config`), then re-run the backup.

Run manually:

```bash
backup/backup.sh --dry-run     # export + show diff, no commit/push
backup/backup.sh --no-push     # commit locally only
backup/backup.sh               # full: export, commit, push
backup/backup.sh npm           # only the npm module
```

### Adding a new service to backups (module contract)

Create `backup/services/<name>.sh`. It is sourced in a subshell and must:

1. set `SERVICE_NAME="<name>"`;
2. define a `backup()` function that writes plaintext files under
   `"$BACKUPS_DIR/$SERVICE_NAME/"`;
3. **never** write secrets (keys, tokens, passwords, hashes) — strip them;
4. produce **stable** output (sort arrays, use `jq -S`) so git diffs are
   meaningful.

Helpers from `backup/lib/common.sh` available inside a module: `log`, `warn`,
`die`, `require_cmd`, `$BACKUPS_DIR`, `$REPO_ROOT`. No registration step — any
`*.sh` in `backup/services/` is picked up automatically.

## Restore (new machine)

`restore/bootstrap.sh` is interactive: checks prereqs → `compose up -d` → waits
for NPM → guides you through the NPM admin account → has you recreate the
secret-bearing objects (certs, access lists) in the UI → automatically restores
the saved hosts/streams with their `*_id` references remapped → installs the
backup timer.

## Upgrade-validation procedure (IMPORTANT)

The NPM backup/restore talks to NPM's REST API, whose shape can change across
versions. **After bumping the `jc21/nginx-proxy-manager` image** (or any managed
image), validate before trusting it:

1. Pull + recreate: `docker compose -f compose/docker-compose.yml up -d`.
2. Snapshot the API contract and diff it against what you last saw:
   `curl -s http://127.0.0.1:81/api/schema | jq -S . > /tmp/npm-schema.json` and
   compare the export endpoints (`/nginx/{proxy-hosts,redirection-hosts,
   dead-hosts,streams,access-lists,certificates}`, `/settings`) for renamed or
   removed fields.
3. Run `backup/backup.sh --dry-run` and confirm it still produces valid JSON for
   every type, with **no secret fields leaking** (grep the diff for
   `dns_provider_credentials`, `password`, `privkey`, `BEGIN .* PRIVATE KEY`).
4. Do a restore dry-run on a throwaway NPM (or staging) and confirm the host
   `*_id` remapping in `restore/bootstrap.sh` still matches the current field
   names.
5. Only then commit the image bump.

If fields moved, update the jq filters in `backup/services/npm.sh` and the remap
logic in `restore/bootstrap.sh` together.

## Known caveats

- **gh token / keyring.** `backup.sh` pushes using `gh auth git-credential`,
  which reads the token from the login keyring. A `--user` timer running while
  you are logged out (linger enabled) may find the keyring locked. If pushes fail
  headless, either keep a login session, or configure `gh`/git with a PAT that
  doesn't depend on the keyring.
- **Live-host adoption.** Adopting this compose file on the *current* host
  recreates the containers. NPM data survives (bind mount); the dev DB volumes
  may reset — acceptable, they're dev-only.
- **Re-running restore** can create duplicate NPM objects; review the UI if you
  run `bootstrap.sh` more than once.
