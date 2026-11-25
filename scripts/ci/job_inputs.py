#!/usr/bin/env python3
"""Where every pull request job for feat-cmux-next declares its inputs, and the fixer for the ones that do not.

Leo, 2026-11-21: "we have auto fixers and we have the fucking like proper fucking routers ourselves. And we have just
a ton of skips and just only the fucking most absolutely necessary and possibly relevant bits." A job a diff cannot
affect should not run; for that each job has to say what it reads. A job of a workflow that a pull request to
feat-cmux-next starts (pull_request or pull_request_target, with no branch filter or one that takes feat-cmux-next)
is declared by the first of these that names it:

  pull-request-skip  scripts/ci/affected-jobs.json pull_request_skip: a pull request skips it unless labeled full-ci.
  fast-check-inputs  scripts/ci/fast-check-inputs.json (fast_check_route.py): the job skips a diff outside its inputs.
  affected-jobs      scripts/ci/affected-jobs.json (affected_jobs.py): the same, for the workflows that list it.
  pr-router          pr-router.yml calls it, and scripts/ci/pr_router.json lists the callee's `affects`.
  tooling-steps      its steps read needs.<job>.outputs.tooling_steps (tooling_steps.py): each step runs only when the
                     diff reaches a test it runs.
  path-route         its `if:` reads needs.path_route.outputs (cmux-next.yml's path router).
  workflow-paths     the workflow's own `on.<event>.paths` is narrow (not "**" with docs-only negations).
  always             scripts/ci/job-inputs-always.json lists it with the reason it runs on every pull request.

All but `always` are narrow; `always` is the whole tree. A job none of them names is undeclared.

    job_inputs.py report [--json]   every job with its source and narrow/whole, and the totals
    job_inputs.py check             exit 1 when a job is undeclared (for agents and the report; no CI job runs it:
                                    cmux AGENTS.md, Lawrence: never add CI gates)
    job_inputs.py fix               add each undeclared job to the always file, with the paths its steps read
                                    (fast_check_route.reads_of) as suggested_inputs, and drop the always entries of
                                    jobs that are gone or now declared elsewhere. The PR autofix runs it
                                    (scripts/cmux-next/autofix-areas.sh `jobinputs`, base-autofix.sh --job-inputs).
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import fast_check_route  # noqa: E402
import same_tree_reuse  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
BRANCH = "feat-cmux-next"
EVENTS = ("pull_request", "pull_request_target")
ALWAYS = "scripts/ci/job-inputs-always.json"
FAST_CHECK = "scripts/ci/fast-check-inputs.json"
AFFECTED = "scripts/ci/affected-jobs.json"
PR_ROUTER = "scripts/ci/pr_router.json"
PR_ROUTER_WORKFLOW = ".github/workflows/pr-router.yml"
SOURCES = ("pull-request-skip", "fast-check-inputs", "affected-jobs", "pr-router", "tooling-steps", "path-route", "workflow-paths",
           "always")
UNDECLARED_WHY = "undeclared: runs on every pull request until its inputs are declared (added by job_inputs.py fix)"
ALWAYS_DOC = [
    "The pull request jobs for feat-cmux-next that run on every pull request (scripts/ci/job_inputs.py), each with why.",
    "A job no router declares (fast-check-inputs.json, affected-jobs.json, pr_router.json, tooling_steps.py, the",
    "path_route job, a narrow workflow `paths:`) is listed here; `job_inputs.py fix` (the PR autofix) adds a new one",
    "with the paths its steps read as suggested_inputs. Declare its inputs in a router and the fix drops it here.",
]
TOOLING_STEPS = re.compile(r"needs\.[\w-]+\.outputs\.tooling_steps")
PATH_ROUTE = re.compile(r"needs\.path_route\.outputs\.")
# A suggestion past this many paths is a job that reads the whole diff or tree (a router, a roll-up): the first ones
# and the count are kept.
SUGGESTED_MAX = 40


def load_json(root: Path, rel: str) -> dict:
    path = root / rel
    return json.loads(path.read_text(encoding="utf-8")) if path.is_file() else {}


def takes_branch(config) -> bool:
    """Whether an event's config lets a pull request to BRANCH start the workflow."""
    if not isinstance(config, dict):
        return True
    branches = config.get("branches")
    if branches:
        return any(fnmatch.fnmatchcase(BRANCH, b) for b in ([branches] if isinstance(branches, str) else branches))
    ignore = config.get("branches-ignore")
    if ignore:
        return not any(fnmatch.fnmatchcase(BRANCH, b) for b in ([ignore] if isinstance(ignore, str) else ignore))
    return True


def pr_configs(workflow: dict) -> list:
    """The configs of the workflow's pull request events that take BRANCH."""
    on = workflow.get("on") or {}
    if isinstance(on, (str, list)):
        names = [on] if isinstance(on, str) else on
        return [None for e in names if e in EVENTS]
    return [on[e] for e in EVENTS if e in on and takes_branch(on[e])]


def narrow_paths(configs: list) -> bool:
    """Whether every taking event filters by a narrow `paths:` (not "**" plus negations, the docs-only filter)."""
    if not configs:
        return False
    for config in configs:
        paths = config.get("paths") if isinstance(config, dict) else None
        if not paths:
            return False
        positive = [p for p in ([paths] if isinstance(paths, str) else paths) if not p.startswith("!")]
        if not positive or any(p in ("**", "**/*", "*") for p in positive):
            return False
    return True


def workflows(root: Path) -> dict[str, dict]:
    """`.github/workflows/X.yml` -> the parsed workflow, for each workflow a pull request to BRANCH starts."""
    out = {}
    for name, data in same_tree_reuse.pr_workflows(root).items():
        if pr_configs(data):
            out[f".github/workflows/{name}"] = data
    return out


def as_text(value) -> str:
    return json.dumps(value) if not isinstance(value, str) else value


ATOM = re.compile(r"^(github\.event_name|github\.event\.pull_request\.base\.ref|github\.base_ref)\s*(==|!=)\s*'([^']*)'$")


def tokens(expression: str) -> list[str]:
    """EXPRESSION as `(`, `)`, `!`, `&&`, `||` and atoms (a comparison, a function call with its arguments)."""
    text = expression.strip()
    if text.startswith("${{") and text.endswith("}}"):
        text = text[3:-2]
    out, atom, i = [], "", 0
    while i < len(text):
        ch = text[i]
        if ch == "'":
            end = text.index("'", i + 1) if "'" in text[i + 1:] else len(text) - 1
            atom += text[i:end + 1]
            i = end + 1
        elif ch == "(" and re.search(r"[\w.]$", atom):
            depth, j = 0, i
            while j < len(text):
                depth += {"(": 1, ")": -1}.get(text[j], 0)
                j += 1
                if depth == 0:
                    break
            atom += text[i:j]
            i = j
        elif text.startswith(("&&", "||"), i) or ch in "()" or (ch == "!" and not text.startswith("!=", i)):
            if atom.strip():
                out.append(atom.strip())
            atom = ""
            size = 2 if text.startswith(("&&", "||"), i) else 1
            out.append(text[i:i + size])
            i += size
        else:
            atom += ch
            i += 1
    if atom.strip():
        out.append(atom.strip())
    return out


def evaluate(expression: str, event: str) -> bool | None:
    """EXPRESSION for a pull request to BRANCH started by EVENT: True, False, or None when it depends on more than the
    event and the base branch (Kleene logic). A parse it cannot follow is None."""
    items = tokens(expression)
    pos = 0

    def atom(text: str) -> bool | None:
        match = ATOM.match(text)
        if not match:
            return None
        field, op, value = match.groups()
        actual = event if field == "github.event_name" else BRANCH
        return (actual == value) == (op == "==")

    def primary() -> bool | None:
        nonlocal pos
        token = items[pos] if pos < len(items) else ""
        pos += 1
        if token == "!":
            value = primary()
            return None if value is None else not value
        if token == "(":
            value = disjunction()
            if pos >= len(items) or items[pos] != ")":
                raise ValueError("unbalanced")
            pos += 1
            return value
        if token in ("", ")", "&&", "||"):
            raise ValueError("unexpected token")
        return atom(token)

    def conjunction() -> bool | None:
        nonlocal pos
        values = [primary()]
        while pos < len(items) and items[pos] == "&&":
            pos += 1
            values.append(primary())
        return False if False in values else None if None in values else True

    def disjunction() -> bool | None:
        nonlocal pos
        values = [conjunction()]
        while pos < len(items) and items[pos] == "||":
            pos += 1
            values.append(conjunction())
        return True if True in values else None if None in values else False

    try:
        value = disjunction()
        return value if pos == len(items) else None
    except (ValueError, IndexError):
        return None


def taking_events(workflow: dict) -> list[str]:
    on = workflow.get("on") or {}
    if isinstance(on, (str, list)):
        return [e for e in ([on] if isinstance(on, str) else on) if e in EVENTS]
    return [e for e in EVENTS if e in on and takes_branch(on[e])]


def runs_on_pull_requests(job: dict, events: list[str] = list(EVENTS)) -> bool:
    """False when the job's `if:` is false for every pull request event to BRANCH the workflow takes (an event other
    than a pull request, a base branch other than BRANCH)."""
    condition = as_text(job.get("if", "")).strip()
    return not condition or any(evaluate(condition, e) is not False for e in events)


def classify(root: Path, wf: str, workflow: dict, job_id: str, maps: dict) -> str | None:
    job = workflow.get("jobs", {}).get(job_id) or {}
    if job_id in (maps["affected"].get("pull_request_skip", {}).get("workflows", {}).get(wf, {}) or {}):
        return "pull-request-skip"
    if job_id in maps["fast"].get("workflows", {}).get(wf, {}):
        return "fast-check-inputs"
    if job_id in (maps["affected"].get("workflows", {}).get(wf, {}) or {}).get("jobs", {}):
        return "affected-jobs"
    if wf == PR_ROUTER_WORKFLOW:
        callee = str(job.get("uses", "")).rsplit("/", 1)[-1]
        spec = maps["router"].get("callees", {}).get(callee)
        if spec and (spec.get("affects") or spec.get("paths")):
            return "pr-router"
    if any(TOOLING_STEPS.search(as_text(step.get("if", ""))) for step in job.get("steps", []) or []
           if isinstance(step, dict)):
        return "tooling-steps"
    if PATH_ROUTE.search(as_text(job.get("if", ""))):
        return "path-route"
    if narrow_paths(pr_configs(workflow)):
        return "workflow-paths"
    if job_id in maps["always"].get("jobs", {}).get(wf, {}):
        return "always"
    return None


def survey(root: Path) -> list[dict]:
    maps = {"fast": load_json(root, FAST_CHECK), "affected": load_json(root, AFFECTED),
            "router": load_json(root, PR_ROUTER), "always": load_json(root, ALWAYS)}
    rows = []
    for wf, workflow in workflows(root).items():
        for job_id, job in (workflow.get("jobs", {}) or {}).items():
            if isinstance(job, dict) and not runs_on_pull_requests(job, taking_events(workflow)):
                continue
            source = classify(root, wf, workflow, job_id, maps)
            rows.append({"workflow": wf, "job": job_id, "source": source,
                         "scope": None if source is None else "whole" if source == "always" else "narrow"})
    return rows


def totals(rows: list[dict]) -> dict:
    by_source = {s: sum(r["source"] == s for r in rows) for s in SOURCES}
    by_source["undeclared"] = sum(r["source"] is None for r in rows)
    return {"jobs": len(rows), "by_source": by_source,
            "narrow": sum(r["scope"] == "narrow" for r in rows), "whole": sum(r["scope"] == "whole" for r in rows)}


def report(root: Path, as_json: bool) -> int:
    rows = survey(root)
    summary = totals(rows)
    if as_json:
        print(json.dumps({"jobs": rows, "totals": summary}, indent=2))
        return 0
    for r in rows:
        print(f"{r['workflow']}  {r['job']}  {r['source'] or 'UNDECLARED'}  {r['scope'] or '-'}")
    print(f"\n{summary['jobs']} jobs: {summary['narrow']} narrow, {summary['whole']} whole tree, "
          f"{summary['by_source']['undeclared']} undeclared")
    for source, count in summary["by_source"].items():
        print(f"  {source}: {count}")
    return 0


def undeclared(rows: list[dict]) -> list[dict]:
    return [r for r in rows if r["source"] is None]


def check(root: Path) -> int:
    missing = undeclared(survey(root))
    for r in missing:
        print(f"{r['workflow']}: job {r['job']} declares no inputs and is not in {ALWAYS}; "
              f"run `python3 scripts/ci/job_inputs.py fix`", file=sys.stderr)
    return 1 if missing else 0


def suggested_inputs(root: Path, wf: str, job_id: str, tree: fast_check_route.Tree) -> list[str]:
    try:
        text = (root / wf).read_text(encoding="utf-8")
    except OSError:
        return []
    block = fast_check_route.job_block(text, job_id)
    if block is None:
        return []
    return sorted(p for p in fast_check_route.reads_of(block, root, tree) if p != wf)


def suggestion(paths: list[str]) -> dict:
    if len(paths) <= SUGGESTED_MAX:
        return {"suggested_inputs": paths}
    return {"suggested_inputs": paths[:SUGGESTED_MAX], "suggested_inputs_more": len(paths) - SUGGESTED_MAX}


def fix(root: Path, files: list[str] | None = None) -> int:
    rows = survey(root)
    data = load_json(root, ALWAYS) or {}
    jobs: dict = data.get("jobs", {})
    listed = {(r["workflow"], r["job"]) for r in rows if r["source"] in (None, "always")}
    dropped = [(wf, j) for wf, entries in jobs.items() for j in entries if (wf, j) not in listed]
    for wf, j in dropped:
        del jobs[wf][j]
        print(f"dropped: {wf} {j} (gone, or declared by a router now)")
    missing = undeclared(rows)
    tree = fast_check_route.Tree(files if files is not None else fast_check_route.tracked(root)) if missing else None
    for r in missing:
        jobs.setdefault(r["workflow"], {})[r["job"]] = {
            "why": UNDECLARED_WHY, **suggestion(suggested_inputs(root, r["workflow"], r["job"], tree))}
        print(f"added: {r['workflow']} {r['job']}")
    if not missing and not dropped and (root / ALWAYS).is_file():
        return 0
    jobs = {wf: dict(sorted(entries.items())) for wf, entries in sorted(jobs.items()) if entries}
    out = {"//": data.get("//", ALWAYS_DOC), "jobs": jobs}
    (root / ALWAYS).write_text(json.dumps(out, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--root", type=Path, default=ROOT)
    sub = parser.add_subparsers(dest="command", required=True)
    rep = sub.add_parser("report")
    rep.add_argument("--json", action="store_true")
    sub.add_parser("check")
    sub.add_parser("fix")
    args = parser.parse_args(argv)
    root = args.root.resolve()
    if args.command == "report":
        return report(root, args.json)
    if args.command == "check":
        return check(root)
    return fix(root)


if __name__ == "__main__":
    sys.exit(main())
