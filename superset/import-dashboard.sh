#!/usr/bin/env bash
# Imports the predefined dashboard in superset/dashboard/.
#
# Superset's importer takes a ZIP holding one top-level directory of YAML, so the
# source is kept unzipped here to stay reviewable and diffable, and packed on the
# way in. The container has no zip or unzip, so the packing happens on this side.
#
# The bundle deliberately ships no databases/ entry. Superset keeps a connection's
# password in its own encrypted column rather than in the URI text, and importing
# a database entry overwrites that column, so a placeholder in the file silently
# replaces the real credential and every dataset then fails to connect. The
# dataset's database_uuid is enough to link it to the connection the service's
# start-up command already created.
#
# Idempotent. The import overwrites by UUID, so re-running restores the shipped
# dashboard rather than adding a copy. Local edits to this dashboard are replaced
# on the next `up`, so copy it under a new name in the UI to keep changes.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPERSET_CONTAINER="${SUPERSET_CONTAINER:-ohs-superset}"
ANALYTICS_CONTAINER="${ANALYTICS_CONTAINER:-ohs-postgres-analytics}"
CHART_DATASET="${CHART_DATASET:-location_flat}"
ANALYTICS_DB="${SUPERSET_ANALYTICS_DB_NAME:-OHS Analytics}"
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

# Superset generates a UUID for the connection and for each dataset, so the ones
# this instance holds are never the ones a committed bundle was authored against.
# The importer resolves the chain by UUID and drops a chart it cannot resolve,
# without reporting anything, so every reference is substituted here.
meta() {
    docker exec "$ANALYTICS_CONTAINER" psql -U postgres -d superset -tAc "$1" 2>/dev/null | tr -d '[:space:]'
}
database_uuid="$(meta "select uuid from dbs where database_name='${ANALYTICS_DB}';")" || database_uuid=""
dataset_uuid="$(meta "select uuid from tables where table_name='${CHART_DATASET}';")" || dataset_uuid=""
if [[ -z "$database_uuid" || -z "$dataset_uuid" ]]; then
    echo "    the '${ANALYTICS_DB}' connection or the '${CHART_DATASET}' dataset is not" >&2
    echo "    registered yet, so the dashboard has nothing to chart. Run" >&2
    echo "    superset/register-datasets.sh first." >&2
    exit 0
fi

# Read from the container rather than .env so the value matches what Superset is
# actually using, and never appears in this script's own argument list.
analytics_uri="$(docker exec "$SUPERSET_CONTAINER" sh -c 'printf %s "$SUPERSET_ANALYTICS_URI"')" || analytics_uri=""
[[ -n "$analytics_uri" ]] || { echo "    SUPERSET_ANALYTICS_URI is unset in the container; skipped" >&2; exit 0; }

python3 - "$WORK/ohs_dashboard" "$database_uuid" "$dataset_uuid" "$analytics_uri" <<'SUBST'
import pathlib, sys
root, db_uuid, ds_uuid, uri = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
for path in pathlib.Path(root).rglob("*.yaml"):
    text = path.read_text()
    swapped = (text.replace("__DATABASE_UUID__", db_uuid)
                   .replace("__LOCATION_FLAT_UUID__", ds_uuid)
                   .replace("__ANALYTICS_URI__", uri))
    if swapped != text:
        path.write_text(swapped)
SUBST

( cd "$WORK" && zip -qr bundle.zip ohs_dashboard )

docker cp "$WORK/bundle.zip" "$SUPERSET_CONTAINER:/tmp/ohs-dashboard.zip" >/dev/null
docker exec "$SUPERSET_CONTAINER" sh -c '
    superset import-dashboards -p /tmp/ohs-dashboard.zip -u admin >/dev/null 2>&1
    status=$?
    rm -f /tmp/ohs-dashboard.zip
    exit $status' \
    || { echo "    Superset rejected the dashboard bundle" >&2; exit 1; }

echo "    imported the predefined Superset dashboard"
