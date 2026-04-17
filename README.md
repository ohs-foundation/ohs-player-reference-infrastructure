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

All four are available on Linux, macOS and Windows. On Windows, run `dev.sh`
from WSL or Git Bash; native `cmd.exe` / PowerShell are not supported.

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
│   └── application-auth.yaml        # rendered by dev.sh (gitignored)
├── postgres/
│   └── init/01-init.sh              # runs once on volume creation
├── .env.example                     # single source of truth for config
├── .env                             # your local copy (gitignored)
├── docker-compose.yaml              # all services; extensions behind profiles
├── dev.sh                           # lifecycle entrypoint
├── README.md                        # this file
└── PRODUCTION.md                    # GCP production deployment guide
```

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
