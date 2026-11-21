#!/usr/bin/env python3
"""Fails when a pinned third-party payload cmux-next ships is behind an upstream security fix.

cmux-next bundles some third-party code at an exact pinned release (today the
built-in uBlock Origin, staged by scripts/cmux-next/fetch-ublock.sh). A pin is
a promise that nothing changes until someone moves it, so an upstream security
release does not reach cmux until a person notices it. uBlock Origin 1.75.0
stayed pinned after GHSA-cmqw-9r2w-6wv2 (element picker universal XSS, fixed in
1.75.4) was published.

This reads each pin from the file that owns it (PAYLOADS below), lists the
upstream repository's published GitHub security advisories, and reports every
advisory whose vulnerable range holds the pinned version.

    python3 scripts/cmux-next/payload_advisories.py [--advisories-json PATH]

Exit codes: 0 every pin is outside every published advisory, 1 a pin is behind
a security fix (report on stdout), 3 an advisory list could not be read
(network; reported, the workflow treats it as no verdict). The workflow
(.github/workflows/cmux-next-payload-advisories.yml) keeps one issue up to date.
The fix is a new pin in the file the report names, never a change here.

A new fetch script that downloads a third-party GitHub release must add a
PAYLOADS entry: tests/test_payload_advisories.py fails until it does.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.request
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


@dataclass(frozen=True)
class Payload:
    name: str
    repo: str  # upstream GitHub owner/name whose security advisories apply
    pin_file: str  # repo-relative file that owns the pin
    pattern: str  # regex (MULTILINE) whose group 1 is the pinned version
    shipped: bool = True  # False: test-only, reported but named as such


PAYLOADS: tuple[Payload, ...] = (
    Payload(
        name="uBlock Origin (built-in ad blocker)",
        repo="gorhill/uBlock",
        pin_file="scripts/cmux-next/fetch-ublock.sh",
        pattern=r'^UBLOCK_VERSION="([0-9][0-9.]*)"$',
    ),
    Payload(
        name="uBlock Origin (extension test store CRX)",
        repo="gorhill/uBlock",
        pin_file="scripts/cmux-next/ext-store/extensions.json",
        pattern=r"gorhill/uBlock/releases/download/([0-9][0-9.]*)/",
        shipped=False,
    ),
)

_VERSION = r"v?(\d+(?:\.\d+)*)"


def parse_version(text: str) -> tuple[int, ...]:
    m = re.fullmatch(_VERSION, text.strip())
    if not m:
        raise ValueError(f"not a release version: {text!r}")
    parts = [int(p) for p in m.group(1).split(".")]
    while len(parts) > 1 and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


def read_pin(payload: Payload, root: Path = ROOT) -> str:
    text = (root / payload.pin_file).read_text()
    found = re.findall(payload.pattern, text, re.MULTILINE)
    if not found:
        raise ValueError(f"{payload.pin_file}: no pin matches {payload.pattern!r}")
    if len(set(found)) > 1:
        raise ValueError(f"{payload.pin_file}: more than one {payload.name} pin: {sorted(set(found))}")
    return found[0]


_CLAUSE = re.compile(r"^(<=|<|>=|>|=)?\s*" + _VERSION + r"$")
_AND_LOWER = re.compile(r"^" + _VERSION + r"\s+and\s+(?:lower|earlier|below|older|prior)$", re.IGNORECASE)


def in_range(version: str, vulnerable_range: str) -> bool | None:
    """Whether version is inside an advisory's vulnerable range; None if the range is unreadable.

    GitHub repository advisories carry free text here: "1.75.2 and lower",
    "<= 1.75.2", ">= 1.60, < 1.75.4". Every comma-separated clause must hold.
    """
    v = parse_version(version)
    clauses = [c.strip() for c in vulnerable_range.split(",") if c.strip()]
    if not clauses:
        return None
    for clause in clauses:
        lower = _AND_LOWER.match(clause)
        if lower:
            op, bound = "<=", parse_version(lower.group(1))
        else:
            m = _CLAUSE.match(clause)
            if not m:
                return None
            op, bound = m.group(1) or "=", parse_version(m.group(2))
        ok = {"<=": v <= bound, "<": v < bound, ">=": v >= bound, ">": v > bound, "=": v == bound}[op]
        if not ok:
            return False
    return True


def patched_versions(text: str | None) -> list[tuple[int, ...]]:
    return [parse_version(m) for m in re.findall(r"\d+(?:\.\d+)+", text or "")]


def affected(version: str, vuln: dict) -> bool | None:
    """Whether one advisory vulnerability entry covers version (None: cannot tell)."""
    verdict = in_range(version, vuln.get("vulnerable_version_range") or "")
    if verdict is not None:
        return verdict
    patched = patched_versions(vuln.get("patched_versions"))
    if patched:
        # Unreadable range: conservative, behind the newest patched release is behind.
        return parse_version(version) < max(patched)
    return None


def findings(payload: Payload, version: str, advisories: list[dict]) -> tuple[list[str], list[str]]:
    """(behind, unreadable) report lines for one pinned payload."""
    behind, unreadable = [], []
    for adv in advisories:
        if adv.get("withdrawn_at") or adv.get("state", "published") != "published":
            continue
        ident = adv.get("ghsa_id") or adv.get("cve_id") or "advisory"
        url = adv.get("html_url") or f"https://github.com/{payload.repo}/security/advisories/{ident}"
        for vuln in adv.get("vulnerabilities") or [{}]:
            verdict = affected(version, vuln)
            fixed = vuln.get("patched_versions") or "no fixed version named"
            if verdict:
                behind.append(f"{ident} ({adv.get('summary', '').strip()}): affected "
                              f"{vuln.get('vulnerable_version_range')}, fixed in {fixed}. {url}")
            elif verdict is None:
                unreadable.append(f"{ident}: cannot read range {vuln.get('vulnerable_version_range')!r} "
                                  f"or fixed {vuln.get('patched_versions')!r}; check by hand. {url}")
    return behind, unreadable


def fetch_json(url: str):
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "cmux-payload-advisories"}
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as resp:
        return json.load(resp)


def live_advisories(repo: str) -> list[dict]:
    out: list[dict] = []
    for page in range(1, 11):
        batch = fetch_json(f"https://api.github.com/repos/{repo}/security-advisories"
                           f"?state=published&per_page=100&page={page}")
        out.extend(batch)
        if len(batch) < 100:
            return out
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--advisories-json", type=Path,
                        help='saved answers, {"owner/repo": [advisory, ...]} (tests)')
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args(argv)

    saved = json.loads(args.advisories_json.read_text()) if args.advisories_json else None
    cache: dict[str, list[dict]] = {}
    lines: list[str] = []
    stale = False
    for payload in PAYLOADS:
        version = read_pin(payload, args.root)
        if payload.repo not in cache:
            try:
                cache[payload.repo] = saved.get(payload.repo, []) if saved is not None else live_advisories(payload.repo)
            except Exception as error:  # noqa: BLE001: any failure here is "no verdict"
                print(f"cannot read {payload.repo}'s security advisories: {error}")
                return 3
        behind, unreadable = findings(payload, version, cache[payload.repo])
        where = f"{payload.name} {version} (pinned in {payload.pin_file}{'' if payload.shipped else ', test-only'})"
        if behind:
            stale = True
            lines.append(f"BEHIND A SECURITY FIX: {where}")
            lines.extend(f"  - {b}" for b in behind)
        else:
            lines.append(f"ok: {where}, outside every published {payload.repo} advisory")
        lines.extend(f"  ? {u}" for u in unreadable)
    print("\n".join(lines))
    return 1 if stale else 0


if __name__ == "__main__":
    sys.exit(main())
