# ──────────────────────────────────────────────────────────────────────────────
# Stage 1: Build Go server binary
# ──────────────────────────────────────────────────────────────────────────────
FROM golang:1.26-bookworm AS gobuilder

WORKDIR /src

# Copy only what Go needs first (better layer caching)
COPY server/go.mod server/go.sum ./server/
COPY server/public/go.mod server/public/go.sum ./server/public/

# Set up Go workspace
RUN cd /src/server && \
    go work init && \
    go work use . && \
    go work use ./public

# Download dependencies
RUN cd /src/server && go mod download
RUN cd /src/server/public && go mod download

# Copy the full source
COPY server/ ./server/

# Build the binary — enterprise ready, Google SSO unlocked
RUN cd /src/server && \
    GOOS=linux GOARCH=amd64 go build \
      -trimpath \
      -tags production \
      -ldflags '-X "github.com/mattermost/mattermost/server/public/model.BuildEnterpriseReady=true"' \
      -o /out/mattermost \
      ./cmd/mattermost


# ──────────────────────────────────────────────────────────────────────────────
# Stage 2: Build webapp
# ──────────────────────────────────────────────────────────────────────────────
FROM node:24-bookworm-slim AS webbuilder

WORKDIR /src

# Copy full webapp source — postinstall script needs platform/ workspaces present
COPY webapp/ ./webapp/

# Install dependencies + production build
RUN npm config set fetch-timeout 600000 && npm config set fetch-retry-mintimeout 20000 && npm config set fetch-retry-maxtimeout 120000
RUN cd /src/webapp && npm ci --include=dev && npm run build


# ──────────────────────────────────────────────────────────────────────────────
# Stage 3: Download plugins into filestore layout
# ──────────────────────────────────────────────────────────────────────────────
FROM debian:bookworm-slim AS pluginbuilder

RUN apt-get update && apt-get install -y --no-install-recommends wget ca-certificates && rm -rf /var/lib/apt/lists/*

# Store as .tar.gz files — Mattermost SyncPlugins reads from here and installs to /mattermost/plugins/
WORKDIR /data/plugins

RUN \
  # Matterpoll
  wget -q https://github.com/matterpoll/matterpoll/releases/download/v1.8.0/com.github.matterpoll.matterpoll-1.8.0.tar.gz \
    -O com.github.matterpoll.matterpoll.tar.gz && \
  \
  # Todo
  wget -q https://github.com/mattermost-community/mattermost-plugin-todo/releases/download/v0.7.1/com.mattermost.plugin-todo-0.7.1.tar.gz \
    -O com.mattermost.plugin-todo.tar.gz && \
  \
  # Remind
  wget -q https://github.com/scottleedavis/mattermost-plugin-remind/releases/download/v1.0.0/com.github.scottleedavis.mattermost-plugin-remind-1.0.0.tar.gz \
    -O com.github.scottleedavis.mattermost-plugin-remind.tar.gz && \
  \
  # Boards (Focalboard)
  wget -q https://github.com/mattermost-community/focalboard/releases/download/v8.0.0/mattermost-plugin-focalboard.tar.gz \
    -O com.mattermost.focalboard.tar.gz && \
  \
  # Standup Raven
  wget -q https://github.com/standup-raven/standup-raven/releases/download/v3.3.2/mattermost-plugin-standup-raven-v3.3.2-linux-amd64.tar.gz \
    -O com.github.standup-raven.standup-raven.tar.gz


# ──────────────────────────────────────────────────────────────────────────────
# Stage 4: Final image — replace binary + webapp + seed filestore plugins
# ──────────────────────────────────────────────────────────────────────────────
FROM mattermost/mattermost-enterprise-edition:11.7.2

USER mattermost
WORKDIR /mattermost

# Replace server binary (Google SSO unlocked, enterprise ready)
COPY --from=gobuilder  --chown=2000:2000 /out/mattermost /mattermost/bin/mattermost

# Replace webapp (licence gates removed)
COPY --from=webbuilder --chown=2000:2000 /src/webapp/channels/dist/. /mattermost/client/

# Seed plugin .tar.gz files into the filestore — SyncPlugins reads from here
# Only takes effect on first boot when production_mattermost_data volume is new
COPY --from=pluginbuilder --chown=2000:2000 /data/plugins/. /mattermost/data/plugins/
