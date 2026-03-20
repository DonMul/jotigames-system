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

sudo certbot --nginx \
  --non-interactive \
  --agree-tos \
  --email "${EMAIL}" \
  -d jotigames.nl \
  -d www.jotigames.nl \
  -d admin.jotigames.nl

echo "Certificate request complete."
