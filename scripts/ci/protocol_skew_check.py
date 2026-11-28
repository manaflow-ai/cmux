#!/usr/bin/env python3
"""Protocol skew: fail a pull request whose app, page or daemon would refuse a peer one version off.

cmux NEXT's chat page, the app's agent pane relay and the daemons do not update together: a web layer, a
`cmux customize use pr:N`, a nightly that is a day old, a remote daemon on another build. When one side
refuses a field or a method the other side sends, every chat fails to open. That happened three times
through the relay's params rule alone: cmux#42185 (`settled`), #42460 (`hold`), and #46563 (`initialize`
`_meta.acpmux.peerRowBatches`, refused 737 times on one NIGHTLY). Leo: "you need to be able to
fix/repair/prevent these in the future".

This gate judges the pull request's merge (HEAD) against each OLD ref: the base, and the commit the NEXT
nightly was built from when that is reachable. A missing ref is reported and skipped, never a pass that
judged nothing: the base is always there.

  1. new page, old relay: a method the page sends to open a chat (OPEN_PATH) that the old relay's
     policy.json does not list. The old relay refuses it and the chat never opens.
  2. new page, old relay: a key the merge's policy adds to an OPEN_PATH method, when the old relay still
     refuses unknown keys (no `stripping_unknown_params`, the P0 strip). Off the open path these are
     warnings: one control fails, not every chat.
  3. new relay, old page: a method the old page sends that the merge's policy drops. Every page still
     running the old build gets refused.
  4. new strict decoders: a line the pull request adds under cmux-tui/ or webviews/src/ that refuses
     unknown fields (`deny_unknown_fields`, `additionalProperties: false`, zod `.strict()`), and a resource
     operation the spec newly marks `"unknown_params": "refuse"` (`"extra": false` alone drops the field). Keep one strict on purpose (a token, a signature,
     a local config file) with `skew: strict <why>` on the line or the line above.

  protocol_skew_check.py --base SHA [--old SHA ...] [--nightly-feed URL] [--head REF]
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

POLICY = "cmux-tui/crates/cmux-agent-pane-policy/policy.json"
PARAMS_RS = "cmux-tui/crates/cmux-agent-pane-policy/src/params.rs"
PAGE = "webviews/src/agent-session/"
RESOURCE_SPEC = "cmux-tui/spec/resource-operations-v2.json"
# The frames a chat sends before it shows anything: a refusal of one fails the chat, not one control.
OPEN_PATH = ("initialize", "session/new", "session/load", "session/resume", "_acpmux/attach",
             "_acpmux/sessions", "_acpmux/status")
NIGHTLY_FEED = "https://files-next.cmux.com/nightly-next/appcast-arm64.xml"  # scripts/ci/nightly_next_feed_watch.py
SOURCE_COMMIT = re.compile(r"<cmux:sourceCommit[^>]*>\s*([0-9a-f]{40})\s*</cmux:sourceCommit>")
STRICT = re.compile(r"deny_unknown_fields|additionalProperties\"?\s*:\s*false|\.strict\(\)")
STRICT_PATHS = re.compile(r"^(cmux-tui/.*\.rs|webviews/src/.*\.(ts|tsx)|cmux-tui/spec/.*\.json)$")
ESCAPE = "skew: strict"


def git(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *args], check=check, capture_output=True, text=True)


def show(ref: str, path: str) -> str | None:
    done = git("show", f"{ref}:{path}", check=False)
    return done.stdout if done.returncode == 0 else None


def sends(ref: str, method: str) -> bool:
    """Whether the page at REF names METHOD as a string literal (what it sends; replies match too, harmlessly)."""
    pattern = f"[\"'`]{re.escape(method)}[\"'`]"
    return git("grep", "-q", "-E", pattern, ref, "--", PAGE, check=False).returncode == 0


def methods(policy: dict) -> set[str]:
    return set(policy.get("requests", [])) | set(policy.get("notifications", [])) | {policy.get("initialize", "")}


def known(policy: dict, method: str) -> set[str]:
    entry = policy.get("known_params", {}).get(method, {})
    return set(entry.get("params", [])) | {f"_meta.acpmux.{k}" for k in entry.get("acpmux", [])}


def nightly_commit(feed_url: str) -> str | None:
    try:
        # The CDN refuses Python's default User-Agent with a 403.
        request = urllib.request.Request(feed_url, headers={"User-Agent": "protocol-skew-check/1"})
        with urllib.request.urlopen(request, timeout=20) as response:  # noqa: S310 (a fixed https URL)
            feed = response.read().decode("utf-8", "replace")
    except (OSError, ValueError):
        return None
    # The highest build's commit: the nightly an updated app runs (an older one runs the base or newer).
    best: tuple[int, str] | None = None
    for item in re.findall(r"<item>.*?</item>", feed, re.S):
        version = re.search(r"<sparkle:version>\s*(\d+)\s*</sparkle:version>", item)
        commit = SOURCE_COMMIT.search(item)
        if version and commit and (best is None or int(version.group(1)) > best[0]):
            best = (int(version.group(1)), commit.group(1))
    return best[1] if best else None


def reachable(ref: str) -> bool:
    if git("cat-file", "-e", f"{ref}^{{commit}}", check=False).returncode == 0:
        return True
    shallow = git("rev-parse", "--is-shallow-repository", check=False).stdout.strip() == "true"
    git("fetch", "-q", *(["--depth=1"] if shallow else []), "origin", ref, check=False)
    return git("cat-file", "-e", f"{ref}^{{commit}}", check=False).returncode == 0


def judge_relay(head: str, old: str, label: str) -> tuple[list[str], list[str]]:
    """Rules 1 to 3 against OLD; (failures, warnings)."""
    fail: list[str] = []
    warn: list[str] = []
    new_text, old_text = show(head, POLICY), show(old, POLICY)
    if new_text is None or old_text is None:
        return fail, [f"{label}: no {POLICY} to compare"]
    new, prior = json.loads(new_text), json.loads(old_text)
    old_strips = "stripping_unknown_params" in (show(old, PARAMS_RS) or "")
    added = methods(new) - methods(prior)
    for method in sorted(added):
        if not sends(head, method):
            continue
        line = f"{label}: the page sends {method}, which that relay does not allow"
        (fail if method in OPEN_PATH else warn).append(line + (", so no chat opens" if method in OPEN_PATH else ""))
    if not old_strips:
        for method in sorted(methods(new) & methods(prior)):
            keys = sorted(known(new, method) - known(method=method, policy=prior))
            if keys:
                line = f"{label}: {method} gains {', '.join(keys)}, and that relay refuses keys it does not know"
                (fail if method in OPEN_PATH else warn).append(line)
    for method in sorted(methods(prior) - methods(new)):
        if sends(old, method):
            fail.append(f"{label}: the page there sends {method}, which this relay no longer allows")
    return fail, warn


def added_lines(base: str, head: str) -> list[tuple[str, int, str, str]]:
    """(path, line, text, the line above) for every line HEAD adds over BASE in STRICT_PATHS."""
    diff = git("diff", "--unified=1", "--no-color", f"{base}...{head}", "--", "cmux-tui", "webviews/src").stdout
    out: list[tuple[str, int, str, str]] = []
    path, number, previous = "", 0, ""
    for raw in diff.splitlines():
        if raw.startswith("+++ "):
            path = raw[6:] if raw.startswith("+++ b/") else ""
        elif raw.startswith("@@"):
            number = int(re.match(r"@@ -\S+ \+(\d+)", raw).group(1)) - 1
            previous = ""
        elif raw.startswith("+") and path:
            number += 1
            if STRICT_PATHS.match(path):
                out.append((path, number, raw[1:], previous))
            previous = raw[1:]
        elif raw.startswith(" "):
            number += 1
            previous = raw[1:]
    return out


def judge_decoders(base: str, head: str) -> list[str]:
    fail = []
    for path, number, text, above in added_lines(base, head):
        if path == RESOURCE_SPEC:
            continue
        if STRICT.search(text) and ESCAPE not in text and ESCAPE not in above:
            fail.append(f"{path}:{number}: a new decoder refuses unknown fields ({text.strip()[:80]}); "
                        f"an older or newer peer's chat fails on it. Ignore unknown fields, or say "
                        f"`{ESCAPE} <why>` beside it")
    new_spec, old_spec = show(head, RESOURCE_SPEC), show(base, RESOURCE_SPEC)
    if new_spec and old_spec:
        # `"extra": false` alone drops an undeclared param (catalog_validation.rs, #49712); only
        # `"unknown_params": "refuse"` refuses the request. Only an operation the old peer already knows can be
        # skewed: a new operation (born strict or not) has no older caller to send it unknown params.
        old_ops, new_ops = strict_ops(old_spec), strict_ops(new_spec)
        flipped = sorted(name for name, strict in new_ops.items() if strict and old_ops.get(name) is False)
        if flipped:
            fail.append(f"{RESOURCE_SPEC}: {len(flipped)} more operation(s) refuse unknown params "
                        f"(\"unknown_params\": \"refuse\"): {', '.join(flipped[:5])}")
    return fail


def strict_ops(spec: str) -> dict[str, bool]:
    """Each operation's name and whether it refuses unknown params; False means it takes them."""
    try:
        tree = json.loads(spec)
    except ValueError:
        return {}
    found: dict[str, bool] = {}

    def walk(node: object, name: str) -> None:
        if isinstance(node, dict):
            params = node.get("params")
            if isinstance(params, dict):
                found[name] = params.get("unknown_params") == "refuse"
            for key, child in node.items():
                walk(child, key)
        elif isinstance(node, list):
            for child in node:
                walk(child, name)

    walk(tree, "")
    return found


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--old", action="append", default=[], help="another deployed commit to judge against")
    parser.add_argument("--nightly-feed", default=NIGHTLY_FEED, help="'' skips the nightly")
    args = parser.parse_args(argv)
    olds = [(args.base, "base")] + [(sha, f"old {sha[:11]}") for sha in args.old]
    if args.nightly_feed:
        sha = nightly_commit(args.nightly_feed)
        if sha and reachable(sha):
            olds.append((sha, f"nightly {sha[:11]}"))
        else:
            print(f"protocol skew: the nightly's commit was not reachable ({sha or 'no feed'}); judged the base only")
    failures: list[str] = []
    for ref, label in olds:
        fail, warn = judge_relay(args.head, ref, label)
        # A skew the base already has against this build is not this change's: it fails the base and every PR
        # alike, and only a change on that old side (or it aging out of the feed) clears it.
        on_base = set(judge_relay(args.base, ref, label)[0]) if ref != args.base else set()
        failures += [line for line in fail if line not in on_base]
        for line in warn + [f"{line} (already on the base)" for line in fail if line in on_base]:
            print(f"::warning::protocol skew: {line}")
    failures += judge_decoders(args.base, args.head)
    for line in failures:
        print(f"::error::protocol skew: {line}")
    judged = ", ".join(label for _, label in olds)
    print(f"protocol skew: {len(failures)} refusal(s) against {judged}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
