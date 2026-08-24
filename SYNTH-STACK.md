# The synth stack

The stack used to run a second HAPI FHIR server and a second Postgres, behind a
`synth` profile, holding synthetic data. The analytics pipeline read from that
server rather than from the transactional one.

Both services were removed. The pipeline now reads from `hapi-fhir`, the
transactional server this stack already runs, and Superset keeps its own
`postgres-analytics` instance as before.

This file records what was removed and what it takes to put it back.

## Why it was removed

The synth pair existed so generated test data never touched real records, and so
the analytics dashboards had something to chart before anyone had captured real
activity. The first run now loads sample data — an organisation, a six-level
location hierarchy and a practitioner per user — so the dashboards have records
to work with without a separate server, and the stack is two services and one
volume lighter.

## What changed with it

| Where | Was | Now |
|---|---|---|
| `PIPELINE_FHIR_SOURCE` | `http://hapi-synth:8080/fhir` | `http://hapi-fhir:8080/fhir` |
| `data-pipes/config/application.yaml` | `fhirServerUrl: hapi-synth` | `fhirServerUrl: hapi-fhir` |
| `pipeline-controller` `depends_on` | `hapi-synth` | `hapi-fhir` |
| `./dev.sh up` flags | `--synth`, `--pipes`, `--proxy`, `--full` | `--pipes`, `--proxy`, `--full` |
| Ports | `8085` synth HAPI, `5435` synth Postgres | gone |
| Volumes | `postgres_synth_data` | gone |

## What this arrangement costs

Two things follow from pointing the pipeline at the transactional server, and
both are worth knowing before deciding whether to restore the synth pair.

**The pipeline reads anonymously.** It connects to `hapi-fhir:8080` directly,
not through the gateway, so nothing supplies it a token. That works against the
default `HAPI_CONFIG=application-no-auth.yaml`. Switch to
`application-auth.yaml` and the FHIR server rejects the pipeline's requests.
The synth server was always open, so this could not arise before.

**Pipeline reads hit the transactional server.** A full pipeline run walks every
resource in the twelve configured types. On a development machine that is
immaterial; on anything shared it competes with the Portal and the Client App
for the same server.

## Restoring it

Add the two services back to `docker-compose.yaml`, immediately before the
`postgres-analytics` block.

```yaml
  # ---------------------------------------------------------------------------
  # synth stack (profile: synth / pipes / full)
  #
  # Isolated HAPI FHIR + PostgreSQL for synthetic/test data generation.
  # Kept separate from the transactional instance (ohs-hapi-fhir) so test
  # data never touches production records.
  # Also included in the pipes profile so the pipeline has a FHIR source.
  #
  # FHIR endpoint:  http://localhost:${HAPI_SYNTH_PORT:-8085}/fhir
  # Postgres:       localhost:${POSTGRES_SYNTH_PORT:-5435}
  #
  # Load synthetic data:
  #   python ohs-player-analytics/test-data/generate.py \
  #     --fhir-url http://localhost:${HAPI_SYNTH_PORT:-8085}/fhir
  # ---------------------------------------------------------------------------
  postgres-synth:
    profiles: ["synth", "pipes", "full"]
    image: postgres:18
    container_name: ohs-postgres-synth
    restart: unless-stopped
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${POSTGRES_ADMIN_PASSWORD}
      POSTGRES_DB: hapi_fhir
    volumes:
      - postgres_synth_data:/var/lib/postgresql
    ports:
      - "127.0.0.1:${POSTGRES_SYNTH_PORT:-5435}:5432"
    networks: [fhir_net]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s

  hapi-synth:
    profiles: ["synth", "pipes", "full"]
    image: hapiproject/hapi:v8.8.0-1
    container_name: ohs-hapi-synth
    restart: unless-stopped
    depends_on:
      postgres-synth:
        condition: service_healthy
    ports:
      - "${HAPI_SYNTH_PORT:-8085}:8080"
    environment:
      - hapi.fhir.mdm_enabled=false
      - hapi.fhir.bulk_export_enabled=true
      - spring.datasource.url=jdbc:postgresql://postgres-synth:5432/hapi_fhir
      - spring.datasource.username=postgres
      - spring.datasource.password=${POSTGRES_ADMIN_PASSWORD}
      - spring.datasource.driverClassName=org.postgresql.Driver
      - spring.jpa.properties.hibernate.dialect=ca.uhn.fhir.jpa.model.dialect.HapiFhirPostgresDialect
    volumes:
      - ./hapi-fhir/health/Healthcheck.class:/healthcheck/Healthcheck.class:ro
    networks: [fhir_net]
    healthcheck:
      test: ["CMD", "java", "-cp", "/healthcheck", "Healthcheck"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 180s
```

Re-add the volume under the top-level `volumes:` key.

```yaml
  postgres_synth_data:
```

Re-add the ports to `.env.example` and to your own `.env`.

```sh
# --- Synth stack ports (profile: --synth / --pipes) --------------------------
# Isolated HAPI FHIR + PostgreSQL for synthetic/test data.
POSTGRES_SYNTH_PORT=5435
HAPI_SYNTH_PORT=8085
```

Point the pipeline back at it, in `.env` and in
`data-pipes/config/application.yaml`.

```sh
PIPELINE_FHIR_SOURCE=http://hapi-synth:8080/fhir
```

Change `pipeline-controller`'s `depends_on` from `hapi-fhir` back to
`hapi-synth`, so the pipeline waits for the server it actually reads.

Finally, restore the `--synth` flag in `dev.sh`. It appears in four places: the
header comment, the flag `case` in the argument parser, the error message
listing valid flags, and the usage text. `cmd_down` and `cmd_reset` each need
`--profile synth` back in their profile lists, or synth containers survive a
`./dev.sh down`.

```bash
--synth) PROFILE_ARGS+=(--profile synth) ;;
```

## If you already had it running

Removing the services from the compose file does not remove containers that are
already up. They become orphans, and `./dev.sh down` will not stop them because
it no longer names the profile. Clear them by hand.

```bash
docker rm -f ohs-hapi-synth ohs-postgres-synth
docker volume rm ohs-player-reference-infrastructure_postgres_synth_data
```

The volume name is prefixed with the compose project name, which defaults to the
directory name. `docker volume ls | grep synth` confirms the actual name.
