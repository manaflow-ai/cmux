#!/usr/bin/env python3
"""Hold zizmor's and gitleaks' findings where they are: the CI check over the two report-only scripts.

zizmor.sh and gitleaks.sh report and always exit 0 when their tool ran. This runs one of them and
judges its report against what is new. It is report-only by default: new findings become ::warning
annotations and a step summary, and it exits 0. With CMUX_STATIC_ANALYSIS_BLOCKING=1 (one line in
.github/workflows/ci-guards.yml) they become ::error and exit 1; that flip waits on Leo's say-so.

  ratchet.py zizmor            reports (blocking: fails) when a workflow or composite action has more findings of an
                               audit and severity than zizmor/baseline.json records for it, or a
                               file zizmor cannot audit is not in the baseline. A count below its
                               baseline passes and says so: `--update` lowers it.
  ratchet.py zizmor --update   rewrites zizmor/baseline.json from this run (a raise shows in the diff).
  ratchet.py gitleaks          reports (blocking: fails) on any secret in this change's commits. The scope is new commits
                               only, so the baseline is empty by construction; a known non-secret goes
                               into gitleaks/gitleaks.toml's allowlist, a real one is rotated.

Findings are counted per file, audit and severity, not per line, so moving a line keeps its
finding's key. zizmor runs offline (no token), so the count does not depend on the network.
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
ZIZMOR_BASELINE = HERE / "zizmor" / "baseline.json"
CRASH = "zizmor-could-not-audit"


class ToolDidNotRun(Exception):
    pass


def blocking() -> bool:
    """CMUX_STATIC_ANALYSIS_BLOCKING=1 makes new findings fail; anything else (the default) only reports them."""
    return os.environ.get("CMUX_STATIC_ANALYSIS_BLOCKING", "0") == "1"


def annotate(file: str, message: str, line: int | None = None) -> str:
    where = f"file={file}" + (f",line={line}" if line else "")
    return f"::{'error' if blocking() else 'warning'} {where}::{message}"


def summarize(lines: list[str]) -> None:
    """Append to the GitHub step summary when there is one (CI), so report-only findings are visible."""
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n\n")


def verdict(new_findings: bool) -> int:
    if not new_findings:
        return 0
    if blocking():
        return 1
    print("ratchet: report-only (CMUX_STATIC_ANALYSIS_BLOCKING is not 1), so this does not fail the job")
    return 0


def run_tool(script: str, out_dir: Path, extra_env: dict[str, str]) -> None:
    env = {k: v for k, v in os.environ.items() if k not in ("GH_TOKEN", "GITHUB_TOKEN")}
    env.update(extra_env)
    env["FAST_CHECKS_OUT"] = str(out_dir)
    proc = subprocess.run(["bash", str(HERE / script)], cwd=ROOT, env=env)
    if proc.returncode != 0:
        raise ToolDidNotRun(f"ratchet: {script} did not run (exit {proc.returncode}); see its output above")


def zizmor_counts(findings: list[dict], report_text: str) -> Counter:
    counts: Counter = Counter()
    for finding in findings:
        primary = [l for l in finding.get("locations", []) if l["symbolic"]["kind"] == "Primary"]
        location = (primary or finding["locations"])[0]
        path = location["symbolic"]["key"]["Local"]["verbatim_path"]
        counts[f"{path}|{finding['ident']}|{finding['determinations']['severity']}"] += 1
    for path in re.findall(r"^zizmor failed: (.+) \(exit \d+\)$", report_text, re.M):
        counts[f"{path}|{CRASH}|-"] += 1
    return counts


def compare(current: Counter, baseline: dict[str, int]) -> tuple[dict[str, tuple[int, int]], int]:
    """(keys above their baseline as key -> (baseline, now), how many keys are below theirs)."""
    over = {k: (baseline.get(k, 0), n) for k, n in sorted(current.items()) if n > baseline.get(k, 0)}
    under = sum(1 for k, n in baseline.items() if current.get(k, 0) < n)
    return over, under


def zizmor(update: bool) -> int:
    with tempfile.TemporaryDirectory() as out:
        out_dir = Path(out)
        run_tool("zizmor.sh", out_dir, {"ZIZMOR_PERSONA": "regular"})
        findings = json.loads((out_dir / "zizmor.json").read_text())
        counts = zizmor_counts(findings, (out_dir / "zizmor.txt").read_text())
    if update:
        ZIZMOR_BASELINE.parent.mkdir(exist_ok=True)
        ZIZMOR_BASELINE.write_text(json.dumps({
            "about": "scripts/static-analysis/ratchet.py zizmor: findings per file|audit|severity, offline, persona regular. "
                     "Lower it with --update; a raise needs a reason in its pull request.",
            "total": sum(counts.values()),
            "findings": dict(sorted(counts.items())),
        }, indent=1) + "\n")
        print(f"ratchet: wrote {ZIZMOR_BASELINE.relative_to(ROOT)} ({sum(counts.values())} findings)")
        return 0
    baseline = json.loads(ZIZMOR_BASELINE.read_text())["findings"]
    over, under = compare(counts, baseline)
    print(f"ratchet: zizmor {sum(counts.values())} findings, baseline {sum(baseline.values())}")
    if under:
        print(f"ratchet: {under} keys are below their baseline; `python3 scripts/static-analysis/ratchet.py zizmor --update` lowers it")
    if not over:
        return 0
    summary = [f"### zizmor: {len(over)} file/audit/severity counts above the baseline", "",
               "| File | Audit | Severity | Baseline | Now |", "| --- | --- | --- | --- | --- |"]
    for key, (was, now) in over.items():
        path, ident, severity = key.split("|")
        print(annotate(path, f"zizmor {severity} {ident}: {now} here, baseline {was}"
              + (" (zizmor could not audit this file)" if ident == CRASH else f" (https://docs.zizmor.sh/audits/#{ident})")))
        summary.append(f"| `{path}` | {ident} | {severity} | {was} | {now} |")
    print("ratchet: fix the new findings (scripts/static-analysis/zizmor.sh prints them in full), "
          "or, for a reviewed exception, `ratchet.py zizmor --update` and say why in the pull request")
    summarize(summary)
    return verdict(True)


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, check=True, capture_output=True, text=True).stdout.strip()


def has_commit(rev: str) -> bool:
    return subprocess.run(["git", "cat-file", "-e", f"{rev}^{{commit}}"], cwd=ROOT, capture_output=True).returncode == 0


def gitleaks_range() -> str | None:
    """The log range of this change: each first-parent commit's diff, so a merge commit's diff is the pull request's.

    A pull request's synthetic merge commit (or a squash push) is judged against its first parent, read from the
    commit object since a depth-1 checkout has no parent; a push with a known previous tip, against that tip.
    Off CI, None: gitleaks.sh picks origin/<base>..HEAD itself."""
    if os.environ.get("GITLEAKS_RANGE"):
        return os.environ["GITLEAKS_RANGE"]
    parents = re.findall(r"^parent ([0-9a-f]{40})$", git("cat-file", "-p", "HEAD"), re.M)
    base = os.environ.get("CMUX_GUARDS_BASE_SHA", "")
    in_ci = os.environ.get("GITHUB_ACTIONS") == "true"
    if len(parents) < 2 and re.fullmatch(r"[0-9a-f]{40}", base) and has_commit(base) and \
            subprocess.run(["git", "merge-base", base, "HEAD"], cwd=ROOT, capture_output=True).returncode == 0:
        return f"-m --first-parent {base}..HEAD"
    if parents and (len(parents) > 1 or in_ci):
        if not has_commit(parents[0]):
            git("fetch", "--quiet", "--no-tags", "--depth=1", "--filter=blob:none", "origin", parents[0])
        return f"-m --first-parent {parents[0]}..HEAD"
    return None


def gitleaks() -> int:
    log_range = gitleaks_range()
    with tempfile.TemporaryDirectory() as out:
        out_dir = Path(out)
        run_tool("gitleaks.sh", out_dir, {"GITLEAKS_RANGE": log_range} if log_range else {})
        findings = json.loads((out_dir / "gitleaks.json").read_text())
    if not findings:
        return 0
    summary = [f"### gitleaks: {len(findings)} possible secrets in this change's commits (values redacted)", "",
               "| File | Line | Rule | Commit |", "| --- | --- | --- | --- |"]
    for f in findings:
        print(annotate(f["File"], f"gitleaks {f['RuleID']} in commit {f['Commit'][:12]} (value redacted)", f["StartLine"]))
        summary.append(f"| `{f['File']}` | {f['StartLine']} | {f['RuleID']} | {f['Commit'][:12]} |")
    print("ratchet: a real secret: rotate it, then drop it from the commits. A known non-secret: add it to "
          "scripts/static-analysis/gitleaks/gitleaks.toml's allowlist")
    summarize(summary)
    return verdict(True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("tool", choices=("zizmor", "gitleaks"))
    parser.add_argument("--update", action="store_true", help="zizmor: rewrite the baseline from this run")
    args = parser.parse_args()
    if args.tool == "gitleaks" and args.update:
        parser.error("gitleaks has no baseline: its scope is this change's commits")
    try:
        return zizmor(args.update) if args.tool == "zizmor" else gitleaks()
    except (ToolDidNotRun, subprocess.CalledProcessError, OSError, ValueError) as err:
        if blocking() or args.update:
            raise
        print(f"::warning::{err}")
        summarize([f"### {args.tool}: did not run", "", str(err)])
        return 0


if __name__ == "__main__":
    sys.exit(main())
