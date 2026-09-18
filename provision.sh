#!/usr/bin/env bash
#
# Provision Entra users into Twilio Flex.
#
# Sources users from either an Entra group or an Entra Enterprise Application
# (same TRIGGER_MODE mechanic as deprovision.sh). For each user not already in
# Flex, calls POST /v4/Instances/{InstanceSid}/Users/Provision.
#
# Idempotent: performs GET /Users?Username=<email> first and skips users that
# already exist. No state file.
#
# Required env vars: TENANT_ID CLIENT_ID CLIENT_SECRET
#                    TWILIO_API_KEY TWILIO_API_SECRET FLEX_INSTANCE_SID
# Group mode also requires: ENTRA_GROUP_ID
# App mode also requires:   ENTRA_ENTERPRISE_APP_SID
#
# Optional env vars:
#   TRIGGER_MODE       group (default) | app
#   ENTRA_EMAIL_FIELD  Entra field(s) used as Flex username / email
#                      (default: mail,userPrincipalName)
#   FLEX_ROLES         Comma-separated roles for provisioned users
#                      (default: agent). Valid: agent, supervisor, admin
#   FLEX_WORKER_JSON   JSON string for the "worker" body field
#                      (default: {}). e.g. '{"attributes":{"channel.voice.capacity":10}}'
#   DEBUG=1            Verbose per-user Graph dump (helps pick ENTRA_EMAIL_FIELD)
#
# Graph API permissions (Application, admin-consented):
#   Group mode:  GroupMember.Read.All + User.Read.All
#   App mode:    Application.Read.All + User.Read.All
# Requires: curl, jq.

set -euo pipefail

command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "jq is required (brew install jq / apt install jq)" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-load .env sitting next to the script (if present).
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi

: "${TENANT_ID:?missing}"
: "${CLIENT_ID:?missing}"
: "${CLIENT_SECRET:?missing}"
: "${TWILIO_API_KEY:?missing}"
: "${TWILIO_API_SECRET:?missing}"
: "${FLEX_INSTANCE_SID:?missing}"

# Trigger mode selection (parallels deprovision.sh).
trigger_mode_raw="${TRIGGER_MODE:-group}"
case "$trigger_mode_raw" in
  group|Group|GROUP)
    trigger_mode="group"
    : "${ENTRA_GROUP_ID:?required when TRIGGER_MODE=group}"
    ;;
  app|App|APP)
    trigger_mode="app"
    : "${ENTRA_ENTERPRISE_APP_SID:?required when TRIGGER_MODE=app}"
    ;;
  *)
    echo "Invalid TRIGGER_MODE '$trigger_mode_raw' — must be 'group' or 'app'" >&2
    exit 1
    ;;
esac

FLEX_BASE="https://flex-api.twilio.com/v4/Instances/$FLEX_INSTANCE_SID"

# Entra field priority list for Flex username.
ENTRA_EMAIL_FIELD="${ENTRA_EMAIL_FIELD:-mail,userPrincipalName}"

# Build $select clause covering displayName + every configured field.
select_fields="id,displayName"
IFS=',' read -ra _ENTRA_FIELDS <<< "$ENTRA_EMAIL_FIELD"
for _f in "${_ENTRA_FIELDS[@]}"; do
  _f="${_f// /}"
  [ -z "$_f" ] && continue
  case ",$select_fields," in
    *",$_f,"*) ;;
    *) select_fields="$select_fields,$_f" ;;
  esac
done

# Provision defaults.
FLEX_ROLES="${FLEX_ROLES:-agent}"
FLEX_WORKER_JSON="${FLEX_WORKER_JSON:-}"
[ -z "$FLEX_WORKER_JSON" ] && FLEX_WORKER_JSON='{}'

if ! echo "$FLEX_WORKER_JSON" | jq -e . >/dev/null 2>&1; then
  echo "FLEX_WORKER_JSON is not valid JSON: $FLEX_WORKER_JSON" >&2
  exit 1
fi
FLEX_ROLES_JSON=$(echo "$FLEX_ROLES" | jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$"; ""))')

MEMBERS_JSON=$(mktemp)
ASSIGNMENT_IDS=$(mktemp)
trap 'rm -f "$MEMBERS_JSON" "$ASSIGNMENT_IDS"' EXIT

# 1. Graph token (client credentials).
token_resp=$(curl -sS -w $'\n%{http_code}' \
  -X POST "https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$CLIENT_ID" \
  -d "client_secret=$CLIENT_SECRET" \
  -d "scope=https://graph.microsoft.com/.default" \
  -d "grant_type=client_credentials")
token_status=$(echo "$token_resp" | tail -n1)
token_body=$(echo "$token_resp"   | sed '$d')
if [ "$token_status" != "200" ]; then
  echo "Graph token request failed: HTTP $token_status" >&2
  echo "$token_body" >&2
  exit 1
fi
TOKEN=$(echo "$token_body" | jq -r .access_token)

# 2. Fetch users (mode-specific).
echo '[]' > "$MEMBERS_JSON"

if [ -n "${DEBUG:-}" ]; then
  effective_select="id,displayName,mail,userPrincipalName,otherMails,proxyAddresses,onPremisesUserPrincipalName,onPremisesSamAccountName,mailNickname,employeeId,userType"
else
  effective_select="$select_fields"
fi

if [ "$trigger_mode" = "group" ]; then
  url="https://graph.microsoft.com/v1.0/groups/$ENTRA_GROUP_ID/members/microsoft.graph.user?\$select=$effective_select"
  while [ -n "$url" ]; do
    page_resp=$(curl -sS -w $'\n%{http_code}' -H "Authorization: Bearer $TOKEN" "$url")
    page_status=$(echo "$page_resp" | tail -n1)
    page=$(echo "$page_resp"        | sed '$d')
    if [ "$page_status" != "200" ]; then
      echo "Graph group-members request failed: HTTP $page_status" >&2
      echo "URL: $url" >&2
      echo "$page" >&2
      [ "$page_status" = "403" ] && echo "Hint: app registration likely lacks GroupMember.Read.All (Application) with admin consent granted." >&2
      exit 1
    fi
    jq -s '.[0] + .[1].value' "$MEMBERS_JSON" <(echo "$page") > "$MEMBERS_JSON.tmp"
    mv "$MEMBERS_JSON.tmp" "$MEMBERS_JSON"
    url=$(echo "$page" | jq -r '."@odata.nextLink" // empty')
  done
else
  : > "$ASSIGNMENT_IDS"
  url="https://graph.microsoft.com/v1.0/servicePrincipals/$ENTRA_ENTERPRISE_APP_SID/appRoleAssignedTo?\$select=principalId,principalType,principalDisplayName"
  while [ -n "$url" ]; do
    page_resp=$(curl -sS -w $'\n%{http_code}' -H "Authorization: Bearer $TOKEN" "$url")
    page_status=$(echo "$page_resp" | tail -n1)
    page=$(echo "$page_resp"        | sed '$d')
    if [ "$page_status" != "200" ]; then
      echo "Graph appRoleAssignedTo request failed: HTTP $page_status" >&2
      echo "URL: $url" >&2
      echo "$page" >&2
      case "$page_status" in
        403)
          echo "Hint: app registration likely lacks Application.Read.All (Application) with admin consent granted." >&2
          ;;
        404)
          echo "" >&2
          echo "Hint: ENTRA_ENTERPRISE_APP_SID must be the servicePrincipal Object ID from" >&2
          echo "  Entra portal → Enterprise applications → your app → Properties → Object ID." >&2
          echo "  It is NOT the Application (client) ID and NOT the Object ID from App registrations." >&2
          echo "  Attempting to resolve '$ENTRA_ENTERPRISE_APP_SID' as an appId..." >&2
          resolve=$(curl -sS -H "Authorization: Bearer $TOKEN" \
            "https://graph.microsoft.com/v1.0/servicePrincipals?\$filter=appId%20eq%20'$ENTRA_ENTERPRISE_APP_SID'&\$select=id,displayName,appId")
          sp_id=$(echo "$resolve" | jq -r '.value[0].id // empty')
          sp_name=$(echo "$resolve" | jq -r '.value[0].displayName // empty')
          if [ -n "$sp_id" ]; then
            echo "  Found a servicePrincipal whose appId matches:" >&2
            echo "    displayName: $sp_name" >&2
            echo "    Object ID:   $sp_id" >&2
            echo "  → Update .env: ENTRA_ENTERPRISE_APP_SID=$sp_id" >&2
          else
            echo "  No servicePrincipal has appId == '$ENTRA_ENTERPRISE_APP_SID' either." >&2
            echo "  Double-check the Object ID from the Enterprise applications blade." >&2
          fi
          ;;
      esac
      exit 1
    fi
    echo "$page" | jq -r '.value[] | select(.principalType == "User") | .principalId' >> "$ASSIGNMENT_IDS"
    url=$(echo "$page" | jq -r '."@odata.nextLink" // empty')
  done
  while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    user_resp=$(curl -sS -w $'\n%{http_code}' -H "Authorization: Bearer $TOKEN" \
      "https://graph.microsoft.com/v1.0/users/$pid?\$select=$effective_select")
    user_status=$(echo "$user_resp" | tail -n1)
    user_body=$(echo "$user_resp"   | sed '$d')
    if [ "$user_status" = "200" ]; then
      jq -s '.[0] + [.[1]]' "$MEMBERS_JSON" <(echo "$user_body") > "$MEMBERS_JSON.tmp"
      mv "$MEMBERS_JSON.tmp" "$MEMBERS_JSON"
    else
      echo "Warning: /users/$pid returned HTTP $user_status; skipping." >&2
    fi
  done < "$ASSIGNMENT_IDS"
fi

# 3. DEBUG dump — helps you pick ENTRA_EMAIL_FIELD.
if [ -n "${DEBUG:-}" ]; then
  count=$(jq 'length' "$MEMBERS_JSON")
  echo "=== DEBUG: $count user(s) fetched ==="
  for i in $(seq 0 $((count - 1))); do
    member=$(jq --argjson i "$i" '.[$i]' "$MEMBERS_JSON")
    name=$(echo "$member" | jq -r '.displayName // .id')
    mid=$(echo "$member"  | jq -r '.id')
    echo ""
    echo "----- $name — id: $mid -----"
    echo "Fields containing '@' (candidates for ENTRA_EMAIL_FIELD):"
    echo "$member" | jq -r '
      [ to_entries[] | .key as $k | .value |
        if type == "string" and test("@") then "  \($k): \(.)"
        elif type == "array" then
          to_entries[] | .key as $j | .value |
            if type == "string" and test("@") then "  \($k)[\($j)]: \(.)"
            else empty end
        else empty end
      ] as $m |
      if ($m | length) == 0 then "  (none — inspect full record below)"
      else $m[] end
    '
    echo "Full record:"
    echo "$member" | jq '.'
  done
  echo ""
  echo "=== end DEBUG ==="
  echo ""
fi

# 4. Iterate members: skip already-provisioned, provision the rest.
count=$(jq 'length' "$MEMBERS_JSON")
if [ "$count" = "0" ]; then
  echo "No users to provision."
  exit 0
fi

provisioned=0
skipped=0
failed=0

for i in $(seq 0 $((count - 1))); do
  member=$(jq --argjson i "$i" '.[$i]' "$MEMBERS_JSON")
  uid=$(echo "$member" | jq -r '.id')
  raw_name=$(echo "$member" | jq -r '.displayName // empty')
  email=$(echo "$member" | jq -r --arg fields "$ENTRA_EMAIL_FIELD" '
    ($fields | split(",") | map(gsub("^\\s+|\\s+$"; ""))) as $priority |
    ( first(
        $priority[] as $f |
        (.[$f]) |
        if type == "array" then
          (map(select(type == "string" and . != "")) | .[0] // empty)
        elif type == "string" and . != "" then .
        else empty end
      ) // "" )
    | sub("^(SMTP|smtp):"; "")
  ')

  if [ -z "$email" ]; then
    echo "[skip] ${raw_name:-$uid}: no value in any of [$ENTRA_EMAIL_FIELD]"
    skipped=$((skipped + 1))
    continue
  fi

  # full_name is required (1-256 chars); fall back to email if displayName is empty.
  full_name="${raw_name:-$email}"

  echo "User: $full_name <$email>"

  encoded=$(jq -rn --arg v "$email" '$v|@uri')
  lookup_url="$FLEX_BASE/Users?Username=$encoded"
  echo "  GET $lookup_url"
  lookup=$(curl -sS -w $'\n%{http_code}' \
    -u "$TWILIO_API_KEY:$TWILIO_API_SECRET" \
    "$lookup_url")
  lstatus=$(echo "$lookup" | tail -n1)
  lbody=$(echo "$lookup"   | sed '$d')

  if [ "$lstatus" != "200" ]; then
    echo "  Lookup failed: HTTP $lstatus - $lbody"
    failed=$((failed + 1))
    continue
  fi

  existing_sid=$(echo "$lbody" | jq -r '(.users // .Users // [])[0] | (.flex_user_sid // .sid // empty)')
  if [ -n "$existing_sid" ]; then
    echo "  Already provisioned (Flex SID: $existing_sid) — skipping"
    skipped=$((skipped + 1))
    continue
  fi

  provision_body=$(jq -nc \
    --arg username "$email" \
    --arg email    "$email" \
    --arg fullname "$full_name" \
    --argjson roles "$FLEX_ROLES_JSON" \
    --argjson worker "$FLEX_WORKER_JSON" \
    '{username: $username, email: $email, full_name: $fullname, roles: $roles, worker: $worker}')

  provision_url="$FLEX_BASE/Users/Provision"
  echo "  POST $provision_url"
  echo "  Body: $provision_body"

  provision=$(curl -sS -w $'\n%{http_code}' -X POST \
    -u "$TWILIO_API_KEY:$TWILIO_API_SECRET" \
    -H "Content-Type: application/json" \
    -d "$provision_body" \
    "$provision_url")
  pstatus=$(echo "$provision" | tail -n1)
  pbody=$(echo "$provision"   | sed '$d')

  echo "  Response: HTTP $pstatus"
  case "$pstatus" in
    200|201|202)
      created_sid=$(echo "$pbody" | jq -r '.flex_user_sid // .sid // empty')
      echo "  Provisioned. Flex SID: $created_sid"
      echo "  Body: $(echo "$pbody" | jq -c '.')"
      provisioned=$((provisioned + 1))
      ;;
    *)
      echo "  Provision FAILED. Body: $(echo "$pbody" | jq -c '.' 2>/dev/null || echo "$pbody")"
      failed=$((failed + 1))
      ;;
  esac
done

echo ""
echo "Summary: $provisioned provisioned, $skipped skipped, $failed failed."
