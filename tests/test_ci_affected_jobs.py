"""scripts/ci/affected_jobs.py: pull-request jobs route by the cmux-tui crate graph, never skip an input, and run
everything on a push, the full-ci label, a router change or a path the graph cannot place."""
import importlib.util
import json
import posixpath
import re
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

    def test_the_label_on_a_tooling_only_change_routes_by_inputs(self):
        """ci-min-per-pr-140: full-ci on a change to CI and tooling files only (scripts/ci/tooling_only.py) runs just
        the jobs whose inputs it touches; one path outside those folders, or an unlistable change, runs every job."""
        run, result = route(["scripts/ci/x.py", "tests/test_x.py", ".github/workflows/other.yml", "docs/a.md",
                             "README.md"], labels=["full-ci"])
        self.assertFalse(any(run.values()), result.lines())
        self.assertFalse(result.everything)
        self.assertEqual(route(["scripts/run-app.sh", "tests/test_x.py"], labels=["full-ci"])[0],
                         {"app-tests": True, "app-sim": False, "core-check": False})
        self.assertTrue(all(route([".github/workflows/w.yml"], labels=["full-ci"])[0].values()))
        self.assertTrue(all(route(["scripts/ci/affected_jobs.py"], labels=["full-ci"])[0].values()))
        for changed in (["scripts/ci/x.py", "webviews/src/App.tsx"], [], None):
            with self.subTest(changed=changed):
                run, result = route(changed, labels=["full-ci"])
                self.assertTrue(all(run.values()), result.lines())

    def test_full_ci_following_the_graph_runs_only_the_jobs_the_change_affects(self):
        """--full-ci-follows-graph (cmux-tui-spec.yml): a full-ci head that touches no input of a job skips it, one
        that touches an input runs it, and every fail-open case still runs every job."""
        follows = {"labels": ["full-ci"], "full_ci_follows_graph": True}
        run, result = route(["webviews/src/app.tsx"], **follows)
        self.assertFalse(any(run.values()), result.lines())
        self.assertFalse(result.everything)
        run, _ = route(["scripts/run-app.sh"], **follows)
        self.assertEqual(run, {"app-tests": True, "app-sim": False, "core-check": False})
        for changed in (None, ["scripts/ci/affected_jobs.py"], ["cmux-tui/scripts/tool.sh"]):
            with self.subTest(changed=changed):
                run, result = route(changed, **follows)
                self.assertTrue(all(run.values()), result.lines())
        run, _ = route(["webviews/src/app.tsx"], event="push", full_ci_follows_graph=True)
        self.assertTrue(all(run.values()))
        run, _ = route(["webviews/src/app.tsx"], labels=["full-ci"])  # without the flag: every job, as before
        self.assertTrue(all(run.values()))

    def test_full_ci_following_the_graph_still_lifts_the_pull_request_skip(self):
        skip = {"workflows": {".github/workflows/s.yml": {"heavy": "x"}}}
        text = json.dumps({**json.loads(MAP), "pull_request_skip": skip})
        with fake_tree(FILES) as tree:
            result = jobs.route(tree, ["scripts/run-app.sh"], map_text=text, labels=["full-ci"],
                                full_ci_follows_graph=True)
        self.assertEqual(result.pr_skip, {(".github/workflows/s.yml", "heavy"): True})

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

    def test_check_reports_an_unreadable_graph_and_still_checks_the_other_jobs(self):
        # #53846: a base whose Cargo.toml did not parse crashed the whole check, which hid the PR's own missing path.
        import tempfile
        broken = {**FILES, "cmux-tui/crates/app/Cargo.toml": "[package\n"}
        with tempfile.TemporaryDirectory() as tmp, fake_tree(broken) as tree:
            root = Path(tmp)
            (root / jobs.MAP).parent.mkdir(parents=True, exist_ok=True)
            (root / jobs.MAP).write_text(MAP)
            (root / ".github/workflows").mkdir(parents=True, exist_ok=True)
            (root / ".github/workflows/w.yml").write_text("on:\n  pull_request:\n    paths:\n      - cmux-tui/**\njobs:\n")
            problems = jobs.check(root, tree)
        text = "\n".join(problems)
        self.assertIn("cmux-tui/crates/app/Cargo.toml does not parse", text)
        self.assertIn('the pull_request paths miss "schemas/core.json"', text)

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


def content_tree(files: dict[str, str]) -> "git_tree.GitTree":
    """fake_tree, with each directory's object id a hash of what is under it, as git's tree ids are."""
    import hashlib
    entries = fake_tree(files).entries()
    blobs = {}
    for path, text in files.items():  # a blob's id is its content, so equal files are equal anywhere
        oid = hashlib.sha1(text.encode()).hexdigest()
        blobs[oid] = text.encode()
        entries[path] = ("100644", oid)
    for path in sorted((p for p, (mode, _) in entries.items() if mode == git_tree.DIRECTORY),
                       key=lambda p: p.count("/"), reverse=True):  # the deepest first: a parent hashes its children
        under = sorted(f"{p}={o}" for p, (_, o) in entries.items() if p.startswith(path + "/") and p.count("/") ==
                       path.count("/") + 1)
        entries[path] = (git_tree.DIRECTORY, hashlib.sha1("\n".join(under).encode()).hexdigest())
    return git_tree.GitTree(ROOT, "fake", entries=entries, read_blob=lambda _path, oid: blobs[oid])


def keys(files: dict[str, str]) -> dict[str, str]:
    files = {**files}
    for p in jobs.SELF:
        files.setdefault(p, "")
    with content_tree(files) as tree:
        return {job: key for (_, job), key in jobs.result_keys(tree, map_text=MAP).items()}


class ResultKeys(unittest.TestCase):
    """The input-tree key a green result is reused by (tree_result.py): equal inputs give an equal key, and a change to
    any input, the workflow or the router gives a new one."""

    def setUp(self):
        self.files = {**FILES, ".github/workflows/w.yml": "jobs: {}\n"}
        self.before = keys(self.files)

    def changed(self, path, text="changed\n"):
        return keys({**self.files, path: text})

    def test_a_change_outside_a_jobs_inputs_keeps_its_key(self):
        after = self.changed("cmux-tui/crates/lonely/src/lib.rs")
        self.assertEqual(after, self.before)
        after = self.changed("README.md")
        self.assertEqual(after, self.before)

    def test_a_change_to_an_input_gives_the_jobs_that_read_it_a_new_key(self):
        after = self.changed("cmux-tui/crates/sim/src/lib.rs")  # only app-sim turns sim on
        self.assertNotEqual(after["app-sim"], self.before["app-sim"])
        self.assertEqual(after["app-tests"], self.before["app-tests"])
        self.assertEqual(after["core-check"], self.before["core-check"])
        after = self.changed("schemas/core.json")  # an include_str! of core: every job builds core
        self.assertTrue(all(after[j] != self.before[j] for j in self.before))
        after = self.changed("scripts/run-app.sh")  # a job's own input
        self.assertEqual([j for j in after if after[j] != self.before[j]], ["app-tests"])

    def test_the_workflow_the_router_and_the_lockfile_are_in_every_key(self):
        for path in (".github/workflows/w.yml", jobs.SELF[0], "cmux-tui/Cargo.lock"):
            after = self.changed(path, "other\n")
            self.assertTrue(all(after[j] != self.before[j] for j in self.before), path)

    def test_jobs_with_the_same_inputs_still_have_their_own_keys(self):
        self.assertEqual(len(set(self.before.values())), 3)

    def test_a_reusing_job_gates_every_step_after_the_lookup(self):
        job = jobs.Job(".github/workflows/w.yml", "app-tests", "app tests", [], [], [])
        good = ("    steps:\n"
                "      - uses: actions/checkout@x\n"
                "      - name: Reuse\n        id: tree\n        uses: ./.github/actions/tree-result\n"
                "        with:\n          mode: restore\n          job: app-tests\n"
                "          key: ${{ needs.changes.outputs.app_tests_tree }}\n"
                "      - name: Test\n        if: ${{ steps.tree.outputs.hit != 'true' && (always()) }}\n"
                "        run: make test\n"
                "      - name: Record\n        if: ${{ success() && steps.tree.outputs.hit != 'true' }}\n"
                "        uses: ./.github/actions/tree-result\n        with:\n          mode: save\n"
                "          job: app-tests\n          key: ${{ needs.changes.outputs.app_tests_tree }}\n")
        self.assertEqual(jobs.tree_result_problems(job, good), [])
        ungated = good.replace("        if: ${{ steps.tree.outputs.hit != 'true' && (always()) }}\n", "")
        self.assertIn("step `name: Test`", " ".join(jobs.tree_result_problems(job, ungated)))
        other_key = good.replace("outputs.app_tests_tree", "outputs.app_sim_tree")
        self.assertTrue(jobs.tree_result_problems(job, other_key))
        no_save = good.split("      - name: Record")[0]
        self.assertTrue(jobs.tree_result_problems(job, no_save))
        self.assertEqual(jobs.tree_result_problems(job, "    steps:\n      - run: make\n"), [])

    def test_an_unreadable_graph_gives_no_key(self):
        files = {**FILES, "cmux-tui/crates/app/Cargo.toml": "not toml ["}
        self.assertEqual(keys(files), {})


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
                             ({"labels": ["other"]}, False), ({"base_ref": "main"}, True),
                             ({"base_ref": "main", "labels": ["other"]}, True)):
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

    def test_a_gate_that_runs_on_an_empty_output_of_a_skipped_job_is_named(self):
        # cmux-tui-sdks.yml's conformance read contract's sdk_inputs as != 'false'; once contract was Tier A, the
        # empty output of the skipped job ran conformance on every pull request (148 of 154 runs on 11-21).
        after = "    if: ${{ !cancelled() }}\n"
        for gate in ("(github.event_name != 'pull_request' || needs.heavy.outputs.inputs != 'false')",
                     "needs.heavy.result != 'success'"):
            with self.subTest(gate=gate):
                problems = self.check(SKIP_WORKFLOW.replace(after, f"    if: ${{{{ !cancelled() && {gate} }}}}\n"))
                self.assertEqual(len(problems), 1, problems)
                self.assertIn("runs on every pull request", problems[0])
        # Carrying the clause, reading the output as == 'true', or never running on a pull request passes.
        for gate in (f"{SKIP_IF} && needs.heavy.outputs.inputs != 'false'", "needs.heavy.outputs.inputs == 'true'",
                     "github.event_name != 'pull_request' && needs.heavy.outputs.inputs != 'false'"):
            with self.subTest(gate=gate):
                self.assertEqual(self.check(SKIP_WORKFLOW.replace(after, f"    if: ${{{{ !cancelled() && {gate} }}}}\n")), [])

    def test_no_push_net_is_named(self):
        for text in (SKIP_WORKFLOW.replace("  push:\n    branches: [feat-cmux-next]\n", ""),
                     SKIP_WORKFLOW.replace("  push:\n    branches: [feat-cmux-next]", "  push:\n    branches: [main]")):
            with self.subTest(text=text):
                problems = self.check(text)
                self.assertEqual(len(problems), 1, problems)
                self.assertIn("no push to feat-cmux-next", problems[0])

    def test_a_post_merge_batch_suite_is_the_net(self):
        import tempfile
        text = SKIP_WORKFLOW.replace("  push:\n    branches: [feat-cmux-next]\n", "  workflow_call:\n")
        key = (".github/workflows/s.yml", "heavy")
        for paths, count in (([], 0), (["a/**"], 1)):
            with self.subTest(paths=paths), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                (root / ".github/workflows").mkdir(parents=True)
                (root / ".github/workflows/s.yml").write_text(text)
                (root / ".github/post-merge-batch.json").write_text(json.dumps(
                    {"suites": {"s": {"workflow": "s.yml", "paths": paths, "jobs": {"heavy": "heavy"}}}}))
                problems = jobs.check_pr_skip(root, [key])
                self.assertEqual(len(problems), count, problems)

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

    def test_a_pull_request_exclude_or_a_path_under_a_pushed_glob_is_no_gap(self):
        # The docs-only block narrows the pull request (`!a/**/*.md`) and puts a read doc back by name; a push
        # that keeps a/** whole still starts on every path the pull request does.
        text = SKIP_WORKFLOW.replace("    branches: [feat-cmux-next]\n  push:\n    branches: [feat-cmux-next]\n",
                                     "    branches: [feat-cmux-next]\n    paths:\n      - a/**\n"
                                     "      - \"!a/**/*.md\"\n      - a/read.md\n"
                                     "  push:\n    branches: [feat-cmux-next]\n    paths:\n      - a/**\n")
        self.assertEqual(self.check(text), [])
        self.assertEqual(jobs.uncovered_by_push(["a/**", "!a/**/*.md", "a/x/read.md", "b/c.md"], ["a/**"]),
                         {"b/c.md"})
        self.assertEqual(jobs.uncovered_by_push(["ab/x.md"], ["a/**"]), {"ab/x.md"})

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
        # A pull request into main runs every skipped job: no push of main would (SKIP_BASE).
        self.assertIn("!startsWith(github.event.pull_request.base.ref, '" + jobs.SKIP_BASE + "')", jobs.PR_SKIP_IF)
        # A pull request into a branch stacked on feat-cmux-next (feat-cmux-next-ios-infinite-scroll) skips the same
        # jobs: that branch reaches feat-cmux-next through a PR that skips them too, and the feat-cmux-next push runs
        # them (Aziz's App Review gate walked 26-30 min on every push into it, 2026-11-22).
        stacked = pr_test_lanes.event_context("feat-cmux-next-ios-infinite-scroll")
        self.assertIs(pr_test_lanes.evaluate("${{ !cancelled() && " + SKIP_IF + " }}", stacked), True)
        tier = "${{ !startsWith(github.event.pull_request.base.ref, 'feat-cmux-next') }}"
        self.assertIs(pr_test_lanes.evaluate(tier, stacked), False)
        self.assertIs(pr_test_lanes.evaluate(tier, context), False)
        self.assertIs(pr_test_lanes.evaluate(tier, pr_test_lanes.event_context("main")), True)

    def follows(self, gate_line: str, followed: str = ".github/workflows/s.yml heavy") -> list[str]:
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".github/workflows").mkdir(parents=True)
            (root / ".github/workflows/s.yml").write_text(SKIP_WORKFLOW)
            (root / ".github/workflows/fix.yml").write_text(
                "jobs:\n  repair:\n    steps:\n      - env:\n" + gate_line + "        run: true\n")
            skip = {"workflows": {".github/workflows/s.yml": {"heavy": "x"}},
                    "follows": {".github/workflows/fix.yml": {"GATE_HEAVY": followed}}}
            return jobs.check_follows(root, json.dumps({"pull_request_skip": skip}))

    def test_a_gate_set_to_the_skip_clause_passes(self):
        self.assertEqual(self.follows(f"          GATE_HEAVY: ${{{{ {SKIP_IF} }}}}\n"), [])

    def test_a_gate_that_drifted_from_the_skip_clause_is_named(self):
        problems = self.follows(f"          GATE_HEAVY: ${{{{ {SKIP_IF.replace('full-ci', 'dev-build')} }}}}\n")
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("different heads", problems[0])

    def test_a_gate_never_set_or_following_an_unlisted_job_is_named(self):
        self.assertIn("never sets", self.follows("")[0])
        problems = self.follows(f"          GATE_HEAVY: ${{{{ {SKIP_IF} }}}}\n", ".github/workflows/s.yml after")
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("does not list", problems[0])

    def test_every_listed_job_is_named_in_the_map_with_its_replay(self):
        data = json.loads((ROOT / jobs.MAP).read_text())
        for workflow, entry in data.get("pull_request_skip", {}).get("workflows", {}).items():
            for job_id, why in entry.items():
                with self.subTest(job=f"{workflow} {job_id}"):
                    self.assertRegex(why, r"\d+ runs? on \d+ merged pull requests")


BINARIES_MAP = json.dumps({
    "workspace_inputs": ["cmux-tui/Cargo.toml", "cmux-tui/Cargo.lock"],
    "workflows": {
        ".github/workflows/next.yml": {
            "inputs": [],
            "jobs": {
                "daemon-test": {"crates": ["cmux-tui/crates/app"], "compile_only": True, "binaries_only": True,
                                "router_output": "daemon", "binaries_key": "key.txt",
                                "inputs": ["scripts/build.sh"], "key_only": ["fixtures/bench.json"]},
            },
        }
    },
})
KEY = "# comment\ntree cmux-tui\ngitlink ghostty\nblob scripts/build.sh\nblob schemas/core.json\nblob fixtures/bench.json\n"


class BinariesOnly(unittest.TestCase):
    """A job that runs the published binaries (cmux-next.yml's daemon-test, routed by cmux_next_route.py)."""

    def placement(self, files=FILES):
        with fake_tree({**files, "key.txt": KEY}) as tree:
            return jobs.placement("daemon-test", tree, map_text=BINARIES_MAP)

    def test_its_crates_are_their_built_targets_only(self):
        found = self.placement()
        self.assertTrue(any(jobs.under("cmux-tui/crates/app/src/lib.rs", entry) for entry in found.inputs))
        self.assertTrue(any(jobs.under("schemas/core.json", entry) for entry in found.inputs))  # core embeds it
        for path in ("cmux-tui/crates/app/tests/t.rs", "fixtures/app/x.json",  # its own tests and their fixtures
                     "cmux-tui/crates/helper/src/lib.rs", "cmux-tui/crates/sim/src/lib.rs"):  # dev, off feature
            with self.subTest(path=path):
                self.assertFalse(any(jobs.under(path, entry) for entry in found.inputs), found.inputs)

    def test_a_path_in_no_package_is_never_placed(self):
        found = self.placement()
        self.assertTrue(found.unknown("cmux-tui/scripts/tool.sh"))
        self.assertFalse(found.unknown("cmux-tui/crates/lonely/src/lib.rs"))
        self.assertFalse(found.unknown("cmux-tui/README.md"))

    def test_a_key_input_outside_the_graph_must_be_the_jobs(self):
        _, all_jobs = jobs.load_map(BINARIES_MAP)
        job = all_jobs[0]
        with fake_tree({**FILES, "key.txt": KEY}) as tree:
            self.assertEqual(jobs.check_binaries_key(jobs.Graph(tree, [], all_jobs), job), [])
        with fake_tree({**FILES, "key.txt": KEY + "blob scripts/new-recipe.sh\n"}) as tree:
            problems = jobs.check_binaries_key(jobs.Graph(tree, [], all_jobs), job)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("scripts/new-recipe.sh", problems[0])


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

    def test_the_remote_web_wasm_build_runs_only_on_what_it_builds(self):
        """remote-web-wasm builds cmux-remote-web for wasm32 (#54014). It ran on every cmux-tui head: 378 of its 426
        runs in 11-26 15Z..22Z (89% of its minutes) touched nothing it builds. Its crate, a crate it reaches, the
        workspace files and its own inputs run it; another crate, a web change or a doc does not; a path the graph
        cannot place still does, and its `if:` reads the router's output."""
        map_text = (ROOT / jobs.MAP).read_text()
        cases = {
            "cmux-tui/crates/cmux-remote-web/src/lib.rs": True,
            "cmux-tui/crates/cmux-remote-protocol/src/frame.rs": True,
            "cmux-tui/Cargo.lock": True,
            "scripts/ci/apt-ensure.sh": True,
            ".github/workflows/cmux-tui-spec.yml": True,
            "cmux-tui/not-in-any-package.bin": True,
            "cmux-tui/crates/acpmux/src/lib.rs": False,
            "web/app/page.tsx": False,
            "docs/notes.md": False,
        }
        with git_tree.GitTree(ROOT) as tree:
            for path, want in cases.items():
                with self.subTest(path=path):
                    result = jobs.route(tree, [path], map_text=map_text, base_tree=tree)
                    run = {key[1]: value for key, value in result.run.items()}
                    self.assertEqual(run["remote-web-wasm"], want, result.lines())
        block = jobs.job_block((ROOT / ".github/workflows/cmux-tui-spec.yml").read_text(), "remote-web-wasm")
        self.assertIn("needs.changes.result != 'success'", block)  # a failed router runs it
        self.assertIn("needs.changes.outputs.remote_web_wasm != 'false'", block)

    def test_the_daemon_tier_routes_by_the_map(self):
        """cmux_next_route.py's daemon tier reads the map's daemon-test: a crate the fetched binaries build runs it, a
        crate none of them builds, or a binary crate's own tests, does not."""
        spec = importlib.util.spec_from_file_location("cmux_next_route_for_jobs", ROOT / "scripts/ci/cmux_next_route.py")
        router = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = router
        spec.loader.exec_module(router)
        daemon = router.daemon_graph(ROOT)
        self.assertIsNotNone(daemon)
        self.assertTrue(daemon.reason("cmux-tui/crates/cmux-tui/src/main.rs"))
        self.assertTrue(daemon.reason("cmux-tui/Cargo.lock"))
        self.assertTrue(daemon.reason("scripts/cmux-next/pin-cmux-tui.sh"))
        self.assertIsNone(daemon.reason("cmux-tui/crates/cmux-tui/tests/does_not_exist.rs"))
        self.assertIsNone(daemon.reason("cmux-tui/crates/cmux-app-ffi/src/lib.rs"))  # the app links its pinned release
        self.assertEqual(set(router.DAEMON_PATHS) - set(router._daemon_map_inputs(ROOT)), set())

    def test_the_gate_passes_over_only_changes_no_routed_job_reads(self):
        """`gate` lets the changes job skip the graph: every input of each of cmux-tui-spec.yml's routed jobs, a Rust
        source or manifest anywhere, the map and the router need it; a web or Swift change does not, and `route` on
        such a change runs none of the workflow's jobs, so skipping it changes no answer."""
        workflow = ".github/workflows/cmux-tui-spec.yml"
        map_text = (ROOT / jobs.MAP).read_text()
        workspace_inputs, all_jobs = jobs.load_map(map_text)
        with git_tree.GitTree(ROOT) as tree:
            graph = jobs.Graph(tree, workspace_inputs, all_jobs)
            inputs = sorted({entry for job in all_jobs if job.workflow == workflow for entry in graph.inputs(job)})
            for entry in inputs:
                probe = entry.rstrip("/") + "/x" if jobs.is_directory(tree, entry) else entry
                with self.subTest(input=probe):
                    self.assertTrue(jobs.gate(ROOT, [probe], workflow, map_text=map_text)[0], probe)
            for path in ("Native/x/src/lib.rs", "cmux-next-ios/rust/Cargo.toml", jobs.MAP, *jobs.SELF, workflow,
                         ".github/post-merge-batch.json", "scripts/ci/pr_router.json", "cmux-tui/README.md"):
                with self.subTest(path=path):
                    self.assertTrue(jobs.gate(ROOT, [path], workflow, map_text=map_text)[0], path)
            outside = ["webviews/src/App.tsx", "Packages/macOS/CmuxNext/Sources/X/Y.swift", "docs/x.md"]
            self.assertFalse(jobs.gate(ROOT, outside, workflow, map_text=map_text)[0])
            result = jobs.route(tree, outside, map_text=map_text, workflow=workflow)
            self.assertFalse(any(result.run.values()), result.lines())
        self.assertTrue(jobs.gate(ROOT, outside, workflow, event="push", map_text=map_text)[0])
        self.assertTrue(jobs.gate(ROOT, outside, workflow, labels=[jobs.FULL_LABEL], map_text=map_text)[0])
        tooling = ["scripts/ci/x.py", "tests/test_x.py", ".github/workflows/other.yml", "docs/x.md"]
        self.assertFalse(jobs.gate(ROOT, tooling, workflow, labels=[jobs.FULL_LABEL], map_text=map_text)[0])
        self.assertTrue(jobs.gate(ROOT, tooling + [workflow], workflow, labels=[jobs.FULL_LABEL], map_text=map_text)[0])
        self.assertTrue(jobs.gate(ROOT, tooling + ["webviews/x.ts"], workflow, labels=[jobs.FULL_LABEL],
                                  map_text=map_text)[0])
        self.assertTrue(jobs.gate(ROOT, None, workflow, map_text=map_text)[0])
        follows = {"labels": [jobs.FULL_LABEL], "full_ci_follows_graph": True, "map_text": map_text}
        self.assertFalse(jobs.gate(ROOT, outside, workflow, **follows)[0])
        self.assertTrue(jobs.gate(ROOT, None, workflow, **follows)[0])
        self.assertTrue(jobs.gate(ROOT, outside, workflow, event="push", **follows)[0])

    def test_sdks_and_windows_follow_the_graph_under_full_ci_only_when_the_variable_is_on(self):
        """cmux-tui-sdks.yml and cmux-tui-windows-check.yml pass --full-ci-follows-graph only through FOLLOWS_GRAPH,
        set from the CI_LAND_KEEPS_SELECTOR repository variable (default off: the call is today's, every job under
        full-ci)."""
        for name in ("cmux-tui-sdks.yml", "cmux-tui-windows-check.yml"):
            with self.subTest(workflow=name):
                text = (ROOT / ".github/workflows" / name).read_text()
                call = re.search(rf"affected_jobs\.py route --workflow \.github/workflows/{re.escape(name)} "
                                 r"\\\n([^\n]*)", text)
                self.assertIsNotNone(call)
                self.assertTrue(call.group(1).rstrip().endswith('--labels "${LABELS:-[]}" $FOLLOWS_GRAPH'),
                                call.group(1))
                self.assertNotIn("--full-ci-follows-graph", call.group(1))
                self.assertIn("FOLLOWS_GRAPH: ${{ vars.CI_LAND_KEEPS_SELECTOR == '1' && '--full-ci-follows-graph' "
                              "|| '' }}", text)
        # Off, the label still routes every job of the workflow; on, an untouched job skips.
        for workflow in (".github/workflows/cmux-tui-sdks.yml", ".github/workflows/cmux-tui-windows-check.yml"):
            with self.subTest(route=workflow):
                off = jobs.route(None, ["webviews/src/app.tsx"], labels=[jobs.FULL_LABEL], workflow=workflow)
                self.assertTrue(off.everything)
                self.assertTrue(all(off.run.values()))

    def test_cmux_tui_spec_lets_full_ci_follow_the_graph_and_unreadable_labels_run_everything(self):
        """cmux-tui-spec.yml's gate and route pass --full-ci-follows-graph (a full-ci head that touches no input of a
        heavy job skips it: about 33,000 runner-minutes a day, 2026-11-26); labels that do not parse still run every
        job."""
        text = (ROOT / ".github/workflows/cmux-tui-spec.yml").read_text()
        for command in ("gate", "route"):
            with self.subTest(command=command):
                call = re.search(rf"affected_jobs\.py {command} --workflow \.github/workflows/cmux-tui-spec\.yml "
                                 r"\\\n([^\n]*)", text)
                self.assertIsNotNone(call, command)
                self.assertIn("--full-ci-follows-graph", call.group(1))
        import contextlib
        import io
        import os
        import subprocess
        import tempfile
        from unittest import mock
        head = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"], capture_output=True, text=True,
                              check=True).stdout.strip()

        def needed(labels):  # an empty change (HEAD..HEAD) with the full-ci label
            with tempfile.TemporaryDirectory() as tmp:
                out = Path(tmp) / "out"
                with mock.patch.dict(os.environ, {"GITHUB_OUTPUT": str(out)}), \
                        contextlib.redirect_stdout(io.StringIO()):
                    jobs.main(["gate", "--workflow", ".github/workflows/cmux-tui-spec.yml", "--base", head,
                               "--head", head, "--labels", labels, "--full-ci-follows-graph"])
                return "needed=true" in out.read_text()

        self.assertFalse(needed('["full-ci"]'))
        self.assertTrue(needed("not json"))

    def test_fix_writes_a_missing_path_in_the_entry_style(self):
        text = 'on:\n  push:\n    paths:\n      - "a/**"\n      # c\n      - "b.txt"\n  pull_request:\n    paths:\n      - a/**\njobs:\n  x:\n'
        pushed = jobs.add_workflow_paths(text, "push", ["skills/x/SKILL.md"])
        self.assertEqual(jobs.workflow_paths(pushed, "push"), ["a/**", "b.txt", "skills/x/SKILL.md"])
        self.assertIn('      - "skills/x/SKILL.md"\n', pushed)
        pulled = jobs.add_workflow_paths(pushed, "pull_request", ["c.txt"])
        self.assertEqual(jobs.workflow_paths(pulled, "pull_request"), ["a/**", "c.txt"])
        self.assertIn("      - c.txt\n", pulled)
        batch = '{"suites": [{"paths": [\n  "a/**"\n]}, {"paths": [\n  "a/**",\n  "b.txt"\n]}]}'
        added = json.loads(jobs.add_batch_paths(batch, ["a/**", "b.txt"], ["c.txt"]))
        self.assertEqual([suite["paths"] for suite in added["suites"]], [["a/**"], ["a/**", "b.txt", "c.txt"]])

    def test_the_workflow_paths_reader(self):
        text = 'on:\n  push:\n    paths:\n      - "a/**"\n      # c\n      - b.txt\n  pull_request:\njobs:\n  x:\n'
        self.assertEqual(jobs.workflow_paths(text, "push"), ["a/**", "b.txt"])
        self.assertIsNone(jobs.workflow_paths(text, "pull_request"))


class ReplayOwnCrateTests(unittest.TestCase):
    """affected_jobs_replay.py fails a skip of a job whose own crate changed; a binaries_only job (daemon-test runs the
    published binaries) owns its crates' sources, not their tests/, benches/ or examples/ (cmux#50031)."""

    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("affected_jobs_replay", ROOT / "scripts/ci/affected_jobs_replay.py")
        cls.replay = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.replay)

    def job(self, binaries_only: bool):
        return jobs.Job(".github/workflows/x.yml", "j", "j", ["cmux-tui/crates/cmux-tui"], [], [],
                        binaries_only=binaries_only)

    def test_binaries_only_job_does_not_own_its_crates_tests(self):
        changed = ["cmux-tui/crates/cmux-tui/tests/terminal_throughput_stages.rs",
                   "cmux-tui/crates/cmux-tui/benches/b.rs", "cmux-tui/crates/cmux-tui/examples/e.rs"]
        self.assertEqual(self.replay.own_crate_changes(jobs, self.job(True), changed), [])

    def test_binaries_only_job_still_owns_its_sources_and_manifest(self):
        changed = ["cmux-tui/crates/cmux-tui/src/main.rs", "cmux-tui/crates/cmux-tui/Cargo.toml",
                   "cmux-tui/crates/cmux-tui/src/tests/mod.rs"]
        self.assertEqual(self.replay.own_crate_changes(jobs, self.job(True), changed), changed)

    def test_a_test_running_job_owns_its_crates_tests(self):
        changed = ["cmux-tui/crates/cmux-tui/tests/terminal_throughput_stages.rs"]
        self.assertEqual(self.replay.own_crate_changes(jobs, self.job(False), changed), changed)


if __name__ == "__main__":
    unittest.main()
