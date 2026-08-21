# OHS Player Reference Infrastructure

Reference Infrastructure brings up the services every other OHS Player component
depends on: a FHIR server, identity, the gateway in front of them, and the database
underneath.

It is deployment material rather than an application. Nothing in it is a component you
use directly, which is why it is the first stage rather than an item in the component
set. Everything you set up afterwards points at what this creates.

Full guide: [Set up the environment](https://ohs-foundation.github.io/ohs-docs/components/reference-infrastructure/).

---

## Before you begin

Install these on your machine:

| Tool | Why |
|---|---|
| **Docker Engine** with the **Compose v2 plugin** (v2.29 or newer) | Runs the stack. v2.29 added the `pull --ignore-buildable` flag `dev.sh` uses, because two images are built from source rather than pulled |
| **GNU gettext** (`envsubst`) | Fills your settings into the service config templates |
| **Bash 4 or newer** | Runs `dev.sh` |

That is the whole list. Secrets are generated from `/dev/urandom`, which every supported
platform already provides — there is nothing to install for it.

### Installing them

Pick your platform. `dev.sh` checks everything it needs before doing anything, and tells
you the right command for your system if something is missing.

**Linux (Debian, Ubuntu, or WSL)**

```bash
sudo apt update
sudo apt install gettext-base
```

Docker Engine and the Compose plugin follow
[Docker's own instructions](https://docs.docker.com/engine/install/).

**Linux (Fedora or RHEL)**

```bash
sudo dnf install gettext
```

Note the package is `gettext` here, not `gettext-base`.

**macOS**

Bash ships with the system. You need `envsubst`, which comes from Homebrew's `gettext`:

```bash
brew install gettext
brew link --force gettext
```

The `link` step is not optional. Homebrew keeps `gettext` "keg-only", meaning it installs
it but deliberately leaves it off your `PATH`, so `envsubst` stays invisible until you
force the link. Install Docker Desktop separately.

macOS also ships Bash 3.2, which is too old. If `bash --version` reports 3.x:

```bash
brew install bash
```

**Windows**

Do not run these scripts from `cmd.exe` or PowerShell — they are Bash scripts and
`envsubst` has no native Windows build worth using.

1. Install [WSL](https://learn.microsoft.com/en-us/windows/wsl/install):
   `wsl --install` in an admin PowerShell, then restart.
2. Install [Docker Desktop](https://docs.docker.com/desktop/install/windows-install/) and
   enable WSL integration in **Settings → Resources → WSL integration**.
3. Open your WSL shell and install the rest:

   ```bash
   sudo apt update
   sudo apt install gettext-base
   ```

4. Clone the repository **inside** the WSL filesystem (`~/`), not under `/mnt/c/`. Builds
   are dramatically slower across the Windows mount.

[Git Bash](https://gitforwindows.org/) also works if you already have it, but WSL is the
better-supported path.

### Check they are all present

```bash
docker --version
docker compose version
envsubst --version
bash --version
head -c 8 /dev/urandom | od -An -tx1
```

Five answers, no "command not found", Compose reporting v2.29 or newer, and the last
command printing some hex bytes.

If you would rather let the script tell you, `./dev.sh render` runs the same checks and
stops with an install command for whatever is missing.

**Optional:** a JDK (any version with `javac`). You only need it if you edit
`hapi-fhir/health/Healthcheck.java`. The compiled `.class` file is committed, so a fresh
clone works without one. See [HAPI FHIR healthcheck](#hapi-fhir-healthcheck).

---

## Bring it up

**Step 1 — get the code.**

```bash
git clone https://github.com/ohs-foundation/ohs-player-reference-infrastructure.git
cd ohs-player-reference-infrastructure
```

**Step 2 — start the stack.**

```bash
./dev.sh up
```

That one command does five things, in order:

1. Copies `.env.example` to `.env` if you do not have one yet.
2. Replaces every `[generated]` placeholder in `.env` with a random secret.
3. Renders the Keycloak realm and HAPI FHIR config from those values.
4. Builds the gateway image from source (first run only — this takes several minutes).
5. Starts the four core services.

Later runs reuse what is already there, so they are much faster.

> **`.env` holds your generated credentials and is deliberately untracked. Never commit it.**

**Step 3 — wait.** Identity and the FHIR server take appreciably longer to become ready
than the database. Allow up to **90 seconds for Keycloak** and up to **3 minutes for HAPI
FHIR** on a first run.

---

## What comes up

| Service | Default port | Role |
|---|---|---|
| PostgreSQL | `5433` | Storage for the FHIR server and identity, bound to loopback only |
| Keycloak | `8081` | Identity: realms, clients, users and roles |
| HAPI FHIR | `8082` | The FHIR server, unmodified |
| FHIR Gateway | `8083` | The authenticated, access-controlled entry point |

Every port is overridable in `.env`.

**Clients never reach the FHIR server directly.** Everything routes through the gateway,
which is why bringing up the gateway is part of standing up the environment rather than a
later step.

Keycloak's admin console is at <http://keycloak.localhost:8081>. Log in with
`KEYCLOAK_ADMIN_USERNAME` and `KEYCLOAK_ADMIN_PASSWORD` from your `.env`. Browsers resolve
any `*.localhost` name to `127.0.0.1` on their own, so there is nothing to add to
`/etc/hosts`.

---

## Confirm it is healthy

**Step 1 — check the containers.**

```bash
docker compose ps
```

All four should show `Up`, and Postgres, Keycloak and HAPI FHIR should show `(healthy)`.

**Step 2 — check each service answers.** Run all three; three silent successes mean
identity is up, the FHIR server is serving, and the gateway is proxying to it.

```bash
curl -sf http://localhost:8081/realms/ohs-player/.well-known/openid-configuration | grep -q issuer
curl -sf http://localhost:8082/fhir/metadata | grep -q CapabilityStatement
curl -sf http://localhost:8083/fhir/metadata | grep -q CapabilityStatement
```

If you prefer to see output rather than silence:

```bash
curl -sf http://localhost:8081/realms/ohs-player/.well-known/openid-configuration | grep -q issuer && echo "Keycloak: OK"
curl -sf http://localhost:8082/fhir/metadata | grep -q CapabilityStatement && echo "HAPI FHIR: OK"
curl -sf http://localhost:8083/fhir/metadata | grep -q CapabilityStatement && echo "FHIR Gateway: OK"
```

> The first command checks the realm rather than `/health/ready`. Keycloak 26 serves its
> health endpoints on a separate management port (`9000`) that this stack does not publish,
> so `curl http://localhost:8081/health/ready` returns 404 even on a perfectly healthy
> Keycloak. The container's own healthcheck probes port 9000 internally, which is what
> `docker compose ps` reports.

---

## Choose an authentication mode

The FHIR server can run open, or validate tokens issued by identity. One value in `.env`
selects which:

| Value | Behaviour |
|---|---|
| `application-no-auth.yaml` | The FHIR server accepts requests without a token |
| `application-auth.yaml` | The FHIR server validates tokens issued by identity |

Open is convenient while exploring. Token validation matches how the components are meant
to fit together, and is the mode to use before running the Portal and the Client App
against this environment.

To switch:

1. Edit `HAPI_CONFIG` in `.env`.
2. Run `./dev.sh up` again.

No compose file is edited — the HAPI volume mount reads the variable directly.

When switching **into** auth mode, check that `HAPI_FHIR_SERVER_KEYCLOAK_CLIENT_SECRET` in
`.env` matches the secret on the `hapi-fhir-server-client` client in the `ohs-player`
realm.

---

## Managing the stack

| Command | Does |
|---|---|
| `./dev.sh up` | Render configuration and start services |
| `./dev.sh down` | Stop services, keeping data |
| `./dev.sh reset` | Stop services and wipe the volumes |
| `./dev.sh logs [service]` | Tail logs for everything, or one service |
| `./dev.sh render` | Regenerate service configuration from `.env` |
| `./dev.sh clean` | Remove generated files |
| `./dev.sh help` | Show usage |

`reset` is the one to reach for when the environment has drifted into a state you cannot
explain. It is faster than diagnosing a local-only problem.

> **`reset` destroys the Postgres volume.** Everything in it is lost: the whole realm,
> including any users, clients or role changes made through the admin console, and every
> FHIR resource stored by the HAPI server.

A few everyday tasks:

```bash
./dev.sh logs keycloak          # follow one service's logs
./dev.sh render                 # re-render configs after editing .env
docker compose restart hapi-fhir
```

---

## Expected result

Four services running and healthy, and the three values every other component needs:

| Value | Default |
|---|---|
| FHIR base URL, through the gateway | `http://localhost:8083/fhir` |
| Gateway URL | `http://localhost:8083` |
| Identity issuer | `http://keycloak.localhost:8081/realms/ohs-player` |

---

## Next step

Set up the backend, which loads the Player endpoints and access rules into the gateway.
The Web Portal and the Client App both depend on it.

---

# Beyond the core stack

Everything above is the environment the guide describes. The rest of this file covers the
optional add-ons, server-oriented configuration, and reference material owned by this
repository.

## Optional profiles

The core four services start by default. Everything else is opt-in behind a flag:

| Command | Adds |
|---|---|
| `./dev.sh up` | Nothing — core only (Postgres, Keycloak, HAPI FHIR, Gateway) |
| `./dev.sh up --web` | The Web Portal SPA |
| `./dev.sh up --synth` | An isolated HAPI FHIR + Postgres pair for synthetic test data |
| `./dev.sh up --pipes` | The synth pair, plus FHIR Data Pipes and Superset |
| `./dev.sh up --proxy` | A same-origin nginx front, plus the Web Portal |
| `./dev.sh up --full` | Everything |

Flags combine: `./dev.sh up --web --proxy`.

Ports for the optional services:

| Service | Profile | Host port | Variable |
|---|---|---|---|
| Web Portal | `--web`, `--proxy` | `8084` | `OHS_PLAYER_WEB_PORT` |
| nginx front | `--proxy` | `80` | `PROXY_PORT` |
| Synth Postgres | `--synth`, `--pipes` | `127.0.0.1:5435` | `POSTGRES_SYNTH_PORT` |
| Synth HAPI FHIR | `--synth`, `--pipes` | `8085` | `HAPI_SYNTH_PORT` |
| Analytics Postgres | `--pipes` | `127.0.0.1:5434` | `POSTGRES_ANALYTICS_PORT` |
| Pipeline controller | `--pipes` | `8090` | `PIPELINE_PORT` |
| Superset | `--pipes` | `8088` | `SUPERSET_PORT` |

### Web Portal — `--web`

Builds the SPA from source and serves it at <http://localhost:8084>.

The first build clones the web portal repository and runs a full `pnpm` install and
build, so it takes several minutes. The browser-facing values are baked into the bundle at
build time, which is why changing any `VITE_*` value in `.env` requires a rebuild —
`./dev.sh up --web` does that for you.

### Synthetic data — `--synth`

Adds a **second** HAPI FHIR server and its own Postgres, at
<http://localhost:8085/fhir>.

It is deliberately separate from the transactional server so generated test data never
touches real records. Point a data generator at port `8085` rather than `8082`.

### Analytics — `--pipes`

Adds FHIR Data Pipes and Superset on top of the synth pair.

The pipeline reads FHIR resources from the synth server, applies the ViewDefinitions in
`data-pipes/config/views/`, and writes flat tables into an analytics Postgres. Superset
then charts those tables.

| What | Where |
|---|---|
| Pipeline control panel | <http://localhost:8090> |
| Superset | <http://localhost:8088> — log in with `admin` / `admin` |

`PIPELINE_FHIR_SOURCE` in `.env` selects which FHIR server the pipeline reads. It defaults
to the synth server; point it at `http://hapi-fhir:8080/fhir` once you have transactional
data worth reporting on.

### Same-origin proxy — `--proxy`

By default each service sits on its own port, so the browser makes cross-origin requests.
`--proxy` puts an nginx container in front that serves the SPA, the gateway and Keycloak
from a **single origin**, so no CORS is involved at all.

That matters because the gateway plugin's `/api/*` endpoints send no CORS headers of their
own. A single origin avoids the problem rather than working around it.

**Step 1 — change two values in `.env`.** They must change together: the first is baked
into the Keycloak realm import, the second into the SPA bundle.

```dotenv
KEYCLOAK_PUBLIC_URL=http://ohs-player.localhost
OHS_PLAYER_APP_HOST=ohs-player.localhost
```

`VITE_FHIR_BASE_URL` needs no change — it is the relative `/fhir`, so it follows whichever
origin serves the SPA.

**Step 2 — start with both flags.**

```bash
./dev.sh up --web --proxy
```

Everything is then served from <http://ohs-player.localhost>.

#### If the stack has already run once

Editing `.env` and re-running `./dev.sh up` is **not enough.**

Keycloak imports the realm with the `IGNORE_EXISTING` strategy. Once the realm is in the
Postgres volume, the re-rendered `keycloak/ohs-player-realm.json` is ignored entirely, so
the `ohs-player-client` redirect URIs keep their first-boot values and login fails on the
new hostname.

Reset first:

```bash
./dev.sh reset
./dev.sh up --web --proxy
```

The import strategy is deliberately not `OVERWRITE_EXISTING` — that would discard
admin-console realm changes on every single start.

#### Notes on the proxy

`PROXY_PORT` must stay at `80` for the values above. nginx listens on `80` inside the
container and other containers reach it through the `PUBLIC_HOST` network alias on that
internal port, while the browser uses the published port. The two agree only at `80`.

For a hostname other than `*.localhost`, set `PUBLIC_HOST` and add a matching line to your
`/etc/hosts`:

```text
127.0.0.1  ohs-player.local
```

Containers do not read your `/etc/hosts` — they resolve `PUBLIC_HOST` through the nginx
service's Docker network alias, which is why nothing is needed on the container side.

`nginx/ohs-player-subdomains.conf.example` documents the alternative layout, one hostname
per service. It needs explicit CORS handling for `/api/*`, which is why the same-origin
config is the default.

---

## Roles and permissions

The realm carries **two independent role models**, because the backend enforces two. They
look similar in a token and are checked in completely different places, so it is worth
knowing which is which before you wonder why a request was refused.

| Role shape | Gates | Enforced by |
|---|---|---|
| `GET_PATIENT`, `POST_ENCOUNTER` | Anything the gateway forwards to the FHIR server (`/fhir/*`) | `OhsPlayerAccessChecker` in the gateway |
| `users.manage`, `roles.view` | The backend's own endpoints (`/api/*`) | `AuthorizationHandler` in the backend |
| `admin`, `care-team-manager` | Which screens the Web Portal shows | The Portal itself, in the browser |

Granting one does nothing for the others. A user with `admin` and `users.manage` can
administer the Portal and still be refused every FHIR read.

### FHIR access — `<VERB>_<RESOURCE>`

`ACCESS_CHECKER=ohs_player_access` makes the gateway require one role per HTTP verb and
FHIR resource type. Reading Encounters needs `GET_ENCOUNTER`; writing Patients needs
`PUT_PATIENT`. The check is literal — the checker builds the name it wants by joining the
verb and the upper-cased resource type.

For a Bundle, **every entry** must be individually authorized or the whole Bundle is
refused.

The realm defines 96 of these, covering 29 resource types:

| Verb | Roles |
|---|---|
| `GET` | 28 |
| `POST` | 26 |
| `PUT` | 27 |
| `PATCH` | 15 |
| `DELETE` | **0** |

> There are no `DELETE_*` roles. Deletion cannot be granted through this realm as it
> stands — add the roles you need if you want it.

### Backend endpoints — `resource.level`

The backend's `/api/*` servlets use a three-level hierarchy per resource, where a higher
level satisfies every lower check: **manage ⊇ edit ⊇ view**.

| Role | Grants |
|---|---|
| `users.view` | `GET /api/users/*` |
| `users.edit` | `users.view`, plus create, update, and password reset |
| `users.manage` | `users.edit`, plus delete |
| `groups.view` | `GET /api/groups/*` |
| `groups.edit` | `groups.view`, plus create, update, and add member |
| `groups.manage` | `groups.edit`, plus delete group and remove member |
| `bulk-import.manage` | `POST /api/bulk-import/*` |
| `roles.view` | `GET /api/roles` |
| `practitioner-details.view` | Looking up **another** user's practitioner record |
| `location-hierarchy.view` | `GET /api/location-hierarchy/{rootId}` |

The hierarchy is resolved in the backend's code, not through Keycloak composite roles, so
assigning `users.manage` alone is enough — there is no need to also assign `users.edit`
and `users.view`.

`GET /api/practitioner-details` with no query parameters resolves the caller's own record
from their token and needs no role beyond a valid one.

### Portal roles

`admin` and `care-team-manager` are the Web Portal's own, and are what it offers when
assigning a role to a user. They gate its screens and mean nothing to the gateway or the
backend.

### Groups

Users get roles by group membership. What each group carries:

| Group | FHIR roles | Backend roles | Portal |
|---|---|---|---|
| **Super User** | 94 | `users.manage`, `groups.manage`, `bulk-import.manage`, `roles.view`, `practitioner-details.view`, `location-hierarchy.view` | `admin` |
| **Provider** | 90 | `location-hierarchy.view` | `care-team-manager` |
| **Practitioner** | 72 | — | — |
| **Cam** | 0 | — | — |

> **`Cam` grants nothing.** It exists in the realm with no roles at all, so a user in it
> is refused everything. Useful as a deliberate negative case; surprising if you assign it
> expecting access.

**No user shipped in the realm import belongs to any group.** A fresh stack authenticates
its default user and then denies it every FHIR request — which reads like a broken
gateway rather than a missing group membership. Assign a group in the admin console
before testing access.

### Where a refusal comes from

| Symptom | Likely cause |
|---|---|
| `401` on any request | No token, or an expired or malformed one |
| `403` from `/fhir/*` | Missing the `<VERB>_<RESOURCE>` role for that exact call |
| `403` from `/api/*` | Missing the `resource.level` role |
| `500` from every `/fhir/*` request | Not a role problem — `ACCESS_CHECKER` names a checker the gateway does not register. See [Troubleshooting](#troubleshooting) |
| Portal hides a screen | Missing `admin` or `care-team-manager` |

### Legacy roles

`VIEW_KEYCLOAK_USERS` and `EDIT_KEYCLOAK_USERS` predate the `users.*` roles and do the
same job by a different route: they are composite roles granting `realm-management`
client roles straight to the end user, rather than going through the backend with its
service account. They are still assigned to Practitioner, Provider and Super User.

Prefer `users.view` / `users.edit` / `users.manage` for anything new.

## Secrets and exposure

`./dev.sh up` generates a unique random value for every `[generated]` marker in `.env`, so
no two installs share a password. Three things it does **not** cover are listed below —
read this before putting the stack anywhere other people can reach.

### What is generated for you

Eight values, each 24 random bytes from `/dev/urandom`, written into `.env` on first run:

| Variable | Protects |
|---|---|
| `POSTGRES_ADMIN_PASSWORD` | The Postgres superuser |
| `KEYCLOAK_DB_PASSWORD` | Keycloak's database role |
| `HAPI_FHIR_DB_PASSWORD` | HAPI FHIR's database role |
| `KEYCLOAK_ADMIN_PASSWORD` | The Keycloak admin console |
| `OHS_PLAYER_KEYCLOAK_CLIENT_SECRET` | The `ohs-player-client` client |
| `HAPI_FHIR_SERVER_KEYCLOAK_CLIENT_SECRET` | The `hapi-fhir-server-client` client |
| `FHIR_GATEWAY_KEYCLOAK_CLIENT_SECRET` | The gateway's service-account client |
| `SUPERSET_SECRET_KEY` | Superset session encryption |

`.env` is gitignored and created `chmod 600`. Never commit it.

### What ships with a fixed value — change these

**1. Superset's login is `admin` / `admin`.**

This one is not in `.env` at all — it is written into `docker-compose.yaml`'s Superset
start-up command, so nothing randomises it. Superset publishes on **all interfaces** on
port `8088`, which means on any networked machine that dashboard is one guess away.

Change it as soon as Superset is up:

```bash
docker compose exec superset superset fab reset-password \
  --username admin --password '<a new password>'
```

**2. The Keycloak admin username is `admin`.**

The password is generated, but the username is predictable. Change `KEYCLOAK_ADMIN_USERNAME`
in `.env` before the first start, or create a new admin account and delete `admin`
afterwards — Keycloak only reads the bootstrap credentials when the realm database is
empty.

**3. The Postgres superuser is `postgres`.**

Conventional, and its password is generated, but worth knowing it is not a secret.

### What is exposed, and where

Only the databases are restricted to your own machine. Everything else publishes on **all
interfaces**:

| Service | Port | Bound to |
|---|---|---|
| Postgres, synth Postgres, analytics Postgres | `5433`, `5435`, `5434` | Loopback only |
| Keycloak | `8081` | All interfaces |
| HAPI FHIR | `8082` | All interfaces |
| FHIR Gateway | `8083` | All interfaces |
| Web Portal | `8084` | All interfaces |
| Synth HAPI FHIR | `8085` | All interfaces |
| Pipeline controller | `8090` | All interfaces |
| Superset | `8088` | All interfaces |

> **Two defaults combine badly.** `HAPI_CONFIG=application-no-auth.yaml` is the default, and
> HAPI FHIR publishes on all interfaces — so on a networked machine the FHIR server accepts
> unauthenticated reads and writes directly on `8082`, bypassing the gateway entirely.
> That is fine on a laptop and wrong anywhere else. Switch to `application-auth.yaml`, or
> keep the machine off untrusted networks.

The pipeline controller on `8090` has no authentication of its own either.

### Rotating a secret after setup

Editing `.env` is not enough on its own, because most of these values were already written
somewhere on first start.

| Secret | To rotate |
|---|---|
| Database passwords | Change `.env`, then `ALTER USER <role> WITH PASSWORD '<new>'` in Postgres. Changing only `.env` leaves the database on the old password and Keycloak or HAPI then fails to connect |
| Keycloak client secrets | Change `.env`, then update the same secret on the client in the Keycloak admin console. The realm import will not overwrite an existing realm |
| Keycloak admin password | Change it in the admin console. `KEYCLOAK_ADMIN_PASSWORD` only applies to a database that has never been initialised |
| Superset login | The `reset-password` command above |
| `SUPERSET_SECRET_KEY` | Change `.env` and restart Superset; existing sessions are invalidated |

The blunt alternative, on a machine with nothing worth keeping:

```bash
./dev.sh reset && ./dev.sh up
```

That wipes every volume and regenerates the lot from a clean slate — realm, users, and all
FHIR data included.

### Before any shared or public deployment

- Change the Superset login, and consider whether Superset and the pipeline controller
  should be published at all.
- Switch `HAPI_CONFIG` to `application-auth.yaml`.
- Keep `RUN_MODE=PROD` and a real `ACCESS_CHECKER`. `RUN_MODE=DEV` with
  `ACCESS_CHECKER=permissive` disables FHIR access control completely.
- Put the stack behind TLS — see [Running on a server](#running-on-a-server).
- Treat `.env` as a credential file: `chmod 600`, never in version control, never in an
  image layer.

## Server and advanced configuration

### Using an external Postgres

The bundled `postgres` service creates the `keycloak` and `hapi_fhir` roles on first boot
via `postgres/init/01-init.sh`. To use a database you already run instead:

**Step 1 — point the stack at it.** Set `POSTGRES_HOST` in `.env` to its hostname, or to
`host.docker.internal` for one running on this same machine.

**Step 2 — create the roles and databases yourself.**

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

The passwords must match `KEYCLOAK_DB_PASSWORD` and `HAPI_FHIR_DB_PASSWORD` in `.env`.

**Two different port variables.** `POSTGRES_PORT` is the port the containers connect to.
`POSTGRES_HOST_PORT` only affects the bundled service's mapping onto your machine. If your
external database listens on the standard port, leave `POSTGRES_PORT=5432`.

### Changing ports

Every port is a variable in `.env`. Change the value and re-run `./dev.sh up`.

Keycloak is the one exception worth understanding: it is published **1:1**, meaning
`KEYCLOAK_PORT` sets both the host port and the port inside the container. That is
deliberate. `keycloak.localhost:8081` then resolves to the same place from your browser and
from inside the Docker network, so the token issuer matches everywhere. If you change
`KEYCLOAK_PORT`, update `KEYCLOAK_PUBLIC_URL` to match, and note that
`nginx/ohs-player.conf` hardcodes `8081` for its Keycloak upstream.

### Running on a server

This repository targets local development. For a server deployment:

- `nginx/ohs-player.conf` is the same-origin front and works unchanged behind a real
  hostname; set `PUBLIC_HOST` to that hostname.
- `nginx/ohs-player-subdomains.conf.example` is the one-hostname-per-service alternative,
  written for an nginx installed on the host rather than the bundled container.
- Add TLS at whichever nginx terminates traffic, and switch `KEYCLOAK_PUBLIC_URL` and
  `OHS_PLAYER_APP_HOST` to `https://` values.
- Keep `RUN_MODE=PROD` and a real `ACCESS_CHECKER`. `RUN_MODE=DEV` with
  `ACCESS_CHECKER=permissive` disables access control entirely and exists only for local
  debugging.

---

## Reference

### How `dev.sh` works

`dev.sh` is a thin wrapper around `docker compose` that adds secret generation and
template rendering. Before it calls compose at all, `./dev.sh up` does three things:

**1. Bootstraps `.env`.** If it does not exist, copies `.env.example` and replaces every
`[generated]` marker with 24 random bytes read from `/dev/urandom`.

**2. Renders the config templates.** Each pair below is rendered with `envsubst` and an
explicit variable list, so Spring's own `${DB_HOST}` placeholders survive untouched while
your secrets are filled in:

| Template | Rendered to |
|---|---|
| `keycloak/ohs-player-realm.json.example` | `keycloak/ohs-player-realm.json` |
| `hapi-fhir/application-no-auth.yaml.example` | `hapi-fhir/application-no-auth.yaml` |
| `hapi-fhir/application-auth.yaml.example` | `hapi-fhir/application-auth.yaml` |
| `data-pipes/config/postgres-analytics.json.example` | `data-pipes/config/postgres-analytics.json` |

All four rendered files are gitignored — they contain secrets.

**3. Recompiles the HAPI healthcheck**, if a JDK is present and the source is newer than
the committed `.class`.

Then it runs `docker compose pull --ignore-buildable` followed by `up -d --build`.

### Running without `dev.sh`

`dev.sh` is a thin wrapper around `docker compose`. Everything it does can be done by
hand, which is what you want if your environment forbids running scripts, you are folding
these steps into your own automation, or you simply want to see exactly what happens.

Run all of these from the repository root.

#### Step 1 — create your `.env`

```bash
cp .env.example .env
chmod 600 .env
```

`docker compose` reads `.env` from the project directory automatically, which is why none
of the commands below pass `--env-file`.

#### Step 2 — fill in the eight secrets

`.env` ships with the literal placeholder `[generated]` on eight settings:

| Variable | Used for |
|---|---|
| `POSTGRES_ADMIN_PASSWORD` | Postgres superuser |
| `KEYCLOAK_DB_PASSWORD` | The `keycloak` database role |
| `KEYCLOAK_ADMIN_PASSWORD` | Keycloak admin console login |
| `HAPI_FHIR_DB_PASSWORD` | The `hapi_fhir` database role |
| `FHIR_GATEWAY_KEYCLOAK_CLIENT_SECRET` | Gateway's Keycloak service-account client |
| `HAPI_FHIR_SERVER_KEYCLOAK_CLIENT_SECRET` | HAPI's Keycloak client (auth mode only) |
| `OHS_PLAYER_KEYCLOAK_CLIENT_SECRET` | The `ohs-player-client` Keycloak client |
| `SUPERSET_SECRET_KEY` | Superset session encryption (`--pipes` only) |

Replace each one with its own distinct value. To generate one:

```bash
od -An -N24 -tx1 /dev/urandom | tr -d ' \n'; echo
```

Or replace them all at once:

```bash
while grep -q '=\[generated\]' .env; do
  secret="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
  [ -n "$secret" ] || { echo "empty secret, aborting"; break; }
  sed -i "0,/=\[generated\]/{s/=\[generated\]/=$secret/}" .env
done
```

On macOS, `sed -i` needs an argument: use `sed -i ''` in place of `sed -i`.

Confirm none were missed. Both commands should print `0`:

```bash
grep -cE '^[A-Z_]+=\[generated\]$' .env    # unfilled placeholders
grep -cE '^[A-Z_]+=$' .env                 # accidentally blank values
```

> A blank secret is the failure worth guarding against: the stack will start, and Postgres
> will accept an empty password, leaving you with a database whose credentials are nothing
> at all.

#### Step 3 — render the four config templates

The services read plain config files, not templates. Each is produced with `envsubst`
given an **explicit list of variables**. The list matters: it is what stops `envsubst`
from also eating Spring's own `${DB_HOST}` and `${DB_PORT}` placeholders, which must
survive into the rendered file for the container to expand at runtime.

```bash
set -a; . ./.env; set +a

envsubst '${OHS_PLAYER_KEYCLOAK_CLIENT_SECRET} ${OHS_PLAYER_APP_HOST} ${HAPI_FHIR_SERVER_KEYCLOAK_CLIENT_SECRET} ${FHIR_GATEWAY_KEYCLOAK_CLIENT_SECRET}' \
  < keycloak/ohs-player-realm.json.example \
  > keycloak/ohs-player-realm.json

envsubst '${HAPI_FHIR_DB_PASSWORD}' \
  < hapi-fhir/application-no-auth.yaml.example \
  > hapi-fhir/application-no-auth.yaml

envsubst '${HAPI_FHIR_DB_PASSWORD} ${HAPI_FHIR_SERVER_KEYCLOAK_CLIENT_SECRET} ${KEYCLOAK_PUBLIC_URL}' \
  < hapi-fhir/application-auth.yaml.example \
  > hapi-fhir/application-auth.yaml

envsubst '${POSTGRES_ADMIN_PASSWORD}' \
  < data-pipes/config/postgres-analytics.json.example \
  > data-pipes/config/postgres-analytics.json
```

Check the realm rendered cleanly — this should print `0`:

```bash
grep -c '\${[A-Z_]*}' keycloak/ohs-player-realm.json
```

All four outputs contain secrets and are gitignored. Never commit them.

> The realm name and the application client id are fixed at `ohs-player` and
> `ohs-player-client`. They are written literally into the template rather than rendered,
> so there is no variable to keep in step — and no way for the realm file, the compose
> issuer and the SPA bundle to disagree about them.

#### Step 4 — the HAPI healthcheck (usually nothing to do)

`hapi-fhir/health/Healthcheck.class` is committed, so there is nothing to build. Only if
you edited the `.java` source:

```bash
cd hapi-fhir/health && javac Healthcheck.java && cd ../..
```

#### Step 5 — start the stack

```bash
docker compose pull --ignore-buildable
docker compose up -d --build
docker compose ps
```

`--ignore-buildable` matters: the gateway and the web portal are built from source and
exist in no registry, so a plain `docker compose pull` exits non-zero on them. `--build`
matters because `up -d` alone only builds an image when it is *absent* — without it, a
changed `.env` value never reaches an already-built SPA bundle.

To include optional services, add profiles:

```bash
docker compose --profile web up -d --build         # + Web Portal
docker compose --profile synth up -d --build       # + synthetic-data HAPI and Postgres
docker compose --profile pipes up -d --build       # + synth, Data Pipes and Superset
docker compose --profile proxy up -d --build       # + nginx front (and the Web Portal)
docker compose --profile full up -d --build        # everything
```

#### Stopping and resetting

Profiles must be repeated when stopping, or containers from those profiles are left
running:

```bash
# stop, keeping data
docker compose --profile web --profile pipes --profile synth --profile proxy --profile full down

# stop and delete all volumes — destroys the realm and every FHIR resource
docker compose --profile web --profile pipes --profile synth --profile proxy --profile full down --volumes
```

#### Command equivalents

| `dev.sh` | By hand |
|---|---|
| `./dev.sh up` | Steps 1–3, then `docker compose pull --ignore-buildable && docker compose up -d --build` |
| `./dev.sh up --web` | Same, with `--profile web` on the compose commands |
| `./dev.sh down` | `docker compose --profile … down` (all profiles, as above) |
| `./dev.sh reset` | The same `down` with `--volumes` |
| `./dev.sh logs [service]` | `docker compose logs -f [service]` |
| `./dev.sh render` | Step 3 |
| `./dev.sh clean` | `rm -f .env keycloak/ohs-player-realm.json hapi-fhir/application-*.yaml data-pipes/config/postgres-analytics.json` |

After `clean`, remember that any existing Postgres volume still holds roles created from
the **old** secrets. Regenerating `.env` without also removing the volumes gives you a
Keycloak that cannot authenticate against its own database.

### HAPI FHIR healthcheck

The HAPI FHIR image is distroless: no shell, no `curl`, no `wget`, so ordinary Docker
`HEALTHCHECK` recipes do not work. The stack ships a small Java program instead and runs it
with the JRE already inside the container.

| File | Purpose |
|---|---|
| `hapi-fhir/health/Healthcheck.java` | Source — readable and reviewable |
| `hapi-fhir/health/Healthcheck.class` | Compiled bytecode, mounted into the container |

Both are committed so a fresh clone works without a JDK. `dev.sh` recompiles the `.class`
only when `javac` is available **and** the source is newer. If you edit the source on a
machine without a JDK, compile it elsewhere and commit the updated `.class` alongside.

### Layout

```text
ohs-player-reference-infrastructure/
├── keycloak/
│   ├── ohs-player-realm.json.example  # realm template
│   ├── ohs-player-realm.json          # rendered by dev.sh (gitignored)
│   └── themes/ohs/                    # OHS-branded Keycloak login theme
├── hapi-fhir/
│   ├── application-no-auth.yaml.example
│   ├── application-auth.yaml.example
│   └── health/                        # container healthcheck source + class
├── postgres/
│   └── init/01-init.sh                # runs once, on volume creation
├── data-pipes/                        # ViewDefinitions and pipeline config
├── nginx/
│   ├── spa.conf                       # inside the web image; proxies /fhir and /api
│   ├── ohs-player.conf                # same-origin front (--proxy)
│   └── ohs-player-subdomains.conf.example
├── Dockerfile                         # fhir-gateway + ohs-player plugin
├── Dockerfile.web                     # ohs-player-web SPA
├── docker-compose.yaml                # all services; extras behind profiles
├── .env.example                       # every setting, documented
├── dev.sh                             # lifecycle entrypoint
└── README.md
```

---

## Troubleshooting

**Keycloak fails to start with a database error.** Postgres is still initialising. Wait
about 30 seconds and re-run `./dev.sh up`, or check `./dev.sh logs postgres`.

**Keycloak fails with `password authentication failed for user "keycloak"`.** You ran
`./dev.sh clean`, which generated fresh secrets, but the existing Postgres volume still
holds roles created from the old ones. Postgres only runs `01-init.sh` on an empty data
directory. Run `./dev.sh reset` to wipe the volumes and start clean. `dev.sh clean` warns
about this when it detects a volume.

**Every gateway request returns HTTP 500.** Check `ACCESS_CHECKER` in `.env`. The gateway
logs the names it actually accepts on its first request:

```bash
docker compose logs fhir-gateway | grep 'registered access-checker factories'
```

**`curl http://localhost:8081/health/ready` returns 404.** Expected. Keycloak 26 serves
health on management port `9000`, which this stack does not publish. Use `docker compose ps`
or the realm check in [Confirm it is healthy](#confirm-it-is-healthy).

**HAPI FHIR cannot find its config.** Run `./dev.sh render`, then restart the service.

**I changed `.env` but nothing picked it up.** Values are baked into the rendered configs
and, for `VITE_*`, into the SPA bundle. Re-run `./dev.sh up`.

**Login fails after switching to proxy mode.** The realm was imported with the old
hostname. See [If the stack has already run once](#if-the-stack-has-already-run-once).

**`envsubst is required but was not found on your PATH`, or `Cannot generate secrets`.** A prerequisite is missing.
`dev.sh` prints the install command for your platform — see [Installing them](#installing-them). On macOS this is nearly always the Homebrew
keg-only trap: `brew install gettext` alone is not enough, you also need
`brew link --force gettext`.

**`.env.example not found`.** The repository is missing its template. Re-clone, or restore
the file from version control.

---

## Not covered here

- **Public demo deployment** — VM provisioning, a periodic reset job, and a public landing
  page.
- **Web Portal dev mode** — whether the Portal runs in-container with hot reload, or on the
  host against a backend-only compose, is still an open decision.
