#!/usr/bin/env python3
"""Every runner label a cmux job can be routed to has a declared provider, and no provider we run sits on Blacksmith.

2026-11-19, twice in one day, jobs were routed to a label nobody served. First HQ's RUNNER_POOLS was hand-set to
cmux-gcp-lane-x64 while no runner carried it. Then, at feat-cmux-next ae733ab0, 168 jobs waited on
cmux-fleet-linux-x64 from 05:27Z with "no runner carries this label". The one thing that boots that label's runners,
HQ's gha-runners reconciler, ran on the starved blacksmith-2vcpu-ubuntu-2404 pool, so the repair waited on the pool it
repairs (cmuxterm-hq docs/handbook/repair-path-on-the-pool-it-repairs.md).

The labels read here:
- every literal label a job's `runs-on` can resolve to, in every workflow (workflow_jobs.runs_on_values: matrix values
  expanded, a reusable workflow's inputs traced to its callers, literal branches of an expression);
- every member of every pool and fleet in .github/runners.json (what a RUNNER_POOLS or LINUX_RUNNER read can hold);
- every FLEET_LINUX, *RUNNER* or *LABEL* constant whose value is shaped like a runner label: workflow `env:`/`with:`
  keys, and module-level Python and shell assignments under scripts/ci.

Each one must match exactly one provider's `serves` in tests/ci_label_providers.json, the one place providers are
declared. A provider that is ours (a runner set or a reconciler) names where it runs. That place must not be Blacksmith
and must not be a RUNNER_POOLS read, unless the provider has a `blacksmith_exempt` reason. An exemption that its
runs_on no longer needs fails the test, so it cannot outlive the move.
"""
from __future__ import annotations

import ast
import fnmatch
import json
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
import workflow_jobs  # noqa: E402

WORKFLOWS = ROOT / ".github" / "workflows"
SCRIPTS_CI = ROOT / "scripts" / "ci"
PROVIDERS = Path(__file__).resolve().parent / "ci_label_providers.json"
KINDS = {"vendor", "runner-set", "reconciler"}
# A constant whose name says it holds a runner label.
LABEL_NAME = re.compile(r"FLEET_LINUX|RUNNER|LABEL")
# A value shaped like one of our runner label families; a prefix (ends in "-") or a PR label is not one.
LABEL_SHAPE = re.compile(r"(?:blacksmith|glaeda|cmux|ubuntu|macos|windows|hq)-[a-z0-9][a-z0-9._-]*[a-z0-9]")
SHELL_ASSIGN = re.compile(r"^\s*(?:export\s+|readonly\s+|local\s+)?([A-Z][A-Z0-9_]*)=['\"]?([A-Za-z0-9._-]+)['\"]?\s*(?:#.*)?$",
                          re.M)
BLACKSMITH = re.compile(r"blacksmith-", re.I)
POOL_READ = re.compile(r"vars\.RUNNER_POOLS")


def load_providers(path: Path = PROVIDERS) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def _runs_on_labels() -> dict[str, set[str]]:
    docs = {p.name: workflow_jobs.document(p) for p in sorted(WORKFLOWS.glob("*.y*ml"))}
    tree = workflow_jobs.Workflows(docs)
    out: dict[str, set[str]] = {}
    for name, doc in docs.items():
        for job_id, job in ((doc or {}).get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            labels, _unresolved = workflow_jobs.runs_on_values(job, name, tree)
            for label in labels:
                if label and "${{" not in label:
                    out.setdefault(label, set()).add(f"{name} {job_id} runs-on")
    return out


def _runners_json_labels() -> dict[str, set[str]]:
    runners = json.loads((ROOT / ".github" / "runners.json").read_text(encoding="utf-8"))
    out: dict[str, set[str]] = {}
    for pool, spec in (runners.get("pools") or {}).items():
        if pool.startswith("$") or not isinstance(spec, dict):
            continue
        for label in spec.get("members") or []:
            out.setdefault(label, set()).add(f".github/runners.json pools.{pool}")
    for fleet, spec in (runners.get("fleets") or {}).items():
        for capability, label in (spec or {}).items():
            if isinstance(label, str):
                out.setdefault(label, set()).add(f".github/runners.json fleets.{fleet}.{capability}")
    return out


def _walk_keys(value, where: str, out: dict[str, set[str]]) -> None:
    if isinstance(value, dict):
        for key, item in value.items():
            if isinstance(key, str) and LABEL_NAME.search(key.upper()) and isinstance(item, str) \
                    and LABEL_SHAPE.fullmatch(item.strip()):
                out.setdefault(item.strip(), set()).add(f"{where} {key}")
            _walk_keys(item, where, out)
    elif isinstance(value, list):
        for item in value:
            _walk_keys(item, where, out)


def _workflow_constants() -> dict[str, set[str]]:
    out: dict[str, set[str]] = {}
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        _walk_keys(workflow_jobs.document(path), path.name, out)
    return out


def python_constants(source: str, where: str) -> dict[str, set[str]]:
    """Label-shaped string constants (or tuples, lists and sets of them) assigned to a FLEET_LINUX / RUNNER / LABEL
    name anywhere in a module."""
    out: dict[str, set[str]] = {}
    try:
        tree = ast.parse(source)
    except SyntaxError:
        return out
    for node in ast.walk(tree):
        targets = node.targets if isinstance(node, ast.Assign) else [node.target] if isinstance(node, ast.AnnAssign) else []
        value = getattr(node, "value", None)
        # A runner GROUP (glaeda-minis, cmux-fleet-linux) is where runners register, not a label a job asks for.
        names = [t.id for t in targets if isinstance(t, ast.Name) and LABEL_NAME.search(t.id) and "GROUP" not in t.id]
        if not names or value is None:
            continue
        items = value.elts if isinstance(value, (ast.Tuple, ast.List, ast.Set)) else [value]
        for item in items:
            if isinstance(item, ast.Constant) and isinstance(item.value, str) and LABEL_SHAPE.fullmatch(item.value):
                out.setdefault(item.value, set()).add(f"{where} {names[0]}")
    return out


def shell_constants(source: str, where: str) -> dict[str, set[str]]:
    out: dict[str, set[str]] = {}
    for match in SHELL_ASSIGN.finditer(source):
        name, value = match.groups()
        if LABEL_NAME.search(name) and "GROUP" not in name and LABEL_SHAPE.fullmatch(value):
            out.setdefault(value, set()).add(f"{where} {name}")
    return out


def _script_constants() -> dict[str, set[str]]:
    out: dict[str, set[str]] = {}
    for path in sorted(SCRIPTS_CI.rglob("*")):
        if not path.is_file() or "_vendor" in path.parts:
            continue
        where = str(path.relative_to(ROOT))
        if path.suffix == ".py":
            found = python_constants(path.read_text(encoding="utf-8", errors="replace"), where)
        elif path.suffix in (".sh", ".bash", "") and path.stat().st_size < 1_000_000:
            text = path.read_text(encoding="utf-8", errors="replace")
            if path.suffix == "" and not text.startswith("#!"):
                continue
            found = shell_constants(text, where)
        else:
            continue
        for label, sources in found.items():
            out.setdefault(label, set()).update(sources)
    return out


def every_label() -> dict[str, set[str]]:
    """label -> where it is named."""
    out: dict[str, set[str]] = {}
    for part in (_runs_on_labels(), _runners_json_labels(), _workflow_constants(), _script_constants()):
        for label, sources in part.items():
            out.setdefault(label, set()).update(sources)
    return out


def providers_of(label: str, providers: dict) -> list[str]:
    low = label.lower()
    return [name for name, spec in providers.items()
            if any(fnmatch.fnmatchcase(low, pattern.lower()) for pattern in spec.get("serves") or [])]


def unprovided(labels: dict[str, set[str]], data: dict) -> dict[str, str]:
    """label -> why it has no single declared provider."""
    skip = data.get("not_runner_labels") or {}
    bad = {}
    for label, sources in sorted(labels.items()):
        if label in skip:
            continue
        found = providers_of(label, data["providers"])
        if len(found) != 1:
            why = "no provider serves it" if not found else f"served by {len(found)} providers ({', '.join(found)})"
            bad[label] = f"{why}; named in {', '.join(sorted(sources)[:3])}"
    return bad


def on_blacksmith(spec: dict) -> list[str]:
    """Each runs_on entry of a provider that can put it on Blacksmith: a Blacksmith label or a RUNNER_POOLS read."""
    return [r for r in spec.get("runs_on") or [] if BLACKSMITH.search(r) or POOL_READ.search(r)]


def provider_problems(data: dict) -> list[str]:
    problems = []
    for name, spec in sorted(data["providers"].items()):
        kind = spec.get("kind")
        if kind not in KINDS:
            problems.append(f"{name}: kind {kind!r} is not one of {sorted(KINDS)}")
            continue
        if not spec.get("serves"):
            problems.append(f"{name}: serves no label")
        if kind == "vendor":
            continue
        if not spec.get("runs_on"):
            problems.append(f"{name}: a {kind} must say where it runs (runs_on)")
            continue
        hits, exempt = on_blacksmith(spec), spec.get("blacksmith_exempt")
        if hits and not exempt:
            problems.append(f"{name}: runs on {hits}, which can be Blacksmith: the provider would wait on the pool "
                            "it may have to repair (move it off Blacksmith, or say why in blacksmith_exempt)")
        if exempt and not hits:
            problems.append(f"{name}: blacksmith_exempt is stale (runs_on no longer reaches Blacksmith); delete it")
    return problems


class LabelHasProvider(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = load_providers()
        cls.labels = every_label()

    def test_every_routed_label_has_one_declared_provider(self):
        self.assertEqual(unprovided(self.labels, self.data), {})

    def test_no_provider_of_ours_runs_on_blacksmith(self):
        self.assertEqual(provider_problems(self.data), [])

    def test_the_scan_reads_each_source(self):
        # The labels of 2026-11-19 and one of each source, so a scan that silently reads nothing fails here.
        for label, source in (("cmux-fleet-linux-x64", "scripts/ci/"), ("cmux-gcp-lane-build-x64", "runs-on"),
                              ("blacksmith-4vcpu-ubuntu-2404", ".github/runners.json"),
                              ("glaeda-side-std-xcode-26.6", "runs-on")):
            self.assertIn(label, self.labels)
            self.assertTrue(any(source in s for s in self.labels[label]), (label, self.labels[label]))
        self.assertEqual(providers_of("cmux-fleet-linux-x64", self.data["providers"]), ["gha-runners"])

    def test_an_unserved_label_fails(self):
        labels = {**self.labels, "cmux-gcp-lane-x64": {"fixture.yml job runs-on"}}
        self.assertIn("cmux-gcp-lane-x64", unprovided(labels, self.data))
        both = {"providers": {"a": {"kind": "vendor", "serves": ["x-*"]}, "b": {"kind": "vendor", "serves": ["x-1"]}}}
        self.assertIn("2 providers", unprovided({"x-1": {"f"}}, both)["x-1"])

    def test_a_provider_on_blacksmith_fails_and_a_stale_exemption_fails(self):
        def data(**spec):
            return {"providers": {"p": {"kind": "reconciler", "serves": ["cmux-x"], **spec}}}
        self.assertTrue(provider_problems(data(runs_on=["blacksmith-2vcpu-ubuntu-2404"])))
        self.assertTrue(provider_problems(data(runs_on=["${{ fromJSON(vars.RUNNER_POOLS).small }}"])))
        self.assertTrue(provider_problems(data()))  # says nowhere where it runs
        self.assertEqual(provider_problems(data(runs_on=["the build controller"])), [])
        self.assertEqual(provider_problems(data(runs_on=["blacksmith-2vcpu-ubuntu-2404"], blacksmith_exempt="moving")), [])
        self.assertTrue(provider_problems(data(runs_on=["the build controller"], blacksmith_exempt="moving")))

    def test_constants_are_read_from_python_and_shell(self):
        py = python_constants('FLEET_LINUX = "cmux-fleet-linux-x64"\nRUNNER_PREFIX = "glaeda-runner-"\n'
                              'LABELS = ("glaeda-a-xcode", "hold")\nISSUE_LABEL = "ci-runner-starved"\n', "f.py")
        self.assertEqual(set(py), {"cmux-fleet-linux-x64", "glaeda-a-xcode"})
        sh = shell_constants('FLEET_LINUX=cmux-fleet-linux-x64\nexport MAC_RUNNER="glaeda-std-xcode-26.6"\n'
                             'OTHER=cmux-x\n', "f.sh")
        self.assertEqual(set(sh), {"cmux-fleet-linux-x64", "glaeda-std-xcode-26.6"})


if __name__ == "__main__":
    unittest.main()
