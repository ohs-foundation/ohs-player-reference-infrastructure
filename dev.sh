#!/bin/bash
set -euo pipefail

# =============================================================================
# dev.sh — local development lifecycle
#
# Subcommands:
#   up [--web|--pipes|--full]   Render configs and start services
#   down                        Stop all running services
#   reset                       Stop services and wipe named volumes
#   logs [service]              Tail logs (all services or one)
#   render                      Render service config templates from .env
#   clean                       Remove generated files (.env, application-*.yaml)
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

# --- Prerequisites -----------------------------------------------------------
check_prerequisites() {
    command -v docker    >/dev/null 2>&1 || error "Docker is not installed."
    docker compose version >/dev/null 2>&1 || error "Docker Compose plugin is not installed."
    command -v envsubst  >/dev/null 2>&1 || error "envsubst is not installed (install 'gettext-base')."
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
generate_secret() {
    openssl rand -hex 24
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
        while grep -q '=\[generated\]' "$ENV_FILE"; do
            sed -i "0,/=\[generated\]/{s/=\[generated\]/=$(generate_secret)/}" "$ENV_FILE"
        done
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
render() {
    local src="$SCRIPT_DIR/$1"
    local dst="$SCRIPT_DIR/$2"
    local vars="$3"
    [[ -f "$src" ]] || error "Template missing: $1"
    envsubst "$vars" < "$src" > "$dst"
    chmod 644 "$dst"
    info "  rendered $2"
}

render_templates() {
    info "Rendering configuration from *.example templates..."
    load_env

    render keycloak/ohs-player-realm.json.example \
           keycloak/ohs-player-realm.json \
           '${KEYCLOAK_REALM} ${OHS_PLAYER_KEYCLOAK_CLIENT_ID} ${OHS_PLAYER_KEYCLOAK_CLIENT_SECRET} ${OHS_PLAYER_DEFAULT_KEYCLOAK_USERNAME} ${OHS_PLAYER_APP_HOST} ${HAPI_FHIR_SERVER_KEYCLOAK_CLIENT_ID} ${HAPI_FHIR_SERVER_KEYCLOAK_CLIENT_SECRET} ${HAPI_FHIR_SERVER_DEFAULT_KEYCLOAK_USERNAME}'

    render hapi-fhir/application-no-auth.yaml.example \
           hapi-fhir/application-no-auth.yaml \
           '${HAPI_FHIR_DB_PASSWORD}'

    render hapi-fhir/application-auth.yaml.example \
           hapi-fhir/application-auth.yaml \
           '${HAPI_FHIR_DB_PASSWORD} ${HAPI_FHIR_SERVER_KEYCLOAK_CLIENT_SECRET}'
}

# --- Compose helpers ---------------------------------------------------------
compose() {
    (cd "$SCRIPT_DIR" && docker compose "$@")
}

parse_profiles() {
    PROFILE_ARGS=()
    for arg in "$@"; do
        case "$arg" in
            --web)   PROFILE_ARGS+=(--profile web)   ;;
            --pipes) PROFILE_ARGS+=(--profile pipes) ;;
            --full)  PROFILE_ARGS+=(--profile full)  ;;
            *)       error "Unknown flag: $arg (expected --web, --pipes, or --full)" ;;
        esac
    done
}

# --- Subcommands -------------------------------------------------------------
cmd_up() {
    parse_profiles "$@"
    check_prerequisites
    render_templates
    info "Pulling images..."
    compose "${PROFILE_ARGS[@]}" pull
    info "Starting stack..."
    compose "${PROFILE_ARGS[@]}" up -d
    info "Stack started. Container status:"
    compose "${PROFILE_ARGS[@]}" ps
}

cmd_down() {
    check_prerequisites
    info "Stopping stack..."
    compose --profile web --profile pipes --profile full down
}

cmd_reset() {
    check_prerequisites
    warn "This will stop all services and delete named volumes (postgres data will be lost)."
    info "Stopping stack and removing volumes..."
    compose --profile web --profile pipes --profile full down --volumes
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

cmd_clean() {
    info "Removing generated files..."
    rm -f "$SCRIPT_DIR/.env"
    rm -f "$SCRIPT_DIR/keycloak/ohs-player-realm.json"
    rm -f "$SCRIPT_DIR/hapi-fhir/application-no-auth.yaml"
    rm -f "$SCRIPT_DIR/hapi-fhir/application-auth.yaml"
    info "Cleaned. Run './dev.sh render' to regenerate configs, or './dev.sh up' to regenerate and start services."
}

# --- Usage -------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $0 <command> [options]

Commands:
  up [--web|--pipes|--full]   Render configs and start services
                                (no flag = core only)
  down                        Stop all running services
  reset                       Stop services and wipe named volumes
  logs [service]              Tail logs (all services or one)
  render                      Render service config templates from .env
  clean                       Remove generated files (.env, application-*.yaml)
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
        clean)    cmd_clean ;;
        help|--help|-h) usage ;;
        *)        error "Unknown command: $command. Run '$0 help' for usage." ;;
    esac
}

main "$@"
