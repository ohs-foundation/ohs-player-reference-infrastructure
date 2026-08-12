# Syncing server configuration into the local stack

**Date:** 2026-08-12
**Status:** Approved, pending implementation

## Context

A server deployment of this stack (snapshot at `~/lab/ohs-foundation/20260729/temp-3`,
dated 2026-07-29) carries work that never made it back into this repository. This
repository is, and remains, the **local development** setup; the goal is to adopt the
server's improvements without adopting its deployment topology.

The two trees have diverged in both directions. The server is ahead on build files,
environment documentation, the Keycloak realm, and reverse-proxy configuration. This
repository is ahead on the synthetic-data stack, the analytics pipeline wiring, and
`dev.sh`. Nothing this repository is ahead on may be overwritten.

### What this repository is ahead on — do not regress

| Item | Repo value | Server value |
|---|---|---|
| `postgres-synth` / `hapi-synth` services | present | absent |
| Pipeline FHIR source | `hapi-synth` | `hapi-fhir` |
| `data-pipes/config/postgres-analytics.json.example` port | `5432` (in-network, correct) | `5434` (host port, wrong for container-to-container) |
| `dev.sh` with `[generated]` secret auto-fill | present | absent |
| README | 296 lines | 111 lines |

**Two rows were removed from this table after implementation — both were wrong.**

- **`fhir-gateway` dependency on `hapi-fhir`.** The table claimed the repository
  already had `service_healthy` and the server had `service_started`. It was the
  other way round for the repository: `git show 72a2303:docker-compose.yaml` shows
  `condition: service_started`. This repository was not ahead here and there is no
  `service_healthy` condition to "restore". The gateway now additionally depends on
  `keycloak: service_healthy`, because it resolves `TOKEN_ISSUER` at startup.
- **`hapi-fhir/application-auth.yaml.example` `auth-server-url`.** The table claimed
  the repository's `http://keycloak:8080/` was the value to preserve over the
  server's `${KEYCLOAK_PUBLIC_URL}/`. The server value was right and is now what the
  template carries. A literal in-network host/port cannot match the issuer of tokens
  minted through `KEYCLOAK_PUBLIC_URL`, and `8080` is no longer the port Keycloak
  listens on — it listens on `KEYCLOAK_PORT`, published 1:1, so that
  `KEYCLOAK_PUBLIC_URL` resolves identically from the browser and from inside the
  network.

### Defects this sync exposes

1. **`Dockerfile` and `Dockerfile.web` have never been committed** (`git log --all --
   Dockerfile` is empty), yet `docker-compose.yaml` builds `fhir-gateway` and
   `ohs-player-web` from them. `./dev.sh up` cannot succeed on a fresh clone.
2. **`.env.example` omits 12 variables that `docker-compose.yaml` references:**
   `POSTGRES_HOST`, `KEYCLOAK_PUBLIC_URL`, `FHIR_GATEWAY_KEYCLOAK_CLIENT_ID`,
   `FHIR_GATEWAY_KEYCLOAK_CLIENT_SECRET`, `ACCESS_CHECKER`, `RUN_MODE`, `GATEWAY_REF`,
   `PLUGIN_REF`, `WEB_REF`, `VITE_FHIR_BASE_URL`, `VITE_CLIENT_ID`,
   `VITE_FHIR_VERSION`.
3. **`POSTGRES_PORT` carries two incompatible meanings.** `docker-compose.yaml` uses it
   as the in-container port (`KC_DB_URL_PORT`, HAPI `DB_PORT`), while `.env.example`
   sets it to `5433`, a host-publish value.
4. **`dev.sh` renders the realm with an envsubst allow-list** ([dev.sh:101](../../../dev.sh))
   that does not include the two `FHIR_GATEWAY_KEYCLOAK_CLIENT_*` variables the updated
   realm template now uses. Keycloak would import a client whose ID is the literal
   string `${FHIR_GATEWAY_KEYCLOAK_CLIENT_ID}`.
5. **`ohs-player-web` has no `profiles:` key**, so it starts on a bare `./dev.sh up`
   despite `--web` existing to opt into it.
6. **`postgres/init/01-init.sh` is dead** — commit 6aee453 removed the `postgres`
   service, and nothing mounts the script.
7. **README is stale** — it documents a Postgres container on `127.0.0.1:5433` that no
   longer exists, and describes extension services as "commented-out stubs" when they
   are profile-gated services.

## Decisions

**Postgres runs locally again.** The server model (external, pre-provisioned Postgres)
is wrong for a local-development repository: it demands host setup before anything runs,
and it left `postgres/init/01-init.sh` orphaned. A `postgres` service returns, with the
external instance reachable by overriding `POSTGRES_HOST` in `.env`.

**nginx runs inside the compose network, behind a profile.** The server's nginx configs
are worth keeping, but they assume a host-installed nginx plus a `docker-compose.server.yml`
`extra_hosts` hairpin so containers can resolve the public Keycloak hostname. Running
nginx as a compose service with a network alias removes the hairpin entirely: containers
resolve the public name through Docker's embedded DNS, and developers only need an
`/etc/hosts` entry for the browser (or none at all, using a `.localhost` name).

**Same-origin is the default proxy layout.** One hostname serving the SPA, the gateway,
and Keycloak avoids CORS on the gateway's `/api/*` routes, which have no CORS
interceptor. The subdomain layout is retained as a documented alternative.

## Out of scope

- `docker-compose.server.yml` — the `extra_hosts` hairpin it provides is unnecessary
  once nginx runs inside the network.
- `.env.server` — server values, and it contains a real client secret.
- `eed` — the server's shell history (VM hardening, Docker install). Not configuration.

## Design

### 1. Postgres service

Add to `docker-compose.yaml`:

```yaml
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

The volume mounts at `/var/lib/postgresql`, matching `postgres-synth` and
`postgres-analytics`. This sidesteps the `postgres:18` `PGDATA` change that makes the
image refuse to start when a volume is mounted at the old `/var/lib/postgresql/data`
path without an explicit `PGDATA`.

`01-init.sh` interpolates `${KEYCLOAK_DB_PASSWORD}` and `${HAPI_FHIR_DB_PASSWORD}`, so
both are passed into the container environment.

`keycloak` and `hapi-fhir` gain `depends_on: postgres: {condition: service_healthy}`.
Their existing `extra_hosts: host.docker.internal:host-gateway` entries stay, so
`POSTGRES_HOST=host.docker.internal` continues to reach a host-run instance.

**Port variable split.** `POSTGRES_PORT` becomes the in-container port only, defaulting
to `5432`; `POSTGRES_HOST_PORT` (default `5433`) is the host publish port. Only
`.env.example` and the new service's `ports:` line change — `KC_DB_URL_PORT` and HAPI's
`DB_PORT` already read `POSTGRES_PORT` and become correct once its value is `5432`.

### 2. Build files, copied verbatim

- `Dockerfile` — three-stage build: clone and package `ohs-foundation/fhir-gateway` at
  `GATEWAY_REF`, build the `ohs-player-reference-backend` plugin jar at `PLUGIN_REF`,
  run on `eclipse-temurin:21-jre` with `-Dloader.path=/app/plugins`.
- `Dockerfile.web` — clone `ohs-player-reference-web-portal` at `WEB_REF`, pnpm/turbo
  build with the `VITE_*` build args, serve the bundle from `nginx:1.27-alpine`.
- `nginx/spa.conf` — the SPA container's server block. Proxies `/api/` and `/fhir` to the
  gateway same-origin and uses `resolver 127.0.0.11` so a recreated gateway container is
  picked up without a restart. Required by `Dockerfile.web`'s `COPY`.

No edits: all three are deployment-agnostic.

### 3. `.env.example`

Add the 12 missing variables, keeping the server file's explanatory comments (in
particular the note that `KEYCLOAK_PUBLIC_URL` must resolve identically from the browser
and from inside the gateway and HAPI containers) but substituting local defaults:

| Variable | Local default |
|---|---|
| `POSTGRES_HOST` | `postgres` |
| `POSTGRES_HOST_PORT` | `5433` |
| `POSTGRES_PORT` | `5432` (changed from `5433`) |
| `KEYCLOAK_PUBLIC_URL` | `http://keycloak.localhost:8081` (corrected; `http://localhost:8081` as specified here is the gateway's own loopback from inside its container, so OIDC discovery could never succeed) |
| `FHIR_GATEWAY_KEYCLOAK_CLIENT_ID` | `fhir-gateway-admin` |
| `FHIR_GATEWAY_KEYCLOAK_CLIENT_SECRET` | `[generated]` |
| `ACCESS_CHECKER` | `permission` |
| `RUN_MODE` | `PROD` |
| `GATEWAY_REF` / `PLUGIN_REF` / `WEB_REF` | `main` |
| `VITE_FHIR_BASE_URL` | `/fhir` (corrected; the absolute URL specified here bypasses `nginx/spa.conf`, which exists to keep the SPA's FHIR calls same-origin) |
| `VITE_CLIENT_ID` | `ohs-player-client` |
| `VITE_FHIR_VERSION` | `R4` |

`RUN_MODE=DEV` combined with `ACCESS_CHECKER=permissive` is documented as the
access-control bypass for local debugging, not set as the default.

A commented block documents the values that change together in proxy mode
(`KEYCLOAK_PUBLIC_URL`, `VITE_FHIR_BASE_URL`, `OHS_PLAYER_APP_HOST`, `PUBLIC_HOST`).

### 4. Keycloak realm, theme, and the renderer fix

Commit the working-tree changes to `keycloak/ohs-player-realm.json.example`:

- `"loginTheme": "ohs"` at realm level.
- The `${FHIR_GATEWAY_KEYCLOAK_CLIENT_ID}` client — confidential, service accounts
  enabled, standard/implicit/direct-access flows disabled.
- Its service-account user, holding the `realm-management` client roles `manage-users`,
  `view-users`, `manage-realm`, `view-realm`.

Commit `keycloak/themes/ohs/` (theme properties, English messages, CSS, logo, login
background). It is byte-identical to the server's copy and `docker-compose.yaml` already
mounts `./keycloak/themes` read-only.

In `dev.sh`, extend the realm render's variable list with
`${FHIR_GATEWAY_KEYCLOAK_CLIENT_ID} ${FHIR_GATEWAY_KEYCLOAK_CLIENT_SECRET}`. Without
this the new client is imported with literal placeholder text and the gateway's IAM
provider cannot obtain a token.

### 5. Proxy profile

New service:

```yaml
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

`nginx/ohs-player.conf` is ported from the server's `ohs-player.conf.example`: same
same-origin routing (`/` to the SPA, `/fhir` and `/api` to the gateway, `/realms`,
`/admin` and `/resources` to Keycloak), with `proxy_pass` targets rewritten from
`127.0.0.1:808x` to service names, and `include /etc/nginx/proxy_params` expanded inline
(that file ships with Debian's nginx package, not the Alpine image).

The network alias is what makes the hairpin unnecessary: `fhir-gateway` resolving
`ohs-player.localhost` reaches the nginx container directly.

`nginx/ohs-player-subdomains.conf.example` is retained verbatim as the documented
alternative for deployments wanting one hostname per service.

`dev.sh` gains `--proxy` in `parse_profiles`, in `usage`, and in the profile list used
by `down` and `reset`.

**Enabling the proxy is not just a flag.** `KEYCLOAK_PUBLIC_URL` is baked into the realm
import and `VITE_FHIR_BASE_URL` into the SPA bundle, so switching requires editing
`.env` and re-running `./dev.sh up`, which re-renders the realm and rebuilds the web
image. The README documents this as a coherent alternate configuration rather than a
toggle.

### 6. Correctness fixes

- `ohs-player-web` gains `profiles: ["web", "full"]`.
- README: drop the Postgres-container-on-5433 section and the "commented-out stubs"
  claim; add the external-Postgres override, `--synth` / `--pipes` usage, the OHS login
  theme, and proxy mode with its `/etc/hosts` guidance.

## Implementation order

Six commits. Steps 1–4 are independent of step 5, so the proxy work can be deferred
without stranding anything.

1. Copy `Dockerfile`, `Dockerfile.web`, `nginx/spa.conf`.
2. Restore the `postgres` service and split the port variables.
3. Complete `.env.example`.
4. Commit realm, theme, and the `dev.sh` render fix.
5. Add the proxy profile and `nginx/ohs-player.conf`.
6. Fix the `ohs-player-web` profile and update the README.

## Verification

- `docker compose config` resolves with no `variable is not set` warnings, for the
  default profile and for `--profile web`, `--profile synth`, `--profile pipes`,
  `--profile proxy`.
- `./dev.sh clean && ./dev.sh up` completes on a tree with no `.env`.
- `keycloak/ohs-player-realm.json` after rendering contains no `${` placeholders.
- Keycloak starts, imports the realm, and its login page renders the OHS theme.
- The `fhir-gateway-admin` client exists in the realm with a real ID and secret, and the
  gateway starts without IAM authentication errors.
- `./dev.sh up --web` builds and serves the SPA; a bare `./dev.sh up` does not start it.
- `./dev.sh up --proxy` with proxy-mode `.env` values serves the SPA, `/fhir`, and
  `/realms` from one origin, and login completes end to end.
- `./dev.sh up --pipes` still brings up the synth stack, pipeline controller, and
  Superset.
