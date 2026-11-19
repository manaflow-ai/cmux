"""scripts/ci/affected_jobs.py: pull-request jobs route by the cmux-tui crate graph, never skip an input, and run
everything on a push, the full-ci label, a router change or a path the graph cannot place."""
import importlib.util
import json
import posixpath
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
spec = importlib.util.spec_from_file_location("affected_jobs", ROOT / "scripts/ci/affected_jobs.py")
jobs = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = jobs  # @dataclass reads its module from sys.modules (Python 3.12 raises without it)
spec.loader.exec_module(jobs)
git_tree = jobs.git_tree
verdict = jobs.cargo_test_verdict


def fake_tree(files: dict[str, str], submodules=()) -> "git_tree.GitTree":
    """A GitTree over FILES (path -> text), its directories listed as git lists them."""
    entries = {}
    for path in [*files, *submodules]:
        parts = path.split("/")
        for at in range(1, len(parts)):
            entries["/".join(parts[:at])] = (git_tree.DIRECTORY, "d" * 40)
    blobs = {}
    for n, (path, text) in enumerate(sorted(files.items())):
        oid = f"{n:040x}"
        entries[path] = ("100644", oid)
        blobs[oid] = text.encode()
    for path in submodules:
        entries[path] = (git_tree.SUBMODULE, "e" * 40)
    return git_tree.GitTree(ROOT, "fake", entries=entries, read_blob=lambda _path, oid: blobs[oid])


WORKSPACE_TOML = """[workspace]
members = ["crates/*"]
[workspace.dependencies]
core = { path = "crates/core" }
"""


def crate(name, deps="", dev="", features=""):
    return (f'[package]\nname = "{name}"\n[dependencies]\n{deps}\n[dev-dependencies]\n{dev}\n'
            f"[features]\n{features}\n")


FILES = {
    "cmux-tui/Cargo.toml": WORKSPACE_TOML,
    "cmux-tui/Cargo.lock": "",
    "cmux-tui/README.md": "",
    "cmux-tui/scripts/tool.sh": "",
    "cmux-tui/crates/core/Cargo.toml": crate("core"),
    "cmux-tui/crates/core/src/lib.rs": 'const S: &str = include_str!("../../../../schemas/core.json");\n',
    "cmux-tui/crates/core/tests/fixture_test.rs": 'const F: &str = "../../../../webviews/fixtures";\n',
    "cmux-tui/crates/app/Cargo.toml": crate("app", 'core = { workspace = true }\nsim = { path = "../sim", optional = true }',
                                            'helper = { path = "../helper" }', 'sim = ["dep:sim"]'),
    "cmux-tui/crates/app/src/lib.rs": 'pub fn f() { let _ = "../../../../fixtures/app"; }\n',
    "cmux-tui/crates/sim/Cargo.toml": crate("sim"),
    "cmux-tui/crates/sim/src/lib.rs": "",
    "cmux-tui/crates/helper/Cargo.toml": crate("helper", 'leaf = { path = "../leaf" }'),
    "cmux-tui/crates/helper/src/lib.rs": "",
    "cmux-tui/crates/leaf/Cargo.toml": crate("leaf"),
    "cmux-tui/crates/leaf/src/lib.rs": "",
    "cmux-tui/crates/lonely/Cargo.toml": crate("lonely"),
    "cmux-tui/crates/lonely/src/lib.rs": "",
    "schemas/core.json": "{}",
    "webviews/fixtures/a.json": "{}",
    "fixtures/app/x.json": "{}",
    "scripts/run-app.sh": "",
}
MAP = json.dumps({
    "workspace_inputs": ["cmux-tui/Cargo.toml", "cmux-tui/Cargo.lock"],
    "workflows": {
        ".github/workflows/w.yml": {
            "inputs": [".github/workflows/w.yml"],
            "jobs": {
                "app-tests": {"crates": ["cmux-tui/crates/app"], "inputs": ["scripts/run-app.sh"]},
                "app-sim": {"crates": ["cmux-tui/crates/app"], "features": ["sim"]},
                "core-check": {"crates": ["cmux-tui/crates/core"], "compile_only": True},
            },
        }
    },
})


def route(changed, **kwargs):
    with fake_tree(FILES) as tree:
        result = jobs.route(tree, changed, map_text=MAP, **kwargs)
    return {key[1]: run for key, run in result.run.items()}, result


class Routes(unittest.TestCase):
    def test_a_crate_runs_the_jobs_that_build_it_and_no_other(self):
        run, _ = route(["cmux-tui/crates/core/src/lib.rs"])
        self.assertEqual(run, {"app-tests": True, "app-sim": True, "core-check": True})
        run, _ = route(["cmux-tui/crates/lonely/src/lib.rs", "webviews/src/app.tsx", "README.md"])
        self.assertEqual(run, {"app-tests": False, "app-sim": False, "core-check": False})

    def test_an_optional_dependency_counts_only_when_a_feature_turns_it_on(self):
        run, _ = route(["cmux-tui/crates/sim/src/lib.rs"])
        self.assertEqual(run, {"app-tests": False, "app-sim": True, "core-check": False})

    def test_a_dev_dependency_counts_for_the_tested_crate_only(self):
        run, _ = route(["cmux-tui/crates/helper/src/lib.rs"])
        self.assertTrue(run["app-tests"])  # app's own dev-dependency
        run, _ = route(["cmux-tui/crates/leaf/src/lib.rs"])
        self.assertTrue(run["app-tests"])  # a normal dependency of that dev-dependency

    def test_a_dependencys_own_tests_are_not_an_input(self):
        run, _ = route(["cmux-tui/crates/core/tests/fixture_test.rs"])
        self.assertEqual(run, {"app-tests": False, "app-sim": False, "core-check": True})

    def test_files_the_sources_name_outside_the_crate_are_inputs(self):
        run, _ = route(["schemas/core.json"])  # include_str! of a dependency: every job building it
        self.assertEqual(run, {"app-tests": True, "app-sim": True, "core-check": True})
        run, _ = route(["fixtures/app/x.json"])  # a fixture of the tested crate, read at run time
        self.assertEqual(run, {"app-tests": True, "app-sim": True, "core-check": False})
        run, _ = route(["webviews/fixtures/a.json"])  # a test fixture of core: only core's own tests read it
        self.assertEqual(run, {"app-tests": False, "app-sim": False, "core-check": False})

    def test_a_concat_include_names_its_file_even_for_a_compile_only_job(self):
        # cmux#45420 review P3-F1: include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../spec/x.json")) is read at
        # compile time, so a compile-only job (no "../" literal scan) must count it; a macro-built name counts the
        # directory its first literal opens.
        files = {**FILES, "cmux-tui/crates/core/src/spec.rs":
                 'const A: &str = include_str!(concat!(\n    env!("CARGO_MANIFEST_DIR"),\n'
                 '    "/../../../spec/ops.json"\n));\n'
                 'macro_rules! m { ($d:expr) => { include_str!(concat!("../../../../ifaces/", $d, "/1.json")) } }\n'
                 'const O: &str = include_str!(concat!(env!("OUT_DIR"), "/gen.ts"));\n',
                 "spec/ops.json": "{}", "ifaces/a/1.json": "{}", "ifaces/b/1.json": "{}"}
        with fake_tree(files) as tree:
            for changed in (["spec/ops.json"], ["ifaces/b/1.json"]):
                with self.subTest(changed=changed):
                    result = jobs.route(tree, changed, map_text=MAP)
                    run = {key[1]: value for key, value in result.run.items()}
                    self.assertEqual(run, {"app-tests": True, "app-sim": True, "core-check": True}, result.lines())

    def test_a_build_scripts_paths_and_path_modules_are_inputs_of_every_job_building_them(self):
        # cmux#45420 review at bce48e967ff6: cmux-cloud-client's build.rs compiles a file outside cmux-tui through
        # #[path = "../..."] and reruns on a "../" literal; a compile-only job and a dependent's job must count both.
        files = {**FILES,
                 "cmux-tui/crates/core/build.rs": '#[path = "../../../codegen/normalize.rs"]\nmod normalize;\n'
                                                 'const RERUN: &str = "../../../codegen/schema.json";\n',
                 "cmux-tui/crates/core/src/gen.rs": 'include!("../../../../codegen/table.rs");\n',
                 "codegen/normalize.rs": "", "codegen/schema.json": "{}", "codegen/table.rs": ""}
        with fake_tree(files) as tree:
            for path in ("codegen/normalize.rs", "codegen/schema.json", "codegen/table.rs"):
                with self.subTest(path=path):
                    result = jobs.route(tree, [path], map_text=MAP)
                    run = {key[1]: value for key, value in result.run.items()}
                    self.assertEqual(run, {"app-tests": True, "app-sim": True, "core-check": True}, result.lines())

    def test_a_jobs_own_inputs_and_the_workspace_inputs_run_it(self):
        self.assertEqual(route(["scripts/run-app.sh"])[0], {"app-tests": True, "app-sim": False, "core-check": False})
        self.assertTrue(all(route(["cmux-tui/Cargo.lock"])[0].values()))
        self.assertTrue(all(route([".github/workflows/w.yml"])[0].values()))

    def test_everything_runs_on_a_push_the_label_a_router_change_or_an_unknown_path(self):
        for kwargs, changed in (({"event": "push"}, []), ({"labels": ["full-ci"]}, []), ({}, None),
                                ({}, ["scripts/ci/affected_jobs.py"]), ({}, ["scripts/ci/affected-jobs.json"]),
                                ({}, ["cmux-tui/scripts/tool.sh"])):
            with self.subTest(kwargs=kwargs, changed=changed):
                run, result = route(changed, **kwargs)
                self.assertTrue(all(run.values()), result.lines())
                self.assertTrue(result.everything)

    def test_a_markdown_file_no_crate_names_runs_nothing(self):
        self.assertFalse(any(route(["cmux-tui/README.md", "cmux-tui/docs/x.md"])[0].values()))

    def test_a_file_of_a_deleted_package_is_placed_by_the_base(self):
        base = fake_tree({**FILES, "cmux-tui/crates/gone/Cargo.toml": crate("gone"),
                          "cmux-tui/crates/gone/src/lib.rs": ""})
        with base:
            run, result = route(["cmux-tui/crates/gone/src/lib.rs"], base_tree=base)
        self.assertFalse(any(run.values()), result.lines())
        run, result = route(["cmux-tui/crates/gone/src/lib.rs"])
        self.assertTrue(all(run.values()), result.lines())  # no base to place it: unknown

    def test_deleting_a_fixture_a_test_still_names_runs_the_job(self):
        # fixtures/app/x.json is read at run time through a "../" literal, which counts only while the path exists:
        # the head's graph alone does not see a change that deletes it.
        head = {path: text for path, text in FILES.items() if path != "fixtures/app/x.json"}
        with fake_tree(FILES) as base, fake_tree(head) as tree:
            result = jobs.route(tree, ["fixtures/app/x.json"], map_text=MAP, base_tree=base)
        run = {key[1]: value for key, value in result.run.items()}
        self.assertEqual(run, {"app-tests": True, "app-sim": True, "core-check": False}, result.lines())

    def test_an_unreadable_graph_runs_everything(self):
        broken = {**FILES, "cmux-tui/crates/app/Cargo.toml": "[package\n"}
        with fake_tree(broken) as tree:
            result = jobs.route(tree, ["cmux-tui/crates/lonely/src/lib.rs"], map_text=MAP)
        self.assertTrue(all(result.run.values()))
        self.assertIn("could not be read", result.everything)

    def test_the_root_package_is_its_targets_not_the_workspace(self):
        files = {**FILES, "cmux-tui/Cargo.toml": '[package]\nname = "watch"\nbuild = "build-support/b.rs"\n'
                                                 '[lib]\npath = "build-support/lib.rs"\n' + WORKSPACE_TOML,
                 "cmux-tui/build-support/b.rs": "", "cmux-tui/build-support/lib.rs": "",
                 "cmux-tui/crates/leaf/Cargo.toml": crate("leaf", 'watch = { path = "../.." }')}
        with fake_tree(files) as tree:
            inputs = verdict.tested_crate_inputs(tree, "cmux-tui/crates/leaf")
        self.assertIn("cmux-tui/build-support", inputs)
        self.assertNotIn("cmux-tui", inputs)

    def test_an_input_inside_a_submodule_is_the_submodule(self):
        files = {**FILES, "cmux-tui/crates/core/src/lib.rs": 'const S: &str = include_str!("../../../../ghostty/src/a.sh");\n'}
        with fake_tree(files, submodules=("ghostty",)) as tree:
            _, all_jobs = jobs.load_map(MAP)
            graph = jobs.Graph(tree, [], all_jobs)
            self.assertIn("ghostty", graph.inputs(all_jobs[0]))

    def test_github_outputs_are_the_job_ids_with_underscores(self):
        self.assertEqual(jobs.output_key("acpmux-protocol-ir"), "acpmux_protocol_ir")


def built_crates(tree, root: str) -> set[str]:
    """The crate directories `cargo test -p ROOT` (default features) builds: normal and build dependencies of every
    crate, dev-dependencies of ROOT only, an optional one only when the depending crate's defaults turn it on.
    Walked here, not through tested_crate_inputs, so the test does not check the router against itself."""
    import tomllib
    shared = tomllib.loads(tree.text(f"{verdict.WORKSPACE}/Cargo.toml")).get("workspace", {}).get("dependencies", {})
    seen, queue = set(), [root]
    while queue:
        crate = queue.pop()
        if crate in seen or not tree.is_file(f"{crate}/Cargo.toml"):
            continue
        seen.add(crate)
        manifest = tomllib.loads(tree.text(f"{crate}/Cargo.toml"))
        on = verdict._default_optional(manifest)
        kinds = [k for k in verdict.DEPENDENCY_TABLES if crate == root or k != "dev-dependencies"]
        tables = [manifest.get(k, {}) for k in kinds]
        tables += [target.get(k, {}) for target in manifest.get("target", {}).values() for k in kinds]
        for table in tables:
            for name, spec in table.items():
                if not isinstance(spec, dict) or (spec.get("optional") and name not in on):
                    continue
                if "path" in spec:
                    queue.append(posixpath.normpath(posixpath.join(crate, spec["path"])))
                elif spec.get("workspace") and isinstance(shared.get(name), dict) and "path" in shared[name]:
                    queue.append(posixpath.normpath(posixpath.join(verdict.WORKSPACE, shared[name]["path"])))
    return seen


def built_source(source: str, built: set[str], root: str) -> bool:
    """SOURCE is compiled by `cargo test -p ROOT`: in a built crate, and outside tests/, benches/, examples/ unless
    it is ROOT's."""
    owners = [crate for crate in built if crate != verdict.WORKSPACE and source.startswith(crate + "/")]
    if not owners:
        return False
    crate = max(owners, key=len)
    return crate == root or source[len(crate) + 1:].split("/", 1)[0] not in verdict.UNBUILT_TARGET_DIRS


SKIP_IF = jobs.PR_SKIP_IF
SKIP_WORKFLOW = f"""name: s
on:
  pull_request:
    branches: [feat-cmux-next]
  push:
    branches: [feat-cmux-next]
jobs:
  heavy:
    if: ${{{{ !cancelled() && {SKIP_IF} }}}}
    runs-on: x
  after:
    needs: [heavy]
    if: ${{{{ !cancelled() }}}}
    runs-on: x
"""


class PullRequestSkip(unittest.TestCase):
    """Tier A of the merged pull request replay: a job that caught nothing of its own skips on a pull request, and the
    feat-cmux-next push runs it."""

    def check(self, workflow_text: str, skipped=((".github/workflows/s.yml", "heavy"),)) -> list[str]:
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".github/workflows").mkdir(parents=True)
            (root / ".github/workflows/s.yml").write_text(workflow_text)
            return jobs.check_pr_skip(root, list(skipped))

    def test_a_pull_request_skips_it_and_a_push_or_the_label_runs_it(self):
        skip = {"workflows": {".github/workflows/s.yml": {"heavy": "x"}}}
        text = json.dumps({**json.loads(MAP), "pull_request_skip": skip})
        key = (".github/workflows/s.yml", "heavy")
        for kwargs, runs in (({}, False), ({"event": "push"}, True), ({"labels": ["full-ci"]}, True),
                             ({"labels": ["other"]}, False)):
            with self.subTest(kwargs=kwargs), fake_tree(FILES) as tree:
                result = jobs.route(tree, ["scripts/run-app.sh"], map_text=text, **kwargs)
                self.assertEqual(result.pr_skip, {key: runs}, result.lines())
                self.assertTrue(any(line.startswith(".github/workflows/s.yml heavy=") for line in result.lines()))
        with fake_tree(FILES) as tree:  # a router change runs every routed job, never a skipped one
            result = jobs.route(tree, ["scripts/ci/affected_jobs.py"], map_text=text)
            self.assertEqual(result.pr_skip, {key: False})
            result = jobs.route(tree, [], map_text=text, workflow=".github/workflows/s.yml")
            self.assertEqual((result.run, result.pr_skip), ({}, {key: False}))

    def test_a_wired_job_with_a_push_net_passes(self):
        self.assertEqual(self.check(SKIP_WORKFLOW), [])
        self.assertEqual(self.check(SKIP_WORKFLOW.replace("    branches: [feat-cmux-next]\njobs", "jobs")), [])

    def test_an_if_without_the_guard_is_named(self):
        problems = self.check(SKIP_WORKFLOW.replace(f" && {SKIP_IF}", ""))
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("does not carry", problems[0])

    def test_no_push_net_is_named(self):
        for text in (SKIP_WORKFLOW.replace("  push:\n    branches: [feat-cmux-next]\n", ""),
                     SKIP_WORKFLOW.replace("  push:\n    branches: [feat-cmux-next]", "  push:\n    branches: [main]")):
            with self.subTest(text=text):
                problems = self.check(text)
                self.assertEqual(len(problems), 1, problems)
                self.assertIn("no push to feat-cmux-next", problems[0])

    def test_a_push_that_starts_on_fewer_paths_is_named(self):
        text = SKIP_WORKFLOW.replace("    branches: [feat-cmux-next]\n  push:\n    branches: [feat-cmux-next]\n",
                                     "    branches: [feat-cmux-next]\n    paths:\n      - a/**\n      - b/**\n"
                                     "  push:\n    branches: [feat-cmux-next]\n    paths:\n      - a/**\n")
        problems = self.check(text)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("fewer paths", problems[0])
        self.assertEqual(self.check(text.replace("      - a/**\njobs", "      - a/**\n      - b/**\njobs")), [])
        # A job the crate graph routes too: `check` holds the push paths to its inputs, not to the pull_request paths.
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / ".github/workflows").mkdir(parents=True)
            (Path(tmp) / ".github/workflows/s.yml").write_text(text)
            key = (".github/workflows/s.yml", "heavy")
            self.assertEqual(jobs.check_pr_skip(Path(tmp), [key], {key}), [])

    def test_a_job_that_runs_only_on_the_push_paths_needs_no_wider_push(self):
        # cmux-tui-spec.yml's shape: every pull request starts it, and its `changes` job runs a job only when the
        # change touches the push trigger's paths, so the push covers every change the job runs on.
        text = SKIP_WORKFLOW.replace("  push:\n    branches: [feat-cmux-next]\n",
                                     "  push:\n    branches: [feat-cmux-next]\n    paths:\n      - a/**\n")
        self.assertIn("fewer paths", "".join(self.check(text)))
        routed = text.replace(
            "jobs:\n  heavy:\n    if: ${{ !cancelled() && ",
            "jobs:\n  changes:\n    runs-on: x\n    steps:\n      - run: python3 .github/scripts/cmux-tui-spec-changed.py"
            " --workflow s.yml\n  heavy:\n    needs: changes\n"
            "    if: ${{ !cancelled() && needs.changes.outputs.run == 'true' && ")
        self.assertEqual(self.check(routed), [])
        self.assertIn("fewer paths", "".join(self.check(routed.replace("cmux-tui-spec-changed.py", "other.py"))))

    def test_a_job_that_needs_it_and_would_skip_with_it_is_named(self):
        text = SKIP_WORKFLOW.replace("    needs: [heavy]\n    if: ${{ !cancelled() }}\n", "    needs: heavy\n")
        problems = self.check(text)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("job after needs heavy", problems[0])
        listed = SKIP_WORKFLOW.replace("    needs: [heavy]\n    if: ${{ !cancelled() }}\n",
                                       "    needs:\n      - other\n      - heavy\n    if: success()\n")
        self.assertEqual(len(self.check(listed)), 1)
        self.assertEqual(self.check(text, skipped=((".github/workflows/s.yml", "heavy"),
                                                   (".github/workflows/s.yml", "after"))),
                         [".github/workflows/s.yml: job after's `if:` does not carry " + SKIP_IF
                          + ", so a pull request still runs it (scripts/ci/affected-jobs.json pull_request_skip)"])

    def test_a_job_that_never_runs_on_a_pull_request_may_need_it(self):
        folded = SKIP_WORKFLOW.replace("    needs: [heavy]\n    if: ${{ !cancelled() }}\n",
                                       "    needs: heavy\n    if: >-\n      github.event_name != 'pull_request'\n"
                                       "      && github.ref == 'refs/heads/main'\n")
        self.assertEqual(self.check(folded), [])
        self.assertEqual(jobs.job_if("    if: >-\n      a\n      && b\n    runs-on: x\n"), "a && b")

    def test_the_lane_reader_counts_the_push_as_its_lane(self):
        # tests/test_pr_lane_coverage.py reads which jobs a pull request runs; a listed job's lane is the push.
        try:
            import pr_test_lanes  # noqa: PLC0415 - needs PyYAML
        except ImportError:
            self.skipTest("PyYAML")
        self.assertEqual(pr_test_lanes.PR_SKIP_IF, jobs.PR_SKIP_IF)
        context = pr_test_lanes.event_context("feat-cmux-next")
        self.assertIs(pr_test_lanes.evaluate("${{ !cancelled() && " + SKIP_IF + " }}", context), True)
        self.assertIs(pr_test_lanes.evaluate("${{ github.event_name != 'pull_request' }}", context), False)

    def test_every_listed_job_is_named_in_the_map_with_its_replay(self):
        data = json.loads((ROOT / jobs.MAP).read_text())
        for workflow, entry in data.get("pull_request_skip", {}).get("workflows", {}).items():
            for job_id, why in entry.items():
                with self.subTest(job=f"{workflow} {job_id}"):
                    self.assertRegex(why, r"\d+ runs? on \d+ merged pull requests")


class TheRepository(unittest.TestCase):
    """The routed workflows, as they are in this commit."""

    def test_every_routed_job_is_wired_and_its_trigger_holds_its_inputs(self):
        with git_tree.GitTree(ROOT) as tree:
            problems = jobs.check(ROOT, tree)
        self.assertEqual(problems, [], "\n".join(problems))

    def test_the_acpmux_job_inputs_hold_what_the_old_scope_step_held(self):
        # The job routes by tested_crate_inputs now. The old crate_inputs walked every crate's dev-dependencies;
        # cargo builds only the tested crate's (cmux-wg's dev-dependency cmux-rd-core never builds for acpmux's
        # tests). So every crate directory and named file the old walk held is still an input, unless only a crate
        # `cargo test -p acpmux` never builds reaches it (built_crates, walked here apart from the router's code).
        root = "cmux-tui/crates/acpmux"
        _, all_jobs = jobs.load_map((ROOT / jobs.MAP).read_text())
        job = next(j for j in all_jobs if j.id == "acpmux-tests")
        with git_tree.GitTree(ROOT) as tree:
            inputs = jobs.Graph(tree, [], all_jobs).inputs(job)
            dirs, files = verdict.crate_inputs(ROOT, root, tree)
            built = built_crates(tree, root)
            sources = {source: tree.text(source, errors="replace") for source in tree.files(verdict.WORKSPACE, ".rs")}
            namers = {path: [source for source, text in sources.items() if posixpath.basename(path) in text]
                      for path in files}
        for path in [*dirs, *files]:
            if path == verdict.WORKSPACE or posixpath.basename(posixpath.dirname(path)) in verdict.UNBUILT_TARGET_DIRS:
                continue
            if path in dirs and path not in built:
                continue  # reached only through a crate cargo does not build for these tests
            if path in namers and not any(built_source(source, built, root) for source in namers[path]):
                continue  # named only by sources cargo does not build for these tests
            with self.subTest(path=path):
                self.assertTrue(any(jobs.under(path, entry) or jobs.under(entry, path) for entry in inputs), path)

    def test_deleting_an_acpmux_runtime_fixture_runs_the_acpmux_tests(self):
        # The reproduced false skip on #45420: a pull request that deletes a file acpmux's tests read at run time
        # routed acpmux-tests=false, because the head's graph no longer holds the deleted path. Each file input of
        # the job outside cmux-tui (one per top-level directory), deleted in a head tree, must still run the job.
        _, all_jobs = jobs.load_map((ROOT / jobs.MAP).read_text())
        job = next(j for j in all_jobs if j.id == "acpmux-tests")
        with git_tree.GitTree(ROOT) as base:
            entries = base.entries()
            outside = sorted(path for path in jobs.Graph(base, [], all_jobs).inputs(job)
                             if not path.startswith(f"{verdict.WORKSPACE}/") and path in entries
                             and entries[path][0] in git_tree.REGULAR)
            sample = list({path.split("/", 1)[0]: path for path in reversed(outside)}.values())
            self.assertTrue(sample, "acpmux-tests has no file input outside cmux-tui to delete")
            blobs: dict[str, bytes] = {}

            def read_blob(path: str, oid: str) -> bytes:
                # Each head tree reads its blobs through the base's (one cat-file process, one missing() scan, each
                # blob once), not a GitTree of its own per sample: that made this test 168 s of the file's 180.
                if oid not in blobs:
                    blobs[oid] = base._blob(path, oid)
                return blobs[oid]

            for path in sample:
                head_entries = {p: e for p, e in entries.items() if p != path}
                with self.subTest(path=path), git_tree.GitTree(ROOT, base.ref, entries=head_entries,
                                                                read_blob=read_blob) as head:
                    result = jobs.route(head, [path], map_text=(ROOT / jobs.MAP).read_text(), base_tree=base)
                    run = {key[1]: value for key, value in result.run.items()}
                    self.assertTrue(run["acpmux-tests"], result.lines())

    def test_the_workflow_paths_reader(self):
        text = 'on:\n  push:\n    paths:\n      - "a/**"\n      # c\n      - b.txt\n  pull_request:\njobs:\n  x:\n'
        self.assertEqual(jobs.workflow_paths(text, "push"), ["a/**", "b.txt"])
        self.assertIsNone(jobs.workflow_paths(text, "pull_request"))


if __name__ == "__main__":
    unittest.main()
