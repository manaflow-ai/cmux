#!/usr/bin/env python3
"""Prototypes/ViewShell/patch_compile.py, inject.sh's fast path: from a kept driver plan (`swiftc -c ... -###`) it runs
only the frontend jobs whose primary is a patched file, writes WORK/NAME.o for each, and exits 3 when the plan cannot
cover a name (inject.sh then compiles the whole module). A fake frontend stands in for swift-frontend, so this runs on
Linux."""
import os
import shlex
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "Prototypes/ViewShell/patch_compile.py"

FRONTEND = textwrap.dedent("""\
    #!/usr/bin/env python3
    import os, sys
    argv = sys.argv[1:]
    primary = argv[argv.index("-primary-file") + 1]
    out = argv[argv.index("-o") + 1]
    with open(os.environ["FAKE_LOG"], "a") as log:
        log.write(os.path.basename(primary) + "\\n")
    if os.path.basename(primary) == os.environ.get("FAKE_FAIL", ""):
        sys.stderr.write(primary + ": error: nope\\n")
        sys.exit(1)
    open(out, "w").write("object of " + primary)
""")


class PatchCompileTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.work = base / "work"
        self.work.mkdir()
        self.frontend = base / "swift-frontend"
        self.frontend.write_text(FRONTEND)
        self.frontend.chmod(0o755)
        self.log = base / "ran.txt"
        self.driver_tmp = base / "TemporaryDirectory.abc"  # the driver's folder: only a real run makes it
        files = [f"/src/ViewShell/{n}.swift" for n in ("Badge", "LiveCode", "main")]
        lines = ["warning: something the driver says"]
        for f in files:
            others = []
            for g in files:
                others += ["-primary-file", g] if g == f else [g]
            out = self.driver_tmp / (Path(f).stem + "-1.o")
            lines.append(shlex.join([str(self.frontend), "-frontend", "-c", *others, "-target", "arm64-apple-macos14.0",
                                     "-module-name", "ViewShell", "-o", str(out)]))
        self.plan = base / "plan.txt"
        self.plan.write_text("\n".join(lines) + "\n")

    def tearDown(self):
        self.tmp.cleanup()

    def run_it(self, *names, fail=""):
        env = dict(os.environ, FAKE_LOG=str(self.log), FAKE_FAIL=fail)
        return subprocess.run([sys.executable, str(SCRIPT), "--plan", str(self.plan), "--work", str(self.work), *names],
                              capture_output=True, text=True, env=env)

    def ran(self):
        return self.log.read_text().split() if self.log.exists() else []

    def test_runs_only_the_patched_files_job_into_work(self):
        done = self.run_it("Badge")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(self.ran(), ["Badge.swift"])
        self.assertEqual((self.work / "Badge.o").read_text(), "object of /src/ViewShell/Badge.swift")
        self.assertFalse((self.driver_tmp / "Badge-1.o").exists(), "the object goes to WORK, not the plan's temp name")

    def test_several_names(self):
        done = self.run_it("Badge", "main")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(sorted(self.ran()), ["Badge.swift", "main.swift"])
        self.assertTrue((self.work / "main.o").exists())

    def test_a_name_the_plan_lacks_exits_3_and_runs_nothing(self):
        done = self.run_it("Badge", "NewFile")
        self.assertEqual(done.returncode, 3)
        self.assertEqual(self.ran(), [])

    def test_a_missing_plan_exits_3(self):
        self.plan.unlink()
        self.assertEqual(self.run_it("Badge").returncode, 3)

    def test_a_failing_job_passes_its_code_and_diagnostics(self):
        done = self.run_it("Badge", fail="Badge.swift")
        self.assertEqual(done.returncode, 1)
        self.assertIn("error: nope", done.stderr)


if __name__ == "__main__":
    unittest.main()
