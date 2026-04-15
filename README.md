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

1. **Create your local `.env` from the example:**

   ```bash
   cp .env.example .env
   ```

2. **Edit `.env` and fill in real values.** Every secret ships as
   `changeme` — you must replace each one before starting the stack.
   Generate strong random values with:

   ```bash
   openssl rand -hex 24
   ```

   The file contains five secrets plus one auth-mode selector:

   | Variable | Purpose |
   |---|---|
   | `POSTGRES_ADMIN_PASSWORD` | Postgres superuser password |
   | `KEYCLOAK_DB_PASSWORD` | Password for the `keycloak` DB role |
   | `KEYCLOAK_ADMIN_PASSWORD` | Keycloak admin console bootstrap password |
   | `HAPI_FHIR_DB_PASSWORD` | Password for the `hapi_fhir` DB role |
   | `HAPI_FHIR_KEYCLOAK_CLIENT_SECRET` | OIDC client secret (auth mode only) |
   | `HAPI_CONFIG` | Which HAPI config to mount (see [Auth mode](#auth-mode)) |

   `.env` is gitignored. **Never commit it.**

3. **Start the stack:**

   ```bash
   ./dev.sh up
   ```

   The script renders per-service config files from the `*.example`
   templates using your `.env`, pulls images and brings up the core
   services.

## Services & Ports

| Service | Host port | Notes |
|---|---|---|
| Postgres | `127.0.0.1:5432` | Bound to loopback only |
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
`HAPI_FHIR_KEYCLOAK_CLIENT_SECRET` in `.env` matches the client secret
configured in the `fhir-server` Keycloak client for the `ohs-realm` realm.

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
│   ├── realm-import/ohs-realm.json   # imported automatically on first boot
│   ├── keycloak.env.example
│   └── keycloak.env                  # rendered by dev.sh (gitignored)
├── hapi-fhir/
│   ├── application-no-auth.yaml.example
│   ├── application-no-auth.yaml      # rendered by dev.sh (gitignored)
│   ├── application-auth.yaml.example
│   └── application-auth.yaml         # rendered by dev.sh (gitignored)
├── postgres/
│   ├── init/01-init.sh               # runs once on volume creation
│   ├── postgres.env.example
│   └── postgres.env                  # rendered by dev.sh (gitignored)
├── gateway/
│   └── gateway.env                   # no secrets; committed
├── .env.example                      # single source of truth for secrets
├── .env                              # your local copy (gitignored)
├── docker-compose.yaml               # all services; extensions behind profiles
├── dev.sh                            # lifecycle entrypoint
├── README.md                         # this file
└── PRODUCTION.md                     # GCP production deployment guide
```

## Troubleshooting

**`.env not found`** — You haven't run `cp .env.example .env` yet. See
[First-Run Setup](#first-run-setup).

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
