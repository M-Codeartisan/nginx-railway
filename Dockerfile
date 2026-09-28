FROM nginx:alpine

USER root

# apache2-utils supplies htpasswd, used to derive the basic-auth file at boot;
# curl, tar and unzip fetch and unpack SITE_SOURCE_URL.
RUN apk add --no-cache apache2-utils ca-certificates curl tar unzip \
    && rm -f /etc/nginx/conf.d/default.conf \
    && mkdir -p /etc/nginx/railway-routes /data/www /data/cache

COPY docker-entrypoint.d/40-railway-nginx.sh /docker-entrypoint.d/40-railway-nginx.sh
COPY www /opt/default-site

# Syntax-check the boot script and assert every tool it shells out to exists,
# so a typo fails the build in seconds instead of crash-looping a container.
RUN chmod 0755 /docker-entrypoint.d/40-railway-nginx.sh \
    && sh -n /docker-entrypoint.d/40-railway-nginx.sh \
    && command -v htpasswd \
    && command -v envsubst \
    && command -v curl \
    && command -v unzip \
    && tar --version | head -1 \
    && nginx -v

EXPOSE 8080
