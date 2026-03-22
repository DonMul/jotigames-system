#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="/var/www/jotigames.nl"
SYSTEM_REPO_URL="${SYSTEM_REPO_URL:-git@github.com:DonMul/jotigames-system.git}"
SYSTEM_REPO_DIR="${ROOT_DIR}/system"
SYSTEM_REPO_BRANCH="${SYSTEM_REPO_BRANCH:-}"

log() {
  echo "[bootstrap] $*"
}

run_as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

require_apt_package() {
  local package_name="$1"
  if dpkg -s "${package_name}" >/dev/null 2>&1; then
    return
  fi
  run_as_root apt-get install -y "${package_name}"
}

require_python_314() {
  if command -v python3.14 >/dev/null 2>&1; then
    return
  fi

  if run_as_root apt-get install -y python3.14 python3.14-venv; then
    return
  fi

  log "python3.14 not available via apt, building Python 3.14.0 from source"

  run_as_root apt-get install -y \
    build-essential \
    zlib1g-dev \
    libncurses5-dev \
    libgdbm-dev \
    libnss3-dev \
    libssl-dev \
    libreadline-dev \
    libffi-dev \
    libsqlite3-dev \
    libbz2-dev \
    liblzma-dev \
    libncursesw5-dev \
    tk-dev \
    uuid-dev \
    wget

  local build_root="/tmp/jotigames-python-build"
  local tarball="${build_root}/Python-3.14.0.tgz"
  local source_dir="${build_root}/Python-3.14.0"

  run_as_root rm -rf "${build_root}"
  run_as_root mkdir -p "${build_root}"

  (
    cd "${build_root}"
    wget https://www.python.org/ftp/python/3.14.0/Python-3.14.0.tgz
    tar -xvf Python-3.14.0.tgz
    cd Python-3.14.0
    run_as_root ./configure --enable-optimizations
    run_as_root make -j 2
    run_as_root make altinstall
  )

  run_as_root rm -rf "${build_root}"

  if ! command -v python3.14 >/dev/null 2>&1; then
    log "Python 3.14 source install failed."
    exit 1
  fi
}

ensure_nodejs_20() {
  local current_major="0"
  if command -v node >/dev/null 2>&1; then
    current_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  fi

  if [[ "${current_major}" =~ ^[0-9]+$ ]] && (( current_major >= 20 )); then
    if ! command -v npm >/dev/null 2>&1; then
      run_as_root apt-get install -y npm
    fi
    return
  fi

  log "Installing/upgrading Node.js 20 via NodeSource"
  run_as_root bash -lc "curl -fsSL https://deb.nodesource.com/setup_20.x | bash -"
  run_as_root apt-get install -y nodejs

  if ! command -v node >/dev/null 2>&1; then
    log "Node.js install failed."
    exit 1
  fi
}

bootstrap_packages() {
  if ! command -v apt-get >/dev/null 2>&1; then
    log "This script currently supports Debian/Ubuntu servers (apt-get required)."
    exit 1
  fi

  log "Installing required system packages"
  run_as_root apt-get update -y

  require_apt_package ca-certificates
  require_apt_package curl
  require_apt_package wget
  require_apt_package git
  require_apt_package openssh-client
  require_python_314
  require_apt_package python3-pip
  ensure_nodejs_20
  require_apt_package nginx
  require_apt_package certbot
  require_apt_package python3-certbot-nginx
  require_apt_package util-linux
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

checkout_or_update_system_repo() {
  run_as_root mkdir -p "${ROOT_DIR}"

  if [[ ! -d "${SYSTEM_REPO_DIR}/.git" ]]; then
    log "Cloning system repo to ${SYSTEM_REPO_DIR}"
    run_as_root git clone "${SYSTEM_REPO_URL}" "${SYSTEM_REPO_DIR}"
  else
    log "Updating system repo"
    run_as_root git -C "${SYSTEM_REPO_DIR}" fetch --all --prune
  fi

  local branch
  if [[ -n "${SYSTEM_REPO_BRANCH}" ]]; then
    branch="${SYSTEM_REPO_BRANCH}"
  else
    branch="$(resolve_default_branch "${SYSTEM_REPO_DIR}")"
  fi

  run_as_root git -C "${SYSTEM_REPO_DIR}" checkout "${branch}"
  run_as_root git -C "${SYSTEM_REPO_DIR}" pull --ff-only origin "${branch}"
}

run_deploy() {
  local deploy_script="${SYSTEM_REPO_DIR}/deploy_update.sh"
  if [[ ! -f "${deploy_script}" ]]; then
    log "Missing deploy script: ${deploy_script}"
    exit 1
  fi

  run_as_root chmod +x "${deploy_script}"
  log "Running deployment script"
  run_as_root bash "${deploy_script}"
}

main() {
  bootstrap_packages
  checkout_or_update_system_repo
  run_deploy
  log "Server bootstrap complete"
}

main "$@"
