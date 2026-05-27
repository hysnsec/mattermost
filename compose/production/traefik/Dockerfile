FROM docker.io/traefik:2.11.0

RUN apk add --no-cache gettext

RUN mkdir -p /etc/traefik/acme \
  && touch /etc/traefik/acme/acme.json \
  && chmod 600 /etc/traefik/acme/acme.json

COPY ./compose/production/traefik/traefik.tmpl /etc/traefik/traefik.tmpl
COPY ./compose/production/traefik/entrypoint.sh /custom-entrypoint.sh
RUN chmod +x /custom-entrypoint.sh

ENTRYPOINT ["/custom-entrypoint.sh"]
CMD ["traefik"]
