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
STACK_API = "https://api.stack-auth.com/api/v1"
PLAN_KEY, PLAN = "cmuxVmPlan", "pro"


class Target:
    """One staging test account and where its credential is sealed. A rotated GitHub key changes key_id;
    `put` then refuses the bundle and the pin here is updated. GitHub gives both environments below the same
    key_id with different key bytes (read from `.../environments/ENV/secrets/public-key` on 2026-11-04);
    `put` checks both against the live key."""

    def __init__(self, email, display_name, repo, environment, key_id, key, email_secret, password_secret):
        self.email, self.display_name = email, display_name
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
}
CAPTURE = TARGETS["capture"]
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
    def __init__(self, project_id, server_key, client_key, transport=http):
        if project_id != STAGING_PROJECT_ID:
            raise ProvisionError("the Stack project is not the staging project; refusing to touch it")
        if not server_key:
            raise ProvisionError("STACK_SECRET_SERVER_KEY is empty")
        if not client_key:
            raise ProvisionError("NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY is empty")
        self.project_id, self.server_key, self.client_key, self.transport = project_id, server_key, client_key, transport

    def server(self, method, path, body=None, ok=(200, 201)):
        headers = {"content-type": "application/json", "x-stack-access-type": "server",
                   "x-stack-project-id": self.project_id, "x-stack-secret-server-key": self.server_key}
        status, reply_headers, parsed = self.transport(method, STACK_API + path, headers, body)
        if status not in ok:
            known = reply_headers.get("x-stack-known-error", "")
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

    def create(self, email, password, display_name=CAPTURE.display_name):
        user = self.server("POST", "/users", {
            "primary_email": email, "primary_email_verified": True, "primary_email_auth_enabled": True,
            "password": password, "display_name": display_name,
            "client_read_only_metadata": {PLAN_KEY: PLAN}})
        if not user.get("id"):
            raise ProvisionError("Stack created the user but returned no id")
        return user

    def rotate(self, user, password):
        metadata = user.get("client_read_only_metadata")
        metadata = dict(metadata) if isinstance(metadata, dict) else {}
        metadata[PLAN_KEY] = PLAN
        self.server("PATCH", f"/users/{urllib.parse.quote(user['id'])}", {
            "password": password, "primary_email_verified": True, "primary_email_auth_enabled": True,
            "client_read_only_metadata": metadata})

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


def provision(stack, out, log=print, lib=None, key_id=None, key=None, make_password=new_password, target=CAPTURE):
    """Find or create TARGET's account, rotate its password, check it, write the sealed bundle to OUT.
    Returns "created" or "rotated"."""
    key_id = target.key_id if key_id is None else key_id
    key = target.key if key is None else key
    email = target.email
    password = make_password()
    try:
        user = stack.find(email)
        if user is None:
            user = stack.create(email, password, target.display_name)
            action = "created"
        else:
            stack.rotate(user, password)
            action = "rotated"
        if stack.plan(user["id"]) != PLAN:
            raise ProvisionError(f"the account's {PLAN_KEY} did not read back as {PLAN!r}")
        if not stack.signs_in(email, password):
            raise ProvisionError("the new password did not sign in")
        bundle = sealed_secrets.seal_bundle(target.repo, target.environment, key_id, key,
                                            {target.email_secret: email, target.password_secret: password}, lib)
    finally:
        # Python cannot wipe a str; dropping the only reference is what is possible. The process ends next.
        password = None  # noqa: F841
    sealed_secrets.write_bundle(out, bundle)
    log(f"{action} the staging test account {email} (plan {PLAN}); sealed {target.email_secret} and "
        f"{target.password_secret} to {target.repo} environment {target.environment} (key_id {key_id})")
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


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--out", help="where to write the sealed bundle (ciphertext only)")
    mode.add_argument("--grant-only", metavar="EMAIL", help="only grant the operator plan to this existing capture account")
    parser.add_argument("--target", choices=sorted(TARGETS), default="capture",
                        help="which staging test account to provision and where its credential is sealed")
    args = parser.parse_args(argv)
    try:
        stack = Stack(os.environ.get("NEXT_PUBLIC_STACK_PROJECT_ID", ""), os.environ.get("STACK_SECRET_SERVER_KEY", ""),
                      os.environ.get("NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY", ""))
        if args.grant_only is not None:
            grant_only(stack, args.grant_only.strip().lower())
        else:
            provision(stack, args.out, target=TARGETS[args.target])
    except (ProvisionError, sealed_secrets.SealError) as error:
        print(f"::error::cloud capture provision: {error}", flush=True)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
