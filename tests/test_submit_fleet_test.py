"""Drive the checkout command in a fresh Git repository with a recording gh."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "submit-fleet-test"
RUN_URL = "https://github.com/manaflow-ai/cmux/actions/runs/123"


class SubmitFleetTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.work = self.root / "repo"
        self.cwd = self.work / "sub dir"
        self.cwd.mkdir(parents=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.bin.joinpath("gh").write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            "with open(os.environ['GH_CALLS'], 'a') as calls:\n"
            "    print(json.dumps(sys.argv[1:]), file=calls)\n"
            "print(os.environ['GH_REPLY'])\n"
            "sys.exit(int(os.environ.get('GH_EXIT', '0')))\n")
        self.bin.joinpath("gh").chmod(0o755)
        # A personal checkout has git and gh, without the lane's helpers or credentials.
        self.bin.joinpath("git").symlink_to(shutil.which("git"))
        self.calls = self.root / "calls"
        self.env = {"HOME": str(self.root), "PATH": str(self.bin), "GH_REPLY": RUN_URL,
                    "GH_CALLS": str(self.calls)}
        for args in (["init", "-q"], ["-c", "user.name=Test", "-c", "user.email=a@example.org",
                                      "commit", "-qm", "fixture", "--allow-empty"]):
            subprocess.run(["git", *args], cwd=self.work, env=self.env, check=True)
        self.head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=self.work, env=self.env,
                                            text=True).strip()

    def submit(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), *args], cwd=self.cwd, env=self.env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def test_runs_from_plain_checkout(self):
        for words, setup in [(["true"], "none"), (["cargo", "test"], "rust"),
                             (["bun", "test", "a b", "$(touch unexpected)", "'quoted'", ""], "webviews")]:
            with self.subTest(words=words):
                result = self.submit("--", *words)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), RUN_URL)
                argv = json.loads(self.calls.read_text().splitlines()[-1])
                self.assertEqual(argv[:7], ["workflow", "run", "fast-checks.yml", "--repo",
                                            "github.com/manaflow-ai/cmux", "--ref", "main"])
                self.assertEqual(argv[7::2], ["-f"] * 4)
                inputs = dict(field.split("=", 1) for field in argv[8::2])
                self.assertEqual(inputs["source_sha"], self.head)
                self.assertEqual(inputs["directory"], "sub dir/")
                self.assertEqual(inputs["setup"], setup)
                self.assertEqual(shlex.split(inputs["command"]), words)

    def test_explicit_setup_and_refusal(self):
        self.env["GH_EXIT"] = "4"
        result = self.submit("--setup", "playwright", "--", "bun", "test")
        self.assertEqual(result.returncode, 4)
        self.assertIn("gh auth status", result.stderr)
        self.assertIn("setup=playwright", json.loads(self.calls.read_text()))

    def test_accepted_without_link_does_not_submit_twice(self):
        self.env["GH_REPLY"] = ""
        result = self.submit("--", "true")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("accepted the dispatch", result.stderr)
        self.assertEqual(len(self.calls.read_text().splitlines()), 1)

    def test_missing_client_names_setup(self):
        self.env["PATH"] = str(self.root)
        result = self.submit("--", "true")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("gh auth login", result.stderr)
        self.assertFalse(self.calls.exists())


if __name__ == "__main__":
    unittest.main()
