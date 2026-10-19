#!/usr/bin/env python3
"""Grade a feat-cmux-next pull request low, medium or high risk by the paths it changes,
and check that its description carries the evidence that tier needs before merge.

The policy is docs/ci/risk-tiers.md. In short:

  low     docs, tests, skills, plans, and scripts/ tooling. Needs green CI.
  medium  app UI, SDK bindings, workflows that don't route checks, anything this file cannot
          place, and a runtime change (daemon, persistence, remote, typing path, agent backend)
          of RUNTIME_LINES lines or fewer. Also needs a screenshot or clip under `## Proof`
          (compared against cmux-design-references when one exists), or `Not UI: <why>`.
  high    at any size: signing, release, update, migrations, defaults, protocol data, vendored
          pins, merge gates and check routing. A runtime change over RUNTIME_LINES lines. Taking
          back a change merged in the last week (recent_reverts). Also needs `Review:` naming a
          reviewed commit and `Runtime test:` naming a run that executed the change.

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
import time
from dataclasses import dataclass, field
from pathlib import Path

TIERS = ("low", "medium", "high")
LABELS = {tier: f"risk:{tier}" for tier in TIERS}
WAIVED_LABEL = "risk:waived"
LARGE_LINES = 1000
# A runtime change (daemon, persistence, remote, typing path) over this many changed lines outside
# tests and generated files is high; at or under it, medium.
RUNTIME_LINES = 40
NEXT = "Packages/macOS/CmuxNext/Sources/"

# Ordered: the first matching rule wins, so specific high paths sit above broad low ones.
# Each rule is (tier, reason, patterns). Patterns are fnmatch globs on the repo path.
# A pattern starting with "re:" is a regular expression searched in the path.
RELEASE_WORDS = (
    r"re:(^|/)(scripts|\.github/workflows)/(.*/)?([^/]*[-_])?"
    r"(sign(ing)?|codesign|notari[sz]\w*|appcast|sparkle|release|publish|deploy|nightly|promote|rollback)([-_.][^/]*)?$"
)
RULES: tuple[tuple[str, str, tuple[str, ...]], ...] = (
    # First, so a gate named like a test (select_package_tests.py) is never graded low.
    # The merge gates and the workflows that decide which checks a pull request runs: one line
    # here can skip the tests every other pull request relies on (feat-cmux-next PRs stopped
    # running swift test through such a line), so any size is high.
    ("high", "merge gate or check routing", (
        ".github/CODEOWNERS", ".github/workflows/risk-tier.yml", ".github/workflows/cla*.yml",
        ".github/workflows/merge-*.yml", ".github/workflows/cmux-next.yml", ".github/workflows/ci.yml",
        ".github/workflows/ci-guards.yml", ".github/workflows/ci-macos.yml", ".github/workflows/cmux-tui.yml",
        "scripts/ci/risk_tier.py", "scripts/gh-merge-green", "scripts/ci/base_red_excuse.py",
        "scripts/ci/revert_pr.py", "scripts/ci/cmux_next_route.py", "scripts/ci/select_package_tests.py",
        "scripts/ci/merge_freeze.py", "scripts/ci/main_fix_evidence.py", "scripts/ci/vercel_merge_gate.py",
        "scripts/merge-main.sh", "scripts/cmux-next/check-no-godfiles.sh",
    )),
    ("low", "test", (
        "*/Tests/*", "*/tests/*", "tests/*", "tests_v2/*", "*/test/*", "*_test.*", "*_tests.*",
        "*/tests.rs", "*/test_*.py", "scripts/*/fixtures/*", "*.test.*", "*Tests.swift",
    )),
    # Scripts that only mention a release: notes, benchmarks, end-to-end probes, compile checks.
    ("low", "CI and tooling", (
        r"re:^scripts/.*(release[-_]notes|[-_]perf[-_]|[-_]e2e\.|release-compile|derived-data)",
    )),
    ("high", "signing, release or update path", (
        "*.entitlements", ".github/workflows/nightly*.yml", RELEASE_WORDS, NEXT + "CmuxNextUpdater/*",
        "scripts/ci/lib/*",
    )),
    # Stored data and contracts other builds read, and defaults every user gets: any size is high.
    ("high", "migration, default or protocol contract", (
        "*/migrations/*", "*migration*.swift", "*Migration*.swift", "*/migrate/*",
        "web/convex/schema*", "schemas/defaults/*", "schemas/*/migrations/*",
        "cmux-tui/spec/*.json", "cmux-tui/spec/*.jsonl", "plans/cmux-next/daemon-capabilities.json",
    )),
    ("high", "vendored pin or package graph", (
        "ghostty", "ghostty-next", "ghostty.h", "homebrew-cmux", ".xcode-version", "vendor/*", ".gitmodules",
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
        "cmux-tui/crates/cmux-palette-ranker/*", "Native/OptChat/*/inspector/*",
    )),
    # Runtime: high once the change is big enough to hide a behavior change (RUNTIME_LINES), medium
    # for a small one, which a reviewer can read whole.
    ("runtime", "daemon, persistence or remote access", (
        "backend/*", "schemas/*", NEXT + "CmuxNextHistory/*",
        "cmux-tui/*", "daemon/*", "mux/*", "server/*", "services/*", "workers/*",
        NEXT + "CmuxNextDaemon*", NEXT + "CmuxNextControl/*", NEXT + "CmuxNextServer*",
        NEXT + "CmuxNextRemote*", NEXT + "CmuxNextMobile/*", NEXT + "CmuxNextBridge/*",
        NEXT + "CmuxNextAccounts/*", NEXT + "CmuxNextAppPermissions/*",
        NEXT + "CmuxNextProcessEnvironment/*", NEXT + "CmuxNextMallocZone/*",
        NEXT + "CmuxNextCrashReporting/*", NEXT + "CmuxNextCLIInstall/*",
        NEXT + "CmuxNextComputerUse/*", NEXT + "CmuxNextBrowserHost/*",
        NEXT + "CmuxNextBrowserImport/*", NEXT + "CmuxNextBrowserAutomation/*", NEXT + "CmuxNextCloud/*",
        "Native/OptChat/*",
    )),
    ("runtime", "terminal input and rendering", (
        NEXT + "CmuxNextTerminal/*", NEXT + "CmuxNextTerminalGeometry/*", NEXT + "CmuxNextFocus/*",
    )),
    ("medium", "CI workflow", (".github/workflows/*", ".github/actions/*")),
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
    "*.sha256", "schemas/settings-export/*", "schemas/settings/settings-schema.json",
)

PROOF_HEADING = re.compile(r"^##+\s*(proof|screenshots?|evidence|demo|videos?|recordings?)\b", re.I | re.M)
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
    counted = runtime = 0
    runtime_files: list[tuple[str, str]] = []
    for path in files:
        tier, reason = classify_path(path)
        generated = any(matches(path, g) for g in GENERATED)
        if tier == "runtime":
            runtime_files.append((path, reason))
            runtime += 0 if generated else lines.get(path, 0)
            tier = "medium"
        else:
            reasons.setdefault(f"{tier}: {reason}", []).append(path)
        rank = max(rank, TIERS.index(tier))
        if tier != "low" and not generated:
            counted += lines.get(path, 0)
    runtime_tier = "high" if runtime > RUNTIME_LINES else "medium"
    for path, reason in runtime_files:
        size = f"{runtime} changed lines" + (f" > {RUNTIME_LINES}" if runtime_tier == "high" else f" <= {RUNTIME_LINES}")
        reasons.setdefault(f"{runtime_tier}: {reason} ({size})", []).append(path)
    rank = max(rank, TIERS.index(runtime_tier) if runtime_files else 0)
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


# A pull request that takes back another pull request's change from this recently is high: that is
# how a stale-base squash silently undoes other people's work (50a0c607aee undid #21369, #21384
# and #21199, all merged in the two days before it).
RECENT_DAYS = 7
MAX_BLAME_FILES = 60
# The whole revert check stops after this many seconds and lists what it didn't get to, so the
# job always finishes inside its own timeout (a timed-out check is red and can't be waived).
REVERT_BUDGET_SECONDS = 120
PR_SUFFIX = re.compile(r"\(#(\d+)\)\s*$")


def deleted_ranges(patch: str) -> list[tuple[int, int]]:
    """The base-side line ranges a unified diff patch deletes, merged into runs."""
    runs: list[tuple[int, int]] = []
    old = 0
    for line in patch.splitlines():
        hunk = re.match(r"^@@ -(\d+)(?:,\d+)? \+\d+(?:,\d+)? @@", line)
        if hunk:
            old = int(hunk.group(1))
            continue
        if line.startswith("-"):
            if runs and runs[-1][1] == old - 1:
                runs[-1] = (runs[-1][0], old)
            else:
                runs.append((old, old))
            old += 1
        elif line.startswith(" "):
            old += 1
    return runs


def diff_lines(patch: str) -> tuple[list[str], list[str]]:
    """The non-blank lines a patch removes and adds, stripped."""
    removed = [l[1:].strip() for l in patch.splitlines() if l.startswith("-") and not l.startswith("---")]
    added = [l[1:].strip() for l in patch.splitlines() if l.startswith("+") and not l.startswith("+++")]
    return [l for l in removed if l], [l for l in added if l]


def undoes(pr_patch: str, commit_patch: str, added_elsewhere: frozenset[str] = frozenset()) -> bool:
    """Whether a pull request's change to a file takes back a commit's change to it: it deletes
    most of what the commit added, and, when the commit replaced lines, puts most of them back."""
    pr_removed, pr_added = map(set, diff_lines(pr_patch))
    # A line the pull request removes and adds back, here or in another file, moved; it wasn't
    # taken back.
    gone, back = pr_removed - pr_added - added_elsewhere, pr_added - pr_removed
    commit_removed, commit_added = map(set, diff_lines(commit_patch))
    if not commit_added:
        return False
    if len(commit_added & gone) / len(commit_added) < 0.8:
        return False
    if not commit_removed:
        return True
    return len(commit_removed & back) / len(commit_removed) >= 0.5


def recent_reverts(entries: list[dict], repo_dir: str, base_sha: str, own: int,
                   now: float | None = None, unread: list[str] | None = None,
                   budget: float = REVERT_BUDGET_SECONDS) -> dict[int, list[str]]:
    """Pull requests (other than `own`) merged in the last RECENT_DAYS whose change to a file this
    pull request takes back, from `git blame` of the base: {pr number: [paths]}. The base's history
    only needs to reach RECENT_DAYS back; older lines blame to the shallow boundary and are skipped.
    Editing recent lines is ordinary; deleting what a recent commit added and restoring what it
    replaced is how a stale base undoes someone's work. Files git couldn't read in time are
    appended to `unread`, so the report can say what went unchecked."""
    cutoff = (now or time.time()) - RECENT_DAYS * 86400
    found: dict[int, list[str]] = {}
    added_anywhere = frozenset(line for e in entries for line in diff_lines(e.get("patch") or "")[1])
    deadline = time.monotonic() + budget
    for entry in entries[:MAX_BLAME_FILES]:
        path = entry.get("previous_filename") or entry["filename"]
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            if unread is not None and deleted_ranges(entry.get("patch") or ""):
                unread.append(path)
            continue
        patch = entry.get("patch") or ""
        ranges = deleted_ranges(patch)
        # Generated files follow their sources; a revert shows on the source.
        if not ranges or entry.get("status") == "added" or any(matches(path, g) for g in GENERATED):
            continue
        args = ["git", "-C", repo_dir, "blame", "--porcelain"]
        for start, end in ranges[:50]:
            args += ["-L", f"{start},{end}"]
        try:
            out = subprocess.run([*args, base_sha, "--", path], capture_output=True, text=True,
                                 timeout=min(30, max(1, remaining)))
        except subprocess.TimeoutExpired:
            out = None
        if out is None or out.returncode != 0:
            if unread is not None:
                unread.append(path)
            continue
        commits: dict[str, dict[str, str]] = {}
        current = None
        for line in out.stdout.splitlines():
            head = re.match(r"^([0-9a-f]{40}) \d+ \d+", line)
            if head:
                current = commits.setdefault(head.group(1), {})
            elif current is not None and line == "boundary":
                current["boundary"] = "1"
            elif current is not None and " " in line and not line.startswith("\t"):
                key, value = line.split(" ", 1)
                current.setdefault(key, value)
        for sha, info in commits.items():
            if "boundary" in info or int(info.get("committer-time", "0")) < cutoff:
                continue
            number = PR_SUFFIX.search(info.get("summary", ""))
            if not number or int(number.group(1)) == own:
                continue
            try:
                shown = subprocess.run(["git", "-C", repo_dir, "show", "--format=", sha, "--", path],
                                       capture_output=True, text=True,
                                       timeout=max(1, deadline - time.monotonic())).stdout
            except subprocess.TimeoutExpired:
                if unread is not None:
                    unread.append(path)
                continue
            if undoes(patch, shown, added_anywhere):
                found.setdefault(int(number.group(1)), []).append(path)
    return {number: sorted(set(paths)) for number, paths in found.items()}


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
    if args.repo_dir:
        unread: list[str] = []
        # The patches' line numbers are relative to the merge base, not the base branch's tip.
        try:
            merge_base = gh_json("api", f"repos/{args.repo}/compare/{pr['base']['sha']}...{pr['head']['sha']}",
                                 "--jq", "{sha: .merge_base_commit.sha}")["sha"]
        except (subprocess.CalledProcessError, json.JSONDecodeError, KeyError, TypeError):
            merge_base = pr["base"]["sha"]
        undone = recent_reverts(entries, args.repo_dir, merge_base, int(args.number), unread=unread)
        for number, paths in sorted(undone.items()):
            grade.reasons.setdefault(f"high: takes back #{number}'s change from the last {RECENT_DAYS} days "
                                     "(a stale base? say so if it's on purpose)", []).extend(paths)
        if undone:
            grade.tier = "high"
        if unread:
            # Not a reason to raise the tier, but never silent: the reviewer checks these by hand.
            grade.reasons.setdefault(f"{grade.tier}: the recent-revert check couldn't read these in time, "
                                     "so check them by hand", []).extend(sorted(set(unread)))
    missing = missing_evidence(grade.tier, pr.get("body") or "", commits)
    # Only consulted when evidence is missing; a lookup that fails reads as no waiver.
    waiver = None
    if missing and WAIVED_LABEL in labels:
        try:
            waiver = waived_by(args.repo, args.number)
        except (subprocess.CalledProcessError, json.JSONDecodeError):
            waiver = None
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


def printable(path: str) -> str:
    """A changed path as it may appear in a log or summary: no control characters (a newline in a
    file name could start a `::` workflow command), no backticks to break the code span."""
    return re.sub(r"[\x00-\x1f\x7f-\x9f\u2028\u2029`]", "?", path)


def render(grade: Grade, missing: list[str], waived: bool, waiver: str | None = None) -> str:
    out = [f"## Risk tier: {grade.tier}", ""]
    if grade.bumped:
        out.append(f"Raised from medium: {grade.counted_lines} changed lines outside tests and generated files "
                   f"(over {LARGE_LINES}).\n")
    for reason, paths in sorted(grade.reasons.items(), key=lambda kv: -TIERS.index(kv[0].split(":")[0])):
        shown = ", ".join(f"`{printable(p)}`" for p in paths[:5]) + (f" and {len(paths) - 5} more" if len(paths) > 5 else "")
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
    p.add_argument("--repo-dir", help="a clone holding the base commit and RECENT_DAYS of its history, "
                   "for the recent-deletion check (skipped without it)")
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
