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
