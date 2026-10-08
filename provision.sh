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

usage() {
  cat <<'USAGE'
Usage: provision.sh [-f|--force] [-n|--dry-run] [-h|--help]

  -n, --dry-run   Print the list of users that would be provisioned and exit
                  without making any changes. Never prompts. Overrides --force.
  -f, --force     Skip the confirmation prompt. Required for non-interactive
                  (cron / no-TTY) runs.
  -h, --help      Show this help and exit.

Default: interactive. Prints a summary of the users that will be provisioned
and requires typing "yes" to proceed.
USAGE
}

FORCE=0
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    -f|--force)   FORCE=1 ;;
    -n|--dry-run) DRY_RUN=1 ;;
    -h|--help)    usage; exit 0 ;;
    *)            echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

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
STATE_TSV_TMP=$(mktemp)
TO_PROVISION=$(mktemp)
trap 'rm -f "$MEMBERS_JSON" "$ASSIGNMENT_IDS" "$STATE_TSV_TMP" "$TO_PROVISION"' EXIT

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
    total_users=$(echo "$page" | jq -r '[.value[] | select(.principalType == "User")] | length')
    kept_users=$(echo "$page"  | jq -r '[.value[] | select(.principalType == "User") | select(.principalId != null)] | length')
    if [ "$total_users" != "$kept_users" ]; then
      echo "Warning: skipped $((total_users - kept_users)) User assignment(s) with null principalId on this page (likely stale rows for deleted users)." >&2
    fi
    echo "$page" | jq -r '.value[] | select(.principalType == "User") | select(.principalId != null) | .principalId' >> "$ASSIGNMENT_IDS"
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
  for ((i = 0; i < count; i++)); do
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

# 4. Discovery pass: classify each Entra user into (to-provision, already-in-Flex,
# no-email). Actual mutations happen in the mutation pass below, after the summary
# and confirmation prompt.
count=$(jq 'length' "$MEMBERS_JSON")

skipped_no_email=0
skipped_already=0
discovery_failed=0
: > "$TO_PROVISION"

for ((i = 0; i < count; i++)); do
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
    echo "[skip] ${raw_name:-$uid}: no value in any of [$ENTRA_EMAIL_FIELD]" >&2
    skipped_no_email=$((skipped_no_email + 1))
    continue
  fi

  # full_name is required (1-256 chars); fall back to email if displayName is empty.
  full_name="${raw_name:-$email}"

  # Record this user for the shared state file so deprovision.sh (app mode) can
  # detect subsequent unassignments. In group mode this file isn't used.
  if [ "$trigger_mode" = "app" ]; then
    printf '%s\t%s\t%s\n' "$uid" "$(printf '%s' "$full_name" | tr '\t' ' ')" "$email" >> "$STATE_TSV_TMP"
  fi

  encoded=$(jq -rn --arg v "$email" '$v|@uri')
  lookup_url="$FLEX_BASE/Users?Username=$encoded"
  lookup=$(curl -sS -w $'\n%{http_code}' \
    -u "$TWILIO_API_KEY:$TWILIO_API_SECRET" \
    "$lookup_url")
  lstatus=$(echo "$lookup" | tail -n1)
  lbody=$(echo "$lookup"   | sed '$d')

  if [ "$lstatus" != "200" ]; then
    echo "[warn] Flex lookup for $email failed: HTTP $lstatus - $lbody" >&2
    discovery_failed=$((discovery_failed + 1))
    continue
  fi

  existing_sid=$(echo "$lbody" | jq -r '(.users // .Users // [])[0] | (.flex_user_sid // .sid // empty)')
  if [ -n "$existing_sid" ]; then
    skipped_already=$((skipped_already + 1))
    continue
  fi

  printf '%s\t%s\t%s\n' "$uid" "$(printf '%s' "$full_name" | tr '\t' ' ')" "$email" >> "$TO_PROVISION"
done

to_count=$(wc -l < "$TO_PROVISION" | tr -d ' ')

# 5. Summary + confirmation.
echo ""
if [ "$to_count" = "0" ]; then
  echo "Nothing to provision."
else
  echo "The following $to_count user(s) will be Provisioned:"
  idx=0
  while IFS=$'\t' read -r _uid _name _email; do
    idx=$((idx + 1))
    printf '  %d. %s <%s>\n' "$idx" "$_name" "$_email"
  done < "$TO_PROVISION"
fi
echo ""
echo "Also: $skipped_already already provisioned (will skip), $skipped_no_email with no email (will skip), $discovery_failed lookup failure(s)."

if [ "$DRY_RUN" = "1" ]; then
  echo ""
  echo "Dry run — no changes made."
  # Still update the app-mode state file below (side-effect of discovery, not mutation).
  provisioned=0
  skipped=$((skipped_already + skipped_no_email))
  failed=0
elif [ "$to_count" = "0" ]; then
  provisioned=0
  skipped=$((skipped_already + skipped_no_email))
  failed=0
else
  if [ "$FORCE" != "1" ]; then
    if [ ! -t 0 ]; then
      echo "error: non-interactive shell requires --force (or --dry-run)" >&2
      exit 1
    fi
    read -r -p 'Type "yes" to proceed: ' answer
    if [ "$answer" != "yes" ]; then
      echo "Aborted — no changes made."
      exit 0
    fi
  fi

  # 6. Mutation pass: provision every user in TO_PROVISION.
  provisioned=0
  skipped=$((skipped_already + skipped_no_email))
  failed=$discovery_failed

  while IFS=$'\t' read -r uid full_name email; do
    [ -z "$email" ] && continue
    echo "User: $full_name <$email>"

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
  done < "$TO_PROVISION"

  echo ""
  echo "Summary: $provisioned provisioned, $skipped skipped, $failed failed."
fi

# App mode: write/update the shared state file consumed by deprovision.sh.
# Writing this here (rather than only in deprovision.sh) is what makes the
# "assign → provision → unassign → deprovision" workflow reliable: without
# a prior snapshot, deprovision has nothing to diff against.
if [ "$trigger_mode" = "app" ]; then
  STATE_FILE="$SCRIPT_DIR/assigned_users.tsv"
  if [ -s "$STATE_TSV_TMP" ]; then
    sort -u -t $'\t' -k1,1 "$STATE_TSV_TMP" > "$STATE_FILE"
    state_count=$(wc -l < "$STATE_FILE" | tr -d ' ')
    echo "State snapshot: $state_count user(s) written to $STATE_FILE (deprovision.sh will detect subsequent unassignments)."
  else
    : > "$STATE_FILE"
    echo "State snapshot: 0 user(s) — $STATE_FILE cleared."
  fi
fi
