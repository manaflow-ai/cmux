#!/usr/bin/env python3
"""Into feat-cmux-next, a label a workflow does not read never re-runs its CI.

`pull_request` with `labeled`/`unlabeled` in its types starts a run for every
label added or removed. For ci.yml that meant a `risk:*` swap queued a second
full CI run at the same head (cmux#29618: run 41241282080 waited over an hour
behind the first and held the webview gate). A workflow that does real work and
reacts to labels lists the labels it reads in GUARDED; every job a label event
could start then skips any other label event, and its concurrency group puts that event in
a group of its own, so it neither waits behind, replaces nor cancels a real run.

A workflow that is cheap and reads labels on purpose (a policy check, the risk
tier, a tour that is labeled-only) goes in REACTS with the reason. Every
label-triggered workflow must be in exactly one; a stale entry fails.

Run: python3 tests/test_ci_label_events_skip_full_ci.py
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

# Workflows that run CI, with the labels they react to.
GUARDED: dict[str, tuple[str, ...]] = {
    "ci.yml": ("full-ci", "dev-build"),
    "cmux-vm.yml": ("cmux-vm-breaking-change-ok",),
}

# Jobs of a GUARDED workflow that run on every label event, and why.
UNGUARDED_JOBS: dict[tuple[str, str], str] = {
    ("ci.yml", "ci-status"): "a skipped ci-status newer than a red or pending one would read as passing to a "
    "newest-by-name merge gate (gh-merge-green); into feat-cmux-next it passes at once",
}

# Label-triggered workflows that may run on any label, and why.
REACTS: dict[str, str] = {
    "backend-migrations.yml": "plans migrations (cheap); applies only on backend:apply-migrations",
    "cmux-next-batch.yml": "debounce only; hold and landing labels change batch eligibility",
    "cmux-next-media.yml": "labeled-only; its jobs already run only for media-tour / no-media-tour",
    "cmux-next-motion-golden.yml": "its job already runs only when motion-golden is the label added",
    "merge-freeze.yml": "one-step freeze check that reads freeze-ok",
    "pr-capture-check.yml": "one-step policy check that reads opt-out labels",
    "pr-perf-section-check.yml": "one-step policy check that reads labels",
    "risk-tier.yml": "the risk tier check itself: it must react to risk:* labels",
}


def guard(labels: tuple[str, ...]) -> str:
    """The job-level condition: false only for a label event of a label not in `labels`."""
    if len(labels) == 1:
        other = f"github.event.label.name != '{labels[0]}'"
    else:
        other = f"!contains(fromJSON('{json.dumps(list(labels), separators=(',', ':'))}'), github.event.label.name)"
    return ("!(github.event_name == 'pull_request' && github.event.pull_request.base.ref == 'feat-cmux-next' && "
            "(github.event.action == 'labeled' || "
            f"github.event.action == 'unlabeled') && {other})")


def evaluate(expr: str, event: dict) -> bool:
    """A small evaluator for the guard's subset of the GitHub expression language."""
    py = expr
    py = re.sub(r"fromJSON\('([^']*)'\)", lambda m: repr(json.loads(m.group(1))), py)
    py = re.sub(r"contains\((\[[^\]]*\]), ([^)]+)\)", r"(\2 in \1)", py)
    py = py.replace("github.event.pull_request.base.ref", repr(event.get("base", "feat-cmux-next")))
    py = py.replace("github.event_name", repr(event.get("event_name")))
    py = py.replace("github.event.action", repr(event.get("action")))
    py = py.replace("github.event.label.name", repr(event.get("label")))
    py = py.replace("&&", " and ").replace("||", " or ").replace("!=", " __NE__ ")
    py = py.replace("!", " not ").replace(" __NE__ ", " != ")
    return bool(eval(py, {"__builtins__": {}}, {}))  # noqa: S307 - the input is our own constant


NOT_ON_PULL_REQUEST = re.compile(r"^(!cancelled\(\) && )?github\.event_name == '(workflow_dispatch|push)' &&")
STATUS_FUNCTION = re.compile(r"\b(always|cancelled|failure)\(\)")


def reachable_by_label_event(body: dict, condition: str) -> bool:
    """Whether a label event could start this job without the guard: a job that needs others and calls no
    status function skips with them, and one gated on push or dispatch never runs on a pull request."""
    if NOT_ON_PULL_REQUEST.match(condition):
        return False
    return not body.get("needs") or bool(STATUS_FUNCTION.search(condition))


def label_triggered(doc: dict) -> bool:
    on = doc.get(True, doc.get("on"))
    if not isinstance(on, dict):
        return False
    for event in ("pull_request", "pull_request_target"):
        config = on.get(event)
        types = config.get("types") if isinstance(config, dict) else None
        if types and ({"labeled", "unlabeled"} & set(types)):
            return True
    return False


def main() -> int:
    failures: list[str] = []
    found: set[str] = set()
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        doc = yaml.safe_load(path.read_text(encoding="utf-8"))
        if isinstance(doc, dict) and label_triggered(doc):
            found.add(path.name)
    for name in sorted(found - set(GUARDED) - set(REACTS)):
        failures.append(f"{name} re-runs on every label: add its labels to GUARDED (and guard its jobs) "
                        "or say why in REACTS")
    for name in sorted((set(GUARDED) | set(REACTS)) - found):
        failures.append(f"{name} is listed here but no longer triggers on labels: drop the entry")
    for name in sorted(set(GUARDED) & set(REACTS)):
        failures.append(f"{name} is in both GUARDED and REACTS")

    for name, labels in sorted(GUARDED.items()):
        path = WORKFLOWS / name
        if not path.exists():
            continue
        doc = yaml.safe_load(path.read_text(encoding="utf-8"))
        expected = guard(labels)
        for job, body in (doc.get("jobs") or {}).items():
            condition = str((body or {}).get("if") or "")
            text = condition.strip()
            if text.startswith("${{") and text.endswith("}}"):
                text = text[3:-2].strip()
            if (name, job) in UNGUARDED_JOBS:
                if expected in text:
                    failures.append(f"{name} job {job} must run on every label event: "
                                    f"{UNGUARDED_JOBS[(name, job)]}")
                continue
            if not reachable_by_label_event(body or {}, text):
                continue
            if not (text == expected or text.endswith(f") && {expected}")):
                failures.append(f"{name} job {job}: its if does not end with the label guard {expected}")
        group = str((doc.get("concurrency") or {}).get("group") or "")
        isolated = f"{expected[2:-1]} && format('-label-{{0}}', github.run_id)"
        if isolated not in group:
            failures.append(f"{name}: its concurrency group does not isolate other label events ({isolated})")

        cases = [
            ({"event_name": "pull_request", "action": "synchronize"}, True),
            ({"event_name": "pull_request", "action": "opened"}, True),
            ({"event_name": "push"}, True),
            ({"event_name": "pull_request", "action": "labeled", "label": "risk:high"}, False),
            ({"event_name": "pull_request", "action": "unlabeled", "label": "risk:normal"}, False),
            ({"event_name": "pull_request", "action": "labeled", "label": "ready-to-land"}, False),
            # Other bases keep re-running: main's required checks must not be superseded by a skip.
            ({"event_name": "pull_request", "action": "labeled", "label": "risk:high", "base": "main"}, True),
        ] + [({"event_name": "pull_request", "action": action, "label": label}, True)
             for label in labels for action in ("labeled", "unlabeled")]
        for event, want in cases:
            if evaluate(expected, event) is not want:
                failures.append(f"{name}: guard gives {not want} for {event}, want {want}")

    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    if failures:
        return 1
    print(f"{len(found)} label-triggered workflows: {len(GUARDED)} skip foreign labels, {len(REACTS)} react on purpose")
    return 0


if __name__ == "__main__":
    sys.exit(main())
