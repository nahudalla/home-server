# home-server

Configuration and setup of my home server, tracked in git so the whole thing can
be replicated on a new machine with everything still working the same.

It contains:

- **`compose/docker-compose.yml`** — the managed Docker services and networks
  (Nginx Proxy Manager, Postgres, MSSQL), translated from the original hand-run
  `docker run --restart=unless-stopped` commands.
- **A periodic backup** of selected service configuration (NPM today) exported as
  plaintext JSON under `backups/`, committed and pushed to GitHub by a daily
  `systemd --user` timer.
- **A guided restore** (`restore/bootstrap.sh`) that brings a fresh machine back
  to the same state.

> Maintainer/agent details — architecture, the backup-module contract, and the
> NPM upgrade-validation procedure — live in [AGENTS.md](AGENTS.md).

## Quick start

### Bring up the services

```bash
cp .env.example .env        # then edit .env and set the secrets
docker compose -f compose/docker-compose.yml up -d
```

Networks `npm-net` / `postgres-net` / `mssql-net` are created with fixed subnets.
Bring this stack up **before** the `../ai-agents` sandboxes (they share
`npm-net`/`postgres-net`).

### Run a backup

```bash
backup/backup.sh --dry-run   # export NPM config and show the diff only
backup/backup.sh             # export, commit, and push to GitHub
```

A daily timer does this automatically once `restore/bootstrap.sh` has installed
it (or install the units in `systemd/` yourself).

### Replicate on a new machine

```bash
git clone https://github.com/nahudalla/home-server.git
cd home-server
gh auth login                # used for pushes (HTTPS, no SSH)
restore/bootstrap.sh         # guided setup + NPM config restore
```

The restore is interactive: it stands up the services, walks you through the NPM
admin account and recreating the secret-bearing objects (TLS certs, DNS tokens,
access-list passwords) that backups intentionally skip, then automatically wires
the saved proxy/redirection/stream/dead hosts back to them.

## What's NOT backed up

Postgres and MSSQL are development databases — their **data is not persisted or
backed up**. Only NPM's configuration is. Secrets (private keys, API tokens,
passwords) are never committed; they're recreated during restore.
