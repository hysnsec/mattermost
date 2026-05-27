# Mattermost Custom Build — Google SSO Without Enterprise Licence

> Base tag: `v11.7.2`
> Final image: `mattermost-custom:11.7.2-google-sso`

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

## Step 2 — Dockerfile (Multi-Stage)

The Dockerfile handles all compilation internally — no local Go or Node toolchain required. Just run `docker compose`.

**`compose/production/mattermost/Dockerfile`**

```dockerfile
# ──────────────────────────────────────────────────────────────────────────────
# Stage 1: Build Go server binary
# ──────────────────────────────────────────────────────────────────────────────
FROM golang:1.25-bullseye AS gobuilder

WORKDIR /src

COPY server/go.mod server/go.sum ./server/
COPY server/public/go.mod server/public/go.sum ./server/public/

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
FROM node:24-bullseye-slim AS webbuilder

WORKDIR /src

COPY webapp/package.json webapp/package-lock.json ./webapp/
COPY webapp/channels/package.json ./webapp/channels/

RUN cd /src/webapp && npm ci --include=dev

COPY webapp/ ./webapp/

RUN cd /src/webapp && npm run build


# ──────────────────────────────────────────────────────────────────────────────
# Stage 3: Final image — replace binary + webapp in official image
# ──────────────────────────────────────────────────────────────────────────────
FROM mattermost/mattermost-enterprise-edition:11.7.2

USER mattermost
WORKDIR /mattermost

COPY --from=gobuilder  --chown=2000:2000 /out/mattermost /mattermost/bin/mattermost
COPY --from=webbuilder --chown=2000:2000 /src/webapp/channels/dist/. /mattermost/client/
```

> All runtime deps, i18n, fonts, templates, config and plugins are inherited from the official enterprise image. Only the server binary and webapp are replaced.

---

## Step 3 — Build & Run

```bash
cd /path/to/mattermost

# Build and start all services (traefik + postgres + mattermost)
docker compose -f production.yml up --build -d

# Build only the mattermost image (cross-compile for linux/amd64 on Apple Silicon)
DOCKER_DEFAULT_PLATFORM=linux/amd64 docker compose -f production.yml build mattermost
```

First build takes ~20–30 min (Go + npm). Subsequent builds are fast due to layer caching on `go.mod` / `package.json` files.

---

## Step 4 — Verify the Image

### Check version
```bash
docker run --rm \
  --entrypoint /mattermost/bin/mattermost \
  mattermost-custom:11.7.2-google-sso version
# → Version: 11.7.2
```

### Check Google provider is compiled in
```bash
strings server/bin/mattermost | grep oauthgoogle
# → *oauthgoogle.GoogleUser
# → *oauthgoogle.googleName
# → *oauthgoogle.googleEmail
```

### Check running container API
```bash
# Get container private IP
IP=$(docker inspect mattermost \
  --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')

# Hit client config endpoint
curl -s "http://$IP:8065/api/v4/config/client?format=old" \
  | python3 -m json.tool | grep -i google

# Expected output:
# "EnableSignUpWithGoogle": "true",
```

---

## Step 5 — Push to Registry

```bash
docker push mattermost-custom:11.7.2-google-sso
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
| `compose/production/mattermost/Dockerfile` | Multi-stage — builds Go + webapp internally, replaces in official image |
| `production.yml` | Docker Compose for traefik + postgres + mattermost |

---

## Notes

- The `go.work` file created during build is gitignored — safe to leave.
- CSS ordering warnings during webapp build are pre-existing in the codebase, not from our changes.
- The `go work init` step inside Docker is required because `server/public` is a separate Go module.
- The `-ldflags BuildEnterpriseReady=true` in Stage 1 is belt-and-suspenders alongside the source code fix in `about_build_modal.tsx` — both ensure "Enterprise Edition" is shown.
