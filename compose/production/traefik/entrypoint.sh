#!/bin/sh
# Substitute env vars into traefik config before starting
envsubst '${TRAEFIK_DOMAIN} ${TRAEFIK_ACME_EMAIL}' \
  < /etc/traefik/traefik.tmpl \
  > /etc/traefik/traefik.yml

exec /entrypoint.sh "$@"
