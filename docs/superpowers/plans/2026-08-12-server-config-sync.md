# Server Config Sync Implementation Plan

> **Status: executed, then superseded in places.** A whole-branch review after
> all six tasks landed found integration defects the per-task reviews could not
> see, and the fixes changed decisions recorded below. Do not copy code
> verbatim from this plan — read the current file instead. Most notably:
> Keycloak now listens on `KEYCLOAK_PORT` (8081) inside its container and is
> published 1:1, so every `keycloak:8080` upstream in the `nginx/ohs-player.conf`
> listing below is now `keycloak:8081`; `KEYCLOAK_PUBLIC_URL` is
> `http://keycloak.localhost:8081`, not `http://localhost:8081`; and
> `VITE_FHIR_BASE_URL` is the relative `/fhir`, so only two values change in
> proxy mode, not three. See the corrections in the spec.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the improvements from the 2026-07-29 server deployment into this repository without regressing its local-development focus, and fix the defects that comparison exposed.

**Architecture:** Six independent commits against a Docker Compose stack driven by `dev.sh`, a bash wrapper that renders `*.example` templates with `envsubst` and then calls `docker compose`. Tasks 1–4 repair the stack (missing build files, missing environment variables, a restored Postgres service, the Keycloak realm and theme). Task 5 adds an optional in-network reverse proxy behind a Compose profile. Task 6 fixes a profile bug and updates documentation.

**Tech Stack:** Docker Compose v2, `postgres:18`, `quay.io/keycloak/keycloak:26.5.0`, `hapiproject/hapi:v8.8.0-1`, `nginx:1.27-alpine`, GNU `envsubst` (gettext), bash 4+.

**Spec:** `docs/superpowers/specs/2026-08-12-server-config-sync-design.md`

## Global Constraints

- The reference copy of the server deployment is at `/home/kiarie/lab/ohs-foundation/20260729/temp-3`. Read from it; never copy wholesale over this repository.
- Do not modify these files — this repository is deliberately ahead of the server on all of them: `data-pipes/config/application.yaml`, `data-pipes/config/postgres-analytics.json.example`, `hapi-fhir/application-auth.yaml.example`, `hapi-fhir/application-no-auth.yaml.example`, and the `postgres-synth` / `hapi-synth` / `postgres-analytics` / `pipeline-controller` / `superset` service definitions.
- `POSTGRES_PORT` is the **in-container** Postgres port and must be `5432`. `POSTGRES_HOST_PORT` is the host publish port and defaults to `5433`.
- Every variable referenced in `docker-compose.yaml` must be defined in `.env.example`. Verify with the command in Task 3.
- Secrets in `.env.example` use the literal marker `[generated]`; `dev.sh` replaces each with `openssl rand -hex 24` output.
- Never commit `.env`, `keycloak/ohs-player-realm.json`, `hapi-fhir/application-auth.yaml`, `hapi-fhir/application-no-auth.yaml`, or `data-pipes/config/postgres-analytics.json` — all are gitignored rendered artifacts.
- Do not port `docker-compose.server.yml`, `.env.server`, or `eed` from the server copy.
- Commit messages follow cbea.ms seven rules: imperative subject, 50 characters or fewer, no trailing period, body wrapped at 72 explaining what and why. No AI attribution trailers of any kind.

---

### Task 1: Add the missing build files

`docker-compose.yaml` builds `fhir-gateway` from `./Dockerfile` and `ohs-player-web` from `./Dockerfile.web`. Neither file has ever been committed (`git log --all -- Dockerfile` returns nothing), so `./dev.sh up` fails on a fresh clone. All three files below are deployment-agnostic and are copied from the server without edits.

**Files:**
- Create: `Dockerfile`
- Create: `Dockerfile.web`
- Create: `nginx/spa.conf`

**Interfaces:**
- Consumes: nothing.
- Produces: build args `GATEWAY_REF`, `PLUGIN_REF` (consumed by `Dockerfile`) and `WEB_REF`, `VITE_FHIR_BASE_URL`, `VITE_OIDC_ISSUER`, `VITE_CLIENT_ID`, `VITE_FHIR_VERSION` (consumed by `Dockerfile.web`). Task 3 defines the `.env` variables that feed them.

- [ ] **Step 1: Verify the files are genuinely absent**

Run:
```bash
ls Dockerfile Dockerfile.web nginx/spa.conf 2>&1
git log --all --oneline -- Dockerfile Dockerfile.web
```
Expected: three "No such file or directory" errors, and no commits listed. If any file exists, stop and re-read the spec — this task assumes a clean absence.

- [ ] **Step 2: Create `Dockerfile`**

```dockerfile
# syntax=docker/dockerfile:1

###############################################################################
# Stage 1: build fhir-gateway (the host application)
###############################################################################
FROM maven:3.9-eclipse-temurin-21 AS gateway-build
WORKDIR /src

# Clone + build the gateway. Pin to a tag/branch via GATEWAY_REF if you want.
ARG GATEWAY_REF=main
RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch "${GATEWAY_REF}" \
    https://github.com/ohs-foundation/fhir-gateway.git .

# Cache Maven deps across builds, then package
RUN --mount=type=cache,target=/root/.m2 \
    mvn -B package -Dspotless.apply.skip=true -DskipTests

# Normalize the exec jar to a stable name (version may change between releases)
RUN cp exec/target/fhir-gateway-exec.jar /fhir-gateway.jar

###############################################################################
# Stage 2: build the ohs-player plugin (access-checker / custom endpoints)
###############################################################################
FROM maven:3.9-eclipse-temurin-21 AS plugin-build
WORKDIR /src

ARG PLUGIN_REF=main
RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch "${PLUGIN_REF}" \
    https://github.com/ohs-foundation/ohs-player-reference-backend.git .

RUN --mount=type=cache,target=/root/.m2 \
    mvn -B clean package -DskipTests

RUN cp target/ohs-player-backend-extensions-*.jar /ohs-player-backend-extensions.jar

###############################################################################
# Stage 3: runtime
###############################################################################
FROM eclipse-temurin:21-jre AS runtime
WORKDIR /app

COPY --from=gateway-build /fhir-gateway.jar /app/fhir-gateway.jar
COPY --from=plugin-build  /ohs-player-backend-extensions.jar /app/plugins/ohs-player-backend-extensions.jar
# Allow-list / config files the gateway reads via ALLOWED_QUERIES_FILE et al.
# (resolved relative to WORKDIR /app). They ship in the gateway repo's resources/.
COPY --from=gateway-build /src/resources /app/resources

# Gateway listens on 8080 inside the container by default
EXPOSE 8080

# loader.path makes Spring Boot pick up the plugin's access-checkers / endpoints
ENTRYPOINT ["java", "-Dloader.path=/app/plugins", \
    "-jar", "/app/fhir-gateway.jar", \
    "--server.port=8080"]
```

- [ ] **Step 3: Create `Dockerfile.web`**

```dockerfile
# syntax=docker/dockerfile:1

###############################################################################
# Build the ohs-player-web SPA from a clone of the web portal monorepo
###############################################################################
FROM node:22-alpine AS web-build
WORKDIR /repo
RUN apk add --no-cache git
RUN corepack enable && corepack prepare pnpm@9.15.4 --activate

ARG WEB_REF=main
RUN git clone --depth 1 --branch "${WEB_REF}" \
    https://github.com/ohs-foundation/ohs-player-reference-web-portal.git .

RUN pnpm install --frozen-lockfile

# Browser-facing config, baked into the bundle at build time.
ARG VITE_FHIR_BASE_URL=http://localhost:8083/fhir
ARG VITE_OIDC_ISSUER=http://localhost:8081/realms/ohs-player
ARG VITE_CLIENT_ID=ohs-player-client
ARG VITE_FHIR_VERSION=R4
ENV VITE_FHIR_BASE_URL=$VITE_FHIR_BASE_URL \
    VITE_OIDC_ISSUER=$VITE_OIDC_ISSUER \
    VITE_CLIENT_ID=$VITE_CLIENT_ID \
    VITE_FHIR_VERSION=$VITE_FHIR_VERSION

RUN pnpm exec turbo run build --filter=ohs-player-web

###############################################################################
# Serve the static bundle
###############################################################################
FROM nginx:1.27-alpine
COPY --from=web-build /repo/apps/ohs-player-web/dist /usr/share/nginx/html
COPY nginx/spa.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
```

- [ ] **Step 4: Create `nginx/spa.conf`**

```nginx
server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    # Docker embedded DNS — resolve the gateway upstream at request time so a
    # recreated fhir-gateway container (new IP) is picked up without rebuilding/
    # restarting this web container. Without this, nginx pins the IP at startup.
    resolver 127.0.0.11 valid=30s ipv6=off;

    # Proxy both the plugin's custom endpoints (/api/*, no CORS) AND the FHIR base
    # (/fhir, /fhir/*) to the gateway so the SPA calls everything SAME-ORIGIN.
    # Same-origin requests skip CORS preflight entirely — avoiding the "redirect
    # not allowed for preflight" failure when the SPA used the gateway subdomain.
    # Set VITE_FHIR_BASE_URL=/fhir (relative) so the app targets this origin.
    # `/fhir` prefix covers the base (POST transaction) and all sub-resources.
    location /api/ {
        set $ohs_gateway fhir-gateway;
        proxy_pass http://$ohs_gateway:8080;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        client_max_body_size 25m;   # headroom for bulk-import payloads
    }

    location /fhir {
        set $ohs_gateway_fhir fhir-gateway;
        proxy_pass http://$ohs_gateway_fhir:8080;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        client_max_body_size 25m;
    }

    # SPA history fallback for client-side routes.
    location / {
        try_files $uri $uri/ /index.html;
    }
}
```

- [ ] **Step 5: Verify the files match the server copy exactly**

Run:
```bash
SRC=/home/kiarie/lab/ohs-foundation/20260729/temp-3
diff "$SRC/Dockerfile" Dockerfile && diff "$SRC/Dockerfile.web" Dockerfile.web && diff "$SRC/nginx/spa.conf" nginx/spa.conf && echo "ALL MATCH"
```
Expected: `ALL MATCH`. If the server copy is unavailable, skip this step — the content above is authoritative.

- [ ] **Step 6: Verify compose can now resolve both build contexts**

Run: `docker compose --profile full config >/dev/null && echo OK`
Expected: `OK`. Warnings about unset variables are expected here and are fixed in Task 3.

- [ ] **Step 7: Commit**

```bash
git add Dockerfile Dockerfile.web nginx/spa.conf
git commit -m "Add gateway and web portal build files" -m "docker-compose.yaml builds fhir-gateway from ./Dockerfile and
ohs-player-web from ./Dockerfile.web, but neither file was ever
committed, so a fresh clone could not start the stack.

Both build from source: the gateway image packages the fhir-gateway
jar together with the ohs-player-reference-backend plugin on the
Spring Boot loader path, and the web image builds the SPA and serves
it behind nginx/spa.conf, which proxies /fhir and /api to the gateway
so the browser talks to a single origin."
```

---

### Task 2: Restore the Postgres service

Commit 6aee453 removed the `postgres` service in favour of the server's external-database model, which left `postgres/init/01-init.sh` orphaned and made a fresh local start depend on host setup. Bring the service back, and fix the `POSTGRES_PORT` collision at the same time: `docker-compose.yaml` uses that variable as the in-container port (`KC_DB_URL_PORT`, HAPI's `DB_PORT`) while `.env.example` sets it to the host value `5433`.

**Files:**
- Modify: `docker-compose.yaml` (insert the `postgres` service before `keycloak` at line 20; add `depends_on` to `keycloak` and `hapi-fhir`; add `postgres_data` to the `volumes:` block at line 298)

**Interfaces:**
- Consumes: `postgres/init/01-init.sh`, which interpolates `${KEYCLOAK_DB_PASSWORD}` and `${HAPI_FHIR_DB_PASSWORD}` from the container environment.
- Produces: a service named `postgres` on `fhir_net`, listening on container port `5432`. Task 3 sets `POSTGRES_HOST=postgres` and `POSTGRES_PORT=5432` to match.

- [ ] **Step 1: Insert the `postgres` service**

Add immediately after the `services:` line in `docker-compose.yaml`, before `keycloak:`:

```yaml
  # Local Postgres for Keycloak and the transactional HAPI FHIR server.
  # postgres/init/01-init.sh runs once on volume creation and provisions the
  # keycloak and hapi_fhir roles/databases from the passwords below.
  #
  # To use an external instance instead, set POSTGRES_HOST in .env to its
  # hostname (or host.docker.internal for one running on this machine) and
  # provision the roles yourself — see the README.
  postgres:
    image: postgres:18
    container_name: ohs-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${POSTGRES_ADMIN_PASSWORD}
      KEYCLOAK_DB_PASSWORD: ${KEYCLOAK_DB_PASSWORD}
      HAPI_FHIR_DB_PASSWORD: ${HAPI_FHIR_DB_PASSWORD}
    volumes:
      # Mounted at /var/lib/postgresql, not /var/lib/postgresql/data: postgres:18
      # moved its default PGDATA and refuses to start against a volume at the old
      # path unless PGDATA is set explicitly. Matches postgres-synth below.
      - postgres_data:/var/lib/postgresql
      - ./postgres/init:/docker-entrypoint-initdb.d:ro
    ports:
      - "127.0.0.1:${POSTGRES_HOST_PORT:-5433}:5432"
    networks: [fhir_net]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s

```

- [ ] **Step 2: Make Keycloak wait for Postgres**

In the `keycloak` service, add a `depends_on` block immediately before its `networks: [fhir_net]` line:

```yaml
    depends_on:
      postgres:
        condition: service_healthy
```

- [ ] **Step 3: Make HAPI FHIR wait for Postgres**

The `hapi-fhir` service already has a `depends_on` block. Extend it so it reads:

```yaml
    depends_on:
      postgres:
        condition: service_healthy
      keycloak:
        condition: service_healthy
```

- [ ] **Step 4: Declare the volume**

In the `volumes:` block at the end of the file, add `postgres_data:` as the first entry, so the block reads:

```yaml
volumes:
  postgres_data:
  postgres_synth_data:
  postgres_analytics_data:
  superset_home:
```

- [ ] **Step 5: Verify the compose file parses and the service is wired correctly**

Run:
```bash
docker compose config 2>/dev/null | grep -A2 'KC_DB_URL_PORT\|DB_PORT'
docker compose config 2>/dev/null | grep -c 'ohs-postgres'
```
Expected: the port values resolve (they read `POSTGRES_PORT`, corrected in Task 3), and the container name appears once.

- [ ] **Step 6: Commit**

```bash
git add docker-compose.yaml
git commit -m "Restore Postgres as a local compose service" -m "Commit 6aee453 removed the postgres service in favour of an
external, pre-provisioned instance. That suits the server but not a
local development repository: nothing starts until the developer
provisions a database by hand, and postgres/init/01-init.sh was left
mounted by nothing.

The service mounts that init script again, so the keycloak and
hapi_fhir roles are created on first boot. An external instance
remains one .env line away via POSTGRES_HOST; the existing
host.docker.internal extra_hosts entries still cover a host-run
database."
```

---

### Task 3: Complete `.env.example`

Twelve variables referenced by `docker-compose.yaml` are undefined in `.env.example`, so Compose substitutes empty strings: the gateway gets a blank `TOKEN_ISSUER` and blank IAM credentials, and the web image is built with a blank FHIR base URL. This task adds them with local defaults and fixes `POSTGRES_PORT`.

**Files:**
- Modify: `.env.example` (full rewrite — content below)

**Interfaces:**
- Consumes: the service and variable names established in Task 2 (`POSTGRES_HOST=postgres`, `POSTGRES_PORT=5432`, `POSTGRES_HOST_PORT=5433`).
- Produces: `FHIR_GATEWAY_KEYCLOAK_CLIENT_ID` and `FHIR_GATEWAY_KEYCLOAK_CLIENT_SECRET`, consumed by the realm template and the `dev.sh` render list in Task 4; `PUBLIC_HOST` and `PROXY_PORT`, consumed by the nginx service in Task 5.

- [ ] **Step 1: Confirm the gap before changing anything**

Run:
```bash
grep -oE '\$\{[A-Z_]+' docker-compose.yaml | sed 's/${//' | sort -u > /tmp/compose_vars.txt
grep -oE '^[A-Z_]+=' .env.example | tr -d '=' | sort -u > /tmp/env_vars.txt
comm -23 /tmp/compose_vars.txt /tmp/env_vars.txt
```
Expected output (12 lines, plus `POSTGRES_HOST_PORT` if Task 2 is already applied):
```
ACCESS_CHECKER
FHIR_GATEWAY_KEYCLOAK_CLIENT_ID
FHIR_GATEWAY_KEYCLOAK_CLIENT_SECRET
GATEWAY_REF
KEYCLOAK_PUBLIC_URL
PLUGIN_REF
POSTGRES_HOST
RUN_MODE
VITE_CLIENT_ID
VITE_FHIR_BASE_URL
VITE_FHIR_VERSION
WEB_REF
```

- [ ] **Step 2: Replace `.env.example` with the completed template**

```dotenv
# =============================================================================
# Local development environment
#
# This file is a template. Running `./dev.sh up` (or `./dev.sh render`)
# auto-generates `.env` from this file (replacing every [generated] marker
# with a unique random secret) and renders hapi-fhir/application-*.yaml
# from their .example templates.
#
# To create `.env` manually instead:
#
#     cp .env.example .env
#     # replace [generated] values with your own secrets
#
# To generate your own strong random secrets:
#
#     openssl rand -hex 24
#
# `.env` is gitignored and must never be committed.
# =============================================================================

# --- Secrets -----------------------------------------------------------------
# Postgres superuser password (used by the postgres container on first boot)
POSTGRES_ADMIN_PASSWORD=[generated]

# Password for the `keycloak` database role
KEYCLOAK_DB_PASSWORD=[generated]

# Bootstrap admin credentials for the Keycloak admin console
KEYCLOAK_ADMIN_USERNAME=admin
KEYCLOAK_ADMIN_PASSWORD=[generated]

# Password for the `hapi_fhir` database role
HAPI_FHIR_DB_PASSWORD=[generated]

# --- Database ----------------------------------------------------------------
# Hostname the containers use to reach Postgres. `postgres` is the service in
# docker-compose.yaml. To use an external instance, set this to its hostname or
# IP — or to host.docker.internal for one running on this machine — and
# provision the keycloak/hapi_fhir roles yourself (see the README).
POSTGRES_HOST=postgres

# Port Postgres listens on *inside* the network. Leave at 5432 unless an
# external instance listens elsewhere. This is NOT the host port; see
# POSTGRES_HOST_PORT under Host ports.
POSTGRES_PORT=5432

# --- Keycloak ----------------------------------------------------------------
# Realm name
# NOTE: Changing this also requires renaming keycloak/ohs-player-realm.json to
# <new-realm>-realm.json and updating the volume mount in docker-compose.yaml
# (Keycloak 26.x requires the filename to match <realm>-realm.json).
KEYCLOAK_REALM=ohs-player

# Canonical public base URL of Keycloak (scheme + host[:port], NO trailing
# slash, NO /realms path). This is the issuer authority: it is baked into the
# SPA, set as Keycloak's hostname, and used by the gateway to validate the
# token issuer — so it must be reachable BOTH from the browser AND from inside
# the gateway (and HAPI, in auth mode) containers. The realm path is appended
# automatically. See the proxy-mode block at the end of this file for the
# value to use when running behind the bundled nginx.
KEYCLOAK_PUBLIC_URL=http://localhost:8081

# Client ID used by the OHS Player application
OHS_PLAYER_KEYCLOAK_CLIENT_ID=ohs-player-client

# FHIR gateway admin client — confidential service-account client the gateway's
# IAM provider uses (client_credentials) to manage users, groups and roles in
# Keycloak. Maps to IAM_PROVIDER_CLIENT_ID/SECRET on the fhir-gateway service.
FHIR_GATEWAY_KEYCLOAK_CLIENT_ID=fhir-gateway-admin
FHIR_GATEWAY_KEYCLOAK_CLIENT_SECRET=[generated]

# --- HAPI FHIR auth (only used when HAPI_CONFIG=application-auth.yaml) ------
# Client ID used by HAPI FHIR for token validation
HAPI_FHIR_SERVER_KEYCLOAK_CLIENT_ID=hapi-fhir-server-client

# Client secret for the `hapi-fhir-server-client` Keycloak client
HAPI_FHIR_SERVER_KEYCLOAK_CLIENT_SECRET=[generated]

# Default user username for the `hapi-fhir-server-client` Keycloak service account
HAPI_FHIR_SERVER_DEFAULT_KEYCLOAK_USERNAME=hapi-fhir-server-user

# Client secret for the `ohs-player-client` Keycloak client
OHS_PLAYER_KEYCLOAK_CLIENT_SECRET=[generated]

# Service account username for the `ohs-player-client` Keycloak client
OHS_PLAYER_DEFAULT_KEYCLOAK_USERNAME=ohs-player-user

# Host and port of the application using `ohs-player-client` (no protocol).
# Must match the origin the browser uses — it populates the ohs-player-client
# redirect URIs and web origins in the realm.
OHS_PLAYER_APP_HOST=localhost:8084

# --- FHIR gateway access control ---------------------------------------------
# Registered access checkers in the gateway build: "list", "patient",
# "permission". "permissive" disables access control entirely, but only when
# RUN_MODE=DEV — use that pair for local debugging only, never as a default.
ACCESS_CHECKER=permission
RUN_MODE=PROD

# --- Build refs (git branch or tag to clone and build) -----------------------
# GATEWAY_REF  ohs-foundation/fhir-gateway
# PLUGIN_REF   ohs-foundation/ohs-player-reference-backend
# WEB_REF      ohs-foundation/ohs-player-reference-web-portal
GATEWAY_REF=main
PLUGIN_REF=main
WEB_REF=main

# --- Web app build args (baked into the SPA bundle at build time) ------------
# Browser-facing values. Changing any of these requires a rebuild:
# `./dev.sh up --web` re-runs the build. The OIDC issuer is derived from
# KEYCLOAK_PUBLIC_URL + KEYCLOAK_REALM and needs no separate variable.
VITE_FHIR_BASE_URL=http://localhost:8083/fhir
VITE_CLIENT_ID=ohs-player-client
VITE_FHIR_VERSION=R4

# --- Host ports --------------------------------------------------------------
# Change these if the defaults conflict with services already running on your
# machine.  Only the *host* side of the mapping is affected; containers still
# listen on their normal internal ports.
# Postgres defaults to 5433 to avoid conflicts with a local postgres install.
POSTGRES_HOST_PORT=5433
KEYCLOAK_PORT=8081
HAPI_FHIR_PORT=8082
FHIR_GATEWAY_PORT=8083
OHS_PLAYER_WEB_PORT=8084

# --- Synth stack ports (profile: --synth / --pipes) --------------------------
# Isolated HAPI FHIR + PostgreSQL for synthetic/test data.
POSTGRES_SYNTH_PORT=5435
HAPI_SYNTH_PORT=8085

# --- Analytics pipeline ports (profile: --pipes) -----------------------------
POSTGRES_ANALYTICS_PORT=5434
PIPELINE_PORT=8090
SUPERSET_PORT=8088

# Superset encryption key (required — set any long random string)
SUPERSET_SECRET_KEY=[generated]

# FHIR server the pipeline reads from.
# Switch to http://hapi-fhir:8080/fhir once transactional data is ready.
PIPELINE_FHIR_SOURCE=http://hapi-synth:8080/fhir

# JVM heap for the pipeline controller (tune to ~50% of Docker memory limit)
PIPELINE_JAVA_OPTS=-Xms512m -Xmx4g

# --- Auth mode ---------------------------------------------------------------
# Controls which HAPI FHIR config file is mounted into the container
#   application-no-auth.yaml  — HAPI FHIR runs open, no token validation
#   application-auth.yaml     — HAPI FHIR validates tokens against Keycloak
#
# Switch modes by editing this value and re-running `./dev.sh up`
HAPI_CONFIG=application-no-auth.yaml

# --- Reverse proxy (profile: --proxy) ----------------------------------------
# Public hostname the bundled nginx answers on, and the host port it binds.
# Browsers resolve any *.localhost name to 127.0.0.1 without an /etc/hosts
# entry; for a different name, add one. Containers resolve this name through
# the nginx service's network alias, so no extra host mapping is needed.
PUBLIC_HOST=ohs-player.localhost
PROXY_PORT=80

# Running behind the proxy puts the SPA, the gateway and Keycloak on one
# origin. Three values above must change together to match — replace them
# with these, then re-run `./dev.sh up --proxy`:
#
#   KEYCLOAK_PUBLIC_URL=http://ohs-player.localhost
#   VITE_FHIR_BASE_URL=http://ohs-player.localhost/fhir
#   OHS_PLAYER_APP_HOST=ohs-player.localhost
#
# The first is baked into the realm import and the other two into the SPA
# bundle, so `./dev.sh up --proxy` must re-render and rebuild after the edit.
```

- [ ] **Step 3: Verify no variable is left undefined**

Run:
```bash
grep -oE '\$\{[A-Z_]+' docker-compose.yaml | sed 's/${//' | sort -u > /tmp/compose_vars.txt
grep -oE '^[A-Z_]+=' .env.example | tr -d '=' | sort -u > /tmp/env_vars.txt
comm -23 /tmp/compose_vars.txt /tmp/env_vars.txt
```
Expected: no output at all.

- [ ] **Step 4: Verify Compose substitutes cleanly from a fresh render**

Run:
```bash
./dev.sh clean
./dev.sh render
docker compose --profile full config 2>&1 >/dev/null | grep -i 'variable is not set' || echo "NO WARNINGS"
```
Expected: `NO WARNINGS`.

- [ ] **Step 5: Verify the port split resolves correctly**

Run: `docker compose config | grep -E 'KC_DB_URL_PORT|DB_PORT:|5433'`
Expected: `KC_DB_URL_PORT` and HAPI's `DB_PORT` are `5432`; `5433` appears only in the `postgres` service's published-ports mapping.

- [ ] **Step 6: Commit**

```bash
git add .env.example
git commit -m "Define every variable compose references" -m "Twelve variables used in docker-compose.yaml had no entry in
.env.example, so Compose substituted empty strings: the gateway
started with a blank TOKEN_ISSUER and blank IAM credentials, and the
web image was built with a blank FHIR base URL.

POSTGRES_PORT also carried two meanings. Compose uses it as the
in-container port for Keycloak and HAPI, but the template set it to
5433, a host-publish value. The host mapping moves to
POSTGRES_HOST_PORT and POSTGRES_PORT becomes 5432, which is what both
consumers actually want."
```

---

### Task 4: Land the realm client, login theme, and renderer fix

The realm template and theme are already present in the working tree, uncommitted. Committing them alone would ship a latent bug: `dev.sh` renders the realm through `envsubst` with an explicit allow-list, and the two new `FHIR_GATEWAY_KEYCLOAK_CLIENT_*` variables are not on it, so Keycloak would import a client whose ID is the literal string `${FHIR_GATEWAY_KEYCLOAK_CLIENT_ID}` and the gateway's IAM provider could never authenticate.

**Files:**
- Modify: `dev.sh:101` (the realm render's variable list)
- Commit (already modified in the working tree): `keycloak/ohs-player-realm.json.example`
- Commit (currently untracked): `keycloak/themes/ohs/login/theme.properties`, `keycloak/themes/ohs/login/messages/messages_en.properties`, `keycloak/themes/ohs/login/resources/css/ohs.css`, `keycloak/themes/ohs/login/resources/img/ohs-logo.png`, `keycloak/themes/ohs/login/resources/img/login-bg.svg`

**Interfaces:**
- Consumes: `FHIR_GATEWAY_KEYCLOAK_CLIENT_ID` and `FHIR_GATEWAY_KEYCLOAK_CLIENT_SECRET` from Task 3.
- Produces: a rendered `keycloak/ohs-player-realm.json` containing a real `fhir-gateway-admin` client, matching the `IAM_PROVIDER_CLIENT_ID`/`IAM_PROVIDER_CLIENT_SECRET` the `fhir-gateway` service already passes.

- [ ] **Step 1: Confirm the working-tree state is what this task expects**

Run:
```bash
git diff --stat keycloak/ohs-player-realm.json.example
git status --porcelain keycloak/themes
grep -c 'FHIR_GATEWAY_KEYCLOAK_CLIENT' keycloak/ohs-player-realm.json.example
```
Expected: the realm example shows roughly 63 added lines, `keycloak/themes/` is untracked (`??`), and the grep count is 4 — one line each for the service-account username, `serviceAccountClientId`, `clientId`, and `secret`. Anything below 4 means the realm changes are missing; re-check the working tree before continuing.

- [ ] **Step 2: Reproduce the bug before fixing it**

Run:
```bash
./dev.sh render
grep -n 'FHIR_GATEWAY_KEYCLOAK_CLIENT' keycloak/ohs-player-realm.json
```
Expected: FAIL — the rendered file still contains literal `${FHIR_GATEWAY_KEYCLOAK_CLIENT_ID}` and `${FHIR_GATEWAY_KEYCLOAK_CLIENT_SECRET}` placeholders. That is the defect.

- [ ] **Step 3: Add the two variables to the realm render list**

In `dev.sh`, the `render_templates` function calls `render` for the realm with a single-quoted variable list. Append the two names to the end of that list, so line 101 reads:

```bash
           '${KEYCLOAK_REALM} ${OHS_PLAYER_KEYCLOAK_CLIENT_ID} ${OHS_PLAYER_KEYCLOAK_CLIENT_SECRET} ${OHS_PLAYER_DEFAULT_KEYCLOAK_USERNAME} ${OHS_PLAYER_APP_HOST} ${HAPI_FHIR_SERVER_KEYCLOAK_CLIENT_ID} ${HAPI_FHIR_SERVER_KEYCLOAK_CLIENT_SECRET} ${HAPI_FHIR_SERVER_DEFAULT_KEYCLOAK_USERNAME} ${FHIR_GATEWAY_KEYCLOAK_CLIENT_ID} ${FHIR_GATEWAY_KEYCLOAK_CLIENT_SECRET}'
```

- [ ] **Step 4: Verify the render is now clean**

Run:
```bash
./dev.sh render
grep -c '\${' keycloak/ohs-player-realm.json
grep -o '"clientId": "fhir-gateway-admin"' keycloak/ohs-player-realm.json
```
Expected: the placeholder count is `0`, and the `clientId` line is found.

- [ ] **Step 5: Verify the rendered realm is valid JSON**

Run: `python3 -m json.tool keycloak/ohs-player-realm.json >/dev/null && echo "VALID JSON"`
Expected: `VALID JSON`.

- [ ] **Step 6: Verify the theme is complete**

Run:
```bash
cat keycloak/themes/ohs/login/theme.properties
ls -R keycloak/themes/ohs
```
Expected: `theme.properties` declares a parent theme, and the tree contains `messages/messages_en.properties`, `resources/css/ohs.css`, `resources/img/ohs-logo.png`, `resources/img/login-bg.svg`. `docker-compose.yaml` already mounts `./keycloak/themes` read-only — no compose change is needed.

- [ ] **Step 7: Commit**

```bash
git add dev.sh keycloak/ohs-player-realm.json.example keycloak/themes
git commit -m "Add gateway admin client and OHS login theme" -m "The fhir-gateway service passes IAM_PROVIDER_CLIENT_ID and
IAM_PROVIDER_CLIENT_SECRET so its IAM provider can manage users,
groups and roles, but the realm template declared no such client. Add
the confidential service-account client, restricted to the
client_credentials grant and holding only the realm-management roles
it needs, plus the OHS login theme the realm now selects.

dev.sh renders the realm through envsubst with an explicit variable
list, so the new placeholders would have been imported verbatim as a
client literally named ${FHIR_GATEWAY_KEYCLOAK_CLIENT_ID}. Extend the
list to cover them."
```

---

### Task 5: Add the reverse-proxy profile

The server fronts the stack with a host-installed nginx plus a `docker-compose.server.yml` override whose only job is an `extra_hosts` hairpin, so containers can resolve the public Keycloak hostname back to the host. Running nginx *inside* the Compose network removes that problem: a network alias makes the public name resolvable from every container through Docker's embedded DNS. Same-origin is the default layout because the gateway's `/api/*` routes have no CORS interceptor.

**Files:**
- Create: `nginx/ohs-player.conf`
- Create: `nginx/ohs-player-subdomains.conf.example` (copied verbatim from the server as the documented alternative)
- Modify: `docker-compose.yaml` (add the `nginx` service after `ohs-player-web`)
- Modify: `dev.sh` (`parse_profiles`, `cmd_down`, `cmd_reset`, `usage`)

**Interfaces:**
- Consumes: `PUBLIC_HOST` and `PROXY_PORT` from Task 3.
- Produces: profile name `proxy`, flag `--proxy`.

- [ ] **Step 1: Create `nginx/ohs-player.conf`**

Ported from the server's `ohs-player.conf.example`: same routing, but `proxy_pass` targets are Compose service names rather than `127.0.0.1:808x`, and the proxy headers are inline because `/etc/nginx/proxy_params` ships with Debian's nginx package, not the Alpine image.

```nginx
# Same-origin front for the local OHS Player stack (profile: proxy).
#
# Serving the SPA, the gateway and Keycloak from one origin avoids CORS
# entirely — which matters because the gateway plugin's /api/* servlets send
# no CORS headers of their own. The subdomain alternative in
# ohs-player-subdomains.conf.example has to work around that; this does not.
#
# Enable with: ./dev.sh up --web --proxy
# See the proxy block in .env.example for the three values that must change.

server {
    listen 80;
    server_name _;

    # Docker embedded DNS — resolve upstreams per request so a recreated
    # container (new IP) is picked up without restarting nginx.
    resolver 127.0.0.11 valid=30s ipv6=off;

    # --- Keycloak (OIDC issuer paths) ---------------------------------------
    # /realms   token, authorize, JWKS, and the login pages
    # /resources theme assets referenced by those pages
    # /admin, /js  the admin console
    location /realms/ {
        set $ohs_keycloak keycloak;
        proxy_pass http://$ohs_keycloak:8080;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host  $host;
    }

    location /resources/ {
        set $ohs_keycloak_res keycloak;
        proxy_pass http://$ohs_keycloak_res:8080;
        proxy_set_header Host              $host;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host  $host;
    }

    location /admin/ {
        set $ohs_keycloak_admin keycloak;
        proxy_pass http://$ohs_keycloak_admin:8080;
        proxy_set_header Host              $host;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host  $host;
    }

    location /js/ {
        set $ohs_keycloak_js keycloak;
        proxy_pass http://$ohs_keycloak_js:8080;
        proxy_set_header Host              $host;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # --- FHIR gateway --------------------------------------------------------
    # /fhir  the FHIR base and all sub-resources
    # /api   the ohs-player plugin's custom endpoints
    location /fhir {
        set $ohs_gateway fhir-gateway;
        proxy_pass http://$ohs_gateway:8080;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        client_max_body_size 25m;   # headroom for bulk-import payloads
    }

    location /api/ {
        set $ohs_gateway_api fhir-gateway;
        proxy_pass http://$ohs_gateway_api:8080;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        client_max_body_size 25m;
    }

    # --- Web SPA (everything else) -------------------------------------------
    location / {
        set $ohs_web ohs-player-web;
        proxy_pass http://$ohs_web:80;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

- [ ] **Step 2: Copy the subdomain layout as the documented alternative**

Run:
```bash
cp /home/kiarie/lab/ohs-foundation/20260729/temp-3/nginx/ohs-player-subdomains.conf.example nginx/
```

If the server copy is unavailable, skip this step and drop the file from the commit in Step 8; the same-origin config is the one the profile actually uses.

- [ ] **Step 3: Add the `nginx` service to `docker-compose.yaml`**

Insert after the `ohs-player-web` service, before the synth-stack comment block:

```yaml
  # ---------------------------------------------------------------------------
  # reverse proxy (profile: proxy / full)
  #
  # Puts the SPA, the gateway and Keycloak on one origin, so the browser makes
  # no cross-origin requests and the gateway's CORS-less /api/* routes work.
  #
  # The network alias is the point: containers resolve PUBLIC_HOST to this
  # container through Docker DNS, so the gateway's OIDC discovery against
  # KEYCLOAK_PUBLIC_URL succeeds from inside the network without any host
  # mapping. Browsers reach it on http://${PUBLIC_HOST}:${PROXY_PORT}.
  # ---------------------------------------------------------------------------
  nginx:
    profiles: ["proxy", "full"]
    image: nginx:1.27-alpine
    container_name: ohs-nginx
    restart: unless-stopped
    ports:
      - "${PROXY_PORT:-80}:80"
    volumes:
      - ./nginx/ohs-player.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      keycloak:
        condition: service_healthy
    networks:
      fhir_net:
        aliases:
          - ${PUBLIC_HOST:-ohs-player.localhost}

```

- [ ] **Step 4: Teach `dev.sh` the `--proxy` flag**

In `parse_profiles`, add a case immediately after the `--pipes` line:

```bash
            --proxy) PROFILE_ARGS+=(--profile proxy) ;;
```

and update the error message on the `*)` line to:

```bash
            *)       error "Unknown flag: $arg (expected --web, --pipes, --synth, --proxy, or --full)" ;;
```

- [ ] **Step 5: Include the profile when stopping and resetting**

In `cmd_down` and `cmd_reset`, add `--profile proxy` to each compose invocation, so they read:

```bash
    compose --profile web --profile pipes --profile synth --profile proxy --profile full down
```

```bash
    compose --profile web --profile pipes --profile synth --profile proxy --profile full down --volumes
```

- [ ] **Step 6: Update the usage text**

In `usage`, replace the `up` line and its indented notes with:

```
  up [--web|--pipes|--synth|--proxy|--full]
                              Render configs and start services
                              (no flag = core only)
                              --synth  adds synthetic HAPI + postgres
                              --pipes  adds synth + analytics pipeline + Superset
                              --proxy  adds the same-origin nginx front
```

- [ ] **Step 7: Verify the profile is wired and inert by default**

Run:
```bash
docker compose config --services | grep -c nginx
docker compose --profile proxy config --services | grep -c nginx
./dev.sh up --badflag 2>&1 | grep -q 'expected --web' && echo "FLAG PARSING OK"
docker compose --profile proxy config | grep -A3 'aliases'
```
Expected: `0` for the default profile, `1` with `--profile proxy`, `FLAG PARSING OK`, and the alias resolving to `ohs-player.localhost`.

- [ ] **Step 8: Verify nginx accepts the config**

Run:
```bash
docker run --rm -v "$PWD/nginx/ohs-player.conf:/etc/nginx/conf.d/default.conf:ro" nginx:1.27-alpine nginx -t
```
Expected: `syntax is ok` and `test is successful`. The upstream names do not need to resolve for this check.

- [ ] **Step 9: Commit**

```bash
git add nginx/ohs-player.conf nginx/ohs-player-subdomains.conf.example docker-compose.yaml dev.sh
git commit -m "Add same-origin nginx behind a proxy profile" -m "The server deployment fronts this stack with a host-installed nginx
plus a compose override whose only purpose is an extra_hosts hairpin,
so containers can resolve the public Keycloak hostname back to the
host. Running nginx inside the compose network makes that unnecessary:
a network alias puts the public name in Docker's DNS, reachable from
every container.

Same-origin rather than one subdomain per service, because the gateway
plugin's /api/* servlets send no CORS headers and a single origin
avoids the problem instead of working around it. The subdomain layout
is kept as a documented alternative. The profile is opt-in via
./dev.sh up --proxy; nothing changes without the flag."
```

---

### Task 6: Fix the web profile and update the README

`ohs-player-web` has no `profiles:` key, so it builds and starts on a bare `./dev.sh up` even though `--web` exists to opt into it — the first `up` on a fresh clone pays for an entire SPA build nobody asked for. The README also describes extension services as unimplemented stubs, which stopped being true when the profiles landed.

**Files:**
- Modify: `docker-compose.yaml` (the `ohs-player-web` service; the header comment block at lines 1–17)
- Modify: `README.md`

**Interfaces:**
- Consumes: the `proxy` profile from Task 5, the `postgres` service from Task 2.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Demonstrate the bug**

Run: `docker compose config --services`
Expected: FAIL — `ohs-player-web` is listed even with no profile selected.

- [ ] **Step 2: Put `ohs-player-web` behind its profile**

In the `ohs-player-web` service, add as the first key under the service name:

```yaml
    profiles: ["web", "full"]
```

- [ ] **Step 3: Verify the fix**

Run:
```bash
docker compose config --services | grep -c ohs-player-web
docker compose --profile web config --services | grep -c ohs-player-web
```
Expected: `0` then `1`.

- [ ] **Step 4: Update the compose header comment**

Replace the profile list in the header block at the top of `docker-compose.yaml` with:

```
#   ./dev.sh up          # core services only
#   ./dev.sh up --web    # core + web-portal
#   ./dev.sh up --synth  # core + synthetic-data HAPI + postgres
#   ./dev.sh up --pipes  # core + synth + analytics pipeline + Superset
#   ./dev.sh up --proxy  # core + same-origin nginx front
#   ./dev.sh up --full   # everything
```

and delete the trailing `NOTE:` paragraph about a reverse proxy being out of scope — it no longer is.

- [ ] **Step 5: Correct the stale README claim about extension services**

Replace this paragraph:

```markdown
Extension services currently ship as commented-out stubs in
`docker-compose.yaml`. The `--web` / `--pipes` / `--full` flags will become
functional once those services are wired up.
```

with:

```markdown
Extension services are real, profile-gated services in
`docker-compose.yaml`. `--web` builds and serves the Web Portal SPA;
`--synth` adds an isolated HAPI FHIR and Postgres pair for synthetic test
data, kept separate so test records never touch the transactional server;
`--pipes` adds that synth stack plus FHIR Data Pipes and Superset; `--proxy`
adds the same-origin nginx front described below.
```

- [ ] **Step 6: Add the missing rows to the run-modes table**

Replace the run-modes table with:

| Command | Services started |
|---|---|
| `./dev.sh up` | Core only (Postgres, Keycloak, HAPI FHIR, Gateway) |
| `./dev.sh up --web` | Core + Web Portal |
| `./dev.sh up --synth` | Core + synthetic-data HAPI FHIR and Postgres |
| `./dev.sh up --pipes` | Core + synth stack + FHIR Data Pipes + Superset |
| `./dev.sh up --proxy` | Core + same-origin nginx front |
| `./dev.sh up --full` | Everything |

- [ ] **Step 7: Document the external-Postgres override**

Add after the "Services & Ports" table:

````markdown
### Using an external Postgres

The bundled `postgres` service provisions the `keycloak` and `hapi_fhir`
roles on first boot via `postgres/init/01-init.sh`. To point at an existing
instance instead, set `POSTGRES_HOST` in `.env` to its hostname — or to
`host.docker.internal` for one running on this machine — and create the
roles and databases yourself:

```sql
CREATE USER keycloak WITH PASSWORD '<KEYCLOAK_DB_PASSWORD>';
CREATE DATABASE keycloak OWNER keycloak;
GRANT ALL PRIVILEGES ON DATABASE keycloak TO keycloak;
\c keycloak
GRANT ALL ON SCHEMA public TO keycloak;

\c postgres
CREATE USER hapi_fhir WITH PASSWORD '<HAPI_FHIR_DB_PASSWORD>';
CREATE DATABASE hapi_fhir OWNER hapi_fhir;
GRANT ALL PRIVILEGES ON DATABASE hapi_fhir TO hapi_fhir;
\c hapi_fhir
GRANT ALL ON SCHEMA public TO hapi_fhir;
```

The passwords must match `KEYCLOAK_DB_PASSWORD` and `HAPI_FHIR_DB_PASSWORD`
in `.env`. `POSTGRES_PORT` is the port the containers connect to;
`POSTGRES_HOST_PORT` only affects the bundled service's host mapping.
````

- [ ] **Step 8: Document proxy mode**

Add a new section immediately before "Auth Mode":

````markdown
## Reverse Proxy Mode

By default each service is reached on its own port, which means the browser
makes cross-origin requests. `--proxy` starts an nginx container that serves
the SPA, the gateway and Keycloak from a single origin, so no CORS is
involved — which matters for the gateway plugin's `/api/*` endpoints, which
send no CORS headers of their own.

Three `.env` values must change together, because the first is baked into
the Keycloak realm import and the other two into the SPA bundle:

```dotenv
KEYCLOAK_PUBLIC_URL=http://ohs-player.localhost
VITE_FHIR_BASE_URL=http://ohs-player.localhost/fhir
OHS_PLAYER_APP_HOST=ohs-player.localhost
```

Then:

```bash
./dev.sh up --web --proxy
```

Browsers resolve any `*.localhost` name to `127.0.0.1` with no `/etc/hosts`
entry. For a different hostname, set `PUBLIC_HOST` and add a matching line
to `/etc/hosts`:

```text
127.0.0.1  ohs-player.local
```

Containers do not read your `/etc/hosts` — they resolve `PUBLIC_HOST`
through the nginx service's Docker network alias, which is why no host
mapping is needed on the container side.

`nginx/ohs-player-subdomains.conf.example` documents the alternative layout,
one hostname per service. It needs explicit CORS handling for `/api/*`,
which is why the same-origin config is the default.
````

- [ ] **Step 9: Update the layout tree**

Replace the layout code block's contents with:

```text
ohs-player-reference-infrastructure/
├── keycloak/
│   ├── ohs-player-realm.json.example  # realm template
│   ├── ohs-player-realm.json          # rendered by dev.sh (gitignored)
│   └── themes/ohs/                    # OHS-branded Keycloak login theme
├── hapi-fhir/
│   ├── application-no-auth.yaml.example
│   ├── application-no-auth.yaml     # rendered by dev.sh (gitignored)
│   ├── application-auth.yaml.example
│   ├── application-auth.yaml        # rendered by dev.sh (gitignored)
│   └── health/
│       ├── Healthcheck.java         # source for the container healthcheck
│       └── Healthcheck.class        # compiled binary; recompiled by dev.sh if javac is present
├── postgres/
│   └── init/01-init.sh              # runs once on volume creation
├── data-pipes/                      # ViewDefinitions and pipeline config
├── nginx/
│   ├── spa.conf                     # inside the web image; proxies /fhir and /api
│   ├── ohs-player.conf              # same-origin front (profile: proxy)
│   └── ohs-player-subdomains.conf.example  # per-subdomain alternative
├── Dockerfile                       # fhir-gateway + ohs-player plugin
├── Dockerfile.web                   # ohs-player-web SPA
├── .env.example                     # single source of truth for config
├── .env                             # your local copy (gitignored)
├── docker-compose.yaml              # all services; extensions behind profiles
├── dev.sh                           # lifecycle entrypoint
└── README.md                        # this file
```

`PRODUCTION.md` is listed in the current tree but does not exist — dropping it is intentional.

- [ ] **Step 10: Update the `dev.sh` command reference**

In the "`dev.sh` Commands" code block, change the `up` line to:

```text
./dev.sh up [--web|--synth|--pipes|--proxy|--full]   Render configs and start services
```

In the "What `dev.sh` Does Under the Hood" table, add rows for the new profiles and add `--profile proxy` to the `down` and `reset` rows:

| `dev.sh` subcommand | Equivalent raw commands |
|---|---|
| `./dev.sh up --synth` | `docker compose --profile synth pull` <br> `docker compose --profile synth up -d` |
| `./dev.sh up --proxy` | `docker compose --profile proxy pull` <br> `docker compose --profile proxy up -d` |
| `./dev.sh down` | `docker compose --profile web --profile synth --profile pipes --profile proxy --profile full down` |
| `./dev.sh reset` | `docker compose --profile web --profile synth --profile pipes --profile proxy --profile full down --volumes` |

Also add `${FHIR_GATEWAY_KEYCLOAK_CLIENT_ID} ${FHIR_GATEWAY_KEYCLOAK_CLIENT_SECRET}` to the truncated `envsubst` example in step 2 of "Steps `dev.sh up` performs before compose", and add a fourth rendered pair:

```bash
envsubst '${POSTGRES_ADMIN_PASSWORD}' \
  < data-pipes/config/postgres-analytics.json.example \
  > data-pipes/config/postgres-analytics.json
```

- [ ] **Step 11: Trim the "Out of Scope" section**

Delete the "Public demo deployment" bullet's reverse-proxy clause, leaving:

```markdown
- **Public demo deployment** — VM provisioning, a periodic reset job and a
  public landing page.
```

- [ ] **Step 12: Verify the documentation matches reality**

Run:
```bash
grep -n 'commented-out stubs\|PRODUCTION.md' README.md
grep -c 'proxy' README.md
docker compose --profile full config --services | sort
```
Expected: the first grep returns nothing; the second returns a non-zero count; the service list contains `postgres`, `keycloak`, `hapi-fhir`, `fhir-gateway`, `ohs-player-web`, `nginx`, `postgres-synth`, `hapi-synth`, `postgres-analytics`, `pipeline-controller`, `superset`.

- [ ] **Step 13: Commit**

```bash
git add docker-compose.yaml README.md
git commit -m "Gate the web portal behind its own profile" -m "ohs-player-web carried no profiles key, so a bare ./dev.sh up built
and started the SPA despite --web existing to opt into it. On a fresh
clone that means a full pnpm and turbo build before the core stack is
usable.

The README still described extension services as commented-out stubs
and omitted the synth, pipes and proxy modes entirely; bring it back in
line with what the compose file actually defines, and document the
external-Postgres override that replaced the removed service."
```

---

## Final verification

Run after all six tasks, from a clean tree:

- [ ] `./dev.sh clean && ./dev.sh up` completes and `docker compose ps` shows `postgres`, `keycloak`, `hapi-fhir` and `fhir-gateway` healthy or running, and no `ohs-player-web`.
- [ ] `curl -sf http://localhost:8081/health/ready | grep -q UP`
- [ ] `curl -sf http://localhost:8082/fhir/metadata | grep -q CapabilityStatement`
- [ ] `curl -sf http://localhost:8083/fhir/metadata | grep -q CapabilityStatement`
- [ ] The Keycloak login page at <http://localhost:8081/realms/ohs-player/account> renders the OHS theme (logo and background image, not the stock Keycloak look).
- [ ] The `ohs-player` realm contains a `fhir-gateway-admin` client, and `./dev.sh logs fhir-gateway` shows no IAM authentication errors.
- [ ] `./dev.sh up --web` builds and serves the SPA at <http://localhost:8084>.
- [ ] With proxy-mode `.env` values, `./dev.sh up --web --proxy` serves the SPA, `/fhir/metadata` and `/realms/ohs-player/.well-known/openid-configuration` from `http://ohs-player.localhost`, and browser login completes end to end.
- [ ] `./dev.sh up --pipes` starts `postgres-synth`, `hapi-synth`, `postgres-analytics`, `pipeline-controller` and `superset`, and the control panel answers on <http://localhost:8090>.
- [ ] `git status --porcelain` is empty — no rendered artifact was committed.
