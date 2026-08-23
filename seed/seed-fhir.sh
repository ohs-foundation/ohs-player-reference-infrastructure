#!/usr/bin/env bash
# Loads sample reference data into the transactional FHIR server.
#
# Two phases, because only one of them can be static:
#
#   1. seed/fhir-seed.json — a transaction Bundle of Locations, an Organization,
#      Practitioners and a CareTeam. Fixed logical ids, written with PUT, so
#      re-running upserts rather than duplicating.
#   2. The realm's human users are linked to Practitioner records. Their Keycloak
#      ids are assigned at realm-import time and so cannot be known in advance;
#      this phase looks them up and writes a Practitioner carrying the id under
#      the identifier system the backend resolves callers by.
#
# Writes go straight to HAPI on the compose network rather than through the
# gateway: HAPI accepts them unauthenticated in the default mode, and seeding
# stays independent of the access control it is populating.
#
#   ./dev.sh seed     (or ./dev.sh up --seed)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET="${FHIR_NET:-ohs-player-reference-infrastructure_fhir_net}"
FHIR="${FHIR_BASE_URL:-http://hapi-fhir:8080/fhir}"
KC="${KC_URL:-http://keycloak:8081}"
REALM="${KEYCLOAK_REALM:-ohs-player}"
CURL_IMG="${CURL_IMG:-curlimages/curl:latest}"
KC_ID_SYSTEM="http://ohs.dev/identifiers/keycloak-user-id"
ORG="seed-org-zamara-health"
ANCHOR_LOCATION="seed-loc-facility-ashford-east-a-hc"

# username | practitioner id | given | family | role code | role display
# The Practitioner id is the Keycloak username, so one name identifies the person
# in both systems and neither has to be looked up to find the other.
LINKED_USERS=(
  "admin-user|admin-user|Admin|User|doctor|Doctor"
  "practitioner-user|practitioner-user|Practitioner|User|nurse|Nurse"
)

curl_net() { docker run --rm -i --network "$NET" "$CURL_IMG" "$@"; }

echo "==> posting the sample bundle to $FHIR"
code=$(curl_net -s -o /tmp/seed-response.json -w '%{http_code}' \
  -X POST "$FHIR" \
  -H 'Content-Type: application/fhir+json' \
  -H 'Accept: application/fhir+json' \
  --data-binary @- < "$HERE/fhir-seed.json")
echo "    HTTP $code"
[[ "$code" =~ ^2 ]] || { echo "    seeding failed" >&2; exit 1; }

echo "==> linking realm users to Practitioner records"
admin_token() {
  curl_net -s -X POST "$KC/realms/master/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=admin-cli \
    -d "username=${KEYCLOAK_ADMIN_USERNAME:-admin}" \
    -d "password=${KEYCLOAK_ADMIN_PASSWORD:?KEYCLOAK_ADMIN_PASSWORD is required}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))'
}
TOKEN="$(admin_token)"
[[ -n "$TOKEN" ]] || { echo "    could not obtain a Keycloak admin token" >&2; exit 1; }

for row in "${LINKED_USERS[@]}"; do
  IFS='|' read -r username pid given family code_ display <<<"$row"
  uid="$(curl_net -s -H "Authorization: Bearer $TOKEN" \
        "$KC/admin/realms/$REALM/users?username=$username&exact=true" \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["id"] if d else "")')"
  if [[ -z "$uid" ]]; then
    echo "    $username: not present in the realm, skipped" >&2
    continue
  fi

  printf '%s' "{\"resourceType\":\"Practitioner\",\"id\":\"$pid\",\"active\":true,
    \"identifier\":[{\"system\":\"$KC_ID_SYSTEM\",\"value\":\"$uid\"}],
    \"name\":[{\"use\":\"official\",\"family\":\"$family\",\"given\":[\"$given\"]}]}" \
    | curl_net -s -o /dev/null -w "    $username -> Practitioner/$pid HTTP %{http_code}\n" \
        -X PUT "$FHIR/Practitioner/$pid" \
        -H 'Content-Type: application/fhir+json' --data-binary @-

  printf '%s' "{\"resourceType\":\"PractitionerRole\",\"id\":\"$pid-role\",\"active\":true,
    \"practitioner\":{\"reference\":\"Practitioner/$pid\"},
    \"organization\":{\"reference\":\"Organization/$ORG\"},
    \"location\":[{\"reference\":\"Location/$ANCHOR_LOCATION\"}],
    \"code\":[{\"coding\":[{\"system\":\"http://terminology.hl7.org/CodeSystem/practitioner-role\",
      \"code\":\"$code_\",\"display\":\"$display\"}]}]}" \
    | curl_net -s -o /dev/null -w "    $username -> PractitionerRole/$pid-role HTTP %{http_code}\n" \
        -X PUT "$FHIR/PractitionerRole/$pid-role" \
        -H 'Content-Type: application/fhir+json' --data-binary @-
done

echo
echo "Seeded. Location hierarchy root: Location/seed-loc-country"
