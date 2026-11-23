#!/usr/bin/env python3
"""zizmor and gitleaks as a CI check: a change fails only on a real security hole it adds itself.

zizmor.sh and gitleaks.sh report and always exit 0 when their tool ran. This runs one of them on the change
(a pull request's merge commit against its first parent, a push against the previous tip, a local branch against
where it meets origin/feat-cmux-next or origin/main) and judges what the change adds:

  ratchet.py zizmor     zizmor over every workflow and composite action the change adds or edits, at the base and
                        at the head; a finding is new when the head has more of its file, audit, severity and
                        confidence than the base. A new finding in ZIZMOR_HOLES (a root .github/ file, severity
                        High, the audit's own condition) is ::error and fails; every other new finding is a
                        ::warning. Then the whole repository's totals, report-only.
  ratchet.py gitleaks   gitleaks over the change's commits (each first-parent diff), values redacted. The scope is
                        the change, so every finding is new and every one fails: a leaked secret. A known
                        non-secret goes into gitleaks/gitleaks.toml's allowlist; a real one is rotated.

The decision (the interim coordinator, for Leo, 2026-11-22): "make them fail a PR only on findings
that PR introduces and that are a real security hole: a leaked secret, untrusted input reaching a privileged
workflow, a poisoned cache that later jobs trust. Everything already on base, and lower-severity findings, stays
report-only." CMUX_STATIC_ANALYSIS_BLOCKING=0 makes the holes warnings too (the switch, top of ci-guards.yml).

--base SHA and --head REV judge any pair of commits (the backtest over merged pull requests); --head skips the
whole-repository totals. zizmor runs offline (no token), so a finding does not depend on the network.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
CRASH = "zizmor-could-not-audit"
AUDITED = re.compile(r"(^\.github/workflows/[^/]+\.ya?ml$|(^|/)action\.ya?ml$)")

# The zizmor audits that fail a change that adds one: each a way for untrusted input to reach a privileged
# workflow, a poisoned cache a later job trusts, or a credential left where a later step or artifact leaks it.
# Only at severity High, and only in the repository's own .github/ (an action.yml elsewhere is a test fixture
# GitHub never runs). Any audit not named here, at any severity, is report-only.
ZIZMOR_HOLES: dict[str, str] = {
    "template-injection": "an attacker-controllable ${{ }} expands into a run: script",
    "dangerous-triggers": "pull_request_target or workflow_run that checks out the pull request's head",
    "cache-poisoning": "a release or publish workflow restores a cache a less trusted run can write",
    "artipacked": "checkout credentials persisted where an uploaded artifact carries them (high confidence)",
    "insecure-commands": "ACTIONS_ALLOW_UNSECURE_COMMANDS lets step output set env and PATH",
    "hardcoded-container-credentials": "a container registry password in the workflow text",
    "bot-conditions": "a spoofable bot-actor check guards a privileged trigger",
}

# An actions/checkout (or a git or gh command) that takes the pull request's own head: with a privileged trigger,
# the head's code then runs with the base's token and secrets.
HEAD_REF = r"(pull_request\.head\.(sha|ref)|workflow_run\.head_(sha|branch)|github\.head_ref|refs/pull/)"
SHELL_HEAD_CHECKOUT = re.compile(r"\b(git\s+(checkout|switch|worktree\s+add)|gh\s+pr\s+checkout)\b.*" + HEAD_REF)


class ToolDidNotRun(Exception):
    pass


def blocking() -> bool:
    """A hole fails the job unless CMUX_STATIC_ANALYSIS_BLOCKING is 0."""
    return os.environ.get("CMUX_STATIC_ANALYSIS_BLOCKING", "1") != "0"


def annotate(level: str, file: str, message: str, line: int | None = None) -> str:
    where = f"file={file}" + (f",line={line}" if line else "")
    return f"::{level} {where}::{message}"


def summarize(lines: list[str]) -> None:
    """Append to the GitHub step summary when there is one (CI)."""
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n\n")


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, check=True, capture_output=True, text=True).stdout.strip()


def git_ok(*args: str) -> bool:
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True).returncode == 0


def has_commit(rev: str) -> bool:
    return git_ok("cat-file", "-e", f"{rev}^{{commit}}")


def fetch_commit(sha: str) -> None:
    """A depth-1 checkout lacks the base; its trees come now and its blobs on demand (partial clone)."""
    if not has_commit(sha):
        git("fetch", "--quiet", "--no-tags", "--depth=1", "--filter=blob:none", "origin", sha)


def resolve_base(head: str) -> str | None:
    """Where the change starts: a merge commit's first parent (a pull request's synthetic merge), else
    CMUX_GUARDS_BASE_SHA (a push's previous tip), else in CI the first parent, else locally where the branch meets
    the closer of origin/feat-cmux-next and origin/main. None when there is nothing to compare with."""
    parents = re.findall(r"^parent ([0-9a-f]{40})$", git("cat-file", "-p", f"{head}^{{commit}}"), re.M)
    if len(parents) > 1:
        fetch_commit(parents[0])
        return parents[0]
    env_base = os.environ.get("CMUX_GUARDS_BASE_SHA", "")
    if re.fullmatch(r"[0-9a-f]{40}", env_base) and env_base.strip("0"):
        try:
            fetch_commit(env_base)
        except subprocess.CalledProcessError:
            env_base = ""
        if env_base:
            return env_base
    if os.environ.get("GITHUB_ACTIONS") == "true" and parents:
        fetch_commit(parents[0])
        return parents[0]
    best: tuple[int, str] | None = None
    for ref in ("origin/feat-cmux-next", "origin/main"):
        if not has_commit(ref):
            continue
        try:
            mb = git("merge-base", ref, head)
            n = int(git("rev-list", "--count", f"{mb}..{head}"))
        except subprocess.CalledProcessError:
            continue
        if best is None or n < best[0]:
            best = (n, mb)
    return best[1] if best else None


def run_tool(script: str, out_dir: Path, extra_env: dict[str, str]) -> None:
    env = {k: v for k, v in os.environ.items() if k not in ("GH_TOKEN", "GITHUB_TOKEN")}
    env.update(extra_env)
    env["FAST_CHECKS_OUT"] = str(out_dir)
    proc = subprocess.run(["bash", str(HERE / script)], cwd=ROOT, env=env,
                          stdout=subprocess.PIPE if extra_env.get("ZIZMOR_TREE") else None, text=True)
    if proc.returncode != 0:
        if proc.stdout:
            print(proc.stdout)
        raise ToolDidNotRun(f"ratchet: {script} did not run (exit {proc.returncode}); see its output above")


def finding_key(finding: dict) -> tuple[str, str, int]:
    """(path|audit|severity|confidence, path, 1-based line) of a finding's primary location."""
    primary = [l for l in finding.get("locations", []) if l["symbolic"]["kind"] == "Primary"]
    location = (primary or finding["locations"])[0]
    path = location["symbolic"]["key"]["Local"]["verbatim_path"]
    d = finding["determinations"]
    row = location.get("concrete", {}).get("location", {}).get("start_point", {}).get("row", 0)
    return f"{path}|{finding['ident']}|{d['severity']}|{d.get('confidence', '-')}", path, row + 1


def zizmor_counts(findings: list[dict], report_text: str) -> Counter:
    """Findings per file, audit, severity and confidence, not per line, so moving a line keeps its finding's key."""
    counts: Counter = Counter(finding_key(f)[0] for f in findings)
    for path in re.findall(r"^zizmor failed: (.+) \(exit \d+\)$", report_text, re.M):
        counts[f"{path}|{CRASH}|-|-"] += 1
    return counts


def new_findings(base: Counter, head: Counter, renames: dict[str, str]) -> dict[str, tuple[int, int]]:
    """key -> (base count, head count) for each key the head has more of. renames maps a base path to its head path."""
    moved: Counter = Counter()
    for key, n in base.items():
        path, rest = key.split("|", 1)
        moved[f"{renames.get(path, path)}|{rest}"] += n
    return {k: (moved.get(k, 0), n) for k, n in sorted(head.items()) if n > moved.get(k, 0)}


def checks_out_head(workflow_text: str) -> bool:
    """Whether a workflow takes the pull request's head into its workspace: an actions/checkout whose ref: names it,
    or a git checkout/switch/worktree add or gh pr checkout of it. Reading the head's sha for an API call is not."""
    lines = workflow_text.splitlines()
    for i, line in enumerate(lines):
        if SHELL_HEAD_CHECKOUT.search(line):
            return True
        m = re.match(r"^(\s*)(-\s+)?uses:\s*['\"]?actions/checkout@", line)
        if not m:
            continue
        indent = len(m.group(1))
        for nxt in lines[i + 1:]:
            if nxt.strip() and (len(nxt) - len(nxt.lstrip()) <= indent or nxt.lstrip().startswith("- ")):
                break
            if re.match(r"^\s*ref:", nxt) and re.search(HEAD_REF, nxt):
                return True
    return False


def is_hole(key: str, head_text: str) -> bool:
    """Whether a new zizmor finding fails the change (ZIZMOR_HOLES)."""
    path, ident, severity, confidence = key.split("|")
    if not path.startswith(".github/") or ident not in ZIZMOR_HOLES or severity != "High":
        return False
    if ident == "artipacked":
        return confidence == "High"
    if ident == "dangerous-triggers":
        return checks_out_head(head_text)
    return True


def changed_audited(base: str, head: str) -> tuple[list[str], dict[str, str], list[str]]:
    """(head paths zizmor audits that the change adds or edits, base path -> head path for renames, their base paths)."""
    out = subprocess.run(["git", "diff", "--name-status", "-z", "-M", base, head], cwd=ROOT, check=True,
                         capture_output=True, text=True).stdout.split("\0")
    head_paths, renames, base_paths = [], {}, []
    i = 0
    while i < len(out) - 1:
        status = out[i]
        if status[:1] in "RC":
            old, new = out[i + 1], out[i + 2]
            i += 3
        else:
            old = new = out[i + 1]
            i += 2
        if status[:1] == "D" or not AUDITED.search(new):
            continue
        head_paths.append(new)
        if status[:1] == "R":
            renames[old] = new
        if status[:1] in "MR" and AUDITED.search(old):
            base_paths.append(old)
    return head_paths, renames, base_paths


def zizmor_at(rev: str, paths: list[str], tmp: Path) -> tuple[list[dict], str]:
    """zizmor over these files as they are at rev, from a tree of only them, so each keeps its repository path."""
    tree = tmp / "tree"
    for p in paths:
        target = tree / p
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(subprocess.run(["git", "show", f"{rev}:{p}"], cwd=ROOT, check=True,
                                          capture_output=True).stdout)
    tree.mkdir(exist_ok=True)
    out = tmp / "out"
    run_tool("zizmor.sh", out, {"ZIZMOR_PERSONA": "regular", "ZIZMOR_TREE": str(tree)})
    return json.loads((out / "zizmor.json").read_text()), (out / "zizmor.txt").read_text()


def zizmor(base: str, head: str, whole_repo: bool) -> int:
    head_paths, renames, base_paths = changed_audited(base, head)
    holes: list[str] = []
    print(f"ratchet: zizmor over the {len(head_paths)} workflows and actions {head[:12]} adds or edits against {base[:12]}")
    if head_paths:
        with tempfile.TemporaryDirectory() as b, tempfile.TemporaryDirectory() as h:
            base_findings, base_txt = zizmor_at(base, base_paths, Path(b))
            head_findings, head_txt = zizmor_at(head, head_paths, Path(h))
        base_counts, head_counts = zizmor_counts(base_findings, base_txt), zizmor_counts(head_findings, head_txt)
        print(f"ratchet: in those files the base has {sum(base_counts.values())} findings, the head "
              f"{sum(head_counts.values())}")
        new = new_findings(base_counts, head_counts, renames)
        lines: dict[str, list[int]] = {}
        for f in head_findings:
            key, _, line = finding_key(f)
            lines.setdefault(key, []).append(line)
        texts = {p: subprocess.run(["git", "show", f"{head}:{p}"], cwd=ROOT, capture_output=True, text=True).stdout
                 for p in head_paths}
        summary = ["### zizmor: findings this change adds", "",
                   "| File | Audit | Severity | Confidence | Base | Now | Verdict |",
                   "| --- | --- | --- | --- | --- | --- | --- |"]
        for key, (was, now) in new.items():
            path, ident, severity, confidence = key.split("|")
            hole = is_hole(key, texts.get(path, ""))
            if hole:
                holes.append(key)
            level = "error" if hole and blocking() else "warning"
            why = f": {ZIZMOR_HOLES[ident]}" if hole else " (report-only)"
            at = sorted(lines.get(key, []))
            print(annotate(level, path, f"zizmor {severity} {ident} ({confidence} confidence): {now} here, {was} on the "
                           f"base{why}; lines {at} (https://docs.zizmor.sh/audits/#{ident})", at[0] if at else None))
            summary.append(f"| `{path}` | {ident} | {severity} | {confidence} | {was} | {now} | "
                           f"{'fails: a security hole' if hole else 'report-only'} |")
        if new:
            summarize(summary)
        print(f"ratchet: {len(new)} new zizmor findings, {len(holes)} of them security holes "
              f"(ZIZMOR_HOLES: {', '.join(ZIZMOR_HOLES)})")
    if whole_repo:
        print("ratchet: the whole repository, report-only (findings already on the base never fail):")
        with tempfile.TemporaryDirectory() as out:
            run_tool("zizmor.sh", Path(out), {"ZIZMOR_PERSONA": "regular"})
    return verdict(holes)


def verdict(holes: list, how_to_excuse: str = "an `# zizmor: ignore[<audit>]` comment on its line, with the reason") -> int:
    if not holes:
        return 0
    if blocking():
        print(f"ratchet: this change adds a security hole (above); fix it. A reviewed false positive: {how_to_excuse}")
        return 1
    print("ratchet: CMUX_STATIC_ANALYSIS_BLOCKING=0, so the holes above do not fail the job")
    return 0


def gitleaks(base: str, head: str) -> int:
    log_range = f"-m --first-parent {base}..{head}"
    with tempfile.TemporaryDirectory() as out:
        out_dir = Path(out)
        run_tool("gitleaks.sh", out_dir, {"GITLEAKS_RANGE": log_range})
        findings = json.loads((out_dir / "gitleaks.json").read_text())
    if not findings:
        return 0
    summary = [f"### gitleaks: {len(findings)} possible secrets in this change's commits (values redacted)", "",
               "| File | Line | Rule | Commit |", "| --- | --- | --- | --- |"]
    for f in findings:
        print(annotate("error" if blocking() else "warning", f["File"],
                       f"gitleaks {f['RuleID']} in commit {f['Commit'][:12]} (value redacted)", f["StartLine"]))
        summary.append(f"| `{f['File']}` | {f['StartLine']} | {f['RuleID']} | {f['Commit'][:12]} |")
    print("ratchet: a real secret: rotate it, then drop it from the commits. A known non-secret: add it to "
          "scripts/static-analysis/gitleaks/gitleaks.toml's allowlist")
    summarize(summary)
    return verdict(findings, "its fingerprint or path in scripts/static-analysis/gitleaks/gitleaks.toml's allowlist")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("tool", choices=("zizmor", "gitleaks"))
    parser.add_argument("--base", help="the commit the change starts from (default: see resolve_base)")
    parser.add_argument("--head", help="the change's commit (default HEAD; given, the whole-repository totals are skipped)")
    args = parser.parse_args()
    head = args.head or "HEAD"
    try:
        base = args.base or resolve_base(head)
        if not base:
            print("::warning::ratchet: no base to compare this change with (no merge parent, CMUX_GUARDS_BASE_SHA "
                  "or origin/feat-cmux-next or origin/main); nothing judged")
            return 0
        base, head = git("rev-parse", f"{base}^{{commit}}"), git("rev-parse", f"{head}^{{commit}}")
        return zizmor(base, head, args.head is None) if args.tool == "zizmor" else gitleaks(base, head)
    except (ToolDidNotRun, subprocess.CalledProcessError, OSError, ValueError) as err:
        # A tool that could not run is not this change's hole: say so, never red (an outage would red every PR).
        detail = getattr(err, "stderr", None)
        print(f"::warning::{err}{': ' + detail.strip() if isinstance(detail, (str, bytes)) and detail else ''}")
        summarize([f"### {args.tool}: did not run", "", str(err)])
        return 0


if __name__ == "__main__":
    sys.exit(main())
