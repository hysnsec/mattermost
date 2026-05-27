# Mattermost Custom Build — Google SSO

Custom build of Mattermost `v11.7.2` with Google SSO unlocked (no enterprise licence required), production Docker Compose stack with Traefik, PostgreSQL, and DigitalOcean Spaces backup.

See [GOOGLE_SSO_CHANGES.md](./GOOGLE_SSO_CHANGES.md) for full details of all source code changes.

---

## Prerequisites

- Docker + Docker Compose (on build machine and server)
- DigitalOcean Container Registry access: `registry.digitalocean.com/designshifu`
- A server with Docker installed (tested on Ubuntu 22.04)

---

## Build Image Locally

The image must be built on your local machine (Apple Silicon) targeting `linux/amd64`, then pushed to the registry. Do **not** build on the server.

```bash
# Cross-compile for linux/amd64 (required on Apple Silicon)
DOCKER_DEFAULT_PLATFORM=linux/amd64 docker build \
  -f compose/production/mattermost/Dockerfile \
  -t registry.digitalocean.com/designshifu/mattermost:11.7.2 \
  .
```

Build takes ~20–30 min on first run (Go compile + npm build). Subsequent builds are fast due to layer caching.

### Push to Registry

```bash
# Authenticate (if not already logged in)
doctl registry login

# Push
docker push registry.digitalocean.com/designshifu/mattermost:11.7.2
```

---

## Server Deployment

### First-time Setup

```bash
# 1. SSH into server
ssh root@your-server-ip

# 2. Clone the repo
git clone https://github.com/designshifu/mattermost.git /home/deploy/mattermost
cd /home/deploy/mattermost

# 3. Copy env templates and fill in real values
cp .envs/.production/.mattermost.example .envs/.production/.mattermost
cp .envs/.production/.postgres.example   .envs/.production/.postgres
cp .envs/.production/.traefik.example    .envs/.production/.traefik
cp .envs/.production/.aws.example        .envs/.production/.aws

# Edit each file and replace placeholder values
nano .envs/.production/.mattermost   # set SITEURL, Google OAuth credentials, DB password
nano .envs/.production/.postgres     # set POSTGRES_PASSWORD (must match .mattermost datasource)
nano .envs/.production/.traefik      # set TRAEFIK_DOMAIN and TRAEFIK_ACME_EMAIL
nano .envs/.production/.aws          # set Spaces credentials and bucket names (for backups)

# 4. Authenticate to DO registry
doctl registry login

# 5. Pull image and start all services
docker compose -f production.yml pull
docker compose -f production.yml up -d
```

### Update Deployment (after new image push)

```bash
cd /home/deploy/mattermost
git pull
docker compose -f production.yml pull mattermost
docker compose -f production.yml up -d --no-deps mattermost
```

### View Logs

```bash
docker compose -f production.yml logs -f mattermost
docker compose -f production.yml logs -f traefik
```

---

## Backup

### Postgres backup to local disk

```bash
docker compose -f production.yml run --rm postgres backup
```

### Upload backup to DigitalOcean Spaces

```bash
docker compose -f production.yml run --rm awscli upload
```

---

## Services

| Service | Description |
|---|---|
| `mattermost` | Custom Mattermost build — pulled from `registry.digitalocean.com/designshifu/mattermost:11.7.2` |
| `postgres` | PostgreSQL database |
| `traefik` | Reverse proxy with automatic Let's Encrypt TLS |
| `awscli` | Postgres backup uploader to DigitalOcean Spaces |

---

## Plugins (Pre-loaded)

The following plugins are seeded into the filestore on first boot and auto-enabled:

| Plugin | Version |
|---|---|
| Matterpoll | 1.8.0 |
| Todo | 0.7.1 |
| Remind | 1.0.0 |
| Boards (Focalboard) | 8.0.0 |
| Standup Raven | 3.3.2 |

The following prepackaged plugins (bundled in the enterprise image) are also enabled:

- GitHub, Calls, Agents (AI)
