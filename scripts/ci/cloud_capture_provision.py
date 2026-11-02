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

Runs in .github/workflows/cloud-capture-provision.yml (environment cloud-vm-staging). The bundle is
stored with `python3 scripts/ci/sealed_secrets.py put BUNDLE`; docs/ci-sealed-secrets.md.
Standard library only, plus the system libsodium.
"""
from __future__ import annotations

import argparse
import json
import os
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
EMAIL = "cmux-cloud-capture@manaflow.dev"
DISPLAY_NAME = "cmux cloud capture"
PLAN_KEY, PLAN = "cmuxVmPlan", "pro"
# Where the credential goes: the capture environment of the team's private infrastructure repository.
# A rotated GitHub key changes key_id; `put` then refuses the bundle and this pin is updated.
TARGET_REPO = "manaflow-ai/cmuxterm-hq"
TARGET_ENVIRONMENT = "cloud-capture"
TARGET_KEY_ID = "3380204578043523366"
TARGET_KEY = "jjGF/Nq5EeX9Ye2kCKwzDsZaAJETgKx/H8cQgQPv9AY="
EMAIL_SECRET = "CLOUD_CAPTURE_STACK_EMAIL"
PASSWORD_SECRET = "CLOUD_CAPTURE_STACK_PASSWORD"
REQUEST_SECONDS = 30


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
            raise ProvisionError(f"{len(matches)} staging users have the capture email; refusing to pick one")
        return matches[0] if matches else None

    def create(self, email, password):
        user = self.server("POST", "/users", {
            "primary_email": email, "primary_email_verified": True, "primary_email_auth_enabled": True,
            "password": password, "display_name": DISPLAY_NAME,
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

    def plan(self, user_id):
        user = self.server("GET", f"/users/{urllib.parse.quote(user_id)}")
        metadata = user.get("client_read_only_metadata")
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


def provision(stack, out, log=print, lib=None, key_id=TARGET_KEY_ID, key=TARGET_KEY, make_password=new_password):
    """Find or create the account, rotate its password, check it, write the sealed bundle to OUT.
    Returns "created" or "rotated"."""
    password = make_password()
    try:
        user = stack.find(EMAIL)
        if user is None:
            user = stack.create(EMAIL, password)
            action = "created"
        else:
            stack.rotate(user, password)
            action = "rotated"
        if stack.plan(user["id"]) != PLAN:
            raise ProvisionError(f"the account's {PLAN_KEY} did not read back as {PLAN!r}")
        if not stack.signs_in(EMAIL, password):
            raise ProvisionError("the new password did not sign in")
        bundle = sealed_secrets.seal_bundle(TARGET_REPO, TARGET_ENVIRONMENT, key_id, key,
                                            {EMAIL_SECRET: EMAIL, PASSWORD_SECRET: password}, lib)
    finally:
        # Python cannot wipe a str; dropping the only reference is what is possible. The process ends next.
        password = None  # noqa: F841
    sealed_secrets.write_bundle(out, bundle)
    log(f"{action} the staging capture account (plan {PLAN}); sealed {EMAIL_SECRET} and {PASSWORD_SECRET} "
        f"to {TARGET_REPO} environment {TARGET_ENVIRONMENT} (key_id {key_id})")
    return action


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--out", required=True, help="where to write the sealed bundle (ciphertext only)")
    args = parser.parse_args(argv)
    try:
        stack = Stack(os.environ.get("NEXT_PUBLIC_STACK_PROJECT_ID", ""), os.environ.get("STACK_SECRET_SERVER_KEY", ""),
                      os.environ.get("NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY", ""))
        provision(stack, args.out)
    except (ProvisionError, sealed_secrets.SealError) as error:
        print(f"::error::cloud capture provision: {error}", flush=True)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
