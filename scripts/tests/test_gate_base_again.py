"""scripts/ci/gate_base_again.py: a pull request's red gate that is red on its merge parent too warns, never fails."""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "ci" / "gate_base_again.py"
GIT = ["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]

CHECK = """import unittest
class T(unittest.TestCase):
{body}
if __name__ == "__main__":
    unittest.main()
"""


def tests(*names_ok):
    return CHECK.format(body="".join(f"    def test_{n}(self):\n        self.assertTrue({ok})\n" for n, ok in names_ok))


class GateBaseAgain(unittest.TestCase):
    def repo(self, base: str, head: str) -> Path:
        root = Path(tempfile.mkdtemp())
        self.addCleanup(subprocess.run, ["rm", "-rf", str(root)])
        env = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"}
        subprocess.run(["git", "init", "-q", str(root)], check=True, env=env)
        for text in (base, head):
            (root / "check.py").write_text(text)
            subprocess.run(GIT + ["-C", str(root), "add", "-A"], check=True, env=env)
            subprocess.run(GIT + ["-C", str(root), "commit", "-q", "--allow-empty", "-m", "c"], check=True, env=env)
        return root

    def judge(self, root: Path, outcome="failure", cmd="python3 check.py") -> dict:
        out = root.parent / f"{root.name}.out"
        env = {**os.environ, "GATE": outcome, "GITHUB_OUTPUT": str(out)}
        p = subprocess.run([sys.executable, str(SCRIPT), "--root", str(root), "--gate", f"GATE={cmd}"],
                           env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        self.assertEqual(p.returncode, 0, p.stdout)
        result = dict(line.split("=", 1) for line in out.read_text().splitlines())
        result["log"] = p.stdout
        return result

    def test_a_test_red_on_the_base_too_is_the_bases(self):
        root = self.repo(tests(("a", False), ("b", True)), tests(("a", False), ("b", True), ("c", True)))
        r = self.judge(root)
        self.assertEqual((r["own_red"], r["base"]), ("false", "GATE"), r["log"])
        self.assertIn("::warning::GATE is red on the base", r["log"])
        self.assertFalse(list(root.parent.glob("gate-base-*/base")))

    def test_a_new_red_test_is_the_changes_even_with_a_base_red(self):
        root = self.repo(tests(("a", False), ("b", True)), tests(("a", False), ("b", False)))
        r = self.judge(root)
        self.assertEqual((r["own_red"], r["own"]), ("true", "GATE"), r["log"])
        self.assertIn("test_b", r["log"])

    def test_green_on_the_base_is_the_changes(self):
        root = self.repo(tests(("a", True)), tests(("a", False)))
        self.assertEqual(self.judge(root)["own_red"], "true")

    def test_a_step_red_on_both_without_tests_is_the_bases(self):
        root = self.repo("raise SystemExit(3)\n", "raise SystemExit(4)\n")
        self.assertEqual(self.judge(root)["own_red"], "false")

    def test_a_base_timeout_judges_nothing(self):
        root = self.repo("import time\ntime.sleep(30)\n", "raise SystemExit(1)\n")
        out = root.parent / f"{root.name}.out"
        env = {**os.environ, "GATE": "failure", "GITHUB_OUTPUT": str(out)}
        subprocess.run([sys.executable, str(SCRIPT), "--root", str(root), "--timeout", "2",
                        "--gate", "GATE=python3 check.py"], env=env, check=True, stdout=subprocess.DEVNULL)
        self.assertIn("own_red=true", out.read_text())

    def test_a_green_gate_runs_nothing(self):
        root = self.repo(tests(("a", False)), tests(("a", False)))
        r = self.judge(root, outcome="success")
        self.assertEqual((r["own_red"], r["own"], r["base"]), ("false", "", ""))
        self.assertNotIn("worktree", r["log"])


if __name__ == "__main__":
    unittest.main()
