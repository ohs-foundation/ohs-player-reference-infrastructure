#!/bin/bash
set -euo pipefail

# =============================================================================
# dev.sh — local development lifecycle
#
# Subcommands:
#   up [--pipes|--proxy|--full]   Render configs and start services
#   down                        Stop all running services
#   reset                       Stop services and wipe named volumes
#   logs [service]              Tail logs (all services or one)
#   render                      Render service config templates from .env
#   seed                        Load sample FHIR data
#   clean                       Remove generated files (.env, application-*.yaml)
#   nginx                       Install host vhosts and take TLS certificates
#   help                        Show this help
#
# On first run, copy .env.example to .env and fill in values:
#   cp .env.example .env
#   ${EDITOR:-vi} .env
# =============================================================================

# --- Colours -----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# --- Paths -------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
# One resource from seed/fhir-seed.json, used to detect whether it has been loaded.
SEED_MARKER="seed-loc-country"

# --- Host nginx (server deployment) ------------------------------------------
# Overridable for distributions that lay nginx out differently.
NGINX_SITES_AVAILABLE="${NGINX_SITES_AVAILABLE:-/etc/nginx/sites-available}"
NGINX_SITES_ENABLED="${NGINX_SITES_ENABLED:-/etc/nginx/sites-enabled}"
CERTBOT_WEBROOT="${CERTBOT_WEBROOT:-/var/www/certbot}"
LETSENCRYPT_LIVE="${LETSENCRYPT_LIVE:-/etc/letsencrypt/live}"

# --- Prerequisites -----------------------------------------------------------
# The package name differs on every platform, so "install gettext-base" is
# useless advice on macOS or Windows. Name the package for each instead.
install_hint() {
    case "$1" in
        envsubst)
            printf '%s\n' \
                "  Debian / Ubuntu / WSL : sudo apt install gettext-base" \
                "  Fedora / RHEL         : sudo dnf install gettext" \
                "  Alpine                : apk add gettext" \
                "  macOS (Homebrew)      : brew install gettext && brew link --force gettext" \
                "                          Homebrew keeps gettext keg-only, so without the" \
                "                          link step envsubst never lands on your PATH" \
                "  Windows               : run this script from WSL or Git Bash; gettext is" \
                "                          not available to cmd.exe or PowerShell"
            ;;
        buildx)
            printf '%s\n' \
                "  Debian / Ubuntu / WSL : sudo apt install docker-buildx-plugin" \
                "  Fedora / RHEL         : sudo dnf install docker-buildx-plugin" \
                "  Arch                  : sudo pacman -S docker-buildx" \
                "  macOS (Homebrew)      : brew install docker-buildx, then link it in:" \
                '                          mkdir -p ~/.docker/cli-plugins && ln -sfn \' \
                '                            "$(brew --prefix)/opt/docker-buildx/bin/docker-buildx" \' \
                "                            ~/.docker/cli-plugins/docker-buildx" \
                "  Docker Desktop        : bundled already; update Docker Desktop"
            ;;
        memory)
            printf '%s\n' \
                "  Colima         : colima stop && colima start --cpu 4 --memory 8" \
                "  Docker Desktop : Settings > Resources > Memory, raise it to 8 GB" \
                "  Linux          : the daemon uses host memory directly; free some up"
            ;;
        secret)
            printf '%s\n' \
                "  Secrets come from /dev/urandom via od, which is present on virtually" \
                "  every system. If you are seeing this, /dev/urandom is unreadable and" \
                "  neither openssl nor python3 is installed. Any one of these fixes it:" \
                "" \
                "  Debian / Ubuntu / WSL : sudo apt install coreutils" \
                "  Fedora / RHEL         : sudo dnf install coreutils" \
                "  Alpine                : apk add coreutils" \
                "  Any platform          : install openssl, or python3"
            ;;
    esac
}

require_tool() {
    command -v "$1" >/dev/null 2>&1 && return 0
    error "$(printf '%s is required but was not found on your PATH.\n\n%s' "$1" "$(install_hint "$1")")"
}

check_prerequisites() {
    command -v docker >/dev/null 2>&1 || error "Docker is not installed. See 'Before you begin' in the README."
    docker compose version >/dev/null 2>&1 \
        || error "The Docker Compose v2 plugin is not installed (v2.29 or newer is required)."
    # The gateway and web images use `RUN --mount=type=cache`, which only BuildKit
    # understands. Without buildx, compose falls back to the legacy builder and
    # dies several minutes into `up`, after the pulls. Fail here instead.
    docker buildx version >/dev/null 2>&1 \
        || error "$(printf 'The Docker Buildx plugin is not installed, and the images need it to build.\n\n%s' "$(install_hint buildx)")"
    # HAPI's JVM settles around 800 MB resident, and Keycloak, Postgres and the
    # gateway sit alongside it. On a 2 GB Docker VM — the Colima default — the
    # guest kernel OOM-kills HAPI in a loop. That is near-invisible from the
    # outside: a global OOM is not a cgroup limit, so the container still reports
    # OOMKilled=false and simply looks slow to start. Warn rather than error, as
    # the figure is a heuristic and a tuned JVM may fit in less.
    local mem_total
    mem_total="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
    if [[ "$mem_total" =~ ^[0-9]+$ ]] && (( mem_total > 0 && mem_total < 4294967296 )); then
        warn "$(printf 'Docker has only %s MiB of memory. The stack needs about 4 GiB, and\nHAPI FHIR will be OOM-killed in a restart loop below that.\n\n%s' \
            "$(( mem_total / 1048576 ))" "$(install_hint memory)")"
    fi
    # envsubst renders the config templates; openssl generates every secret.
    # Both are checked here so a missing one stops us now rather than surfacing
    # later as an unrendered template or a blank password.
    require_tool envsubst
    # Functional check rather than a named package: generate_secret has three
    # possible sources and only needs one of them to work.
    generate_secret >/dev/null 2>&1 \
        || error "$(printf 'Cannot generate secrets on this machine.\n\n%s' "$(install_hint secret)")"
}

# --- Env file ----------------------------------------------------------------
# Secrets workflow:
#   1. If .env does not exist, copy .env.example to create it.
#   2. Scan .env for any values set to the literal marker [generated].
#      Replace each one with a unique random secret (openssl rand -hex 24).
#
# This means:
#   - First run with no .env: file is created and all secrets are populated.
#   - User copies .env.example manually but leaves some [generated] markers:
#     the remaining markers are filled in automatically on next run.
#   - User has already set all values: nothing is changed.
# /dev/urandom read through od is the widest-available combination there is:
# od is POSIX and ships in GNU coreutils, BSD userland and busybox alike, and
# /dev/urandom exists on Linux, macOS, WSL and Git Bash. It is the same CSPRNG
# that openssl seeds itself from, so this is not a weaker source — and it is
# more available: debian:12-slim, for one, has od but no openssl.
#
# The fallbacks cover hardened environments that restrict /dev/urandom.
# Returns non-zero if no method works; callers must treat that as fatal.
generate_secret() {
    if [[ -r /dev/urandom ]] && command -v od >/dev/null 2>&1; then
        od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
    elif command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 24
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import secrets; print(secrets.token_hex(24))'
    else
        return 1
    fi
}

require_env_file() {
    if [[ ! -f "$ENV_FILE" ]]; then
        local example="$SCRIPT_DIR/.env.example"
        [[ -f "$example" ]] || error ".env.example not found at $example"
        info "No .env found — creating from .env.example..."
        cp "$example" "$ENV_FILE"
        chmod 600 "$ENV_FILE"
    fi
    if grep -q '=\[generated\]' "$ENV_FILE"; then
        info "Replacing [generated] markers in .env with random secrets..."
        # Bash substitution, not `sed -i`: BSD sed (macOS) reads the word after
        # -i as a backup suffix, and has no GNU `0,/re/` for "first match only".
        # `1,/re/` is not a substitute — it spans to the *second* match and would
        # share one secret across two credentials.
        #
        # Assign first, then substitute. Inline, a failing generate_secret would
        # not trip `set -e` — command substitution used as a word never does —
        # and every credential would be blank on a zero exit status.
        #
        # The temp file's bytes are copied back so .env keeps its own mode.
        local tmp line secret
        tmp="$(mktemp "${TMPDIR:-/tmp}/ohs-env.XXXXXX")" \
            || error "Cannot create a temporary file to rewrite .env."
        # The trailing -n test keeps a final line that has no newline.
        while IFS= read -r line || [[ -n "$line" ]]; do
            while [[ "$line" == *"=[generated]"* ]]; do
                secret="$(generate_secret)"
                # Hex, not merely non-empty: bash 5.2 expands an unquoted `&`
                # in the replacement to the matched text, so a non-hex secret
                # would corrupt on Linux but not on macOS. Quoting the
                # replacement instead is worse — bash 3.2 writes the quotes
                # literally.
                [[ -n "$secret" && "$secret" != *[!0-9a-f]* ]] \
                    || { rm -f "$tmp"; error "generate_secret produced an empty or non-hexadecimal value; refusing to write unusable credentials to .env."; }
                line="${line/"=[generated]"/=$secret}"
            done
            printf '%s\n' "$line"
        done < "$ENV_FILE" > "$tmp"
        cat "$tmp" > "$ENV_FILE"
        rm -f "$tmp"
        info "Secrets generated. Review at: $ENV_FILE"
    fi
}

load_env() {
    require_env_file
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
}

# --- Template rendering ------------------------------------------------------
# Uses envsubst with an explicit variable list so Spring placeholders like
# ${DB_HOST} are left untouched.
# Renders to a temp file first and only replaces the target when the bytes
# differ, so a repeat `up` reports the handful of files that actually moved
# rather than reprinting the whole list and looking like it rewrote everything.
RENDER_CHANGED=0
render() {
    local src="$SCRIPT_DIR/$1"
    local dst="$SCRIPT_DIR/$2"
    local vars="$3"
    local tmp
    [[ -f "$src" ]] || error "Template missing: $1"
    tmp="$(mktemp "${TMPDIR:-/tmp}/ohs-render.XXXXXX")" \
        || error "Cannot create a temporary file to render $2."
    envsubst "$vars" < "$src" > "$tmp"
    if [[ -f "$dst" ]] && cmp -s "$tmp" "$dst"; then
        rm -f "$tmp"
        return 0
    fi
    cat "$tmp" > "$dst"
    rm -f "$tmp"
    chmod 644 "$dst"
    RENDER_CHANGED=$((RENDER_CHANGED + 1))
    info "  rendered $2"
}

render_templates() {
    load_env
    RENDER_CHANGED=0

    render keycloak/ohs-player-realm.json.example \
           keycloak/ohs-player-realm.json \
           '${OHS_PLAYER_KEYCLOAK_CLIENT_SECRET} ${OHS_PLAYER_APP_HOST} ${HAPI_FHIR_SERVER_KEYCLOAK_CLIENT_SECRET} ${FHIR_GATEWAY_KEYCLOAK_CLIENT_SECRET}'

    render hapi-fhir/application-no-auth.yaml.example \
           hapi-fhir/application-no-auth.yaml \
           '${HAPI_FHIR_DB_PASSWORD}'

    render hapi-fhir/application-auth.yaml.example \
           hapi-fhir/application-auth.yaml \
           '${HAPI_FHIR_DB_PASSWORD} ${HAPI_FHIR_SERVER_KEYCLOAK_CLIENT_SECRET} ${KEYCLOAK_PUBLIC_URL}'

    render data-pipes/config/postgres-analytics.json.example \
           data-pipes/config/postgres-analytics.json \
           '${POSTGRES_ADMIN_PASSWORD}'

    # Host nginx vhosts, one per public subdomain. Only used for a server
    # deployment; harmless to render for a local stack, which never reads them.
    # The allow-lists keep nginx's own $host, $scheme and $http_origin intact.
    render nginx/host/keycloak.conf.example \
           nginx/host/keycloak.conf \
           '${KEYCLOAK_HOST} ${KEYCLOAK_PORT}'

    render nginx/host/gateway.conf.example \
           nginx/host/gateway.conf \
           '${GATEWAY_HOST} ${FHIR_GATEWAY_PORT}'

    render nginx/host/web.conf.example \
           nginx/host/web.conf \
           '${WEB_HOST} ${OHS_PLAYER_WEB_PORT}'

    # The analytics vhosts belong to the --pipes profile, which most stacks never
    # start. Rendering them with an unset hostname would write `server_name ;`,
    # which nginx refuses to load, so they are written only when named.
    if [[ -n "${PIPELINE_HOST:-}" ]]; then
        render nginx/host/pipeline.conf.example \
               nginx/host/pipeline.conf \
               '${PIPELINE_HOST} ${PIPELINE_PORT}'
    fi

    if [[ -n "${SUPERSET_HOST:-}" ]]; then
        render nginx/host/superset.conf.example \
               nginx/host/superset.conf \
               '${SUPERSET_HOST} ${SUPERSET_PORT}'
    fi

    if (( RENDER_CHANGED == 0 )); then
        info "Configuration is up to date."
    fi
    compile_healthcheck
}

# Service and container id for everything in the selected profiles. Comparing
# two of these across `up` is what lets the summary say which containers were
# actually touched, rather than leaving the reader to infer it from compose
# listing every service it considered.
container_snapshot() {
    # State as well as id: starting a stopped container keeps its id, so an id
    # comparison alone would report a restart as untouched.
    compose_profiles ps -a --format '{{.Service}}:{{.ID}}:{{.State}}' 2>/dev/null | sort
}

report_container_changes() {
    local before="$1" after line svc started="" unchanged=""
    after="$(container_snapshot)"
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        svc="${line%%:*}"
        if printf '%s\n' "$before" | grep -qxF "$line"; then
            unchanged="${unchanged:+$unchanged, }$svc"
        else
            started="${started:+$started, }$svc"
        fi
    done <<<"$after"
    [[ -n "$started" ]]   && info "Started: $started"
    [[ -n "$unchanged" ]] && info "Left running, untouched: $unchanged"
    return 0
}

# True when the named profile was selected, either directly or through --full.
profile_active() {
    local want="$1" arg
    for arg in ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}; do
        case "$arg" in
            "$want"|full) return 0 ;;
        esac
    done
    return 1
}

# Both images already present means this is a repeat run, where the build is a
# cache check worth a second or two and its sixty lines of CACHED steps are
# noise. A first run is the opposite, so let it print.
build_is_incremental() {
    docker image inspect ohs-fhir-gateway:local >/dev/null 2>&1 \
        && docker image inspect ohs-player-web:local >/dev/null 2>&1 \
        || return 1
    # Superset is built too, but only the pipes profile ever needs it, so a
    # core-only run should not go verbose over an image it will not build.
    if profile_active pipes; then
        docker image inspect ohs-superset:local >/dev/null 2>&1 || return 1
    fi
    return 0
}

# --- HAPI healthcheck binary -------------------------------------------------
# The HAPI image is distroless (no shell, no curl). docker-compose mounts
# Healthcheck.class into the container and runs it via the JRE. We commit both
# the .java source and the compiled .class so a fresh clone works without a
# host JDK; if javac is installed and the source is newer, we recompile to
# keep the committed binary honest with the source.
compile_healthcheck() {
    local src="$SCRIPT_DIR/hapi-fhir/health/Healthcheck.java"
    local dst="$SCRIPT_DIR/hapi-fhir/health/Healthcheck.class"

    [[ -f "$src" ]] || return 0

    if ! command -v javac >/dev/null 2>&1; then
        [[ -f "$dst" ]] || error "Healthcheck.class missing and javac not installed. Install a JDK or restore the committed class file."
        return 0
    fi

    if [[ -f "$dst" && "$dst" -nt "$src" ]]; then
        return 0
    fi

    info "Compiling hapi-fhir/health/Healthcheck.java..."
    (cd "$SCRIPT_DIR/hapi-fhir/health" && javac Healthcheck.java)
    info "  compiled Healthcheck.class"
}

# --- Compose helpers ---------------------------------------------------------
compose() {
    (cd "$SCRIPT_DIR" && docker compose "$@")
}

# compose, prefixed with the --profile flags parse_profiles selected.
#
# `${arr[@]+"${arr[@]}"}` rather than plain `"${arr[@]}"`: bash 3.2 (macOS)
# counts an empty array as unbound under `set -u`, and a flagless `./dev.sh up`
# leaves it empty. The `+` form expands to no words, so nothing stray is passed.
compose_profiles() {
    compose ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"} "$@"
}

parse_profiles() {
    PROFILE_ARGS=()
    SEED=auto
    for arg in "$@"; do
        case "$arg" in
            # The web portal is part of the default set; --web is kept so existing
            # commands and docs keep working, and selects nothing.
            --web)   ;;
            --seed)    SEED=1 ;;
            --no-seed) SEED=0 ;;
            --pipes) PROFILE_ARGS+=(--profile pipes) ;;
            --proxy) PROFILE_ARGS+=(--profile proxy) ;;
            --full)  PROFILE_ARGS+=(--profile full)  ;;
            *)       error "Unknown flag: $arg (expected --web, --seed, --no-seed, --pipes, --proxy, or --full)" ;;
        esac
    done
}

# HAPI builds its schema on first boot and can take minutes to answer. Anything
# that queries it right after `up` must wait, or it sees a connection failure and
# mistakes an unready server for an empty one.
wait_for_hapi() {
    local net; net="$(compose_network)"
    for _ in $(seq 1 60); do
        docker run --rm --network "$net" curlimages/curl:latest \
            -sf -o /dev/null http://hapi-fhir:8080/fhir/metadata 2>/dev/null && return 0
        sleep 5
    done
    return 1
}

# --- Seeding -----------------------------------------------------------------
# Waits for the services the seed writes through before running it, so a slow
# first boot surfaces as a wait rather than a confusing connection failure.
cmd_seed() {
    check_prerequisites
    load_env
    local script="$SCRIPT_DIR/seed/seed-fhir.sh"
    [[ -x "$script" ]] || error "Seed script missing or not executable: $script"

    wait_for_hapi || error "HAPI FHIR did not become ready; is the stack up?"

    info "Seeding sample FHIR data..."
    FHIR_NET="$(compose_network)" "$script"
}

# The compose project name prefixes the network; deriving it keeps the seed
# working if the directory is renamed or COMPOSE_PROJECT_NAME is set.
compose_network() {
    printf '%s_fhir_net' "${COMPOSE_PROJECT_NAME:-$(basename "$SCRIPT_DIR")}"
}

# A first run against an empty FHIR server leaves every list in the Portal blank,
# which reads as a broken deployment rather than an empty one. Seed it — but only
# when the server really is empty, so a later `up` never overwrites resources the
# user created or edited. --seed forces it, --no-seed skips it.
maybe_seed() {
    case "${SEED:-auto}" in
        0) return 0 ;;
        1) cmd_seed; return $? ;;
    esac

    info "Waiting for HAPI FHIR before checking for sample data..."
    if ! wait_for_hapi; then
        warn "HAPI FHIR did not become ready; skipped seeding."
        warn "Run './dev.sh seed' once it is up if the Portal's lists are empty."
        return 0
    fi

    # Probe one known resource by id rather than counting. An unfiltered
    # `Location?_summary=count` reports 0 for a while after a bulk write even
    # though the resources are readable, so counting here would re-seed on every
    # single `up`. A read by id is always consistent.
    local code
    code=$(docker run --rm --network "$(compose_network)" curlimages/curl:latest \
             -s -o /dev/null -w '%{http_code}' \
             "http://hapi-fhir:8080/fhir/Location/$SEED_MARKER" 2>/dev/null) || code=000

    case "$code" in
        200) info "Sample data already present — leaving the FHIR server alone." ;;
        404) info "No sample data found — loading it so the Portal has something to show."
             # Never fail `up` over the seed: the stack is already running.
             cmd_seed || warn "Seeding did not complete. Run './dev.sh seed' to retry." ;;
        *)   warn "Could not tell whether sample data is present (HTTP $code); skipped seeding."
             warn "Run './dev.sh seed' if the Portal's lists are empty." ;;
    esac
}

# This is a development stack and the sample logins are printed deliberately.
# They are fixed values in a tracked file, so the terminal reveals nothing a
# reader of the repository does not already have. The Keycloak admin password is
# different — it is generated per install — but a developer cannot administer the
# realm without it, and it is already sitting in .env on the same machine.
#
# Read from the realm template rather than hardcoded here, so this stays correct
# if the roster changes.
# Superset charts datasets, not database connections. The container registers
# the connection at start-up, but the datasets have to be created against a
# built app context, so this runs after `up` rather than in the compose command.
maybe_register_superset() {
    profile_active pipes || return 0
    local script="$SCRIPT_DIR/superset/register-datasets.sh"
    [[ -x "$script" ]] || return 0

    # Superset takes a while past `Started` before its CLI will run.
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        docker exec ohs-superset true >/dev/null 2>&1 && break
        sleep 3
    done

    # The dashboard bundle declares the dataset its chart sits on, and the
    # importer treats that declaration as the whole truth. So it runs first and
    # the dataset registration, which syncs columns from the tables, runs after
    # and repairs anything the bundle shortened.
    local dash="$SCRIPT_DIR/superset/import-dashboard.sh"
    if [[ -x "$dash" ]]; then
        "$dash" || warn "Could not import the Superset dashboard. Run superset/import-dashboard.sh to retry."
    fi

    "$script" || warn "Could not register the Superset datasets. Run superset/register-datasets.sh to retry."
}

print_login_details() {
    local realm="$SCRIPT_DIR/keycloak/ohs-player-realm.json.example"
    [[ -f "$realm" ]] || return 0

    echo
    info "Login credentials"
    echo "    Web Portal at http://localhost:${OHS_PLAYER_WEB_PORT:-8084}"
    python3 - "$realm" <<'PYEOF'
import json, sys
users = []
for u in json.load(open(sys.argv[1])).get("users", []):
    if u.get("serviceAccountClientId"):
        continue                      # machine identities; no interactive login
    creds = u.get("credentials") or []
    users.append((u["username"],
                  creds[0]["value"] if creds else "(no password)",
                  (u.get("groups") or ["-"])[0].lstrip("/")))
if users:
    rows = [("USER", "PASSWORD", "GROUP")] + users
    w0 = max(len(r[0]) for r in rows)
    w1 = max(len(r[1]) for r in rows)
    for user, pw, grp in rows:
        print(f"        {user:<{w0}}  {pw:<{w1}}  {grp}")
PYEOF
    echo
    echo "    Keycloak admin console at ${KEYCLOAK_PUBLIC_URL:-http://keycloak.localhost:8081}"
    local kc_user="${KEYCLOAK_ADMIN_USERNAME:-admin}"
    local kc_pass="${KEYCLOAK_ADMIN_PASSWORD:-(see .env)}"
    local w=$(( ${#kc_user} > 4 ? ${#kc_user} : 4 ))
    printf "        %-${w}s  %s\n" "USER" "PASSWORD"
    printf "        %-${w}s  %s\n" "$kc_user" "$kc_pass"

    # Services that only exist behind a profile. Printed here rather than in the
    # compose comments because this is where someone looks after `up`, and the
    # ports move with .env.
    if profile_active pipes; then
        echo
        echo "    Superset at http://localhost:${SUPERSET_PORT:-8088}"
        printf "        %-5s  %s\n" "USER" "PASSWORD"
        printf "        %-5s  %s\n" "admin" "admin"
        echo
        echo "    Pipeline control panel at http://localhost:${PIPELINE_PORT:-8090}"
        echo "        No sign-in of its own. Anyone who reaches the port can start a"
        echo "        pipeline run and read the warehouse it writes."
    fi

    if profile_active proxy; then
        local origin="http://${PUBLIC_HOST:-ohs-player.localhost}"
        [[ "${PROXY_PORT:-80}" == "80" ]] || origin="$origin:${PROXY_PORT}"
        echo
        echo "    Single origin front at $origin"
        echo "        Serves the Portal, the gateway and Keycloak from one name."
    fi

    echo
    warn "Sample credentials — change them for anything beyond development, staging or testing."
    if profile_active pipes; then
        warn "Superset's admin/admin is fixed in docker-compose.yaml, so it is the same on every install."
    fi
}

# --- Subcommands -------------------------------------------------------------
cmd_up() {
    parse_profiles "$@"
    check_prerequisites
    render_templates
    # --ignore-buildable: fhir-gateway and ohs-player-web are built from source
    # (ohs-fhir-gateway:local, ohs-player-web:local) and exist in no registry, so
    # a plain `pull` fails and set -e would abort before anything starts.
    # Left with its own progress output, unlike the build. A pull is the one
    # step that can genuinely fetch hundreds of megabytes, and watching that
    # happen beats a silent wait. What it changes also shows in the summary
    # below, because a new image id makes compose recreate that container.
    info "Checking for image updates..."
    compose_profiles pull --ignore-buildable

    # --build: `up -d` alone only builds when the image is absent, so changed
    # build args (VITE_*, *_REF) would otherwise never reach a rebuilt image.
    # Quiet on a repeat run, because a full-cache rebuild changes nothing and
    # its output reads as though the stack were being rebuilt from scratch.
    local before
    before="$(container_snapshot)"
    if build_is_incremental; then
        info "Starting services..."
        compose_profiles --progress quiet up -d --build
    else
        info "Building images and starting services. The first build takes several minutes..."
        compose_profiles up -d --build
    fi

    report_container_changes "$before"
    maybe_seed
    maybe_register_superset
    print_login_details
}

cmd_down() {
    check_prerequisites
    info "Stopping stack..."
    compose --profile web --profile pipes --profile proxy --profile full down
}

cmd_reset() {
    check_prerequisites
    warn "This will stop all services and delete named volumes (postgres data will be lost)."
    info "Stopping stack and removing volumes..."
    compose --profile web --profile pipes --profile proxy --profile full down --volumes
    info "Reset complete. Run './dev.sh up' to start fresh."
}

cmd_logs() {
    check_prerequisites
    if [[ $# -eq 0 ]]; then
        compose logs -f
    else
        compose logs -f "$1"
    fi
}

cmd_render() {
    check_prerequisites
    render_templates
}

# Deleting .env means the next `up` generates fresh secrets. Existing volumes
# still hold the roles and admin account created from the OLD ones, and Postgres
# only runs postgres/init/01-init.sh on an empty data directory — so Keycloak
# then fails with "password authentication failed for user keycloak" and the
# admin console rejects the new password. Warn when a volume is present.
cmd_clean() {
    info "Removing generated files..."
    rm -f "$SCRIPT_DIR/.env"
    rm -f "$SCRIPT_DIR/keycloak/ohs-player-realm.json"
    rm -f "$SCRIPT_DIR/hapi-fhir/application-no-auth.yaml"
    rm -f "$SCRIPT_DIR/hapi-fhir/application-auth.yaml"
    rm -f "$SCRIPT_DIR/data-pipes/config/postgres-analytics.json"
    rm -f "$SCRIPT_DIR/nginx/host/keycloak.conf" \
          "$SCRIPT_DIR/nginx/host/gateway.conf" \
          "$SCRIPT_DIR/nginx/host/web.conf" \
          "$SCRIPT_DIR/nginx/host/pipeline.conf" \
          "$SCRIPT_DIR/nginx/host/superset.conf"

    local project
    project="$(basename "$SCRIPT_DIR")"
    if docker volume inspect "${project}_postgres_data" >/dev/null 2>&1; then
        warn "A Postgres volume from a previous run still exists."
        warn "Its database roles use the OLD secrets, which './dev.sh up' has now"
        warn "replaced — Keycloak will fail to authenticate against it."
        warn "Run './dev.sh reset' to wipe the volumes (destroys all data), or keep"
        warn "your existing .env instead of cleaning it."
    fi

    info "Cleaned. Run './dev.sh render' to regenerate configs, or './dev.sh up' to regenerate and start services."
}

# --- Host nginx --------------------------------------------------------------
# Root already has the privileges, so calling sudo would only fail where it is not installed.
as_root() {
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

# A vhost serving nothing but the ACME challenge. The rendered vhosts reference certificates that
# do not exist yet, so nginx would refuse to load them and certbot could never obtain the very
# certificates they need. This breaks that cycle for the port 80 phase.
bootstrap_vhost() {
    cat <<EOF
# Temporary, written by './dev.sh nginx' so certbot can answer the HTTP-01 challenge for $1.
# Replaced by the rendered vhost once the certificate exists.
server {
    listen 80;
    listen [::]:80;
    server_name $1;

    location /.well-known/acme-challenge/ {
        root $CERTBOT_WEBROOT;
    }

    location / {
        return 404;
    }
}
EOF
}

nginx_reload() {
    as_root nginx -t || error "nginx rejected the configuration. Nothing was reloaded."
    if command -v systemctl >/dev/null 2>&1; then
        as_root systemctl reload nginx || warn "Could not reload nginx via systemctl."
    else
        as_root nginx -s reload || warn "Could not signal nginx to reload."
    fi
}

enable_site() {
    local file="$1" base
    base="$(basename "$file")"
    as_root cp "$file" "$NGINX_SITES_AVAILABLE/$base"
    as_root ln -sfn "$NGINX_SITES_AVAILABLE/$base" "$NGINX_SITES_ENABLED/$base"
}

# Installs the rendered vhosts and obtains a certificate per subdomain, one certbot run each so a
# single failing name does not cost the others their certificate.
cmd_nginx() {
    command -v nginx >/dev/null 2>&1 || error "nginx is not installed on this host."
    require_env_file
    load_env
    render_templates

    local -a hosts=("${KEYCLOAK_HOST:-}" "${GATEWAY_HOST:-}" "${WEB_HOST:-}" \
                    "${PIPELINE_HOST:-}" "${SUPERSET_HOST:-}")
    local -a files=("keycloak.conf" "gateway.conf" "web.conf" \
                    "pipeline.conf" "superset.conf")
    local -a pending=()
    local i host file

    as_root mkdir -p "$CERTBOT_WEBROOT" "$NGINX_SITES_AVAILABLE" "$NGINX_SITES_ENABLED"

    for i in "${!hosts[@]}"; do
        host="${hosts[$i]}"
        [[ -n "$host" ]] || { warn "Skipping ${files[$i]}, its hostname is unset in .env."; continue; }
        if [[ -f "$LETSENCRYPT_LIVE/$host/fullchain.pem" ]]; then
            info "Certificate already present for $host."
        else
            pending+=("$i")
        fi
    done

    # Phase one. Only the hosts still needing a certificate get a bootstrap vhost, so hosts that
    # already have one keep serving from their real config throughout.
    if (( ${#pending[@]} )); then
        info "Installing temporary port 80 vhosts for the ACME challenge..."
        for i in "${pending[@]}"; do
            host="${hosts[$i]}"
            bootstrap_vhost "$host" | as_root tee "$NGINX_SITES_AVAILABLE/${files[$i]}" >/dev/null
            as_root ln -sfn "$NGINX_SITES_AVAILABLE/${files[$i]}" "$NGINX_SITES_ENABLED/${files[$i]}"
            echo "    $host -> ${files[$i]}"
        done
        nginx_reload

        command -v certbot >/dev/null 2>&1 || error "certbot is not installed on this host."
        local -a certbot_args=(certonly --webroot -w "$CERTBOT_WEBROOT")
        if [[ -n "${CERTBOT_EMAIL:-}" ]]; then
            certbot_args+=(--non-interactive --agree-tos -m "$CERTBOT_EMAIL")
        fi

        for i in "${pending[@]}"; do
            host="${hosts[$i]}"
            info "Requesting a certificate for $host..."
            # One run per name rather than a single multi-domain certificate, so one failing DNS
            # record does not deny the others.
            as_root certbot "${certbot_args[@]}" -d "$host" \
                || warn "certbot failed for $host. Its vhost stays on port 80 only."
        done
    fi

    # Phase two. Only install a rendered vhost where the certificate it references now exists,
    # otherwise nginx would refuse to load and take the working sites down with it.
    info "Installing the rendered vhosts..."
    for i in "${!hosts[@]}"; do
        host="${hosts[$i]}"; file="$SCRIPT_DIR/nginx/host/${files[$i]}"
        [[ -n "$host" && -f "$file" ]] || continue
        if [[ -f "$LETSENCRYPT_LIVE/$host/fullchain.pem" ]]; then
            enable_site "$file"
            echo "    $host -> ${files[$i]}"
        else
            warn "No certificate for $host, leaving its temporary port 80 vhost in place."
        fi
    done
    nginx_reload
    info "Host nginx updated."
}

# --- Usage -------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $0 <command> [options]

Commands:
  up [--pipes|--proxy|--full]
                              Render configs and start services
                              (no flag = postgres, keycloak, hapi-fhir,
                               fhir-gateway and the web portal)
                              --pipes  adds the analytics pipeline + Superset
                              --proxy  adds the same-origin nginx front
                              --seed     force-load the sample FHIR data
                              --no-seed  never load it
  down                        Stop all running services
  reset                       Stop services and wipe named volumes
  logs [service]              Tail logs (all services or one)
  render                      Render service config templates from .env
  seed                        Load sample FHIR data (locations, org, practitioners)
  clean                       Remove generated files (.env, application-*.yaml)
  nginx                       Install the host nginx vhosts and take a TLS
                              certificate per subdomain. Needs sudo, nginx
                              and certbot. Server deployments only.
  help                        Show this help

First-run setup:
  cp .env.example .env
  \${EDITOR:-vi} .env
  ./dev.sh up
EOF
}

# --- Main --------------------------------------------------------------------
main() {
    local command="${1:-help}"
    shift || true
    case "$command" in
        up)       cmd_up "$@" ;;
        down)     cmd_down ;;
        reset)    cmd_reset ;;
        logs)     cmd_logs "$@" ;;
        render)   cmd_render ;;
        seed)     cmd_seed ;;
        clean)    cmd_clean ;;
        nginx)    cmd_nginx ;;
        help|--help|-h) usage ;;
        *)        error "Unknown command: $command. Run '$0 help' for usage." ;;
    esac
}

main "$@"
