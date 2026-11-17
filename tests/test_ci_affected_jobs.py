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


class TheRepository(unittest.TestCase):
    """The routed workflows, as they are in this commit."""

    def test_every_routed_job_is_wired_and_its_trigger_holds_its_inputs(self):
        with git_tree.GitTree(ROOT) as tree:
            problems = jobs.check(ROOT, tree)
        self.assertEqual(problems, [], "\n".join(problems))

    def test_the_acpmux_job_inputs_hold_what_the_old_scope_step_held(self):
        # The job routes by tested_crate_inputs now; every crate directory the old crate_inputs walked (minus the
        # workspace root, read as its targets) is still an input of the acpmux tests job.
        _, all_jobs = jobs.load_map((ROOT / jobs.MAP).read_text())
        job = next(j for j in all_jobs if j.id == "acpmux-tests")
        with git_tree.GitTree(ROOT) as tree:
            inputs = jobs.Graph(tree, [], all_jobs).inputs(job)
            dirs, files = verdict.crate_inputs(ROOT, "cmux-tui/crates/acpmux", tree)
        for path in [*dirs, *files]:
            if path == verdict.WORKSPACE or posixpath.basename(posixpath.dirname(path)) in verdict.UNBUILT_TARGET_DIRS:
                continue
            with self.subTest(path=path):
                self.assertTrue(any(jobs.under(path, entry) or jobs.under(entry, path) for entry in inputs), path)

    def test_the_workflow_paths_reader(self):
        text = 'on:\n  push:\n    paths:\n      - "a/**"\n      # c\n      - b.txt\n  pull_request:\njobs:\n  x:\n'
        self.assertEqual(jobs.workflow_paths(text, "push"), ["a/**", "b.txt"])
        self.assertIsNone(jobs.workflow_paths(text, "pull_request"))


if __name__ == "__main__":
    unittest.main()
