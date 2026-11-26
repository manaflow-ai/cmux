#!/usr/bin/env python3
"""The rolling blobless bundle list VM guests fetch through (RFD 0056 part 3, the edge route).

git-mirror-bundle.yml already writes cmux-blobless.bundle and a one-entry list with no heuristic, which serves a
first clone only. This adds a list a later `git fetch` can use too: it sets `bundle.heuristic = creationToken`, so a
clone stores `fetch.bundleURI` and `fetch.bundleCreationToken`, and each later fetch downloads only bundles whose
token is newer, then tops up from the code host.

    v1/any/git-bundle/cmux-blobless-base.bundle    a blobless bundle of every branch, rewritten once a week
    v1/any/git-bundle/cmux-blobless-delta.bundle   what the branches gained since the base (prerequisites: the base's
                                                   tips), rewritten every publish
    v1/any/git-bundle/cmux-blobless-rolling.list   both, with creation tokens (unix seconds of their writing)

A guest that fetches every 12 h downloads the delta (megabytes), and the new base once a week (about 160 MB) at the
edge's rate, never the whole bundle on every publish. A single bundle rewritten under one key with a newer token each
time would make every fetch download all of it, which is why the first lists carry no heuristic.

    git_bundle_list.py plan --repo GIT_DIR --built BLOBLESS_BUNDLE --out DIR --public BASE_URL [--now S]

reads the published list at BASE_URL/cmux-blobless-rolling.list and the published base's header, decides whether the
base rotates (no list, a base older than BASE_MAX_DAYS, or none of its tips in GIT_DIR), and writes into DIR the
files to upload, in upload order: cmux-blobless-base.bundle (only when it rotates, a hard link to BUILT),
cmux-blobless-delta.bundle (only when the branches moved past the base) and the list. It prints the plan as JSON.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

LIST = "cmux-blobless-rolling.list"
BASE = "cmux-blobless-base.bundle"
DELTA = "cmux-blobless-delta.bundle"
BASE_MAX_DAYS = 7
HEADER_BYTES = 1 << 20  # a bundle's header (its refs and prerequisites) ends well before this
USER_AGENT = "cmux-ci git_bundle_list"
SHA = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")


def parse_list(text: str) -> dict[str, dict[str, str]]:
    """A bundle list (git-config syntax) as {section: {key: value}}: "bundle" for [bundle], the id for [bundle "id"].
    Keys are lower-cased, as git reads them."""
    out: dict[str, dict[str, str]] = {}
    section = None
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith(("#", ";")):
            continue
        m = re.fullmatch(r'\[bundle(?:\s+"([^"]+)")?\]', line)
        if m:
            section = m.group(1) or "bundle"
            out.setdefault(section, {})
            continue
        if section is not None and "=" in line:
            key, value = line.split("=", 1)
            out[section][key.strip().lower()] = value.strip()
    return out


def render_list(bundles: list[tuple[str, str, int]]) -> str:
    """The list text for BUNDLES [(id, uri, creation token)], every one blobless."""
    lines = ["[bundle]", "\tversion = 1", "\tmode = all", "\theuristic = creationToken"]
    for ident, uri, token in bundles:
        lines += [f'[bundle "{ident}"]', f"\turi = {uri}", f"\tcreationToken = {token}", "\tfilter = blob:none"]
    return "\n".join(lines) + "\n"


def header_tips(header: bytes) -> list[str]:
    """The ref tips a bundle's header names (its prerequisites, `-SHA`, and capabilities, `@...`, left out)."""
    text = header.split(b"\n\n", 1)[0].decode("utf-8", "replace")
    tips = []
    for line in text.splitlines()[1:]:
        if not line or line.startswith(("-", "@", "#")):
            continue
        sha = line.split(" ", 1)[0]
        if SHA.fullmatch(sha):
            tips.append(sha)
    return tips


def http_get(url: str, byte_range: int | None = None, timeout: float = 30) -> bytes | None:
    """URL's body (its first BYTE_RANGE bytes when given), or None when it is not there (404)."""
    # The edge (Cloudflare) answers urllib's default User-Agent with 403, which raised here and, under the publish
    # step's continue-on-error, kept the rolling list from ever being written: name ourselves.
    headers = {"User-Agent": USER_AGENT, **({"Range": f"bytes=0-{byte_range - 1}"} if byte_range else {})}
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read(byte_range) if byte_range else resp.read()
    except urllib.error.HTTPError as err:
        if err.code == 404:
            return None
        raise


def present(repo: Path, shas: list[str]) -> list[str]:
    return [s for s in shas if subprocess.run(["git", "-C", str(repo), "cat-file", "-e", f"{s}^{{commit}}"],
                                              capture_output=True, check=False).returncode == 0]


def plan(repo: Path, built: Path, out: Path, public: str, now: int, fetch=http_get) -> dict:
    out.mkdir(parents=True, exist_ok=True)
    public = public.rstrip("/")
    why = None
    base_token = None
    tips: list[str] = []
    listed = fetch(f"{public}/{LIST}")
    if listed is None:
        why = "no rolling list yet"
    else:
        base = parse_list(listed.decode("utf-8", "replace")).get("base") or {}
        try:
            base_token = int(base.get("creationtoken", ""))
        except ValueError:
            why = "the list's base has no creation token"
        if why is None and now - base_token >= BASE_MAX_DAYS * 86400:
            why = f"the base is {(now - base_token) / 86400:.1f} days old"
        if why is None:
            header = fetch(f"{public}/{BASE}", HEADER_BYTES)
            tips = present(repo, header_tips(header or b""))
            if not tips:
                why = "none of the base's tips is in this fetch"
    bundles: list[tuple[str, str, int]] = []
    if why is not None:
        target = out / BASE
        target.unlink(missing_ok=True)
        os.link(built, target)
        bundles.append(("base", BASE, now))
        result = {"rotated": True, "why": why, "base_token": now, "delta": False}
    else:
        bundles.append(("base", BASE, base_token))
        target = out / DELTA
        target.unlink(missing_ok=True)
        made = subprocess.run(["git", "-C", str(repo), "bundle", "create", "--quiet", str(target),
                               "--filter=blob:none", "--branches", "--not", *tips],
                              capture_output=True, text=True, check=False)
        if made.returncode == 0:
            bundles.append(("delta", DELTA, now))
        elif "empty bundle" not in (made.stderr or ""):
            raise SystemExit(f"git bundle create {DELTA}: {made.stderr.strip()[-400:]}")
        result = {"rotated": False, "base_token": base_token, "delta": made.returncode == 0,
                  "delta_bytes": target.stat().st_size if made.returncode == 0 else 0}
    (out / LIST).write_text(render_list(bundles), encoding="utf-8")
    result["upload"] = [name for name in (BASE, DELTA, LIST) if (out / name).exists()]
    return result


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--repo", type=Path, required=True)
    p.add_argument("--built", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--public", required=True)
    p.add_argument("--now", type=int, default=None)
    args = ap.parse_args(argv)
    print(json.dumps(plan(args.repo, args.built, args.out, args.public, args.now or int(time.time()))))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
