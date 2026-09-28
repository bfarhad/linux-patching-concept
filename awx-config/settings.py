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
CSRF_TRUSTED_ORIGINS = ['http://localhost:8050', 'http://127.0.0.1:8050']

CLUSTER_HOST_ID = 'awx'
AWX_ISOLATION_BASE_PATH = '/tmp'

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
