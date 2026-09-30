#!/usr/bin/env bash
# Bring up the multi-distro patch-management lab (target nodes only).
#
# Usage:
#   ./scripts/setup.sh            # build + start rhel/ubuntu/debian nodes
#   ./scripts/setup.sh --with-awx # also build + start the AWX control plane
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SSH_KEY="${HOME}/.ssh/id_rsa_ansible"

echo "==> Checking for local SSH key pair..."
if [[ ! -f "${SSH_KEY}" ]]; then
  echo "    No key found at ${SSH_KEY}, generating one (lab use only)."
  ssh-keygen -t rsa -b 4096 -N "" -f "${SSH_KEY}"
else
  echo "    Found existing key at ${SSH_KEY}."
fi

echo "==> Staging public key into build context..."
cp "${SSH_KEY}.pub" "${REPO_ROOT}/id_rsa_ansible.pub"

echo "==> Building and starting fleet nodes (rhel-node, ubuntu-node, debian-node)..."
docker compose up --build -d rhel-node ubuntu-node debian-node

if [[ "${1:-}" == "--with-awx" ]]; then
  echo "==> Starting AWX control plane (this can take a few minutes on first run)..."
  docker compose --profile awx up -d --build   # --build: awx-receptor image (docker/awx-receptor)
  echo "    AWX web UI will be available at http://localhost:8050 once migrations finish."
  echo "    Tail startup with: docker compose logs -f awx-web"
  echo "    Then provision AWX with: ./scripts/awx-configure.sh"
fi

echo "==> Waiting for SSH to come up on fleet nodes..."
for port in 2221 2222 2223; do
  for _ in $(seq 1 30); do
    if nc -z 127.0.0.1 "${port}" 2>/dev/null; then
      break
    fi
    sleep 1
  done
done

echo "==> Fleet is up. Verify connectivity with:"
echo "    ansible linux_cluster -i ansible/inventory.ini -m ping"
echo "==> Run the patch playbook with:"
echo "    ansible-playbook -i ansible/inventory.ini ansible/patch.yml"
