#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

ROOT_DIR="/var/www/jotigames.nl"
BACKEND_PYTHON_BIN="${BACKEND_PYTHON_BIN:-python3.14}"
NODE_MIN_MAJOR="${NODE_MIN_MAJOR:-24}"
NODE_MIN_MINOR="${NODE_MIN_MINOR:-14}"
SERVICES_DIR_SOURCE="${ROOT_DIR}/system/services"
CRON_INSTALL_SCRIPT="${ROOT_DIR}/system/cron/install_crontab.sh"
NGINX_CONFIG_SOURCE="${ROOT_DIR}/system/nginx/jotigames.conf"
NGINX_HTTP_CONFIG_SOURCE="${ROOT_DIR}/system/nginx/jotigames.http.conf"
NGINX_SITE_AVAILABLE="/etc/nginx/sites-available/jotigames.conf"
NGINX_SITE_ENABLED="/etc/nginx/sites-enabled/jotigames.conf"
LE_FULLCHAIN_PATH="/etc/letsencrypt/live/jotigames.nl/fullchain.pem"
LE_PRIVKEY_PATH="/etc/letsencrypt/live/jotigames.nl/privkey.pem"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"

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

declare -A SERVICE_PORTS=(
  ["jotigames-backend.service"]=8000
  ["jotigames-frontend.service"]=4173
  ["jotigames-admin.service"]=4174
  ["jotigames-socketserver.service"]=8081
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
      curl) run_as_root apt-get install -y curl ;;
      python3.14)
        if ! run_as_root apt-get install -y python3.14 python3.14-venv; then
          log "Unable to install python3.14 from apt repositories. Install Python 3.14 manually or add a repository providing python3.14."
          exit 1
        fi
        ;;
      python3) run_as_root apt-get install -y python3 ;;
      npm|node)
        run_as_root apt-get install -y nodejs npm
        ;;
      flock)
        run_as_root apt-get install -y util-linux
        ;;
      ss)
        run_as_root apt-get install -y iproute2
        ;;
      nginx)
        run_as_root apt-get install -y nginx
        ;;
      certbot)
        run_as_root apt-get install -y certbot python3-certbot-nginx
        ;;
      openssl)
        run_as_root apt-get install -y openssl
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

install_nodejs_24() {
  if ! command -v apt-get >/dev/null 2>&1; then
    log "Node.js 24 auto-install is only implemented for apt-based systems."
    return 1
  fi

  require_command curl
  log "Installing/upgrading Node.js 24 via NodeSource"
  run_as_root bash -lc "curl -fsSL https://deb.nodesource.com/setup_24.x | bash -"
  run_as_root apt-get install -y nodejs
}

ensure_nodejs_min_version() {
  require_command node

  local node_major node_minor
  node_major="$(node -p 'Number(process.versions.node.split(".")[0]||0)' 2>/dev/null || echo 0)"
  node_minor="$(node -p 'Number(process.versions.node.split(".")[1]||0)' 2>/dev/null || echo 0)"
  if [[ "${node_major}" =~ ^[0-9]+$ ]] && [[ "${node_minor}" =~ ^[0-9]+$ ]] && \
     ( (( node_major > NODE_MIN_MAJOR )) || (( node_major == NODE_MIN_MAJOR && node_minor >= NODE_MIN_MINOR )) ); then
    require_command npm
    return
  fi

  log "Detected Node.js version ${node_major}.${node_minor}, but >= ${NODE_MIN_MAJOR}.${NODE_MIN_MINOR}.x is required."
  install_nodejs_24

  node_major="$(node -p 'Number(process.versions.node.split(".")[0]||0)' 2>/dev/null || echo 0)"
  node_minor="$(node -p 'Number(process.versions.node.split(".")[1]||0)' 2>/dev/null || echo 0)"
  if [[ ! "${node_major}" =~ ^[0-9]+$ ]] || [[ ! "${node_minor}" =~ ^[0-9]+$ ]] || \
     ! ( (( node_major > NODE_MIN_MAJOR )) || (( node_major == NODE_MIN_MAJOR && node_minor >= NODE_MIN_MINOR )) ); then
    log "Node.js upgrade failed. Please install Node.js >= ${NODE_MIN_MAJOR}.${NODE_MIN_MINOR}.x manually."
    exit 1
  fi

  require_command npm
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

  require_command "${BACKEND_PYTHON_BIN}"

  local venv_python="${backend_dir}/.venv/bin/python"
  local recreate_venv="false"
  if [[ -x "${venv_python}" ]]; then
    local current_mm
    current_mm="$("${venv_python}" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || true)"
    if [[ "${current_mm}" != "3.14" ]]; then
      log "Existing backend virtualenv uses Python ${current_mm:-unknown}; recreating with Python 3.14"
      recreate_venv="true"
    fi
  fi

  if [[ ! -d "${backend_dir}/.venv" || "${recreate_venv}" == "true" ]]; then
    rm -rf "${backend_dir}/.venv"
    "${BACKEND_PYTHON_BIN}" -m venv "${backend_dir}/.venv"
  fi

  local effective_mm
  effective_mm="$(${venv_python} -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || true)"
  if [[ "${effective_mm}" != "3.14" ]]; then
    log "Backend venv must use Python 3.14, but resolved ${effective_mm:-unknown}."
    log "Check BACKEND_PYTHON_BIN and python3.14 installation."
    exit 1
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
  (
    cd "${app_dir}" && \
    NPM_CONFIG_PRODUCTION=false npm ci --include=dev && \
    npm run build
  )

  if [[ ! -d "${app_dir}/dist" ]]; then
    log "Build output missing for ${app_dir##*/}: ${app_dir}/dist does not exist"
    exit 1
  fi
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

    run_as_root systemctl stop "${unit}" || true
    run_as_root systemctl disable "${unit}" || true
    run_as_root systemctl unmask "${unit}" || true

    # Remove legacy/masked artifacts so the new unit is always authoritative.
    run_as_root rm -f "/etc/systemd/system/${unit}" || true
    run_as_root rm -f "/run/systemd/system/${unit}" || true
    run_as_root rm -f "/lib/systemd/system/${unit}" || true
    run_as_root rm -f "/usr/lib/systemd/system/${unit}" || true
    run_as_root rm -rf "/etc/systemd/system/${unit}.d" || true
    run_as_root rm -rf "/run/systemd/system/${unit}.d" || true
    run_as_root rm -f "/etc/systemd/system/multi-user.target.wants/${unit}" || true

    run_as_root cp "${source_file}" "${target_file}"
  done

  run_as_root systemctl daemon-reload

  for unit in "${SYSTEMD_UNITS[@]}"; do
    run_as_root systemctl enable "${unit}"
    run_as_root systemctl restart "${unit}"
  done
}

verify_services_healthy() {
  log "Verifying services are active and listening on expected ports"

  require_command ss

  for unit in "${SYSTEMD_UNITS[@]}"; do
    local port="${SERVICE_PORTS[${unit}]}"

    # Give each service a short grace period to bind.
    local service_ready="false"
    for _ in {1..20}; do
      if run_as_root systemctl is-active --quiet "${unit}"; then
        service_ready="true"
        break
      fi
      sleep 1
    done

    if [[ "${service_ready}" != "true" ]]; then
      log "Service failed to become active: ${unit}"
      run_as_root systemctl status "${unit}" --no-pager || true
      exit 1
    fi

    local port_ready="false"
    for _ in {1..20}; do
      if run_as_root ss -ltn "sport = :${port}" | grep -q ":${port}"; then
        port_ready="true"
        break
      fi
      sleep 1
    done

    if [[ "${port_ready}" != "true" ]]; then
      log "Service ${unit} is active but port ${port} is not listening"
      run_as_root systemctl status "${unit}" --no-pager || true
      run_as_root journalctl -u "${unit}" -n 100 --no-pager || true
      exit 1
    fi
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

certificate_covers_required_domains() {
  if [[ ! -f "${LE_FULLCHAIN_PATH}" ]]; then
    return 1
  fi

  local cert_text
  cert_text="$(run_as_root openssl x509 -in "${LE_FULLCHAIN_PATH}" -noout -text 2>/dev/null || true)"
  [[ -n "${cert_text}" ]] || return 1

  grep -q "DNS:jotigames.nl" <<<"${cert_text}" || return 1
  grep -q "DNS:www.jotigames.nl" <<<"${cert_text}" || return 1
  grep -q "DNS:admin.jotigames.nl" <<<"${cert_text}" || return 1
}

ensure_https_certificates() {
  require_command openssl

  if [[ -f "${LE_FULLCHAIN_PATH}" && -f "${LE_PRIVKEY_PATH}" ]] && certificate_covers_required_domains; then
    log "Let's Encrypt certs already present and cover all required domains"
    return
  fi

  if [[ -f "${LE_FULLCHAIN_PATH}" && -f "${LE_PRIVKEY_PATH}" ]]; then
    log "Existing certificate is present but does not include all required domains; requesting expanded certificate"
  fi

  if [[ -z "${CERTBOT_EMAIL}" ]]; then
    log "Let's Encrypt certs are missing/incomplete and CERTBOT_EMAIL is not set; keeping current nginx config"
    return
  fi

  log "Requesting Let's Encrypt certificate for jotigames.nl, www.jotigames.nl and admin.jotigames.nl"
  run_as_root mkdir -p /var/www/letsencrypt
  run_as_root certbot certonly --webroot \
    --non-interactive \
    --agree-tos \
    --email "${CERTBOT_EMAIL}" \
    --cert-name jotigames.nl \
    --expand \
    -w /var/www/letsencrypt \
    -d jotigames.nl \
    -d www.jotigames.nl \
    -d admin.jotigames.nl

  if [[ -f "${LE_FULLCHAIN_PATH}" && -f "${LE_PRIVKEY_PATH}" ]] && certificate_covers_required_domains; then
    log "Let's Encrypt certificate obtained successfully"
  else
    log "Let's Encrypt certificate request completed but required domain coverage is still missing"
    exit 1
  fi
}

main() {
  require_command git
  ensure_nodejs_min_version
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
  verify_services_healthy
  install_nginx_reverse_proxy
  ensure_https_certificates
  install_nginx_reverse_proxy
  ensure_certbot_auto_renew

  log "Deployment/update complete"
}

main "$@"
