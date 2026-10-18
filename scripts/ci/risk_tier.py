#!/usr/bin/env python3
"""Grade a feat-cmux-next pull request low, medium or high risk by the paths it changes,
and check that its description carries the evidence that tier needs before merge.

The policy is docs/ci/risk-tiers.md. In short:

  low     docs, tests, skills, plans, CI and tooling. Needs green CI.
  medium  app UI and anything this file cannot place. Also needs a screenshot or clip
          under `## Proof` (compared against cmux-design-references when one exists).
  high    the daemon and its protocol, persistence and migrations, the typing path,
          remote access, updates, signing and release, vendored pins. Also needs
          `Review:` naming a reviewed commit and `Runtime test:` naming a run that
          executed the change.

A pull request takes the highest tier of any file it changes. A medium pull request
that changes more than LARGE_LINES lines outside tests becomes high. A file nothing
here matches is medium, so a new directory is never graded low by accident.

Usage:
  risk_tier.py classify --files FILE [--numstat FILE] [--json]
  risk_tier.py evidence --tier TIER --body FILE [--commits FILE]
  risk_tier.py pr --repo OWNER/REPO --number N [--github-output FILE] [--summary FILE]
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

TIERS = ("low", "medium", "high")
LABELS = {tier: f"risk:{tier}" for tier in TIERS}
WAIVED_LABEL = "risk:waived"
LARGE_LINES = 1000
NEXT = "Packages/macOS/CmuxNext/Sources/"

# Ordered: the first matching rule wins, so specific high paths sit above broad low ones.
# Each rule is (tier, reason, patterns). Patterns are fnmatch globs on the repo path.
# A pattern starting with "re:" is a regular expression searched in the path.
RELEASE_WORDS = r"re:^(scripts|\.github/workflows)/(.*/)?([^/]*[-_])?(sign|codesign|notari[sz]\w*|appcast|sparkle|release|publish|deploy)([-_.][^/]*)?$"
RULES: tuple[tuple[str, str, tuple[str, ...]], ...] = (
    ("low", "test", (
        "*/Tests/*", "*/tests/*", "tests/*", "*/test/*", "*_test.*", "*.test.*", "*Tests.swift",
    )),
    # Scripts that only mention a release: notes, benchmarks, end-to-end probes, compile checks.
    ("low", "CI and tooling", (
        r"re:^scripts/.*(release[-_]notes|[-_]perf[-_]|[-_]e2e\.|release-compile|derived-data)",
    )),
    # The merge gates themselves: a change here changes what every other pull request must show.
    ("high", "merge gate or ownership", (
        ".github/CODEOWNERS", ".github/workflows/risk-tier.yml", ".github/workflows/cla*.yml",
        "scripts/ci/risk_tier.py", "scripts/gh-merge-green", "scripts/ci/base_red_excuse.py",
        "scripts/ci/revert_pr.py",
    )),
    ("high", "signing, release or update path", (
        "*.entitlements", ".github/workflows/nightly*.yml", RELEASE_WORDS, NEXT + "CmuxNextUpdater/*",
    )),
    ("high", "persistence, migration or protocol contract", (
        "*/migrations/*", "*migration*.swift", "*Migration*.swift", "*/migrate/*",
        "backend/*", "web/convex/schema*", "schemas/*",
        "cmux-tui/spec/*", "plans/cmux-next/daemon-capabilities.json", NEXT + "CmuxNextHistory/*",
    )),
    ("high", "vendored pin or package graph", (
        "ghostty", "ghostty-next", "vendor/*", ".gitmodules",
        "Packages/Shared/CmuxGhosttyKit/Package.swift", "scripts/cmux-next/cef-manifest.json",
        "scripts/cmux-next/cmux-tui.pin", "Packages/*/Package.swift", "Packages/*/Package.resolved",
        "*/Package.resolved",
    )),
    ("low", "docs, plans or skills", (
        "*.md", "*.mdx", "docs/*", "skills/*", "plans/*", "LICENSE*",
    )),
    # Generated SDK bindings and UI-only crates under cmux-tui/ ship outside the daemon.
    ("medium", "SDK bindings or UI crate", (
        "cmux-tui/bindings/*", "cmux-tui/crates/cmux-motion/*", "cmux-tui/crates/cmux-theme-tokens/*",
        "cmux-tui/crates/cmux-palette-ranker/*",
    )),
    ("high", "daemon, protocol or remote access", (
        "cmux-tui/*", "daemon/*", "mux/*", "server/*", "services/*", "workers/*",
        NEXT + "CmuxNextDaemon*", NEXT + "CmuxNextControl/*", NEXT + "CmuxNextServer*",
        NEXT + "CmuxNextRemote*", NEXT + "CmuxNextMobile/*", NEXT + "CmuxNextBridge/*",
        NEXT + "CmuxNextAccounts/*", NEXT + "CmuxNextAppPermissions/*",
        NEXT + "CmuxNextProcessEnvironment/*", NEXT + "CmuxNextMallocZone/*",
        NEXT + "CmuxNextCrashReporting/*", NEXT + "CmuxNextCLIInstall/*",
        NEXT + "CmuxNextComputerUse/*", NEXT + "CmuxNextBrowserHost/*",
        NEXT + "CmuxNextBrowserImport/*", NEXT + "CmuxNextBrowserAutomation/*", NEXT + "CmuxNextCloud/*",
    )),
    ("high", "terminal input and rendering", (
        NEXT + "CmuxNextTerminal/*", NEXT + "CmuxNextTerminalGeometry/*", NEXT + "CmuxNextFocus/*",
    )),
    ("low", "CI and tooling", (
        ".github/*", "scripts/*", ".claude/*", ".codex/*", ".agents/*", "tools/*",
        "biome.json", ".coderabbit.yaml", ".greptile/*", "dogfood/*", "experiments/*",
        "Prototypes/*", "KeyboardPinningLab/*", "samples/*", "examples/*",
    )),
    ("medium", "app UI", (
        "Packages/*", "App/*", "Native/*", "webviews/*", "ios/*", "Resources/*",
        "Assets.xcassets/*", "AppIcon.icon/*", "cmux.xcodeproj/*", "cmux.xcworkspace/*",
        "web/*", "design/*", "art/*", "images/*", "agent-chat/*", "first-party-apps/*",
        "clients/*", "libs/*", "cmux-browser/*", "coderouter/*", "config/*",
    )),
)

# Files that count toward the size bump: tests and generated output do not.
GENERATED = (
    "*.xcstrings", "*/Resources/agent-pane/*", "Resources/markdown-viewer/*", "*.lock",
    "*/ci-target-graph.json", "*.pbxproj", "*-lock.json", "*/generated/*", "*.generated.*",
)

PROOF_HEADING = re.compile(r"^##+\s*(proof|screenshots?|evidence)\b", re.I | re.M)
# An embedded image or video, an uploaded attachment, or a link to a media file. A bare URL
# ("CI only, see https://...") is not proof.
LINK = re.compile(
    r"(!\[[^\]]*\]\([^)]+\)|<img\s|<video\s|https://github\.com/user-attachments/\S+"
    r"|https?://\S+\.(png|jpe?g|gif|webp|mov|mp4|webm)\b)", re.I)
NOT_UI = re.compile(r"\bnot\s+ui\b\s*[:\-—]\s*\S+(\s+\S+){3,}", re.I)
REVIEW = re.compile(r"^[ \t]*[-*]?[ \t]*\**review\**[ \t]*:[ \t]*(\S.*)$", re.I | re.M)
RUNTIME = re.compile(r"^[ \t]*[-*]?[ \t]*\**runtime test\**[ \t]*:[ \t]*(\S.*)$", re.I | re.M)
SHA = re.compile(r"\b[0-9a-f]{7,40}\b", re.I)
RUN_URL = re.compile(r"https://github\.com/[\w.-]+/[\w.-]+/actions/runs/\d+")


def matches(path: str, pattern: str) -> bool:
    if pattern.startswith("re:"):
        return re.search(pattern[3:], path) is not None
    return fnmatch.fnmatchcase(path, pattern) or (pattern.endswith("/*") and path == pattern[:-2])


def classify_path(path: str) -> tuple[str, str]:
    for tier, reason, patterns in RULES:
        if any(matches(path, p) for p in patterns):
            return tier, reason
    return "medium", "unclassified path"


@dataclass
class Grade:
    tier: str
    reasons: dict[str, list[str]] = field(default_factory=dict)
    counted_lines: int = 0
    bumped: bool = False

    def as_json(self) -> dict:
        return {"tier": self.tier, "label": LABELS[self.tier], "reasons": self.reasons,
                "counted_lines": self.counted_lines, "size_bump": self.bumped}


def classify(files: list[str], lines: dict[str, int] | None = None) -> Grade:
    lines = lines or {}
    rank = 0
    reasons: dict[str, list[str]] = {}
    counted = 0
    for path in files:
        tier, reason = classify_path(path)
        rank = max(rank, TIERS.index(tier))
        reasons.setdefault(f"{tier}: {reason}", []).append(path)
        if tier != "low" and not any(matches(path, g) for g in GENERATED):
            counted += lines.get(path, 0)
    grade = Grade(TIERS[rank], reasons, counted)
    if grade.tier == "medium" and counted > LARGE_LINES:
        grade.tier, grade.bumped = "high", True
    return grade


def section(body: str, heading: re.Pattern[str]) -> str:
    match = heading.search(body)
    if not match:
        return ""
    rest = body[match.end():]
    end = re.search(r"^##?\s", rest, re.M)
    return rest[: end.start()] if end else rest


def strip_comments(body: str) -> str:
    return re.sub(r"<!--.*?-->", "", body, flags=re.S)


def on_pr(shas: list[str], commits: list[str]) -> bool:
    return any(c.lower().startswith(s.lower()) for s in shas for c in commits)


def missing_evidence(tier: str, body: str, commits: list[str] | None = None) -> list[str]:
    """What the description still needs for this tier. Empty means ready."""
    body = strip_comments(body or "")
    missing = []
    if tier in ("medium", "high"):
        proof = section(body, PROOF_HEADING)
        if not (LINK.search(proof) or NOT_UI.search(proof)):
            missing.append(
                "a screenshot or clip under `## Proof`, compared against cmux-design-references when "
                "a reference exists (or `Not UI: <why>` when nothing user-visible changes)")
    if tier == "high":
        review = REVIEW.search(body)
        shas = SHA.findall(review.group(1)) if review else []
        if not shas:
            missing.append("`Review:` naming the verdict and the commit SHA the independent review read")
        elif commits is not None and not on_pr(shas, commits):
            missing.append(f"`Review:` names {', '.join(shas)}, which is not a commit on this pull request")
        runtime = RUNTIME.search(body)
        line = runtime.group(1) if runtime else ""
        runtime_shas = SHA.findall(line)
        if not (RUN_URL.search(line) or (runtime_shas and (commits is None or on_pr(runtime_shas, commits)))):
            missing.append(
                "`Runtime test:` naming the test and the CI run URL (or the commit of this pull request "
                "a tagged build ran) where it executed this change")
    return missing


def gh_json(*args: str):
    out = subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout
    return json.loads(out) if out.strip() else None


def gh_items(endpoint: str) -> list[dict]:
    """Every item of a paginated list endpoint, one JSON object per line (no --slurp on older gh)."""
    out = subprocess.run(["gh", "api", "--paginate", endpoint, "--jq", ".[] | @json"],
                         check=True, capture_output=True, text=True).stdout
    return [json.loads(line) for line in out.splitlines() if line.strip()]


def pr_mode(args: argparse.Namespace) -> int:
    base = f"repos/{args.repo}/pulls/{args.number}"
    entries = gh_items(f"{base}/files?per_page=100")
    files = [f["filename"] for f in entries]
    lines = {f["filename"]: f.get("additions", 0) + f.get("deletions", 0) for f in entries}
    # A rename moves the old path too: grade both ends.
    files += [f["previous_filename"] for f in entries if f.get("previous_filename")]
    pr = gh_json("api", base)
    commits = [c["sha"] for c in gh_items(f"{base}/commits?per_page=100")]
    labels = {label["name"] for label in pr.get("labels", [])}
    grade = classify(files, lines)
    missing = missing_evidence(grade.tier, pr.get("body") or "", commits)
    waiver = waived_by(args.repo, args.number) if WAIVED_LABEL in labels else None
    waived = waiver is not None
    report = render(grade, missing, waived, waiver)
    print(report)
    if args.summary:
        Path(args.summary).open("a").write(report + "\n")
    if args.github_output:
        with Path(args.github_output).open("a") as out:
            out.write(f"tier={grade.tier}\nlabel={LABELS[grade.tier]}\n")
            out.write(f"ready={'true' if waived or not missing else 'false'}\n")
    return 0


def last_labeler(events: list[dict], name: str) -> str | None:
    """Who added the label, if it is still on: the last add, cleared by a later removal."""
    actor = None
    for event in events:
        if (event.get("label") or {}).get("name") != name:
            continue
        if event.get("event") == "labeled":
            actor = (event.get("actor") or {}).get("login")
        elif event.get("event") == "unlabeled":
            actor = None
    return actor


def waived_by(repo: str, number: str) -> str | None:
    """The maintainer (admin or maintain role) who added risk:waived, else None: a waiver from
    anyone with only triage or write access doesn't count."""
    actor = last_labeler(gh_items(f"repos/{repo}/issues/{number}/events?per_page=100"), WAIVED_LABEL)
    if not actor:
        return None
    role = (gh_json("api", f"repos/{repo}/collaborators/{actor}/permission") or {}).get("role_name")
    return actor if role in ("admin", "maintain") else None


def render(grade: Grade, missing: list[str], waived: bool, waiver: str | None = None) -> str:
    out = [f"## Risk tier: {grade.tier}", ""]
    if grade.bumped:
        out.append(f"Raised from medium: {grade.counted_lines} changed lines outside tests and generated files "
                   f"(over {LARGE_LINES}).\n")
    for reason, paths in sorted(grade.reasons.items(), key=lambda kv: -TIERS.index(kv[0].split(":")[0])):
        shown = ", ".join(f"`{p}`" for p in paths[:5]) + (f" and {len(paths) - 5} more" if len(paths) > 5 else "")
        out.append(f"- {reason}: {shown}")
    out.append("")
    if waived:
        out.append(f"`{WAIVED_LABEL}` is set by @{waiver}: a maintainer accepted this pull request "
                   "without the tier's evidence.")
    elif missing:
        out.append("Before merge, the description needs:")
        out += [f"- {item}" for item in missing]
    else:
        out.append("The description has the evidence this tier needs.")
    out.append("\nPolicy: docs/ci/risk-tiers.md")
    return "\n".join(out)


def read_lines(path: str | None) -> list[str]:
    if not path:
        return []
    return [line.strip() for line in Path(path).read_text().splitlines() if line.strip()]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="mode", required=True)
    c = sub.add_parser("classify")
    c.add_argument("--files", required=True, help="one changed path per line")
    c.add_argument("--numstat", help="`git diff --numstat` output, for the size bump")
    c.add_argument("--json", action="store_true")
    e = sub.add_parser("evidence")
    e.add_argument("--tier", choices=TIERS, required=True)
    e.add_argument("--body", required=True)
    e.add_argument("--commits")
    p = sub.add_parser("pr")
    p.add_argument("--repo", required=True)
    p.add_argument("--number", required=True)
    p.add_argument("--github-output")
    p.add_argument("--summary")
    args = parser.parse_args(argv)

    if args.mode == "classify":
        lines: dict[str, int] = {}
        for row in read_lines(args.numstat):
            added, deleted, path = row.split("\t", 2)
            lines[path] = (int(added) if added.isdigit() else 0) + (int(deleted) if deleted.isdigit() else 0)
        grade = classify(read_lines(args.files), lines)
        print(json.dumps(grade.as_json(), indent=2) if args.json else grade.tier)
        return 0
    if args.mode == "evidence":
        commits = read_lines(args.commits) if args.commits else None
        missing = missing_evidence(args.tier, Path(args.body).read_text(), commits)
        for item in missing:
            print(f"missing: {item}")
        return 1 if missing else 0
    return pr_mode(args)


if __name__ == "__main__":
    sys.exit(main())
