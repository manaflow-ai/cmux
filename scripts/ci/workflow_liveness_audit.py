#!/usr/bin/env python3
"""Which workflow files cannot run, never ran, or duplicate another (ci-v2 migration step 3).

    workflow_liveness_audit.py [--ref origin/feat-cmux-next --ref origin/main] [--default-branch main]
        [--days 14 | --since EPOCH --until EPOCH] [--records FILE.jsonl[.gz] ...] [--json]

Joins every `.github/workflows/*.yml` at each --ref (read with `git show`, so no checkout is needed) to the jobs
that finished in the window, from the build controller's webhook timing feed (GET /v1/github/timing/records:
every runner, every attempt, no GitHub quota) or from saved pulls (--records). It prints one line per candidate:

- unreachable: no trigger in the file can fire for that ref. GitHub runs `schedule`, `workflow_run`,
  `repository_dispatch`, `issues`, `issue_comment`, `pull_request_target` and the other repository events from the
  default branch's copy only (pull_request_target reads main's copy whatever base its filter names: cmux#48946 edited
  feat-cmux-next's risk-tier.yml and nothing changed, cmux#49014 edited main's and it did); `push` and
  `pull_request` need a branch filter that admits the ref's branch; `workflow_call` needs
  a caller on the same ref that can itself run. `workflow_dispatch` counts as reachable (anyone can dispatch it at
  any ref), as do tag pushes and `merge_group`.
- never-ran: reachable, but no job of it finished in the window. A record is matched by the file's `name:` and by
  its `run-name:` (the feed carries the run's display title), and a called workflow is alive when a caller ran. A
  workflow whose every job skipped has no record either, so "always skipped" lands here.
- dead-schedule: a `schedule:` key on a non-default ref whose default-branch copy has none (GitHub never fires it).
- duplicate: two files on one ref with the same `name:`, or the same bytes.

A record that matches several files keeps all of them alive: the audit errs toward keeping. Stdlib plus PyYAML.
"""
from __future__ import annotations

import argparse
import collections
import fnmatch
import gzip
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
from dataclasses import dataclass, field
from typing import Iterable

import yaml

CONTROLLER = os.environ.get("PAID_HOSTS_CONTROLLER", "http://100.89.225.106:18765").rstrip("/")
REPO = "manaflow-ai/cmux"
WORKFLOW_DIR = ".github/workflows"
PAGE = 5000

# Events GitHub fires from the default branch's copy of the file only.
DEFAULT_BRANCH_ONLY = {
    "schedule", "workflow_run", "repository_dispatch", "issues", "issue_comment", "label", "milestone",
    "discussion", "discussion_comment", "check_run", "check_suite", "status", "deployment", "deployment_status",
    "page_build", "project", "project_card", "project_column", "public", "watch", "fork", "gollum",
    "branch_protection_rule", "registry_package", "release", "create", "delete", "member", "workflow_job",
    "pull_request_target",
}
# Events that run at a PR's merge ref, so the base branch decides which copy runs.
PR_EVENTS = {"pull_request"}
PR_NO_FILTER = {"pull_request_review", "pull_request_review_comment"}
ALWAYS_REACHABLE = {"workflow_dispatch", "merge_group"}
EXPR = re.compile(r"\$\{\{(.*?)\}\}", re.S)
QUOTED = re.compile(r"'((?:[^']|'')*)'")
MIN_LITERAL = 4


@dataclass
class Workflow:
    path: str
    ref: str
    branch: str
    text: str
    name: str = ""
    run_name: str = ""
    triggers: dict = field(default_factory=dict)
    calls: set = field(default_factory=set)
    error: str = ""

    @property
    def file(self) -> str:
        return self.path.rsplit("/", 1)[-1]


def parse(path: str, ref: str, branch: str, text: str) -> Workflow:
    wf = Workflow(path=path, ref=ref, branch=branch, text=text)
    try:
        doc = yaml.safe_load(text) or {}
    except yaml.YAMLError as exc:
        wf.error = f"yaml: {str(exc).splitlines()[0]}"
        return wf
    if not isinstance(doc, dict):
        wf.error = "not a mapping"
        return wf
    wf.name = str(doc.get("name") or "")
    wf.run_name = str(doc.get("run-name") or "")
    on = doc.get("on", doc.get(True))  # PyYAML reads a bare `on` key as True
    if isinstance(on, str):
        on = {on: None}
    elif isinstance(on, list):
        on = {event: None for event in on}
    wf.triggers = dict(on or {})
    for job in (doc.get("jobs") or {}).values():
        uses = isinstance(job, dict) and job.get("uses")
        if isinstance(uses, str) and uses.startswith(f"./{WORKFLOW_DIR}/"):
            wf.calls.add(uses.split("@", 1)[0].rsplit("/", 1)[-1])
    return wf


def _match_any(branch: str, patterns: Iterable[str]) -> bool:
    return any(fnmatch.fnmatchcase(branch, p.lstrip("!")) and not p.startswith("!") for p in patterns)


def branch_admitted(config, branch: str) -> bool:
    """Whether a push or pull_request config admits a branch (the push's branch or the PR's base)."""
    if not isinstance(config, dict):
        return True
    if "branches" in config:
        pats = [str(p) for p in config["branches"] or []]
        ok = False
        for p in pats:  # GitHub reads the list in order; a later `!x` excludes what an earlier one admitted
            if p.startswith("!"):
                if fnmatch.fnmatchcase(branch, p[1:]):
                    ok = False
            elif fnmatch.fnmatchcase(branch, p):
                ok = True
        return ok
    if "branches-ignore" in config:
        return not _match_any(branch, [str(p) for p in config["branches-ignore"] or []])
    if "tags" in config or "tags-ignore" in config:
        return False  # a tag-only push filter never fires for a branch push
    return True


def names_other_branch(config, foreign: set[str]) -> bool:
    """Whether a filter names a branch that carries this ref's tree: any listed branch that is not another audited
    ref's (nightly-next, rc/*, lane/* hold NEXT's files, so `push: nightly-next` on NEXT fires)."""
    if not isinstance(config, dict):
        return True
    if "branches" in config:
        return any(not str(p).startswith("!") and str(p) not in foreign for p in config["branches"] or [])
    if "branches-ignore" in config:
        return True
    return not ("tags" in config or "tags-ignore" in config)


def reachable_events(wf: Workflow, default_branch: str, foreign: frozenset = frozenset()) -> set[str]:
    """Events (other than workflow_call) that can fire this ref's copy of the file."""
    out = set()
    for event, config in wf.triggers.items():
        if event in ALWAYS_REACHABLE or event in PR_NO_FILTER:
            out.add(event)
        elif event in DEFAULT_BRANCH_ONLY:
            if wf.branch == default_branch:
                out.add(event)
        elif event == "push":
            tagged = isinstance(config, dict) and ("tags" in config or "tags-ignore" in config)
            if branch_admitted(config, wf.branch) or tagged or names_other_branch(config, foreign):
                out.add(event)
        elif event in PR_EVENTS:
            if branch_admitted(config, wf.branch) or names_other_branch(config, foreign):
                out.add(event)
        elif event != "workflow_call":
            out.add(event)  # unknown event: keep
    return out


def literal_patterns(template: str) -> list[re.Pattern]:
    """Regexes for every display title a name or run-name template can produce, as far as its literals tell."""
    template = " ".join(template.split())  # YAML folded scalars
    if not template:
        return []
    exprs = EXPR.findall(template)
    pieces = EXPR.split(template)
    outer = "".join(re.escape(p) if i % 2 == 0 else "(?:.*)" for i, p in enumerate(pieces))
    found = []
    if len(re.sub(r"\(\?:\.\*\)|\\", "", outer)) >= MIN_LITERAL:
        found.append(outer)
    for expr in exprs:  # a title that is all expression: its quoted literals, `{0}` as a wildcard
        for lit in QUOTED.findall(expr):
            lit = lit.replace("''", "'")
            rx = "".join(re.escape(p) if i % 2 == 0 else ".*" for i, p in enumerate(re.split(r"(\{\d+\})", lit)))
            if len(re.sub(r"\{\d+\}", "", lit)) >= MIN_LITERAL:
                found.append(rx)
    return [re.compile(rf"^{rx}$", re.S) for rx in dict.fromkeys(found)]


def title_patterns(wf: Workflow) -> list[re.Pattern]:
    pats = literal_patterns(wf.name) + literal_patterns(wf.run_name)
    if not wf.name:
        pats.append(re.compile(rf"^{re.escape(wf.path)}$"))
    return pats


def git_workflows(ref: str) -> list[tuple[str, str]]:
    names = subprocess.run(["git", "ls-tree", "--name-only", f"{ref}:{WORKFLOW_DIR}"], check=True,
                           capture_output=True, text=True).stdout.split()
    out = []
    for name in names:
        if name.endswith((".yml", ".yaml")):
            text = subprocess.run(["git", "show", f"{ref}:{WORKFLOW_DIR}/{name}"], check=True,
                                  capture_output=True, text=True).stdout
            out.append((f"{WORKFLOW_DIR}/{name}", text))
    return out


def branch_of(ref: str) -> str:
    return ref.split("/", 1)[1] if ref.startswith("origin/") else ref


def fetch_titles(since: int, until: int) -> collections.Counter:
    titles: collections.Counter = collections.Counter()
    seen: set = set()
    cursor = since
    while True:
        url = f"{CONTROLLER}/v1/github/timing/records?repo={REPO}&limit={PAGE}&since={cursor}"
        req = urllib.request.Request(url, headers={"Accept-Encoding": "gzip"})
        with urllib.request.urlopen(req, timeout=180) as resp:
            raw = resp.read()
            if resp.headers.get("Content-Encoding") == "gzip":
                raw = gzip.decompress(raw)
        page = json.loads(raw)
        last = None
        for rec in page["records"]:
            at = stamp(rec["at"])
            if at >= until:
                page["more"] = False
                break
            key = (rec.get("id"), rec.get("attempt"), bool(rec.get("job")))
            if key not in seen:
                seen.add(key)
                titles[rec.get("workflow") or ""] += 1
            last = at
        if not page.get("more") or last is None:
            return titles
        cursor = last if last > cursor else cursor + 1


def stamp(at: str) -> int:
    return int(time.mktime(time.strptime(at, "%Y-%m-%dT%H:%M:%SZ")) - time.timezone)


def read_titles(files: list[str], since: int, until: int) -> collections.Counter:
    titles: collections.Counter = collections.Counter()
    for name in files:
        opener = gzip.open if name.endswith(".gz") else open
        with opener(name, "rt") as fh:
            for line in fh:
                rec = json.loads(line)
                if since <= stamp(rec["at"]) < until:
                    titles[rec.get("workflow") or ""] += 1
    return titles


def runs_by_file(workflows: list[Workflow], titles: collections.Counter) -> dict[str, int]:
    """Jobs in the window per file name (a file on two refs shares its count: the feed has no ref for old rows)."""
    exact: dict[str, set[str]] = collections.defaultdict(set)
    pats: dict[str, list[re.Pattern]] = collections.defaultdict(list)
    for wf in workflows:
        for template in (wf.name, wf.run_name):
            template = " ".join(template.split())
            if template and not EXPR.search(template):
                exact[template].add(wf.file)
            elif template:
                pats[wf.file].extend(literal_patterns(template))
        if not wf.name:
            exact[wf.path].add(wf.file)
    out = {wf.file: 0 for wf in workflows}
    for title, n in titles.items():
        for name in exact.get(title, ()):
            out[name] += n
        for name, rxs in pats.items():
            if any(rx.match(title) for rx in rxs):
                out[name] += n
    return out


def audit(workflows: list[Workflow], runs: dict[str, int], default_branch: str) -> list[dict]:
    by_ref: dict[str, dict[str, Workflow]] = collections.defaultdict(dict)
    for wf in workflows:
        by_ref[wf.ref][wf.file] = wf
    default_copy = {wf.file: wf for wf in workflows if wf.branch == default_branch}
    found = []
    for ref, files in by_ref.items():
        foreign = frozenset(r.branch for r in workflows if r.ref != ref)
        direct = {name: reachable_events(wf, default_branch, foreign) for name, wf in files.items()}
        live = {name for name, ev in direct.items() if ev}
        callers: dict[str, set] = collections.defaultdict(set)
        for name, wf in files.items():
            for callee in wf.calls:
                callers[callee].add(name)
        changed = True
        while changed:  # a called workflow can run when a caller on the same ref can
            changed = False
            for name, wf in files.items():
                if name not in live and "workflow_call" in wf.triggers and callers[name] & live:
                    live.add(name)
                    changed = True
        ran = {name for name in files if runs.get(name, 0) > 0}
        changed = True
        while changed:
            changed = False
            for name in files:
                if name not in ran and callers[name] & ran:
                    ran.add(name)
                    changed = True
        for name, wf in sorted(files.items()):
            row = {"ref": ref, "file": name, "path": wf.path, "lines": wf.text.count("\n"),
                   "triggers": sorted(map(str, wf.triggers)), "jobs_14d": runs.get(name, 0)}
            if wf.error:
                found.append({**row, "kind": "unparsable", "why": wf.error})
            elif name not in live:
                found.append({**row, "kind": "unreachable",
                              "why": f"no trigger fires on {wf.branch}: {', '.join(row['triggers']) or 'none'}"})
            elif name not in ran:
                found.append({**row, "kind": "never-ran",
                              "why": f"reachable by {', '.join(sorted(direct[name])) or 'workflow_call'}, "
                                     "no job finished in the window"})
            if wf.branch != default_branch and "schedule" in wf.triggers:
                main = default_copy.get(name)
                if main is None or "schedule" not in main.triggers:
                    found.append({**row, "kind": "dead-schedule",
                                  "why": f"schedule on {wf.branch}; {default_branch}'s copy has "
                                         f"{'no file' if main is None else 'no schedule'}"})
        names: dict[str, list[str]] = collections.defaultdict(list)
        digests: dict[str, list[str]] = collections.defaultdict(list)
        for name, wf in files.items():
            if wf.name:
                names[wf.name].append(name)
            digests[hashlib.sha256(wf.text.encode()).hexdigest()].append(name)
        for group, why in [(g, f"same name: {n!r}") for n, g in names.items()] + \
                          [(g, "same bytes") for g in digests.values()]:
            if len(group) > 1:
                for name in sorted(group):
                    others = ", ".join(sorted(set(group) - {name}))
                    found.append({"ref": ref, "file": name, "path": files[name].path, "kind": "duplicate",
                                  "lines": files[name].text.count("\n"), "triggers": sorted(map(str, files[name].triggers)),
                                  "jobs_14d": runs.get(name, 0), "why": f"{why} with {others}"})
    return found


def self_test() -> int:
    """Checks of the trigger rules (run by hand: --self-test); not wired into CI."""
    def wf(branch: str, triggers: dict) -> Workflow:
        return Workflow(path=f"{WORKFLOW_DIR}/x.yml", ref=f"origin/{branch}", branch=branch, text="", triggers=triggers)
    next_only = {"branches": ["feat-cmux-next"]}
    cases = [
        # pull_request_target runs main's copy, even for PRs into feat-cmux-next (cmux#48946 vs cmux#49014)
        (wf("main", {"pull_request_target": next_only}), set(), {"pull_request_target"}),
        (wf("feat-cmux-next", {"pull_request_target": next_only}), set(), set()),
        (wf("feat-cmux-next", {"pull_request_target": None, "workflow_dispatch": None}), set(), {"workflow_dispatch"}),
        # pull_request runs the base's copy under its filter
        (wf("feat-cmux-next", {"pull_request": next_only}), set(), {"pull_request"}),
        (wf("main", {"pull_request": next_only}), {"feat-cmux-next"}, set()),
        (wf("feat-cmux-next", {"schedule": [{"cron": "0 0 * * *"}]}), set(), set()),
        (wf("main", {"schedule": [{"cron": "0 0 * * *"}]}), set(), {"schedule"}),
        (wf("feat-cmux-next", {"push": {"branches": ["nightly-next"]}}), {"main"}, {"push"}),
        (wf("feat-cmux-next", {"push": {"branches": ["main"]}}), {"main"}, set()),
    ]
    bad = 0
    for w, foreign, want in cases:
        got = reachable_events(w, "main", frozenset(foreign))
        if got != want:
            bad += 1
            print(f"FAIL {w.branch} {w.triggers}: got {sorted(got)}, want {sorted(want)}", file=sys.stderr)
    print(f"self-test: {len(cases) - bad}/{len(cases)} passed")
    return 1 if bad else 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--ref", action="append", help="git ref to read workflows from (repeatable)")
    ap.add_argument("--default-branch", default="main")
    ap.add_argument("--days", type=float, default=14)
    ap.add_argument("--since", type=int)
    ap.add_argument("--until", type=int)
    ap.add_argument("--records", action="append", help="saved timing records (JSONL, optionally .gz)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--self-test", action="store_true", help="check the trigger rules and exit")
    args = ap.parse_args(argv)
    if args.self_test:
        return self_test()
    refs = args.ref or ["origin/feat-cmux-next", "origin/main"]
    until = args.until or int(time.time())
    since = args.since or int(until - args.days * 86400)
    workflows = [parse(path, ref, branch_of(ref), text) for ref in refs for path, text in git_workflows(ref)]
    titles = read_titles(args.records, since, until) if args.records else fetch_titles(since, until)
    runs = runs_by_file(workflows, titles)
    found = audit(workflows, runs, args.default_branch)
    counts = collections.Counter(wf.ref for wf in workflows)
    if args.json:
        json.dump({"refs": dict(counts), "since": since, "until": until, "records": sum(titles.values()),
                   "candidates": found}, sys.stdout, indent=1)
        print()
        return 0
    window = f"{time.strftime('%Y-%m-%dT%H:%MZ', time.gmtime(since))}..{time.strftime('%Y-%m-%dT%H:%MZ', time.gmtime(until))}"
    print(f"window {window}: {sum(titles.values())} job records, {len(titles)} titles")
    for ref, n in counts.items():
        print(f"{ref}: {n} workflow files, {sum(1 for f in found if f['ref'] == ref)} candidates")
    for f in sorted(found, key=lambda r: (r["ref"], r["kind"], r["file"])):
        print(f"{f['ref']}\t{f['kind']}\t{f['file']}\t{f['lines']} lines\t{f['jobs_14d']} jobs\t{f['why']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
