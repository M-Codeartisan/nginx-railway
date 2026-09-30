#!/bin/sh
# Send everything that is not handled elsewhere to an upstream application.
#
# Runs after 40-railway-nginx.sh has rendered the server block and after
# 41-media-proxy.sh has added its route, so this only has to rewrite the
# fallback location. Neither of those scripts is modified.
#
# WHY NOT PROXY_ROUTES
# The template's own PROXY_ROUTES cannot express this. An entry of "/=upstream"
# renders `location ^~ /` beside the `location /` the server block already has,
# and nginx refuses to start with "duplicate location". Rewriting the existing
# fallback in place is the only way to keep one of them.
#
# WHAT CHANGES
# `location /` becomes `location ^~ /` and its try_files is replaced by a
# proxy_pass. The "^~" matters: it makes the prefix win outright over regex
# locations, so the template's static-asset block stops intercepting requests
# for files this container does not have — the application serves its own
# assets. Longer prefixes still win, so /media/ keeps going to S3, and the
# exact-match /healthz stays local for Railway's health probe.
#
# Deliberately NOT "set -e": the stock nginx entrypoint aborts the container if
# any /docker-entrypoint.d script exits non-zero, so an error here would take
# the whole site down rather than just leaving it serving static files. Every
# path below ends in exit 0.
set -u

ME="[app-proxy]"
log() { echo "$ME $*"; }

CONF_D=/etc/nginx/conf.d
HEADERS=/etc/nginx/railway-security-headers.conf
SERVER_CONF="$CONF_D/10-railway-server.conf"

APP_UPSTREAM="${APP_UPSTREAM:-}"

if [ -z "$APP_UPSTREAM" ]; then
  log "disabled (set APP_UPSTREAM to proxy everything else to an application)"
  exit 0
fi

APP_READ_TIMEOUT="${APP_READ_TIMEOUT:-60s}"

# Response header buffer, then body buffers, then how much may be flushed to the
# client while the rest is still arriving. Defaults are four times nginx's own.
APP_BUFFER_SIZE="${APP_BUFFER_SIZE:-16k}"
APP_BUFFERS="${APP_BUFFERS:-8 16k}"
APP_BUSY_BUFFERS_SIZE="${APP_BUSY_BUFFERS_SIZE:-32k}"

case "$APP_UPSTREAM" in
  http://*|https://*) ;;
  *)
    log "ERROR: APP_UPSTREAM must start with http:// or https://; disabling"
    exit 0 ;;
esac

app_scheme=${APP_UPSTREAM%%://*}
app_authority=${APP_UPSTREAM#*://}
app_hostport=${app_authority%%/*}
app_host=${app_hostport%%:*}

case "$app_hostport" in
  *[!A-Za-z0-9.:-]*)
    log "ERROR: APP_UPSTREAM host '$app_hostport' is not valid; disabling"
    exit 0 ;;
esac

if [ ! -f "$SERVER_CONF" ]; then
  log "ERROR: $SERVER_CONF is missing, so 40-railway-nginx.sh did not run; disabling"
  exit 0
fi

# Railway's private network routes over IPv6 only between services, and the
# private A record is unroutable, so pin .railway.internal upstreams to IPv6.
# Public hosts keep both families.
case "$app_host" in
  *.railway.internal) app_resolver_flags="ipv4=off" ;;
  *) app_resolver_flags="" ;;
esac

RESOLVERS="${NGINX_LOCAL_RESOLVERS:-}"
if [ -z "$RESOLVERS" ]; then
  RESOLVERS=$(awk 'BEGIN{ORS=" "} $1=="nameserver" {if ($2 ~ ":") {print "["$2"]"} else {print $2}}' /etc/resolv.conf)
  RESOLVERS="${RESOLVERS% }"
fi
[ -n "$RESOLVERS" ] || RESOLVERS="[fd12::10]"

if [ "$app_scheme" = "https" ]; then
  APP_TLS="        proxy_ssl_server_name on;
        proxy_ssl_name        $app_host;
        proxy_ssl_verify      on;
        proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
        proxy_ssl_verify_depth 3;
        proxy_set_header Host $app_hostport;"
else
  # Pass the client's Host through, so the application generates links on the
  # domain the visitor actually used.
  APP_TLS="        proxy_set_header Host \$host;"
fi

BODY_FILE="$(mktemp)" || { log "ERROR: cannot create a temporary file; disabling"; exit 0; }
SERVER_BACKUP="$(mktemp)" || { log "ERROR: cannot create a temporary file; disabling"; rm -f "$BODY_FILE"; exit 0; }
cp "$SERVER_CONF" "$SERVER_BACKUP" 2>/dev/null || true

cat > "$BODY_FILE" <<APP_BODY
        resolver $RESOLVERS $app_resolver_flags valid=10s;
        set \$app_upstream "$app_scheme://$app_hostport";

        proxy_pass         \$app_upstream\$request_uri;
        proxy_http_version 1.1;
$APP_TLS

        # X-Forwarded-Proto is what lets the application generate https links
        # behind Railway's TLS termination. Without it Laravel emits http:// and
        # a service worker refuses to register.
        proxy_set_header X-Real-IP         \$real_client_ip;
        proxy_set_header X-Forwarded-For   \$real_client_ip;
        proxy_set_header X-Forwarded-Proto \$forwarded_scheme;
        proxy_set_header X-Forwarded-Host  \$host;
        proxy_set_header Upgrade           \$http_upgrade;
        proxy_set_header Connection        \$connection_upgrade;

        proxy_read_timeout $APP_READ_TIMEOUT;
        proxy_buffering on;

        # Raised from the defaults, which are sized for small responses. A
        # framework that sets many cookies or a long Set-Cookie chain overflows
        # the 4k header buffer and nginx answers 502 with
        # "upstream sent too big header while reading response header".
        proxy_buffer_size       $APP_BUFFER_SIZE;
        proxy_buffers           $APP_BUFFERS;
        proxy_busy_buffers_size $APP_BUSY_BUFFERS_SIZE;
APP_BODY

# Replace the try_files inside "location /" only. The static-asset block has a
# try_files of its own, so the rewrite has to be block-aware rather than a
# global substitution.
awk -v bodyfile="$BODY_FILE" '
  /^[[:space:]]*location \/ \{[[:space:]]*$/ && !seen {
      print "    location ^~ / {"
      seen = 1
      inblock = 1
      next
  }
  inblock && /try_files/ {
      while ((getline line < bodyfile) > 0) print line
      close(bodyfile)
      replaced = 1
      next
  }
  inblock && /^[[:space:]]*\}[[:space:]]*$/ { inblock = 0 }
  { print }
  END { exit (seen && replaced) ? 0 : 1 }
' "$SERVER_CONF" > "$SERVER_CONF.new"

if [ $? -ne 0 ]; then
  log "ERROR: could not find the fallback location to rewrite; the rendered server block is not the shape this script expects. Leaving it alone."
  rm -f "$SERVER_CONF.new" "$BODY_FILE" "$SERVER_BACKUP"
  exit 0
fi

mv "$SERVER_CONF.new" "$SERVER_CONF"
rm -f "$BODY_FILE"

if nginx -t; then
  log "proxying everything except /media/ and /healthz to $app_scheme://$app_hostport"
else
  log "ERROR: the rewritten server block failed nginx -t; reverting and keeping the static site"
  cp "$SERVER_BACKUP" "$SERVER_CONF" 2>/dev/null || true
  if nginx -t >/dev/null 2>&1; then
    log "reverted; the rest of the configuration is valid"
  else
    log "WARNING: the configuration is still invalid after reverting, so the fault is not this script"
  fi
fi

rm -f "$SERVER_BACKUP"
exit 0
