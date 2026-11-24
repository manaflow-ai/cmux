#!/usr/bin/env python3
"""A docs-only pull request starts only the workflows ALLOWED names, and nothing it skips reads its files.

Leo, 2026-11-19, on prose-only pull requests that each started 28 workflows and 180-275 jobs: "I kept saying, skip
CI, skip it ... when it's unnecessary ... We need to skip more often." scripts/ci/docs_only_paths.py holds the one
`paths:` block (DOCS_ONLY_PATHS) the skippable workflows carry on pull_request. This fails when:

  - a docs-only pull request into feat-cmux-next or main would start a workflow ALLOWED does not name (give that
    workflow the block, or add it here with the reason it must start for prose);
  - a required check's workflow gets a path filter (a required check that never starts blocks the merge forever);
  - a copy of the block drifted from DOCS_ONLY_PATHS (`python3 scripts/ci/docs_only_paths.py --sync`);
  - a Rust `include_str!` / `include_bytes!` compiles in a file the block leaves out;
  - a test ci-guards.yml's groups run (ci.yml and cmux-next-guards.yml run them) reads a file the block leaves out;
  - docs-only-fallback.yml stops covering what the block gets wrong: GitHub matches `paths:` against only the first
    300 changed files (300 prose files and one code file started none of the filtered workflows), and the block
    filters label events too (`full-ci`/`dev-build` on a docs-only pull request started no CI). Its gate must call
    each filtered workflow that should have started and did not, fail open, and take no runner otherwise.

The tests a filtered workflow's own steps run are checked by tests/test_ci_workflow_paths_cover_inputs.py, as for
any path filter.
"""
from __future__ import annotations

import fnmatch
import functools
import importlib.util
import os
import re
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import docs_only_paths as docs  # noqa: E402
import workflow_paths_cover_inputs as filters  # noqa: E402

WORKFLOWS = ROOT / ".github" / "workflows"

# The required checks' workflows (repository rules: main requires CLA Assistant, CLA policy guard and backend
# migrations applied; feat-cmux-next requires clippy (changed cmux-tui packages) and React Doctor (changed React
# projects)). They must start for every pull request: each gates its own work inside.
REQUIRED = {
    "backend-migrations.yml": "backend migrations applied (main); its plan job finds no migration in prose",
    "cmux-tui-spec.yml": "clippy (changed cmux-tui packages) (feat-cmux-next); its changes job skips the rest",
    "cmux-next-react-doctor.yml": "React Doctor (changed React projects) (feat-cmux-next)",
}

# workflow -> why a docs-only pull request still starts it. Each entry must still start for some sample below.
ALLOWED: dict[str, str] = {
    **REQUIRED,
    "cmux-next-fast-gates.yml": "next-autoland lands a head only on its cmux-next/fast-gates status (and dispatches "
                                "the workflow when the status is missing), about two minutes on Linux",
    "risk-tier.yml": "next-autoland's MUST_PASS `risk evidence`; one job",
    "merge-freeze.yml": "a merge freeze holds every pull request, prose included; one job",
    "pr-body-checks.yml": "lints the description, which a docs pull request has too; one job",
    "pr-router.yml": "the router: it reads the changed paths and starts only the workflows they reach (scripts/ci/pr_router.json); one small job",
    "language-boundaries.yml": "policy over every changed path; one job",
    "thunderdome-label.yml": "labels by title; one job that skips unless the title asks",
    "cmux-next-batch.yml": "batches every open pull request; one job, off unless CMUX_NEXT_BATCH_ENABLED",
    "docs-only-fallback.yml": "covers what the docs-only block can get wrong (GitHub reads only the first 300 changed "
                              "files; label events are filtered too); its gate skips with no runner for a pull request "
                              "of 300 files or fewer and no full-ci/dev-build label",
    "ios-e2e.yml": "already routes a prose-only diff past its Mac job (route + status only), and its status is on "
                   "the way to being required (docs/ci/ios-e2e.md): a filter would then block docs pull requests",
}

# Path-filtered workflows whose own list takes a package or tree whole, Markdown included, so an edit to a README or
# design note inside that tree still starts them. Each must keep a pull_request path filter (an unfiltered workflow
# is never excused here) and still start for some tracked docs file. Taking Markdown out of each list is a follow-up
# per workflow: each list's push copy must stay in step (tests/test_ci_workflow_path_filter_parity.py), and several
# put Markdown back on purpose (ios-review-gate.yml's AppStoreReview/**).
SCOPED: dict[str, str] = {
    "auth-refresh-tests.yml": "the auth runtime package and the vendored Stack Auth SDK",
    "backend.yml": "backend/** and libs/**",
    "chief-evals.yml": "Native/OptChat/optchat-chief/evals/person.md, the eval cases' default profile (#47445)",
    "classic-frozen-guard.yml": ".github/classic-frozen.txt's globs, Markdown in frozen classic paths included "
                                "(scripts/ci/pr_trigger_paths.py classic_frozen)",
    "billing.yml": "docs/billing/** by name, the billing spec beside its package",
    "cloudflare-relay.yml": "cmux-tui/relays/cloudflare-do/**",
    "cmux-next-crash-class.yml": "Packages/macOS/CmuxNext/Sources/**",
    "cmux-next.yml": "the plan docs a Swift target names (put back by name; test_unrouted_plan_docs_skip_cmux_next) "
                     "and the README its checks tier reads",
    "cmux-tui-sdks.yml": "cmux-tui/**",
    "rust-workspaces.yml": "the files a run workspace's sources name by literal path (scripts/ci/pr_trigger_paths.py "
                           "rust_workspaces): docs/assets/screenshot.png, cmux-image-linear's compare test fixture, "
                           "and docs/posthog/chief-product-analytics.md, the event catalog optchat-chief's analytics "
                           "follow",
    "cmux-tui-windows-check.yml": "cmux-tui/**",
    "cmux-vm.yml": "workers/cmux-vm/**",
    "coderouter-ci.yml": "coderouter/**",
    "device-hub.yml": "workers/device-hub/**",
    "fleet-artifact-cdn.yml": "workers/fleet-artifacts/**",
    "ios-reliability-matrix.yml": "cmux-next-ios/rust/** and the vendored smoltcp",
    "ios-review-gate.yml": "cmux-next-ios/AppStoreReview/**, whose Markdown the gate reads",
    "iroh-v2.yml": "workers/iroh-v2/**",
    "relay-tls.yml": "Packages/Shared/CmuxIrohTransport/**",
    "terminal-hang-diagnostics.yml": "Packages/Shared/CMUXMobileCore/**",
    "test-ios.yml": "Packages/Shared/**",
    "web-complexity.yml": "web/**",
    "web-complexity-trusted.yml": "web/**",
}

# Docs-only pull requests: the two of Leo's 2026-11-19 complaint that are prose (#45476 changed CLAUDE.md, which
# agents read as instructions: never docs-only), and one for each prose tree.
SAMPLES: dict[str, list[str]] = {
    "#44917": [
        "cmux-next-ios/design/SPEC.md",
        "cmux-next-ios/verify/design/terminal/ACCEPTANCE.md",
        "cmux-next-ios/verify/tui-fast-scroll.md",
        "cmux-next-ios/verify/url-truncation.md",
        "plans/cmux-next/device-control-DESIGN.md",
    ],
    "#40040": ["plans/cmux-next/ghostty-integration.md"],
    "a docs note": ["docs/cmux-next/a-new-note.md"],
    "a docs image": ["docs/images/a-new-diagram.png"],
    "a root doc": ["CONTRIBUTING.md"],
}
BASES = ("feat-cmux-next", "main")
DEFAULT_TYPES = {"opened", "synchronize", "reopened"}


@functools.lru_cache(maxsize=None)
def load(name: str):
    # Parsed once: the allowed-workflows test asks for every workflow once per base and sample (282 x 2 x 12 parses, 113 s).
    return filters.load_yaml(WORKFLOWS / name)


def branch_matches(patterns, base: str) -> bool:
    return filters.admits("paths", [str(p) for p in patterns], base)


def starts(document, base: str, files: list[str]) -> bool:
    """Whether a push of `files` to a pull request into `base` (opened or synchronize) starts the workflow."""
    for event in ("pull_request", "pull_request_target"):
        if event not in filters.triggers(document):
            continue
        config = filters.triggers(document)[event] or {}
        if not isinstance(config, dict):
            config = {}
        if "branches" in config and not branch_matches(config["branches"], base):
            continue
        if "branches-ignore" in config and branch_matches(config["branches-ignore"], base):
            continue
        types = set(map(str, config.get("types") or DEFAULT_TYPES))
        if not types & {"opened", "synchronize"}:
            continue
        if "paths" in config:
            if any(filters.admits("paths", [str(p) for p in config["paths"]], f) for f in files):
                return True
        elif "paths-ignore" in config:
            if any(filters.admits("paths-ignore", [str(p) for p in config["paths-ignore"]], f) for f in files):
                return True
        else:
            return True
    return False


def workflow_names() -> list[str]:
    return sorted(p.name for p in [*WORKFLOWS.glob("*.yml"), *WORKFLOWS.glob("*.yaml")])


@functools.lru_cache(maxsize=None)
def tracked_docs() -> tuple[str, ...]:
    out = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z"], capture_output=True, check=True).stdout
    return tuple(p for p in out.decode("utf-8", "replace").split("\0") if p and docs.is_docs(p))


INCLUDE = re.compile(r'include_(?:str|bytes)!\s*\(\s*(?:concat!\s*\(\s*env!\s*\(\s*"CARGO_MANIFEST_DIR"\s*\)\s*,\s*)?'
                     r'"([^"]+)"')


def crate_root(rel: str) -> str:
    parts = rel.split("/")[:-1]
    while parts and not (ROOT / "/".join(parts) / "Cargo.toml").is_file():
        parts.pop()
    return "/".join(parts)


def compiled_in() -> dict[str, str]:
    """{repo path: the .rs file and line} for every literal include_str! / include_bytes! of a tracked .rs file."""
    out = subprocess.run(["git", "-C", str(ROOT), "grep", "-n", "-E", r"include_(str|bytes)!", "--", "*.rs"],
                         capture_output=True, text=True)
    found: dict[str, str] = {}
    for line in out.stdout.splitlines():
        source, number, text = line.split(":", 2)
        for match in INCLUDE.finditer(text):
            literal = match.group(1)
            if "CARGO_MANIFEST_DIR" in match.group(0):
                target = os.path.normpath(os.path.join(crate_root(source), literal.lstrip("/")))
            else:
                target = os.path.normpath(os.path.join(os.path.dirname(source), literal))
            found.setdefault(target, f"{source}:{number}")
    return found


class DocsOnlyPullRequests(unittest.TestCase):
    def test_samples_are_docs_only(self):
        for name, files in SAMPLES.items():
            self.assertTrue(docs.docs_only(files), f"{name}: {[f for f in files if not docs.is_docs(f)]}")

    def test_instructions_and_read_prose_are_never_docs(self):
        for path in ("CLAUDE.md", "AGENTS.md", "cmux-next-ios/AGENTS.md", "skills/cmux/SKILL.md",
                     "skills/cmux-browser/references/commands.md", ".github/pull_request_template.md",
                     "docs/agent-hooks.md", "release-notes/next/1.2.3.md", "CHANGELOG.md", "src/main.rs"):
            self.assertFalse(docs.is_docs(path), path)
        self.assertFalse(docs.docs_only([]), "an empty diff is not docs-only")
        self.assertFalse(docs.docs_only(["docs/a.md", "src/a.rs"]), "a mixed diff is not docs-only")

    def test_a_docs_only_pull_request_starts_only_allowed_workflows(self):
        unexpected = []
        for base in BASES:
            for sample, files in SAMPLES.items():
                for name in workflow_names():
                    if name not in ALLOWED and starts(load(name), base, files):
                        unexpected.append(f"{name} (into {base}, {sample})")
        self.assertEqual(unexpected, [], "give each workflow the docs-only block (scripts/ci/docs_only_paths.py "
                                         "WORKFLOWS, then --sync) or add it to ALLOWED with its reason")

    def test_every_tracked_doc_alone_starts_only_allowed_or_scoped_workflows(self):
        unexpected: dict[str, list[str]] = {}
        documents = {name: load(name) for name in workflow_names() if name not in ALLOWED}
        for base in BASES:
            for path in tracked_docs():
                for name, document in documents.items():
                    if starts(document, base, [path]) and name not in SCOPED:
                        unexpected.setdefault(name, []).append(f"{path} (into {base})")
        lines = [f"{name}: {', '.join(paths[:3])}" for name, paths in sorted(unexpected.items())]
        self.assertEqual(lines, [], "give each workflow the docs-only block, or take Markdown out of its own list")

    def test_every_allowed_workflow_still_starts_for_docs(self):
        for name, reason in ALLOWED.items():
            self.assertTrue(reason.strip(), name)
            self.assertTrue((WORKFLOWS / name).is_file(), f"{name} is gone: remove its ALLOWED entry")
            started = any(starts(load(name), base, files) for base in BASES for files in SAMPLES.values())
            self.assertTrue(started, f"{name} no longer starts for a docs-only pull request: remove its entry")

    def test_every_scoped_workflow_is_filtered_and_still_starts_for_a_doc(self):
        docs_files = tracked_docs()
        for name, reason in SCOPED.items():
            self.assertTrue(reason.strip(), name)
            self.assertNotIn(name, ALLOWED, name)
            self.assertTrue((WORKFLOWS / name).is_file(), f"{name} is gone: remove its SCOPED entry")
            events = filters.triggers(load(name))
            configs = [events.get(e) for e in ("pull_request", "pull_request_target") if e in events]
            self.assertTrue(configs and all(isinstance(c, dict) and {"paths", "paths-ignore"} & set(c) for c in configs),
                            f"{name} has no pull_request(_target) path filter: SCOPED excuses only a scoped list")
            started = any(starts(load(name), base, [path]) for base in BASES for path in docs_files)
            self.assertTrue(started, f"{name} no longer starts for any docs file: remove its SCOPED entry")

    def test_required_checks_have_no_path_filter(self):
        for name in REQUIRED:
            for event in ("pull_request", "pull_request_target"):
                config = filters.triggers(load(name)).get(event)
                if isinstance(config, dict):
                    self.assertFalse({"paths", "paths-ignore"} & set(config), f"{name} {event}: a required check "
                                     "that never starts stays Expected and blocks the merge")
        for name in docs.WORKFLOWS:
            self.assertNotIn(Path(name).name, REQUIRED, name)

    def test_every_copy_of_the_block_matches(self):
        self.assertEqual(docs.main(["--check", "--root", str(ROOT)]), 0,
                         "run python3 scripts/ci/docs_only_paths.py --sync")
        for name in docs.block_workflows(ROOT):
            config = filters.triggers(filters.load_yaml(ROOT / name)).get("pull_request") or {}
            self.assertEqual([str(p) for p in config.get("paths") or []], list(docs.DOCS_ONLY_PATHS), name)
            self.assertNotIn("paths-ignore", config, name)

    def test_a_workflow_with_derived_trigger_paths_keeps_them(self):
        # scripts/ci/pr_trigger_paths.py derives these from their own deciders: fewer paths than the block, so the
        # block is not written into them, and the fallback still calls them.
        derived = set(docs.json.loads((ROOT / docs.TRIGGER_PATHS).read_text()).get("derived", {}))
        fallback = (ROOT / docs.FALLBACK).read_text()
        for name in set(docs.WORKFLOWS) & derived:
            self.assertNotIn(name, docs.block_workflows(ROOT), name)
            self.assertNotIn(docs.BEGIN, (ROOT / name).read_text(), name)
            self.assertIn(f"uses: ./{name}", fallback, name)

    def test_nothing_compiled_in_is_docs(self):
        found = compiled_in()
        self.assertIn("docs/cmux-next/customize-recipes.md", found, "the include_str! scan reads the Rust tree")
        skipped = sorted(f"{path} ({where})" for path, where in found.items() if docs.is_docs(path))
        self.assertEqual(skipped, [], "put each back in scripts/ci/docs_only_paths.py DOCS_ONLY_PATHS")

    def test_no_generated_output_is_docs(self):
        """cmux-next-pr-autofix's generated-drift job catches a hand edit of a generated file; a docs-only pull
        request does not start it, so no generated output may be docs."""
        spec = importlib.util.spec_from_file_location("generated_outputs",
                                                      ROOT / "scripts" / "cmux-next" / "generated_outputs.py")
        generated = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(generated)
        patterns = [pattern for outputs, _inputs, _how in generated.OUTPUTS for pattern in outputs]
        self.assertIn("plans/cmux-next/actions.md", patterns)
        tracked = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z"], capture_output=True,
                                 check=True).stdout.decode("utf-8", "replace").split("\0")
        outputs = [p for p in tracked if p and any(fnmatch.fnmatch(p, pattern) for pattern in patterns)]
        self.assertEqual([p for p in outputs if docs.is_docs(p)], [],
                         "put each back in scripts/ci/docs_only_paths.py DOCS_ONLY_PATHS")

    def test_unrouted_plan_docs_skip_cmux_next(self):
        """cmux-next.yml's pull_request list takes plans/cmux-next/** but leaves its Markdown out, putting back by
        name each doc a Swift target reads (scripts/ci/cmux_next_route.py routes a doc only when a target's string
        literal names it, or a generated one). Every plan doc the list leaves out must route to no tier."""
        import cmux_next_route  # noqa: PLC0415 - scripts/ci

        config = filters.triggers(load("cmux-next.yml"))["pull_request"]
        patterns = [str(p) for p in config["paths"]]
        out = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z", "plans/cmux-next"], capture_output=True,
                             check=True).stdout.decode("utf-8", "replace").split("\0")
        left_out = [p for p in out if p.endswith(".md") and not filters.admits("paths", patterns, p)]
        self.assertTrue(left_out, "cmux-next.yml leaves plan docs out")
        reached = []
        for path in left_out:
            values = cmux_next_route.outputs(cmux_next_route.route(ROOT, "pull_request", [path], set()))
            tiers = sorted(name for name, value in values.items() if value == "true")
            if tiers:
                reached.append(f"{path}: {', '.join(tiers)}")
        self.assertEqual(reached, [], "put each back by name in cmux-next.yml's pull_request paths (and "
                                      "tests/test_ci_workflow_path_filter_parity.py PULL_REQUEST_ONLY_PATTERNS)")

    def test_no_guard_group_test_reads_docs(self):
        """ci-guards.yml's groups run inside ci.yml and cmux-next-guards.yml (guards-local.sh --feat-routes), which
        a docs-only pull request no longer starts: none of their tests may read a file the block leaves out."""
        import run_ci_guards  # noqa: PLC0415 - scripts/ci

        units = run_ci_guards.plan(run_ci_guards.load_yaml(WORKFLOWS / "ci-guards.yml"), "BASE", "HEAD")
        walker = filters.Walker(filters.Repo.load(ROOT))
        reads: list[str] = []
        for unit in units:
            for step in unit.steps:
                cwd = str(ROOT / step.working_directory) if step.working_directory else str(ROOT)
                for test in walker.entries(step.run, cwd, {}):
                    for found, chain in walker.closure(test, cwd).items():
                        if docs.is_docs(str(found)):
                            reads.append(f"{found}  [{' -> '.join(chain)}]")
        self.assertTrue(units, "ci-guards.yml has groups")
        self.assertEqual(sorted(set(reads)), [], "put each back in scripts/ci/docs_only_paths.py DOCS_ONLY_PATHS")


CODE = "Sources/App.swift"
PROSE = [f"plans/cmux-next/note-{i:03}.md" for i in range(300)]


def pull_request_event(action: str, base: str = "feat-cmux-next", label: str | None = None,
                       changed: int = 1) -> dict:
    event = {"action": action, "pull_request": {"base": {"ref": base}, "changed_files": changed}}
    if label is not None:
        event["label"] = {"name": label}
    return event


def gate_runs(event: dict) -> bool:
    """Evaluates the fallback gate's `if` for a pull_request event (its operators only)."""
    text = docs.gate_condition().strip()[3:-2]
    text = re.sub(r"fromJSON\('([^']*)'\)", lambda m: repr(__import__("json").loads(m.group(1))), text)
    text = re.sub(r"contains\((\[[^\]]*\]), ([^)]+)\)", r"(\2 in \1)", text)
    values = {
        "github.event.pull_request.changed_files": repr(event["pull_request"]["changed_files"]),
        "github.event.pull_request.base.ref": repr(event["pull_request"]["base"]["ref"]),
        "github.event_name": repr("pull_request"),
        "github.event.action": repr(event["action"]),
        "github.event.label.name": repr((event.get("label") or {}).get("name")),
    }
    for name, value in values.items():
        text = text.replace(name, value)
    text = text.replace("&&", " and ").replace("||", " or ").replace("!=", " __NE__ ")
    text = text.replace("!", " not ").replace(" __NE__ ", " != ")
    return bool(eval(text, {"__builtins__": {}}, {}))  # noqa: S307 - our own generated expression


class Fallback(unittest.TestCase):
    """GitHub matches `paths:` against only a pull request's first 300 changed files, and filters label events too.
    docs-only-fallback.yml calls, in the pull request's own context, each workflow of WORKFLOWS that should have
    started and shows no run; anything it cannot read, it calls."""

    calls = {Path(name).name: docs.pull_request_config(ROOT, name) for name in docs.WORKFLOWS}
    feat_only = sorted(n for n, c in calls.items() if c["branches"] == ["feat-cmux-next"])
    # A pr-router callee (web-validation.yml, #48775) starts on its own only into main: into feat-cmux-next the
    # router calls it, so the fallback never does.
    main_only = sorted(n for n, c in calls.items() if c["branches"] == ["main"])

    def plan(self, event, files, runs=(), since=1000.0):
        return docs.plan_fallback(event, self.calls, files, None if runs is None else list(runs), since)

    def test_301_files_with_code_last_call_every_workflow_that_did_not_start(self):
        files = PROSE + [CODE]
        self.assertFalse(docs.docs_only(files))
        self.assertTrue(docs.docs_only(files[:docs.PATHS_FILTER_LIMIT]), "GitHub's first 300 are prose")
        event = pull_request_event("synchronize", changed=len(files))
        self.assertTrue(gate_runs(event))
        pushed = sorted(n for n, c in self.calls.items() if "synchronize" in c["types"])
        self.assertEqual(set(pushed), set(self.calls), "every filtered workflow runs on a push")
        due = sorted(set(pushed) - set(self.main_only))
        self.assertEqual(sorted(self.plan(event, files)), due)
        # A workflow GitHub did start (it saw a code file in its first 300) is not called again.
        started = [{"path": ".github/workflows/ci.yml", "created": 0.0}]
        self.assertEqual(sorted(self.plan(event, files, started)), [n for n in due if n != "ci.yml"])
        # Into main only the workflows without a feat-cmux-next branch filter are due.
        main = pull_request_event("synchronize", base="main", changed=len(files))
        self.assertEqual(sorted(self.plan(main, files)), sorted(set(pushed) - set(self.feat_only)))

    def test_unread_files_or_runs_fail_open(self):
        event = pull_request_event("opened", changed=5000)
        self.assertTrue(gate_runs(event))
        opened = sorted(n for n, c in self.calls.items() if "opened" in c["types"])
        due = sorted(set(opened) - set(self.main_only))
        self.assertEqual(sorted(self.plan(event, None, None)), due)
        main = pull_request_event("opened", base="main", changed=5000)
        self.assertEqual(sorted(self.plan(main, None, None)), sorted(set(opened) - set(self.feat_only)))
        self.assertEqual(sorted(self.plan(event, None)), due, "no run seen: call each")
        self.assertEqual(sorted(self.plan(event, PROSE + [CODE], None)), due)

    def test_a_large_docs_only_pull_request_calls_nothing(self):
        files = PROSE + ["docs/one-more.md"]
        self.assertEqual(self.plan(pull_request_event("synchronize", changed=len(files)), files, None), [])

    def test_300_files_or_fewer_take_no_runner_and_call_nothing(self):
        for action in ("opened", "synchronize", "reopened", "edited", "ready_for_review", "closed", "unlabeled"):
            self.assertFalse(gate_runs(pull_request_event(action, changed=300)), action)
            self.assertFalse(gate_runs(pull_request_event(action, base="main", changed=12)), action)
        self.assertEqual(self.plan(pull_request_event("synchronize", changed=2), ["docs/a.md", CODE], None), [])
        self.assertEqual(self.plan(pull_request_event("synchronize", changed=1), ["docs/a.md"], None), [])

    def test_a_ci_label_on_a_docs_only_pull_request_calls_what_listens_for_it(self):
        listens = sorted(n for n, c in self.calls.items() if "labeled" in c["types"])
        self.assertEqual(listens, ["ci.yml"])
        for label in docs.LABEL_OPT_INS:
            for base in BASES:
                event = pull_request_event("labeled", base=base, label=label)
                self.assertTrue(gate_runs(event), (label, base))
                self.assertEqual(self.plan(event, ["docs/a.md"], None), listens, (label, base))
        # Any other label: no runner into feat-cmux-next (or main, under 300 files), nothing called.
        for base in BASES:
            self.assertFalse(gate_runs(pull_request_event("labeled", base=base, label="risk:high")), base)
        self.assertEqual(self.plan(pull_request_event("labeled", label="risk:high"), ["docs/a.md"], None), [])
        # A code pull request of 300 files or fewer: ci.yml's own filter started it.
        self.assertEqual(self.plan(pull_request_event("labeled", label="full-ci"), [CODE], None), [])

    def test_a_ci_label_on_a_large_pull_request_needs_a_run_of_this_event(self):
        files = PROSE + [CODE]
        event = pull_request_event("labeled", label="full-ci", changed=len(files))
        earlier = [{"path": ".github/workflows/ci.yml", "created": 0.0}]
        self.assertEqual(self.plan(event, files, earlier, since=10_000.0), ["ci.yml"], "a run before the label")
        this_event = [{"path": ".github/workflows/ci.yml", "created": 9_999.0}]
        self.assertEqual(self.plan(event, files, this_event, since=10_000.0), [])

    def test_every_filtered_workflow_is_callable_and_called(self):
        fallback = load(Path(docs.FALLBACK).name)
        jobs = fallback["jobs"]
        for name in docs.WORKFLOWS:
            events = filters.triggers(filters.load_yaml(ROOT / name))
            self.assertIn("workflow_call", events, f"{name}: the fallback calls it (add `workflow_call:`)")
            calls = [j for j in jobs.values() if j.get("uses") == f"./{name}"]
            self.assertEqual(len(calls), 1, name)
            self.assertEqual(calls[0].get("needs"), "gate", name)
            self.assertIn(f"'{Path(name).name}')", calls[0]["if"], name)
            self.assertNotIn("secrets", calls[0], f"{name}: a call passes no secrets (they stay in their "
                                                  "protected environments), as for a fork's pull request")
        config = filters.triggers(fallback)["pull_request"]
        self.assertFalse({"paths", "paths-ignore", "branches", "branches-ignore"} & set(config),
                         "the fallback must start for every pull request")
        types = {t for name in docs.WORKFLOWS for t in self.calls[Path(name).name]["types"]}
        self.assertEqual(set(config["types"]), types - set(docs.UNCOVERED_TYPES),
                         "the fallback listens for every event a filtered one does but a description edit")
        self.assertTrue({"synchronize", "labeled"} <= set(config["types"]))
        gate = jobs["gate"]
        self.assertNotIn("needs", gate)
        self.assertIn("--fallback-plan", gate["steps"][-1]["run"])
        self.assertEqual(__import__("json").loads(gate["steps"][-1]["env"]["CALLS"]), self.calls)
        group = fallback["concurrency"]["group"]
        self.assertIn("format('-{0}-{1}', github.event.action, github.run_id)", group,
                      "only a push supersedes a run: a label or close event must not cancel a push's calls")
        self.assertIs(fallback["concurrency"]["cancel-in-progress"], True)

    def test_the_labels_are_ci_yml_s(self):
        ci = (WORKFLOWS / "ci.yml").read_text()
        self.assertIn(docs.label_guard(), ci, "ci.yml's label guard and the fallback's name the same labels")


class Units(unittest.TestCase):
    def test_starts_reads_branches_types_and_paths(self):
        doc = {"on": {"pull_request": {"branches": ["feat-cmux-next"], "types": ["closed"]}}}
        self.assertFalse(starts(doc, "feat-cmux-next", ["a.md"]))
        doc = {"on": {"pull_request": {"branches": ["main"]}}}
        self.assertFalse(starts(doc, "feat-cmux-next", ["a.md"]))
        self.assertTrue(starts(doc, "main", ["a.md"]))
        doc = {"on": {"pull_request": {"paths": list(docs.DOCS_ONLY_PATHS)}}}
        self.assertFalse(starts(doc, "main", ["docs/a.md", "plans/b/c.md"]))
        self.assertTrue(starts(doc, "main", ["docs/a.md", "CLAUDE.md"]))
        self.assertTrue(starts({"on": ["pull_request"]}, "main", ["a.md"]))
        self.assertFalse(starts({"on": {"push": {}}}, "main", ["a.md"]))

    def test_include_scan_resolves_paths(self):
        match = INCLUDE.search('const A: &str = include_str!("../../docs/x.md");')
        self.assertEqual(match.group(1), "../../docs/x.md")
        match = INCLUDE.search('include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/README.md"))')
        self.assertEqual(match.group(1), "/README.md")

    def test_rewrite_replaces_only_the_marked_block(self):
        text = f"on:\n  pull_request:\n    branches: [x]\n    {docs.BEGIN}\n    paths: [stale]\n    {docs.END}\n  push:\n"
        new = docs.rewrite(text, "w.yml")
        self.assertIn('      - "!**/*.md"', new)
        self.assertNotIn("stale", new)
        self.assertTrue(new.endswith("  push:\n"))
        with self.assertRaises(ValueError):
            docs.rewrite("on:\n  pull_request:\n", "w.yml")


if __name__ == "__main__":
    unittest.main()
