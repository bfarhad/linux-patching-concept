import os

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': os.environ.get('DATABASE_NAME', 'awx'),
        'USER': os.environ.get('DATABASE_USER', 'awx'),
        'PASSWORD': os.environ.get('DATABASE_PASSWORD', 'awxpassword'),
        'HOST': os.environ.get('DATABASE_HOST', 'awx-postgres'),
        'PORT': os.environ.get('DATABASE_PORT', '5432'),
    }
}

SECRET_KEY = os.environ.get('AWX_SECRET_KEY', 'please-change-me-lab-only')

ALLOWED_HOSTS = ['*']
CSRF_TRUSTED_ORIGINS = [
    'http://localhost:8050',
    'http://127.0.0.1:8050',
    # OrbStack's automatic HTTPS hostname for the awx-web container
    'https://awx-web.linux-patching-concept.orb.local',
]

CLUSTER_HOST_ID = 'awx'
# Job private data dirs (awx_<id>_*). AWX 23.x only sends the run parameters
# to a *local* receptor work unit, not the directory itself, so awx-task and
# awx-receptor must see the same files at the same path: the awx_job_data
# volume is mounted here in both (docker-compose.yml).
AWX_ISOLATION_BASE_PATH = '/var/lib/awx/job_data'

# The base image defaults to a unix socket at /var/run/redis/redis.sock,
# which is awkward to share safely between the separate awx-web/awx-task
# containers under plain docker compose. Use TCP to the awx-redis service
# instead - simpler and just as fine for a lab.
REDIS_TCP_URL = 'redis://awx-redis:6379'
BROKER_URL = REDIS_TCP_URL
CACHES = {'default': {'BACKEND': 'awx.main.cache.AWXRedisCache', 'LOCATION': REDIS_TCP_URL + '/1'}}
CHANNEL_LAYERS = {
    'default': {
        'BACKEND': 'channels_redis.core.RedisChannelLayer',
        'CONFIG': {'hosts': [REDIS_TCP_URL], 'capacity': 10000, 'group_expiry': 157784760},
    }
}
# --- Job execution ----------------------------------------------------------
# Outside Kubernetes, AWX runs every job as `podman run <EE image> ...` on the
# execution node, which here is the awx-receptor sidecar (a privileged awx-ee
# image with podman added, see docker/awx-receptor/). IS_K8S must stay False:
# on 23.x it only skips podman for Kubernetes container groups, and it makes
# the dispatcher rewrite receptor.conf with the operator's TLS/K8S template.
#
# AWX's default here is slirp4netns, which would cut job containers off from
# lab-net. Host networking shares awx-receptor's network namespace, so the
# node names resolve through Docker DNS.
DEFAULT_CONTAINER_RUN_OPTIONS = ['--network', 'host']

# Registered by `awx-manage register_default_execution_environments`
# (migrate.sh). Pinned to the AWX version instead of :latest. Pulled once by
# podman into the awx_receptor_containers volume.
CONTROL_PLANE_EXECUTION_ENVIRONMENT = 'quay.io/ansible/awx-ee:23.8.1'
GLOBAL_JOB_EXECUTION_ENVIRONMENTS = [
    {'name': 'AWX EE (23.8.1)', 'image': 'quay.io/ansible/awx-ee:23.8.1'},
]
