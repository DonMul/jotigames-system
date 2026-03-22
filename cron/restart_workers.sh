#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${WORKSPACE_ROOT}/backend/.venv/bin/python"
LOG_DIR="${WORKSPACE_ROOT}/system/logs"

mkdir -p "${LOG_DIR}"

if [[ ! -x "${PYTHON_BIN}" ]]; then
  echo "Python venv binary not found or not executable: ${PYTHON_BIN}" >&2
  exit 1
fi

start_worker() {
  local worker_name="$1"
  local script_path="$2"
  local lock_file="$3"
  local log_file="$4"

  pkill -f "${script_path}" >/dev/null 2>&1 || true

  nohup /usr/bin/flock -n "${lock_file}" \
    "${PYTHON_BIN}" "${script_path}" \
    >> "${log_file}" 2>&1 &

  disown || true
  echo "Started ${worker_name}"
}

start_worker \
  "auto_resolve_pending_actions" \
  "${WORKSPACE_ROOT}/backend/scripts/auto_resolve_pending_actions.py" \
  "${LOG_DIR}/auto_resolve_pending_actions.lock" \
  "${LOG_DIR}/auto_resolve_pending_actions.log"

start_worker \
  "birds_of_prey_auto_drop_eggs" \
  "${WORKSPACE_ROOT}/backend/scripts/birds_of_prey_auto_drop_eggs.py" \
  "${LOG_DIR}/birds_of_prey_auto_drop_eggs.lock" \
  "${LOG_DIR}/birds_of_prey_auto_drop_eggs.log"

echo "Background workers restarted without reboot."
