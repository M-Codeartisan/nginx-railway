#!/bin/sh
# Render the Railway-specific NGINX configuration from environment variables.
#
# Runs from the stock nginx image entrypoint, after 15-local-resolvers.envsh has
# exported NGINX_LOCAL_RESOLVERS and after 30-tune-worker-processes.sh has sized
# worker_processes from the cgroup quota.
set -eu

ME="[railway-nginx]"
log() { echo "$ME $*"; }

CONF_D=/etc/nginx/conf.d
ROUTE_D=/etc/nginx/railway-routes
HEADERS=/etc/nginx/railway-security-headers.conf
HTPASSWD=/etc/nginx/railway.htpasswd
SERVER_CONF="$CONF_D/10-railway-server.conf"

PORT="${PORT:-8080}"
SERVER_NAME="${SERVER_NAME:-_}"
SITE_ROOT="${SITE_ROOT:-/data/www}"
INDEX_FILES="${INDEX_FILES:-index.html index.htm}"
SPA_MODE="${SPA_MODE:-false}"
DIRECTORY_LISTING="${DIRECTORY_LISTING:-false}"
GZIP_ENABLED="${GZIP_ENABLED:-true}"
CLIENT_MAX_BODY_SIZE="${CLIENT_MAX_BODY_SIZE:-64m}"
ACCESS_LOG="${ACCESS_LOG:-true}"
CACHE_ENABLED="${CACHE_ENABLED:-false}"
CACHE_PATH="${CACHE_PATH:-/data/cache}"
CACHE_MAX_SIZE="${CACHE_MAX_SIZE:-1g}"
CACHE_VALID="${CACHE_VALID:-10m}"
HSTS_MAX_AGE="${HSTS_MAX_AGE:-31536000}"
STATIC_ASSET_EXPIRES="${STATIC_ASSET_EXPIRES:-30d}"
PROXY_ROUTES="${PROXY_ROUTES:-}"
PROXY_READ_TIMEOUT="${PROXY_READ_TIMEOUT:-60s}"
BASIC_AUTH_USER="${BASIC_AUTH_USER:-}"
BASIC_AUTH_PASSWORD="${BASIC_AUTH_PASSWORD:-}"
BASIC_AUTH_REALM="${BASIC_AUTH_REALM:-Restricted}"
RATE_LIMIT_RPS="${RATE_LIMIT_RPS:-}"
RATE_LIMIT_BURST="${RATE_LIMIT_BURST:-20}"
SITE_SOURCE_URL="${SITE_SOURCE_URL:-}"
SITE_SOURCE_STRIP="${SITE_SOURCE_STRIP:-0}"

case "$PORT" in
  ''|*[!0-9]*) log "PORT is not numeric ('$PORT'), falling back to 8080"; PORT=8080 ;;
esac

is_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

# Railway's resolver is IPv6 and nginx needs it bracketed; the stock
# 15-local-resolvers.envsh hook already brackets it for us.
RESOLVERS="${NGINX_LOCAL_RESOLVERS:-}"
if [ -z "$RESOLVERS" ]; then
  RESOLVERS=$(awk 'BEGIN{ORS=" "} $1=="nameserver" {if ($2 ~ ":") {print "["$2"]"} else {print $2}}' /etc/resolv.conf)
  RESOLVERS="${RESOLVERS% }"
fi
if [ -z "$RESOLVERS" ]; then
  RESOLVERS="[fd12::10]"
fi

# The stock welcome page shadows our server block. A build-layer delete does not
# always survive into the running container, so repeat it here every boot.
rm -f "$CONF_D/default.conf"
mkdir -p "$ROUTE_D" "$SITE_ROOT"
rm -f "$ROUTE_D"/*.conf 2>/dev/null || true

# ---------------------------------------------------------------- default site
if [ -z "$(ls -A "$SITE_ROOT" 2>/dev/null || true)" ]; then
  log "site root $SITE_ROOT is empty, seeding the shipped landing page"
  # BusyBox cp does not understand the GNU "src/." idiom, so glob explicitly.
  cp -a /opt/default-site/* "$SITE_ROOT"/ 2>/dev/null || true
  log "seeded: $(ls -A "$SITE_ROOT" | tr '\n' ' ')"
else
  log "serving existing content from $SITE_ROOT"
fi

# ----------------------------------------------------------- fetched site content
# SITE_SOURCE_URL unpacks a .tar.gz or .zip over the site root. The archive is
# fetched every boot but only unpacked when its contents have changed, so a
# redeploy picks up a new build of the site and an unchanged one costs nothing.
# It overlays rather than wiping: anything the archive does not contain is left alone.
if [ -n "$SITE_SOURCE_URL" ]; then
  site_marker="$SITE_ROOT/.railway-site-source"
  site_have=$(cat "$site_marker" 2>/dev/null || true)
  site_tmp=$(mktemp -d)
  mkdir -p "$site_tmp/x"
  if ! curl -fsSL --max-time 120 -o "$site_tmp/archive" "$SITE_SOURCE_URL"; then
    log "WARNING: could not download SITE_SOURCE_URL; keeping the existing site root"
  else
    site_want="$(md5sum "$site_tmp/archive" | cut -d' ' -f1)-$SITE_SOURCE_STRIP"
    if [ "$site_want" = "$site_have" ]; then
      log "SITE_SOURCE_URL is unchanged since the last unpack, skipping"
    else
      site_ok=true
      case "$SITE_SOURCE_URL" in
        *.zip|*.zip\?*)
          unzip -q -o "$site_tmp/archive" -d "$site_tmp/x" || site_ok=false ;;
        *)
          tar -xzf "$site_tmp/archive" -C "$site_tmp/x" --strip-components="$SITE_SOURCE_STRIP" || site_ok=false ;;
      esac
      if [ "$site_ok" = true ] && [ -n "$(ls -A "$site_tmp/x" 2>/dev/null || true)" ]; then
        cp -a "$site_tmp/x"/* "$SITE_ROOT"/
        printf '%s' "$site_want" > "$site_marker"
        log "unpacked SITE_SOURCE_URL into $SITE_ROOT: $(ls -A "$site_tmp/x" | tr '\n' ' ')"
      else
        log "WARNING: SITE_SOURCE_URL produced no files; keeping the existing site root"
      fi
    fi
  fi
  rm -rf "$site_tmp"
fi

# ------------------------------------------------------------------ basic auth
AUTH_LINE=""
if [ -n "$BASIC_AUTH_USER" ] && [ -n "$BASIC_AUTH_PASSWORD" ]; then
  # nginx implements apr1 itself, so it is portable across every base image.
  htpasswd -b -c -m "$HTPASSWD" "$BASIC_AUTH_USER" "$BASIC_AUTH_PASSWORD" >/dev/null 2>&1
  chmod 0640 "$HTPASSWD"
  chown root:nginx "$HTPASSWD" 2>/dev/null || true
  AUTH_LINE="auth_basic \"$BASIC_AUTH_REALM\"; auth_basic_user_file $HTPASSWD;"
  log "basic auth enabled for user '$BASIC_AUTH_USER'"
else
  rm -f "$HTPASSWD"
  log "basic auth disabled (set BASIC_AUTH_USER and BASIC_AUTH_PASSWORD to enable)"
fi

# ------------------------------------------------------------ security headers
{
  echo 'add_header X-Content-Type-Options "nosniff" always;'
  echo 'add_header X-Frame-Options "SAMEORIGIN" always;'
  echo 'add_header Referrer-Policy "strict-origin-when-cross-origin" always;'
  echo 'add_header Cross-Origin-Opener-Policy "same-origin" always;'
  if [ "$HSTS_MAX_AGE" != "0" ]; then
    echo "add_header Strict-Transport-Security \"max-age=$HSTS_MAX_AGE; includeSubDomains\" always;"
  fi
} > "$HEADERS"

# ---------------------------------------------------------------- http context
cat > "$CONF_D/00-railway-http.conf" <<'RAILWAY_HTTP'
# Railway's edge overwrites a client-supplied X-Forwarded-For, so the LEFTMOST
# entry is the real client. The second entry is the edge and it rotates per
# request, which is why realip/recursive and $proxy_add_x_forwarded_for are
# both wrong here.
map $http_x_forwarded_for $real_client_ip {
    '~^\s*(?P<xff_first>[^,\s]+)'  $xff_first;
    default                        $remote_addr;
}

map $http_x_forwarded_proto $forwarded_scheme {
    default  $scheme;
    https    https;
    http     http;
}

map $http_upgrade $connection_upgrade {
    default  upgrade;
    ''       close;
}

log_format railway '$real_client_ip - [$time_local] "$request" $status $body_bytes_sent '
                   '"$http_referer" "$http_user_agent" rt=$request_time '
                   'uct=$upstream_connect_time urt=$upstream_response_time '
                   'cache=$upstream_cache_status';

server_tokens off;
absolute_redirect off;
RAILWAY_HTTP

{
  echo "client_max_body_size $CLIENT_MAX_BODY_SIZE;"
  if is_true "$GZIP_ENABLED"; then
    echo 'gzip on;'
    echo 'gzip_vary on;'
    echo 'gzip_proxied any;'
    echo 'gzip_comp_level 5;'
    echo 'gzip_min_length 256;'
    echo 'gzip_types text/plain text/css text/xml text/javascript application/javascript application/json application/xml application/rss+xml application/atom+xml application/wasm image/svg+xml font/ttf font/otf;'
    # Serve a pre-compressed .gz sibling when the client accepts it. Every
    # official nginx build carries this module; brotli is in none of them.
    echo 'gzip_static on;'
  fi
  if is_true "$CACHE_ENABLED"; then
    mkdir -p "$CACHE_PATH"
    chown -R nginx:nginx "$CACHE_PATH" 2>/dev/null || true
    echo "proxy_cache_path $CACHE_PATH levels=1:2 keys_zone=railway_cache:10m max_size=$CACHE_MAX_SIZE inactive=60m use_temp_path=off;"
  fi
  if [ -n "$RATE_LIMIT_RPS" ]; then
    echo "limit_req_zone \$real_client_ip zone=railway_rl:10m rate=${RATE_LIMIT_RPS}r/s;"
    echo 'limit_req_status 429;'
  fi
} >> "$CONF_D/00-railway-http.conf"

# ---------------------------------------------------------------- proxy routes
route_n=0
for entry in $(printf '%s' "$PROXY_ROUTES" | tr ',' ' '); do
  case "$entry" in *=*) ;; *) log "ignoring malformed PROXY_ROUTES entry '$entry'"; continue ;; esac
  route_path=${entry%%=*}
  route_upstream=${entry#*=}
  case "$route_path" in
    /*) ;;
    *) log "ignoring route '$entry': path must start with /"; continue ;;
  esac
  case "$route_path" in
    *[!A-Za-z0-9._/~-]*) log "ignoring route '$entry': path has unsupported characters"; continue ;;
  esac
  case "$route_upstream" in
    http://*|https://*) ;;
    *) log "ignoring route '$entry': upstream must start with http:// or https://"; continue ;;
  esac

  route_n=$((route_n + 1))
  route_scheme=${route_upstream%%://*}
  route_authority=${route_upstream#*://}
  route_hostport=${route_authority%%/*}
  route_host=${route_hostport%%:*}
  route_path=${route_path%/}
  [ -n "$route_path" ] || route_path=/

  # nginx's own convention: an upstream ending in "/" strips the matched prefix,
  # one without it passes the request path through unchanged.
  route_base=""
  route_strip=false
  case "$route_upstream" in
    */) route_strip=true
        route_base=${route_authority#"$route_hostport"}
        route_base=${route_base%/}
        ;;
  esac

  # Railway's private A record is unroutable between services, so pin private
  # upstreams to IPv6. Public upstreams keep both families: several hosts
  # Railway itself uses publish no AAAA record at all.
  case "$route_host" in
    *.railway.internal) route_resolver_flags="ipv4=off" ;;
    *) route_resolver_flags="" ;;
  esac

  if [ "$route_scheme" = "https" ]; then
    route_host_headers="proxy_ssl_server_name on; proxy_ssl_name $route_host; proxy_set_header Host $route_hostport;"
  else
    route_host_headers="proxy_set_header Host \$host;"
  fi

  route_conf="$ROUTE_D/$(printf '%02d' "$route_n")-route.conf"
  {
    echo "location ^~ $route_path {"
    echo "    resolver $RESOLVERS $route_resolver_flags valid=10s;"
    echo "    set \$railway_upstream_$route_n \"$route_scheme://$route_hostport\";"
    if [ "$route_strip" = true ]; then
      echo "    rewrite ^${route_path%/}/?(.*)\$ $route_base/\$1 break;"
      echo "    proxy_pass \$railway_upstream_$route_n\$uri\$is_args\$args;"
    else
      echo "    proxy_pass \$railway_upstream_$route_n\$request_uri;"
    fi
    echo "    proxy_http_version 1.1;"
    echo "    $route_host_headers"
    echo "    proxy_set_header X-Real-IP \$real_client_ip;"
    echo "    proxy_set_header X-Forwarded-For \$real_client_ip;"
    echo "    proxy_set_header X-Forwarded-Proto \$forwarded_scheme;"
    echo "    proxy_set_header X-Forwarded-Host \$host;"
    echo "    proxy_set_header Upgrade \$http_upgrade;"
    echo "    proxy_set_header Connection \$connection_upgrade;"
    echo "    proxy_read_timeout $PROXY_READ_TIMEOUT;"
    echo "    proxy_buffering on;"
  } > "$route_conf"
  if is_true "$CACHE_ENABLED"; then
    {
      echo "    proxy_cache railway_cache;"
      echo "    proxy_cache_valid 200 301 302 $CACHE_VALID;"
      echo "    proxy_cache_valid 404 1m;"
      echo "    proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;"
      echo "    proxy_cache_lock on;"
      echo "    add_header X-Cache-Status \$upstream_cache_status always;"
    } >> "$route_conf"
  fi
  {
    echo "    include $HEADERS;"
    echo "}"
  } >> "$route_conf"
  log "route $route_path -> $route_scheme://$route_hostport"
done
if [ "$route_n" -eq 0 ]; then
  log "no proxy routes configured (set PROXY_ROUTES to add some)"
fi

# --------------------------------------------------------------- server block
if is_true "$SPA_MODE"; then
  TRY_FILES='try_files $uri $uri/ /index.html;'
else
  TRY_FILES='try_files $uri $uri/ =404;'
fi

AUTOINDEX=""
if is_true "$DIRECTORY_LISTING"; then
  AUTOINDEX="autoindex on; autoindex_exact_size off; autoindex_localtime on;"
fi

ACCESS_LOG_LINE="access_log off;"
if is_true "$ACCESS_LOG"; then
  ACCESS_LOG_LINE="access_log /dev/stdout railway;"
fi

LIMIT_LINE=""
if [ -n "$RATE_LIMIT_RPS" ]; then
  LIMIT_LINE="limit_req zone=railway_rl burst=$RATE_LIMIT_BURST nodelay;"
fi

ERROR_PAGE=""
if [ -f "$SITE_ROOT/404.html" ]; then
  ERROR_PAGE="error_page 404 /404.html;"
fi

cat > "$SERVER_CONF" <<'RAILWAY_SERVER'
server {
    listen      RWPORT default_server;
    listen      [::]:RWPORT default_server;
    server_name RWSERVERNAME;

    root    RWSITEROOT;
    index   RWINDEXFILES;
    charset utf-8;

    RWACCESSLOG
    error_log /dev/stderr warn;

    RWAUTH
    include RWHEADERS;

    RWERRORPAGE

    # Anonymous, dot-free liveness route for Railway's health prober. It sits
    # outside any auth so an authenticated deployment still passes.
    location = /healthz {
        auth_basic off;
        access_log off;
        default_type text/plain;
        return 200 "ok";
    }

    include RWROUTEDIR/*.conf;

    # Never serve dotfiles, but leave ACME and similar well-known paths reachable.
    location ~ /\.(?!well-known).* {
        deny all;
        access_log off;
        log_not_found off;
    }

    location ~* \.(?:css|js|mjs|json|woff2?|ttf|otf|eot|svg|png|jpe?g|gif|webp|avif|ico|map)$ {
        expires RWEXPIRES;
        access_log off;
        include RWHEADERS;
        try_files $uri =404;
    }

    location / {
        RWLIMIT
        RWAUTOINDEX
        RWTRYFILES
        include RWHEADERS;
    }
}
RAILWAY_SERVER

subst() {
  _rep=$(printf '%s' "$2" | sed -e 's/[|&\\]/\\&/g')
  sed -i "s|$1|$_rep|g" "$SERVER_CONF"
}
subst RWPORT "$PORT"
subst RWSERVERNAME "$SERVER_NAME"
subst RWSITEROOT "$SITE_ROOT"
subst RWINDEXFILES "$INDEX_FILES"
subst RWACCESSLOG "$ACCESS_LOG_LINE"
subst RWAUTH "$AUTH_LINE"
subst RWERRORPAGE "$ERROR_PAGE"
subst RWROUTEDIR "$ROUTE_D"
subst RWEXPIRES "$STATIC_ASSET_EXPIRES"
subst RWLIMIT "$LIMIT_LINE"
subst RWAUTOINDEX "$AUTOINDEX"
subst RWTRYFILES "$TRY_FILES"
subst RWHEADERS "$HEADERS"

# Fail closed if any marker survived the rewrite.
if grep -qE 'RW[A-Z]{4,}' "$SERVER_CONF"; then
  log "ERROR: unsubstituted marker left in the rendered config"
  grep -nE 'RW[A-Z]{4,}' "$SERVER_CONF" >&2
  exit 1
fi

# Validating here turns a bad rendered config into one readable line instead of
# a crash loop behind a green deployment.
if ! nginx -t; then
  log "ERROR: rendered configuration failed nginx -t; serving a 503 placeholder"
  rm -f "$CONF_D"/*.conf "$ROUTE_D"/*.conf
  {
    echo "server {"
    echo "    listen $PORT default_server;"
    echo "    listen [::]:$PORT default_server;"
    echo "    default_type text/plain;"
    echo "    return 503 \"nginx configuration error - check the deploy logs\";"
    echo "}"
  } > "$SERVER_CONF"
  nginx -t
fi

log "listening on $PORT, root $SITE_ROOT, $route_n proxy route(s)"
