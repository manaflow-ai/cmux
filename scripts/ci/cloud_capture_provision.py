#!/usr/bin/env python3
"""Provision the Cloud capture test account and seal its credential for the capture environment.

The team's Cloud capture runs (a signed-in DEV build that creates, pauses and resumes a throwaway
Cloud machine) sign in as one dedicated test account on the STAGING Stack project. This makes that
account without anyone holding its password:

1. Find the account by its fixed email with the staging Stack server key, or create it.
2. Set a fresh random password and the operator plan grant `cmuxVmPlan: "pro"` (the key Cloud's
   entitlements read; other metadata on the account is kept).
3. Check the password signs in (client API) and the grant reads back.
4. Seal the email and the password to the capture environment's GitHub public key (pinned below,
   sealed_secrets.py) and write only that ciphertext bundle.

The password is generated here, masked in the job log the moment it exists, sent only to Stack over
TLS, sealed, and dropped. It is never printed, written to disk, put in an environment variable or an
argument. Every run is a rotation: the old password stops working, so no other copy is worth keeping.
Stack's response bodies are never echoed (they hold account data), only status codes.

`--grant-only EMAIL` instead gives one existing capture test account (an email matching
GRANT_ONLY_EMAIL: `cmux-cloud-capture…@manaflow.dev`, such as the no-team owner account) the same operator plan
grant and a verified primary email, and touches nothing else: no password, no seal, no bundle. Without the plan, a
staging account whose record carries a plan that is not paid is restricted and gets no Cloud machines, the stub
plan included. Without the verified email, a team invitation sent to the account cannot be accepted (cmux web
teams/received.ts answers email_mismatch), so HQ's team invite readback could never join it to a team. The account
made above is created verified; this does the same for one made some other way.

`--target journey` does the same for the Cloud journey's own staging account, sealed to this repository's
cmux-next-vm-image-dev environment as CMUX_DOGFOOD_STACK_EMAIL and _PASSWORD (TARGETS below).

`--target journey-guest` makes a second staging account (cmux-cloud-capture-guest@manaflow.dev, display name
"Capture Guest", a profile image), sealed to the same cmux-next-vm-image-dev environment as
CMUX_DOGFOOD_GUEST_STACK_EMAIL and _PASSWORD: the other side of a two-account test such as a chat share (the journey
account owns the chat, the guest is invited to it; the share room refuses an unverified email, and this account is
created verified). cloud-chat-proof.yml's signin job mints its session with `signin_account: guest`.

`--target production` makes the production test account (cmux-cloud-capture-prod@manaflow.dev) in the
PRODUCTION Stack project, with the same plan grant, sealed to cmuxterm-hq's cloud-capture environment as
CLOUD_PROBE_PRODUCTION_STACK_EMAIL and _PASSWORD: the hourly production Cloud chat probe signs in as it
(cmuxterm-hq synthetic-probes.yml app-chat-production). It runs in environment cloud-vm-production, whose server
key belongs to that project; each target names the one project it may touch. The run also prints the account's
Stack user id (not a secret), which a GitHub OIDC session trust row pins (hq#7076).

`--target production-team` makes a second production account (cmux-cloud-capture-prod-team@manaflow.dev) the same
way, sealed to cmuxterm-hq's cloud-capture environment as CLOUD_PROBE_PRODUCTION_TEAM_STACK_EMAIL and _PASSWORD: the
probe's shared-team row (cmuxterm-hq cloud-chat-replies-production-team), which joins a shared team through the
platform's own invitation API with its own session. The probe account above must stay in no shared team. This
account is also made a member of the company team "cmux" (COMPANY_TEAM_ID, a production Stack team) with the server
key: the membership is added when it is missing (POST /team-memberships/TEAM/USER) and read back from the account's
team list (GET /teams?user_id=USER); a read-back without the team fails the run before anything is sealed. Nobody
invites it by hand, and no person's account stands in for it (a person's account would put the capture runs'
machines on that person's team).

`--target production-team --team-only` does only that membership step for the existing account: no password
change, nothing sealed, and a missing account is never created.

`--probe-teams N` (target capture only) makes sure the staging capture account (cmux-cloud-capture@manaflow.dev) is
in N probe teams on the staging Stack project, the one cmux-api-development and cmux-platform-development sign in to,
so a concurrent-create probe (cmuxterm-hq build-fleet/pr_capture/platform_probe.py, spec "teams") can spread its
creates over its own team and N more: 3x10 needs 2, 5x10 needs 4. Each probe team is named "cmux probe team K (test
accounts only)" and carries the server-only marker PROBE_TEAM_KEY = {"slot": K}, which is how a rerun finds it among
the account's teams (GET /teams?user_id=USER) instead of making another. A missing slot is made with POST /teams (no
creator_user_id, so Stack grants no creator defaults) and the account joins it as a plain member
(POST /team-memberships/TEAM/USER); a team the account could not join (an HTTP refusal or a transport error
such as a timeout) is deleted again. Every probe team then gets the
operator grant `cmuxVmPlan: "team"` on the team's own record (PATCH /teams/TEAM, other metadata kept): development
reads a shared team's plan from the team record (cmux-api cloud-vm-plan.ts), and without a paid grant the team gets
the stub plan, at most 5 machines active and 20 held (cmux-platform Plan.ts STUB_PLAN), so 10 parallel creates in one
team would be refused past the fifth. With the grant (development meters machines) the counts are uncapped; the
per-team CLOUD_CREATE_PER_HOUR (20 on development) still applies and is not changed here. A probe team holds only the
capture account: one whose members read back as anything else (a person added by hand, say) fails the run before the
grant, and nothing in it is changed. No password changes, nothing is sealed, and a missing account is never created.
Slots above N are left as they are.

`--target journey-production` does the same for the production Cloud journey's own account
(cmux-cloud-capture-journey-prod@manaflow.dev), sealed to this repository's cmux-next-cloud-journey environment as
CMUX_DOGFOOD_STACK_EMAIL and _PASSWORD (cloud-journey-prod.yml, backend.yml journey-production).

`--target platform-staging` and `--target platform-production` make cmux-platform's own journey accounts (staging and
production projects), sealed to manaflow-ai/cmux-platform's repository secrets (no environment: its ci.yml job has
none) as CMUX_DOGFOOD_STACK_* and CMUX_JOURNEY_PROD_STACK_*, which its deploy journeys read.

Runs in .github/workflows/cloud-capture-provision.yml (environment cloud-vm-staging). The bundle is
stored with `python3 scripts/ci/sealed_secrets.py put BUNDLE`; docs/ci-sealed-secrets.md.
Standard library only, plus the system libsodium.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import sys
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import sealed_secrets  # noqa: E402

# The staging Stack project every DEV build signs in to (public: it ships in DEV builds). The server
# key must belong to this project; any other project id refuses before a request is made.
STAGING_PROJECT_ID = "454ecd03-1db2-4050-845e-4ce5b0cd9895"
# The production Stack project the shipped app (cmux NIGHTLY and release) signs in to (public: it ships in every
# release build; cmux environment cloud-vm-production's NEXT_PUBLIC_STACK_PROJECT_ID).
PRODUCTION_PROJECT_ID = "9790718f-14cd-4f7e-824d-eaf527a82b82"
STACK_API = "https://api.stack-auth.com/api/v1"
PLAN_KEY, PLAN = "cmuxVmPlan", "pro"
# The company team "cmux" in the production Stack project (CmuxNextCrashReporting CrashReportIdentity.cmuxTeamID).
COMPANY_TEAM_ID = "d13acd51-c77d-438a-9610-5369455e2a2f"


class Target:
    """One staging test account and where its credential is sealed. A rotated GitHub key changes key_id;
    `put` then refuses the bundle and the pin here is updated. GitHub gives both environments below the same
    key_id with different key bytes (read from `.../environments/ENV/secrets/public-key` on 2026-11-04);
    `put` checks both against the live key."""

    def __init__(self, email, display_name, repo, environment, key_id, key, email_secret, password_secret,
                 project=STAGING_PROJECT_ID, profile_image_url=None, team_id=None):
        self.email, self.display_name, self.project = email, display_name, project
        # The Stack team the account is made a member of on every run; None keeps it out of every team. An account
        # with a team shares that team's machines with its people, so it may never take a carrier fault: cmux-tui
        # carrier/fault.rs PROBE_ACCOUNTS takes only the targets without one (its test reads this argument).
        self.team_id = team_id
        # Set on create and on every rotation when given, so a person looking at a two-account test tells them apart.
        self.profile_image_url = profile_image_url
        self.repo, self.environment, self.key_id, self.key = repo, environment, key_id, key
        self.email_secret, self.password_secret = email_secret, password_secret


TARGETS = {
    # The team's Cloud capture runs: the capture environment of the private infrastructure repository.
    "capture": Target("cmux-cloud-capture@manaflow.dev", "cmux cloud capture", "manaflow-ai/cmuxterm-hq",
                      "cloud-capture", "3380204578043523366", "jjGF/Nq5EeX9Ye2kCKwzDsZaAJETgKx/H8cQgQPv9AY=",
                      "CLOUD_CAPTURE_STACK_EMAIL", "CLOUD_CAPTURE_STACK_PASSWORD"),
    # The headless Cloud journey's staging smoke (backend.yml journey-staging) and cloud-chat-proof.yml: both run
    # in this repository's cmux-next-vm-image-dev environment and read the staging pair as CMUX_DOGFOOD_STACK_*.
    # Environment secrets take precedence over the repository's own pair (the production test account), so only
    # jobs in that environment see this one.
    "journey": Target("cmux-cloud-capture-journey@manaflow.dev", "cmux cloud journey", "manaflow-ai/cmux",
                      "cmux-next-vm-image-dev", "3380204578043523366", "wOq7reXDAHystKwvJikDgeR+KKcU8k+s8gV/E0CHzVk=",
                      "CMUX_DOGFOOD_STACK_EMAIL", "CMUX_DOGFOOD_STACK_PASSWORD"),
    # The journey account's guest: a second staging account for two-account tests (a chat share: one owner, one
    # guest), in the same environment under its own secret names, so the journey's pair is never shadowed.
    "journey-guest": Target("cmux-cloud-capture-guest@manaflow.dev", "Capture Guest", "manaflow-ai/cmux",
                            "cmux-next-vm-image-dev", "3380204578043523366",
                            "wOq7reXDAHystKwvJikDgeR+KKcU8k+s8gV/E0CHzVk=",
                            "CMUX_DOGFOOD_GUEST_STACK_EMAIL", "CMUX_DOGFOOD_GUEST_STACK_PASSWORD",
                            profile_image_url="https://cmux.com/icon.png"),
    # The hourly production Cloud chat probe (cmuxterm-hq synthetic-probes.yml app-chat-production): the shipped
    # NIGHTLY app signed in to production, `cmux cloud start-chat --wait`, in its personal scope.
    "production": Target("cmux-cloud-capture-prod@manaflow.dev", "cmux cloud probe (production)",
                         "manaflow-ai/cmuxterm-hq", "cloud-capture", "3380204578043523366",
                         "jjGF/Nq5EeX9Ye2kCKwzDsZaAJETgKx/H8cQgQPv9AY=",
                         "CLOUD_PROBE_PRODUCTION_STACK_EMAIL", "CLOUD_PROBE_PRODUCTION_STACK_PASSWORD",
                         project=PRODUCTION_PROJECT_ID),
    # The production probe's shared-team row (cmuxterm-hq synthetic-probes.yml app-chat-production,
    # cloud-chat-replies-production-team): a second production account that joins a shared team, since the probe
    # account above must stay in none. Sealed beside it in cmuxterm-hq cloud-capture under its own names.
    "production-team": Target("cmux-cloud-capture-prod-team@manaflow.dev", "cmux cloud probe (production, team)",
                              "manaflow-ai/cmuxterm-hq", "cloud-capture", "3380204578043523366",
                              "jjGF/Nq5EeX9Ye2kCKwzDsZaAJETgKx/H8cQgQPv9AY=",
                              "CLOUD_PROBE_PRODUCTION_TEAM_STACK_EMAIL", "CLOUD_PROBE_PRODUCTION_TEAM_STACK_PASSWORD",
                              project=PRODUCTION_PROJECT_ID, team_id=COMPANY_TEAM_ID),
    # The production Cloud journey (cloud-journey-prod.yml hourly, backend.yml journey-production): both run in this
    # repository's cmux-next-cloud-journey environment and read the production pair as CMUX_DOGFOOD_STACK_*, which
    # shadows the repository's dev pair (production refuses that one with EMAIL_PASSWORD_MISMATCH). Its own
    # account, so rotating it never signs the probe's account out.
    "journey-production": Target("cmux-cloud-capture-journey-prod@manaflow.dev", "cmux cloud journey (production)",
                                 "manaflow-ai/cmux", "cmux-next-cloud-journey", "3380204578043523366",
                                 "phe+RfKRmKGeO9B3rCULM4jdTzJX8aS7LbvGrIoTFWM=",
                                 "CMUX_DOGFOOD_STACK_EMAIL", "CMUX_DOGFOOD_STACK_PASSWORD",
                                 project=PRODUCTION_PROJECT_ID),
    # cmux-platform's deploys (its ci.yml job `ci`, no environment) journey after "Deploy staging" and "Deploy
    # production" and read these from that repository's own Actions secrets (environment None). Their own accounts:
    # rotating cmux's journey accounts would sign out the copies in cmux (cmuxterm-hq#8293, goal cloud-deploy-checked).
    "platform-staging": Target("cmux-cloud-capture-platform@manaflow.dev", "cmux cloud journey (cmux-platform)",
                               "manaflow-ai/cmux-platform", None, "3380204578043523366",
                               "EzR9/8XfEWpKYAO5ulRMqEaTWp1BuVXmv7i36gCaCwA=",
                               "CMUX_DOGFOOD_STACK_EMAIL", "CMUX_DOGFOOD_STACK_PASSWORD"),
    "platform-production": Target("cmux-cloud-capture-platform-prod@manaflow.dev",
                                  "cmux cloud journey (cmux-platform, production)",
                                  "manaflow-ai/cmux-platform", None, "3380204578043523366",
                                  "EzR9/8XfEWpKYAO5ulRMqEaTWp1BuVXmv7i36gCaCwA=",
                                  "CMUX_JOURNEY_PROD_STACK_EMAIL", "CMUX_JOURNEY_PROD_STACK_PASSWORD",
                                  project=PRODUCTION_PROJECT_ID),
}
CAPTURE = TARGETS["capture"]
# --probe-teams: the server-only marker on each probe team ({"slot": K}), the grant it gets, and how many there may be
# (cmuxterm-hq platform_probe.py TEAMS_MAX is 10 teams with the account's own; the default makes 5x10 possible).
PROBE_TEAM_KEY = "cmuxProbeTeam"
PROBE_TEAM_PLAN = "team"
PROBE_TEAMS_MAX = 9
PROBE_TEAMS_DEFAULT = 4
# The only target whose account --probe-teams puts in probe teams, and the only accounts a probe team may hold.
PROBE_TEAM_TARGET = "capture"


def probe_team_name(slot):
    return f"cmux probe team {slot} (test accounts only)"
EMAIL = CAPTURE.email
REQUEST_SECONDS = 30
# The only accounts --grant-only touches: the staging capture test accounts, never a person's.
GRANT_ONLY_EMAIL = re.compile(r"cmux-cloud-capture(-[a-z0-9]+)*@manaflow\.dev")


class ProvisionError(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Never follow a redirect: it would carry the server key (or the password) to another URL."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


OPENER = urllib.request.build_opener(NoRedirect)


def http(method, url, headers, body, timeout=REQUEST_SECONDS):
    """One HTTPS request to Stack's API host only, no redirects; (status, headers, parsed JSON or None).
    Never raises for an HTTP status (a 3xx comes back as its status)."""
    parts = urllib.parse.urlsplit(url)
    if parts.scheme != "https" or parts.hostname != urllib.parse.urlsplit(STACK_API).hostname:
        raise ProvisionError("refusing a request outside Stack's API host")
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


class Stack:
    def __init__(self, project_id, server_key, client_key, transport=http, expected_project=STAGING_PROJECT_ID):
        if project_id != expected_project:
            raise ProvisionError("the Stack project is not the target's project; refusing to touch it")
        if not server_key:
            raise ProvisionError("STACK_SECRET_SERVER_KEY is empty")
        if not client_key:
            raise ProvisionError("NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY is empty")
        self.project_id, self.server_key, self.client_key, self.transport = project_id, server_key, client_key, transport

    def server(self, method, path, body=None, ok=(200, 201), ok_known=()):
        """OK_KNOWN: Stack known-error codes that count as success (answered with an empty body)."""
        headers = {"content-type": "application/json", "x-stack-access-type": "server",
                   "x-stack-project-id": self.project_id, "x-stack-secret-server-key": self.server_key}
        status, reply_headers, parsed = self.transport(method, STACK_API + path, headers, body)
        if status not in ok:
            known = reply_headers.get("x-stack-known-error", "")
            if known and known in ok_known:
                return {}
            raise ProvisionError(f"Stack {method} {path.split('?')[0]} answered HTTP {status}"
                                 + (f" ({known})" if known else ""))
        return parsed or {}

    def find(self, email):
        """The one user whose primary email is EMAIL, or None. Two would be ambiguous: refuse."""
        answer = self.server("GET", f"/users?query={urllib.parse.quote(email)}&limit=100")
        items = answer.get("items")
        if not isinstance(items, list):
            raise ProvisionError("Stack's user search returned no items list")
        matches = [u for u in items if isinstance(u, dict)
                   and str(u.get("primary_email") or "").lower() == email.lower()]
        if len(matches) > 1:
            raise ProvisionError(f"{len(matches)} staging users have that email; refusing to pick one")
        return matches[0] if matches else None

    def create(self, email, password, display_name=CAPTURE.display_name, profile_image_url=None):
        body = {"primary_email": email, "primary_email_verified": True, "primary_email_auth_enabled": True,
                "password": password, "display_name": display_name, "client_read_only_metadata": {PLAN_KEY: PLAN}}
        if profile_image_url:
            body["profile_image_url"] = profile_image_url
        user = self.server("POST", "/users", body)
        if not user.get("id"):
            raise ProvisionError("Stack created the user but returned no id")
        return user

    def rotate(self, user, password, profile=None):
        """New password, the plan grant and a verified email; PROFILE (display_name, profile_image_url) when given."""
        metadata = user.get("client_read_only_metadata")
        metadata = dict(metadata) if isinstance(metadata, dict) else {}
        metadata[PLAN_KEY] = PLAN
        body = {"password": password, "primary_email_verified": True, "primary_email_auth_enabled": True,
                "client_read_only_metadata": metadata}
        body.update(profile or {})
        self.server("PATCH", f"/users/{urllib.parse.quote(user['id'])}", body)

    def grant(self, user):
        """Sets the operator plan grant and marks the primary email verified, keeping the account's other metadata
        and its password."""
        metadata = user.get("client_read_only_metadata")
        metadata = dict(metadata) if isinstance(metadata, dict) else {}
        metadata[PLAN_KEY] = PLAN
        self.server("PATCH", f"/users/{urllib.parse.quote(user['id'])}",
                    {"client_read_only_metadata": metadata, "primary_email_verified": True})

    def read(self, user_id):
        return self.server("GET", f"/users/{urllib.parse.quote(user_id)}")

    def plan(self, user_id):
        metadata = self.read(user_id).get("client_read_only_metadata")
        return metadata.get(PLAN_KEY) if isinstance(metadata, dict) else None

    def user_teams(self, user_id):
        """The Stack teams USER_ID is a member of now, as Stack's server API answers them (metadata included)."""
        items = self.server("GET", f"/teams?user_id={urllib.parse.quote(user_id)}").get("items")
        if not isinstance(items, list):
            raise ProvisionError("Stack's team list returned no items list")
        return [t for t in items if isinstance(t, dict) and t.get("id")]

    def teams(self, user_id):
        """The ids of the Stack teams USER_ID is a member of now."""
        return {str(t.get("id")) for t in self.user_teams(user_id)}

    def team(self, team_id):
        return self.server("GET", f"/teams/{urllib.parse.quote(team_id)}")

    def create_team(self, display_name, server_metadata):
        """A new team with no members: no creator_user_id, so nobody gets Stack's creator defaults."""
        team = self.server("POST", "/teams", {"display_name": display_name, "server_metadata": server_metadata})
        if not team.get("id"):
            raise ProvisionError("Stack created the team but returned no id")
        return team

    def delete_team(self, team_id):
        self.server("DELETE", f"/teams/{urllib.parse.quote(team_id)}", ok=(200, 204))

    def team_members(self, team_id):
        """The user ids of TEAM_ID's members (/team-member-profiles: /team-memberships only adds and removes one)."""
        answer = self.server("GET", f"/team-member-profiles?team_id={urllib.parse.quote(team_id)}")
        items = answer.get("items")
        pagination = answer.get("pagination")
        # A probe team has one member; a list that pages is not one, and is never read in part.
        if not isinstance(items, list) or (isinstance(pagination, dict) and pagination.get("next_cursor")):
            raise ProvisionError("Stack's team member list returned no complete items list")
        ids = [m.get("user_id") for m in items if isinstance(m, dict)]
        if len(ids) != len(items) or not all(isinstance(i, str) and i for i in ids):
            raise ProvisionError("Stack's team member list has a member without a user id")
        return set(ids)

    def grant_team(self, team):
        """Sets the operator plan grant on TEAM's own record, keeping its other client read-only metadata."""
        metadata = team.get("client_read_only_metadata")
        metadata = dict(metadata) if isinstance(metadata, dict) else {}
        metadata[PLAN_KEY] = PROBE_TEAM_PLAN
        self.server("PATCH", f"/teams/{urllib.parse.quote(team['id'])}", {"client_read_only_metadata": metadata})

    def add_member(self, team_id, user_id):
        """Adds USER_ID to TEAM_ID as a plain member (no creator defaults); a membership already there is fine."""
        self.server("POST", f"/team-memberships/{urllib.parse.quote(team_id)}/{urllib.parse.quote(user_id)}", {},
                    ok_known=("TEAM_MEMBERSHIP_ALREADY_EXISTS",))

    def signs_in(self, email, password):
        headers = {"content-type": "application/json", "x-stack-access-type": "client",
                   "x-stack-project-id": self.project_id, "x-stack-publishable-client-key": self.client_key}
        status, _, parsed = self.transport("POST", STACK_API + "/auth/password/sign-in", headers,
                                           {"email": email, "password": password})
        return status == 200 and bool((parsed or {}).get("access_token"))


def new_password():
    """A 43-character URL-safe random password (256 bits), masked in the job log before anything else."""
    password = secrets.token_urlsafe(32)
    if os.environ.get("GITHUB_ACTIONS") == "true":
        # A workflow command, consumed by the runner: from here on the value shows as *** in every log.
        print(f"::add-mask::{password}", flush=True)
    return password


def join_team(stack, user_id, team_id, log=print):
    """Makes USER_ID a member of TEAM_ID unless it already is, then reads the membership back; fails without it."""
    if team_id in stack.teams(user_id):
        action = "already a member of"
    else:
        stack.add_member(team_id, user_id)
        action = "added as a member of"
    if team_id not in stack.teams(user_id):
        raise ProvisionError(f"the account read back as not a member of the company team {team_id}")
    log(f"Stack user id {user_id}: {action} the company team {team_id} (read back: member of the company team "
        f"{team_id})")
    return action


def provision(stack, out, log=print, lib=None, key_id=None, key=None, make_password=new_password, target=CAPTURE):
    """Find or create TARGET's account, rotate its password, check it, write the sealed bundle to OUT.
    Returns "created" or "rotated"."""
    if stack.project_id != target.project:
        raise ProvisionError("the Stack project is not the target's project; refusing to touch it")
    key_id = target.key_id if key_id is None else key_id
    key = target.key if key is None else key
    email = target.email
    password = make_password()
    try:
        user = stack.find(email)
        if user is None:
            user = stack.create(email, password, target.display_name, target.profile_image_url)
            action = "created"
        else:
            profile = ({"display_name": target.display_name, "profile_image_url": target.profile_image_url}
                       if target.profile_image_url else None)
            stack.rotate(user, password, profile)
            action = "rotated"
        if stack.plan(user["id"]) != PLAN:
            raise ProvisionError(f"the account's {PLAN_KEY} did not read back as {PLAN!r}")
        if not stack.signs_in(email, password):
            raise ProvisionError("the new password did not sign in")
        if target.team_id:
            join_team(stack, user["id"], target.team_id, log)
        bundle = sealed_secrets.seal_bundle(target.repo, target.environment, key_id, key,
                                            {target.email_secret: email, target.password_secret: password}, lib)
    finally:
        # Python cannot wipe a str; dropping the only reference is what is possible. The process ends next.
        password = None  # noqa: F841
    sealed_secrets.write_bundle(out, bundle)
    where = "production" if target.project == PRODUCTION_PROJECT_ID else "staging"
    log(f"{action} the {where} test account {email}, Stack user id {user['id']} (plan {PLAN}); sealed "
        f"{target.email_secret} and {target.password_secret} to {sealed_secrets.where(bundle)[1]} "
        f"(key_id {key_id})")
    return action


def grant_only(stack, email, log=print):
    """Gives the existing capture account EMAIL the operator plan grant and a verified email; nothing else changes."""
    if not GRANT_ONLY_EMAIL.fullmatch(email):
        raise ProvisionError("--grant-only takes only a staging capture test account's email")
    user = stack.find(email)
    if user is None:
        raise ProvisionError("no staging account has that email; --grant-only never creates one")
    stack.grant(user)
    after = stack.read(user["id"])
    metadata = after.get("client_read_only_metadata")
    if (metadata.get(PLAN_KEY) if isinstance(metadata, dict) else None) != PLAN:
        raise ProvisionError(f"the account's {PLAN_KEY} did not read back as {PLAN!r}")
    if after.get("primary_email_verified") is not True:
        raise ProvisionError("the account's primary email did not read back as verified")
    log(f"granted {PLAN_KEY} {PLAN!r} and a verified email to the staging capture account; its password and other "
        "metadata are unchanged")


def team_only(stack, target, log=print):
    """Makes TARGET's existing account a member of its company team; no rotation, nothing sealed, never a create."""
    if not target.team_id:
        raise ProvisionError("this target has no company team; --team-only refuses it")
    if stack.project_id != target.project:
        raise ProvisionError("the Stack project is not the target's project; refusing to touch it")
    user = stack.find(target.email)
    if user is None:
        raise ProvisionError("no account has the target's email; --team-only never creates one")
    return join_team(stack, user["id"], target.team_id, log)


def probe_slot(team):
    """The probe slot TEAM's server-only marker names, or None for any other team."""
    metadata = team.get("server_metadata")
    marker = metadata.get(PROBE_TEAM_KEY) if isinstance(metadata, dict) else None
    slot = marker.get("slot") if isinstance(marker, dict) else None
    return slot if isinstance(slot, int) and not isinstance(slot, bool) and slot >= 1 else None


def probe_teams(stack, count=PROBE_TEAMS_DEFAULT, log=print, target=CAPTURE):
    """Makes sure TARGET's existing account is the only member of COUNT probe teams, each with the team operator grant;
    finds the ones an earlier run made (by their marker) and makes only the missing slots. Returns their ids by slot."""
    if target is not TARGETS[PROBE_TEAM_TARGET]:
        raise ProvisionError(f"--probe-teams puts only the {PROBE_TEAM_TARGET} target's account in probe teams")
    if isinstance(count, bool) or not isinstance(count, int) or not 1 <= count <= PROBE_TEAMS_MAX:
        raise ProvisionError(f"--probe-teams takes a count from 1 to {PROBE_TEAMS_MAX}")
    if stack.project_id != target.project or target.project != STAGING_PROJECT_ID:
        raise ProvisionError("probe teams are made only in the staging Stack project")
    user = stack.find(target.email)
    if user is None:
        raise ProvisionError("no account has the target's email; --probe-teams never creates one")
    uid = user["id"]
    found = {}
    for team in stack.user_teams(uid):
        slot = probe_slot(team)
        if slot is None:
            continue
        if slot in found:
            raise ProvisionError(f"two probe teams claim slot {slot} ({found[slot]['id']} and {team['id']}); "
                                 "refusing to pick one")
        found[slot] = team
    ids, actions = {}, {}
    for slot in range(1, count + 1):
        team = found.get(slot)
        if team is None:
            team = stack.create_team(probe_team_name(slot), {PROBE_TEAM_KEY: {"slot": slot,
                                                                              "members": [target.email]}})
            try:
                stack.add_member(team["id"], uid)
            except BaseException:
                # Any failed join, not only an HTTP refusal: a transport error (URLError, a timeout, any OSError) or an
                # interrupt leaves a team the account may never have joined, invisible to the next run's search, so a
                # retry would make a second team for this slot. Remove it; the join's own error is what the run reports.
                try:
                    stack.delete_team(team["id"])
                except Exception:
                    log(f"::warning::probe team {slot} {team['id']}: the join failed and so did its delete")
                raise
            actions[slot] = "created"
        else:
            actions[slot] = "found"
        # Only test accounts: anyone else in the team (a person added by hand) stops the run before any grant.
        members = stack.team_members(team["id"])
        if members != {uid}:
            raise ProvisionError(f"probe team {slot} ({team['id']}) holds {len(members - {uid})} member(s) other than "
                                 f"the {target.email} test account; a probe team holds only test accounts, so "
                                 "nothing was granted (remove them, then run again)")
        current = stack.team(team["id"])
        metadata = current.get("client_read_only_metadata")
        if (metadata.get(PLAN_KEY) if isinstance(metadata, dict) else None) != PROBE_TEAM_PLAN:
            stack.grant_team(current)
            actions[slot] += ", granted"
        ids[slot] = team["id"]
    listed = stack.teams(uid)
    for slot, team_id in ids.items():
        if team_id not in listed:
            raise ProvisionError(f"the account read back as not a member of probe team {slot} ({team_id})")
        metadata = stack.team(team_id).get("client_read_only_metadata")
        if (metadata.get(PLAN_KEY) if isinstance(metadata, dict) else None) != PROBE_TEAM_PLAN:
            raise ProvisionError(f"probe team {slot}'s {PLAN_KEY} did not read back as {PROBE_TEAM_PLAN!r}")
        log(f"probe team {slot} {team_id}: {actions[slot]} (read back: members the {target.email} test account only, "
            f"{PLAN_KEY} {PROBE_TEAM_PLAN})")
    extra = sorted(s for s in found if s > count)
    if extra:
        log(f"probe team slot(s) {', '.join(map(str, extra))} above {count} are left as they are")
    log(f"the {target.email} test account is in its own team and {count} probe team(s)")
    return ids


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--out", help="where to write the sealed bundle (ciphertext only)")
    mode.add_argument("--grant-only", metavar="EMAIL", help="only grant the operator plan to this existing capture account")
    mode.add_argument("--team-only", action="store_true",
                      help="only make the target's existing account a member of its company team")
    mode.add_argument("--probe-teams", type=int, metavar="N",
                      help=f"only make sure the capture account is the only member of N probe teams "
                           f"(1 to {PROBE_TEAMS_MAX}, {PROBE_TEAMS_DEFAULT} for 5x10), each with the team grant")
    parser.add_argument("--target", choices=sorted(TARGETS), default="capture",
                        help="which test account to provision and where its credential is sealed")
    args = parser.parse_args(argv)
    target = TARGETS[args.target]
    try:
        if args.grant_only is not None and target.project != STAGING_PROJECT_ID:
            raise ProvisionError("--grant-only touches only the staging capture test accounts")
        if args.probe_teams is not None and args.target != PROBE_TEAM_TARGET:
            raise ProvisionError(f"--probe-teams puts only the {PROBE_TEAM_TARGET} target's account in probe teams")
        stack = Stack(os.environ.get("NEXT_PUBLIC_STACK_PROJECT_ID", ""), os.environ.get("STACK_SECRET_SERVER_KEY", ""),
                      os.environ.get("NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY", ""), expected_project=target.project)
        if args.grant_only is not None:
            grant_only(stack, args.grant_only.strip().lower())
        elif args.team_only:
            team_only(stack, target)
        elif args.probe_teams is not None:
            probe_teams(stack, args.probe_teams, target=target)
        else:
            provision(stack, args.out, target=target)
    except (ProvisionError, sealed_secrets.SealError) as error:
        print(f"::error::cloud capture provision: {error}", flush=True)
        return 1
    except OSError as error:
        # A transport error (URLError, a timeout) carries no response body, so naming it echoes no account data.
        print(f"::error::cloud capture provision: {type(error).__name__}: {error}", flush=True)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
