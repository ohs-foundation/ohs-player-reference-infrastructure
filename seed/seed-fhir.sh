#!/usr/bin/env bash
# Loads sample data into the transactional FHIR server.
#
# Two phases, because only one of them can be static:
#
#   1. seed/fhir-seed.json — the reference data: an Organization and the location
#      hierarchy. Fixed logical ids written with PUT, so re-running upserts.
#   2. The people. Each realm user gets a Practitioner carrying its Keycloak id
#      under the identifier system the backend resolves callers by, a
#      PractitionerRole placing it at a facility, and a shared CareTeam.
#      Keycloak assigns those ids at realm-import time, so this half cannot be a
#      static file — and HAPI rejects a reference to a resource that does not
#      exist yet, so the CareTeam has to be written after its participants.
#
# Writes go straight to HAPI on the compose network rather than through the
# gateway: HAPI accepts them unauthenticated in the default mode, and seeding
# stays independent of the access control it is populating.
#
#   ./dev.sh seed     (or automatically on the first ./dev.sh up)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET="${FHIR_NET:-ohs-player-reference-infrastructure_fhir_net}"
FHIR="${FHIR_BASE_URL:-http://hapi-fhir:8080/fhir}"
KC="${KC_URL:-http://keycloak:8081}"
REALM="${KEYCLOAK_REALM:-ohs-player}"
CURL_IMG="${CURL_IMG:-curlimages/curl:latest}"

KC_ID_SYSTEM="http://ohs.dev/identifiers/keycloak-user-id"
ROLE_SYSTEM="http://terminology.hl7.org/CodeSystem/practitioner-role"
TEAM_SYSTEM="http://terminology.hl7.org/CodeSystem/care-team-roles"
ORG="seed-org-zamara-health"
FACILITY="seed-loc-facility-ndumberi-hc"
CARE_TEAM="seed-careteam-ndumberi"

# username | given | family | practitioner-role code
# The Practitioner id is the username, so one name identifies a person in both
# Keycloak and FHIR.
PEOPLE=(
  "admin-user|Admin|User|doctor"
  "practitioner-user|Practitioner|User|nurse"
)

curl_net() { docker run --rm -i --network "$NET" "$CURL_IMG" "$@"; }

# PUT a resource and report the status on one line.
put() {
    local type="$1" id="$2" label="$3"
    curl_net -s -o /dev/null -w "    ${label} -> HTTP %{http_code}\n" \
        -X PUT "$FHIR/$type/$id" \
        -H 'Content-Type: application/fhir+json' --data-binary @-
}

echo "==> reference data (organization and locations)"
curl_net -s -o /dev/null -w '    bundle -> HTTP %{http_code}\n' \
    -X POST "$FHIR" \
    -H 'Content-Type: application/fhir+json' -H 'Accept: application/fhir+json' \
    --data-binary @- < "$HERE/fhir-seed.json"

echo "==> people"
TOKEN="$(curl_net -s -X POST "$KC/realms/master/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=admin-cli \
    -d "username=${KEYCLOAK_ADMIN_USERNAME:-admin}" \
    -d "password=${KEYCLOAK_ADMIN_PASSWORD:?KEYCLOAK_ADMIN_PASSWORD is required}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))')"
[[ -n "$TOKEN" ]] || { echo "    could not obtain a Keycloak admin token" >&2; exit 1; }

members=()
for row in "${PEOPLE[@]}"; do
    IFS='|' read -r username given family role <<<"$row"

    uid="$(curl_net -s -H "Authorization: Bearer $TOKEN" \
            "$KC/admin/realms/$REALM/users?username=$username&exact=true" \
          | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["id"] if d else "")')"
    if [[ -z "$uid" ]]; then
        echo "    $username: not in the realm, skipped" >&2
        continue
    fi

    printf '{"resourceType":"Practitioner","id":"%s","active":true,
      "identifier":[{"system":"%s","value":"%s"}],
      "name":[{"use":"official","family":"%s","given":["%s"]}]}' \
      "$username" "$KC_ID_SYSTEM" "$uid" "$family" "$given" \
      | put Practitioner "$username" "Practitioner/$username"

    printf '{"resourceType":"PractitionerRole","id":"%s-role","active":true,
      "practitioner":{"reference":"Practitioner/%s"},
      "organization":{"reference":"Organization/%s"},
      "location":[{"reference":"Location/%s"}],
      "code":[{"coding":[{"system":"%s","code":"%s"}]}]}' \
      "$username" "$username" "$ORG" "$FACILITY" "$ROLE_SYSTEM" "$role" \
      | put PractitionerRole "$username-role" "PractitionerRole/$username-role"

    members+=("{\"role\":[{\"coding\":[{\"system\":\"$TEAM_SYSTEM\",\"code\":\"$role\"}]}],\"member\":{\"reference\":\"Practitioner/$username\"}}")
done

# Written last: HAPI rejects a reference to a resource that does not exist yet.
if [[ ${#members[@]} -gt 0 ]]; then
    printf '{"resourceType":"CareTeam","id":"%s","status":"active",
      "name":"Ndumberi Primary Care Team",
      "managingOrganization":[{"reference":"Organization/%s"}],
      "participant":[%s]}' \
      "$CARE_TEAM" "$ORG" "$(IFS=,; echo "${members[*]}")" \
      | put CareTeam "$CARE_TEAM" "CareTeam/$CARE_TEAM"
fi

echo
echo "Seeded. Location hierarchy root: Location/seed-loc-country"
