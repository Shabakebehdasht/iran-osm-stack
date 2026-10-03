#!/bin/sh
# Render nginx.conf from the template, substituting the access key.
#
# The template carries a literal __OSM_ACCESS_KEY__ placeholder on purpose: a
# real secret must never be baked into an image layer, where it would survive
# in `docker history` and in any pushed registry copy. It is substituted here,
# at container start, from the environment.
set -eu

TEMPLATE=/etc/nginx/templates/gateway.conf.template
OUTPUT=/etc/nginx/conf.d/gateway.conf

: "${OSM_ACCESS_KEY:?OSM_ACCESS_KEY must be set (docker-compose.yml generates it)}"

if [ -z "$OSM_ACCESS_KEY" ]; then
  echo "OSM_ACCESS_KEY is empty — refusing to start with an open gateway" >&2
  exit 1
fi

sed "s|__OSM_ACCESS_KEY__|${OSM_ACCESS_KEY}|g" "$TEMPLATE" > "$OUTPUT"

# Fail fast and loudly on a syntax error rather than crash-looping later.
nginx -t

echo "Gateway starting: access key configured ($(printf '%s' "$OSM_ACCESS_KEY" | wc -c) chars)"

# Hand over to nginx. Without this exec the script simply ends, the container
# exits 0, and `restart: unless-stopped` turns that into a silent restart loop
# that looks like a crash even though nginx -t passed.
#
# Run in the foreground: nginx must be PID 1's child so that
# `docker compose stop` delivers SIGTERM to it directly.
# -g 'daemon off;' is required or nginx forks to the background and the
# container exits immediately for the same reason.
exec nginx -g 'daemon off;'