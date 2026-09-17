#!/usr/bin/env python3
"""
Check an Entra ID group for new members and deprovision each from Twilio Flex.

Required environment variables:
  TENANT_ID          Entra tenant (directory) ID
  CLIENT_ID          App registration client ID
  CLIENT_SECRET      App registration client secret
  ENTRA_GROUP_ID     Object ID of the group to watch
  TWILIO_API_KEY     Twilio API Key SID (SK...)
  TWILIO_API_SECRET  Twilio API Key secret
  FLEX_INSTANCE_SID  Flex Instance SID (GO...)

Graph API permission required on the app registration:
  GroupMember.Read.All (application, admin-consented)

State: seen_users.json is written next to this script. First run records the
current members as the baseline and takes no action.
"""

import json
import os
import sys
from pathlib import Path

import requests

STATE_FILE = Path(__file__).with_name("seen_users.json")
GRAPH_BASE = "https://graph.microsoft.com/v1.0"


def env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        sys.exit(f"Missing required env var: {name}")
    return value


def graph_token(tenant_id: str, client_id: str, client_secret: str) -> str:
    r = requests.post(
        f"https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/token",
        data={
            "client_id": client_id,
            "client_secret": client_secret,
            "scope": "https://graph.microsoft.com/.default",
            "grant_type": "client_credentials",
        },
        timeout=30,
    )
    r.raise_for_status()
    return r.json()["access_token"]


def group_members(token: str, group_id: str):
    url = f"{GRAPH_BASE}/groups/{group_id}/members?$select=id,mail,userPrincipalName,displayName"
    headers = {"Authorization": f"Bearer {token}"}
    while url:
        r = requests.get(url, headers=headers, timeout=30)
        r.raise_for_status()
        payload = r.json()
        for member in payload.get("value", []):
            yield member
        url = payload.get("@odata.nextLink")


def flex_user_sid(flex_base: str, auth, email: str) -> str | None:
    r = requests.get(
        f"{flex_base}/Users",
        params={"Username": email},
        auth=auth,
        timeout=30,
    )
    r.raise_for_status()
    body = r.json()
    users = body.get("users") or body.get("Users") or []
    if not users:
        return None
    user = users[0]
    return user.get("flex_user_sid") or user.get("sid")


def deprovision(flex_base: str, auth, sid: str) -> dict:
    r = requests.post(
        f"{flex_base}/Users/Deprovision",
        json={"flex_user_sid": sid},
        auth=auth,
        timeout=30,
    )
    r.raise_for_status()
    return r.json() if r.content else {}


def load_seen() -> set[str] | None:
    if not STATE_FILE.exists():
        return None
    return set(json.loads(STATE_FILE.read_text()))


def save_seen(ids: set[str]) -> None:
    STATE_FILE.write_text(json.dumps(sorted(ids), indent=2))


def main() -> None:
    tenant_id = env("TENANT_ID")
    client_id = env("CLIENT_ID")
    client_secret = env("CLIENT_SECRET")
    group_id = env("ENTRA_GROUP_ID")
    twilio_key = env("TWILIO_API_KEY")
    twilio_secret = env("TWILIO_API_SECRET")
    instance_sid = env("FLEX_INSTANCE_SID")

    flex_base = f"https://flex-api.twilio.com/v4/Instances/{instance_sid}"
    twilio_auth = (twilio_key, twilio_secret)

    token = graph_token(tenant_id, client_id, client_secret)
    members = list(group_members(token, group_id))
    current_ids = {m["id"] for m in members}

    seen = load_seen()
    if seen is None:
        save_seen(current_ids)
        print(f"Baseline recorded: {len(current_ids)} member(s). No action taken.")
        return

    new_ids = current_ids - seen
    if not new_ids:
        print("No new users.")
        save_seen(current_ids)
        return

    by_id = {m["id"]: m for m in members}
    failed: set[str] = set()

    for user_id in sorted(new_ids):
        member = by_id[user_id]
        email = member.get("mail") or member.get("userPrincipalName")
        name = member.get("displayName") or user_id
        if not email:
            print(f"[skip] {name}: no mail or userPrincipalName")
            continue

        print(f"New user: {name} <{email}>")
        try:
            sid = flex_user_sid(flex_base, twilio_auth, email)
        except requests.HTTPError as e:
            print(f"  Flex lookup failed: {e.response.status_code} {e.response.text}")
            failed.add(user_id)
            continue

        if not sid:
            print(f"  No Flex user for {email} — nothing to deprovision")
            continue

        print(f"  Flex SID: {sid} — deprovisioning...")
        try:
            deprovision(flex_base, twilio_auth, sid)
            print("  Deprovisioned.")
        except requests.HTTPError as e:
            print(f"  Deprovision failed: {e.response.status_code} {e.response.text}")
            failed.add(user_id)

    save_seen(current_ids - failed)
    if failed:
        print(f"{len(failed)} user(s) failed and will be retried next run.")


if __name__ == "__main__":
    main()
