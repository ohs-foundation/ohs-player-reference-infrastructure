#!/usr/bin/env bash
# Imports the predefined dashboard in superset/dashboard/.
#
# Superset's importer takes a ZIP holding one top-level directory of YAML, so the
# source is kept unzipped here to stay reviewable and diffable, and packed on the
# way in. The container has no zip or unzip, so the packing happens on this side.
#
# The bundle's database entry carries an inert placeholder rather than real
# credentials. The connection is created by the service's start-up command and
# matched here by uuid, and Superset keeps the existing password rather than
# taking the one in the file.
#
# Idempotent. The import overwrites by UUID, so re-running restores the shipped
# dashboard rather than adding a copy. Local edits to this dashboard are replaced
# on the next `up`, so copy it under a new name in the UI to keep changes.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPERSET_CONTAINER="${SUPERSET_CONTAINER:-ohs-superset}"
SRC="$HERE/dashboard"

[[ -d "$SRC" ]] || { echo "    no dashboard source at $SRC; skipped" >&2; exit 0; }
docker inspect "$SUPERSET_CONTAINER" >/dev/null 2>&1 || {
    echo "    $SUPERSET_CONTAINER is not running; skipped dashboard import" >&2; exit 0; }
command -v zip >/dev/null 2>&1 || {
    echo "    zip is not installed, so the dashboard bundle cannot be packed; skipped" >&2; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/ohs_dashboard"
cp -R "$SRC/." "$WORK/ohs_dashboard/"
( cd "$WORK" && zip -qr bundle.zip ohs_dashboard )

docker cp "$WORK/bundle.zip" "$SUPERSET_CONTAINER:/tmp/ohs-dashboard.zip" >/dev/null
docker exec "$SUPERSET_CONTAINER" sh -c '
    superset import-dashboards -p /tmp/ohs-dashboard.zip -u admin >/dev/null 2>&1
    status=$?
    rm -f /tmp/ohs-dashboard.zip
    exit $status' \
    || { echo "    Superset rejected the dashboard bundle" >&2; exit 1; }

echo "    imported the predefined Superset dashboard"
