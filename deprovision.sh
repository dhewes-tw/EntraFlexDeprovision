#!/usr/bin/env bash
#
# Watch an Entra ID group OR an Entra Enterprise Application and deprovision
# users from Twilio Flex (Flex v4 User + optional TaskRouter Worker) on trigger.
#
# Trigger modes (TRIGGER_MODE env var):
#   group  (default) — process users ADDED to ENTRA_GROUP_ID
#   app              — process users UNASSIGNED from ENTRA_ENTERPRISE_APP_SID
#
# Required env vars: TENANT_ID CLIENT_ID CLIENT_SECRET
#                    TWILIO_API_KEY TWILIO_API_SECRET FLEX_INSTANCE_SID
# Group mode also requires: ENTRA_GROUP_ID
# App mode also requires:   ENTRA_ENTERPRISE_APP_SID (service principal Object ID)
#
# Graph API permissions (Application, admin-consented):
#   Group mode:  GroupMember.Read.All  (+ User.Read.All if DEBUG=1)
#   App mode:    Application.Read.All + User.Read.All
# Requires: curl, jq.
#
# State files (written next to this script):
#   Group mode: seen_users.txt        — one Entra user ID per line
#   App mode:   assigned_users.tsv    — "id\tname\temail" per line
# Group mode: if no state file, all current members are processed.
# App mode:   if no state file, the current assignees are baselined and no
#             action is taken; subsequent runs process any user removed since.

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: deprovision.sh [-f|--force] [-n|--dry-run] [-h|--help]

  -n, --dry-run   Print the list of users that would be deprovisioned and exit
                  without making any changes (state file is not updated either,
                  so a subsequent run will re-detect the same users). Never
                  prompts. Overrides --force.
  -f, --force     Skip the confirmation prompt. Required for non-interactive
                  (cron / no-TTY) runs.
  -h, --help      Show this help and exit.

Default: interactive. Prints a summary of the users that will be deprovisioned
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

# Trigger mode: 'group' (default) or 'app'. Selects which Entra resource to
# watch, which required env var applies, and which state file to use.
trigger_mode_raw="${TRIGGER_MODE:-group}"
case "$trigger_mode_raw" in
  group|Group|GROUP)
    trigger_mode="group"
    : "${ENTRA_GROUP_ID:?required when TRIGGER_MODE=group}"
    STATE_FILE="$SCRIPT_DIR/seen_users.txt"
    ;;
  app|App|APP)
    trigger_mode="app"
    : "${ENTRA_ENTERPRISE_APP_SID:?required when TRIGGER_MODE=app}"
    STATE_FILE="$SCRIPT_DIR/assigned_users.tsv"
    ;;
  *)
    echo "Invalid TRIGGER_MODE '$trigger_mode_raw' — must be 'group' or 'app'" >&2
    exit 1
    ;;
esac

FLEX_BASE="https://flex-api.twilio.com/v4/Instances/$FLEX_INSTANCE_SID"

# TaskRouter cleanup is opt-in. Enable by setting DELETE_TASKROUTER_WORKER=1
# (or true/yes/on) in .env. When enabled, the Workspace SID is auto-discovered
# from Flex Configuration unless TASKROUTER_WORKSPACE_SID is set explicitly.
tr_enabled=0
case "${DELETE_TASKROUTER_WORKER:-}" in
  1|true|True|TRUE|yes|Yes|YES|on|On|ON) tr_enabled=1 ;;
esac

TR_BASE=""
if [ "$tr_enabled" = "1" ]; then
  if [ -z "${TASKROUTER_WORKSPACE_SID:-}" ]; then
    cfg_resp=$(curl -sS -w $'\n%{http_code}' \
      -u "$TWILIO_API_KEY:$TWILIO_API_SECRET" \
      "https://flex-api.twilio.com/v1/Configuration")
    cfg_status=$(echo "$cfg_resp" | tail -n1)
    cfg_body=$(echo "$cfg_resp"   | sed '$d')
    if [ "$cfg_status" = "200" ]; then
      TASKROUTER_WORKSPACE_SID=$(echo "$cfg_body" | jq -r '.taskrouter_workspace_sid // empty')
    fi
  fi
  if [ -n "${TASKROUTER_WORKSPACE_SID:-}" ]; then
    TR_BASE="https://taskrouter.twilio.com/v1/Workspaces/$TASKROUTER_WORKSPACE_SID"
  else
    echo "Warning: DELETE_TASKROUTER_WORKER is set but Workspace SID could not be discovered — cleanup will be skipped." >&2
    echo "  Set TASKROUTER_WORKSPACE_SID in .env or ensure the Twilio key can read Flex Configuration." >&2
  fi
fi

# Which Entra user field(s) to use as the Flex Username. Comma-separated priority
# list; first non-empty wins. Scalar and array fields both work — array fields
# use the first non-empty string. proxyAddresses entries have their "SMTP:" /
# "smtp:" prefix stripped automatically.
ENTRA_EMAIL_FIELD="${ENTRA_EMAIL_FIELD:-mail,userPrincipalName}"

# Build a $select clause that includes every configured field.
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

MEMBERS_JSON=$(mktemp)
CURRENT_IDS=$(mktemp)
NEW_IDS=$(mktemp)
FAILED=$(mktemp)
ASSIGNMENT_IDS=$(mktemp)
TO_PROCESS=$(mktemp)
trap 'rm -f "$MEMBERS_JSON" "$CURRENT_IDS" "$NEW_IDS" "$FAILED" "$ASSIGNMENT_IDS" "$TO_PROCESS"' EXIT

# Helper: given an Entra user ID present in MEMBERS_JSON, print id\tname\temail
# to stdout — used to build both TO_PROCESS and the app-mode state file.
extract_user_row() {
  local uid="$1" member name email
  member=$(jq --arg id "$uid" '.[] | select(.id == $id)' "$MEMBERS_JSON")
  if [ -z "$member" ]; then
    printf '%s\t%s\t%s\n' "$uid" "" ""
    return
  fi
  name=$(echo "$member" | jq -r '.displayName // .id' | tr '\t' ' ')
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
  printf '%s\t%s\t%s\n' "$uid" "$name" "$email"
}

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
  # In DEBUG mode, pull a broad set of common email-candidate fields.
  effective_select="id,displayName,mail,userPrincipalName,otherMails,proxyAddresses,onPremisesUserPrincipalName,onPremisesSamAccountName,mailNickname,employeeId,userType"
else
  effective_select="$select_fields"
fi

if [ "$trigger_mode" = "group" ]; then
  # Group mode: paginate through the group's user members.
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
  # App mode: paginate through the enterprise app's user assignments, then
  # fetch each user's full profile so we can extract the Flex username field.
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
    # Count User assignments with null principalId (stale rows for deleted users)
    # so we can warn about them rather than emitting "null" into ASSIGNMENT_IDS.
    total_users=$(echo "$page" | jq -r '[.value[] | select(.principalType == "User")] | length')
    kept_users=$(echo "$page"  | jq -r '[.value[] | select(.principalType == "User") | select(.principalId != null)] | length')
    if [ "$total_users" != "$kept_users" ]; then
      echo "Warning: skipped $((total_users - kept_users)) User assignment(s) with null principalId on this page (likely stale rows for deleted users)." >&2
    fi
    echo "$page" | jq -r '.value[] | select(.principalType == "User") | select(.principalId != null) | .principalId' >> "$ASSIGNMENT_IDS"
    url=$(echo "$page" | jq -r '."@odata.nextLink" // empty')
  done
  # Fetch full profile per assigned user.
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
      echo "Warning: /users/$pid returned HTTP $user_status; stub-recording ID only." >&2
      jq --arg id "$pid" '. + [{id: $id, displayName: ""}]' "$MEMBERS_JSON" > "$MEMBERS_JSON.tmp"
      mv "$MEMBERS_JSON.tmp" "$MEMBERS_JSON"
    fi
  done < "$ASSIGNMENT_IDS"
fi

if [ -n "${DEBUG:-}" ]; then
  # /groups/{id}/members often returns trimmed user objects. In DEBUG mode we
  # re-fetch each member via /users/{id} with a broad $select to see everything
  # Graph will hand back. If this 403s, add User.Read.All (Application) to the
  # app registration and grant admin consent.
  user_select="id,displayName,mail,userPrincipalName,otherMails,proxyAddresses,onPremisesUserPrincipalName,onPremisesSamAccountName,onPremisesDistinguishedName,mailNickname,employeeId,userType,accountEnabled,givenName,surname,jobTitle,department,companyName"
  count=$(jq 'length' "$MEMBERS_JSON")
  if [ "$trigger_mode" = "group" ]; then
    echo "=== DEBUG: $count member(s); fetching each via /users/{id} ==="
  else
    echo "=== DEBUG: $count assignee(s) currently on enterprise app ==="
  fi
  for ((i = 0; i < count; i++)); do
    mid=$(jq -r --argjson i "$i" '.[$i].id' "$MEMBERS_JSON")
    echo ""
    echo "----- id: $mid -----"
    if [ "$trigger_mode" = "app" ]; then
      # App mode: MEMBERS_JSON already contains the full profile fetched
      # in step 2 — use it directly instead of re-fetching.
      user_body=$(jq -c --argjson i "$i" '.[$i]' "$MEMBERS_JSON")
    else
      # Group mode: /groups/{id}/members returns trimmed user objects, so
      # re-fetch each via /users/{id} for the broader $select.
      user_resp=$(curl -sS -w $'\n%{http_code}' -H "Authorization: Bearer $TOKEN" \
        "https://graph.microsoft.com/v1.0/users/$mid?\$select=$user_select")
      user_status=$(echo "$user_resp" | tail -n1)
      user_body=$(echo "$user_resp"   | sed '$d')
      if [ "$user_status" != "200" ]; then
        echo "  /users/$mid failed: HTTP $user_status"
        echo "  $user_body"
        [ "$user_status" = "403" ] && echo "  Hint: add User.Read.All (Application) to the app registration and grant admin consent."
        continue
      fi
    fi
    echo "Fields containing '@' (candidates for ENTRA_EMAIL_FIELD):"
    echo "$user_body" | jq -r '
      [ to_entries[] | .key as $k | .value |
        if type == "string" and test("@") then "  \($k): \(.)"
        elif type == "array" then
          to_entries[] | .key as $i | .value |
            if type == "string" and test("@") then "  \($k)[\($i)]: \(.)"
            else empty end
        else empty end
      ] as $m |
      if ($m | length) == 0 then "  (none — inspect full record below)"
      else $m[] end
    '
    echo "Full record:"
    echo "$user_body" | jq '.'

    echo ""
    echo "Flex Username probe — trying each Entra string field value as ?Username="
    # Every scalar / array-element string value in the Graph record becomes a
    # candidate. For proxyAddresses we strip the SMTP:/smtp: prefix.
    candidates=$(echo "$user_body" | jq -r '
      [ to_entries[] | .key as $k | .value |
        if type == "string" and . != "" then "\($k)|\(.)"
        elif type == "array" then
          to_entries[] | .key as $j | .value |
            if type == "string" and . != "" then "\($k)[\($j)]|\(sub("^(SMTP|smtp):"; ""))"
            else empty end
        else empty end
      ] | .[]
    ')
    while IFS='|' read -r field value; do
      [ -z "$value" ] && continue
      encoded=$(jq -rn --arg v "$value" '$v|@uri')
      probe_url="$FLEX_BASE/Users?Username=$encoded"
      echo "  [$field] GET $probe_url"
      probe=$(curl -sS -w $'\n%{http_code}' \
        -u "$TWILIO_API_KEY:$TWILIO_API_SECRET" \
        "$probe_url")
      pstatus=$(echo "$probe" | tail -n1)
      pbody=$(echo "$probe"   | sed '$d')
      if [ "$pstatus" = "200" ]; then
        matches=$(echo "$pbody" | jq -r '(.users // .Users // []) | length')
        if [ "$matches" != "0" ]; then
          echo "    → HTTP 200, MATCH ($matches user(s))"
          echo "$pbody" | jq -c '(.users // .Users // [])[0]' | sed 's/^/       /'
        else
          echo "    → HTTP 200, no match"
        fi
      else
        echo "    → HTTP $pstatus: $(echo "$pbody" | jq -c '.' 2>/dev/null || echo "$pbody")"
      fi
    done <<< "$candidates"
  done

  if [ -n "$TR_BASE" ]; then
    echo ""
    echo "=== DEBUG: All TaskRouter Workers ==="
    tr_list_url="$TR_BASE/Workers?PageSize=100"
    tr_page_num=1
    while [ -n "$tr_list_url" ]; do
      echo "Page $tr_page_num: GET $tr_list_url"
      tr_list_resp=$(curl -sS -w $'\n%{http_code}' \
        -u "$TWILIO_API_KEY:$TWILIO_API_SECRET" \
        "$tr_list_url")
      tr_list_status=$(echo "$tr_list_resp" | tail -n1)
      tr_list_body=$(echo "$tr_list_resp"   | sed '$d')
      if [ "$tr_list_status" != "200" ]; then
        echo "  → HTTP $tr_list_status: $tr_list_body"
        break
      fi
      tr_list_count=$(echo "$tr_list_body" | jq -r '(.workers // []) | length')
      echo "  → HTTP 200, $tr_list_count worker(s) on this page"
      echo "$tr_list_body" | jq '.'
      tr_list_next=$(echo "$tr_list_body" | jq -r '.meta.next_page_url // empty')
      if [ -n "$tr_list_next" ]; then
        tr_list_url="$tr_list_next"
        tr_page_num=$((tr_page_num + 1))
      else
        tr_list_url=""
      fi
    done
  fi

  echo ""
  echo "=== end DEBUG ==="
  echo ""
fi

jq -r '.[].id' "$MEMBERS_JSON" | sort -u > "$CURRENT_IDS"

# 3. Build TO_PROCESS (id\tname\temail) based on the trigger mode.
: > "$TO_PROCESS"

if [ "$trigger_mode" = "group" ]; then
  # Group mode: new = current - seen. On first run, all current members are new.
  if [ ! -f "$STATE_FILE" ]; then
    cp "$CURRENT_IDS" "$NEW_IDS"
    first_run_count=$(wc -l < "$NEW_IDS" | tr -d ' ')
    echo "First run — no state file. Processing all $first_run_count current member(s)."
  else
    comm -23 "$CURRENT_IDS" <(sort -u "$STATE_FILE") > "$NEW_IDS"
  fi

  if [ ! -s "$NEW_IDS" ]; then
    echo "No new users."
    cp "$CURRENT_IDS" "$STATE_FILE"
    exit 0
  fi

  while IFS= read -r uid; do
    [ -n "$uid" ] && extract_user_row "$uid" >> "$TO_PROCESS"
  done < "$NEW_IDS"
else
  # App mode: removed = state IDs - current IDs. On first run, baseline only.
  if [ ! -f "$STATE_FILE" ]; then
    while IFS= read -r uid; do
      [ -n "$uid" ] && extract_user_row "$uid"
    done < "$CURRENT_IDS" > "$STATE_FILE"
    baseline_count=$(wc -l < "$STATE_FILE" | tr -d ' ')
    echo "First run — no state file. Baselined $baseline_count current assignee(s). No action taken."
    exit 0
  fi

  STATE_IDS=$(mktemp)
  REMOVED_IDS=$(mktemp)
  awk -F'\t' '{print $1}' "$STATE_FILE" | sort -u > "$STATE_IDS"
  comm -23 "$STATE_IDS" "$CURRENT_IDS" > "$REMOVED_IDS"

  removed_count=$(wc -l < "$REMOVED_IDS" | tr -d ' ')
  if [ "$removed_count" = "0" ]; then
    echo "No users unassigned since last run."
    # Refresh state to reflect any newly-added assignees.
    while IFS= read -r uid; do
      [ -n "$uid" ] && extract_user_row "$uid"
    done < "$CURRENT_IDS" > "$STATE_FILE"
    rm -f "$STATE_IDS" "$REMOVED_IDS"
    exit 0
  fi

  # Look up each removed ID's stored row in the previous state.
  while IFS= read -r uid; do
    [ -z "$uid" ] && continue
    row=$(awk -F'\t' -v id="$uid" '$1 == id {print; exit}' "$STATE_FILE")
    if [ -z "$row" ]; then
      echo "[warn] no state entry for unassigned user $uid — skipping"
      continue
    fi
    echo "$row" >> "$TO_PROCESS"
  done < "$REMOVED_IDS"
  rm -f "$STATE_IDS" "$REMOVED_IDS"
fi

# 5. Summary + confirmation prompt.
if [ ! -s "$TO_PROCESS" ]; then
  case "$trigger_mode" in
    group) echo "No new users." ;;
    app)   echo "No users to process." ;;
  esac
else
  to_count=$(wc -l < "$TO_PROCESS" | tr -d ' ')
  echo ""
  echo "The following $to_count user(s) will be De-Provisioned:"
  idx=0
  while IFS=$'\t' read -r _uid _name _email; do
    idx=$((idx + 1))
    if [ -n "$_email" ]; then
      printf '  %d. %s <%s>\n' "$idx" "$_name" "$_email"
    else
      printf '  %d. %s (no Flex username — will skip)\n' "$idx" "${_name:-$_uid}"
    fi
  done < "$TO_PROCESS"
  echo ""

  if [ "$DRY_RUN" = "1" ]; then
    echo "Dry run — no changes made. State file not updated."
    exit 0
  fi

  if [ "$FORCE" != "1" ]; then
    if [ ! -t 0 ]; then
      echo "error: non-interactive shell requires --force (or --dry-run)" >&2
      exit 1
    fi
    read -r -p 'Type "yes" to proceed: ' answer
    if [ "$answer" != "yes" ]; then
      echo "Aborted — no changes made. State file not updated."
      exit 0
    fi
  fi
fi

# 6. Iterate TO_PROCESS: (id, name, email) — Flex v4 deprovision + TR worker delete.
while IFS=$'\t' read -r user_id name email; do
  [ -z "$user_id" ] && continue

  if [ -z "$email" ]; then
    echo "[skip] $name ($user_id): no Flex username available"
    continue
  fi

  case "$trigger_mode" in
    group) echo "New user in group: $name <$email>" ;;
    app)   echo "Unassigned from enterprise app: $name <$email>" ;;
  esac
  encoded=$(jq -rn --arg v "$email" '$v|@uri')
  user_failed=0

  # --- Flex v4 User deprovision ---
  echo "  --- Flex v4 User ---"
  lookup_url="$FLEX_BASE/Users?Username=$encoded"
  echo "  GET $lookup_url"
  lookup=$(curl -sS -w $'\n%{http_code}' \
    -u "$TWILIO_API_KEY:$TWILIO_API_SECRET" \
    "$lookup_url")
  status=$(echo "$lookup" | tail -n1)
  body=$(echo "$lookup"   | sed '$d')

  if [ "$status" != "200" ]; then
    echo "  Flex lookup failed: HTTP $status - $body"
    user_failed=1
  else
    sid=$(echo "$body" | jq -r '(.users // .Users // [])[0] | (.flex_user_sid // .sid // empty)')
    if [ -z "$sid" ]; then
      echo "  No Flex v4 user for $email — nothing to deprovision"
      echo "  Raw lookup response: $(echo "$body" | jq -c '.')"
    else
      echo "  Flex SID: $sid — deprovisioning..."
      deprov_url="$FLEX_BASE/Users/Deprovision"
      echo "  POST $deprov_url"
      deprov=$(curl -sS -w $'\n%{http_code}' -X POST \
        -u "$TWILIO_API_KEY:$TWILIO_API_SECRET" \
        -H "Content-Type: application/json" \
        -d "{\"flex_user_sid\":\"$sid\"}" \
        "$deprov_url")
      dstatus=$(echo "$deprov" | tail -n1)
      dbody=$(echo "$deprov"   | sed '$d')

      echo "  Deprovision response: HTTP $dstatus"
      case "$dstatus" in
        200|202|204)
          [ -n "$dbody" ] && echo "  Body: $(echo "$dbody" | jq -c '.' 2>/dev/null || echo "$dbody")"
          verify=$(curl -sS -w $'\n%{http_code}' \
            -u "$TWILIO_API_KEY:$TWILIO_API_SECRET" \
            "$FLEX_BASE/Users/$sid")
          vstatus=$(echo "$verify" | tail -n1)
          vbody=$(echo "$verify"   | sed '$d')
          echo "  Verify GET $FLEX_BASE/Users/$sid → HTTP $vstatus"
          case "$vstatus" in
            404) echo "  Confirmed: user no longer exists in Flex." ;;
            200)
              marker=$(echo "$vbody" | jq -r '
                [ .provisioning_status // empty,
                  .status              // empty,
                  .state               // empty,
                  (if has("is_active") then "is_active=\(.is_active)" else empty end)
                ]
                | map(select(. != null and . != ""))
                | .[0] // empty
              ')
              [ -n "$marker" ] && echo "  Reported status: $marker"
              echo "  Body: $(echo "$vbody" | jq -c '.')"
              ;;
            *) echo "  Verification returned unexpected response: $vbody" ;;
          esac
          ;;
        *)
          echo "  Deprovision FAILED body: $dbody"
          user_failed=1
          ;;
      esac
    fi
  fi

  # --- TaskRouter Worker delete ---
  if [ -n "$TR_BASE" ]; then
    echo "  --- TaskRouter Worker ---"
    tr_lookup_url="$TR_BASE/Workers?FriendlyName=$encoded"
    echo "  GET $tr_lookup_url"
    tr_lookup=$(curl -sS -w $'\n%{http_code}' \
      -u "$TWILIO_API_KEY:$TWILIO_API_SECRET" \
      "$tr_lookup_url")
    tr_status=$(echo "$tr_lookup" | tail -n1)
    tr_body=$(echo "$tr_lookup"   | sed '$d')

    if [ "$tr_status" != "200" ]; then
      echo "  Worker lookup failed: HTTP $tr_status - $tr_body"
      user_failed=1
    else
      worker_count=$(echo "$tr_body" | jq -r '(.workers // []) | length')
      worker_sid=$(echo "$tr_body" | jq -r '(.workers // [])[0].sid // empty')
      if [ -z "$worker_sid" ]; then
        echo "  No TaskRouter worker with FriendlyName=$email — nothing to delete"
        echo "  Raw lookup response: $(echo "$tr_body" | jq -c '.')"
      else
        [ "$worker_count" != "1" ] && echo "  Note: $worker_count workers matched; deleting the first (sid: $worker_sid)"
        del_url="$TR_BASE/Workers/$worker_sid"
        echo "  DELETE $del_url"
        tr_del=$(curl -sS -w $'\n%{http_code}' -X DELETE \
          -u "$TWILIO_API_KEY:$TWILIO_API_SECRET" \
          "$del_url")
        tr_del_status=$(echo "$tr_del" | tail -n1)
        tr_del_body=$(echo "$tr_del"   | sed '$d')
        echo "  Delete response: HTTP $tr_del_status"
        case "$tr_del_status" in
          200|202|204)
            [ -n "$tr_del_body" ] && echo "  Body: $(echo "$tr_del_body" | jq -c '.' 2>/dev/null || echo "$tr_del_body")"
            tr_verify=$(curl -sS -w $'\n%{http_code}' \
              -u "$TWILIO_API_KEY:$TWILIO_API_SECRET" \
              "$del_url")
            tr_vstatus=$(echo "$tr_verify" | tail -n1)
            tr_vbody=$(echo "$tr_verify"   | sed '$d')
            echo "  Verify GET $del_url → HTTP $tr_vstatus"
            case "$tr_vstatus" in
              404) echo "  Confirmed: worker no longer exists in TaskRouter." ;;
              200) echo "  Warning: worker still present. Body: $(echo "$tr_vbody" | jq -c '.')" ;;
              *)   echo "  Verification returned unexpected response: $tr_vbody" ;;
            esac
            ;;
          *)
            echo "  Worker delete FAILED body: $tr_del_body"
            echo "  (TaskRouter blocks deletes for workers with active reservations — set activity to Offline first if needed.)"
            user_failed=1
            ;;
        esac
      fi
    fi
  fi

  [ "$user_failed" = "1" ] && echo "$user_id" >> "$FAILED"
done < "$TO_PROCESS"

# 6. Update state.
if [ "$trigger_mode" = "group" ]; then
  # Group mode: state = current IDs minus failed IDs (so failures retry).
  if [ -s "$FAILED" ]; then
    comm -23 "$CURRENT_IDS" <(sort -u "$FAILED") > "$STATE_FILE"
    fcount=$(wc -l < "$FAILED" | tr -d ' ')
    echo "$fcount user(s) failed and will be retried next run."
  else
    cp "$CURRENT_IDS" "$STATE_FILE"
  fi
else
  # App mode: state = TSV row per currently-assigned user, PLUS any rows for
  # users that failed (their previous-state row is preserved so they'll be
  # detected as "still unassigned" next run and retried).
  FAILED_ROWS=$(mktemp)
  : > "$FAILED_ROWS"
  if [ -s "$FAILED" ]; then
    while IFS= read -r fid; do
      awk -F'\t' -v id="$fid" '$1 == id {print; exit}' "$STATE_FILE"
    done < "$FAILED" > "$FAILED_ROWS"
  fi

  NEW_STATE=$(mktemp)
  while IFS= read -r uid; do
    [ -n "$uid" ] && extract_user_row "$uid"
  done < "$CURRENT_IDS" > "$NEW_STATE"
  cat "$FAILED_ROWS" >> "$NEW_STATE"
  sort -u -t $'\t' -k1,1 "$NEW_STATE" > "$STATE_FILE"
  rm -f "$NEW_STATE" "$FAILED_ROWS"

  if [ -s "$FAILED" ]; then
    fcount=$(wc -l < "$FAILED" | tr -d ' ')
    echo "$fcount user(s) failed and will be retried next run."
  fi
fi
