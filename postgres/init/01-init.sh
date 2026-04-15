#!/bin/bash
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    -- Keycloak
    CREATE USER keycloak WITH PASSWORD '${KEYCLOAK_DB_PASSWORD}';
    CREATE DATABASE keycloak;
    GRANT ALL PRIVILEGES ON DATABASE keycloak TO keycloak;

    -- HAPI FHIR
    CREATE USER hapi_fhir WITH PASSWORD '${HAPI_FHIR_DB_PASSWORD}';
    CREATE DATABASE hapi_fhir;
    GRANT ALL PRIVILEGES ON DATABASE hapi_fhir TO hapi_fhir;
EOSQL
