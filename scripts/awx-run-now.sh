#!/usr/bin/env bash
# Manually launch the "Weekly Enterprise Linux Patching" job template right
# now, regardless of its schedule. A Schedule in AWX is just an additional
# trigger - it never prevents launching a Job Template by hand, via the UI
# ("Launch" button) or, as here, via the API.
#
# The first run pulls the execution environment image (~1.5 GB) inside
# awx-receptor, so it sits in "running" for a few minutes before any output.
#
# Usage: ./scripts/awx-run-now.sh
#        LIMIT=debian-node ./scripts/awx-run-now.sh   # patch a single node
set -euo pipefail

AWX_URL="${AWX_URL:-http://localhost:8050}"
AWX_USER="${AWX_ADMIN_USER:-admin}"
AWX_PASS="${AWX_ADMIN_PASSWORD:-adminpassword}"

JT_ID=$(curl -sS -u "${AWX_USER}:${AWX_PASS}" \
  "${AWX_URL}/api/v2/job_templates/?name=Weekly%20Enterprise%20Linux%20Patching" \
  | jq -r '.results[0].id // empty')

if [[ -z "${JT_ID}" ]]; then
  echo "Job template 'Weekly Enterprise Linux Patching' not found. Run scripts/awx-configure.sh first." >&2
  exit 1
fi

LAUNCH_BODY=$(jq -n --arg limit "${LIMIT:-}" 'if $limit == "" then {} else {limit: $limit} end')
JOB_URL=$(curl -sS -u "${AWX_USER}:${AWX_PASS}" -H "Content-Type: application/json" \
  -X POST "${AWX_URL}/api/v2/job_templates/${JT_ID}/launch/" -d "${LAUNCH_BODY}" \
  | jq -r '.url')

echo "==> Launched job: ${AWX_URL}${JOB_URL}"
echo "==> Follow progress with: curl -u ${AWX_USER}:*** ${AWX_URL}${JOB_URL}stdout/?format=txt"
echo "==> Or watch it in the UI: Views -> Jobs. The JSON patch report is on the job's Artifacts tab."
