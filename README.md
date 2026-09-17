# EntraFlex

Watch a Microsoft Entra ID group for newly-added members and automatically deprovision each one from Twilio Flex — both the **Flex v4 User** identity and the **TaskRouter Worker** record.

Written as a single self-contained Bash script (`deprovision.sh`) — no runtime, no dependencies beyond `curl` and `jq`. A Python equivalent (`deprovision.py`) is included for teams that prefer Python.

---

## How it works

1. On each run, the script fetches the Entra group's current *user* members via Microsoft Graph.
2. It compares the returned user IDs against `seen_users.txt` (state file, one ID per line).
3. For each user in the group but not yet in state, it:
   - Reads a configurable Entra field (default `mail`, falling back to `userPrincipalName`) as the identifier used against Twilio.
   - **Flex v4 User step:** `GET https://flex-api.twilio.com/v4/Instances/{InstanceSid}/Users?Username={email}` to find the `flex_user_sid`, then `POST /Users/Deprovision` with that SID, then verifies with a follow-up `GET /Users/{sid}`.
   - **TaskRouter Worker step:** `GET https://taskrouter.twilio.com/v1/Workspaces/{WorkspaceSid}/Workers?FriendlyName={email}` to find the worker, then `DELETE /Workers/{sid}`, then verifies with a follow-up GET.
4. Successfully processed users are added to state. Users that failed transiently are kept out of state so they retry next run. Users who leave the Entra group drop out of state too.

**On the first run** (no `seen_users.txt` present), *every* current member of the group is processed. On subsequent runs only members added since the last run are processed.

The **TaskRouter Worker delete step is opt-in.** Set `DELETE_TASKROUTER_WORKER=1` in `.env` to enable it. When enabled, the **TaskRouter Workspace SID** is auto-discovered from `GET https://flex-api.twilio.com/v1/Configuration` on each run — or set `TASKROUTER_WORKSPACE_SID` in `.env` to skip the discovery call. If discovery fails and no override is set, the Worker-delete step is skipped with a warning (Flex v4 deprovision still runs).

---

## Prerequisites

- **On the host that runs the script:** Bash, `curl`, and `jq`.
  - macOS: `brew install jq` (curl is preinstalled)
  - Debian / Ubuntu: `sudo apt install jq`
  - RHEL / Amazon Linux: `sudo dnf install jq` or `sudo yum install jq`
- **Admin access to a Microsoft Entra ID tenant** — you need to be able to create app registrations and grant admin consent to Graph permissions.
- **A Twilio Flex account** — with permission to create API keys.

---

## Part 1 — Entra ID setup

### 1.1  Get your Tenant ID

1. Sign in to the [Microsoft Entra admin center](https://entra.microsoft.com).
2. In the left nav go to **Overview**. The **Tenant ID** appears on the right (a GUID).
3. Copy it — this is `TENANT_ID` in `.env`.

### 1.2  Register an application

1. Left nav → **Applications → App registrations → New registration**.
2. **Name:** anything, e.g. `EntraFlex Deprovisioner`.
3. **Supported account types:** *Accounts in this organizational directory only (single tenant)*.
4. **Redirect URI:** leave blank.
5. Click **Register**.
6. On the app's Overview page, copy the **Application (client) ID** — this is `CLIENT_ID` in `.env`.

### 1.3  Create a client secret

1. On the app page, left nav → **Certificates & secrets**.
2. Under **Client secrets**, click **New client secret**.
3. Description: anything (e.g. `entraflex-prod`). Expires: pick per your policy (e.g. 12 months).
4. Click **Add**.
5. **Copy the "Value" column immediately** — it is only shown this one time. This is `CLIENT_SECRET` in `.env`. (The "Secret ID" column is not what you want.)

### 1.4  Grant Microsoft Graph API permissions

The app needs two application permissions on Microsoft Graph:

| Permission | Why |
| --- | --- |
| `GroupMember.Read.All` | To list the group's members |
| `User.Read.All` | To read `mail`, `proxyAddresses`, etc. on each user |

Steps:

1. On the app page → **API permissions → Add a permission → Microsoft Graph → Application permissions** (**not** Delegated — client-credentials scripts only see Application scopes).
2. Search **`GroupMember.Read.All`** → check → **Add permissions**.
3. Repeat: **Add a permission → Microsoft Graph → Application permissions → `User.Read.All`** → **Add permissions**.
4. Back on the API permissions page, click **"Grant admin consent for &lt;your tenant&gt;"** → **Yes**.
5. Both rows should now show a green check under **Status**. Wait ~30 seconds for propagation.

If you don't see the "Grant admin consent" button, you don't have the directory role required — a tenant admin (Global Admin, Privileged Role Admin, or Cloud Application Admin) needs to click it.

### 1.5  Find the group's Object ID

1. Left nav → **Groups → All groups**.
2. Click into the group you want to watch (create one first if needed — **New group → Security**).
3. On the group's Overview page, copy the **Object ID** (a GUID).
4. This is `ENTRA_GROUP_ID` in `.env`.

The group may contain nested groups, service principals, or devices — the script filters to *user* members only and safely ignores the rest.

---

## Part 2 — Twilio Flex setup

### 2.1  Find your Flex Instance SID

1. Sign in to the [Twilio Console](https://console.twilio.com).
2. Left nav → **Flex → Manage → Instances** (or the URL `console.twilio.com/us1/flex/manage/instances`).
3. Copy the **Instance SID** — it starts with `GO`.
4. This is `FLEX_INSTANCE_SID` in `.env`.

### 2.2  Create an API Key

The Flex Users API authenticates with any account-level API key.

1. Console top-right avatar → **API keys & tokens** (or **Account → API keys & tokens**).
2. Click **Create API key**.
3. **Friendly name:** anything, e.g. `EntraFlex`. **Key type:** *Standard*.
4. Click **Create**.
5. **Copy both values immediately** — the secret is only shown once:
   - **SID** starts with `SK...` — this is `TWILIO_API_KEY` in `.env`.
   - **Secret** — this is `TWILIO_API_SECRET` in `.env`.

Store these in a password manager as backup. If lost, revoke the key and create a new one — you can't retrieve an existing secret.

---

## Part 3 — Local install and configuration

```bash
git clone <your-fork-url> entraflex
cd entraflex
cp .env.example .env
chmod 600 .env
# Edit .env and fill in the seven values collected in Parts 1 and 2.
chmod +x deprovision.sh
```

Your `.env` should now look like:

```dotenv
TENANT_ID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
CLIENT_ID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
CLIENT_SECRET=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
ENTRA_GROUP_ID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
TWILIO_API_KEY=SKxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
TWILIO_API_SECRET=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
FLEX_INSTANCE_SID=GOxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

# Optional — set to enable TaskRouter Worker cleanup (default off)
# DELETE_TASKROUTER_WORKER=1

# Optional — only used when DELETE_TASKROUTER_WORKER is enabled;
# auto-discovered from Flex Configuration if omitted
# TASKROUTER_WORKSPACE_SID=WSxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

---

## Running

### First run

Processes every current member of the group:

```bash
./deprovision.sh
# → First run — no state file. Processing all N current member(s).
# → New user: ...
```

### Every subsequent run

Only members added since the last run get processed:

```bash
./deprovision.sh
# → No new users.
# or
# → New user: Jane Doe <jane@contoso.com>
#     Flex SID: FUxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx — deprovisioning...
#     Deprovisioned.
```

### Debug mode — inspect what Graph returns per member

Useful when picking which Entra field to map to the Flex username, or when a user is being skipped because expected fields look empty:

```bash
DEBUG=1 ./deprovision.sh
```

For each member, DEBUG mode prints:
- Every field whose value contains `@` (candidates for `ENTRA_EMAIL_FIELD`) with its field name.
- The full raw user record from Graph.

### Scheduled runs (cron)

Poll every 5 minutes and log to a file:

```
*/5 * * * * cd /opt/entraflex && ./deprovision.sh >> run.log 2>&1
```

Adjust the interval per your needs. Ensure the process running cron has read/write access to `seen_users.txt` next to the script.

---

## Configuring the Entra → Flex username mapping

Twilio Flex looks up users by their **Username**, typically an email. The script pulls that value from Entra using `ENTRA_EMAIL_FIELD`:

```dotenv
# .env
ENTRA_EMAIL_FIELD=mail,userPrincipalName
```

- Comma-separated priority list — first non-empty value wins.
- Scalar fields work as-is: `mail`, `userPrincipalName`, `onPremisesUserPrincipalName`.
- Array fields work automatically: `otherMails`, `proxyAddresses` — the first non-empty element is used.
- `proxyAddresses` entries prefixed with `SMTP:` or `smtp:` have the prefix stripped.

**Examples:**

```dotenv
# Default — most cloud-only tenants
ENTRA_EMAIL_FIELD=mail,userPrincipalName

# Hybrid AD tenant where the primary SMTP lives in proxyAddresses
ENTRA_EMAIL_FIELD=proxyAddresses,mail,userPrincipalName

# Only use the sign-in name
ENTRA_EMAIL_FIELD=userPrincipalName
```

If you're unsure which field to pick, run `DEBUG=1 ./deprovision.sh` and copy the field name(s) from the "Fields containing '@'" section into `ENTRA_EMAIL_FIELD`.

---

## State file

`seen_users.txt` sits next to the script (one Entra user ID per line). It's how the script knows who's already been processed. Behavior:

- **File missing** → every current group member is treated as new and processed.
- **File exists** → users in the group but not in the file are treated as new; failed users retry next run; users who left the group drop out of state.
- Force reprocessing of every current member: `rm seen_users.txt` or `: > seen_users.txt` (either works — a missing or empty state file causes everyone to be treated as new).

**Do not commit `seen_users.txt`** — it's in `.gitignore` by default.

---

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `curl (22)` / `Graph token request failed: HTTP 400 invalid_client` | `CLIENT_ID` or `CLIENT_SECRET` wrong, or the secret has expired. Regenerate a client secret in Entra. |
| `Graph group-members request failed: HTTP 403 Authorization_RequestDenied` | App is missing `GroupMember.Read.All` (Application) with admin consent granted. See §1.4. |
| `/users/{id} failed: HTTP 403` (in DEBUG mode) | App is missing `User.Read.All` (Application) with admin consent. See §1.4. |
| `Directory_ObjectNotFound` on group members URL | `ENTRA_GROUP_ID` is not the group's Object ID (a GUID). Don't paste display name / mail nickname. |
| `[skip] <name>: no value in any of [mail,userPrincipalName]` | The configured fields are empty on this user. Run `DEBUG=1` to see what's populated and adjust `ENTRA_EMAIL_FIELD`. |
| `No Flex v4 user for <email> — nothing to deprovision` | Not an error — this user has no Flex v4 identity under that Username. The TaskRouter step still runs. |
| `No TaskRouter worker with FriendlyName=<email>` | Not an error — no matching Worker exists. The Flex v4 step still runs. |
| `Worker delete FAILED` with HTTP 400 mentioning reservations | TaskRouter blocks deleting a Worker with active reservations. Move the Worker's Activity to Offline first, then re-run. |
| `Warning: TaskRouter Workspace SID not discovered` | The Flex Configuration call failed. Either set `TASKROUTER_WORKSPACE_SID` explicitly in `.env`, or ensure the API key can read Flex Configuration. |
| Deprovision or worker delete returns 5xx | Transient — the user is kept out of state and retried next run. |
| Non-user members appearing (nested groups, service principals, devices) | Filtered out automatically — Graph URL is scoped to `microsoft.graph.user`. |

---

## Security notes

- `.env` contains a client secret and an API key secret. `chmod 600` it, keep it out of source control (already in `.gitignore`), and rotate both if either is exposed.
- The Twilio API key is **account-level** — anyone with it can act on your Twilio account. Use a dedicated key for this integration and revoke it in the Console if compromised.
- The Entra client secret gives the app application-level access to `GroupMember.Read.All` and `User.Read.All` tenant-wide. Rotate it periodically per your organization's policy.
- The script does not log secrets, but `DEBUG=1` prints full user records including email addresses — take care where you redirect the output.

---

## Files in this repo

| File | Purpose |
| --- | --- |
| `deprovision.sh` | Primary script (Bash + curl + jq). |
| `deprovision.py` | Python 3.10+ equivalent, same behavior. |
| `requirements.txt` | Python dependency (`requests`). Only needed if using `deprovision.py`. |
| `.env.example` | Template for the `.env` you create locally. |
| `.gitignore` | Excludes `.env`, `seen_users.txt`, and other local artifacts. |
| `README.md` | This file. |
