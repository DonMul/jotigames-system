#!/usr/bin/env bash
set -euo pipefail

EMAIL="${1:-${CERTBOT_EMAIL:-}}"
if [[ -z "${EMAIL}" ]]; then
  echo "Usage: $0 <email>"
  echo "Or set CERTBOT_EMAIL environment variable."
  exit 1
fi

if ! command -v certbot >/dev/null 2>&1; then
  echo "certbot is not installed" >&2
  exit 1
fi

sudo mkdir -p /var/www/letsencrypt

sudo certbot certonly --webroot \
  --non-interactive \
  --agree-tos \
  --email "${EMAIL}" \
  -w /var/www/letsencrypt \
  -d jotigames.nl \
  -d www.jotigames.nl \
  -d admin.jotigames.nl

echo "Certificate request complete."
echo "Now run deploy_update.sh to switch nginx from HTTP-only to HTTPS config."
