#!/usr/bin/env bash
# Auto-configure AWX (credential, inventory + linux_cluster group, project,
# execution environment, job template, schedule) to run ansible/patch.yml
# against the lab fleet, via the AWX REST API.
#
# Requires: curl, jq. AWX must already be up (docker compose --profile awx up -d)
# and finished its first-boot migrations (check: docker compose logs -f awx-web).
# Set AWX_ADMIN_PASSWORD if you changed the admin password.
#
# Usage: ./scripts/awx-configure.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

AWX_URL="${AWX_URL:-http://localhost:8050}"
AWX_USER="${AWX_ADMIN_USER:-admin}"
AWX_PASS="${AWX_ADMIN_PASSWORD:-adminpassword}"
PROJECT_DIR_NAME="linux-patch-management"
EE_NAME="AWX EE (23.8.1)"   # registered by awx-config/migrate.sh from settings.py

api() {
  local method="$1" path="$2" data="${3:-}"
  if [[ -n "$data" ]]; then
    curl -sS -u "${AWX_USER}:${AWX_PASS}" -H "Content-Type: application/json" \
      -X "$method" "${AWX_URL}/api/v2${path}" -d "$data"
  else
    curl -sS -u "${AWX_USER}:${AWX_PASS}" -H "Content-Type: application/json" \
      -X "$method" "${AWX_URL}/api/v2${path}"
  fi
}

echo "==> Waiting for AWX API to respond..."
for _ in $(seq 1 60); do
  if curl -sSf -u "${AWX_USER}:${AWX_PASS}" "${AWX_URL}/api/v2/ping/" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

# No copy step: docker-compose.yml bind-mounts ./ansible read-only at
# /var/lib/awx/projects/${PROJECT_DIR_NAME}, so AWX always sees the repo's
# current playbook.
if ! docker exec awx-task test -f "/var/lib/awx/projects/${PROJECT_DIR_NAME}/patch.yml"; then
  echo "ERROR: patch.yml not visible in awx-task - recreate it: docker compose --profile awx up -d --force-recreate awx-task" >&2
  exit 1
fi

ORG_ID=$(api GET "/organizations/?name=Default" | jq -r '.results[0].id')
echo "==> Using organization id ${ORG_ID}"

echo "==> Setting '${EE_NAME}' as the organization's default execution environment..."
EE_ID=$(api GET "/execution_environments/?name=$(jq -rn --arg n "${EE_NAME}" '$n|@uri')" | jq -r '.results[0].id // empty')
if [[ -z "${EE_ID}" ]]; then
  echo "ERROR: execution environment '${EE_NAME}' not found - check: docker compose logs awx-migrations" >&2
  exit 1
fi
api PATCH "/organizations/${ORG_ID}/" "$(jq -n --argjson ee "${EE_ID}" '{default_environment: $ee}')" >/dev/null
echo "    execution environment id ${EE_ID}"

echo "==> Creating machine credential ('Lab SSH Key')..."
CRED_TYPE_ID=$(api GET "/credential_types/?name=Machine" | jq -r '.results[0].id')
CRED_ID=$(api GET "/credentials/?name=Lab%20SSH%20Key" | jq -r '.results[0].id // empty')
if [[ -z "${CRED_ID}" ]]; then
  CRED_ID=$(api POST "/credentials/" "$(jq -n \
    --arg name "Lab SSH Key" \
    --argjson org "${ORG_ID}" \
    --argjson ctype "${CRED_TYPE_ID}" \
    --rawfile key "${HOME}/.ssh/id_rsa_ansible" \
    '{name: $name, organization: $org, credential_type: $ctype, inputs: {username: "root", ssh_key_data: $key}}')" \
    | jq -r '.id')
fi
if [[ ! "${CRED_ID}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: failed to create 'Lab SSH Key' credential (is ~/.ssh/id_rsa_ansible a valid private key?)" >&2
  exit 1
fi
echo "    credential id ${CRED_ID}"

echo "==> Creating inventory ('Local Multi-Distro Fleet') and hosts..."
INV_ID=$(api GET "/inventories/?name=Local%20Multi-Distro%20Fleet" | jq -r '.results[0].id // empty')
if [[ -z "${INV_ID}" ]]; then
  INV_ID=$(api POST "/inventories/" "$(jq -n --argjson org "${ORG_ID}" \
    '{name: "Local Multi-Distro Fleet", organization: $org}')" | jq -r '.id')
fi
# patch.yml targets the linux_cluster group (same as ansible/inventory*.ini).
GROUP_ID=$(api GET "/inventories/${INV_ID}/groups/?name=linux_cluster" | jq -r '.results[0].id // empty')
if [[ -z "${GROUP_ID}" ]]; then
  GROUP_ID=$(api POST "/inventories/${INV_ID}/groups/" '{"name": "linux_cluster"}' | jq -r '.id')
fi
for host in rhel-node ubuntu-node debian-node; do
  HOST_ID=$(api GET "/inventories/${INV_ID}/hosts/?name=${host}" | jq -r '.results[0].id // empty')
  if [[ -z "${HOST_ID}" ]]; then
    HOST_ID=$(api POST "/inventories/${INV_ID}/hosts/" "$(jq -n --arg name "${host}" \
      '{name: $name, variables: ("ansible_host: " + $name + "\nansible_user: root\n")}')" | jq -r '.id')
  fi
  # Associating an already-associated host is a no-op.
  api POST "/groups/${GROUP_ID}/hosts/" "$(jq -n --argjson h "${HOST_ID}" '{id: $h}')" >/dev/null
done
echo "    inventory id ${INV_ID}, group linux_cluster id ${GROUP_ID}"

echo "==> Creating manual project ('Linux Patch Management')..."
PROJ_ID=$(api GET "/projects/?name=Linux%20Patch%20Management" | jq -r '.results[0].id // empty')
if [[ -z "${PROJ_ID}" ]]; then
  PROJ_ID=$(api POST "/projects/" "$(jq -n --argjson org "${ORG_ID}" --arg path "${PROJECT_DIR_NAME}" \
    '{name: "Linux Patch Management", organization: $org, scm_type: "", local_path: $path}')" | jq -r '.id')
fi
echo "    project id ${PROJ_ID}"

echo "==> Creating job template ('Weekly Enterprise Linux Patching')..."
JT_ID=$(api GET "/job_templates/?name=Weekly%20Enterprise%20Linux%20Patching" | jq -r '.results[0].id // empty')
if [[ -z "${JT_ID}" ]]; then
  JT_ID=$(api POST "/job_templates/" "$(jq -n \
    --argjson inv "${INV_ID}" --argjson proj "${PROJ_ID}" \
    '{name: "Weekly Enterprise Linux Patching", job_type: "run", inventory: $inv, project: $proj, playbook: "patch.yml", become_enabled: true, ask_variables_on_launch: false}')" \
    | jq -r '.id')
fi
# Outside the create branch so a re-run also repairs an existing template
# (re-associating an already-attached credential is a no-op). Prompting for
# the limit lets a manual launch target a single node.
api POST "/job_templates/${JT_ID}/credentials/" "$(jq -n --argjson c "${CRED_ID}" '{id: $c}')" >/dev/null
api PATCH "/job_templates/${JT_ID}/" "$(jq -n --argjson ee "${EE_ID}" \
  '{execution_environment: $ee, ask_limit_on_launch: true}')" >/dev/null
echo "    job template id ${JT_ID}"

echo "==> Creating weekly schedule (Sundays 02:00 UTC)..."
SCHED_ID=$(api GET "/job_templates/${JT_ID}/schedules/?name=Weekly%20Sunday%20Patch%20Window" | jq -r '.results[0].id // empty')
if [[ -z "${SCHED_ID}" ]]; then
  DTSTART=$(date -u +"%Y%m%dT020000Z")
  api POST "/job_templates/${JT_ID}/schedules/" "$(jq -n --arg dtstart "${DTSTART}" \
    '{name: "Weekly Sunday Patch Window", rrule: ("DTSTART:" + $dtstart + " RRULE:FREQ=WEEKLY;BYDAY=SU")}')" >/dev/null
fi

echo "==> Done. Open ${AWX_URL} (user: ${AWX_USER}) and launch 'Weekly Enterprise Linux Patching' to test."
echo "==> Or launch it right now without waiting for the schedule: ./scripts/awx-run-now.sh"
