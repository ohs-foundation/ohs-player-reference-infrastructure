# syntax=docker/dockerfile:1

###############################################################################
# Stage 1: build fhir-gateway (the host application)
###############################################################################
FROM maven:3.9-eclipse-temurin-21 AS gateway-build
WORKDIR /src

# Clone + build the gateway. Pin to a tag/branch via GATEWAY_REF if you want.
ARG GATEWAY_REF=main
RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch "${GATEWAY_REF}" \
    https://github.com/ohs-foundation/fhir-gateway.git .

# Cache Maven deps across builds, then package
RUN --mount=type=cache,target=/root/.m2 \
    mvn -B package -Dspotless.apply.skip=true -DskipTests

# Normalize the exec jar to a stable name (version may change between releases)
RUN cp exec/target/fhir-gateway-exec.jar /fhir-gateway.jar

###############################################################################
# Stage 2: build the ohs-player plugin (access-checker / custom endpoints)
###############################################################################
FROM maven:3.9-eclipse-temurin-21 AS plugin-build
WORKDIR /src

ARG PLUGIN_REF=main
RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch "${PLUGIN_REF}" \
    https://github.com/ohs-foundation/ohs-player-reference-backend.git .

RUN --mount=type=cache,target=/root/.m2 \
    mvn -B clean package -DskipTests

RUN cp target/ohs-player-backend-extensions-*.jar /ohs-player-backend-extensions.jar

###############################################################################
# Stage 3: runtime
###############################################################################
FROM eclipse-temurin:21-jre AS runtime
WORKDIR /app

COPY --from=gateway-build /fhir-gateway.jar /app/fhir-gateway.jar
COPY --from=plugin-build  /ohs-player-backend-extensions.jar /app/plugins/ohs-player-backend-extensions.jar
# Allow-list / config files the gateway reads via ALLOWED_QUERIES_FILE et al.
# (resolved relative to WORKDIR /app). They ship in the gateway repo's resources/.
COPY --from=gateway-build /src/resources /app/resources

# Gateway listens on 8080 inside the container by default
EXPOSE 8080

# loader.path makes Spring Boot pick up the plugin's access-checkers / endpoints
ENTRYPOINT ["java", "-Dloader.path=/app/plugins", \
    "-jar", "/app/fhir-gateway.jar", \
    "--server.port=8080"]