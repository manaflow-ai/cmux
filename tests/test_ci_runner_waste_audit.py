import subprocess, sys, tempfile, textwrap, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/runner_waste_audit.py"

def run(files):
    with tempfile.TemporaryDirectory() as d:
        for n, t in files.items(): Path(d, n).write_text(textwrap.dedent(t))
        return subprocess.run([sys.executable, SCRIPT, d], capture_output=True, text=True, check=True).stdout

class RunnerWasteAudit(unittest.TestCase):
    def test_flags_pr_workflow_without_concurrency(self):
        out = run({"a.yml": "on: [pull_request]\njobs:\n  x:\n    runs-on: ubuntu-24.04\n    steps: [{run: 'true'}]\n"})
        self.assertIn("no-concurrency  a.yml", out)
    def test_job_level_concurrency_is_enough(self):
        out = run({"a.yml": "on: [pull_request]\njobs:\n  x:\n    runs-on: ubuntu-24.04\n    concurrency: g\n    steps: [{run: 'true'}]\n"})
        self.assertNotIn("no-concurrency", out)
    def test_flags_step_skip(self):
        out = run({"a.yml": "on: [push]\njobs:\n  x:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: |\n          echo skipping\n          exit 0\n"})
        self.assertIn("step-skip", out)
    def test_repo_has_no_pr_workflow_without_concurrency(self):
        out = subprocess.run([sys.executable, SCRIPT, ROOT / ".github/workflows"], capture_output=True, text=True, check=True).stdout
        self.assertNotIn("no-concurrency", out)

if __name__ == "__main__":
    unittest.main()
