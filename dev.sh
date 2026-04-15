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
require_env_file() {
    if [[ ! -f "$ENV_FILE" ]]; then
        cat >&2 <<EOF
${RED}[ERROR]${NC} .env not found at $ENV_FILE

Create it from the example and fill in real values before continuing:

    cp .env.example .env
    \${EDITOR:-vi} .env

Generate strong random secrets with:

    openssl rand -hex 24

EOF
        exit 1
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
    (
        umask 077
        envsubst "$vars" < "$src" > "$dst"
    )
    info "  rendered $2"
}

render_templates() {
    info "Rendering configuration from *.example templates..."
    load_env

    render postgres/postgres.env.example \
           postgres/postgres.env \
           '${POSTGRES_ADMIN_PASSWORD} ${KEYCLOAK_DB_PASSWORD} ${HAPI_FHIR_DB_PASSWORD}'

    render keycloak/keycloak.env.example \
           keycloak/keycloak.env \
           '${KEYCLOAK_ADMIN_PASSWORD} ${KEYCLOAK_DB_PASSWORD}'

    render hapi-fhir/application-no-auth.yaml.example \
           hapi-fhir/application-no-auth.yaml \
           '${HAPI_FHIR_DB_PASSWORD}'

    render hapi-fhir/application-auth.yaml.example \
           hapi-fhir/application-auth.yaml \
           '${HAPI_FHIR_DB_PASSWORD} ${HAPI_FHIR_KEYCLOAK_CLIENT_SECRET}'
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
        help|--help|-h) usage ;;
        *)        error "Unknown command: $command. Run '$0 help' for usage." ;;
    esac
}

main "$@"
