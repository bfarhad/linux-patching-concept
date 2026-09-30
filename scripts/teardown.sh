#!/usr/bin/env bash
# Tear down the lab. Pass --volumes to also wipe AWX's data volumes (postgres,
# projects, job dirs, and the ~1.5 GB execution environment image cache).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ "${1:-}" == "--volumes" ]]; then
  docker compose --profile awx down -v
else
  docker compose --profile awx down
fi

rm -f "${REPO_ROOT}/id_rsa_ansible.pub"
echo "==> Lab stopped."
