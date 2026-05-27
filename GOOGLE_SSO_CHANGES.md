# Mattermost Custom Build — Google SSO Without Enterprise Licence

> Base tag: `v11.7.2`
> Final image: `registry.digitalocean.com/designshifu/mattermost:11.7.2`

---

## Why This Exists

Out of the box, Mattermost gates Google OAuth behind an enterprise licence check at three layers:

| Layer | Where | What it does |
|---|---|---|
| Backend | `server/config/client.go` | Only sends `EnableSignUpWithGoogle` to frontend if `license.Features.GoogleOAuth = true` |
| Frontend signup | `webapp/.../signup/signup.tsx` | Only renders Google button if `isLicensed && enableSignUpWithGoogle` |
| Admin console | `webapp/.../admin_definition.tsx` | Hides Google Apps option unless licensed |

We removed all three gates, added the missing open-source Google provider implementation, and removed the "Team Edition" branding that appeared without a licence key.

---

## Step 0 — Checkout Tag

```bash
cd /path/to/mattermost

# Stash any existing changes on master
git stash

# Checkout v11.7.2 (detached HEAD — no branch needed)
git checkout v11.7.2
```

---

## Step 1 — Code Changes

### 1.1 New file — Google OAuth Provider

**`server/channels/app/oauthproviders/google/google.go`**

Full implementation that:
- Parses the Google People API v1 response (`resourceName`, `names`, `emailAddresses`)
- Extracts stable user ID from `resourceName` (strips `people/` prefix)
- Maps to a Mattermost `model.User`
- Registers itself under `model.ServiceGoogle` (`"google"`) on `init()`

```go
package oauthgoogle

import (
    "encoding/json"
    "errors"
    "io"
    "strings"

    "github.com/mattermost/mattermost/server/public/model"
    "github.com/mattermost/mattermost/server/public/shared/mlog"
    "github.com/mattermost/mattermost/server/public/shared/request"
    "github.com/mattermost/mattermost/server/v8/einterfaces"
)

type GoogleProvider struct{}

type googleName struct {
    DisplayName string `json:"displayName"`
    FamilyName  string `json:"familyName"`
    GivenName   string `json:"givenName"`
    Metadata    struct {
        Primary bool `json:"primary"`
    } `json:"metadata"`
}

type googleEmail struct {
    Value    string `json:"value"`
    Metadata struct {
        Primary bool `json:"primary"`
    } `json:"metadata"`
}

type GoogleUser struct {
    ResourceName   string        `json:"resourceName"`
    Names          []googleName  `json:"names"`
    EmailAddresses []googleEmail `json:"emailAddresses"`
}

func init() {
    provider := &GoogleProvider{}
    einterfaces.RegisterOAuthProvider(model.ServiceGoogle, provider)
}

func googleUserFromJSON(data io.Reader) (*GoogleUser, error) {
    var gu GoogleUser
    if err := json.NewDecoder(data).Decode(&gu); err != nil {
        return nil, err
    }
    return &gu, nil
}

func (gu *GoogleUser) IsValid() error {
    if gu.ResourceName == "" {
        return errors.New("google user resource name cannot be empty")
    }
    if gu.primaryEmail() == "" {
        return errors.New("google user email cannot be empty")
    }
    return nil
}

func (gu *GoogleUser) authData() string {
    return strings.TrimPrefix(gu.ResourceName, "people/")
}

func (gu *GoogleUser) primaryEmail() string {
    for _, e := range gu.EmailAddresses {
        if e.Metadata.Primary {
            return e.Value
        }
    }
    if len(gu.EmailAddresses) > 0 {
        return gu.EmailAddresses[0].Value
    }
    return ""
}

func (gu *GoogleUser) primaryName() *googleName {
    for i := range gu.Names {
        if gu.Names[i].Metadata.Primary {
            return &gu.Names[i]
        }
    }
    if len(gu.Names) > 0 {
        return &gu.Names[0]
    }
    return nil
}

func userFromGoogleUser(logger mlog.LoggerIFace, gu *GoogleUser) *model.User {
    user := &model.User{}
    email := gu.primaryEmail()
    user.Email = strings.ToLower(email)
    parts := strings.Split(email, "@")
    user.Username = model.CleanUsername(logger, parts[0])
    if n := gu.primaryName(); n != nil {
        user.FirstName = n.GivenName
        user.LastName = n.FamilyName
        if user.FirstName == "" && user.LastName == "" {
            split := strings.SplitN(n.DisplayName, " ", 2)
            user.FirstName = split[0]
            if len(split) == 2 {
                user.LastName = split[1]
            }
        }
    }
    authData := gu.authData()
    user.AuthData = &authData
    user.AuthService = model.ServiceGoogle
    return user
}

func (gp *GoogleProvider) GetUserFromJSON(rctx request.CTX, data io.Reader, _ *model.User, _ *model.SSOSettings) (*model.User, error) {
    gu, err := googleUserFromJSON(data)
    if err != nil {
        return nil, err
    }
    if err = gu.IsValid(); err != nil {
        return nil, err
    }
    return userFromGoogleUser(rctx.Logger(), gu), nil
}

func (gp *GoogleProvider) GetSSOSettings(_ request.CTX, config *model.Config, _ string) (*model.SSOSettings, error) {
    return &config.GoogleSettings, nil
}

func (gp *GoogleProvider) GetUserFromIdToken(_ request.CTX, _ string) (*model.User, error) {
    return nil, nil
}

func (gp *GoogleProvider) IsSameUser(_ request.CTX, dbUser, oAuthUser *model.User) bool {
    return dbUser.AuthData != nil && oAuthUser.AuthData != nil && *dbUser.AuthData == *oAuthUser.AuthData
}
```

---

### 1.2 Register the Provider

**`server/cmd/mattermost/main.go`**

```diff
  _ "github.com/mattermost/mattermost/server/v8/channels/app/oauthproviders/gitlab"
+ _ "github.com/mattermost/mattermost/server/v8/channels/app/oauthproviders/google"
```

---

### 1.3 Remove Backend Licence Gate

**`server/config/client.go`**

```diff
- props["EnableSignUpWithGoogle"] = "false"
+ props["EnableSignUpWithGoogle"] = strconv.FormatBool(*c.GoogleSettings.Enable)
```

Also remove the licence-gated block inside `if license != nil`:

```diff
- if *license.Features.GoogleOAuth {
-     props["EnableSignUpWithGoogle"] = strconv.FormatBool(*c.GoogleSettings.Enable)
- }
-
  if *license.Features.Office365OAuth {
```

---

### 1.4 Remove Frontend Licence Gate (Signup)

**`webapp/channels/src/components/signup/signup.tsx`**

```diff
- if (isLicensed && enableSignUpWithGoogle) {
+ if (enableSignUpWithGoogle) {
```

---

### 1.5 Remove Admin Console Licence Gate

**`webapp/channels/src/components/admin_console/admin_definition.tsx`**

```diff
  value: Constants.GOOGLE_SERVICE,
  display_name: defineMessage({id: 'admin.oauth.google', defaultMessage: 'Google Apps'}),
- isHidden: it.all(it.not(it.licensedForFeature('GoogleOAuth')), it.not(it.cloudLicensed)),
  help_text: defineMessage({...}),
```

---

### 1.6 Fix "Team Edition" Branding in Header

Without a licence key, the header showed "Team Edition" instead of the expected branding. Fixed by hardcoding `isFreeEdition = false` since we always want the enterprise branding.

**`webapp/channels/src/components/global_header/left_controls/product_menu/product_menu.tsx`**

```diff
- const isFreeEdition = license.IsLicensed === 'false' || license.SkuShortName === LicenseSkus.Entry;
+ const isFreeEdition = false;
```

---

### 1.7 Fix "Team Edition" Text in About Dialog

The About modal showed "Team Edition" when the binary was built without `BuildEnterpriseReady=true` ldflags. Fixed directly in source so it always shows "Enterprise Edition".

**`webapp/channels/src/components/about_build_modal/about_build_modal.tsx`**

```diff
- if (config.BuildEnterpriseReady === 'true') {
+ if (true) {
```

---

### 1.8 Remove "Team Edition" Badge from Login / Signup Page

The header on the `/login` and `/signup` pages showed a "TEAM EDITION" badge when no licence was present. Fixed by setting `freeBanner = null` unconditionally and removing the now-unused licence imports.

**`webapp/channels/src/components/header_footer_route/header.tsx`**

```diff
- import {getLicense} from 'mattermost-redux/selectors/entities/general';
- import {LicenseSkus} from 'utils/constants';
  import {getConfig} from 'mattermost-redux/selectors/entities/general';
  ...
- const license = useSelector(getLicense);
  const {SiteName} = useSelector(getConfig);
- const freeBanner = license.IsLicensed === 'false' || license.SkuShortName === LicenseSkus.Entry
-   ? <TeamEditionLeftNav/>
-   : null;
+ const freeBanner = null;
```

---

## Step 2 — Dockerfile (Multi-Stage)

The Dockerfile handles all compilation internally — no local Go or Node toolchain required.

**`compose/production/mattermost/Dockerfile`**

```dockerfile
# ──────────────────────────────────────────────────────────────────────────────
# Stage 1: Build Go server binary
# ──────────────────────────────────────────────────────────────────────────────
FROM golang:1.25-bookworm AS gobuilder

WORKDIR /src

# Copy only what Go needs first (better layer caching)
COPY server/go.mod server/go.sum ./server/
COPY server/public/go.mod server/public/go.sum ./server/public/

# Set up Go workspace (server/public is a separate Go module)
RUN cd /src/server && \
    go work init && \
    go work use . && \
    go work use ./public

RUN cd /src/server && go mod download
RUN cd /src/server/public && go mod download

COPY server/ ./server/

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

# Increase npm timeouts to handle slow network during build
RUN npm config set fetch-timeout 600000 && \
    npm config set fetch-retry-mintimeout 20000 && \
    npm config set fetch-retry-maxtimeout 120000

RUN cd /src/webapp && npm ci --include=dev && npm run build


# ──────────────────────────────────────────────────────────────────────────────
# Stage 3: Download plugins into filestore layout
# ──────────────────────────────────────────────────────────────────────────────
FROM debian:bookworm-slim AS pluginbuilder

RUN apt-get update && apt-get install -y --no-install-recommends wget ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Store as .tar.gz — Mattermost SyncPlugins reads from filestore and installs to /mattermost/plugins/
WORKDIR /data/plugins

RUN \
  wget -q https://github.com/matterpoll/matterpoll/releases/download/v1.8.0/com.github.matterpoll.matterpoll-1.8.0.tar.gz \
    -O com.github.matterpoll.matterpoll.tar.gz && \
  wget -q https://github.com/mattermost-community/mattermost-plugin-todo/releases/download/v0.7.1/com.mattermost.plugin-todo-0.7.1.tar.gz \
    -O com.mattermost.plugin-todo.tar.gz && \
  wget -q https://github.com/scottleedavis/mattermost-plugin-remind/releases/download/v1.0.0/com.github.scottleedavis.mattermost-plugin-remind-1.0.0.tar.gz \
    -O com.github.scottleedavis.mattermost-plugin-remind.tar.gz && \
  wget -q https://github.com/mattermost-community/focalboard/releases/download/v8.0.0/mattermost-plugin-focalboard.tar.gz \
    -O com.mattermost.focalboard.tar.gz && \
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

# Seed plugin .tar.gz files into filestore — SyncPlugins reads from here on first boot
COPY --from=pluginbuilder --chown=2000:2000 /data/plugins/. /mattermost/data/plugins/
```

> All runtime deps, i18n, fonts, templates, and config are inherited from the official enterprise image. Only the server binary, webapp, and plugin filestore seed are replaced.
>
> **Plugin seeding note:** Plugins are copied to `/mattermost/data/plugins/` (the filestore), not `/mattermost/plugins/` (the runtime dir). Mattermost's `SyncPlugins` reads from the filestore and installs to the runtime dir on startup. This only takes effect on first boot when the `production_mattermost_data` volume is new.

---

## Step 3 — Build Locally & Push to Registry

Build must be done on the local machine (Apple Silicon) targeting `linux/amd64`. Do **not** build on the server.

```bash
# Build image (cross-compile for linux/amd64)
DOCKER_DEFAULT_PLATFORM=linux/amd64 docker build \
  -f compose/production/mattermost/Dockerfile \
  -t registry.digitalocean.com/designshifu/mattermost:11.7.2 \
  .

# Push to DigitalOcean Container Registry
doctl registry login
docker push registry.digitalocean.com/designshifu/mattermost:11.7.2
```

First build takes ~20–30 min (Go compile + npm build). Subsequent builds are fast due to layer caching.

---

## Step 4 — Verify the Image

### Check Google provider is compiled in
```bash
docker run --rm registry.digitalocean.com/designshifu/mattermost:11.7.2 \
  grep -c oauthgoogle /mattermost/bin/mattermost || true
```

### Check plugin files are seeded in filestore
```bash
docker run --rm registry.digitalocean.com/designshifu/mattermost:11.7.2 \
  sh -c 'echo /mattermost/data/plugins/*.tar.gz'
# → com.github.matterpoll.matterpoll.tar.gz  com.mattermost.plugin-todo.tar.gz  ...
```

### Smoke test with local postgres
```bash
docker network create mm-test

docker run -d --name mm-postgres --network mm-test \
  -e POSTGRES_USER=mattermost -e POSTGRES_PASSWORD=changeme -e POSTGRES_DB=mattermost \
  postgres:16

sleep 5

docker run -d --name mm-test --network mm-test -p 8065:8065 \
  -e MM_SQLSETTINGS_DRIVERNAME=postgres \
  -e MM_SQLSETTINGS_DATASOURCE="postgres://mattermost:changeme@mm-postgres:5432/mattermost?sslmode=disable" \
  -e MM_SERVICESETTINGS_SITEURL=http://localhost:8065 \
  -e MM_PLUGINSETTINGS_ENABLEUPLOADS=true \
  registry.digitalocean.com/designshifu/mattermost:11.7.2

# Watch for "Installing extracted plugin" — not "Removing local installation"
docker logs -f mm-test

# Cleanup
docker rm -f mm-test mm-postgres && docker network rm mm-test
```

---

## Step 6 — Configure Google OAuth in Admin Console

1. Go to **Admin Console → Authentication → OAuth 2.0**
2. Select **Google Apps**
3. Fill in:
   - **Client ID** — from Google Cloud Console
   - **Client Secret** — from Google Cloud Console
4. In Google Cloud Console add the redirect URI:
   ```
   https://your-domain.com/signup/google/complete
   ```
5. Enable the **Google People API** in Google Cloud Console

---

## File Summary

| File | Change |
|---|---|
| `server/channels/app/oauthproviders/google/google.go` | **NEW** — Google People API provider |
| `server/cmd/mattermost/main.go` | Added google provider import |
| `server/config/client.go` | Removed `GoogleOAuth` licence gate |
| `webapp/channels/src/components/signup/signup.tsx` | Removed `isLicensed &&` from Google button |
| `webapp/channels/src/components/admin_console/admin_definition.tsx` | Removed `isHidden` licence check |
| `webapp/channels/src/components/global_header/.../product_menu.tsx` | Hardcoded `isFreeEdition = false` |
| `webapp/channels/src/components/about_build_modal/about_build_modal.tsx` | Hardcoded enterprise edition check to `true` |
| `webapp/channels/src/components/header_footer_route/header.tsx` | Removed "Team Edition" badge from login/signup page |
| `compose/production/mattermost/Dockerfile` | 4-stage build — Go binary, webapp, plugin filestore seed, final image |
| `compose/production/traefik/Dockerfile` | Custom Traefik image with `envsubst` support |
| `compose/production/traefik/traefik.tmpl` | Traefik config template with `${TRAEFIK_DOMAIN}` placeholders |
| `compose/production/traefik/entrypoint.sh` | Runs `envsubst` to expand env vars before starting Traefik |
| `production.yml` | Docker Compose — traefik + postgres + mattermost + awscli backup |
| `.envs/.production/.mattermost.example` | Mattermost env template (Google SSO, plugin states, SMTP) |
| `.envs/.production/.postgres.example` | Postgres env template |
| `.envs/.production/.traefik.example` | Traefik env template (domain + ACME email) |
| `.envs/.production/.aws.example` | AWS/Spaces env template (for postgres backups) |

---

## Notes

- The `go.work` file created during build is gitignored — safe to leave.
- CSS ordering warnings during webapp build are pre-existing in the codebase, not from our changes.
- The `go work init` step inside Docker is required because `server/public` is a separate Go module.
- The `-ldflags BuildEnterpriseReady=true` in Stage 1 is belt-and-suspenders alongside the source code fix in `about_build_modal.tsx` — both ensure "Enterprise Edition" is shown.
