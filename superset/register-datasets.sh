#!/usr/bin/env bash
# Registers a Superset dataset for every table the analytics pipeline writes.
#
# The container's start-up command registers the database connection, but a
# connection alone is not chartable. Superset explores datasets, and those are
# rows in its own metadata rather than anything it discovers, so without this
# the UI shows a database with nothing under it.
#
# Uses `superset legacy-import-datasources` rather than the REST API. The API
# needs a session cookie and a CSRF token that has to be issued against that same
# session, which is awkward to hold across container invocations. The CLI runs
# inside the container with the app context already built, so it needs neither.
#
# Idempotent. The import upserts, so a table that already has a dataset is left
# as it is and this can run on every `up`.
set -euo pipefail

SUPERSET_CONTAINER="${SUPERSET_CONTAINER:-ohs-superset}"
ANALYTICS_CONTAINER="${ANALYTICS_CONTAINER:-ohs-postgres-analytics}"
ANALYTICS_DB="${SUPERSET_ANALYTICS_DB_NAME:-OHS Analytics}"

docker inspect "$SUPERSET_CONTAINER" >/dev/null 2>&1 || {
    echo "    $SUPERSET_CONTAINER is not running; skipped dataset registration" >&2; exit 0; }

# The pipeline decides which tables exist, so read them rather than hardcoding a
# list that drifts as ViewDefinitions are added.
tables="$(docker exec "$ANALYTICS_CONTAINER" psql -U postgres -d analytics -tAc \
    "select table_name from information_schema.tables where table_schema='public' order by 1;" \
    2>/dev/null)" || tables=""
tables="$(printf '%s\n' "$tables" | sed '/^[[:space:]]*$/d')"
[[ -n "$tables" ]] || { echo "    no analytics tables yet; run the pipeline first" >&2; exit 0; }

# sqlalchemy_uri is left as a placeholder and substituted inside the container,
# so the password is never written to a file on the host or shown in a process
# list here.
yaml="databases:
- database_name: ${ANALYTICS_DB}
  sqlalchemy_uri: __ANALYTICS_URI__
  tables:"
while IFS= read -r table; do
    yaml="$yaml
  - table_name: ${table}
    schema: public"
done <<<"$tables"

printf '%s\n' "$yaml" | docker exec -i "$SUPERSET_CONTAINER" sh -c 'cat > /tmp/ohs-datasets.yaml'
docker exec "$SUPERSET_CONTAINER" sh -c '
    sed -i "s|__ANALYTICS_URI__|$SUPERSET_ANALYTICS_URI|" /tmp/ohs-datasets.yaml
    superset legacy-import-datasources -p /tmp/ohs-datasets.yaml >/dev/null 2>&1
    rm -f /tmp/ohs-datasets.yaml' \
    || { echo "    Superset rejected the dataset import" >&2; exit 1; }

# The YAML import creates the dataset rows but no columns, so a chart built on
# one fails with "Columns missing in dataset". fetch_metadata reads the actual
# table and fills them in, which also repairs any dataset the dashboard bundle
# has just overwritten with a shorter list.
# Reported rather than silenced. A dataset with no columns still looks fine in a
# listing, so a failure here surfaces later as "Columns missing in dataset" on a
# chart, a long way from the cause.
synced="$(docker exec "$SUPERSET_CONTAINER" python -c "
from superset.app import create_app
with create_app().app_context():
    from superset import db
    from superset.connectors.sqla.models import SqlaTable
    ok = 0
    problems = []
    for dataset in db.session.query(SqlaTable).all():
        try:
            dataset.fetch_metadata()
            ok += 1
        except Exception as exc:
            problems.append(f'{dataset.table_name}: {type(exc).__name__}')
    db.session.commit()
    print(f'SYNCED={ok}')
    for line in problems[:3]:
        print(line)
" 2>/dev/null | tr -d '\r')" || synced=""

# Superset prints a configuration-load line before anything we ask for, so the
# count is tagged rather than taken from the first line.
count="$(printf '%s\n' "$synced" | sed -n 's/^SYNCED=//p' | head -1)"
if [[ ! "$count" =~ ^[0-9]+$ ]] || (( count == 0 )); then
    echo "    could not read columns from the analytics tables, so charts on these" >&2
    echo "    datasets will report missing columns. Check the connection credentials." >&2
    printf '%s\n' "$synced" | tail -n +2 | sed 's/^/      /' >&2
else
    echo "    synced columns for $count dataset(s)"
fi

echo "    registered $(printf '%s\n' "$tables" | wc -l | tr -d ' ') Superset dataset(s) against '${ANALYTICS_DB}'"
