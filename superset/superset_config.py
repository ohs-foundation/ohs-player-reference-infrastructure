"""Superset configuration for the OHS Player analytics profile.

Superset reads its settings from a config module, not from the container
environment. Setting SQLALCHEMY_DATABASE_URI as a plain variable on the service
does nothing, which is why the metadata store silently fell back to SQLite under
superset_home while the `superset` database created by postgres-init.sql stayed
empty. Mounting this file and pointing SUPERSET_CONFIG_PATH at it is what makes
the documented setting take effect.
"""

import os

# Where Superset keeps its own dashboards, charts and users. Distinct from the
# `analytics` database the pipeline writes, which is registered as a data source
# by the service's start-up command.
SQLALCHEMY_DATABASE_URI = os.environ["SQLALCHEMY_DATABASE_URI"]

# Generated per install into .env. Superset refuses to start with the shipped
# default once it is anything other than a throwaway.
SECRET_KEY = os.environ["SUPERSET_SECRET_KEY"]

# Behind the host nginx, Superset builds links from the forwarded headers rather
# than from the address it is bound to. Without this it issues http:// redirects
# from behind a TLS terminator. Off by default because trusting X-Forwarded-*
# only makes sense when something in front is setting them.
ENABLE_PROXY_FIX = os.environ.get("SUPERSET_ENABLE_PROXY_FIX", "false").lower() == "true"
