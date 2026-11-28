#!/usr/bin/env python3
"""RFD 0051's simsdk cutover rule, measured: per kit simulator test bundle, how many consecutive counted runs agree.

A run counts for a bundle only when both sides gave a verdict (Mac: the `iOS simulator test cases:` line in the
"xcodebuild test (iOS simulator)" step log; Linux: a junit.xml with test cases). It agrees when the set of failing
tests in that bundle is the same on both sides. A disagreement ends the streak; a run that does not count is skipped.

  python3 -I scripts/ci/ios_sim_agreement.py CACHE_DIR [--fetch] [--since ISO] [--limit N] [--need N]

CACHE_DIR holds runs.json (gh run list --json databaseId,headSha,conclusion,createdAt) and, per run, RUN/jobs.json,
RUN/mac.log and RUN/linux/{junit.xml,summary.txt}. --fetch fills what is missing with gh (one call at a time,
900 s bound each, never retried); without it the script only reads the cache.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tarfile
import time
import xml.etree.ElementTree as ET
from pathlib import Path

REPO = "manaflow-ai/cmux"
WORKFLOW = "cmux-next-ios-kit.yml"
BRANCH = "feat-cmux-next"
SINCE = "2026-11-25T07:53:00Z"
BUNDLES = [
    f"CmuxMobile{n}Tests"
    for n in ("AgentChat", "Auth", "BrowserStream", "Chief", "Live", "Model", "Notifications", "Onboarding",
              "ScreenSharing", "Shell", "Terminal", "Voice", "Workspaces")
]
MAC_STEP = "xcodebuild test (iOS simulator"  # also matches ", Mac fallback)"
SCRIPT = "scripts/ci/ios-kit-sim-mac-test.sh"
VERDICT_MARK = "iOS simulator test cases:"
Test = tuple[str, str, str]  # (bundle, suite, test)

_TS = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ?")


def step_lines(log: str, step_prefix: str = MAC_STEP) -> list[str]:
    """Lines of the simulator step in a `gh run view --job J --log` dump (JOB<TAB>STEP<TAB>TIMESTAMP TEXT).
    gh names the step only on some jobs; on others every line says UNKNOWN STEP, and the step is the span from
    its `##[group]Run bash ../../scripts/ci/ios-kit-sim-mac-test.sh` line to the next `##[group]Run`. A log with
    no tabs (a step log on its own) is taken whole."""
    rows = []
    named = False
    for raw in log.splitlines():
        parts = raw.split("\t", 2)
        step = ""
        if len(parts) == 3:
            step, raw = parts[1], parts[2]
            named = named or step.startswith(step_prefix)
        rows.append((step, _TS.sub("", raw).rstrip()))
    if not any(step for step, _ in rows):
        return [text for _, text in rows]
    if named:
        return [text for step, text in rows if step.startswith(step_prefix)]
    out, inside = [], False
    for _, text in rows:
        if text.startswith("##[group]Run "):
            inside = SCRIPT in text
            continue
        if inside:
            out.append(text)
    return out


def clean_test(name: str) -> str:
    return re.sub(r"\(\)$", "", name.strip())


def parse_mac(log: str) -> tuple[bool, set[Test]]:
    """(verdict, failing tests). NOT FINISHED tests count as failing: they did not pass."""
    lines = step_lines(log)
    verdict = any(line.startswith(VERDICT_MARK) for line in lines)
    failing: set[Test] = set()
    for line in lines:
        m = re.match(r"^(?:FAILED|NOT FINISHED(?: \([^)]*\))?):\s*(.+)$", line)
        if not m:
            continue
        parts = [p.strip() for p in m.group(1).split(" / ")]
        i = next((k for k, p in enumerate(parts) if re.fullmatch(r"CmuxMobile\w*Tests", p)), None)
        if i is None:  # not a bundle path: keep it, under "?"
            failing.add(("?", " / ".join(parts[:-1]), clean_test(parts[-1])))
        else:
            failing.add((parts[i], " / ".join(parts[i + 1:-1]), clean_test(parts[-1])))
    return verdict, failing


def split_classname(classname: str) -> tuple[str, str]:
    """(bundle, suite) of a junit classname: `Bundle.Suite`, `Bundle/Suite` or `Bundle.module.Suite`."""
    parts = [p for p in re.split(r"[./]", classname) if p]
    for i, p in enumerate(parts):
        if re.fullmatch(r"CmuxMobile\w*Tests", p):
            return p, ".".join(parts[i + 1:])
    return "?", classname


def parse_junit(xml_text: str) -> tuple[bool, set[Test]]:
    """(verdict, failing tests): a verdict needs at least one test case."""
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError:
        return False, set()
    cases = 0
    failing: set[Test] = set()
    for case in root.iter("testcase"):
        cases += 1
        if case.find("failure") is not None or case.find("error") is not None:
            bundle, suite = split_classname(case.get("classname", ""))
            failing.add((bundle, suite, clean_test(case.get("name", ""))))
    return cases > 0, failing


def by_bundle(tests: set[Test]) -> dict[str, set[tuple[str, str]]]:
    out: dict[str, set[tuple[str, str]]] = {}
    for bundle, suite, test in tests:
        out.setdefault(bundle, set()).add((suite, test))
    return out


def evaluate(runs: list[dict], need: int = 5, bundles: list[str] = BUNDLES):
    """runs: newest first, each {id, mac: (verdict, failing) | None, linux: same | None, why: str}.
    Returns (rows, uncounted) with a row per bundle."""
    rows = {b: {"bundle": b, "counted": 0, "streak": 0, "open": True, "last_disagreement": None} for b in bundles}
    uncounted = []
    for run in runs:
        mac, linux = run.get("mac"), run.get("linux")
        if not (mac and mac[0] and linux and linux[0]):
            why = run.get("why") or ("no Mac verdict" if not (mac and mac[0]) else "no Linux verdict")
            uncounted.append((run["id"], why))
            continue
        mb, lb = by_bundle(mac[1]), by_bundle(linux[1])
        for b, row in rows.items():
            row["counted"] += 1
            a, c = mb.get(b, set()), lb.get(b, set())
            if a == c:
                if row["open"]:
                    row["streak"] += 1
            else:
                if row["last_disagreement"] is None:
                    row["last_disagreement"] = (run["id"], sorted(a - c), sorted(c - a))
                row["open"] = False
    return list(rows.values()), uncounted


def fmt_tests(items) -> str:
    return ", ".join(f"{s}/{t}" for s, t in items) or "-"


def table(rows: list[dict], need: int) -> str:
    out = ["| bundle | counted runs | current streak | meets N=%d | last disagreement |" % need,
           "|---|---|---|---|---|"]
    for r in rows:
        d = r["last_disagreement"]
        text = "none" if d is None else f"{d[0]}: Mac only [{fmt_tests(d[1])}]; Linux only [{fmt_tests(d[2])}]"
        out.append(f"| {r['bundle']} | {r['counted']} | {r['streak']} | {'yes' if r['streak'] >= need else 'no'} | {text} |")
    return "\n".join(out)


# ---- cache and fetch -------------------------------------------------------------------------------------------

def gh(args: list[str], out: Path | None = None) -> str:
    done = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=900)
    if done.returncode != 0:
        raise RuntimeError(done.stderr.strip()[:300])
    if out is not None:
        out.write_text(done.stdout)
    return done.stdout


def fetch_run(cache: Path, run_id: int, notes: list[str]) -> None:
    d = cache / str(run_id)
    d.mkdir(exist_ok=True)
    (d / "fetch-error.txt").unlink(missing_ok=True)
    jobs_file = d / "jobs.json"
    try:
        if not jobs_file.exists():
            gh(["run", "view", str(run_id), "-R", REPO, "--json", "jobs"], jobs_file)
        jobs = json.loads(jobs_file.read_text())["jobs"]
        kit = next((j for j in jobs if j["name"].startswith("CmuxMobileKit tests")), None)
        mac_step = next((s for s in (kit or {}).get("steps", []) if s["name"].startswith(MAC_STEP)
                         and s.get("conclusion") in ("success", "failure")), None)
        if mac_step and not (d / "mac.log").exists():
            log = gh(["run", "view", str(run_id), "-R", REPO, "--job", str(kit["databaseId"]), "--log"])
            (d / "mac.log").write_text("\n".join(step_lines(log)) + "\n")
        if not (d / "linux").exists() and any(s["name"] == "Upload the fleet pool result" and s.get("conclusion") == "success"
                                              for j in jobs for s in j.get("steps", [])):
            # Bounded pages through gh_pages.py: the gh quota wrapper refuses gh api's paginate flag.
            pages = subprocess.run([sys.executable, str(Path(__file__).with_name("gh_pages.py")),
                                    f"repos/{REPO}/actions/runs/{run_id}/artifacts"],
                                   check=True, capture_output=True, text=True, timeout=900).stdout
            listing = [a["name"] for a in json.loads(pages) if not a.get("expired")]
            names = [n for n in listing if n.startswith("kit-sim-linux-result-")]
            (d / "linux").mkdir()
            if names:
                tmp = d / "linux.tmp"
                tmp.mkdir(exist_ok=True)
                gh(["run", "download", str(run_id), "-R", REPO, "-n", sorted(names)[-1], "-D", str(tmp)])
                for tgz in tmp.rglob("result.tgz"):
                    with tarfile.open(tgz) as t:
                        for m in t.getmembers():
                            if m.isfile() and m.name.split("/")[-1] in ("junit.xml", "summary.txt"):
                                (d / "linux" / m.name.split("/")[-1]).write_bytes(t.extractfile(m).read())
        if (d / "mac.log").exists() and parse_mac((d / "mac.log").read_text())[0] and not (d / "pool.txt").exists():
            # The pool side's own verdict line, for the runs where no result artifact exists to read.
            lines = []
            for j in jobs:
                if "fleet pool" in j["name"] and any(s.get("conclusion") not in ("skipped", None, "")
                                                     and s["name"] in ("Fleet pool run", "Fleet pool result")
                                                     for s in j["steps"]):
                    log = gh(["run", "view", str(run_id), "-R", REPO, "--job", str(j["databaseId"]), "--log"])
                    lines += [_TS.sub("", l.split("\t", 2)[-1]) for l in log.splitlines()
                              if re.search(r"fleet pool[^:]*: (pass|fail|none)\b|no verdict", l)]
            (d / "pool.txt").write_text("\n".join(lines)[:2000] + "\n")
            time.sleep(31)  # the broker refuses 20 distinct runs' reads in 600 s
    except Exception as e:  # recorded, not retried
        notes.append(f"{run_id}: fetch failed: {e}")
        (d / "fetch-error.txt").write_text(str(e))


def load_run(cache: Path, run: dict) -> dict:
    d = cache / str(run["databaseId"])
    out = {"id": run["databaseId"], "mac": None, "linux": None, "why": ""}
    if (d / "mac.log").exists():
        out["mac"] = parse_mac((d / "mac.log").read_text())
    if (d / "linux" / "junit.xml").exists():
        out["linux"] = parse_junit((d / "linux" / "junit.xml").read_text())
    reasons = []
    if not (out["mac"] and out["mac"][0]):
        reasons.append("no Mac verdict" + (f" (run {run.get('conclusion') or 'in progress'}, no xcodebuild step result)" if not out["mac"] else " (no 'iOS simulator test cases:' line)"))
    if not (out["linux"] and out["linux"][0]):
        pool = (d / "pool.txt").read_text().strip().splitlines() if (d / "pool.txt").exists() else []
        reasons.append("no Linux verdict (no usable kit-sim-linux-result artifact"
                       + (f"; pool said: {pool[0][:170]}" if pool else "") + ")")
    if (d / "fetch-error.txt").exists():
        reasons.append("fetch error: " + (d / "fetch-error.txt").read_text()[:80])
    out["why"] = "; ".join(reasons)
    return out


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("cache")
    ap.add_argument("--fetch", action="store_true")
    ap.add_argument("--since", default=SINCE)
    ap.add_argument("--limit", type=int, default=0, help="at most N runs, newest first (0: all)")
    ap.add_argument("--need", type=int, default=5)
    args = ap.parse_args(argv)
    cache = Path(args.cache)
    cache.mkdir(parents=True, exist_ok=True)
    listing = cache / "runs.json"
    if not listing.exists():
        if not args.fetch:
            print("no runs.json in the cache; use --fetch", file=sys.stderr)
            return 2
        gh(["run", "list", "-R", REPO, "-w", WORKFLOW, "-b", BRANCH, "-e", "push", "-L", "300",
            "--json", "databaseId,headSha,conclusion,createdAt"], listing)
    runs = sorted((r for r in json.loads(listing.read_text()) if r["createdAt"] >= args.since),
                  key=lambda r: r["createdAt"], reverse=True)
    if args.limit:
        runs = runs[: args.limit]
    notes: list[str] = []
    if args.fetch:
        for r in runs:
            fetch_run(cache, r["databaseId"], notes)
    loaded = [load_run(cache, r) for r in runs]
    rows, uncounted = evaluate(loaded, args.need)
    print(table(rows, args.need))
    print(f"\nRuns considered: {len(runs)}; counted: {len(runs) - len(uncounted)}; not counted: {len(uncounted)}\n")
    print("Runs that did not count:")
    for rid, why in uncounted:
        print(f"- {rid}: {why}")
    for n in notes:
        print(f"! {n}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
