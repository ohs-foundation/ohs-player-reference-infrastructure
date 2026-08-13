# Adopting startup verification and seeding from opensrp-infrastructure

**Date:** 2026-08-13
**Status:** Approved, pending implementation

## Context

`nawitech/opensrp-infrastructure` (private, last pushed 2026-08-12) is a sibling of this
repository: same `dev.sh` skeleton, same `postgres/init/01-init.sh`, same
`hapi-fhir/health/Healthcheck`, same `.github` templates. It targets OpenSRP v3 rather
than OHS Player, so its services differ, but its `dev.sh` has grown capabilities ours
lacks.

This work adopts three of them. It deliberately takes nothing that would add a service
we do not run.

### What we are not taking, and why

| Item | Reason |
|---|---|
| `nanomq` MQTT broker | A service we do not run |
| Catchment access-checker, `gateway/scope-config/`, `--scope` | OpenSRP domain; our checker is `ohs_player_access` |
| `managing-location` SearchParameter + `$reindex` | OpenSRP domain |
| `keycloak/opensrp-stage-realm.json` | Their realm |
| `postgres:16`, volume at `/var/lib/postgresql/data` | We run `postgres:18`, mounted a level up on purpose |
| `--desktop` / `--emulator` / `--lan`, `BIND_ADDR` | Considered and declined: no device-addressing requirement here |

### The gateway build, adopted with a difference

Their `gateway/exec` is a POM plus a small `MainApp` depending on
`com.google.fhir.gateway:server:0.5.0` and `:plugins:0.5.0` from Maven Central, so no
gateway source checkout is needed. Both artifacts and their parent POM are genuinely
published at 0.5.0 (verified against `repo1.maven.org`), and `ohs-foundation/fhir-gateway`
is a standalone copy at that same version whose recent history is dependency bumps.

We adopt the idea and reject the packaging. Three findings shape how:

1. **`MainApp` is not published.** It lives in the gateway's `exec` module, which sets
   `maven.deploy.skip` and `skipPublishing`. The Central `server` jar contains
   `FhirProxyServer` but no `MainApp`. So an exec module of our own must supply one —
   which is exactly why OpenSRP wrote theirs.
2. **We can use the upstream `MainApp` verbatim.** OpenSRP's version scans
   `dev.ohs.opensrp.gateway` because they compile their access checker *into* the exec
   jar. We do not: our extensions are injected at runtime through `-Dloader.path`, and
   they ship
   `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`
   naming `dev.ohs.player.configs.OhsPlayerBackendExtensionSpringConfiguration`. Spring
   Boot auto-configuration therefore discovers them irrespective of `scanBasePackages` —
   which is why `ohs_player_access` registered on 2026-08-13 even though the gateway's
   `MainApp` scans only `com.google.fhir.gateway.plugin`. Copying that `MainApp`
   unchanged reproduces today's behaviour exactly.
3. **The build stays inside Docker.** OpenSRP's `build.sh` builds the jars on the host and
   requires a sibling `ohs-player-reference-backend` checkout. We keep both builds in the
   image, so a fresh clone still builds unaided with no host toolchain.

The net change: the stage that clones and compiles the entire gateway server is replaced
by a small module resolving released artifacts. The stage that clones and builds the
ohs-player extensions is untouched.

**What this costs.** `GATEWAY_REF` disappears. A Maven coordinate is a released version,
not a branch, so tracking `main` is no longer possible and bumping the gateway means
editing one POM. That is the point — the current build clones `main`, whose result is
neither reproducible nor pinned, and Docker caches the clone layer so an unchanged
`GATEWAY_REF=main` silently reuses a stale checkout.

**What this risks.** Central's 0.5.0 is the released version; `ohs-foundation/fhir-gateway`'s
`main` carries dependency bumps made since. The images are therefore not bit-identical to
what we built yesterday, and only a runtime check can confirm equivalence — hence the
verification below is a real build and boot, not a config parse.

## What the exploration established

Two facts were confirmed by reading `ohs-player-reference-backend`, and they shape the
design:

1. **`OhsPlayerAccessChecker` decides from roles in the token**, not from a FHIR
   identity graph. It registers as `@Named("ohs_player_access")` — matching what the
   running gateway reported on 2026-08-13 — and denies everything when the IAM provider
   returns no roles for a token. The FHIR `Practitioner` / `PractitionerRole` /
   `Organization` / `Location` graph serves the backend's `/api/practitioner-details`
   endpoint, not the access decision.
2. **The Keycloak-to-FHIR link is an identifier**, system
   `http://ohs.dev/identifiers/keycloak-user-id`, carrying the Keycloak user id. The
   backend defines this system and the OpenSRP repository uses the same one, so the
   convention is already shared between the two projects.

A third fact is a gap this work exposes rather than creates:

3. **The realm ships no user that can do anything.** Its groups carry the method roles —
   `Practitioner` 76, `Provider` 95, `Super User` 99, and `Cam` **zero** — but every user
   in the realm import (`ohs-player-user`, `hapi-fhir-server-user`, the gateway service
   account) belongs to no group and holds only `default-roles-*`. A fresh stack therefore
   authenticates a user who is denied every FHIR request through the gateway. Seeding is
   what closes this.

## Design

### 1. Addressing report and assertions after `up`

`dev.sh` gains `report_addressing`, called at the end of `cmd_up`. It prints the
client-facing URLs and then asserts two things. Both assertions encode a failure this
repository actually hit on 2026-08-13.

**Assertion A — the issuer matches.** Fetch
`http://localhost:${KEYCLOAK_PORT}/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration`
and compare its `issuer` against `${KEYCLOAK_PUBLIC_URL}/realms/${KEYCLOAK_REALM}`. A
mismatch means tokens will carry an `iss` the gateway rejects. Retry while Keycloak
finishes starting; warn, do not fail, on mismatch.

**Assertion B — the access checker exists.** `ACCESS_CHECKER` must appear in the
gateway's own log line `List of registered access-checker factories: [...]`. An
unrecognised name makes every gateway request return 500 — the exact defect fixed in
commit `07f9175`.

**Implementation note that matters.** The gateway logs that line during servlet
initialisation, which is lazy: it does not appear until the first request arrives.
Observed on 2026-08-13 — the gateway started at 20:27:50 and only logged the factory list
at 20:29:02, when a request was made. So assertion B must issue one throwaway request to
the gateway *before* reading the log. Reading the log first will find nothing and produce
a false warning.

Both assertions warn rather than exit non-zero: a stack that is up but misconfigured is
more useful to a developer than a failed command, and `up` has already succeeded by this
point.

### 2. Token lifespan

`KEYCLOAK_ACCESS_TOKEN_LIFESPAN` is added to `.env.example`, **empty by default**,
meaning "leave whatever the realm import set". When non-empty, `dev.sh` waits for
Keycloak to be healthy, obtains an admin token via `admin-cli` against the `master`
realm, and `PUT`s `accessTokenLifespan` onto the realm.

Keycloak's 5-minute default expires mid-operation on long-running work, and the resulting
401 reads like an application bug rather than an expired token. Every failure path here
warns and continues — a token lifespan is a convenience, and failing `up` over it would
be wrong.

### 3. Seeding

New `seed-users.sh`, invoked by `./dev.sh up --seed`, idempotent so re-running upserts.

**Roster — one user per realm group**, which is what the realm already defines rather
than an invented hierarchy:

| Username | Group | Roles the group carries | Purpose |
|---|---|---|---|
| `ohs-practitioner` | `Practitioner` | 76 | Ordinary clinical user |
| `ohs-provider` | `Provider` | 95 | Wider access |
| `ohs-superuser` | `Super User` | 99 | Full access |
| `ohs-cam` | `Cam` | 0 | Deliberate negative case |

`Cam` is seeded precisely *because* it carries no roles: it is the control that shows
what an unauthorised token looks like through the gateway, and it documents the group's
current emptiness rather than hiding it.

**Per user, the script creates:**

- a Keycloak user with a known password, joined to its group (group ids resolved from
  `GET /admin/realms/{realm}/groups`)
- a FHIR `Practitioner` carrying `identifier` system
  `http://ohs.dev/identifiers/keycloak-user-id` with the Keycloak user id as its value
- a FHIR `PractitionerRole` linking that practitioner to a shared `Organization`

**Shared, created once:** one `Organization` and one `Location`.

**Write path.** FHIR resources are written directly to `hapi-fhir:8080/fhir` from a
throwaway `curlimages/curl` container on the compose network, not through the gateway.
With the default `HAPI_CONFIG=application-no-auth.yaml` HAPI accepts them unauthenticated,
and going direct keeps seeding independent of the very access control it is setting up.
Keycloak calls go to `http://localhost:${KEYCLOAK_PORT}` with an `admin-cli` token.

**Deterministic ids.** Resources use fixed logical ids and are written with `PUT`, so
re-running updates in place instead of accumulating duplicates.

### 4. Gateway exec module

A new `gateway/exec/` directory holding two files:

- `pom.xml` — parent `com.google.fhir.gateway:fhir-gateway:0.5.0` resolved from Central;
  dependencies `server`, `plugins` and `spring-boot-starter-web`; repackaged by
  `spring-boot-maven-plugin` with `mainClass` `com.google.fhir.gateway.MainApp`,
  `finalName` `fhir-gateway-exec`, and **`<layout>ZIP</layout>`**. The layout is
  load-bearing: it selects `PropertiesLauncher`, which is what makes `-Dloader.path`
  work. Without it the extensions jar is silently ignored and the access checker
  disappears. The gateway parent runs license and formatting checks against files that
  exist only in its own source tree, so `license.skip`, `spotless.check.skip` and
  `spotless.apply.skip` are set.
- `src/main/java/com/google/fhir/gateway/MainApp.java` — the upstream file, copied
  unchanged including its Apache-2.0 header, since it is Google's code.

`Dockerfile` stage 1 changes from "clone `ohs-foundation/fhir-gateway`, `mvn package`" to
"`COPY gateway/exec`, `mvn package`". Stage 2 (clone and build the ohs-player extensions)
and stage 3 (runtime) are unchanged, as is the `-Dloader.path` entrypoint.

`GATEWAY_REF` is removed from `Dockerfile`, `docker-compose.yaml` and `.env.example`.
`PLUGIN_REF` stays, because the extensions are still built from a clone.

## Out of scope

- Changing the realm import so its default users belong to a group. The gap is recorded
  above and the seed covers it; changing shipped realm content is a separate decision.
- `HAPI_CONFIG` defaulting, and `BIND_ADDR` — offered and not selected.
- `Dockerfile.web` and the compose service set. The only compose change is dropping the
  `GATEWAY_REF` build arg.
- Building on the host, or a sibling checkout requirement. Both builds stay in the image.

## Verification

- `./dev.sh up` prints the addressing report; with a correct `.env` both assertions pass
  silently.
- Deliberately setting `KEYCLOAK_PUBLIC_URL` to a wrong value makes assertion A warn.
- Deliberately setting `ACCESS_CHECKER` to a name the build does not register makes
  assertion B warn — and the warning appears without needing a manual request first.
- With `KEYCLOAK_ACCESS_TOKEN_LIFESPAN=1800`, the realm's `accessTokenLifespan` reads
  `1800` through the admin API afterwards; with it empty, the value is untouched.
- `./dev.sh up --seed` creates four users; each authenticates; `ohs-superuser` reaches a
  FHIR resource through the gateway and `ohs-cam` is denied.
- Running `--seed` twice leaves exactly one `Practitioner` per user and one shared
  `Organization`.

For the gateway exec module, a config parse proves nothing — the risk is that Central's
0.5.0 differs from the `main` we built yesterday. The verification is therefore a real
build and boot:

- `docker compose build fhir-gateway` succeeds, and its log shows Maven resolving
  `com.google.fhir.gateway:server:0.5.0` from Central rather than cloning a repository.
- The built image contains both `/app/fhir-gateway-exec.jar` and
  `/app/plugins/ohs-player-backend-extensions.jar`.
- On boot and one request, the gateway logs
  `List of registered access-checker factories: [list, patient, ohs_player_access]` —
  the same list observed on 2026-08-13. `ohs_player_access` present is the proof that
  the ZIP layout and `-Dloader.path` still combine correctly.
- `GET /fhir/metadata` through the gateway returns 200, unauthenticated and with a
  bearer token.
- The stage that clones `ohs-foundation/fhir-gateway` no longer appears in the build.
