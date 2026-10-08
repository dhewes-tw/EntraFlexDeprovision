# EntraFlex

Two self-contained Bash scripts that sync Twilio Flex user identities to a Microsoft Entra source of truth:

| Script | Purpose |
| --- | --- |
| `provision.sh` | Push users **into** Flex via `POST /Users/Provision` |
| `deprovision.sh` | Remove users **from** Flex (Flex v4 User + optional TaskRouter Worker) |

Both read users from the same Entra source and support two trigger modes via `TRIGGER_MODE` in `.env`:

| Mode | Watch target | provision.sh acts on | deprovision.sh acts on |
| --- | --- | --- | --- |
| `group` (default) | An Entra ID group | every current member (skips ones already in Flex) | users **added** to the group since last run |
| `app` | An Entra Enterprise Application | every currently-assigned user (skips ones already in Flex) | users **unassigned** since last run |

No runtime, no dependencies beyond `curl` and `jq`.

---

## How it works

Each run:

1. **Fetch users** — mode-specific:
   - Group mode: paginate through `GET /groups/{ENTRA_GROUP_ID}/members/microsoft.graph.user` (nested groups, service principals, devices are filtered out).
   - App mode: paginate through `GET /servicePrincipals/{ENTRA_ENTERPRISE_APP_SID}/appRoleAssignedTo`, keep only `principalType == "User"`, then `GET /users/{principalId}` per user to get the fields needed to resolve the Flex username.
2. **Diff against state** — mode-specific:
   - Group mode: `to_process = current_ids − seen_ids`. If `seen_users.txt` is missing, every current member is processed.
   - App mode: `to_process = seen_ids − current_ids` (users that were assigned last run but not this run). If `assigned_users.tsv` is missing, the current assignees are baselined and no action is taken.
3. **Cleanup, per user in `to_process`:**
   - **Flex v4 User step** — `GET /v4/Instances/{InstanceSid}/Users?Username={email}` to find `flex_user_sid`, then `POST /Users/Deprovision`, then verify with a follow-up GET.
   - **TaskRouter Worker step (opt-in)** — `GET /v1/Workspaces/{WS}/Workers?FriendlyName={email}`, then `DELETE /Workers/{sid}`, then verify.
4. **Update state** — mode-specific:
   - Group mode: state = current IDs minus failed IDs (so failures retry).
   - App mode: state = TSV row (`id\tname\temail`) per currently-assigned user, plus rows for users whose cleanup failed (so they're seen again next run and retried).

**Flex username resolution.** Both modes read the Flex username from a configurable Entra field via `ENTRA_EMAIL_FIELD` (default `mail,userPrincipalName`, comma-separated priority list — first non-empty wins; array fields like `otherMails`/`proxyAddresses` use the first element; `SMTP:` prefixes are stripped).

**App-mode username snapshot.** In app mode, the resolved Flex username is written to the state file at snapshot time. This means users whose Entra account has been **fully deleted** (not just unassigned) still get cleaned up — the script uses the stored username instead of trying to fetch a user that no longer exists.

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

The app needs Application permissions on Microsoft Graph. Which ones depend on the trigger mode you'll use:

| Permission | Group mode | App mode | Why |
| --- | :-: | :-: | --- |
| `GroupMember.Read.All` | ✔ | | List the group's members |
| `User.Read.All` | ✔ | ✔ | Read `mail`, `proxyAddresses`, etc. on each user |
| `Application.Read.All` | | ✔ | Read the enterprise app's `appRoleAssignedTo` list |

If you plan to use both modes at different times, add all three.

Steps:

1. On the app page → **API permissions → Add a permission → Microsoft Graph → Application permissions** (**not** Delegated — client-credentials scripts only see Application scopes).
2. Add each permission you need (from the table above): search the name → check → **Add permissions**. Common combinations:
   - Group mode only: `GroupMember.Read.All` + `User.Read.All`
   - App mode only: `Application.Read.All` + `User.Read.All`
   - Both modes: all three
3. Back on the API permissions page, click **"Grant admin consent for &lt;your tenant&gt;"** → **Yes**.
5. Both rows should now show a green check under **Status**. Wait ~30 seconds for propagation.

If you don't see the "Grant admin consent" button, you don't have the directory role required — a tenant admin (Global Admin, Privileged Role Admin, or Cloud Application Admin) needs to click it.

### 1.5  Find the group's Object ID (group mode)

1. Left nav → **Groups → All groups**.
2. Click into the group you want to watch (create one first if needed — **New group → Security**).
3. On the group's Overview page, copy the **Object ID** (a GUID).
4. This is `ENTRA_GROUP_ID` in `.env`.

The group may contain nested groups, service principals, or devices — the script filters to *user* members only and safely ignores the rest.

### 1.6  Find the Enterprise App's Object ID (app mode)

**Watch out — three GUIDs are visible for the same app in the portal, and only one is correct.** The script needs the **servicePrincipal Object ID**, which is different from the Application (client) ID *and* from the App registration's Object ID.

1. Left nav → **Applications → Enterprise applications** (**not** App registrations — those are a different directory object).
2. Find and click the app whose assignments you want to watch (typically your Flex SSO app, but any Enterprise Application works).
3. Left nav on the app → **Properties**. Copy the **Object ID** from this page. Do **not** use the "Application ID" shown on the Overview page — that's the appId.
4. This is `ENTRA_ENTERPRISE_APP_SID` in `.env`.
5. Set `TRIGGER_MODE=app` in `.env`.

If you paste the wrong ID, both scripts detect the 404 and try to resolve your value as an appId, printing the correct servicePrincipal Object ID if it matches.

Only users assigned via **Users and groups** (as User principals, not through nested groups) are detected. Group-based assignments to the Enterprise App won't fire the unassign trigger for individual users when they leave one of those groups — the app just sees the group as still assigned.

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

Both scripts prompt for confirmation by default. On a normal run, the script gathers the affected users, prints a summary of who **will be Provisioned** or **De-Provisioned**, and then waits for you to type `yes` to proceed. Any other input aborts before any Flex mutation happens.

Flags (available on both `provision.sh` and `deprovision.sh`):

| Flag | Effect |
| --- | --- |
| `-n`, `--dry-run` | Print the summary and exit 0. Never prompts, never mutates. Overrides `--force`. For `deprovision.sh` the state file is also left untouched, so a subsequent run re-detects the same users. |
| `-f`, `--force` | Skip the confirmation prompt. **Required for non-interactive runs (cron, no TTY)** — otherwise the script exits 1 with an error. |
| `-h`, `--help` | Show usage and exit. |

### First run

Processes every current member of the group:

```bash
./deprovision.sh
# → First run — no state file. Processing all N current member(s).
# →
# → The following 3 user(s) will be De-Provisioned:
# →   1. Jane Doe <jane@contoso.com>
# →   2. ...
# →
# → Type "yes" to proceed: yes
# → Unassigned from enterprise app: Jane Doe <jane@contoso.com>
# →   ...
```

### Every subsequent run

Only members added since the last run get processed:

```bash
./deprovision.sh
# → No new users.
# or
# → The following 1 user(s) will be De-Provisioned:
# →   1. Jane Doe <jane@contoso.com>
# → Type "yes" to proceed: yes
# →   Flex SID: FUxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx — deprovisioning...
# →   Deprovisioned.
```

### Preview (dry-run)

Show what would happen without touching Flex or the state file:

```bash
./deprovision.sh --dry-run
./provision.sh -n
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
*/5 * * * * cd /opt/entraflex && ./deprovision.sh --force >> run.log 2>&1
```

The `--force` flag is required for non-interactive runs — without it, the script exits 1 rather than silently mutating Flex.

Adjust the interval per your needs. Ensure the process running cron has read/write access to `seen_users.txt` next to the script.

---

## Provisioning users into Flex

`provision.sh` walks the same Entra source (`TRIGGER_MODE=group` or `app`) and, for each user, either **skips** them (already in Flex) or **provisions** them via `POST /v4/Instances/{InstanceSid}/Users/Provision`.

The script is idempotent — it performs `GET /Users?Username=<email>` first and skips any user that already exists in Flex. There is no state file. Safe to run repeatedly.

### Body sent to `/Users/Provision`

```json
{
  "username":  "<email from ENTRA_EMAIL_FIELD>",
  "email":     "<same>",
  "full_name": "<displayName from Entra, falls back to email>",
  "roles":     ["agent"],
  "worker":    {}
}
```

### Provisioning-specific env vars (optional)

```dotenv
# Roles assigned to provisioned users. Comma-separated.
# Valid values: agent, supervisor, admin.  Default: agent
FLEX_ROLES=agent,supervisor

# TaskRouter Worker attributes to attach at provision time, as a JSON string.
# Sent verbatim as the "worker" field. Default: {}
FLEX_WORKER_JSON={"attributes":{"channel.voice.capacity":10}}
```

### Running

```bash
./provision.sh
# → The following 1 user(s) will be Provisioned:
# →   1. Jane Doe <jane@contoso.com>
# →
# → Also: 1 already provisioned (will skip), 0 with no email (will skip), 0 lookup failure(s).
# → Type "yes" to proceed: yes
# → User: Jane Doe <jane@contoso.com>
# →   POST https://flex-api.twilio.com/v4/Instances/GO.../Users/Provision
# →   Body: {"username":"jane@contoso.com","email":"jane@contoso.com","full_name":"Jane Doe","roles":["agent"],"worker":{}}
# →   Response: HTTP 201
# →   Provisioned. Flex SID: FU...
# → Summary: 1 provisioned, 1 skipped, 0 failed.
```

Same auth requirements as `deprovision.sh` (Graph permissions and Twilio API key) — nothing extra to configure to run it.

### Round-tripping with `deprovision.sh`

The natural symmetric setup uses **app mode** on both sides — one Entra Enterprise App becomes the source of truth for Flex access:

```dotenv
TRIGGER_MODE=app
ENTRA_ENTERPRISE_APP_SID=<service principal Object ID>
```

**Recommended workflow:**

1. Assign the user in Entra → Enterprise applications → your app → Users and groups.
2. Run `./provision.sh` — creates the Flex User (and TaskRouter Worker on next Flex login) and **writes the user's ID/name/email to `assigned_users.tsv`**.
3. Later, unassign the user in Entra.
4. Run `./deprovision.sh` — sees the user in `assigned_users.tsv` but not in the current `appRoleAssignedTo` fetch, and removes them from Flex.

**Why provision.sh writes the state file too:** step 4 needs a prior snapshot of "who was assigned" to detect anyone who has since been unassigned. If only `deprovision.sh` maintained state, a user who was assigned → provisioned → unassigned before `deprovision.sh` ever ran would slip through — deprovision's first run would baseline an already-empty assignee list and do nothing. Having `provision.sh` update the same TSV closes that gap.

Both scripts safely overwrite `assigned_users.tsv` with each run's fetch view of currently-assigned users. Running them in the same cron interval also works:

```bash
# e.g. every 5 minutes — --force skips the confirmation prompt (required in cron)
*/5 * * * * cd /opt/entraflex && ./provision.sh --force >> provision.log 2>&1
*/5 * * * * cd /opt/entraflex && ./deprovision.sh --force >> deprovision.log 2>&1
```

**Group mode note.** `provision.sh` treats the group as an "allow list" (provision every current member); `deprovision.sh` treats the group as a "kick list" (act on users **added** to the group). If you want a group to work as an access list end-to-end, prefer app mode. `provision.sh` only writes the shared TSV in app mode.

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
| `Graph group-members request failed: HTTP 403 Authorization_RequestDenied` | Group mode: app is missing `GroupMember.Read.All` (Application) with admin consent. See §1.4. |
| `Graph appRoleAssignedTo request failed: HTTP 403 Authorization_RequestDenied` | App mode: app is missing `Application.Read.All` (Application) with admin consent. See §1.4. |
| `/users/{id} failed: HTTP 403` (in DEBUG mode or in app mode) | App is missing `User.Read.All` (Application) with admin consent. See §1.4. |
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
- The Entra client secret gives the app application-level access to whichever Graph permissions you've granted (`GroupMember.Read.All`, `User.Read.All`, and/or `Application.Read.All`) tenant-wide. Rotate it periodically per your organization's policy.
- The script does not log secrets, but `DEBUG=1` prints full user records including email addresses — take care where you redirect the output.

---

## Files in this repo

| File | Purpose |
| --- | --- |
| `provision.sh` | Creates Flex Users for people currently in the Entra source (idempotent). |
| `deprovision.sh` | Removes Flex Users (v4) and optionally TaskRouter Workers when Entra removes/unassigns them. |
| `.env.example` | Template for the `.env` you create locally. |
| `.gitignore` | Excludes `.env`, `seen_users.txt`, and other local artifacts. |
| `README.md` | This file. |
