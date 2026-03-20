#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEMPLATE_FILE="${SCRIPT_DIR}/crontab.template"

if [[ ! -f "${TEMPLATE_FILE}" ]]; then
  echo "Template not found: ${TEMPLATE_FILE}" >&2
  exit 1
fi

mkdir -p "${WORKSPACE_ROOT}/system/logs"

MANAGED_BEGIN="# >>> JOTIGAMES SYSTEM CRON BEGIN >>>"
MANAGED_END="# <<< JOTIGAMES SYSTEM CRON END <<<"

resolved_template="$(sed "s|__WORKSPACE_ROOT__|${WORKSPACE_ROOT}|g" "${TEMPLATE_FILE}")"

current_crontab=""
if crontab -l >/dev/null 2>&1; then
  current_crontab="$(crontab -l)"
fi

cleaned_crontab="$(printf '%s\n' "${current_crontab}" | awk -v begin="${MANAGED_BEGIN}" -v end="${MANAGED_END}" '
  $0 == begin { in_block=1; next }
  $0 == end { in_block=0; next }
  !in_block { print }
')"

new_crontab_content="$(cat <<EOF
${cleaned_crontab}
${MANAGED_BEGIN}
${resolved_template}
${MANAGED_END}
EOF
)"

# Trim leading blank lines for neatness
new_crontab_content="$(printf '%s\n' "${new_crontab_content}" | sed '/./,$!d')"

printf '%s\n' "${new_crontab_content}" | crontab -

echo "Installed JotiGames managed cron block."
echo "Workspace root: ${WORKSPACE_ROOT}"
echo "Check with: crontab -l"
