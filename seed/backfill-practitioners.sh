#!/usr/bin/env bash
# Creates a FHIR Practitioner for every realm user that lacks one.
#
# The Portal's user list is FHIR-driven: GET /api/users returns a Bundle of
# Practitioner resources and never queries Keycloak. A user created straight in
# the Keycloak admin console can therefore sign in but never appears in the list,
# because creating one through the Portal is what normally writes both halves.
# This backfills the missing half.
#
# The resource matches what the backend's PractitionerService.buildPractitioner
# would have written, so a backfilled record is indistinguishable from one the
# Portal created: active from the user's enabled flag, the Keycloak id under the
# identifier system the backend resolves callers by, a name, and an email
# telecom. No PractitionerRole — the Portal does not create one either.
#
# Idempotent. The logical id is the Keycloak user id, so re-running updates in
# place rather than duplicating, and users that already have a Practitioner are
# skipped whatever their logical id.
#
# Reports what it would do and writes nothing unless given --apply.
#
#   ./seed/backfill-practitioners.sh              # dry run
#   ./seed/backfill-practitioners.sh --apply
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET="${FHIR_NET:-ohs-player-reference-infrastructure_fhir_net}"
FHIR="${FHIR_BASE_URL:-http://hapi-fhir:8080/fhir}"
KC="${KC_URL:-http://keycloak:8081}"
REALM="${KEYCLOAK_REALM:-ohs-player}"
CURL_IMG="${CURL_IMG:-curlimages/curl:latest}"
KC_ID_SYSTEM="http://ohs.dev/identifiers/keycloak-user-id"

APPLY=0
for arg in "$@"; do
    case "$arg" in
        --apply)   APPLY=1 ;;
        --dry-run) APPLY=0 ;;
        *) echo "Unknown flag: $arg (expected --apply or --dry-run)" >&2; exit 1 ;;
    esac
done

curl_net() { docker run --rm -i --network "$NET" "$CURL_IMG" "$@"; }

TOKEN="$(curl_net -s -X POST "$KC/realms/master/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=admin-cli \
    -d "username=${KEYCLOAK_ADMIN_USERNAME:-admin}" \
    -d "password=${KEYCLOAK_ADMIN_PASSWORD:?KEYCLOAK_ADMIN_PASSWORD is required}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))')"
[[ -n "$TOKEN" ]] || { echo "Could not obtain a Keycloak admin token." >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Keycloak caps /users at 100 per call whatever you ask for, so page until a
# short page arrives. Pages land as separate files and are merged once, rather
# than concatenated into JSON by hand where one failed fetch corrupts the lot.
first=0
page_no=0
while :; do
    page="$WORK/users-$page_no.json"
    curl_net -s -H "Authorization: Bearer $TOKEN" \
        "$KC/admin/realms/$REALM/users?first=$first&max=100" > "$page"
    n="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit("unreadable")
if not isinstance(d, list):
    sys.exit(str(d.get("error", "unexpected response"))[:120])
print(len(d))' "$page" 2>&1)" \
        || { echo "Failed to list realm users: $n" >&2; exit 1; }
    [[ "$n" -eq 0 ]] && break
    page_no=$((page_no + 1))
    [[ "$n" -lt 100 ]] && break
    first=$((first + 100))
done

# Every Keycloak id already carried by a Practitioner. Paged with explicit
# _offset rather than by following Bundle.link[next], which is a URL the server
# reports about itself and need not match the base we dialled.
offset=0
bundle_no=0
while :; do
    bundle="$WORK/prac-$bundle_no.json"
    curl_net -s -H 'Accept: application/fhir+json' \
        "$FHIR/Practitioner?_count=200&_offset=$offset" > "$bundle"
    n="$(python3 -c '
import json, sys
try:
    b = json.load(open(sys.argv[1]))
except Exception:
    sys.exit("unreadable")
if b.get("resourceType") == "OperationOutcome":
    sys.exit("; ".join(i.get("diagnostics", "?") for i in b.get("issue", []))[:120])
print(len(b.get("entry") or []))' "$bundle" 2>&1)" \
        || { echo "Failed to list Practitioners: $n" >&2; exit 1; }
    [[ "$n" -eq 0 ]] && break
    bundle_no=$((bundle_no + 1))
    [[ "$n" -lt 200 ]] && break
    offset=$((offset + 200))
done

linked="$(python3 -c "
import json, glob, sys
out = set()
for f in glob.glob(sys.argv[1] + '/prac-*.json'):
    b = json.load(open(f))
    for e in b.get('entry') or []:
        for i in e.get('resource', {}).get('identifier') or []:
            if i.get('system') == '$KC_ID_SYSTEM' and i.get('value'):
                out.add(i['value'])
print(' '.join(sorted(out)))
" "$WORK")"

users_json="$(python3 -c "
import json, glob, sys
users = []
for f in sorted(glob.glob(sys.argv[1] + '/users-*.json')):
    users.extend(json.load(open(f)))
print(json.dumps(users))
" "$WORK")"

# Decide the work: skip service accounts and anyone already linked.
plan="$(printf '%s' "$users_json" | python3 -c "
import json, sys
linked = set(filter(None, '''$linked'''.split()))
out = []
for u in json.load(sys.stdin):
    uid = u.get('id')
    name = u.get('username','')
    if not uid or name.startswith('service-account-') or u.get('serviceAccountClientId'):
        continue
    if uid in linked:
        continue
    first = (u.get('firstName') or '').strip()
    last  = (u.get('lastName')  or '').strip()
    if not first and not last:
        last = name                     # nothing better to show in a list
    out.append({'id': uid, 'username': name, 'given': first, 'family': last,
                'email': u.get('email') or '', 'active': bool(u.get('enabled', True))})
print(json.dumps(out))
")"

count="$(printf '%s' "$plan" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
if [[ "$count" == "0" ]]; then
    echo "Every realm user already has a Practitioner. Nothing to do."
    exit 0
fi

echo "Users without a Practitioner: $count"
printf '%s' "$plan" | python3 -c "
import json,sys
for u in json.load(sys.stdin):
    who = ' '.join(x for x in (u['given'], u['family']) if x)
    print(f\"    {u['username']:28} {who}  <{u['email'] or 'no email'}>\")
"

if [[ "$APPLY" -eq 0 ]]; then
    echo
    echo "Dry run. Re-run with --apply to write these."
    exit 0
fi

echo
FAILURES=0
CREATED=0
while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    uid="$(printf '%s' "$row"  | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
    uname="$(printf '%s' "$row"| python3 -c 'import json,sys; print(json.load(sys.stdin)["username"])')"
    body="$(printf '%s' "$row" | python3 -c "
import json,sys
u=json.load(sys.stdin)
name={'use':'official'}
if u['family']: name['family']=u['family']
# FHIR forbids empty arrays, so given is omitted rather than [] when unknown.
if u['given']:  name['given']=[u['given']]
p={'resourceType':'Practitioner','id':u['id'],'active':u['active'],
   'identifier':[{'system':'$KC_ID_SYSTEM','value':u['id']}],
   'name':[name]}
if u['email']:
    p['telecom']=[{'system':'email','use':'work','value':u['email']}]
print(json.dumps(p))
")"
    code="$(curl_net -s -o /dev/null -w '%{http_code}' \
        -X PUT "$FHIR/Practitioner/$uid" \
        -H 'Content-Type: application/fhir+json' --data-binary @- <<<"$body")"
    if [[ "$code" =~ ^2 ]]; then
        CREATED=$((CREATED + 1))
    else
        echo "    failed: $uname -> HTTP $code" >&2
        FAILURES=$((FAILURES + 1))
    fi
done < <(printf '%s' "$plan" | python3 -c 'import json,sys
for u in json.load(sys.stdin): print(json.dumps(u))')

echo "Practitioners written: $CREATED"
[[ "$FAILURES" -eq 0 ]] || { echo "Failures: $FAILURES" >&2; exit 1; }
