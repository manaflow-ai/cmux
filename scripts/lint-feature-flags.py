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
  3. Zombie-flag guard: every flag has a reviewBy date (YYYY-MM-DD); a past
     date fails CI until the flag is removed or consciously extended.
  4. Safe defaults: every flag declares defaultWhenUnavailable.
  5. Single evaluation site: each key literal appears in at most one
     non-registry source file per surface (web, Swift), so removal is a
     two-line change and states don't multiply through business logic.
  6. No reuse: keys in scripts/retired-feature-flags.txt may never
     reappear anywhere.
"""

from __future__ import annotations

import datetime
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

errors: list[str] = []


def fail(msg: str) -> None:
    errors.append(msg)


def parse_web_registry(text: str) -> list[dict]:
    flags = []
    for block in re.finditer(r"\{[^{}]*key:\s*\"([^\"]+)\"[^{}]*\}", text, re.S):
        body = block.group(0)
        flag = {"key": block.group(1), "source": WEB_REGISTRY_REL}
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
        })
    return flags


def grep_key_files(key: str) -> set[str]:
    out = subprocess.run(
        ["git", "grep", "-l", "--untracked", "--fixed-strings", key, "--",
         "web", "Sources", "Packages", "ios", "CLI",
         ":!*node_modules*"],
        cwd=REPO, capture_output=True, text=True,
    )
    return {line.strip() for line in out.stdout.splitlines() if line.strip()}


def main() -> int:
    flags: list[dict] = []
    if WEB_REGISTRY.exists():
        flags += parse_web_registry(WEB_REGISTRY.read_text())
    swift_registries = swift_registry_files()
    for rel in swift_registries:
        path = REPO / rel
        if path.exists():
            flags += parse_swift_registry(path.read_text(), rel)

    if not flags:
        print("lint-feature-flags: no flags declared")
        return 0

    today = datetime.date.today()
    seen: dict[str, str] = {}
    # git grep returns repo-relative paths.
    registries = {WEB_REGISTRY_REL, *swift_registries}

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
        elif datetime.date.fromisoformat(review) < today:
            fail(
                f"{where}: '{key}' reviewBy {review} has passed — remove the "
                "zombie flag or consciously extend the date"
            )
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

    if errors:
        print("lint-feature-flags: FAILED")
        for e in errors:
            print(f"  - {e}")
        return 1
    print(f"lint-feature-flags: ok ({len(flags)} flag declaration(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
