#!/usr/bin/env python3
"""Lint PostHog feature flags against the rules from
https://posthog.com/newsletter/feature-flag-mistakes.

Registries:
  - web/app/lib/feature-flags.ts   (FEATURE_FLAGS object literals)
  - Sources/FeatureFlags.swift     (FLAG(...) comments)

Enforced rules:
  1. Naming: kebab-case, a type suffix (-release / -experiment /
     -permission), positive phrasing (no not/disable/hidden negations).
  2. Ownership: every flag names an owner.
  3. Zombie-flag guard: every flag has a reviewBy date (YYYY-MM-DD); a
     missing or malformed date always fails. A past date is a warning, and
     fails only when the change being checked edits that flag's own
     declaration, so an expired flag cannot be edited without removing it or
     consciously extending the date. A calendar date never turns main or an
     unrelated PR red; the scheduled feature-flag-review-drift issue mentions
     the owner instead. The diff base is --base, FEATURE_FLAG_LINT_BASE, HEAD^1
     in CI (the PR merge commit's base side), or locally the merge-base with
     the remote default branch; with none, past dates only warn.
  4. Safe defaults: every flag declares defaultWhenUnavailable.
  5. Single evaluation site: each key literal appears in at most one
     non-registry source file per surface (web, Swift), so removal is a
     two-line change and states don't multiply through business logic.
  6. No reuse: keys in scripts/retired-feature-flags.txt may never
     reappear anywhere.
"""

from __future__ import annotations

import argparse
import datetime
import os
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
WEB_REGISTRY_REL = "web/app/lib/feature-flags.ts"
WEB_REGISTRY = REPO / WEB_REGISTRY_REL
RETIRED = REPO / "scripts/retired-feature-flags.txt"

# Discovery and parsing must agree on what counts as a declaration, or a file is
# found by one and misread by the other. A declaration is literally `FLAG(key:`.
# A prose reference such as `// FLAG(sidebar-appkit-list-experiment): ...`
# (Sources/ContentView.swift:1771) is not one, and matching it would report
# "flag entry without a key" against an untouched comment instead of against the
# flag someone just declared beside the code that reads it.
FLAG_DECLARATION = "FLAG(key:"
FLAG_RE = re.compile(r"FLAG\((?=key:)([^)]*)\)", re.S)

NAME_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*-(release|experiment|permission)$")
NEGATION_RE = re.compile(r"(^|-)(not|no|disable|disabled|hide|hidden)(-|$)")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

HUNK_RE = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")

errors: list[str] = []
warnings: list[str] = []


def fail(msg: str) -> None:
    errors.append(msg)


def line_span(text: str, match: re.Match) -> tuple[int, int]:
    """1-based first and last line of a declaration."""
    first = text.count("\n", 0, match.start()) + 1
    return first, first + text.count("\n", match.start(), match.end())


def parse_web_registry(text: str) -> list[dict]:
    flags = []
    for block in re.finditer(r"\{[^{}]*key:\s*\"([^\"]+)\"[^{}]*\}", text, re.S):
        body = block.group(0)
        flag = {"key": block.group(1), "source": WEB_REGISTRY_REL,
                "lines": line_span(text, block)}
        for field in ("owner", "reviewBy"):
            m = re.search(rf"{field}:\s*\"([^\"]+)\"", body)
            flag[field] = m.group(1) if m else None
        flag["hasDefault"] = "defaultWhenUnavailable:" in body
        flags.append(flag)
    return flags


def swift_registry_files() -> list[str]:
    """Every Swift file that declares a flag, not one hardcoded path.

    A FLAG( comment outside the single hardcoded registry used to be invisible:
    the flag was silently exempt from every rule below, including the zombie
    reviewBy check it was relying on.
    """
    out = subprocess.run(
        ["git", "grep", "-l", "--untracked", "--fixed-strings", FLAG_DECLARATION, "--",
         "Sources", "Packages", "CLI", "ios", ":!*node_modules*"],
        cwd=REPO, capture_output=True, text=True,
    )
    return sorted({line.strip() for line in out.stdout.splitlines() if line.strip()})


def parse_swift_registry(text: str, source: str) -> list[dict]:
    flags = []
    for m in FLAG_RE.finditer(text):
        body = re.sub(r"\n\s*//\s*", " ", m.group(1))
        fields = dict(
            (k.strip(), v.strip())
            for k, v in (pair.split(":", 1) for pair in body.split(",") if ":" in pair)
        )
        flags.append({
            "key": fields.get("key"),
            "owner": fields.get("owner"),
            "reviewBy": fields.get("reviewBy"),
            "hasDefault": "defaultWhenUnavailable" in fields,
            "source": source,
            "lines": line_span(text, m),
        })
    return flags


def collect_flags() -> tuple[list[dict], list[str]]:
    """Return declarations and the registry paths discovered in the same walk."""
    flags: list[dict] = []
    if WEB_REGISTRY.exists():
        flags += parse_web_registry(WEB_REGISTRY.read_text(encoding="utf-8", errors="replace"))
    swift_registries = swift_registry_files()
    for rel in swift_registries:
        path = REPO / rel
        if path.exists():
            flags += parse_swift_registry(path.read_text(encoding="utf-8", errors="replace"), rel)
    return flags, [WEB_REGISTRY_REL, *swift_registries]


def grep_key_files(key: str) -> set[str]:
    out = subprocess.run(
        ["git", "grep", "-l", "--untracked", "--fixed-strings", key, "--",
         "web", "Sources", "Packages", "ios", "CLI",
         ":!*node_modules*"],
        cwd=REPO, capture_output=True, text=True,
    )
    return {line.strip() for line in out.stdout.splitlines() if line.strip()}


def git_ok(*args: str) -> str | None:
    try:
        out = subprocess.run(["git", *args], cwd=REPO, capture_output=True, text=True,
                             timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    return out.stdout.strip() if out.returncode == 0 else None


def default_base() -> str | None:
    """The commit this change is measured against, or None when unknown."""
    explicit = os.environ.get("FEATURE_FLAG_LINT_BASE", "").strip()
    if explicit:
        return explicit
    if os.environ.get("GITHUB_ACTIONS") or os.environ.get("CI"):
        # A pull_request checkout is the merge commit; its first parent is the
        # base branch tip. On a push it is the previous commit.
        return git_ok("rev-parse", "--verify", "-q", "HEAD^1^{commit}")
    for remote in ("upstream", "origin"):
        ref = git_ok("symbolic-ref", "-q", f"refs/remotes/{remote}/HEAD")
        if ref:
            merge_base = git_ok("merge-base", ref, "HEAD")
            if merge_base:
                return merge_base
    return None


def changed_lines(base: str, paths: list[str]) -> dict[str, list[tuple[int, int]]] | None:
    """New-side line ranges each path changes since base, working tree included.

    A pure deletion after line N is recorded as the reversed range (N + 1, N),
    which touches a declaration only when it falls strictly inside it.
    """
    if not paths:
        return {}
    try:
        out = subprocess.run(
            ["git", "diff", "--no-color", "--no-ext-diff", "--no-renames", "-U0",
             base, "--", *paths],
            cwd=REPO, capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    ranges: dict[str, list[tuple[int, int]]] = {}
    path = None
    for line in out.stdout.splitlines():
        if line.startswith("+++ "):
            target = line[4:]
            path = target[2:] if target.startswith("b/") else None
        elif path and (hunk := HUNK_RE.match(line)):
            start = int(hunk.group(1))
            count = int(hunk.group(2)) if hunk.group(2) is not None else 1
            if count == 0:
                # Deletion between lines start and start + 1.
                ranges.setdefault(path, []).append((start + 1, start))
            else:
                ranges.setdefault(path, []).append((start, start + count - 1))
    return ranges


def touches(flag: dict, changes: dict[str, list[tuple[int, int]]]) -> bool:
    span = flag.get("lines")
    if not span:
        return False
    first, last = span
    for start, end in changes.get(flag["source"], []):
        if end < start:  # deletion between end and start
            if first <= end and start <= last:
                return True
        elif start <= last and first <= end:
            return True
    return False


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Lint PostHog feature flag declarations.")
    parser.add_argument(
        "--base", metavar="REF",
        help="fail an expired reviewBy only where the diff since REF edits that flag "
             "(default: FEATURE_FLAG_LINT_BASE, HEAD^1 in CI, else the merge-base "
             "with the remote default branch)")
    args = parser.parse_args([] if argv is None else argv)
    warnings.clear()
    flags, registry_files = collect_flags()

    if not flags:
        print("lint-feature-flags: no flags declared")
        return 0

    today = datetime.date.today()
    base = args.base or default_base()
    changes = changed_lines(base, registry_files) if base else None
    if base and changes is None:
        print(f"lint-feature-flags: could not diff against {base}; "
              "expired reviewBy dates are warnings only")
    seen: dict[str, str] = {}
    # git grep returns repo-relative paths.
    registries = set(registry_files)

    retired = set()
    if RETIRED.exists():
        retired = {
            line.strip()
            for line in RETIRED.read_text().splitlines()
            if line.strip() and not line.startswith("#")
        }

    for flag in flags:
        key = flag.get("key")
        where = flag["source"]
        if not key:
            fail(f"{where}: flag entry without a key")
            continue
        if key in seen and seen[key] != where:
            # Same key on two surfaces is allowed only when intentional; the
            # registries must both document it. Different concepts must not
            # share a key.
            pass
        seen[key] = where
        if not NAME_RE.match(key):
            fail(
                f"{where}: '{key}' must be kebab-case with a type suffix "
                "(-release, -experiment, -permission)"
            )
        if NEGATION_RE.search(key):
            fail(f"{where}: '{key}' uses negative phrasing; name flags positively")
        if not flag.get("owner"):
            fail(f"{where}: '{key}' has no owner")
        review = flag.get("reviewBy")
        if not review or not DATE_RE.match(review):
            fail(f"{where}: '{key}' needs reviewBy: YYYY-MM-DD")
        else:
            try:
                review_date = datetime.date.fromisoformat(review)
            except ValueError:
                fail(f"{where}: '{key}' needs reviewBy: YYYY-MM-DD")
            else:
                if review_date < today:
                    message = (
                        f"{where}: '{key}' reviewBy {review} has passed — remove the "
                        f"zombie flag or consciously extend the date (owner: "
                        f"{flag.get('owner') or 'none'})"
                    )
                    if changes is not None and touches(flag, changes):
                        fail(f"{message}; this change edits its declaration")
                    else:
                        warnings.append(message)
        if not flag.get("hasDefault"):
            fail(f"{where}: '{key}' must declare defaultWhenUnavailable")
        if key in retired:
            fail(f"{where}: '{key}' is retired (scripts/retired-feature-flags.txt); never reuse keys")

        usage = grep_key_files(key) - registries
        # One evaluation site per surface keeps flags removable.
        web_uses = [f for f in usage if f.startswith("web/")]
        swift_uses = [f for f in usage if not f.startswith("web/")]
        if len(web_uses) > 1:
            fail(f"'{key}' evaluated in multiple web files: {sorted(web_uses)}")
        if len(swift_uses) > 1:
            fail(f"'{key}' evaluated in multiple app files: {sorted(swift_uses)}")

    for key in retired:
        for f in grep_key_files(key):
            fail(f"retired flag key '{key}' still referenced in {f}")

    for warning in warnings:
        print(f"lint-feature-flags: warning: {warning}")
    if errors:
        print("lint-feature-flags: FAILED")
        for e in errors:
            print(f"  - {e}")
        return 1
    print(f"lint-feature-flags: ok ({len(flags)} flag declaration(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
