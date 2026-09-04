# OHS Player Reference Infrastructure

Reference Infrastructure brings up the services every other OHS Player component
depends on: a FHIR server, identity, the gateway in front of them, and the database
underneath.

It is deployment material rather than an application. Nothing in it is a component you
use directly, which is why it is the first stage rather than an item in the component
set. Everything you set up afterwards points at what this creates.

Full guide: [Set up the environment](https://ohs-foundation.github.io/ohs-docs/components/reference-infrastructure/).

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

#### Linux (Debian, Ubuntu or WSL)

```bash
sudo apt update
sudo apt install gettext-base
```

Docker Engine and the Compose plugin follow
[Docker's own instructions](https://docs.docker.com/engine/install/).

#### Linux (Fedora or RHEL)

```bash
sudo dnf install gettext
```

Note the package is `gettext` here, not `gettext-base`.

#### macOS

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

#### Windows

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

## Bring it up

```bash
git clone https://github.com/ohs-foundation/ohs-player-reference-infrastructure.git
cd ohs-player-reference-infrastructure
./dev.sh up
```

The first run copies `.env.example` to `.env`, replaces every `[generated]` placeholder in
it with a random secret, renders the Keycloak realm and the HAPI FHIR configuration from
those values, builds the gateway and the Web Portal from source, and starts the stack.
Building from source takes several minutes. Published images for the gateway and the Web
Portal are planned, so a first run will pull them rather than build them. Subsequent runs
reuse what is already there.

`.env` holds generated credentials and is deliberately untracked. Do not commit it.

Identity and the FHIR server both take appreciably longer to become ready than the
database does. Allow up to ninety seconds for Keycloak and up to three minutes for HAPI
FHIR on a first run.

## What comes up

| Service | Default port | Role |
|---|---|---|
| PostgreSQL | `5433` | Storage for the FHIR server and identity, bound to loopback only |
| Keycloak | `8081` | Identity: realms, clients, users and roles |
| HAPI FHIR | `8082` | The FHIR server, unmodified |
| FHIR Gateway | `8083` | The authenticated, access-controlled entry point |
| Web Portal | `8084` | The reference SPA, served over the gateway |

Every port is overridable in `.env`.

> The upstream setup guide describes four services. This repository starts the Web Portal
> as well, so the first build also compiles the SPA — several minutes on a cold cache.

**Clients never reach the FHIR server directly.** Everything routes through the gateway,
which is why bringing up the gateway is part of standing up the environment rather than a
later step.

Keycloak's admin console is at <http://keycloak.localhost:8081>. Log in with
`KEYCLOAK_ADMIN_USERNAME` and `KEYCLOAK_ADMIN_PASSWORD` from your `.env`. Browsers resolve
any `*.localhost` name to `127.0.0.1` on their own, so there is nothing to add to
`/etc/hosts`.

---

## Confirm it is healthy

`docker compose ps` lists the containers. All five should show `Up`, and Postgres,
Keycloak and HAPI FHIR should also show `(healthy)`.

Then check that each service answers. Three silent successes mean identity is up, the FHIR
server is serving, and the gateway is proxying to it.

```bash
# identity is serving the realm
curl -sf http://localhost:8081/realms/ohs-player/.well-known/openid-configuration | grep -q issuer

# the FHIR server, reached directly
curl -sf http://localhost:8082/fhir/metadata | grep -q CapabilityStatement

# the same document through the gateway, which is the only route clients use
curl -sf http://localhost:8083/fhir/metadata | grep -q CapabilityStatement
```

The first command checks the realm rather than `/health/ready`. Keycloak 26 serves its
health endpoints on a separate management port that this stack does not publish, so
`curl http://localhost:8081/health/ready` returns 404 even on a healthy Keycloak. The
container's own healthcheck probes that port internally, which is what `docker compose ps`
reports.

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

## Managing the stack

| Command | Does |
|---|---|
| `./dev.sh up` | Render configuration and start services |
| `./dev.sh down` | Stop services, keeping data |
| `./dev.sh reset` | Stop services and wipe the volumes |
| `./dev.sh logs [service]` | Tail logs for everything, or one service |
| `./dev.sh render` | Regenerate service configuration from `.env` |
| `./dev.sh clean` | Remove generated files |
| `./dev.sh nginx` | Install the host vhosts and take TLS certificates (server only) |
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

## Expected result

Five services running, and the three values every other component needs:

| Value | Default |
|---|---|
| FHIR base URL, through the gateway | `http://localhost:8083/fhir` |
| Gateway URL | `http://localhost:8083` |
| Identity issuer | `http://keycloak.localhost:8081/realms/ohs-player` |

## Next step

Set up the backend, which loads the Player endpoints and access rules into the gateway.
The Web Portal and the Client App both depend on it.

## Beyond the core stack

Everything above is the environment the guide describes. The rest of this file covers the
optional add-ons, server-oriented configuration, and reference material owned by this
repository.

## Optional profiles

Postgres, Keycloak, HAPI FHIR, the Gateway and the Web Portal all start by default.
Everything else is opt-in behind a flag:

| Command | Adds |
|---|---|
| `./dev.sh up` | Nothing — the five default services |
| `./dev.sh up --pipes` | FHIR Data Pipes and Superset |
| `./dev.sh up --proxy` | A same-origin nginx front |
| `./dev.sh up --full` | Everything |

Flags combine: `./dev.sh up --pipes --proxy`.

`--web` is still accepted so existing commands keep working, but it now selects nothing —
the Web Portal is always started.

Ports for the optional services:

| Service | Profile | Host port | Variable |
|---|---|---|---|
| nginx front | `--proxy` | `80` | `PROXY_PORT` |
| Analytics Postgres | `--pipes` | `127.0.0.1:5434` | `POSTGRES_ANALYTICS_PORT` |
| Pipeline controller | `--pipes` | `8090` | `PIPELINE_PORT` |
| Superset | `--pipes` | `8088` | `SUPERSET_PORT` |

### Web Portal

Starts by default. Builds the SPA from source and serves it at <http://localhost:8084>.

The first build clones the web portal repository and runs a full `pnpm` install and
build, so it takes several minutes. The browser-facing values are baked into the bundle at
build time, which is why changing any `VITE_*` value in `.env` requires a rebuild —
`./dev.sh up` does that for you.

### Analytics

Adds FHIR Data Pipes and Superset.

The pipeline reads FHIR resources from the transactional server, applies the
ViewDefinitions in `data-pipes/config/views/`, and writes flat tables into an analytics
Postgres. Superset then charts those tables.

| What | Where |
|---|---|
| Pipeline control panel | <http://localhost:8090> |
| Superset | <http://localhost:8088> — log in with `admin` / `admin` |

`PIPELINE_FHIR_SOURCE` in `.env` selects which FHIR server the pipeline reads. It points
at the transactional server, so the pipeline reports on the same records the Portal
writes. It reads anonymously, which `HAPI_CONFIG=application-auth.yaml` does not allow, so the
pipeline collects nothing in that mode until it is given a service account of its own.

### Same-origin proxy

By default each service sits on its own port, so the browser makes cross-origin requests.
`--proxy` puts an nginx container in front that serves the SPA, the gateway and Keycloak
from a **single origin**, so no CORS is involved at all.

That matters because the gateway plugin's `/api/*` endpoints send no CORS headers of their
own. A single origin avoids the problem rather than working around it.

Two values in `.env` must change together. The first is baked
into the Keycloak realm import, the second into the SPA bundle.

```dotenv
KEYCLOAK_PUBLIC_URL=http://ohs-player.localhost
OHS_PLAYER_APP_HOST=ohs-player.localhost
VITE_FHIR_BASE_URL=http://ohs-player.localhost/fhir
```

`VITE_FHIR_BASE_URL` changes with them because it carries an origin. It has to be absolute
— the Portal derives the base for its `/api/*` calls by stripping a trailing `/fhir`, and a
bare `/fhir` strips to nothing, which sends every custom endpoint to `/fhir/api/...` and
earns a 403 from the gateway. It must also name the origin serving the SPA rather than the
gateway, so those calls stay same-origin.

Then start the stack with the proxy profile.

```bash
./dev.sh up --proxy
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
./dev.sh up --proxy
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

The templates under `nginx/host/` document the alternative layout, one hostname per
service, for an nginx running on the host rather than the bundled container. See
[Running on a server](#running-on-a-server).

## Sample data

The stack starts empty. `seed` loads a small, deliberately fictional dataset so the
Portal and the location endpoints have something to show:

`./dev.sh up` loads it automatically the first time, so the Portal's lists are never
blank on a fresh install. It checks for one known resource before doing anything, and
leaves the server alone if it is already there — a later `up` never overwrites what you
have created or edited.

```bash
./dev.sh up             # seeds automatically, but only if the sample data is absent
./dev.sh seed           # load it explicitly, against a running stack
./dev.sh up --seed      # force it, even if it is already loaded
./dev.sh up --no-seed   # never load it
```

Seeding never fails `up`: if HAPI is slow to start or the load does not complete, you get
a warning and a running stack, not a failed command.

| Resource | Count | What it is |
|---|---|---|
| Location | 17 | A six-level tree: Country, Region, District, Constituency, Ward, Facility |
| Organization | 1 | Ndumberi Health Services |
| Practitioner | 2 | One per login |
| PractitionerRole | 2 | Each practitioner at a facility, in the organization |
| CareTeam | 1 | Both practitioners |

The hierarchy runs from Kenya down through Central, Kiambu County, the Kiambu and Limuru
constituencies and their wards to eight facilities, so every level has something beneath
it.

Everything else is one resource per person. There are no practitioner records without a
matching login, so nothing in the Portal's lists is unreachable.

### Users you can sign in as

| Username | Password | Group | Practitioner |
|---|---|---|---|
| `admin-user` | `Admin@123` | Super User | `Practitioner/admin-user` |
| `practitioner-user` | `Practitioner@123` | Practitioner | `Practitioner/practitioner-user` |

`./dev.sh up` prints these at the end of every run, so you do not have to look them up.

The users come from the realm import; the seed creates their Practitioner records. **The
Practitioner id is the Keycloak username**, so one name identifies a person in both
systems.

Each record carries the `http://ohs.dev/identifiers/keycloak-user-id` identifier holding
that user's Keycloak id, which is how the backend resolves a caller to their own record.
Without it, `GET /api/practitioner-details` returns nothing for a signed-in user.

These are sample credentials. Change them for anything beyond development, staging or
testing — see [Secrets and exposure](#secrets-and-exposure).

Everything is written with `PUT` at fixed ids, so re-running upserts rather than
duplicating. Writes go straight to HAPI rather than through the gateway, so seeding does
not depend on the access control it is populating.

To see the tree:

```bash
GET /api/location-hierarchy/seed-loc-country
```

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

The realm defines 99 of these, covering 30 resource types:

| Verb | Roles |
|---|---|
| `GET` | 29 |
| `POST` | 27 |
| `PUT` | 28 |
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
assigning `users.manage` alone would be enough — `users.edit` and `users.view` add nothing
on top of it. Super User is nonetheless given all ten, so that what a token carries matches
what the group is meant to be able to do without relying on the backend to infer it.

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
| **Super User** | 99 | all ten | `admin`, `care-team-manager` |
| **Practitioner** | 72 | `location-hierarchy.view`, `practitioner-details.view` | — |

Super User holds every role the realm defines, all 116 of them. Practitioner holds the two
read-only backend roles, which is what lets it open the location tree and read a
practitioner record; the other eight administer users, groups and imports and are not a
health worker's to hold.

Each group has exactly one member: `admin-user` in Super User, `practitioner-user` in
Practitioner. The three service accounts belong to no group, which is correct — they
authenticate machine-to-machine and never make FHIR requests on a person's behalf.

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
service account. Super User still carries both; Practitioner carries `VIEW_KEYCLOAK_USERS`
only.

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

### What ships with a fixed value

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
| Postgres, analytics Postgres | `5433`, `5434` | Loopback only |
| Keycloak | `8081` | All interfaces |
| HAPI FHIR | `8082` | All interfaces |
| FHIR Gateway | `8083` | All interfaces |
| Web Portal | `8084` | All interfaces |
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

Set `POSTGRES_HOST` in `.env` to its hostname, or to
`host.docker.internal` for one running on this same machine.

Then create the roles and databases yourself.

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

This repository targets local development, so treat what follows as the shape of a
deployment rather than a hardened one. Read [Secrets and exposure](#secrets-and-exposure)
alongside it.

There are two layouts. `--proxy` puts every service on one hostname behind the bundled
nginx, and works on a server unchanged once `PUBLIC_HOST` is a real name. The alternative
gives each service its own subdomain behind an nginx installed on the host, which is what
`nginx/host/` is for.

#### One subdomain per service

Three names, one per service, all resolving publicly to the server's external IP:

| Variable | Example | Serves |
|---|---|---|
| `KEYCLOAK_HOST` | `keycloak.example.org` | Sign-in and token issuance |
| `WEB_HOST` | `web.example.org` | The Portal, and its FHIR and API calls |
| `GATEWAY_HOST` | `gateway.example.org` | The Client App, other native clients, debugging |

Set those in `.env`, then bring the browser-facing values into line:

```dotenv
OHS_PLAYER_APP_HOST=web.example.org
CERTBOT_EMAIL=ops@example.org
BIND_ADDR=127.0.0.1
COMPOSE_FILE=docker-compose.yaml:docker-compose.server.yml
```

`COMPOSE_FILE` makes every `docker compose` call load `docker-compose.server.yml` alongside
the base file, `./dev.sh up` included. That override is what makes the stack server-shaped:

| It sets | Why |
|---|---|
| `KC_HOSTNAME=https://$KEYCLOAK_HOST` | Otherwise Keycloak keeps advertising `KEYCLOAK_PUBLIC_URL`, and the admin console redirects to `http://keycloak.localhost:8081` |
| `KC_PROXY_HEADERS=xforwarded` | So Keycloak builds URLs from the proxy's forwarded headers rather than its container address |
| `TOKEN_ISSUER=https://$KEYCLOAK_HOST/realms/ohs-player` | Must match the `iss` Keycloak mints, character for character |
| `extra_hosts` on the gateway | A container cannot route to its own machine's external IP, so the public Keycloak name is mapped to the docker host and discovery goes out to nginx and back |
| The SPA's build args | Built against `WEB_HOST` and `KEYCLOAK_HOST` rather than localhost |

`BIND_ADDR` lives in the base file rather than the override because compose **appends** port
lists across files instead of replacing them, so an override cannot take a public binding
away. Setting it to `127.0.0.1` moves every published port to loopback and leaves nginx the
only public listener.

`OHS_PLAYER_APP_HOST` is the one value the override cannot supply. It is substituted into
the realm at render time rather than read by compose, so set it by hand.

`VITE_FHIR_BASE_URL` names `WEB_HOST`, not `GATEWAY_HOST`. The web image's own nginx
forwards `/fhir` and `/api/` to the gateway over the compose network, so the browser only
ever talks to one origin and no CORS is involved. Pointing it at `GATEWAY_HOST` also works,
but only because `gateway.conf.example` adds the CORS headers the plugin's `/api/*`
servlets do not send for themselves.

Install the vhosts and start the stack:

```bash
./dev.sh nginx
./dev.sh up
```

`./dev.sh nginx` needs `sudo`, `nginx` and `certbot` on the host. It renders the vhosts,
puts a temporary port 80 one in place for each name that still needs a certificate, runs
certbot, then installs the real vhost.

That order is the whole point. Each rendered vhost names the certificate files it will use,
and nginx refuses to load a vhost whose certificate is missing — so installing them first
would leave certbot unable to obtain the very certificate they need. Setting `CERTBOT_EMAIL`
runs certbot unattended; leaving it empty makes certbot prompt.

It takes one certificate per name rather than a single multi-domain one, so a name whose DNS
is not ready yet does not deny the others theirs. Any name that fails keeps its temporary
port 80 vhost, and re-running the command retries just that one.

`./dev.sh render` alone writes `nginx/host/*.conf` from the `.example` templates beside them,
substituting each hostname and its port. Change a name in `.env` and re-render rather than
editing the rendered file, which is untracked and overwritten on every `up`.

The vhosts redirect port 80 to 443 and keep serving `/.well-known/acme-challenge/` from
`/var/www/certbot`, so renewals continue to work.

#### Before calling it a deployment

- **Bind the published ports to loopback.** They currently listen on every interface, so
  the containers are reachable around nginx. Only Postgres is restricted today.
- **Rebuild after changing the `https://` values.** `VITE_FHIR_BASE_URL` is baked into the
  SPA bundle and `KEYCLOAK_PUBLIC_URL` into the realm import, so both need `./dev.sh up` to
  re-render and rebuild. An already-imported realm ignores the re-rendered file, so switching
  an existing stack also needs `./dev.sh reset`.
- **Leave nginx listening on all interfaces.** The gateway container resolves `KEYCLOAK_HOST`
  for OIDC discovery and calls back in on 443, so binding the listener to the external address
  alone would break token validation from inside the stack.
- **Keep `RUN_MODE=PROD` and a real `ACCESS_CHECKER`.** `RUN_MODE=DEV` with
  `ACCESS_CHECKER=permissive` disables access control entirely and exists only for local
  debugging.
- **Change the sample credentials**, including Superset's `admin` / `admin`.

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
| `nginx/host/keycloak.conf.example` | `nginx/host/keycloak.conf` |
| `nginx/host/gateway.conf.example` | `nginx/host/gateway.conf` |
| `nginx/host/web.conf.example` | `nginx/host/web.conf` |

All seven rendered files are gitignored. The first four hold secrets; the vhosts are
generated rather than secret, and only a server deployment installs them.

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

# host nginx vhosts, only needed for a server deployment
envsubst '${KEYCLOAK_HOST} ${KEYCLOAK_PORT}' \
  < nginx/host/keycloak.conf.example \
  > nginx/host/keycloak.conf

envsubst '${GATEWAY_HOST} ${FHIR_GATEWAY_PORT}' \
  < nginx/host/gateway.conf.example \
  > nginx/host/gateway.conf

envsubst '${WEB_HOST} ${OHS_PLAYER_WEB_PORT}' \
  < nginx/host/web.conf.example \
  > nginx/host/web.conf
```

The vhost allow-lists carry only a hostname and a port, which is what keeps nginx's own
`$host`, `$scheme` and `$http_origin` from being substituted away.

Check the realm rendered cleanly — this should print `0`:

```bash
grep -c '\${[A-Z_]*}' keycloak/ohs-player-realm.json
```

All four outputs contain secrets and are gitignored. Never commit them.

> The realm name and the application client id are fixed at `ohs-player` and
> `ohs-player-client`. They are written literally into the template rather than rendered,
> so there is no variable to keep in step — and no way for the realm file, the compose
> issuer and the SPA bundle to disagree about them.

#### Step 4 — the HAPI healthcheck

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
docker compose --profile pipes up -d --build       # + Data Pipes and Superset
docker compose --profile proxy up -d --build       # + nginx front (and the Web Portal)
docker compose --profile full up -d --build        # everything
```

#### Stopping and resetting

Profiles must be repeated when stopping, or containers from those profiles are left
running:

```bash
# stop, keeping data
docker compose --profile web --profile pipes --profile proxy --profile full down

# stop and delete all volumes — destroys the realm and every FHIR resource
docker compose --profile web --profile pipes --profile proxy --profile full down --volumes
```

#### Command equivalents

| `dev.sh` | By hand |
|---|---|
| `./dev.sh up` | Steps 1–3, then `docker compose pull --ignore-buildable && docker compose up -d --build` |
| `./dev.sh down` | `docker compose --profile … down` (all profiles, as above) |
| `./dev.sh reset` | The same `down` with `--volumes` |
| `./dev.sh logs [service]` | `docker compose logs -f [service]` |
| `./dev.sh render` | Step 3 |
| `./dev.sh clean` | `rm -f .env keycloak/ohs-player-realm.json hapi-fhir/application-*.yaml data-pipes/config/postgres-analytics.json nginx/host/*.conf` |
| `./dev.sh nginx` | No short equivalent — it is a two-phase certbot bootstrap, see [Running on a server](#running-on-a-server) |

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
├── seed/
│   ├── fhir-seed.json                 # organisation and location hierarchy
│   └── seed-fhir.sh                   # loads it, and links realm users
├── nginx/
│   ├── spa.conf                       # inside the web image; proxies /fhir and /api
│   ├── ohs-player.conf                # same-origin front (--proxy)
│   └── host/                          # one vhost per subdomain, for a server
│       ├── keycloak.conf.example
│       ├── gateway.conf.example
│       └── web.conf.example
├── Dockerfile                         # fhir-gateway + ohs-player plugin
├── Dockerfile.web                     # ohs-player-web SPA
├── docker-compose.yaml                # all services; extras behind profiles
├── .env.example                       # every setting, documented
├── dev.sh                             # lifecycle entrypoint
└── README.md
```

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
<<<<<<< Updated upstream
=======

---

## Not covered here

- **Public demo deployment** — VM provisioning, a periodic reset job, and a public landing
  page.
- **Web Portal dev mode** — whether the Portal runs in-container with hot reload, or on the
  host against a backend-only compose, is still an open decision.

Outstanding work on the stack itself is tracked outside this file.
>>>>>>> Stashed changes
