#!/usr/bin/env python3
"""The feat-cmux-next head compiles, and a red head names the merge that broke it.

2026-11-22 the head broke four times from merges that each passed on their own base: a stale
cmux-app-ffi Cargo.lock, a second Supervisor::signal_due (#50234 after another), a committed
SettingsSchema+Appearance5.generated.swift (#49757 after #50929 moved it into a SwiftPM plugin), and
#51052 calling acpmux qos helpers the #51319 revert had removed. A pull request's checks compile its
own merge with the base it saw; nothing compiled the head the merges made together, so each break was
found later by an agent's red build and bisected by hand.

.github/workflows/cmux-next-head-compile.yml runs this on every push to feat-cmux-next:

  plan --base B --head H       which checks the change reaches: "app" (the cmux-next app and the macOS
                               cmux-tui crates with their tests, `cmux-ci compile-check --app --release
                               --tests`) and "linux" (`cargo check --workspace --all-targets --locked` of
                               cmux-tui on Linux); none for a change no compile reads.
  run --base B --head H --check CMD [--parallel K] [--no-bisect] [--json OUT]
                               runs CMD on H. Red: probes the merges in B..H that touch a compile input
                               (first parent, oldest first), K at a time, down to the first red one, and
                               names it with its pull request. CMD is a shell command; {sha} is the commit
                               and {tree} a checkout of it (made only when CMD names it). Exit 0 is a pass,
                               1 a compile error, anything else no verdict (a busy fleet, a lost runner).
  report --json OUT            the verdict as Markdown (the issue body and the step summary).

B is the newest commit this workflow verified green, so a run that a newer push superseded leaves
nothing unchecked, and B is green by construction: the first red merge after it is the culprit. A
merge that touches no compile input (docs, web) is never probed or named. Exit: 1 for a red head,
else 0 (no verdict is never red).
"""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import re
import subprocess
import sys
import tempfile
from dataclasses import asdict, dataclass
from pathlib import Path

# The app check: the Swift package, the app, the FFI it links, and the macOS cmux-tui crates it bundles.
APP_ONLY = ("Packages/", "vendor/", "App/", "Package.swift", "cmux.xcodeproj/", "scripts/cmux-next/gen-",
            "scripts/cmux-next/build-app-ffi.sh", "scripts/ci/xcode-pins.txt")
# Both checks: Rust, its locks and toolchain, the Zig the crates build, and this check itself.
BOTH = ("cmux-tui/", "ghostty-next", ".cargo/", "scripts/ci/head_compile.py", "scripts/ci/head-compile.sh",
        "scripts/ci/feat-parity-check.sh", ".github/workflows/cmux-next-head-compile.yml")
PASS, FAIL, NONE = "pass", "fail", "none"
ERROR_LINE = re.compile(r"(^|\s)(error(\[\w+\])?:|error: |fatal error|compile-check: .*(red|fail))", re.I)
PR = re.compile(r"\(#(\d+)\)\s*$")


def plan(paths: list[str]) -> set[str]:
    """The checks a change to PATHS needs: "app", "linux", or none."""
    checks: set[str] = set()
    for path in paths:
        if path.startswith(BOTH) or path == "ghostty-next":
            checks |= {"app", "linux"}
        elif path.startswith(APP_ONLY):
            checks.add("app")
    return checks


def pr_of(subject: str) -> int | None:
    match = PR.search(subject)
    return int(match.group(1)) if match else None


@dataclass
class Commit:
    sha: str
    subject: str
    author: str
    pr: int | None


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout


def changed(repo: Path, base: str, head: str) -> list[str]:
    return [p for p in git(repo, "diff", "--no-renames", "--name-only", "-z", base, head).split("\0") if p]


def candidates(repo: Path, base: str, head: str) -> list[Commit]:
    """The first-parent commits in BASE..HEAD, oldest first, whose own change a compile reads."""
    out = []
    for line in git(repo, "rev-list", "--first-parent", "--reverse", f"{base}..{head}").split():
        parent = f"{line}^1"
        if not plan(changed(repo, parent, line)):
            continue
        subject, author = git(repo, "show", "-s", "--format=%s%x00%an", line).rstrip("\n").split("\0")
        out.append(Commit(line, subject, author, pr_of(subject)))
    return out


def run_check(repo: Path, cmd: str, sha: str) -> tuple[str, str]:
    """(verdict, output) of CMD on SHA."""
    with tempfile.TemporaryDirectory(prefix="head-compile-") as tmp:
        tree = Path(tmp) / "tree"
        if "{tree}" in cmd:
            git(repo, "worktree", "add", "-q", "--detach", str(tree), sha)
        try:
            result = subprocess.run(cmd.replace("{sha}", sha).replace("{tree}", str(tree)), shell=True,
                                    capture_output=True, text=True)
        finally:
            if "{tree}" in cmd:
                subprocess.run(["git", "-C", str(repo), "worktree", "remove", "--force", str(tree)],
                               capture_output=True)
    output = result.stdout + result.stderr
    return {0: PASS, 1: FAIL}.get(result.returncode, NONE), output


def first_errors(output: str, limit: int = 20) -> str:
    lines = [line for line in output.splitlines() if ERROR_LINE.search(line)]
    return "\n".join(lines[:limit]) if lines else "\n".join(output.splitlines()[-limit:])


def bisect(repo: Path, cmd: str, cands: list[Commit], parallel: int, probes: list[str]) -> tuple[int | None, int]:
    """(index of the first red candidate, index of the last green one before it) given that the base is green and
    the last candidate red (the head compiles what the last candidate left). None when probes gave no verdict."""
    lo, hi = -1, len(cands) - 1
    while hi - lo > 1:
        inside = list(range(lo + 1, hi))
        step = max(1, len(inside) // parallel + (1 if len(inside) % parallel else 0))
        points = inside[step - 1::step][:parallel] if len(inside) > parallel else inside
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(points)) as pool:
            verdicts = dict(zip(points, pool.map(lambda i: run_check(repo, cmd, cands[i].sha)[0], points)))
        probes.extend(cands[i].sha for i in points)
        answered = [i for i in points if verdicts[i] != NONE]
        if not answered:
            return None, lo
        reds = [i for i in answered if verdicts[i] == FAIL]
        if reds:
            hi = min(reds)
        greens = [i for i in answered if verdicts[i] == PASS and i < hi]
        if greens:
            lo = max(greens)
        if not reds and not greens:
            return None, lo
    return hi, lo


def run(repo: Path, base: str, head: str, cmd: str, parallel: int, probe: bool = True) -> dict:
    cands = candidates(repo, base, head)
    verdict, output = run_check(repo, cmd, head)
    result = {"base": base, "head": head, "verdict": verdict, "candidates": [asdict(c) for c in cands],
              "probes": [], "culprit": None, "suspects": [], "errors": ""}
    if verdict != FAIL:
        return result
    result["errors"] = first_errors(output)
    if not cands:
        # Nothing in the range touches a compile input: the base was already red (or the check itself is).
        result["suspects"] = []
        return result
    if len(cands) == 1:
        result["culprit"] = asdict(cands[0])
        return result
    if not probe:
        result["suspects"] = [asdict(c) for c in cands]
        return result
    probes: list[str] = []
    first, last_green = bisect(repo, cmd, cands, max(1, parallel), probes)
    result["probes"] = probes
    if first is None:
        result["suspects"] = [asdict(c) for c in cands[last_green + 1:]]
    else:
        result["culprit"] = asdict(cands[first])
    return result


def report(result: dict, server: str = "https://github.com", repo: str = "manaflow-ai/cmux") -> str:
    def commit_link(c: dict) -> str:
        pr = f" ([#{c['pr']}]({server}/{repo}/pull/{c['pr']}))" if c.get("pr") else ""
        return f"[`{c['sha'][:11]}`]({server}/{repo}/commit/{c['sha']}){pr} by {c['author']}: {c['subject']}"

    head = result["head"]
    if result["verdict"] == PASS:
        return f"The head [`{head[:11]}`]({server}/{repo}/commit/{head}) compiles."
    if result["verdict"] == NONE:
        return f"No verdict for [`{head[:11]}`]({server}/{repo}/commit/{head}) (the check did not finish)."
    lines = [f"**The feat-cmux-next head [`{head[:11]}`]({server}/{repo}/commit/{head}) does not compile.**", ""]
    if result["culprit"]:
        lines += [f"Broken by {commit_link(result['culprit'])}.", "",
                  "Every merge before it compiles. It passed on its own base; together with the merges before it "
                  "the head does not compile. Fix forward on feat-cmux-next (or revert it), red/green."]
    elif result["suspects"]:
        lines += ["Not bisected (the probes gave no verdict, or the head was already red); one of these broke it:", ""]
        lines += [f"- {commit_link(c)}" for c in result["suspects"]]
    else:
        lines += [f"No merge since the last green head [`{result['base'][:11]}`]({server}/{repo}/commit/"
                  f"{result['base']}) touches a compile input: the check itself or its tools are red."]
    lines += ["", "First errors:", "", "```", result["errors"] or "(none printed)", "```"]
    if result["probes"]:
        lines += ["", f"Probed {len(result['probes'])} merge(s): " + ", ".join(p[:11] for p in result["probes"])]
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--repo", type=Path, default=Path("."))
    p.add_argument("--base", required=True)
    p.add_argument("--head", required=True)
    r = sub.add_parser("run")
    r.add_argument("--repo", type=Path, default=Path("."))
    r.add_argument("--base", required=True)
    r.add_argument("--head", required=True)
    r.add_argument("--check", required=True)
    r.add_argument("--parallel", type=int, default=6)
    r.add_argument("--json", type=Path)
    r.add_argument("--no-bisect", action="store_true",
                   help="a red head names the merges in the range, probing none (the head is already known red)")
    o = sub.add_parser("report")
    o.add_argument("--json", type=Path, required=True)
    o.add_argument("--repository", default="manaflow-ai/cmux")
    args = parser.parse_args(argv)
    if args.command == "plan":
        checks = sorted(plan(changed(args.repo, args.base, args.head)))
        print(json.dumps({"checks": checks, "candidates": len(candidates(args.repo, args.base, args.head))}))
        return 0
    if args.command == "report":
        print(report(json.loads(args.json.read_text()), repo=args.repository))
        return 0
    result = run(args.repo.resolve(), args.base, args.head, args.check, args.parallel, probe=not args.no_bisect)
    if args.json:
        args.json.write_text(json.dumps(result, indent=1) + "\n")
    print(report(result))
    return 1 if result["verdict"] == FAIL else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
