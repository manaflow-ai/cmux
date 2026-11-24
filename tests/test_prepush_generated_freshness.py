"""The pre-push gate's generated-file freshness layer (GENERATED_FRESH_CHECK): a push that changes a committed
generator's input without rerunning it is refused, and the generator is run in the checkout so the fix is there to
commit (Leo, 2026-11-23: "Mistakes should also be auto fixed and ran properly a lot of these are pretty mechanical").
"""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1]


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


git_fixture_env = load("git_fixture_env", Path(__file__).resolve().parent / "git_fixture_env.py")
gate = load("cmux_next_prepush_gate_generated_fresh", SOURCE / "scripts/cmux-next/prepush-gate.py")

GENERATOR = "scripts/cmux-next/gen-demo.py"
# Like the real gen-*.py: the repository is two folders above the script, --check exits 1 on drift.
GENERATOR_CODE = '''import os, sys
ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
want = open(os.path.join(ROOT, "schemas/demo.txt")).read().upper()
out = os.path.join(ROOT, "out/demo.generated.txt")
have = open(out).read() if os.path.exists(out) else None
if have != want:
    if "--check" in sys.argv[1:]:
        print("stale out/demo.generated.txt", file=sys.stderr)
        sys.exit(1)
    open(out, "w").write(want)
'''
CONFIG = {"generators": [{"id": "demo", "generator": GENERATOR, "outputs": ["out/demo.generated.txt"],
                          "inputs": ["schemas/**"], "status": "committed", "check": ["--check"]}]}


class GeneratedFreshness(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="cmux-generated-fresh-test-")
        self.addCleanup(temporary.cleanup)
        self.repo = Path(temporary.name)
        self.env = git_fixture_env.fixture_env({
            **os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "F", "GIT_AUTHOR_EMAIL": "f@e",
            "GIT_COMMITTER_NAME": "F", "GIT_COMMITTER_EMAIL": "f@e"})
        git_fixture_env.init_repo(self.repo, env=self.env)
        self.write("scripts/ci/generated-files.json", json.dumps(CONFIG))
        self.write(GENERATOR, GENERATOR_CODE)
        self.write("schemas/demo.txt", "one")
        self.write("out/demo.generated.txt", "ONE")
        self.base = self.commit("base")

    def write(self, relative, text):
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self, message):
        subprocess.run(["git", "-C", str(self.repo), "add", "-A"], env=self.env, check=True)
        subprocess.run(["git", "-C", str(self.repo), "commit", "-qm", message], env=self.env, check=True)
        return subprocess.run(["git", "-C", str(self.repo), "rev-parse", "HEAD"], env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def test_a_stale_output_is_regenerated_in_the_checkout_and_refused(self):
        self.write("schemas/demo.txt", "two")
        head = self.commit("edit the input only")
        found = gate.generated_freshness(self.repo, self.base, head)
        self.assertEqual(len(found), 1, found)
        self.assertIn("rewrote 1 file(s) in your checkout (out/demo.generated.txt)", found[0])
        self.assertEqual((self.repo / "out/demo.generated.txt").read_text(), "TWO")

    def test_a_regenerated_push_passes(self):
        self.write("schemas/demo.txt", "two")
        self.write("out/demo.generated.txt", "TWO")
        self.assertEqual(gate.generated_freshness(self.repo, self.base, self.commit("regenerated")), [])

    def test_a_push_off_the_generator_runs_nothing(self):
        self.write("README", "x")
        self.assertEqual(gate.generated_freshness(self.repo, self.base, self.commit("docs")), [])

    def test_a_dirty_checkout_or_another_head_is_left_to_ci_and_untouched(self):
        self.write("schemas/demo.txt", "two")
        head = self.commit("edit the input only")
        self.write("schemas/demo.txt", "three")  # an uncommitted edit: the checkout is not the pushed head
        self.assertEqual(gate.generated_freshness(self.repo, self.base, head), [])
        self.assertEqual((self.repo / "out/demo.generated.txt").read_text(), "ONE")

    def test_a_hook_run_runs_only_the_installed_copy(self):
        self.write("schemas/demo.txt", "two")
        self.write(GENERATOR, GENERATOR_CODE + "# changed by the push\n")
        head = self.commit("change the generator")
        with tempfile.TemporaryDirectory() as trusted:
            (Path(trusted) / Path(GENERATOR).name).write_text(GENERATOR_CODE)
            self.assertEqual(gate.generated_freshness(self.repo, self.base, head, Path(trusted)), [])
        self.assertEqual((self.repo / "out/demo.generated.txt").read_text(), "ONE")


if __name__ == "__main__":
    unittest.main()
