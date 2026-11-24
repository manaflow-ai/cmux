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
