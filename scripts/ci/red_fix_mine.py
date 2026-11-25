#!/usr/bin/env python3
"""Mine red-to-green commit pairs from recently merged pull requests and cluster the fixes into classes.

A pair is a PR commit whose check rollup is FAILURE followed by the PR's next commit. The next commit is the fix
(or the author's next push after waiting). Each pair is classified by the fix's files when read, else by the red
commit's failing check names and the fix's subject. Per class: pairs, PRs, wall-clock wait (red push to fix push).
The mechanical classes are the ones red-autofix can fix with no model call.

One GraphQL query per page of PRs; a capped number of REST commit reads refine the classes.

Run: python3 scripts/ci/red_fix_mine.py --days 7 --max-prs 300 --rest-cap 20 --json OUT.json --md OUT.md
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import re
import statistics
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone

REPO = "manaflow-ai/cmux"
GENERATED = ("plans/cmux-next/*", "schemas/*", "docs/mdm/*", "*.lock", "*/bun.lock", "bun.lock", "Cargo.lock",
             "*/Cargo.lock", "package-lock.json", "*/package-lock.json", "*.pbxproj", "*/Package.resolved")
# Classes red-autofix fixes, or can fix, with no model call.
MECHANICAL = {"formatter": "a formatter (swift-format, rustfmt, prettier)",
              "generated": "copy the red job's regenerated files (red-autofix regen)",
              "test-registry": "register the new test in tests/test-execution.toml",
              "base-merge": "merge the base into the PR head (scripts/merge-main.sh)",
              "workflow-lint": "actionlint/shellcheck suggestions"}
CHECK_HINTS = [
    ("generated", re.compile(r"generated files|regenerat|schema|lockfile", re.I)),
    ("test-registry", re.compile(r"registry|test wiring|sync-test-wiring", re.I)),
    ("workflow-lint", re.compile(r"actionlint|workflow lint|workflow-guard|ci-guards|guards", re.I)),
    ("formatter", re.compile(r"format|lint\b|swiftlint|rustfmt|prettier|oxlint|clippy", re.I)),
    ("rust-compile", re.compile(r"rust|cargo|tui|ios rust", re.I)),
    ("ts-typecheck", re.compile(r"typecheck|tsc|webviews|bun", re.I)),
    ("swift-compile", re.compile(r"swift|xcode|compile|build", re.I)),
    ("python-test", re.compile(r"python|pytest", re.I)),
]
SUBJECT_HINTS = [
    ("base-merge", re.compile(r"^merge (?:branch |remote-tracking branch )?'?(?:origin/)?(?:main|feat-cmux-next)", re.I)),
    ("formatter", re.compile(r"\b(?:fmt|format|formatting|rustfmt|prettier|swift-format|lint)\b", re.I)),
    ("generated", re.compile(r"regenerat|generated|lockfile|schema", re.I)),
    ("test-registry", re.compile(r"registry|test wiring|register", re.I)),
    ("ts-typecheck", re.compile(r"\btype(?:check| error)|\btsc\b|\bTS\d{4}", re.I)),
    ("rust-compile", re.compile(r"\bclippy\b|\bcargo\b|\brust\b", re.I)),
    ("swift-compile", re.compile(r"\bswift\b|\bcompile\b|\bbuild\b", re.I)),
    ("python-test", re.compile(r"\bpytest\b|\btest\b", re.I)),
]

# Light: rollup state only. The failing check names come in a second query, for the red commits alone.
QUERY = """query($owner: String!, $name: String!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(states: MERGED, first: 10, after: $after, orderBy: {field: UPDATED_AT, direction: DESC}) {
      pageInfo { hasNextPage endCursor }
      nodes { number mergedAt
        commits(last: 20) { nodes { commit { id oid committedDate messageHeadline additions deletions
          parents(first: 2) { totalCount } statusCheckRollup { state } } } } } } }
}"""
CHECKS = """query($ids: [ID!]!) { nodes(ids: $ids) { ... on Commit { oid statusCheckRollup { contexts(first: 100) {
  nodes { ... on CheckRun { name conclusion } ... on StatusContext { context state } } } } } } }"""


def gh(argv: list[str], calls: list[int], tries: int = 4) -> str:
    for attempt in range(tries):
        calls[0] += 1
        try:
            out = subprocess.run(["gh", *argv], capture_output=True, text=True, timeout=240)
        except subprocess.TimeoutExpired:
            if attempt + 1 < tries:
                continue
            raise RuntimeError(f"gh {' '.join(argv[:3])}: timed out")
        if out.returncode == 0:
            return out.stdout
        wait = re.search(r"retry after (\d+)s", out.stderr)
        if attempt + 1 < tries and (wait or re.search(r"busy|rate limit|HTTP 5\d\d|timeout", out.stderr, re.I)):
            time.sleep(min(int(wait.group(1)) + 1, 120) if wait else 15 * (attempt + 1))
            continue
        raise RuntimeError(f"gh {' '.join(argv[:3])}: {out.stderr.strip()[-400:]}")
    return ""


def classify_files(files: list[dict]) -> str:
    """FILES: REST commit files ({filename, patch}). Order: formatter-only, then by what the files are."""
    names = [f["filename"] for f in files]
    if not names:
        return "other"
    if files and all(f.get("patch") is not None for f in files) and all(whitespace_only(f["patch"]) for f in files):
        return "formatter"
    if all(any(fnmatch.fnmatchcase(n, g) for g in GENERATED) for n in names):
        return "generated"
    if "tests/test-execution.toml" in names and all(n == "tests/test-execution.toml" or n.startswith(".github/")
                                                    or n.startswith("tests/") for n in names):
        return "test-registry"
    if all(n.startswith(".github/workflows/") or n.startswith(".github/actions/") for n in names):
        return "workflow-lint"
    exts = {n.rsplit(".", 1)[-1] for n in names if "." in n.rsplit("/", 1)[-1]}
    for cls, want in (("swift-compile", {"swift"}), ("rust-compile", {"rs"}), ("ts-typecheck", {"ts", "tsx"}),
                      ("python-test", {"py"})):
        if exts & want and exts <= want | {"md", "json", "toml", "yml", "yaml", "lock"}:
            return cls
    return "other"


def whitespace_only(patch: str) -> bool:
    minus = [ln[1:] for ln in patch.splitlines() if ln.startswith("-") and not ln.startswith("---")]
    plus = [ln[1:] for ln in patch.splitlines() if ln.startswith("+") and not ln.startswith("+++")]
    squash = lambda xs: re.sub(r"\s+", "", "".join(xs))  # noqa: E731
    return bool(minus or plus) and squash(minus) == squash(plus)


def classify_hint(failed_checks: list[str], subject: str, merge: bool) -> str:
    if merge or SUBJECT_HINTS[0][1].search(subject):
        return "base-merge"
    for cls, rx in SUBJECT_HINTS[1:]:
        if rx.search(subject):
            return cls
    for cls, rx in CHECK_HINTS:
        if any(rx.search(c) for c in failed_checks):
            return cls
    return "other"


def failed_names(commit: dict) -> list[str]:
    nodes = ((commit.get("statusCheckRollup") or {}).get("contexts") or {}).get("nodes") or []
    out = []
    for n in nodes:
        if n.get("conclusion") in {"FAILURE", "TIMED_OUT"} or n.get("state") in {"FAILURE", "ERROR"}:
            out.append(n.get("name") or n.get("context") or "")
    return out


def pairs_of(pr: dict) -> list[dict]:
    commits = [c["commit"] for c in (pr.get("commits") or {}).get("nodes") or []]
    out = []
    for red, fix in zip(commits, commits[1:]):
        if ((red.get("statusCheckRollup") or {}).get("state")) != "FAILURE":
            continue
        failed = failed_names(red) if red.get("statusCheckRollup", {}).get("contexts") else ["(unread)"]
        # A red only from bots or CLA is not the author's red.
        failed = [f for f in failed if not re.search(r"CLA Assistant|CodeRabbit|Socket Security", f)]
        if not failed:
            continue
        t0 = datetime.fromisoformat(red["committedDate"].replace("Z", "+00:00"))
        t1 = datetime.fromisoformat(fix["committedDate"].replace("Z", "+00:00"))
        out.append({"pr": pr["number"], "red": red["oid"], "fix": fix["oid"], "failed": failed[:8],
                    "subject": fix.get("messageHeadline") or "", "merge": (fix.get("parents") or {}).get("totalCount", 1) > 1,
                    "lines": (fix.get("additions") or 0) + (fix.get("deletions") or 0),
                    "wait_min": max(0.0, (t1 - t0).total_seconds() / 60)})
    return out


def mine(days: int, max_prs: int, rest_cap: int, check_batches: int = 8) -> dict:
    calls = [0]
    since = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%d")
    owner, name = REPO.split("/")
    prs, after = [], None
    while len(prs) < max_prs:
        argv = ["api", "graphql", "-f", f"query={QUERY}", "-f", f"owner={owner}", "-f", f"name={name}"]
        if after:
            argv += ["-f", f"after={after}"]
        page = json.loads(gh(argv, calls))["data"]["repository"]["pullRequests"]
        nodes = [n for n in page["nodes"] if n]
        prs += [n for n in nodes if (n.get("mergedAt") or "") >= since]
        if not page["pageInfo"]["hasNextPage"] or all((n.get("mergedAt") or "") < since for n in nodes):
            break
        after = page["pageInfo"]["endCursor"]
    prs = prs[:max_prs]
    reds = [c["commit"] for pr in prs for c in (pr.get("commits") or {}).get("nodes") or []
            if ((c["commit"].get("statusCheckRollup") or {}).get("state")) == "FAILURE"]
    for i in range(0, min(len(reds), check_batches * 25), 25):
        batch = {c["id"]: c for c in reds[i:i + 25]}
        argv = ["api", "graphql", "-R", REPO, "-f", f"query={CHECKS}"] + [a for k in batch for a in ("-f", f"ids[]={k}")]
        try:
            nodes = json.loads(gh(argv, calls))["data"]["nodes"]
        except (RuntimeError, KeyError, ValueError):
            continue
        for node, cid in zip(nodes, batch):
            if node and node.get("statusCheckRollup"):
                batch[cid]["statusCheckRollup"]["contexts"] = node["statusCheckRollup"]["contexts"]
    pairs = [p for pr in prs for p in pairs_of(pr)]
    for p in pairs:
        p["class"], p["by"] = classify_hint(p["failed"], p["subject"], p["merge"]), "checks+subject"
    # Refine the smallest non-merge fixes (likeliest mechanical) with their files.
    for p in sorted((p for p in pairs if not p["merge"]), key=lambda p: p["lines"])[:rest_cap]:
        try:
            data = json.loads(gh(["api", f"repos/{REPO}/commits/{p['fix']}"], calls))
        except RuntimeError as err:
            p["rest_error"] = str(err)[-200:]
            continue
        cls = classify_files(data.get("files") or [])
        if cls != "other" or p["class"] == "other":
            p["class"], p["by"] = cls, "files"
    classes: dict[str, dict] = {}
    for p in pairs:
        c = classes.setdefault(p["class"], {"class": p["class"], "pairs": 0, "prs": set(), "waits": []})
        c["pairs"] += 1
        c["prs"].add(p["pr"])
        c["waits"].append(p["wait_min"])
    rows = []
    for c in classes.values():
        w = sorted(c["waits"])
        rows.append({"class": c["class"], "pairs": c["pairs"], "prs": len(c["prs"]),
                     "wait_p50_min": round(statistics.median(w), 1),
                     "wait_p95_min": round(w[min(len(w) - 1, int(0.95 * len(w)))], 1),
                     "wait_total_h": round(sum(w) / 60, 1), "mechanical": c["class"] in MECHANICAL,
                     "fixer": MECHANICAL.get(c["class"], "model (red-autofix fix job)")})
    rows.sort(key=lambda r: (-r["pairs"], r["class"]))
    return {"repo": REPO, "since": since, "prs": len(prs), "pairs": len(pairs), "calls": calls[0],
            "top": rows[:10], "pair_list": pairs}


def markdown(out: dict) -> str:
    lines = [f"Red-to-green pairs in {out['prs']} merged {out['repo']} PRs since {out['since']}: {out['pairs']} pairs "
             f"({out['calls']} GitHub calls).", "",
             "| class | pairs | PRs | wait p50 min | wait p95 min | total wait h | mechanical | fixer |",
             "|---|---|---|---|---|---|---|---|"]
    for r in out["top"]:
        lines.append(f"| {r['class']} | {r['pairs']} | {r['prs']} | {r['wait_p50_min']} | {r['wait_p95_min']} | "
                     f"{r['wait_total_h']} | {'yes' if r['mechanical'] else 'no'} | {r['fixer']} |")
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--max-prs", type=int, default=300)
    ap.add_argument("--rest-cap", type=int, default=20)
    ap.add_argument("--check-batches", type=int, default=8, help="25 red commits per check-names query")
    ap.add_argument("--json")
    ap.add_argument("--md")
    a = ap.parse_args(argv)
    out = mine(a.days, a.max_prs, a.rest_cap, a.check_batches)
    md = markdown(out)
    if a.json:
        with open(a.json, "w") as f:
            json.dump(out, f, indent=1)
    if a.md:
        with open(a.md, "w") as f:
            f.write(md)
    print(md)
    return 0


if __name__ == "__main__":
    sys.exit(main())
