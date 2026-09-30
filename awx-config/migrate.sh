#!/usr/bin/env bash
set -euo pipefail

echo "==> Running database migrations (retries until Postgres is reachable)..."
until awx-manage migrate --noinput; do
  echo "    ...migrate failed, retrying in 5s"
  sleep 5
done

echo "==> Ensuring admin superuser exists..."
DJANGO_SUPERUSER_USERNAME="${AWX_ADMIN_USER:-admin}" \
DJANGO_SUPERUSER_PASSWORD="${AWX_ADMIN_PASSWORD:-adminpassword}" \
DJANGO_SUPERUSER_EMAIL="admin@example.com" \
awx-manage createsuperuser --noinput || true

echo "==> Loading preload data (demo org/credential, needs the superuser above)..."
awx-manage create_preload_data || true

echo "==> Registering this instance..."
awx-manage provision_instance --hostname="${CLUSTER_HOST_ID:-awx}" || true
# AWX's task manager requires a "controlplane" group (the operator creates it).
awx-manage register_queue --queuename=controlplane --hostnames="${CLUSTER_HOST_ID:-awx}" || true
awx-manage register_queue --queuename=default --hostnames="${CLUSTER_HOST_ID:-awx}" || true

echo "==> Registering default execution environments..."
awx-manage register_default_execution_environments || true

echo "==> Migrations complete."
