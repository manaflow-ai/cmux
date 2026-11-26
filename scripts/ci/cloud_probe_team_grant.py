#!/usr/bin/env python3
"""Give the production probe's shared team `paused-claim-probe` the operator Cloud plan grant `cmuxVmPlan: "pro"`.

cmuxterm-hq's production paused-claim probe (build-fleet/pr_capture/platform_probe.py, `Owner.named_team`) creates
its machines in one shared team, `paused-claim-probe`, so its spare is never claimed or kept warm by the other jobs
signed in as the same account. A shared team's Cloud grant is its own Stack team record's
client_read_only_metadata.cmuxVmPlan (cmux backend stack-server.ts getTeam, read by TeamDO.cloudVmPlan for
cmux-platform's Entitlements readGrant); the account's own grant does not reach it, so without this every
cloud.machine.create there answered cloud.plan.required (cmuxterm-hq run 45737788257, job 139635116929).

This touches exactly one team and refuses everything else, before any write:
- the Stack project must be production (PRODUCTION_PROJECT_ID);
- the team is found through the production probe test accounts (emails matching PROBE_EMAIL, the
  `cmux-cloud-capture…@manaflow.dev` test accounts; no person's account matches), among their teams;
- its display name must be TEAM_NAME and its cmux id (cmux-platform auth/Ids.ts stackTeamIdFor) must be TEAM_ID;
- every member of the team must be such a test account.
Only `cmuxVmPlan` changes; the team's other metadata is kept. The grant is read back. Rerunning is harmless.

Stack's response bodies are never echoed (they hold account data), only status codes and the fields named here.
Runs in .github/workflows/cloud-probe-team-grant.yml (environment cloud-vm-canary: production Stack keys, main only).
Standard library only.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

# The production Stack project (cmux-platform wrangler.jsonc production STACK_PROJECT_ID). Any other refuses.
PRODUCTION_PROJECT_ID = "9790718f-14cd-4f7e-824d-eaf527a82b82"
STACK_API = "https://api.stack-auth.com/api/v1"
TEAM_NAME = "paused-claim-probe"
TEAM_ID = "team_0f8b004051872de73537"
PLAN_KEY, PLAN = "cmuxVmPlan", "pro"
# The test accounts the probe signs in as (cloud_capture_provision.py GRANT_ONLY_EMAIL): never a person's.
PROBE_EMAIL = re.compile(r"cmux-cloud-capture(-[a-z0-9]+)*@manaflow\.dev")
PROBE_QUERY = "cmux-cloud-capture"
REQUEST_SECONDS = 30


class GrantError(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Never follow a redirect: it would carry the server key to another URL."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


OPENER = urllib.request.build_opener(NoRedirect)


def http(method, url, headers, body, timeout=REQUEST_SECONDS):
    """One HTTPS request to Stack's API host only, no redirects: (status, headers, parsed JSON or None)."""
    parts = urllib.parse.urlsplit(url)
    if parts.scheme != "https" or parts.hostname != urllib.parse.urlsplit(STACK_API).hostname:
        raise GrantError("refusing a request outside Stack's API host")
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with OPENER.open(request, timeout=timeout) as response:
            status, reply_headers, text = response.status, dict(response.headers), response.read()
    except urllib.error.HTTPError as error:
        status, reply_headers, text = error.code, dict(error.headers or {}), error.read()
    try:
        parsed = json.loads(text) if text else None
    except ValueError:
        parsed = None
    return status, {k.lower(): v for k, v in reply_headers.items()}, parsed


def cmux_team_id(project, stack_team):
    """cmux-platform auth/Ids.ts stackTeamIdFor: the cmux id of the Stack (shared) team STACK_TEAM."""
    return f"team_{hashlib.sha256(f'stack-team:{project}:{stack_team}'.encode()).hexdigest()[:20]}"


class Stack:
    def __init__(self, project_id, server_key, transport=http):
        if project_id != PRODUCTION_PROJECT_ID:
            raise GrantError("the Stack project is not the production project; refusing to touch it")
        if not server_key:
            raise GrantError("STACK_SECRET_SERVER_KEY is empty")
        self.project_id, self.server_key, self.transport = project_id, server_key, transport

    def server(self, method, path, body=None):
        headers = {"content-type": "application/json", "x-stack-access-type": "server",
                   "x-stack-project-id": self.project_id, "x-stack-secret-server-key": self.server_key}
        status, reply_headers, parsed = self.transport(method, STACK_API + path, headers, body)
        if status not in (200, 201):
            known = reply_headers.get("x-stack-known-error", "")
            raise GrantError(f"Stack {method} {path.split('?')[0]} answered HTTP {status}" + (f" ({known})" if known else ""))
        return parsed if isinstance(parsed, dict) else {}

    def items(self, path):
        items = self.server("GET", path).get("items")
        if not isinstance(items, list):
            raise GrantError(f"Stack GET {path.split('?')[0]} returned no items list")
        return [i for i in items if isinstance(i, dict)]


def is_probe(user):
    return bool(PROBE_EMAIL.fullmatch(str(user.get("primary_email") or "").lower()))


def find_team(stack):
    """The one Stack team that is the probe's TEAM_NAME with cmux id TEAM_ID, among the probe accounts' teams."""
    probes = [u for u in stack.items(f"/users?query={urllib.parse.quote(PROBE_QUERY)}&limit=100")
              if is_probe(u) and isinstance(u.get("id"), str)]
    if not probes:
        raise GrantError("no production probe test account found")
    hits = {}
    for user in probes:
        for team in stack.items(f"/teams?user_id={urllib.parse.quote(user['id'])}"):
            tid = team.get("id")
            if isinstance(tid, str) and team.get("display_name") == TEAM_NAME and cmux_team_id(stack.project_id, tid) == TEAM_ID:
                hits[tid] = team
    if len(hits) != 1:
        raise GrantError(f"{len(hits)} probe teams named {TEAM_NAME!r} have the cmux id {TEAM_ID}; want exactly one")
    return next(iter(hits.values()))


def grant(stack, log=print):
    team = find_team(stack)
    tid = team["id"]
    members = stack.items(f"/users?team_id={urllib.parse.quote(tid)}&limit=100")
    if not members or not all(is_probe(m) for m in members):
        raise GrantError(f"the team {TEAM_NAME!r} has a member that is not a probe test account; refusing")
    record = stack.server("GET", f"/teams/{urllib.parse.quote(tid)}")
    if record.get("display_name") != TEAM_NAME:
        raise GrantError("the team's record does not carry the expected name")
    metadata = record.get("client_read_only_metadata")
    metadata = dict(metadata) if isinstance(metadata, dict) else {}
    before = metadata.get(PLAN_KEY)
    if before != PLAN:
        metadata[PLAN_KEY] = PLAN
        stack.server("PATCH", f"/teams/{urllib.parse.quote(tid)}", {"client_read_only_metadata": metadata})
    after = stack.server("GET", f"/teams/{urllib.parse.quote(tid)}").get("client_read_only_metadata")
    read = after.get(PLAN_KEY) if isinstance(after, dict) else None
    if read != PLAN:
        raise GrantError(f"the team's {PLAN_KEY} did not read back as {PLAN!r}")
    log(f"team {TEAM_NAME} ({TEAM_ID}, {len(members)} probe member(s)): {PLAN_KEY} was {before!r}, "
        f"reads back {read!r}" + ("" if before != PLAN else " (unchanged)"))
    return before


def main():
    try:
        grant(Stack(os.environ.get("NEXT_PUBLIC_STACK_PROJECT_ID", ""), os.environ.get("STACK_SECRET_SERVER_KEY", "")))
    except GrantError as error:
        print(f"::error::probe team grant: {error}", flush=True)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
