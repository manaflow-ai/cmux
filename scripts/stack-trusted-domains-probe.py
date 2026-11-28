#!/usr/bin/env python3
"""Ask the live auth projects which sign-in addresses they trust, read-only.

The auth projects' trusted-domain lists live only in the auth dashboard. This
asks each project's OAuth start endpoint, with the project's public client key,
whether it accepts the hosted sign-in page's redirect URLs on an origin, the
same check that fails a sign-in with REDIRECT_URL_NOT_WHITELISTED. An accepted
answer is only a redirect to the provider; nothing is signed in and no setting
changes.

    scripts/stack-trusted-domains-probe.py
        re-asks every probe in the committed fixture
        (cmux-tui/crates/cmux-cloud-config/fixtures/stack-trusted-domains.json)
        and exits 1 when a live answer differs from it.
    scripts/stack-trusted-domains-probe.py --project development --origin https://cmux-staging.vercel.app
        asks about one origin.

Exit codes: 0 every answer matches, 1 an answer differs, 2 the service could
not be asked.
"""

from __future__ import annotations

import argparse
import json
import secrets
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

FIXTURE = Path(__file__).resolve().parent.parent / "cmux-tui/crates/cmux-cloud-config/fixtures/stack-trusted-domains.json"
API = "https://api.hexclave.com/api/v1"
# The SDK's stand-in for a project that needs no publishable key (production).
NO_CLIENT_KEY = "__stack_public_client__"
# Any valid S256 challenge: the trip is never finished, so no verifier is kept.
CODE_CHALLENGE = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"


class ProbeError(Exception):
    pass


def accepted(project: dict, origin: str) -> bool:
    """Whether the project accepts the hosted page's redirect URLs on `origin`."""
    origin = origin.rstrip("/")
    query = urllib.parse.urlencode({
        "client_id": project["projectId"],
        "client_secret": project.get("publishableClientKey") or NO_CLIENT_KEY,
        "redirect_uri": f"{origin}/handler/oauth-callback",
        "error_redirect_url": f"{origin}/handler/error",
        "after_callback_redirect_url": f"{origin}/handler/sign-in",
        "scope": "legacy",
        "state": secrets.token_urlsafe(16),
        "grant_type": "authorization_code",
        "code_challenge": CODE_CHALLENGE,
        "code_challenge_method": "S256",
        "response_type": "code",
        "type": "authenticate",
        "hexclave_response_mode": "json",
        "stack_response_mode": "json",
    })
    request = urllib.request.Request(f"{API}/auth/oauth/authorize/google?{query}", method="GET")
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            body = json.loads(response.read() or b"{}")
            if isinstance(body.get("location"), str):
                return True
            raise ProbeError(f"{origin}: unexpected answer {response.status}")
    except urllib.error.HTTPError as error:
        try:
            body = json.loads(error.read() or b"{}")
        except ValueError:
            body = {}
        if body.get("code") == "REDIRECT_URL_NOT_WHITELISTED":
            return False
        raise ProbeError(f"{origin}: HTTP {error.code} {body.get('code', '')}".strip()) from error
    except (urllib.error.URLError, TimeoutError, ValueError) as error:
        raise ProbeError(f"{origin}: {error}") from error


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--fixture", type=Path, default=FIXTURE)
    parser.add_argument("--project", help="development or production (with --origin)")
    parser.add_argument("--origin", help="one origin to ask about")
    args = parser.parse_args()

    fixture = json.loads(args.fixture.read_text())
    projects = fixture["projects"]
    if args.origin:
        if args.project not in projects:
            parser.error(f"--project must be one of {', '.join(projects)}")
        probes = [{"project": args.project, "origin": args.origin, "accepted": None}]
    else:
        probes = fixture["probes"]

    differs = 0
    try:
        for probe in probes:
            live = accepted(projects[probe["project"]], probe["origin"])
            recorded = probe["accepted"]
            mark = "" if recorded is None or recorded == live else "   DIFFERS from the fixture"
            differs += bool(mark)
            print(f"{probe['project']:<12} {probe['origin']:<55} {'accepted' if live else 'REDIRECT_URL_NOT_WHITELISTED'}{mark}")
    except ProbeError as error:
        print(f"could not ask the auth service: {error}", file=sys.stderr)
        return 2
    if differs:
        print(f"{differs} answer(s) differ from {args.fixture}; update it from this run "
              "(and DEV_PROJECT_TRUSTS_STAGING in stack_redirects_tests.rs when the staging entry lands).",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
