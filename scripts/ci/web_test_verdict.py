#!/usr/bin/env python3
"""Is this PR's red web test its own fault, or a flake? One command:

    python3 scripts/ci/web_test_verdict.py --pr 21651
    python3 scripts/ci/web_test_verdict.py --pr 21651 --file vm-route-deadlines.test.ts --coverage
    python3 scripts/ci/web_test_verdict.py --pr 21651 --post      # also comment the verdict on the PR

For each web test file that failed on the PR's branch (or the one --file/--test
names), it combines:

  history       web_test_failure_census.py: the test's failures in the last
                --days days on main and on other branches, and whether a
                re-run of the same SHA passed
  import graph  test_touches_diff.py: whether any file the PR changes is in
                the test's import graph, and with --coverage whether the test
                runs a changed line

and prints one verdict per file:

  likely this PR's   the test imports (or runs) code the PR changes, or the PR
                     changes the test runner, and it fails nowhere else
  touched, also flaky the PR touches its code, and it fails elsewhere too
  unrelated flake    the PR cannot reach it, and it failed elsewhere too
  probably unrelated the PR cannot reach it, and nothing else failed it in the
                     window; a re-run settles it

"Cannot reach" means outside the import graph, tree-shaken, or (--coverage)
imported without running a changed line. The head and base commits must be
fetchable; the script runs `git fetch origin <sha>` unless --no-fetch.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from collections.abc import Iterable, Mapping
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import test_touches_diff as graph  # noqa: E402
import web_test_failure_census as census  # noqa: E402

MARKER = "<!-- cmux-web-test-verdict -->"
LIKELY, TOUCHED_FLAKY, FLAKE, PROBABLY = "likely this PR's", "touched, also flaky", "unrelated flake", \
    "probably unrelated"
MAX_FILES = 5


def decide(own: list[Mapping], others: list[Mapping], touch: Mapping, days: int) -> dict:
    """The verdict for one test file from its failures here, elsewhere, and its import graph."""
    on_main = sum(1 for f in others if f.get("where") == "main")
    elsewhere = sorted({str(f.get("pr") or f.get("branch")) for f in others if f.get("where") != "main"})
    reran = sum(1 for f in own if f.get("rerun") == "passed")
    history = (f"{len(others)} other failure{'s' if len(others) != 1 else ''} in {days} days"
               + (f" ({on_main} on main, {len(elsewhere)} other PR branch{'es' if len(elsewhere) != 1 else ''})"
                  if others else ""))
    reach = touch["summary"]
    if touch["touches"]:
        verdict = TOUCHED_FLAKY if others else LIKELY
    else:
        verdict = FLAKE if others else PROBABLY
    parts = [history, reach]
    if reran:
        parts.append(f"{reran} of {len(own)} failure(s) here passed on a re-run of the same SHA")
    return {"verdict": verdict, "line": f"{verdict}: " + "; ".join(parts)}


def own_and_others(report: Mapping, branch: str) -> tuple[list[dict], list[dict]]:
    own = [f for f in report["failures"] if f.get("branch") == branch]
    return own, [f for f in report["failures"] if f.get("branch") != branch]


def fetch(repo: Path, shas: Iterable[str]) -> None:
    missing = [s for s in shas if subprocess.run(["git", "-C", str(repo), "cat-file", "-e", f"{s}^{{commit}}"],
                                                 capture_output=True).returncode]
    if missing:
        subprocess.run(["git", "-C", str(repo), "fetch", "--quiet", "--no-tags", "origin", *missing], check=True)


def render(pr: Mapping, results: list[Mapping], days: int) -> str:
    lines = [MARKER, f"**Web test verdict for #{pr['number']}** (head `{pr['head']['sha'][:10]}`)", ""]
    if not results:
        lines.append(f"No web test failed on `{pr['head']['ref']}` in the last {days} days.")
    for result in results:
        lines.append(f"- `{result['file']}`: **{result['verdict']['verdict']}**. "
                     f"{result['verdict']['line'].split(': ', 1)[1]}")
        for item in result["own"][:3]:
            lines.append(f"  - here: {item['test']} ({item['kind']}) [job]({item['job_url']})")
        for item in result["others"][:5]:
            who = "main" if item["where"] == "main" else (f"#{item['pr']}" if item.get("pr") else item["branch"])
            lines.append(f"  - {who}, {str(item.get('at'))[:10]}: {item['test']} [job]({item['job_url']})")
    lines += ["", f"<sub>scripts/ci/web_test_verdict.py; history from {results[0]['source'] if results else 'CI'}"
              "; logs history samples PR runs, see --max-runs.</sub>"]
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--pr", type=int, required=True)
    parser.add_argument("--file", help="only this test file")
    parser.add_argument("--test", help="only tests whose name contains this")
    parser.add_argument("--days", type=int, default=7)
    parser.add_argument("--source", choices=("auto", "junit", "logs"), default="auto")
    parser.add_argument("--max-main-runs", type=int, default=150)
    parser.add_argument("--max-runs", type=int, default=60)
    parser.add_argument("--coverage", action="store_true", help="run the test to see whether changed lines execute")
    parser.add_argument("--repo", default=census.REPO)
    parser.add_argument("--no-fetch", action="store_true")
    parser.add_argument("--post", action="store_true", help="comment the verdict on the pull request")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    src = census.make_source(args.repo, True)
    census.check_budget(src, census.estimate_calls(args.source, args.max_main_runs, args.max_runs, 300) + 10)
    pr = src.gh.get(f"repos/{args.repo}/pulls/{args.pr}") or {}
    branch, head, base = pr["head"]["ref"], pr["head"]["sha"], pr["base"]["sha"]  # type: ignore[index]
    # The PR's own failures first: they name the files to look at when --file is not given.
    mine = census.census(src, test=args.test, file=args.file, days=args.days, source=args.source,
                         max_main_runs=0, max_runs=0, branches=[branch])
    files = sorted({f["file"] for f in mine["failures"] if f.get("branch") == branch and f.get("file")})
    if args.file and not files:
        files = [census.web_path(args.file) if "/" in args.file else f"tests/{args.file}"]
    repo = Path(str(graph.git(Path.cwd(), "rev-parse", "--show-toplevel")).strip())
    if files and not args.no_fetch:
        fetch(repo, [head, base])
    results = []
    for file in files[:MAX_FILES]:
        history = census.census(src, test=args.test, file=file, days=args.days, source=args.source,
                                max_main_runs=args.max_main_runs, max_runs=args.max_runs, branches=[branch])
        own, others = own_and_others(history, branch)
        touch = graph.check(repo, file, base, head, coverage=args.coverage)
        results.append({"file": file, "own": own, "others": others, "touch": touch, "source": history["source"],
                        "verdict": decide(own, others, touch, args.days)})
    body = render(pr, results, args.days)  # type: ignore[arg-type]
    if args.json:
        print(json.dumps({"pr": args.pr, "head": head, "base": base, "results": results}, indent=2, default=str))
    else:
        print(body)
    if args.post:
        src.gh.request("POST", f"repos/{args.repo}/issues/{args.pr}/comments", {"body": body})
        print("posted the verdict on the pull request", file=sys.stderr)
    print(f"{src.gh.calls} REST calls", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
