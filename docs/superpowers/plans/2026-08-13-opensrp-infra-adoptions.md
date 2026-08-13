# OpenSRP Infra Adoptions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Adopt three capabilities from `nawitech/opensrp-infrastructure` — an addressing report that asserts the stack is correctly wired, a token-lifespan knob, and user seeding — without adding any service this repository does not run.

**Architecture:** Three additive changes to `dev.sh` plus one new script. Nothing in `docker-compose.yaml`, `Dockerfile`, `Dockerfile.web` or the service set changes. Task 1 adds post-start assertions, Task 2 a realm tweak applied on each `up`, Task 3 a seeding script behind a new `--seed` flag.

**Tech Stack:** bash 4+, `docker compose`, `curl` (host), `python3` (host, for JSON), `curlimages/curl` (container, for FHIR writes), Keycloak 26.5.0 admin REST API, HAPI FHIR R4.

**Spec:** `docs/superpowers/specs/2026-08-13-opensrp-infra-adoptions-design.md`

## Global Constraints

- Tasks 1–3 are confined to `dev.sh`, a new `seed-users.sh`, `.env.example` and `README.md`. They must not touch `docker-compose.yaml`, `Dockerfile`, `Dockerfile.web`, `nginx/`, or any `*.yaml.example` template.
- Task 4 additionally owns `Dockerfile` (stage 1 and one stage-3 line), the `fhir-gateway` service's `build.args` in `docker-compose.yaml`, and a new `gateway/` directory. It must not touch `Dockerfile.web`, `nginx/`, or any service definition other than that one `build.args` entry.
- The gateway's runtime entrypoint — `-Dloader.path=/app/plugins` — does not change. The ohs-player extensions are still built from a clone and injected at runtime, never compiled into the gateway jar.
- Do not port anything OpenSRP-specific: no `nanomq`, no catchment access-checker, no `gateway/scope-config/`, no `--scope`, no `managing-location` SearchParameter, no `--desktop`/`--emulator`/`--lan`, no `BIND_ADDR`.
- Every new check warns and continues. None may make `./dev.sh up` exit non-zero — `up` has already succeeded by the time they run.
- Container names are fixed: `ohs-keycloak`, `ohs-fhir-gateway`, `ohs-hapi-fhir`, `ohs-postgres`. The compose network is `ohs-player-reference-infrastructure_fhir_net`.
- The realm's access checker is `ohs_player_access`; `ACCESS_CHECKER` defaults to it. The Keycloak-to-FHIR identifier system is `http://ohs.dev/identifiers/keycloak-user-id`.
- `curl` is not currently a documented prerequisite. New code must degrade gracefully when it is absent, not fail.
- Never commit `.env` or any rendered artifact (`keycloak/ohs-player-realm.json`, `hapi-fhir/application-*.yaml`, `data-pipes/config/postgres-analytics.json`).
- Commit messages follow the cbea.ms seven rules: imperative subject ≤50 chars, no trailing period, blank line, body wrapped at 72 explaining what and why. No AI attribution trailers.

---

### Task 1: Assert the stack is correctly addressed after `up`

Two misconfigurations cost a full debugging cycle on 2026-08-13, and both were silent until someone tried to use the stack: a `KEYCLOAK_PUBLIC_URL` the gateway could not resolve, and an `ACCESS_CHECKER` naming a checker the build does not register. Both are cheaply detectable right after `up`.

**Files:**
- Modify: `dev.sh` (new functions before `# --- Subcommands`; one call added at the end of `cmd_up`)
- Modify: `README.md` (document what the report prints and what each warning means)

**Interfaces:**
- Consumes: `KEYCLOAK_PUBLIC_URL`, `KEYCLOAK_REALM`, `KEYCLOAK_PORT`, `FHIR_GATEWAY_PORT`, `OHS_PLAYER_WEB_PORT`, `ACCESS_CHECKER` — all already in `.env.example`.
- Produces: `report_addressing`, called at the end of `cmd_up`. Task 2 adds `apply_token_lifespan` immediately before it and reuses `wait_for_keycloak`.

- [ ] **Step 1: Confirm the lazy-logging behaviour this task depends on**

The gateway logs its factory list during servlet init, which is lazy. Verify before coding, on a running stack:

```bash
docker logs ohs-fhir-gateway 2>&1 | grep -c 'List of registered access-checker factories'
curl -sf -o /dev/null http://localhost:8083/fhir/metadata
docker logs ohs-fhir-gateway 2>&1 | grep -c 'List of registered access-checker factories'
```
Expected: `0` before the request and `1` after, on a gateway that has served no traffic. If it is already `1`, the gateway has served a request since starting — that is fine, the point is only that the line appears at request time, not boot.

If the stack is not running, skip this step and trust the spec; the implementation provokes a request regardless, which is correct either way.

- [ ] **Step 2: Add the helpers to `dev.sh`**

Insert immediately before the `# --- Compose helpers` block:

```bash
# --- Post-start verification --------------------------------------------------
# Both checks below encode a real failure. A KEYCLOAK_PUBLIC_URL the gateway
# cannot resolve mints tokens whose `iss` it then rejects; an ACCESS_CHECKER the
# build does not register turns every proxied request into a 500. Neither shows
# up until someone tries to log in, so assert them while the developer is still
# looking at the terminal.
have_curl() { command -v curl >/dev/null 2>&1; }

check_issuer() {
    local realm="$1" expected="$2" advertised=""
    for _ in $(seq 1 30); do
        advertised=$(curl -sf "http://localhost:${KEYCLOAK_PORT:-8081}/realms/${realm}/.well-known/openid-configuration" 2>/dev/null \
            | sed -n 's/.*"issuer":"\([^"]*\)".*/\1/p') && [[ -n "$advertised" ]] && break
        sleep 5
    done
    if [[ -z "$advertised" ]]; then
        warn "Could not read Keycloak's discovery document; skipped the issuer check."
    elif [[ "$advertised" != "$expected" ]]; then
        warn "Keycloak advertises issuer '$advertised', but KEYCLOAK_PUBLIC_URL implies '$expected'."
        warn "Tokens will carry an 'iss' the gateway rejects. Fix KEYCLOAK_PUBLIC_URL in .env and re-run."
    fi
}

# The factory list is logged during servlet init, which is lazy: nothing appears
# until a request arrives. Provoke one, then read the log.
check_access_checker() {
    local want="${ACCESS_CHECKER:-}"
    [[ -n "$want" ]] || return 0
    curl -sf -o /dev/null "http://localhost:${FHIR_GATEWAY_PORT:-8083}/fhir/metadata" 2>/dev/null || true
    local line
    line=$(docker logs ohs-fhir-gateway 2>&1 | grep -m1 'List of registered access-checker factories' || true)
    if [[ -z "$line" ]]; then
        warn "Gateway reported no access-checker factories; skipped the ACCESS_CHECKER check."
    elif [[ "$line" != *"$want"* ]]; then
        warn "ACCESS_CHECKER='$want' is not among the gateway's registered factories:"
        warn "  ${line#*INFO }"
        warn "Every gateway request returns 500 until this value matches one of them."
    fi
}

report_addressing() {
    local realm="${KEYCLOAK_REALM:-ohs-player}"
    local expected="${KEYCLOAK_PUBLIC_URL}/realms/${realm}"

    info "Client addressing:"
    echo "    Keycloak issuer : ${expected}"
    echo "    FHIR base URL   : http://localhost:${FHIR_GATEWAY_PORT:-8083}/fhir"
    echo "    Web portal      : http://localhost:${OHS_PLAYER_WEB_PORT:-8084}"

    if ! have_curl; then
        warn "curl not installed; skipped the issuer and access-checker checks."
        return 0
    fi
    check_issuer "$realm" "$expected"
    check_access_checker
}
```

- [ ] **Step 3: Call it from `cmd_up`**

`cmd_up` currently ends with `compose "${PROFILE_ARGS[@]}" ps`. Add one line after it:

```bash
    report_addressing
```

`cmd_up` already ran `render_templates`, which calls `load_env`, so the variables are in scope.

- [ ] **Step 4: Verify the happy path is quiet**

Run: `./dev.sh up` on a correctly configured `.env`.
Expected: the three addressing lines print, and no `[WARN]` follows them.

- [ ] **Step 5: Verify assertion A fires**

```bash
cp .env /tmp/env.bak
sed -i 's|^KEYCLOAK_PUBLIC_URL=.*|KEYCLOAK_PUBLIC_URL=http://wrong.example:8081|' .env
./dev.sh up 2>&1 | grep -A1 'advertises issuer'
cp /tmp/env.bak .env
```
Expected: a warning naming both the advertised and the expected issuer.

- [ ] **Step 6: Verify assertion B fires**

```bash
cp .env /tmp/env.bak
sed -i 's|^ACCESS_CHECKER=.*|ACCESS_CHECKER=not-a-real-checker|' .env
./dev.sh up 2>&1 | grep -A2 'is not among the gateway'
cp /tmp/env.bak .env
./dev.sh up
```
Expected: a warning listing the real registered factories (`[list, patient, ohs_player_access]`), produced without any manual request first. The final `up` restores a working gateway.

- [ ] **Step 7: Document it in the README**

Add a subsection under "Verifying the Stack", before "Service endpoints":

````markdown
### Addressing report

`./dev.sh up` ends by printing the URLs a client uses and checking two things
that are otherwise silent until someone tries to log in:

- **Keycloak's advertised issuer** matches `KEYCLOAK_PUBLIC_URL`. A mismatch
  means tokens carry an `iss` the gateway rejects, which surfaces as an
  authentication failure with no obvious cause.
- **`ACCESS_CHECKER` names a checker this gateway build registers.** An
  unrecognised value makes every gateway request return HTTP 500. The gateway
  logs its registered factories only when it serves its first request, so the
  check issues one before reading the log.

Both warn and continue — the stack is already up, and a warning you can read is
more useful than a failed command.
````

- [ ] **Step 8: Commit**

```bash
git add dev.sh README.md
git commit -m "Check issuer and access checker after startup" -m "Two misconfigurations cost a full debugging cycle and both stayed
silent until someone tried to log in: a KEYCLOAK_PUBLIC_URL the gateway
could not resolve, so tokens carried an 'iss' it rejected, and an
ACCESS_CHECKER naming a checker the build does not register, which made
every proxied request a 500.

Assert both at the end of up, while the developer is still watching.
The gateway logs its registered factories lazily, on first request
rather than at boot, so the check provokes one before reading the log.
Both warn rather than fail: the stack is up by then, and a warning is
more use than a non-zero exit."
```

---

### Task 2: Apply a realm access-token lifespan on each `up`

Keycloak's default access token lives 5 minutes. Long-running work outlives it and fails with a 401 that reads like an application bug. This adds an opt-in knob, applied through the admin API after Keycloak is healthy.

**Files:**
- Modify: `.env.example` (new variable in the Keycloak section)
- Modify: `dev.sh` (`wait_for_keycloak`, `admin_token`, `apply_token_lifespan`; one call in `cmd_up`)
- Modify: `README.md` (document the variable)

**Interfaces:**
- Consumes: `KEYCLOAK_ADMIN_USERNAME`, `KEYCLOAK_ADMIN_PASSWORD`, `KEYCLOAK_REALM`, `KEYCLOAK_PORT` — all existing.
- Produces: `wait_for_keycloak` and `admin_token`, both reused by Task 3.

- [ ] **Step 1: Add the variable to `.env.example`**

In the `# --- Keycloak ---` section, after the `KEYCLOAK_REALM` block:

```dotenv
# Access token lifetime in seconds, applied to the realm on every `./dev.sh up`.
# Keycloak's 5-minute default expires in the middle of long-running work, and the
# resulting 401 reads like an application bug rather than an expired token.
# Leave empty to keep whatever the realm import set.
KEYCLOAK_ACCESS_TOKEN_LIFESPAN=
```

- [ ] **Step 2: Add the helpers to `dev.sh`**

Insert immediately before the `# --- Post-start verification` block from Task 1:

```bash
# --- Keycloak admin -----------------------------------------------------------
wait_for_keycloak() {
    for _ in $(seq 1 60); do
        [[ "$(docker inspect -f '{{.State.Health.Status}}' ohs-keycloak 2>/dev/null)" == "healthy" ]] && return 0
        sleep 5
    done
    return 1
}

admin_token() {
    curl -sf -X POST "http://localhost:${KEYCLOAK_PORT:-8081}/realms/master/protocol/openid-connect/token" \
        -d client_id=admin-cli -d grant_type=password \
        -d "username=${KEYCLOAK_ADMIN_USERNAME:-admin}" \
        -d "password=${KEYCLOAK_ADMIN_PASSWORD}" 2>/dev/null \
        | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'
}

# Opt-in: empty KEYCLOAK_ACCESS_TOKEN_LIFESPAN leaves the realm's own value alone.
# Every failure path warns and continues — a token lifetime is a convenience, and
# failing `up` over it would be wrong.
apply_token_lifespan() {
    local want="${KEYCLOAK_ACCESS_TOKEN_LIFESPAN:-}"
    [[ -n "$want" ]] || return 0
    have_curl || { warn "curl not installed; left accessTokenLifespan unchanged."; return 0; }
    wait_for_keycloak || { warn "Keycloak not healthy; left accessTokenLifespan unchanged."; return 0; }
    local realm="${KEYCLOAK_REALM:-ohs-player}" token
    token=$(admin_token || true)
    [[ -n "$token" ]] || { warn "Could not obtain a Keycloak admin token; left accessTokenLifespan unchanged."; return 0; }
    if curl -sf -o /dev/null -X PUT "http://localhost:${KEYCLOAK_PORT:-8081}/admin/realms/${realm}" \
        -H "Authorization: Bearer ${token}" -H 'Content-Type: application/json' \
        -d "{\"realm\":\"${realm}\",\"accessTokenLifespan\":${want}}"; then
        info "Keycloak accessTokenLifespan set to ${want}s."
    else
        warn "Failed to set accessTokenLifespan on realm ${realm}."
    fi
}
```

`have_curl` is defined in Task 1. If Task 1 is not yet applied, add it alongside.

- [ ] **Step 3: Call it from `cmd_up`**

In `cmd_up`, immediately before the `report_addressing` line added in Task 1:

```bash
    apply_token_lifespan
```

- [ ] **Step 4: Verify the default is inert**

```bash
grep -n '^KEYCLOAK_ACCESS_TOKEN_LIFESPAN=' .env
./dev.sh up 2>&1 | grep -c accessTokenLifespan
```
Expected: the variable is empty, and the count is `0` — nothing is said and nothing is changed.

- [ ] **Step 5: Verify it applies when set**

```bash
sed -i 's|^KEYCLOAK_ACCESS_TOKEN_LIFESPAN=.*|KEYCLOAK_ACCESS_TOKEN_LIFESPAN=1800|' .env
./dev.sh up 2>&1 | grep accessTokenLifespan
set -a; source .env; set +a
TOK=$(curl -sf -X POST "http://localhost:${KEYCLOAK_PORT}/realms/master/protocol/openid-connect/token" \
  -d client_id=admin-cli -d grant_type=password \
  -d "username=${KEYCLOAK_ADMIN_USERNAME}" -d "password=${KEYCLOAK_ADMIN_PASSWORD}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
curl -sf -H "Authorization: Bearer $TOK" "http://localhost:${KEYCLOAK_PORT}/admin/realms/${KEYCLOAK_REALM}" \
  | python3 -c 'import json,sys; print("accessTokenLifespan:", json.load(sys.stdin)["accessTokenLifespan"])'
```
Expected: the script reports setting it, and the realm reads back `1800`.

- [ ] **Step 6: Document it**

In the README's Auth Mode section, add:

````markdown
### Token lifetime

`KEYCLOAK_ACCESS_TOKEN_LIFESPAN` (seconds) is applied to the realm on every
`./dev.sh up`. Keycloak's 5-minute default expires during long-running work and
returns a 401 that looks like an application bug. Leave it empty to keep
whatever the realm import set.
````

- [ ] **Step 7: Commit**

```bash
git add dev.sh .env.example README.md
git commit -m "Let .env set the realm access-token lifetime" -m "Keycloak's default access token lives five minutes, which expires in
the middle of long-running work and returns a 401 that reads like an
application bug rather than an expired token.

KEYCLOAK_ACCESS_TOKEN_LIFESPAN applies a realm value through the admin
API once Keycloak is healthy. Empty by default, so the realm import's
own value stands unless someone opts in, and every failure path warns
and continues rather than failing an up that has already succeeded."
```

---

### Task 3: Seed users with a matching FHIR identity

The realm's groups carry the method roles the access checker reads — `Practitioner` 76, `Provider` 95, `Super User` 99, `Cam` zero — but every user the realm imports belongs to no group and holds only `default-roles-*`. A fresh stack therefore authenticates a user who is denied every request through the gateway. This seeds usable ones.

**Files:**
- Create: `seed-users.sh` (executable)
- Modify: `dev.sh` (`--seed` in `parse_profiles`, `run_seed`, call in `cmd_up`, `usage`)
- Modify: `README.md` (document the roster and `--seed`)

**Interfaces:**
- Consumes: `wait_for_keycloak` and `admin_token` from Task 2; `KEYCLOAK_PORT`, `KEYCLOAK_REALM`, `KEYCLOAK_ADMIN_USERNAME`, `KEYCLOAK_ADMIN_PASSWORD`, `HAPI_FHIR_PORT`.
- Produces: `./dev.sh up --seed`, and four Keycloak users each linked to a FHIR `Practitioner` by identifier system `http://ohs.dev/identifiers/keycloak-user-id`.

- [ ] **Step 1: Create `seed-users.sh`**

```bash
#!/usr/bin/env bash
# Seeds one Keycloak user per realm group, each with a matching FHIR identity.
#
# The realm ships groups that carry the method roles (Practitioner 76, Provider 95,
# Super User 99, Cam 0) but no user that belongs to any of them, so a fresh stack
# authenticates a user the gateway denies for everything. These four fix that.
#
# `Cam` is seeded precisely because it carries no roles: it is the control that
# shows what an unauthorised token looks like through the gateway.
#
# The access checker (ohs_player_access) decides from roles in the token. The FHIR
# Practitioner/PractitionerRole/Organization resources exist for the backend's
# /api/practitioner-details endpoint, not for the access decision.
#
# Idempotent: users are upserted, FHIR resources are PUT at fixed ids.
#
#   ./seed-users.sh    (or ./dev.sh up --seed)
#
# Env overrides: KC_URL, REALM, ADMIN_USER, ADMIN_PASS, FHIR_NET, PASSWORD.
set -euo pipefail

KC_URL="${KC_URL:-http://localhost:8081}"
REALM="${REALM:-ohs-player}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:?ADMIN_PASS is required}"
FHIR_NET="${FHIR_NET:-ohs-player-reference-infrastructure_fhir_net}"
PASSWORD="${PASSWORD:-test}"
KC_ID_SYSTEM="http://ohs.dev/identifiers/keycloak-user-id"
CURL_IMG="curlimages/curl:latest"
ORG_ID="ohs-org"
LOC_ID="ohs-loc"

# username | realm group | given | family
ROSTER=(
  "ohs-practitioner|Practitioner|Ada|Practitioner"
  "ohs-provider|Provider|Ben|Provider"
  "ohs-superuser|Super User|Cara|Superuser"
  "ohs-cam|Cam|Dee|Cam"
)

jq_py() { python3 -c "$1"; }

admin_token() {
  curl -sf -X POST "$KC_URL/realms/master/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=admin-cli \
    -d "username=$ADMIN_USER" -d "password=$ADMIN_PASS" \
    | jq_py 'import sys,json; print(json.load(sys.stdin)["access_token"])'
}

# FHIR writes go straight to HAPI on the compose network, not through the gateway:
# with HAPI_CONFIG=application-no-auth.yaml it accepts them unauthenticated, and
# seeding stays independent of the access control it is setting up.
fhir_put() {
  local path="$1" body="$2"
  printf '%s' "$body" | docker run -i --rm --network "$FHIR_NET" "$CURL_IMG" \
    -s -o /dev/null -w "    $path -> HTTP %{http_code}\n" \
    -X PUT "http://hapi-fhir:8080/fhir/$path" \
    -H 'Content-Type: application/fhir+json' --data-binary @-
}

echo "==> Keycloak admin token"
ADMIN="$(admin_token)"
[[ -n "$ADMIN" ]] || { echo "could not obtain an admin token" >&2; exit 1; }

echo "==> resolving realm groups"
GROUPS_JSON="$(curl -sf "$KC_URL/admin/realms/$REALM/groups" -H "Authorization: Bearer $ADMIN")"
# Group names contain spaces ("Super User"), so pass the name through the
# environment rather than interpolating it into the Python source.
group_id() {
  printf '%s' "$GROUPS_JSON" | GROUP_NAME="$1" python3 -c '
import sys, json, os
name = os.environ["GROUP_NAME"]
for g in json.load(sys.stdin):
    if g["name"] == name:
        print(g["id"]); break
'
}

echo "==> shared Organization and Location"
fhir_put "Organization/$ORG_ID" "{\"resourceType\":\"Organization\",\"id\":\"$ORG_ID\",\"name\":\"OHS Player Reference Organization\",\"active\":true}"
fhir_put "Location/$LOC_ID" "{\"resourceType\":\"Location\",\"id\":\"$LOC_ID\",\"name\":\"OHS Player Reference Facility\",\"status\":\"active\",\"managingOrganization\":{\"reference\":\"Organization/$ORG_ID\"}}"

for row in "${ROSTER[@]}"; do
  IFS='|' read -r user group given family <<<"$row"
  echo "==> $user ($group)"

  # Upsert the Keycloak user; a 409 means it already exists.
  curl -s -o /dev/null -X POST "$KC_URL/admin/realms/$REALM/users" \
    -H "Authorization: Bearer $ADMIN" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$user\",\"enabled\":true,\"firstName\":\"$given\",\"lastName\":\"$family\",\"emailVerified\":true}" || true

  uid="$(curl -sf "$KC_URL/admin/realms/$REALM/users?username=$user&exact=true" \
    -H "Authorization: Bearer $ADMIN" \
    | jq_py 'import sys,json; d=json.load(sys.stdin); print(d[0]["id"] if d else "")')"
  [[ -n "$uid" ]] || { echo "    could not resolve user id for $user" >&2; continue; }

  curl -s -o /dev/null -X PUT "$KC_URL/admin/realms/$REALM/users/$uid/reset-password" \
    -H "Authorization: Bearer $ADMIN" -H 'Content-Type: application/json' \
    -d "{\"type\":\"password\",\"value\":\"$PASSWORD\",\"temporary\":false}"

  gid="$(group_id "$group")"
  if [[ -n "$gid" ]]; then
    curl -s -o /dev/null -X PUT "$KC_URL/admin/realms/$REALM/users/$uid/groups/$gid" \
      -H "Authorization: Bearer $ADMIN"
    echo "    joined group '$group'"
  else
    echo "    WARNING: realm group '$group' not found" >&2
  fi

  fhir_put "Practitioner/$user" "{\"resourceType\":\"Practitioner\",\"id\":\"$user\",\"active\":true,\"identifier\":[{\"system\":\"$KC_ID_SYSTEM\",\"value\":\"$uid\"}],\"name\":[{\"given\":[\"$given\"],\"family\":\"$family\"}]}"
  fhir_put "PractitionerRole/$user-role" "{\"resourceType\":\"PractitionerRole\",\"id\":\"$user-role\",\"active\":true,\"practitioner\":{\"reference\":\"Practitioner/$user\"},\"organization\":{\"reference\":\"Organization/$ORG_ID\"},\"location\":[{\"reference\":\"Location/$LOC_ID\"}]}"
done

echo
echo "Seeded ${#ROSTER[@]} users; password for each: $PASSWORD"
echo "Note: 'ohs-cam' is in the Cam group, which carries no roles — it is denied by design."
```

Then: `chmod +x seed-users.sh`

- [ ] **Step 2: Wire `--seed` into `dev.sh`**

In `parse_profiles`, initialise the flag before the loop by adding `SEED=0` as the first line after `PROFILE_ARGS=()`, and add a case alongside the existing profile flags:

```bash
            --seed)  SEED=1 ;;
```

Update the error message on the `*)` line to include `--seed`.

- [ ] **Step 3: Add `run_seed` to `dev.sh`**

Insert after `apply_token_lifespan`:

```bash
run_seed() {
    have_curl || { warn "curl not installed; skipped seeding."; return 0; }
    info "Waiting for Keycloak and HAPI FHIR before seeding..."
    wait_for_keycloak || { warn "Keycloak not healthy; skipped seeding."; return 0; }
    for _ in $(seq 1 60); do
        curl -sf -o /dev/null "http://localhost:${HAPI_FHIR_PORT:-8082}/fhir/metadata" && break
        sleep 5
    done
    KC_URL="http://localhost:${KEYCLOAK_PORT:-8081}" \
    REALM="${KEYCLOAK_REALM:-ohs-player}" \
    ADMIN_USER="${KEYCLOAK_ADMIN_USERNAME:-admin}" \
    ADMIN_PASS="${KEYCLOAK_ADMIN_PASSWORD}" \
    "$SCRIPT_DIR/seed-users.sh"
}
```

- [ ] **Step 4: Call it from `cmd_up`**

In `cmd_up`, after `compose "${PROFILE_ARGS[@]}" ps` and before `apply_token_lifespan`:

```bash
    [[ "${SEED:-0}" == 1 ]] && run_seed || true
```

- [ ] **Step 5: Update `usage`**

Add to the `up` options block:

```
                              --seed   seed Keycloak users + FHIR identity
```

- [ ] **Step 6: Verify seeding works**

```bash
bash -n seed-users.sh && echo "syntax OK"
./dev.sh up --seed
```
Expected: four `==>` blocks, each reporting `joined group` and two `HTTP 200` or `HTTP 201` FHIR writes.

- [ ] **Step 7: Verify idempotence**

```bash
./dev.sh up --seed
set -a; source .env; set +a
docker run --rm --network ohs-player-reference-infrastructure_fhir_net curlimages/curl:latest \
  -sf 'http://hapi-fhir:8080/fhir/Practitioner?_summary=count' \
  | python3 -c 'import json,sys; print("Practitioner total:", json.load(sys.stdin)["total"])'
```
Expected: total is `4` after the second run, not `8`.

- [ ] **Step 8: Verify the access difference is real**

```bash
set -a; source .env; set +a
for u in ohs-superuser ohs-cam; do
  T=$(curl -sf -X POST "http://localhost:${KEYCLOAK_PORT}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \
    -d grant_type=password -d "client_id=${OHS_PLAYER_KEYCLOAK_CLIENT_ID}" \
    -d "client_secret=${OHS_PLAYER_KEYCLOAK_CLIENT_SECRET}" \
    -d "username=$u" -d 'password=test' \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))')
  printf '%s -> ' "$u"
  curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $T" \
    "http://localhost:${FHIR_GATEWAY_PORT}/fhir/Patient"
done
```
Expected: `ohs-superuser` is permitted and `ohs-cam` is not. If the token request itself fails, the `ohs-player-client` may not allow the password grant — record the actual behaviour in the report rather than forcing it; the roster and identity are still correct.

- [ ] **Step 9: Document it**

Add a README section after "Verifying the Stack":

````markdown
## Seeding Users

The realm's groups carry the FHIR method roles the access checker reads, but no
user it imports belongs to any of them — so a fresh stack authenticates a user
that the gateway denies for everything.

```bash
./dev.sh up --seed
```

creates one user per group, each with a FHIR `Practitioner` linked by the
`http://ohs.dev/identifiers/keycloak-user-id` identifier, plus a
`PractitionerRole` against a shared `Organization` and `Location`:

| User | Group | Roles | Password |
|---|---|---|---|
| `ohs-practitioner` | Practitioner | 76 | `test` |
| `ohs-provider` | Provider | 95 | `test` |
| `ohs-superuser` | Super User | 99 | `test` |
| `ohs-cam` | Cam | 0 | `test` |

`ohs-cam` is seeded deliberately: the `Cam` group carries no roles, so it shows
what an unauthorised token looks like through the gateway.

Seeding is idempotent — re-running upserts rather than duplicating. It writes
FHIR resources straight to HAPI rather than through the gateway, so it does not
depend on the access control it is setting up.
````

- [ ] **Step 10: Commit**

```bash
git add seed-users.sh dev.sh README.md
git commit -m "Seed one usable user per realm group" -m "The realm's groups carry the method roles the access checker reads —
Practitioner 76, Provider 95, Super User 99, Cam none — but every user
the import creates belongs to no group and holds only default-roles.
A fresh stack therefore authenticates a user the gateway denies for
everything, which looks like a broken gateway rather than a missing
group membership.

Seed one user per group, each with a FHIR Practitioner linked by the
keycloak-user-id identifier for the practitioner-details endpoint. Cam
is included precisely because it grants nothing: it is the control that
shows what an unauthorised token looks like. Writes go straight to HAPI
so seeding does not depend on the access control it sets up."
```

---

### Task 4: Build the gateway from published artifacts

`Dockerfile` stage 1 currently clones `ohs-foundation/fhir-gateway` and compiles the whole gateway server. Replace it with a small module that resolves the released artifacts from Maven Central. The extensions stage is untouched, and both builds stay inside the image so a fresh clone still builds with no host toolchain.

**Files:**
- Create: `gateway/exec/pom.xml`
- Create: `gateway/exec/src/main/java/com/google/fhir/gateway/MainApp.java`
- Modify: `Dockerfile` (stage 1 only)
- Modify: `docker-compose.yaml` (drop the `GATEWAY_REF` build arg)
- Modify: `.env.example` (drop `GATEWAY_REF`)
- Modify: `README.md` (layout tree, and the build-refs description)

**Interfaces:**
- Consumes: nothing from Tasks 1–3. This task is independent and can be done first or last.
- Produces: an image whose `/app/fhir-gateway-exec.jar` is built from `com.google.fhir.gateway:server:0.5.0` and `:plugins:0.5.0`. The runtime entrypoint and `-Dloader.path` are unchanged, so `ohs_player_access` must still register.

- [ ] **Step 1: Record the current behaviour to compare against**

```bash
docker compose --env-file .env config | grep -A3 'GATEWAY_REF'
grep -n 'GATEWAY_REF' Dockerfile docker-compose.yaml .env.example README.md
```
Expected: `GATEWAY_REF` appears in all four. Note every hit — Step 6 removes them.

- [ ] **Step 2: Create `gateway/exec/pom.xml`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>

  <!-- Resolved from Maven Central, so this image needs no gateway source checkout.
       Bumping the gateway means changing this version (and gateway.version below);
       a Maven coordinate is a release, not a branch, which is the point: the old
       build cloned `main` and Docker then cached a checkout that silently went stale. -->
  <parent>
    <groupId>com.google.fhir.gateway</groupId>
    <artifactId>fhir-gateway</artifactId>
    <version>0.5.0</version>
  </parent>

  <groupId>dev.ohs.player</groupId>
  <artifactId>ohs-player-gateway-exec</artifactId>
  <version>1.0-SNAPSHOT</version>
  <packaging>jar</packaging>
  <name>OHS Player Gateway Executable</name>
  <description>
    The FHIR Gateway server packaged as a runnable jar from published artifacts. The
    ohs-player extensions are not compiled in — they are injected at runtime via
    -Dloader.path, exactly as before.
  </description>

  <properties>
    <maven.compiler.release>17</maven.compiler.release>
    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
    <gateway.version>0.5.0</gateway.version>
    <spring-boot.version>3.5.7</spring-boot.version>
    <maven.deploy.skip>true</maven.deploy.skip>
    <!-- The gateway parent runs license and formatting checks over files that exist
         only in its own source tree; this module is just a packaging shell. -->
    <license.skip>true</license.skip>
    <spotless.check.skip>true</spotless.check.skip>
    <spotless.apply.skip>true</spotless.apply.skip>
  </properties>

  <dependencyManagement>
    <dependencies>
      <!-- The gateway parent manages HAPI but not Spring, and the parent slot is
           taken, so import Spring Boot's BOM instead of inheriting it. -->
      <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-dependencies</artifactId>
        <version>${spring-boot.version}</version>
        <type>pom</type>
        <scope>import</scope>
      </dependency>
    </dependencies>
  </dependencyManagement>

  <dependencies>
    <dependency>
      <groupId>com.google.fhir.gateway</groupId>
      <artifactId>server</artifactId>
      <version>${gateway.version}</version>
    </dependency>
    <!-- The stock access checkers: list, patient. ohs_player_access arrives at
         runtime from the extensions jar on -Dloader.path. -->
    <dependency>
      <groupId>com.google.fhir.gateway</groupId>
      <artifactId>plugins</artifactId>
      <version>${gateway.version}</version>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-web</artifactId>
    </dependency>
  </dependencies>

  <build>
    <finalName>fhir-gateway-exec</finalName>
    <plugins>
      <plugin>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-maven-plugin</artifactId>
        <version>${spring-boot.version}</version>
        <executions>
          <execution>
            <id>repackage</id>
            <goals>
              <goal>repackage</goal>
            </goals>
            <configuration>
              <mainClass>com.google.fhir.gateway.MainApp</mainClass>
              <!-- LOAD-BEARING: ZIP layout selects PropertiesLauncher, which is what
                   makes -Dloader.path work. With the default layout the extensions
                   jar is ignored, ohs_player_access never registers, and every
                   request 500s with "ACCESS_CHECKER ... is not recognized". -->
              <layout>ZIP</layout>
            </configuration>
          </execution>
        </executions>
      </plugin>
      <!-- The parent configures publishing; this module is never published. -->
      <plugin>
        <groupId>org.sonatype.central</groupId>
        <artifactId>central-publishing-maven-plugin</artifactId>
        <configuration>
          <skipPublishing>true</skipPublishing>
        </configuration>
      </plugin>
    </plugins>
  </build>
</project>
```

- [ ] **Step 3: Create `gateway/exec/src/main/java/com/google/fhir/gateway/MainApp.java`**

This is Google's file from the gateway's `exec` module, copied unchanged — the `exec` module is not published, so it cannot be resolved. Keep the licence header and the package intact. It scans only `com.google.fhir.gateway.plugin`; our extensions are still discovered, because they ship `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`.

```java
/*
 * Copyright 2021-2025 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *       http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package com.google.fhir.gateway;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.autoconfigure.jdbc.DataSourceAutoConfiguration;
import org.springframework.boot.web.servlet.ServletComponentScan;

/**
 * This class shows the minimum that is required to create a FHIR Gateway with all AccessChecker
 * plugins defined in "com.google.fhir.gateway.plugin".
 */
@SpringBootApplication(
    scanBasePackages = {"com.google.fhir.gateway.plugin"},
    exclude = {DataSourceAutoConfiguration.class})
@ServletComponentScan(basePackages = "com.google.fhir.gateway")
public class MainApp {

  public static void main(String[] args) {
    SpringApplication.run(MainApp.class, args);
  }
}
```

- [ ] **Step 4: Replace stage 1 of `Dockerfile`**

Replace the whole `Stage 1` block — from its banner comment through `RUN cp exec/target/fhir-gateway-exec.jar /fhir-gateway.jar` — with:

```dockerfile
###############################################################################
# Stage 1: package the gateway from published artifacts
#
# The gateway server and its stock plugins resolve from Maven Central, so nothing
# is cloned here. gateway/exec is a packaging shell: the upstream MainApp plus a
# POM that repackages it with ZIP layout, which is what lets -Dloader.path inject
# the ohs-player extensions at runtime.
###############################################################################
FROM maven:3.9-eclipse-temurin-21 AS gateway-build
WORKDIR /src

COPY gateway/exec/pom.xml ./pom.xml
COPY gateway/exec/src ./src

RUN --mount=type=cache,target=/root/.m2 \
    mvn -B package -DskipTests

RUN cp target/fhir-gateway-exec.jar /fhir-gateway.jar
```

Leave stages 2 and 3 exactly as they are. Stage 3 still does `COPY --from=gateway-build /fhir-gateway.jar /app/fhir-gateway.jar`, which this satisfies.

**One stage-3 line needs checking, not assuming.** It currently reads
`COPY --from=gateway-build /src/resources /app/resources` — the gateway repo's `resources/` directory, holding the files `ALLOWED_QUERIES_FILE` and `SYNC_FILTER_IGNORE_RESOURCES_FILE` point at. That directory came from the clone and no longer exists. Resolve it in Step 5 before building.

- [ ] **Step 5: Vendor the allow-list resource stage 1 no longer provides**

This was investigated while writing the plan, so the answer is known — do not re-derive it, but do confirm the first command's output matches before acting.

`docker-compose.yaml` sets `ALLOWED_QUERIES_FILE=resources/hapi_page_url_allowed_queries.json` and `SYNC_FILTER_IGNORE_RESOURCES_FILE=resources/hapi_sync_filter_ignored_queries.json`, both resolved relative to `/app`. Neither published jar contains them; they live in the gateway repo's top-level `resources/`, which is what the old stage 1 copied out of the clone.

Confirm what the current image actually holds:

```bash
docker run --rm --entrypoint sh ohs-fhir-gateway:local -c 'ls /app/resources'
```
Expected: `README.md`, `fhir_access_proxy.png`, `hapi_page_url_allowed_queries.json`, `patient-list-example.json`.

Two things follow. First, only one of those four files is referenced by anything — the image has been carrying a README and a PNG for no reason. Second, **`hapi_sync_filter_ignored_queries.json` is not there and does not exist in the gateway repo either**: `SYNC_FILTER_IGNORE_RESOURCES_FILE` has been pointing at a nonexistent path since the configuration came over from the server deployment. The gateway starts and serves requests regardless, as verified on 2026-08-13, so this is latent rather than breaking.

Do this:

```bash
mkdir -p gateway/resources
gh api repos/ohs-foundation/fhir-gateway/contents/resources/hapi_page_url_allowed_queries.json \
  --jq '.content' | base64 -d > gateway/resources/hapi_page_url_allowed_queries.json
python3 -c "import json; json.load(open('gateway/resources/hapi_page_url_allowed_queries.json')); print('valid JSON')"
```

Then in stage 3 of `Dockerfile`, replace

```dockerfile
COPY --from=gateway-build /src/resources /app/resources
```

with

```dockerfile
# Only the allow-list the gateway is configured to read. The clone also carried a
# README and a screenshot into the image, which nothing referenced.
COPY gateway/resources /app/resources
```

Leave `SYNC_FILTER_IGNORE_RESOURCES_FILE` alone in this task — it is a pre-existing defect, unrelated to where the gateway is built from, and removing it belongs in its own change. Note it in your report so it can be triaged separately.

- [ ] **Step 6: Remove `GATEWAY_REF`**

A Maven coordinate is not a branch, so the variable no longer means anything.

- `Dockerfile`: the `ARG GATEWAY_REF=main` line is gone with the old stage 1.
- `docker-compose.yaml`: remove `GATEWAY_REF: ${GATEWAY_REF:-main}` from the `fhir-gateway` service's `build.args`. Leave `PLUGIN_REF`.
- `.env.example`: remove the `GATEWAY_REF=main` line and rewrite the build-refs comment to cover only `PLUGIN_REF` and `WEB_REF`, noting that the gateway version is pinned in `gateway/exec/pom.xml`.
- `README.md`: same correction wherever the build refs are described, and add `gateway/exec/` to the layout tree.

- [ ] **Step 7: Verify the build no longer clones the gateway**

```bash
docker compose --env-file .env build --progress plain fhir-gateway 2>&1 | tee /tmp/gwbuild.log | tail -20
grep -c 'git clone .*fhir-gateway.git' /tmp/gwbuild.log
grep -cE 'Downloading from central:.*com/google/fhir/gateway' /tmp/gwbuild.log
```
Expected: the build succeeds, the gateway clone count is `0`, and the Central download count is greater than `0`.

- [ ] **Step 8: Verify the image contents**

```bash
docker run --rm --entrypoint sh ohs-fhir-gateway:local -c 'ls -la /app /app/plugins'
```
Expected: `/app/fhir-gateway.jar` and `/app/plugins/ohs-player-backend-extensions.jar` both present.

- [ ] **Step 9: Verify the access checker still registers — the real test**

```bash
./dev.sh up
curl -s -o /dev/null -w 'gateway /fhir/metadata -> %{http_code}\n' http://localhost:8083/fhir/metadata
docker logs ohs-fhir-gateway 2>&1 | grep -m1 'List of registered access-checker factories'
docker logs ohs-fhir-gateway 2>&1 | grep -iE 'ERROR' | grep -vi 'sniff|elasticsearch' | head -5
```
Expected: HTTP 200, the factory list reads `[list, patient, ohs_player_access]`, and no errors beyond the benign Elasticsearch sniffer noise. `ohs_player_access` in that list is the proof that ZIP layout plus `-Dloader.path` still work; if it is missing, the `<layout>ZIP</layout>` element is the first thing to check.

- [ ] **Step 10: Commit**

```bash
git add gateway/exec Dockerfile docker-compose.yaml .env.example README.md
git commit -m "Build the gateway from published artifacts" -m "The image cloned ohs-foundation/fhir-gateway and compiled the whole
gateway server on every build. That is the slowest stage, it needs
network at build time, and it is not reproducible: GATEWAY_REF=main is a
moving target whose clone layer Docker then caches, so an unchanged ref
silently reuses a stale checkout.

The server and its stock plugins are published on Maven Central, so
gateway/exec resolves them instead. MainApp is not published — it lives
in the gateway's own exec module, which skips publishing — so it is
copied here unchanged; it scans only Google's package, and the
ohs-player extensions are still discovered because they ship a Spring
Boot AutoConfiguration.imports entry.

ZIP layout is retained deliberately: it selects PropertiesLauncher, and
without it -Dloader.path is ignored and ohs_player_access disappears.
GATEWAY_REF goes with the clone; bumping the gateway is now a version
edit in one POM."
```

---

## Final verification

- [ ] `bash -n dev.sh && bash -n seed-users.sh`
- [ ] `./dev.sh clean && ./dev.sh up --seed` on a wiped stack completes, seeds four users, and prints the addressing report with no warnings.
- [ ] `./dev.sh up` without `--seed` does not seed.
- [ ] `./dev.sh help` lists `--seed`.
- [ ] `git status --porcelain` is empty — no `.env` or rendered artifact committed.
- [ ] `git diff --stat <base>..HEAD` lists only: `dev.sh`, `seed-users.sh`, `.env.example`, `README.md`, `Dockerfile`, `docker-compose.yaml`, and the new `gateway/` files. `Dockerfile.web` and `nginx/` must not appear.
- [ ] `grep -rn 'GATEWAY_REF' .` returns nothing outside `docs/`.
- [ ] A full build from a clean cache succeeds and the gateway is not cloned:
      `docker compose build --no-cache fhir-gateway` — `ohs-player-reference-backend` is still cloned, `fhir-gateway.git` is not.
- [ ] After `./dev.sh up`, the gateway logs `[list, patient, ohs_player_access]` and `GET /fhir/metadata` returns 200 — identical to the behaviour recorded on 2026-08-13.
