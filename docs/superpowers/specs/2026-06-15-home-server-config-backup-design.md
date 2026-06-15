# Home-server config + backup — design

**Date:** 2026-06-15
**Status:** Approved
**Repo:** `github.com/nahudalla/home-server` (private)

## Purpose

Track the configuration and setup of the home server in git so the same setup
can be replicated on a new machine with everything still working the same. The
first services covered are three Docker containers started manually with
`docker run --restart=unless-stopped`: Nginx Proxy Manager (NPM), Postgres, and
MSSQL. Beyond static config, the repo also runs a periodic backup of designated
service configuration (NPM first) committed and pushed back to GitHub.

## Context and constraints

- The host is an Arch/Manjaro machine running systemd; Docker is system-level.
- The sibling repo `../ai-agents` implements a secure sandbox for AI coding
  agents. It **already creates `npm-net`** (idempotent, plain
  `docker network create npm-net`) and attaches sandbox containers to both
  `npm-net` and `postgres-net`; it owns the `ai-agents-mcp` network
  (`172.16.200.0/24`). There is deliberate network overlap between the repos.
- Postgres and MSSQL are **development only** — their *data* does not need to be
  persisted or backed up. Only NPM's configuration must be preserved.
- Secrets must stay out of git (the repo may go public later). The MSSQL SA
  password lives in `.env`; Postgres uses `POSTGRES_HOST_AUTH_METHOD=trust`.
- Git pushes use **`git` over HTTPS with a token from `gh`**, not SSH — the SSH
  agent is 1Password and requires manual per-use approval.

## Current running state (captured 2026-06-15)

| Service | Image | Networks | Ports | Storage |
|---|---|---|---|---|
| nginx-proxy-manager | `jc21/nginx-proxy-manager:latest` (build 2.14.0) | `bridge` + `npm-net` | 80/81/443 | binds `/home/nahuel/npm/data`, `/home/nahuel/npm/letsencrypt` |
| postgres | `postgres:18` | `postgres-net` | `127.0.0.1:5432` | named vol `postgres-data` |
| mssql-dev | `mcr.microsoft.com/mssql/server:2022-latest` | `mssql-net` | none published | named vol `mssql-data` |

Networks (explicit subnets, deliberately assigned):

| Network | Subnet | Owner |
|---|---|---|
| `npm-net` | `172.16.204.0/24` | this repo (shared with ai-agents) |
| `postgres-net` | `172.16.201.0/24` | this repo (shared with ai-agents) |
| `mssql-net` | `172.16.203.0/24` | this repo |
| `ai-agents-mcp` | `172.16.200.0/24` | ai-agents (not managed here) |

Env captured:
- NPM: standard image envs (no custom config envs).
- Postgres: `POSTGRES_HOST_AUTH_METHOD=trust`, `POSTGRES_USER=postgres`,
  `PGDATA=/var/lib/postgresql/18/docker`.
- MSSQL: `ACCEPT_EULA=Y`, `MSSQL_SA_PASSWORD=<secret>`, `MSSQL_PID=developer`.

NPM API verified reachable at `http://127.0.0.1:81/api/`
(`{"status":"OK","setup":true,"version":{"major":2,"minor":14}}`); auth endpoint
`POST /api/tokens`; OpenAPI at `GET /api/schema` (200).

## Decisions

1. **Format:** a single declarative `docker-compose.yml` (not scripts/prose).
2. **Networks:** this repo *owns and defines* `npm-net`, `postgres-net`,
   `mssql-net` with explicit subnets; `ai-agents-mcp` is left external/unmanaged.
3. **Secrets:** `.env` (gitignored) + committed `.env.example`.
4. **Data:** dev DB data is *not* persisted/backed up; NPM config *is*.
5. **Backup protection:** plaintext config only; **skip** private keys / API
   tokens / cert material; provide a guided setup script to recreate those
   secrets on restore.
6. **Scope of this spec:** all of components 1–4 below (one combined spec).
7. **Backup driver:** `systemd --user` timer + host script, running in the user
   session so the `gh` keyring token is reachable.
8. **Push auth:** `gh auth token` over HTTPS.
9. **NPM capture:** export via NPM REST API to per-type pretty-JSON, secret
   fields stripped.

## Architecture

### Repo layout

```
home-server/
├── AGENTS.md                       # maintainer/agent guide (see Docs)
├── CLAUDE.md                       # single line: @AGENTS.md
├── README.md                       # human quick-start
├── .env.example                    # documents required vars
├── .gitignore                      # ignores .env
├── compose/
│   └── docker-compose.yml          # all three services + three networks
├── backup/
│   ├── backup.sh                   # orchestrator: run modules → commit → push
│   ├── lib/common.sh               # shared helpers (logging, git, env)
│   └── services/
│       └── npm.sh                  # NPM export module
├── systemd/
│   ├── home-server-backup.service
│   └── home-server-backup.timer
├── restore/
│   └── bootstrap.sh                # guided fresh-machine setup
└── backups/
    └── npm/                        # committed plaintext config snapshots
        ├── proxy_hosts.json
        ├── redirection_hosts.json
        ├── dead_hosts.json
        ├── streams.json
        ├── access_lists.json
        ├── certificates.json       # metadata only — no key material
        └── settings.json
```

### Component 1 — `compose/docker-compose.yml`

Single file. Each `docker run` translated to a service:

- **nginx-proxy-manager:** `jc21/nginx-proxy-manager:latest`,
  `restart: unless-stopped`, ports `80:80`, `81:81`, `443:443`, network
  `npm-net`, bind mounts `/home/nahuel/npm/data:/data` and
  `/home/nahuel/npm/letsencrypt:/etc/letsencrypt`. (The incidental default
  `bridge` attachment from the original `docker run` is dropped; `npm-net`
  provides both proxy reachability and egress.)
- **postgres:** `postgres:18`, `restart: unless-stopped`, port
  `127.0.0.1:5432:5432`, env `POSTGRES_HOST_AUTH_METHOD=trust`,
  `POSTGRES_USER=postgres`, network `postgres-net`, named vol `postgres-data`.
- **mssql:** `mcr.microsoft.com/mssql/server:2022-latest`,
  `restart: unless-stopped`, env `ACCEPT_EULA=Y`,
  `MSSQL_SA_PASSWORD=${MSSQL_SA_PASSWORD}`, `MSSQL_PID=developer`, network
  `mssql-net`, named vol `mssql-data`, no published ports.

Networks declared with **pinned `name:`** to avoid the compose project prefix,
so the real network names are exactly `npm-net` / `postgres-net` / `mssql-net`:

```yaml
networks:
  npm-net:
    name: npm-net
    ipam: { config: [{ subnet: 172.16.204.0/24 }] }
  postgres-net:
    name: postgres-net
    ipam: { config: [{ subnet: 172.16.201.0/24 }] }
  mssql-net:
    name: mssql-net
    ipam: { config: [{ subnet: 172.16.203.0/24 }] }
```

**Ordering:** this repo creates `npm-net`/`postgres-net`, so `compose up` must
run *before* ai-agents launches sandboxes (its idempotent network-create then
no-ops). Documented in AGENTS.md.

### Component 2 — Backup system

- **`backup/backup.sh`** — orchestrator. Loads `.env`, sources every module in
  `backup/services/*.sh`, calls each module's `backup` function (writing into
  `backups/<service>/`), then: if `git status --porcelain backups/` shows
  changes, stage `backups/`, commit with message
  `backup: <services> YYYY-MM-DDTHH:MM`, and push to `origin` over HTTPS using a
  token from `gh auth token`. No-op (no commit) when nothing changed.
- **`backup/services/npm.sh`** — exposes `backup`:
  1. `POST :81/api/tokens` with `NPM_API_IDENTITY`/`NPM_API_SECRET` → JWT.
  2. `GET` proxy-hosts, redirection-hosts, dead-hosts, streams, access-lists,
     certificates, settings.
  3. **Strip secret fields** (cert key material, DNS provider credentials in
     cert `meta`, access-list basic-auth passwords) and **volatile noise**
     (sort by id; drop `created_on`/`modified_on` and similar churn fields).
  4. Write each as pretty-printed, stably-sorted JSON to `backups/npm/`.
  Certificates are exported as **metadata only** (provider, domains, expiry) so
  restore knows what to re-issue.
- **Extensibility:** adding a service = drop a new `backup/services/<name>.sh`
  exposing a `backup` function that writes under `backups/<name>/`. Contract
  documented in AGENTS.md.
- **`systemd/home-server-backup.{service,timer}`** — `--user` units; timer fires
  daily (`OnCalendar=daily`, `Persistent=true`). The service runs `backup.sh`
  from the repo checkout, inside the user session so the `gh` keyring token is
  available.

### Component 3 — `restore/bootstrap.sh` (guided)

Interactive fresh-machine setup:

1. Preconditions: `docker`, `docker compose`, `gh` logged in, `.env` present
   (offer to copy from `.env.example`), npm bind-mount dirs exist.
2. `docker compose -f compose/docker-compose.yml up -d` (creates networks +
   services).
3. NPM first-run: prompt the user to complete NPM's initial admin
   email/password, then record `NPM_API_IDENTITY`/`NPM_API_SECRET` into `.env`.
4. Restore NPM config: POST/PUT each `backups/npm/*.json` back via the API,
   reconciling references (e.g. cert IDs) where needed.
5. **Interactive secret recreation** (the parts backups skip): re-issue or
   upload TLS certs, re-enter DNS provider API tokens, reset access-list
   passwords. Automate via the API where possible; prompt where not.
6. Install + `--user enable --now` the systemd timer.

Idempotent where feasible (safe to re-run).

### Component 4 — Docs

- **`AGENTS.md`** — architecture overview; how compose/backup/restore fit
  together; the **backup-module contract** for adding services; and the
  **upgrade-validation procedure**: after bumping the NPM image, re-run the
  backup, diff `GET /api/schema` against the last-known schema, perform a restore
  dry-run, and confirm field mappings still hold before trusting the new
  version.
- **`CLAUDE.md`** — single line `@AGENTS.md`.
- **`README.md`** — human quick-start (bring up services, run a backup, restore
  on a new machine).

## Known risks (documented, not blockers)

1. **Live-host adoption.** Switching the *current* host to compose recreates the
   containers. NPM data survives (bind mount); dev DB volumes may reset —
   acceptable (dev-only). Primary target is a fresh machine.
2. **Keyring lock.** `gh auth token` needs an unlocked keyring; the timer runs
   in-session to ensure availability. Fallback noted in AGENTS.md.
3. **NPM API drift.** API shape can change across NPM versions; mitigated by the
   AGENTS.md upgrade-validation procedure and the `/api/schema` check.

## Out of scope (future specs)

- Backing up/restoring dev database *data* (intentionally not persisted).
- Additional services beyond NPM/Postgres/MSSQL (the backup system is built to
  extend to them later).
