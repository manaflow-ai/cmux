#!/usr/bin/env python3
"""Send the job's token with SwiftPM's github.com git fetches for the rest of the job.

GitHub answers anonymous git and release downloads from the office Macs' shared address with 403, while the
same Mac's authenticated fetches succeed (11-26: pr pipeline / ios on one mini, actions/checkout fetched cmux
with the job token at 07:23:22Z; xcodebuild's anonymous clone of apple/swift-crypto got 403 at 07:36:50Z).
An authenticated request is counted against the token, not the address.

For every github.com repository a tracked Package.resolved pins, this appends to $GITHUB_ENV a
`http.<repo url>/.extraheader` with the token as basic auth, through GIT_CONFIG_COUNT/KEY/VALUE (continuing any
entries already in the environment). The token never reaches argv or a config file on disk outside the
runner's own env file. Each key names one repository, so no request gets two Authorization headers:
manaflow-ai/cmux itself, which actions/checkout authenticates, is never included.

Fails soft: no token, no $GITHUB_ENV or no pins means nothing is written; SwiftPM fetches anonymously as before.

    github_fetch_auth.py [--root DIR]

The token is read from GH_TOKEN, else GITHUB_TOKEN (the step passes `${{ github.token }}`).
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import subprocess
import sys
from pathlib import Path

GITHUB_REPO = re.compile(r"https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?/?$", re.IGNORECASE)
# actions/checkout puts its own extraheader on these; a second header would make GitHub answer 400.
CHECKOUT_REPOS = {("manaflow-ai", "cmux")}
MARKER = "CMUX_GITHUB_FETCH_AUTH"


def token_from(environ) -> str:
    return (environ.get("GH_TOKEN") or environ.get("GITHUB_TOKEN") or "").strip()


def resolved_files(root: Path) -> list[Path]:
    try:
        listed = subprocess.run(["git", "-C", str(root), "ls-files", "-z", "--", "*Package.resolved"],
                                check=True, capture_output=True, timeout=60).stdout
        names = [name for name in listed.decode().split("\0") if name]
    except (OSError, subprocess.SubprocessError):
        names = []
    return [root / name for name in names if (root / name).is_file()]


def pinned_repos(files: list[Path]) -> list[tuple[str, str]]:
    """(owner, repo) of each github.com source-control pin, lower-cased and de-duplicated."""
    found: set[tuple[str, str]] = set()
    for path in files:
        try:
            data = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        pins = data.get("pins") or (data.get("object") or {}).get("pins") or []
        for pin in pins:
            location = (pin.get("location") or pin.get("repositoryURL") or "") if isinstance(pin, dict) else ""
            match = GITHUB_REPO.match(location.strip())
            if match:
                found.add((match.group(1).lower(), match.group(2).lower()))
    return sorted(found - CHECKOUT_REPOS)


def config_entries(repos: list[tuple[str, str]], token: str) -> list[tuple[str, str]]:
    """Both spellings SwiftPM may request (with and without .git), each scoped to its own path."""
    header = "AUTHORIZATION: basic " + base64.b64encode(f"x-access-token:{token}".encode()).decode()
    entries = []
    for owner, repo in repos:
        for suffix in ("", ".git"):
            entries.append((f"http.https://github.com/{owner}/{repo}{suffix}/.extraheader", header))
    return entries


def env_lines(entries: list[tuple[str, str]], environ) -> list[str]:
    try:
        start = int(environ.get("GIT_CONFIG_COUNT") or 0)
    except ValueError:
        start = 0
    lines = []
    for offset, (key, value) in enumerate(entries):
        lines += [f"GIT_CONFIG_KEY_{start + offset}={key}", f"GIT_CONFIG_VALUE_{start + offset}={value}"]
    lines += [f"GIT_CONFIG_COUNT={start + len(entries)}", f"{MARKER}={len(entries) // 2}"]
    return lines


def main(argv=None, environ=os.environ) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", type=Path, default=Path(environ.get("GITHUB_WORKSPACE") or "."))
    args = parser.parse_args(argv)
    token, env_file = token_from(environ), environ.get("GITHUB_ENV")
    if environ.get(MARKER):
        print(f"github fetch auth: already set for {environ[MARKER]} repositories")
        return 0
    if not token or not env_file:
        print("github fetch auth: no token or no GITHUB_ENV; SwiftPM fetches github.com anonymously")
        return 0
    repos = pinned_repos(resolved_files(args.root))
    if not repos:
        print("github fetch auth: no github.com pins found")
        return 0
    try:
        with open(env_file, "a", encoding="utf-8") as handle:
            handle.write("\n".join(env_lines(config_entries(repos, token), environ)) + "\n")
    except OSError as error:
        print(f"::warning::github fetch auth: could not write GITHUB_ENV: {error}")
        return 0
    print(f"github fetch auth: SwiftPM's fetches of {len(repos)} github.com repositories send the job token: "
          + ", ".join(f"{owner}/{repo}" for owner, repo in repos))
    return 0


if __name__ == "__main__":
    sys.exit(main())
