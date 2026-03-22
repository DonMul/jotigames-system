#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="/var/www/jotigames.nl"
SERVICES_DIR_SOURCE="${ROOT_DIR}/system/services"
CRON_INSTALL_SCRIPT="${ROOT_DIR}/system/cron/install_crontab.sh"
NGINX_CONFIG_SOURCE="${ROOT_DIR}/system/nginx/jotigames.conf"
NGINX_HTTP_CONFIG_SOURCE="${ROOT_DIR}/system/nginx/jotigames.http.conf"
NGINX_SITE_AVAILABLE="/etc/nginx/sites-available/jotigames.conf"
NGINX_SITE_ENABLED="/etc/nginx/sites-enabled/jotigames.conf"
LE_FULLCHAIN_PATH="/etc/letsencrypt/live/jotigames.nl/fullchain.pem"
LE_PRIVKEY_PATH="/etc/letsencrypt/live/jotigames.nl/privkey.pem"

declare -A REPOS=(
  [admin]="git@github.com:DonMul/jotigames-admin.git"
  [backend]="git@github.com:DonMul/jotigames-backend.git"
  [frontend]="git@github.com:DonMul/jotigames-frontend.git"
  [system]="git@github.com:DonMul/jotigames-system.git"
  [ws]="git@github.com:DonMul/jotigames-ws.git"
)

SYSTEMD_UNITS=(
  "jotigames-backend.service"
  "jotigames-frontend.service"
  "jotigames-admin.service"
  "jotigames-socketserver.service"
)

log() {
  echo "[deploy] $*"
}

run_as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

require_command() {
  local command_name="$1"
  if command -v "${command_name}" >/dev/null 2>&1; then
    return
  fi

  if command -v apt-get >/dev/null 2>&1; then
    log "Installing missing command '${command_name}' via apt-get"
    run_as_root apt-get update -y
    case "${command_name}" in
      git) run_as_root apt-get install -y git ;;
      python3) run_as_root apt-get install -y python3 ;;
      npm|node)
        run_as_root apt-get install -y nodejs npm
        ;;
      flock)
        run_as_root apt-get install -y util-linux
        ;;
      nginx)
        run_as_root apt-get install -y nginx
        ;;
      certbot)
        run_as_root apt-get install -y certbot python3-certbot-nginx
        ;;
      *)
        log "Unable to auto-install '${command_name}'. Please install it manually."
        exit 1
        ;;
    esac
  fi

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    log "Required command missing: ${command_name}"
    exit 1
  fi
}

resolve_default_branch() {
  local repo_dir="$1"
  local default_ref
  default_ref="$(git -C "${repo_dir}" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || true)"
  default_ref="${default_ref#refs/remotes/origin/}"
  if [[ -n "${default_ref}" ]]; then
    echo "${default_ref}"
  else
    echo "main"
  fi
}

clone_or_update_repo() {
  local name="$1"
  local url="$2"
  local repo_dir="${ROOT_DIR}/${name}"

  if [[ ! -d "${repo_dir}/.git" ]]; then
    log "Cloning ${name}"
    git clone "${url}" "${repo_dir}"
  else
    log "Updating ${name}"
    git -C "${repo_dir}" fetch --all --prune
    local branch
    branch="$(resolve_default_branch "${repo_dir}")"
    git -C "${repo_dir}" checkout "${branch}"
    git -C "${repo_dir}" pull --ff-only origin "${branch}"
  fi
}

setup_backend() {
  local backend_dir="${ROOT_DIR}/backend"
  log "Setting up backend"

  require_command python3
  if [[ ! -d "${backend_dir}/.venv" ]]; then
    python3 -m venv "${backend_dir}/.venv"
  fi

  "${backend_dir}/.venv/bin/pip" install --upgrade pip
  "${backend_dir}/.venv/bin/pip" install -r "${backend_dir}/requirements.txt"

  if [[ -f "${backend_dir}/scripts/setup_database.py" ]]; then
    log "Running setup_database.py"
    "${backend_dir}/.venv/bin/python" "${backend_dir}/scripts/setup_database.py"
  fi

  if [[ -f "${backend_dir}/alembic.ini" ]]; then
    log "Running alembic migrations"
    (cd "${backend_dir}" && "${backend_dir}/.venv/bin/alembic" upgrade head)
  fi
}

setup_frontend_like() {
  local app_dir="$1"
  log "Installing dependencies and building ${app_dir##*/}"
  (cd "${app_dir}" && npm ci && npm run build)
}

setup_ws() {
  local ws_dir="${ROOT_DIR}/ws"
  log "Installing WS dependencies"
  (cd "${ws_dir}" && npm ci)
}

install_cron() {
  if [[ -x "${CRON_INSTALL_SCRIPT}" ]]; then
    log "Installing managed crontab"
    (cd "${ROOT_DIR}" && bash "${CRON_INSTALL_SCRIPT}")
  else
    log "Cron install script missing or not executable: ${CRON_INSTALL_SCRIPT}"
    exit 1
  fi
}

install_and_restart_services() {
  log "Installing/updating systemd service units"

  for unit in "${SYSTEMD_UNITS[@]}"; do
    local source_file="${SERVICES_DIR_SOURCE}/${unit}"
    local target_file="/etc/systemd/system/${unit}"
    if [[ ! -f "${source_file}" ]]; then
      log "Missing service unit file: ${source_file}"
      exit 1
    fi

    run_as_root cp "${source_file}" "${target_file}"
  done

  run_as_root systemctl daemon-reload

  for unit in "${SYSTEMD_UNITS[@]}"; do
    run_as_root systemctl enable "${unit}"
    run_as_root systemctl restart "${unit}"
  done
}

install_nginx_reverse_proxy() {
  log "Installing/updating nginx reverse proxy config"

  if [[ ! -f "${NGINX_CONFIG_SOURCE}" || ! -f "${NGINX_HTTP_CONFIG_SOURCE}" ]]; then
    log "Missing nginx config source(s): ${NGINX_CONFIG_SOURCE} and/or ${NGINX_HTTP_CONFIG_SOURCE}"
    exit 1
  fi

  run_as_root mkdir -p /var/www/letsencrypt

  local selected_nginx_source="${NGINX_HTTP_CONFIG_SOURCE}"
  if [[ -f "${LE_FULLCHAIN_PATH}" && -f "${LE_PRIVKEY_PATH}" ]]; then
    selected_nginx_source="${NGINX_CONFIG_SOURCE}"
    log "Let's Encrypt certs found, enabling HTTPS nginx config"
  else
    log "Let's Encrypt certs not found yet, using HTTP-only nginx config"
  fi

  run_as_root cp "${selected_nginx_source}" "${NGINX_SITE_AVAILABLE}"

  if [[ -L "/etc/nginx/sites-enabled/default" ]]; then
    run_as_root rm -f /etc/nginx/sites-enabled/default
  fi

  if [[ ! -L "${NGINX_SITE_ENABLED}" ]]; then
    run_as_root ln -s "${NGINX_SITE_AVAILABLE}" "${NGINX_SITE_ENABLED}"
  fi

  run_as_root nginx -t
  run_as_root systemctl enable nginx
  run_as_root systemctl restart nginx
}

ensure_certbot_auto_renew() {
  log "Ensuring certbot auto-renew timer is enabled"
  run_as_root systemctl enable certbot.timer
  run_as_root systemctl restart certbot.timer
}

main() {
  require_command git
  require_command npm
  require_command node
  require_command flock
  require_command nginx
  require_command certbot

  run_as_root mkdir -p "${ROOT_DIR}"

  for name in admin backend frontend system ws; do
    clone_or_update_repo "${name}" "${REPOS[${name}]}"
  done

  setup_backend
  setup_frontend_like "${ROOT_DIR}/frontend"
  setup_frontend_like "${ROOT_DIR}/admin"
  setup_ws
  install_cron
  install_and_restart_services
  install_nginx_reverse_proxy
  ensure_certbot_auto_renew

  log "Deployment/update complete"
}

main "$@"
