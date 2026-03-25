# System

This folder stores operational/system setup files for background jobs.

## Documentation Note

Cross-system architecture and runbook context are centralized in `docs/` at repository root.

Start at: `docs/README.md`

## Structure

- `cron/`: crontab templates + installer scripts.
- `logs/`: local log files for background workers started by cron.

## Current background jobs

- `auto_resolve_pending_actions`
  - Script: `backend/scripts/auto_resolve_pending_actions.py`
  - Purpose: auto-accept EK pending actions older than 30 seconds.
- `certbot_renew`
  - Command: `certbot renew --quiet --deploy-hook "systemctl reload nginx"`
  - Purpose: renew Let's Encrypt certificates twice daily and reload nginx when certificates are updated.

## Production deployment

- Script: `system/deploy_update.sh`
- Purpose:
  - clone/update all production repos under `/var/www/jotigames.nl`
  - install backend/python (Python 3.14) and frontend/admin/ws dependencies
  - build frontend and admin
  - run backend migrations
  - install managed cron block
  - install/restart systemd services
  - install/update nginx reverse proxy config for `jotigames.nl` and `admin.jotigames.nl`
  - ensure certbot auto-renew timer is enabled

Run from server:

```bash
bash /var/www/jotigames.nl/system/deploy_update.sh
```

## One-time server bootstrap

- Script: `system/bootstrap_server.sh`
- Purpose:
  - install required base packages (git/python/node/nginx/certbot/etc.)
  - clone/update `system` repo into `/var/www/jotigames.nl/system`
  - execute `deploy_update.sh` to deploy all repositories and services

Example run (fresh server):

```bash
sudo bash /path/to/bootstrap_server.sh
```

Optional environment variables:

- `SYSTEM_REPO_URL` (default: `git@github.com:DonMul/jotigames-system.git`)
- `SYSTEM_REPO_BRANCH` (default: remote default branch)
- `CERTBOT_EMAIL` (recommended): email used by deploy for first-time automatic Let's Encrypt certificate issuance

## Nginx + Let's Encrypt

- Nginx config source: `system/nginx/jotigames.conf`
- HTTP fallback source (used before certs exist): `system/nginx/jotigames.http.conf`
- Hosts configured:
  - `jotigames.nl` (+ `www.jotigames.nl`) -> frontend service (`127.0.0.1:4173`)
  - `admin.jotigames.nl` -> admin service (`127.0.0.1:4174`)
- Shared reverse-proxied paths:
  - `/api/*` -> backend (`127.0.0.1:8000`)
  - `/ws/*` -> websocket server (`127.0.0.1:8081`)

Request certificates after DNS points to the server:

```bash
bash /var/www/jotigames.nl/system/nginx/request_certificates.sh you@example.com
```

Alternatively, set `CERTBOT_EMAIL` when running deploy and it will automatically request certs if missing:

```bash
CERTBOT_EMAIL=you@example.com bash /var/www/jotigames.nl/system/deploy_update.sh
```

The deploy script enables `certbot.timer` for automatic renewal.
It auto-selects HTTP-only nginx config when certs are missing and switches to HTTPS `:443` config once cert files are present.
