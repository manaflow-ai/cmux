#!/usr/bin/env python3
"""The shadow input key covers what React Doctor reads, changes when an input changes, and nothing else.

Runs scripts/ci/receipt_input_key.py against a temporary git repository, plus a check that
scripts/ci/receipt-inputs/react-doctor.txt names every gate input and project of react_doctor_gate.py.
"""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "scripts" / "ci"))
import react_doctor_gate as gate  # noqa: E402
import receipt_input_key as rik  # noqa: E402
import receipt_signed as signed  # noqa: E402

sys.path.insert(0, str(HERE))
import git_fixture_env  # noqa: E402

ROWS = [("*", "blob", "gate.py"), ("app", "tree", "app"), ("app", "tree", "shared"), ("site", "tree", "site")]
ENV = git_fixture_env.fixture_env({**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
       "GIT_COMMITTER_EMAIL": "t@t", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"})


class KeyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        self.git("init", "-q")
        for rel, text in {"gate.py": "g", "app/a.tsx": "a", "shared/s.ts": "s", "site/b.tsx": "b", "rust/x.rs": "x"}.items():
            self.write(rel, text)
        self.commit()
        self.old_root, rik.ROOT = rik.ROOT, self.repo

    def tearDown(self):
        rik.ROOT = self.old_root
        self.tmp.cleanup()

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args], text=True, env=ENV).strip()

    def write(self, rel, text):
        path = self.repo / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "c", "--allow-empty")

    def key(self, units):
        return rik.input_key("react-doctor", units, rows=ROWS)[0]

    def test_same_inputs_same_key(self):
        before = self.key(["app"])
        self.write("rust/x.rs", "changed")
        self.write("site/b.tsx", "changed")
        self.commit()
        self.assertEqual(before, self.key(["app"]), "a path the unit does not read must not change its key")

    def test_each_input_changes_the_key(self):
        for rel in ("app/a.tsx", "shared/s.ts", "gate.py"):
            before = self.key(["app"])
            self.write(rel, "changed " + rel)
            self.commit()
            self.assertNotEqual(before, self.key(["app"]), rel)

    def test_an_input_appearing_changes_the_key(self):
        self.git("rm", "-q", "-r", "shared")
        self.commit()
        before = self.key(["app"])
        self.write("shared/s.ts", "s")
        self.commit()
        self.assertNotEqual(before, self.key(["app"]))

    def test_units_are_part_of_the_key(self):
        self.assertNotEqual(self.key(["app"]), self.key(["app", "site"]))
        self.assertEqual(self.key(["site", "app"]), self.key(["app", "site"]))

    def test_unit_without_inputs_is_refused(self):
        with self.assertRaises(ValueError):
            self.key(["unlisted"])

    def test_pinned_files_are_reported(self):
        base = self.git("rev-parse", "HEAD")
        self.write("scripts/ci/check-paths.txt", "# pinned\nscripts/ci/check-*\n")
        self.commit()
        base = self.git("rev-parse", "HEAD")
        self.write("app/a.tsx", "changed")
        self.commit()
        self.assertEqual(rik.pinned_touched("react-doctor", base, rows=ROWS), [], "a project file is not pinned")
        self.write("gate.py", "changed")
        self.write("scripts/ci/check-lint.sh", "x")
        self.write("app2/x.ts", "x")
        self.commit()
        self.assertEqual(sorted(rik.pinned_touched("react-doctor", base, rows=ROWS)),
                         ["gate.py", "scripts/ci/check-lint.sh"])

    def test_record_is_ci_receipt_v1_with_input_key(self):
        rec = rik.record("react-doctor", "k" * 64, "b" * 40, 0)
        for field in ("schema", "check", "repo", "tree", "base", "command_sha256", "exit", "runner", "logs",
                      "finished_at", "sig"):
            self.assertIn(field, rec)
        self.assertEqual(rec["schema"], "ci-receipt/v1")
        self.assertEqual(rec["input_key"], "k" * 64)
        self.assertEqual(rec["tree"], self.git("rev-parse", "HEAD^{tree}"))
        self.assertIsNone(rec["sig"], "shadow records are unsigned")


class InputsListTest(unittest.TestCase):
    def test_react_doctor_inputs_cover_the_gate(self):
        rows = rik.load_inputs("react-doctor")
        always = {rel.rstrip("/") for unit, _, rel in rows if unit == "*"}
        for path in gate.GATE_INPUTS:
            self.assertIn(path.rstrip("/"), always, f"gate input {path} is not in receipt-inputs/react-doctor.txt")
        for project in gate.PROJECTS:
            self.assertIn((project, "tree", project), rows, f"project {project} does not key on its own tree")
        self.assertEqual({u for u, _, _ in rows if u != "*"}, set(gate.PROJECTS), "a listed unit is not a project")


class StepReceiptTest(unittest.TestCase):
    """One receipt per step of static-checks (cmuxterm-hq RFD 0148 row 34), in shadow. A step's key is its own
    traced rows and its own command, and its receipt is recorded as soon as it passes, so a job that times out or
    fails in a later step keeps it."""

    JOB = "static-checks"
    WORKFLOW = HERE.parent / ".github" / "workflows" / "cmux-next-guards.yml"

    @classmethod
    def setUpClass(cls):
        import yaml
        cls.steps = yaml.load(cls.WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)["jobs"][cls.JOB]["steps"]
        cls.ids = [step.get("id", "") for step in cls.steps]
        cls.checks = rik.step_checks(cls.JOB)

    def test_there_are_step_checks(self):
        self.assertEqual(sorted(self.checks), ["defaults-snapshot", "group-menus", "page-strings"])

    def test_the_key_command_is_the_step_the_workflow_runs(self):
        # The workflow file is not a row of a step's list (an edit to another step must not change this step's
        # key), so the command in the key has to be the step's own, held equal here.
        node = next(step["with"]["node-version"] for step in self.steps
                    if str(step.get("uses", "")).startswith("actions/setup-node@"))
        for step_id, check in self.checks.items():
            step = self.steps[self.ids.index(step_id)]
            spec = rik.CHECKS[check]
            self.assertEqual(step["run"].strip(), spec["command"], step_id)
            self.assertEqual(spec.get("node"), node if spec["command"].startswith("node ") else None, step_id)
            self.assertEqual([k for k, v in (step.get("env") or {}).items() if v], [],
                             f"{step_id}: a step env value is an input the key does not cover")

    def test_each_list_is_the_steps_own_rows(self):
        whole = {(kind, rel) for _unit, kind, rel in rik.load_inputs(self.JOB)}
        for step_id, check in self.checks.items():
            rows = rik.load_inputs(check)
            self.assertTrue(rows, check)
            self.assertEqual({unit for unit, _, _ in rows}, {"*"}, f"{check}: a step has no units")
            paths = {rel for _unit, _kind, rel in rows}
            self.assertIn(rik.CHECKS[check]["command"].split()[-1], paths, f"{check}: its own script is not a row")
            self.assertIn(f"scripts/ci/receipt-inputs/{check}.txt", paths, f"{check}: its list is not a row")
            self.assertNotIn(".github/workflows/cmux-next-guards.yml", paths,
                             f"{check}: keyed on the workflow file, every edit to another step would change it")
            self.assertLess(len(rows), len(whole), f"{check}: not narrower than the job's list")

    def test_a_step_receipt_is_recorded_before_the_next_step(self):
        for step_id in self.checks:
            at = self.ids.index(step_id)
            lookup, record, save = (self.steps[self.ids.index(f"{step_id}-receipt")], self.steps[at + 1],
                                    self.steps[at + 2])
            self.assertLess(self.ids.index("step-keys"), self.ids.index(f"{step_id}-receipt"))
            self.assertLess(self.ids.index(f"{step_id}-receipt"), at, "the lookup comes before the step")
            self.assertEqual(lookup["with"]["lookup-only"], "true", "shadow: the receipt is looked up, never used")
            self.assertEqual(record.get("id"), f"{step_id}-record")
            self.assertIn(f"record {self.checks[step_id]} ", record["run"])
            self.assertIn(f"steps.{step_id}.outcome == 'success'", record["if"])
            self.assertTrue(str(save.get("uses", "")).startswith("actions/cache/save@"), step_id)
            self.assertEqual(save["with"]["key"], lookup["with"]["key"])
            self.assertIn(f"steps.step-keys.outputs.{step_id}", save["with"]["key"])
            for shadow in (lookup, record, save):
                self.assertEqual(shadow.get("continue-on-error"), "true", "a shadow step never fails the job")
                # success() would drop the receipt of a step that passed when an earlier step failed.
                self.assertNotIn("success()", shadow["if"])
            self.assertNotIn("steps.", self.steps[at].get("if", ""), "shadow: the step itself still always runs")

    def test_verdicts_compare_each_step_with_its_receipt(self):
        steps = {
            "step-keys": {"outputs": {"defaults-snapshot": "a" * 64, "group-menus": "b" * 64, "page-strings": ""}},
            "defaults-snapshot-receipt": {"outputs": {"cache-hit": "true"}},
            "defaults-snapshot": {"outcome": "failure"},
            "group-menus-receipt": {"outputs": {"cache-hit": "true"}},
            "group-menus": {"outcome": "success"},
            "page-strings": {"outcome": "success"},
        }
        by = {v["step"]: v for v in rik.step_verdicts(self.JOB, steps)}
        self.assertEqual(sorted(by), ["defaults-snapshot", "group-menus"], "a step with no key reports nothing")
        self.assertTrue(by["defaults-snapshot"]["wrong_reuse"], "found a receipt and the step failed")
        self.assertTrue(by["group-menus"]["would_skip"])
        self.assertFalse(by["group-menus"]["wrong_reuse"])
        cut_off = {"step-keys": steps["step-keys"], "group-menus-receipt": {"outputs": {"cache-hit": "true"}},
                   "defaults-snapshot": {"outcome": "success"}}
        by = {v["step"]: v for v in rik.step_verdicts(self.JOB, cut_off)}
        self.assertEqual(by["group-menus"]["run"], "not-run", "the job was cut off before the step")
        self.assertFalse(by["group-menus"]["wrong_reuse"], "a step that did not run has no verdict to contradict")
        self.assertFalse(by["defaults-snapshot"]["would_skip"])


class StepKeyTest(KeyTest):
    def test_a_step_key_moves_with_its_own_rows_only(self):
        mine, other = [("*", "blob", "gate.py"), ("*", "tree", "app")], [("*", "tree", "site"), ("*", "names", "rust")]
        key = lambda rows: rik.input_key("static-checks-group-menus", [], rows=rows)[0]  # noqa: E731
        before_mine, before_other = key(mine), key(other)
        self.write("site/b.tsx", "changed")
        self.write("rust/x.rs", "changed")
        self.commit()
        self.assertEqual(before_mine, key(mine), "another step's input changed this step's key")
        self.assertNotEqual(before_other, key(other))
        self.write("app/a.tsx", "changed")
        self.commit()
        self.assertNotEqual(before_mine, key(mine))

    def test_a_probed_directory_keys_on_being_there_not_on_its_tree(self):
        # `stat scripts` on the way to scripts/x.py: a blob row on the directory was its whole tree, so every edit
        # under it changed the key (group menus: 77% of a day's pushes reused, 98% with exists).
        key = lambda kind: rik.input_key("static-checks-group-menus", [], rows=[("*", kind, "app"), ("*", "blob", "gate.py")])[0]  # noqa: E731
        probed, whole = key("exists"), key("blob")
        self.write("app/a.tsx", "changed")
        self.write("app/new.tsx", "new")
        self.commit()
        self.assertEqual(probed, key("exists"), "an edit under a probed directory changed the key")
        self.assertNotEqual(whole, key("blob"))
        self.git("rm", "-q", "-r", "app")
        self.commit()
        gone = key("exists")
        self.assertNotEqual(probed, gone, "the probed directory went away and the key stayed")
        self.write("app", "now a file")
        self.commit()
        as_file = key("exists")
        self.assertNotIn(as_file, (probed, gone), "a file where the directory was is another key")
        self.write("app", "another file")
        self.commit()
        self.assertNotEqual(as_file, key("exists"), "a probed file keys on its content")

    def test_the_widest_kind_of_a_path_wins(self):
        rows = lambda *kinds: [("*", kind, "app") for kind in kinds]  # noqa: E731
        key = lambda *kinds: rik.input_key("static-checks-group-menus", [], rows=rows(*kinds))[0]  # noqa: E731
        self.assertEqual(key("exists", "names"), key("names"))
        self.assertEqual(key("names", "exists", "blob"), key("blob"))
        self.assertEqual(rik.pinned_patterns("static-checks-group-menus", "HEAD", rows=rows("exists")), [],
                         "a probed directory pins nothing")

    def test_the_node_pin_is_part_of_a_node_steps_key(self):
        rows = [("*", "blob", "gate.py")]
        before = rik.input_key("static-checks-page-strings", [], rows=rows)[0]
        old = rik.CHECKS["static-checks-page-strings"]
        rik.CHECKS["static-checks-page-strings"] = {**old, "node": "99.0.0"}
        try:
            self.assertNotEqual(before, rik.input_key("static-checks-page-strings", [], rows=rows)[0])
        finally:
            rik.CHECKS["static-checks-page-strings"] = old


class ControllerVectorTest(unittest.TestCase):
    """cmuxterm-hq build-fleet/cmd/controller/input_receipt_test.go keys the same material to the same key; the
    controller computes the key a signed receipt is stored under, so the two must never drift."""

    def test_key_vector_matches_the_controller(self):
        rows = [("*", "blob", "scripts/gate.py"), ("*", "tree", "scripts/tool"), ("app", "tree", "app"),
                ("app", "tree", "shared"), ("site", "tree", "site")]
        oids = {"scripts/gate.py": "1" * 40, "scripts/tool": "2" * 40, "app": "3" * 40, "site": "4" * 40}
        old, rik.object_id = rik.object_id, lambda _rev, rel: oids.get(rel)
        try:
            key, _ = rik.input_key("react-doctor", ["site", "app"], rows=rows)
        finally:
            rik.object_id = old
        self.assertEqual(key, "7eb85f4c009c58704d26dc87728db0639c8f0f1b71a256307d07b1a30f1c9fe5")  # gitleaks:allow (sha256 input key test vector, not a secret)
        self.assertEqual(rik.CHECKS["react-doctor"]["command"], "python3 scripts/ci/react_doctor_gate.py")


class SignedReceiptTest(unittest.TestCase):
    """scripts/ci/receipt_signed.py skips only on the controller's hit for this checkout's own key."""

    def run_main(self, op, answer=None, error=None):
        def ask_fn(_op, _check, _token):
            if error:
                raise error
            return answer
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "out"
            signed.main([op, "react-doctor", "--output", str(out)], env={}, token_fn=lambda _env: "t", ask_fn=ask_fn)
            return dict(line.split("=", 1) for line in out.read_text().splitlines())

    def test_hit_on_the_same_key(self):
        key = signed.all_units_key("react-doctor")
        self.assertEqual(self.run_main("lookup", {"hit": True, "input_key": key})["hit"], "true")

    def test_no_hit_on_another_key(self):
        self.assertEqual(self.run_main("lookup", {"hit": True, "input_key": "0" * 64})["hit"], "false")

    def test_no_hit_on_a_miss_or_an_error(self):
        self.assertEqual(self.run_main("lookup", {"hit": False, "reason": "pinned"})["hit"], "false")
        self.assertEqual(self.run_main("lookup", error=OSError("down"))["hit"], "false")

    def test_no_token_is_a_miss(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "out"
            self.assertEqual(signed.main(["lookup", "react-doctor", "--output", str(out)], env={}), 0)
            self.assertIn("hit=false", out.read_text())


if __name__ == "__main__":
    unittest.main()
