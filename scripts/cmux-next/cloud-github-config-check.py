#!/usr/bin/env python3
"""Is staging set up for the GitHub main-path recording? Fails early, with the reason, before any app starts.

Run by cloud-chat-proof.yml's `flow: github-pr-app` before the recording (docs/cmux-next/cloud-github-main-path-recording.md):

1. The App's public page: `GET https://api.github.com/apps/<slug>` answers 200. A 404 means GitHub does not show the
   App to the public (a private App, or a wrong slug), and then an organization the App's owner does not own (the test
   org) cannot install it: the recording would stop on GitHub's install page. No secret; `--public-only` runs this alone.
2. With the staging Stack pair in the environment (CMUX_DOGFOOD_STACK_EMAIL and _PASSWORD): the account signs in, and
   `GET /v1/integrations/github/status` on the staging Cloud API says `configured: true` and `app_slug: <slug>`.

Prints one `config: NAME ok|FAIL ...` line per check and exits 1 if any failed. Never prints a token or a password.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_SLUG = "cmux-cloud-staging"
DEFAULT_API = "https://cloud-api-staging.cmux.dev"


def say(name: str, ok: bool, detail: str) -> bool:
    print(f"config: {name} {'ok' if ok else 'FAIL'} {detail}".rstrip(), flush=True)
    return ok


def get(url: str, headers: dict[str, str] | None = None) -> tuple[int, dict]:
    request = urllib.request.Request(url, headers={"accept": "application/json", "user-agent": "cmux-config-check",
                                                   **(headers or {})})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            status, raw = response.status, response.read()
    except urllib.error.HTTPError as exc:
        status, raw = exc.code, exc.read() or b""
    except (urllib.error.URLError, TimeoutError) as exc:
        return 0, {"error": str(getattr(exc, "reason", exc))[:200]}
    try:
        body = json.loads(raw or b"{}")
    except ValueError:
        body = {}
    return status, body if isinstance(body, dict) else {}


def public_app(slug: str) -> bool:
    status, body = get(f"https://api.github.com/apps/{slug}")
    if status == 200:
        owner = (body.get("owner") or {}).get("login") or "?"
        return say("app_public", True, f"https://api.github.com/apps/{slug} answers 200 (owner {owner})")
    if status == 404:
        return say("app_public", False, f"https://api.github.com/apps/{slug} answers 404: the App is private or the slug is "
                   "wrong, so the test org cannot install it. Fix: the App's owner makes it public (GitHub > the App's "
                   "settings > Advanced > Make public), then rerun.")
    return say("app_public", False, f"https://api.github.com/apps/{slug} answers HTTP {status or 'no answer'} "
               f"{body.get('error') or body.get('message') or ''}; retry in a few minutes")


def stack_sign_in(email: str, password: str) -> str:
    """The staging access token, through dev-signin-token.py's sign-in (one copy of the Stack call)."""
    path = Path(__file__).resolve().parent / "dev-signin-token.py"
    spec = importlib.util.spec_from_file_location("dev_signin_token", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader
    spec.loader.exec_module(module)
    return module.sign_in(email, password, "staging")["accessToken"]


def api_status(api: str, slug: str) -> bool:
    email = os.environ.get("CMUX_DOGFOOD_STACK_EMAIL", "")
    password = os.environ.get("CMUX_DOGFOOD_STACK_PASSWORD", "")
    if not email or not password:
        return say("api_status", False, "CMUX_DOGFOOD_STACK_EMAIL and _PASSWORD are not set (the staging capture account)")
    try:
        token = stack_sign_in(email, password)
    except SystemExit as exc:
        return say("api_status", False, f"the staging account did not sign in: {exc}")
    status, body = get(f"{api.rstrip('/')}/v1/integrations/github/status", {"authorization": f"Bearer {token}"})
    del token
    if status != 200:
        return say("api_status", False, f"GET /v1/integrations/github/status answers HTTP {status or 'no answer'}; retry, "
                   "and if it stays, the staging API is down or refuses the account")
    seen = body.get("app_slug")
    configured = body.get("configured") is True
    connection = body.get("connection") if isinstance(body.get("connection"), dict) else None
    detail = (f"configured {configured}, app_slug {seen!r}, allowed {body.get('allowed', '?')}, "
              f"connection {connection.get('status') if connection else 'none'}")
    if not configured or seen != slug:
        return say("api_status", False, f"{detail}; the recording needs configured true and app_slug {slug!r}: set the "
                   "staging API's GitHub App (cmux-platform staging env) to that App")
    return say("api_status", True, detail)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--slug", default=DEFAULT_SLUG)
    parser.add_argument("--api", default=DEFAULT_API)
    parser.add_argument("--public-only", action="store_true", help="only the App's public page (no secret)")
    args = parser.parse_args()
    results = [public_app(args.slug)]
    if not args.public_only:
        results.append(api_status(args.api, args.slug))
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
