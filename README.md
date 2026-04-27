# OHS Player Reference Infrastructure

The OHS Player Reference Infrastructure repo contains a set of deployment scripts, images and documentation for packaging and deployment of an [OHS based project](https://developers.google.com/open-health-stack/overview). This set of scripts will be useful for quickly spinning up the OHS "back-end" for faster development or deployments.

Docker Compose stack for running the OHS reference infrastructure locally:
PostgreSQL, Keycloak, HAPI FHIR Server and FHIR Info Gateway, with optional extension
services (OHS Player Web Portal, FHIR Data Pipes) behind profiles.

## Prerequisites

Install the following software on your development machine:

- **Docker Engine** (with the Compose v2 plugin)
- **GNU gettext** — provides the template rendering used by `dev.sh`
- **OpenSSL** — used to generate strong random secrets
- **Bash** (version 4 or newer) — required to run `dev.sh`

All four are available on Linux, macOS and Windows. On Windows, run
`dev.sh` from [WSL](https://learn.microsoft.com/en-us/windows/wsl/install)
(the recommended option, also required by Docker Desktop) or
[Git Bash](https://gitforwindows.org/); native `cmd.exe` / PowerShell are
not supported.

**Optional:**

- **JDK** (any version with `javac`) — only needed if you modify
  `hapi-fhir/health/Healthcheck.java`. The committed `Healthcheck.class`
  is used as-is when no JDK is present, so this is not required for a
  fresh setup. See [HAPI FHIR Healthcheck](#hapi-fhir-healthcheck).

## First-Run Setup

```bash
./dev.sh up
```

On first run the script auto-generates `.env` from `.env.example`, replacing
every `[generated]` marker with a unique random secret. It then renders the
HAPI FHIR config templates, pulls images and brings up the core services.

`.env` is gitignored. **Never commit it.**

To create `.env` manually instead, copy the example and replace the
`[generated]` values with your own secrets before running `./dev.sh up`.

## Services & Ports

| Service | Host port | Notes |
|---|---|---|
| Postgres | `127.0.0.1:5433` | Bound to loopback only |
| Keycloak | `8081` maps to container `8080` | Admin console at <http://localhost:8081> |
| HAPI FHIR | `8082` maps to container `8080` | HAPI FHIR base at <http://localhost:8082/fhir> |
| FHIR Gateway | `8083` maps to container `8080` | FHIR Info Gateway entry at <http://localhost:8083> |

## `dev.sh` Commands

```text
./dev.sh up [--web|--pipes|--full]   Render configs and start services
./dev.sh down                        Stop all running services
./dev.sh reset                       Stop services and wipe named volumes
./dev.sh logs [service]              Tail logs (all services or one)
./dev.sh render                      Render service config templates from .env
./dev.sh clean                       Remove generated files (.env, application-*.yaml)
./dev.sh help                        Show usage
```

### Run modes (profiles)

| Command | Services started |
|---|---|
| `./dev.sh up` | Core only (Postgres, Keycloak, HAPI FHIR, Gateway) |
| `./dev.sh up --web` | Core + Web Portal |
| `./dev.sh up --pipes` | Core + FHIR Data Pipes |
| `./dev.sh up --full` | Everything |

Extension services currently ship as commented-out stubs in
`docker-compose.yaml`. The `--web` / `--pipes` / `--full` flags will become
functional once those services are wired up.

## Verifying the Stack

After `./dev.sh up`, check that all containers are running and healthy:

```bash
docker compose ps
```

All core services should show `Up` with `(healthy)` status. Keycloak and
HAPI FHIR have longer start-up times — wait for their health checks to pass
before testing (up to 90s for Keycloak, up to 180s for HAPI FHIR).

### Service endpoints

| Service | URL | What to expect |
|---|---|---|
| **Postgres** | `psql -h 127.0.0.1 -p ${POSTGRES_PORT:-5433} -U postgres` | Connection prompt (use `POSTGRES_ADMIN_PASSWORD` from `.env`) |
| **Keycloak** | <http://localhost:8081> | Admin console login page (use `KEYCLOAK_ADMIN_USERNAME` / `KEYCLOAK_ADMIN_PASSWORD` from `.env`) |
| **HAPI FHIR** | <http://localhost:8082/fhir/metadata> | FHIR CapabilityStatement JSON response |
| **FHIR Gateway** | <http://localhost:8083/fhir/metadata> | Proxied CapabilityStatement via the gateway |

> Ports above are the defaults. If you changed them in `.env`, substitute
> your values.

### Quick smoke test

```bash
# Keycloak is responding
curl -sf http://localhost:8081/health/ready | grep -q UP && echo "Keycloak: OK"

# HAPI FHIR returns a CapabilityStatement
curl -sf http://localhost:8082/fhir/metadata | grep -q CapabilityStatement && echo "HAPI FHIR: OK"

# FHIR Gateway proxies to HAPI FHIR
curl -sf http://localhost:8083/fhir/metadata | grep -q CapabilityStatement && echo "FHIR Gateway: OK"
```

## Auth Mode

HAPI FHIR can run in two modes, controlled by a single variable in `.env`:

```dotenv
HAPI_CONFIG=application-no-auth.yaml   # open, no token validation
# or
HAPI_CONFIG=application-auth.yaml      # Keycloak token validation
```

To switch modes:

1. Edit `HAPI_CONFIG` in `.env`.
2. Run `./dev.sh up` again.

No compose files are touched. The HAPI volume mount reads the variable
directly.

When switching **into** auth mode, make sure
`HAPI_FHIR_SERVER_KEYCLOAK_CLIENT_SECRET` in `.env` matches the client secret
configured in the `hapi-fhir-server-client` Keycloak client for the `ohs-player` realm.

## HAPI FHIR Healthcheck

The HAPI FHIR image is distroless - it has no shell, no `curl`, no `wget`.
Standard Docker `HEALTHCHECK` recipes don't work, so the stack ships a tiny
Java program that uses the JRE already inside the container to probe
`/fhir/metadata`.

The two files live in `hapi-fhir/health/`:

| File | Purpose | Committed? |
|---|---|---|
| `Healthcheck.java` | Source — readable, reviewable | Yes |
| `Healthcheck.class` | Compiled bytecode — mounted into the HAPI container at `/healthcheck/` | Yes |

Both are committed so a fresh clone works without a host JDK. `dev.sh`
recompiles `Healthcheck.class` from `Healthcheck.java` automatically when
all of the following are true:

- A JDK is installed on the host (`javac` is on `PATH`).
- `Healthcheck.java` has been modified more recently than `Healthcheck.class`.

If `javac` is not installed, the committed `.class` is used as-is. If you
edit the source on a machine without a JDK, install a JDK or recompile on
another machine and commit the updated `.class` alongside the source.

## Common Tasks

**Tail logs for one service:**

```bash
./dev.sh logs keycloak
```

**Restart a single service after editing its config template:**

```bash
./dev.sh render
docker compose restart hapi-fhir
```

**Wipe all data and start fresh** (destroys the Postgres volume):

```bash
./dev.sh reset
./dev.sh up
```

## Layout

```text
ohs-player-reference-infrastructure/
├── keycloak/
│   ├── ohs-player-realm.json.example  # realm template
│   └── ohs-player-realm.json         # rendered by dev.sh (gitignored)
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
├── .env.example                     # single source of truth for config
├── .env                             # your local copy (gitignored)
├── docker-compose.yaml              # all services; extensions behind profiles
├── dev.sh                           # lifecycle entrypoint
├── README.md                        # this file
└── PRODUCTION.md                    # GCP production deployment guide
```

## What `dev.sh` Does Under the Hood

`dev.sh` is a thin wrapper around `docker compose` that adds template
rendering, secrets bootstrapping, and a few convenience flags. If you'd
rather drive compose directly, the table below shows the equivalent raw
commands for every subcommand. Run all commands from the repo root.

| `dev.sh` subcommand | Equivalent raw commands |
|---|---|
| `./dev.sh up` | `docker compose pull` <br> `docker compose up -d` <br> `docker compose ps` |
| `./dev.sh up --web` | `docker compose --profile web pull` <br> `docker compose --profile web up -d` |
| `./dev.sh up --pipes` | `docker compose --profile pipes pull` <br> `docker compose --profile pipes up -d` |
| `./dev.sh up --full` | `docker compose --profile full pull` <br> `docker compose --profile full up -d` |
| `./dev.sh down` | `docker compose --profile web --profile pipes --profile full down` |
| `./dev.sh reset` | `docker compose --profile web --profile pipes --profile full down --volumes` |
| `./dev.sh logs` | `docker compose logs -f` |
| `./dev.sh logs <service>` | `docker compose logs -f <service>` |
| `./dev.sh render` | _No compose equivalent._ Renders config templates from `.env`. See [Steps `dev.sh up` performs before compose](#steps-devsh-up-performs-before-compose). |
| `./dev.sh clean` | _No compose equivalent._ Deletes `.env` and all rendered config files. |
| `./dev.sh help` | `docker compose --help` _(shows compose's own help, not the wrapper's)_ |

### Steps `dev.sh up` performs before compose

The wrapper runs three things before any `docker compose` invocation. If
you skip the wrapper, you'll need to do these yourself the first time and
whenever `.env.example` or any `*.example` template changes:

1. **Bootstrap `.env`** — if it doesn't exist, copy `.env.example` to
   `.env` and replace every `[generated]` marker with a unique random
   secret (`openssl rand -hex 24`).
2. **Render config templates** — for each pair below, run `envsubst` with
   an explicit variable list so Spring's `${DB_HOST}` placeholders are
   preserved while application secrets are substituted:

   ```bash
   set -a && source .env && set +a

   envsubst '${KEYCLOAK_REALM} ${OHS_PLAYER_KEYCLOAK_CLIENT_ID} ...' \
     < keycloak/ohs-player-realm.json.example \
     > keycloak/ohs-player-realm.json

   envsubst '${HAPI_FHIR_DB_PASSWORD}' \
     < hapi-fhir/application-no-auth.yaml.example \
     > hapi-fhir/application-no-auth.yaml

   envsubst '${HAPI_FHIR_DB_PASSWORD} ${HAPI_FHIR_SERVER_KEYCLOAK_CLIENT_SECRET}' \
     < hapi-fhir/application-auth.yaml.example \
     > hapi-fhir/application-auth.yaml
   ```

3. **Recompile the HAPI healthcheck** — if `Healthcheck.java` is newer
   than `Healthcheck.class` (and a JDK is installed):

   ```bash
   javac hapi-fhir/health/Healthcheck.java
   ```

After those three steps, plain `docker compose up -d` works.

## Troubleshooting

**`.env.example not found`** — The repo is missing its template file.
Re-clone or restore it from version control.

**Keycloak fails to start with a DB error** — Postgres is still
initialising. Wait ~30s and re-run `./dev.sh up`, or check
`./dev.sh logs postgres`.

**HAPI FHIR fails to find its config** — Run `./dev.sh render` to
regenerate `hapi-fhir/application-*.yaml` from the templates, then restart
the `hapi-fhir` service.

**I changed `.env` but nothing picked it up** — `.env` values are baked
into the rendered config files. Re-run `./dev.sh up` (or `./dev.sh render`
followed by `docker compose restart <service>`) after any `.env` change.

## Out of Scope

The following are deliberately not covered by this local dev setup and will
be added later:

- **Public demo deployment** — reverse proxy config, VM provisioning, a
  periodic reset job and a public landing page.
- **Web Portal dev mode** — whether the Web Portal runs in-container with
  hot reload or on the host against a backend-only compose is still an
  open decision.
