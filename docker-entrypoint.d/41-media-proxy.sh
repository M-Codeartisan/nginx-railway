#!/bin/sh
# Serve an S3 bucket same-origin under a path on this host.
#
# Runs after 40-railway-nginx.sh, which has already emptied and repopulated the
# route directory and rendered the server block that includes it. Nothing in
# that script is modified, so the eject stays reconcilable with upstream.
#
# WHY A PROXY RATHER THAN BUCKET URLS
# A service worker fetching cross-origin media without CORS receives an opaque
# response: no readable status, and a storage quota charge of roughly 7 MB per
# entry in Chrome regardless of the file's real size. A few hundred cached
# objects exhaust the quota, the browser evicts the cache, and any offline
# guarantee built on it is gone. The unreadable status is worse in practice —
# a cached 404 is indistinguishable from a successful fetch.
#
# Serving from this origin makes those responses `basic`: real status, real
# size, no padding. For the same reason media must never move to a media.*
# subdomain, which is same-site but cross-origin.
# Deliberately NOT "set -e": the stock nginx entrypoint aborts the container if
# any /docker-entrypoint.d script exits non-zero, so an error here would take the
# whole site down rather than just disabling the media proxy. Every path below
# ends in exit 0.
set -u

ME="[media-proxy]"
log() { echo "$ME $*"; }

CONF_D=/etc/nginx/conf.d
ROUTE_D=/etc/nginx/railway-routes
HEADERS=/etc/nginx/railway-security-headers.conf
HTTP_CONF="$CONF_D/00-railway-http.conf"
MEDIA_CONF="$ROUTE_D/90-media.conf"

MEDIA_S3_HOST="${MEDIA_S3_HOST:-}"

if [ -z "$MEDIA_S3_HOST" ]; then
  log "disabled (set MEDIA_S3_HOST to enable)"
  exit 0
fi

MEDIA_PATH="${MEDIA_PATH:-/media}"
MEDIA_CACHE_PATH="${MEDIA_CACHE_PATH:-/data/media-cache}"
MEDIA_CACHE_MAX_SIZE="${MEDIA_CACHE_MAX_SIZE:-2g}"
MEDIA_CACHE_VALID="${MEDIA_CACHE_VALID:-30d}"
MEDIA_EXPIRES="${MEDIA_EXPIRES:-31536000}"

# Normalise to a leading slash and no trailing slash.
case "$MEDIA_PATH" in
  /*) ;;
  *) MEDIA_PATH="/$MEDIA_PATH" ;;
esac
MEDIA_PATH="${MEDIA_PATH%/}"
[ -n "$MEDIA_PATH" ] || MEDIA_PATH=/media

case "$MEDIA_PATH" in
  *[!A-Za-z0-9._/~-]*)
    log "ERROR: MEDIA_PATH '$MEDIA_PATH' has unsupported characters; disabling"
    exit 0 ;;
esac

case "$MEDIA_S3_HOST" in
  http://*|https://*)
    log "ERROR: MEDIA_S3_HOST must be a bare hostname, not a URL; disabling"
    exit 0 ;;
  *[!A-Za-z0-9.-]*)
    log "ERROR: MEDIA_S3_HOST '$MEDIA_S3_HOST' is not a valid hostname; disabling"
    exit 0 ;;
esac

# Reuse the resolver 40-railway-nginx.sh settled on. Railway's is IPv6 and is
# already bracketed by the stock 15-local-resolvers.envsh hook.
RESOLVERS="${NGINX_LOCAL_RESOLVERS:-}"
if [ -z "$RESOLVERS" ]; then
  RESOLVERS=$(awk 'BEGIN{ORS=" "} $1=="nameserver" {if ($2 ~ ":") {print "["$2"]"} else {print $2}}' /etc/resolv.conf)
  RESOLVERS="${RESOLVERS% }"
fi
[ -n "$RESOLVERS" ] || RESOLVERS="[fd12::10]"

if ! mkdir -p "$MEDIA_CACHE_PATH" 2>/dev/null; then
  log "ERROR: cannot create cache directory $MEDIA_CACHE_PATH; disabling"
  exit 0
fi
chown -R nginx:nginx "$MEDIA_CACHE_PATH" 2>/dev/null || true

# Restored verbatim if the rendered configuration turns out to be invalid.
HTTP_BACKUP="$(mktemp)" || { log "ERROR: cannot create a temporary file; disabling"; exit 0; }
cp "$HTTP_CONF" "$HTTP_BACKUP" 2>/dev/null || true

# ---------------------------------------------------------------- http context
# proxy_cache_path is only valid at http level. 40-railway-nginx.sh rewrites
# this file from scratch on every boot, so appending here is idempotent.
cat >> "$HTTP_CONF" <<MEDIA_HTTP

# Media proxy cache (41-media-proxy.sh). Deliberately ephemeral: it spares
# repeat round trips to S3, it is not a durability mechanism.
proxy_cache_path $MEDIA_CACHE_PATH levels=1:2 keys_zone=media_cache:10m max_size=$MEDIA_CACHE_MAX_SIZE inactive=30d use_temp_path=off;
MEDIA_HTTP

# -------------------------------------------------------------- server context
# "^~" makes this a prefix match that wins outright over regex locations, so the
# static-asset block in the rendered server config cannot capture /media/*.webp
# before this one sees it.
cat > "$MEDIA_CONF" <<MEDIA_SERVER
location ^~ $MEDIA_PATH/ {
    limit_except GET HEAD { deny all; }

    # proxy_pass with a variable defers DNS to request time; without a resolver
    # every request fails.
    resolver $RESOLVERS valid=300s;
    resolver_timeout 5s;

    set \$media_upstream "https://$MEDIA_S3_HOST";

    rewrite ^$MEDIA_PATH/(.*)\$ /\$1 break;
    proxy_pass \$media_upstream\$uri\$is_args\$args;
    proxy_http_version 1.1;

    # Without SNI the handshake presents the wrong name and S3 answers with a
    # certificate error, which reads as a bucket problem rather than an nginx one.
    proxy_ssl_server_name on;
    proxy_ssl_name        $MEDIA_S3_HOST;
    proxy_ssl_verify      on;
    proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
    proxy_ssl_verify_depth 3;

    # Virtual-hosted-style addressing needs the bucket as Host; forwarding the
    # client's Host returns 404 from S3.
    proxy_set_header Host          $MEDIA_S3_HOST;
    proxy_set_header Authorization "";
    proxy_set_header Cookie        "";

    proxy_hide_header x-amz-id-2;
    proxy_hide_header x-amz-request-id;
    proxy_hide_header x-amz-version-id;
    proxy_hide_header x-amz-server-side-encryption;
    proxy_hide_header Set-Cookie;
    proxy_hide_header Cache-Control;
    proxy_ignore_headers Set-Cookie Cache-Control;

    proxy_cache                   media_cache;
    proxy_cache_key               \$uri;
    proxy_cache_valid             200 $MEDIA_CACHE_VALID;
    proxy_cache_valid             404 1m;
    proxy_cache_lock              on;
    proxy_cache_background_update on;

    # Keep serving what we hold if S3 hiccups. This covers the one dangerous
    # overlap: a browser restarting with an empty cache while the bucket is
    # unreachable.
    proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;

    proxy_buffering on;
    proxy_read_timeout 30s;

    # Safe only because derivative filenames are content-addressed: the bytes
    # behind a URL never change.
    add_header Cache-Control "public, max-age=$MEDIA_EXPIRES, immutable" always;
    add_header X-Cache-Status \$upstream_cache_status always;
    include $HEADERS;

    # S3 answers 403, not 404, for a missing object when the bucket denies
    # ListBucket. Normalise it so a client can tell absent from forbidden.
    proxy_intercept_errors on;
    error_page 403 404 = @media_missing;
}

location @media_missing {
    internal;
    access_log off;
    default_type text/plain;
    add_header Cache-Control "no-store" always;
    return 404 "media not found\n";
}
MEDIA_SERVER

# 40-railway-nginx.sh validated the config before we appended to it, so re-check
# here rather than letting a bad render crash-loop the container.
if nginx -t; then
  log "serving $MEDIA_PATH/ from https://$MEDIA_S3_HOST (cache $MEDIA_CACHE_PATH, max $MEDIA_CACHE_MAX_SIZE)"
else
  log "ERROR: media proxy configuration failed nginx -t; reverting it and leaving the site up"
  rm -f "$MEDIA_CONF"
  cp "$HTTP_BACKUP" "$HTTP_CONF" 2>/dev/null || true
  if nginx -t >/dev/null 2>&1; then
    log "reverted; the rest of the configuration is valid"
  else
    log "WARNING: the configuration is still invalid after reverting, so the fault is not the media proxy"
  fi
fi

rm -f "$HTTP_BACKUP"
exit 0
