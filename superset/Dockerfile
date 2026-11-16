# apache/superset ships no PostgreSQL driver, so out of the box it can reach
# neither the `superset` metadata database nor the `analytics` database the
# pipeline writes. Without one, a postgresql:// URI fails to import and Superset
# falls back to SQLite under superset_home without saying so.
FROM apache/superset:latest

USER root
# Installed with uv, into the image's virtualenv, because `python` resolves to
# /app/.venv/bin/python while a bare `pip` is the system one outside it. The
# obvious `pip install` lands in the wrong interpreter and changes nothing.
RUN uv pip install --python /app/.venv/bin/python --no-cache psycopg2-binary
USER superset
