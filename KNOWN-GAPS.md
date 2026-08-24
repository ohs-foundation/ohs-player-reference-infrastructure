# Known gaps

Work this repository still needs, recorded so it is not rediscovered. Each entry says what
is wrong, why it matters, and what the change would be.

## Correctness

### `SYNC_FILTER_IGNORE_RESOURCES_FILE` points at a file that does not exist

`docker-compose.yaml` sets it to `resources/hapi_sync_filter_ignored_queries.json`. That
file is absent from the gateway image and from the gateway repository — `/app/resources`
holds only `hapi_page_url_allowed_queries.json`, a README and a screenshot. The gateway
starts and serves requests regardless, so this is latent rather than breaking.

Either supply the file or drop the variable. Do not simply delete it without checking
whether sync filtering is wanted.

### `ohs-player-client` has a service account it cannot have

The realm declares `ohs-player-user` with `serviceAccountClientId: ohs-player-client`, but
that client is public with `serviceAccountsEnabled: false`. A public PKCE client has no
service account. Keycloak creates the user anyway and it does nothing.

`hapi-fhir-server-user` is the same shape against a confidential client, so it is valid but
invisible: service accounts do not appear in the admin console's user list.

### `VIEW_KEYCLOAK_USERS` and `EDIT_KEYCLOAK_USERS` duplicate the `users.*` roles

They composite into `realm-management` client roles, granting an end user direct Keycloak
administration. `users.view` / `users.edit` / `users.manage` cover the same intent through
the backend, which acts under the gateway's service account instead. Five references remain
in the realm across the Practitioner and Super User groups.

Retire the pair in favour of the documented roles.

### The Practitioner group's role set has never been reviewed

`GET_PRACTITIONER` and `GET_PRACTITIONERDETAIL` were missing from the higher groups and had
to be added after the Portal failed on its first request. Practitioner is still short 24 of
the 96 FHIR roles. That may be a deliberate tier or the same oversight repeated — nobody has
gone through the list.

## Build and distribution

### Publish the gateway and Web Portal images

Every cold build clones three repositories and runs two Maven builds and a `pnpm install` of
446 packages. It is the slowest thing in the project and the most fragile: a registry
timeout during `pnpm install` fails the whole build.

The gateway is ready to publish today. The Web Portal is not: `VITE_OIDC_ISSUER` is baked
into the bundle at build time, so one published image cannot serve both the default and
proxy configurations. That needs the Portal to read its issuer at runtime — a change in the
Portal repository, not this one.

### Build the gateway from Maven Central

`Dockerfile` clones and compiles the whole gateway server. `com.google.fhir.gateway:server`
and `:plugins` are published at 0.5.0, so a small `gateway/exec` module could resolve them
instead, removing one clone and one Maven build. `MainApp` is not published and would have
to be copied, but can be copied unchanged — the ohs-player extensions load through
`-Dloader.path` and are discovered by Spring Boot auto-configuration.

Fully specified in `.claude/superpowers/plans/2026-08-13-opensrp-infra-adoptions.md`.

### The gateway image is 958 MB

`fhir-gateway.jar` alone is 246 MB. Spring Boot layered jars, or a smaller runtime base,
would cut both build churn and what anyone pulls once images are published.

## Operability

### The gateway and the Web Portal have no health endpoint

Neither has a `healthcheck:` in compose, because neither has anything real to probe. The
gateway returns 404 on every health path and its jar contains no Spring Boot Actuator. The
Portal appears to answer `/health` and `/healthz`, but `spa.conf`'s `try_files` fallback
returns the app shell for any path — those responses are byte-identical to `/index.html`.

For the gateway, add Actuator to the build. For the Portal, serve a literal `/healthz`
above the `try_files` fallback so it is not swallowed.

### Assert the stack is correctly addressed after `up`

Two misconfigurations cost a full debugging cycle each and were silent until someone tried
to log in: a `KEYCLOAK_PUBLIC_URL` the gateway could not resolve, and an `ACCESS_CHECKER`
naming a checker the build does not register. Both are cheap to check at the end of `up`.

Note that the gateway logs its registered checkers only on first request, so the check has
to provoke one before reading the log.

### Superset ships `admin` / `admin`

Written into the compose start-up command rather than `.env`, so nothing randomises it,
and Superset publishes on all interfaces. Documented under **Secrets and exposure** with the
reset command, but it remains a fixed credential in a tracked file.

### The analytics pipeline cannot read an authenticated FHIR server

Removing the synth stack pointed the pipeline at `hapi-fhir`, which it reads anonymously and
directly rather than through the gateway. That works against the default
`application-no-auth.yaml`; under `application-auth.yaml` the FHIR server rejects it and the
pipeline collects nothing. Giving the pipeline a service account of its own is the fix.
Recorded with the rest of the trade-off in [SYNTH-STACK.md](SYNTH-STACK.md).

### `KEYCLOAK_ACCESS_TOKEN_LIFESPAN`

Keycloak's five-minute default expires during long-running work and returns a 401 that reads
like an application bug. An opt-in realm setting applied on each `up` is specified in the
same plan.

## Documentation

### The published guide's health check does not work here

`https://ohs-foundation.github.io/ohs-docs/components/reference-infrastructure/` tells the
reader to `curl http://localhost:8081/health/ready`. Keycloak 26 serves health on a
management port this stack does not publish, so that returns 404 on a healthy Keycloak. The
README uses the realm discovery endpoint instead and explains why. The guide needs the same
correction.

### The README is much longer than the guide

The guide covers the four-service happy path. The README covers that plus profiles, roles,
secrets, server configuration and a manual runbook. If it is published as-is it may want
splitting: everything above **Beyond the core stack** matches the guide's scope, and the
rest reads more naturally as separate pages.

### Sample credentials are non-temporary

`admin-user` and `practitioner-user` ship with fixed passwords in a tracked file. Setting
`"temporary": true` would make Keycloak force a change at first login, at the cost of
breaking any scripted sign-in.
