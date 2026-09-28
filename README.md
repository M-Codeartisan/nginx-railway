# NGINX on Railway

A production-ready [NGINX](https://nginx.org) image for Railway: a static site host,
a reverse proxy for your other Railway services, and an edge cache — all configured
with environment variables.

Built `FROM nginx:alpine`. The whole configuration is rendered at boot by
[`docker-entrypoint.d/40-railway-nginx.sh`](docker-entrypoint.d/40-railway-nginx.sh),
validated with `nginx -t` before the server starts, and falls back to a loud `503`
placeholder rather than serving a wrong configuration silently.

## What it handles for you

- **`$PORT`** — listens on the port Railway assigns, on both IPv4 and IPv6, so a
  private peer can reach it as well as the public edge.
- **Real client IP** — Railway's edge appends its own rotating address to
  `X-Forwarded-For`. The config reads the **leftmost** entry, so access logs, the
  rate limiter and the headers sent upstream all carry the true client. The usual
  `real_ip_recursive` / `$proxy_add_x_forwarded_for` recipes land on the edge here.
- **Worker sizing** — `NGINX_ENTRYPOINT_WORKER_PROCESSES_AUTOTUNE` reads the cgroup
  CPU quota instead of the 48-core host, so `worker_processes` matches the plan.
- **IPv6 upstream resolution** — Railway's private network routes over IPv6 only
  between services, so `*.railway.internal` upstreams get `resolver … ipv4=off`
  while public upstreams keep both families. Upstreams are re-resolved every
  10 seconds, so redeploying a backend never strands a stale address.
- **Security headers** — `nosniff`, `SAMEORIGIN`, a referrer policy, COOP and HSTS
  are re-declared inside every `location`, because a block that sets any header of
  its own drops the ones it would otherwise inherit.

## Configuration

Every variable is optional and has a working default.

| Variable | Default | Description |
|---|---|---|
| `PORT` | `8080` | Port NGINX listens on. Railway sets this. |
| `SITE_ROOT` | `/data/www` | Directory served as the site root. Keep it below the volume mount root. |
| `INDEX_FILES` | `index.html index.htm` | Index file names. |
| `SITE_SOURCE_URL` | *(unset)* | URL of a `.tar.gz` or `.zip` unpacked over the site root at boot. Fetched every boot, unpacked only when its contents changed, and overlaid rather than wiping — so a redeploy publishes a new build of your site. |
| `SITE_SOURCE_STRIP` | `0` | `--strip-components` for a tarball. Use `1` for a GitHub source archive, whose files sit under a top-level directory. |
| `SPA_MODE` | `false` | Fall back to `/index.html` for unknown paths. |
| `DIRECTORY_LISTING` | `false` | `autoindex` for directories with no index file. |
| `PROXY_ROUTES` | *(unset)* | Comma-separated `/path=upstream` list, e.g. `/api=http://api.railway.internal:3000`. |
| | | An upstream **ending in `/`** strips the matched prefix (`/api/users` → `/users`), one without it passes the path through unchanged — the same convention as `proxy_pass` itself. |
| `PROXY_READ_TIMEOUT` | `60s` | Upstream read timeout. |
| `CACHE_ENABLED` | `false` | Cache proxied responses on the volume; adds `X-Cache-Status`. |
| `CACHE_PATH` | `/data/cache` | Cache directory. |
| `CACHE_MAX_SIZE` | `1g` | Cache size ceiling. |
| `CACHE_VALID` | `10m` | How long a `200`/`301`/`302` stays fresh. |
| `GZIP_ENABLED` | `true` | gzip plus `gzip_static` for pre-compressed `.gz` siblings. |
| `CLIENT_MAX_BODY_SIZE` | `64m` | Request body ceiling. |
| `STATIC_ASSET_EXPIRES` | `30d` | `Expires` for fingerprinted asset types. |
| `HSTS_MAX_AGE` | `31536000` | `0` removes the HSTS header. |
| `BASIC_AUTH_USER` | *(unset)* | Set with `BASIC_AUTH_PASSWORD` to put HTTP basic auth over the whole site. |
| `BASIC_AUTH_PASSWORD` | *(unset)* | Hashed into an htpasswd file at boot; never stored in the image. |
| `BASIC_AUTH_REALM` | `Restricted` | Realm shown in the browser prompt. |
| `RATE_LIMIT_RPS` | *(unset)* | Requests per second per client IP. Unset means no limiting. |
| `RATE_LIMIT_BURST` | `20` | Burst allowance for the limiter. |
| `SERVER_NAME` | `_` | `server_name`. Railway's edge routes by Host already. |
| `ACCESS_LOG` | `true` | Access log to stdout. |

`/healthz` always answers `200` anonymously, outside basic auth, so it works as the
Railway health-check path on an otherwise locked-down deployment.

## Getting your site onto the volume

Two ways, and the second one is what a template deploy should use:

```sh
# 1. Upload files directly over Railway's volume SFTP.
railway volume files --volume "$VOLUME_ID" upload ./index.html /www/index.html

# 2. Point the service at an archive and let it unpack on boot.
SITE_SOURCE_URL=https://example.com/my-site.tar.gz
```

`examples/demo-site.tar.gz` in this repo is a working example — set `SITE_SOURCE_URL`
to its raw URL and the pages appear under `/demo/`. It is built from
`examples/demo-site/`:

```sh
cd examples/demo-site && tar -czf ../demo-site.tar.gz demo
```

## Storage

Mount a Railway volume at `/data`. The site root (`/data/www`) and the proxy cache
(`/data/cache`) sit one level below the mount root, because every Railway volume
ships a `lost+found` directory. The shipped placeholder page is copied into the site
root only while it is empty, so uploading your own files replaces it permanently.

## Local check

```sh
docker build -t nginx-railway .
docker run --rm -e PORT=8080 -p 8080:8080 nginx-railway
```
