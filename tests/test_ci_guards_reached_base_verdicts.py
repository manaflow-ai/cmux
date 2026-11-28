#!/usr/bin/env python3
"""scripts/ci/guards_reached.sh: CI_GUARDS_REACHED_BASE_VERDICTS=1 reuses recorded base verdicts; 0 re-runs as before.

The real script runs in a scratch repository whose guard tools are stubs that log each call: guards-local.sh
(the head pass reds two steps), guard_base_verdicts.py (records one of them) and guards_new_reds.py (the real one).
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

GUARDS_LOCAL = r"""#!/usr/bin/env bash
# Stub: logs its --step list and --root; the head reds alpha and beta, the base reds alpha only.
steps=(); root=""; results=""
while [ $# -gt 0 ]; do
  case "$1" in
    --step) steps+=("$2"); shift 2 ;;
    --root) root="$2"; shift 2 ;;
    --results) results="$2"; shift 2 ;;
    *) shift ;;
  esac
done
echo "${root:-head} ${steps[*]}" >> "$CALL_LOG"
python3 - "$results" "${root:-}" "${steps[@]}" <<'EOF'
import json, sys
out, root, steps = sys.argv[1], sys.argv[2], sys.argv[3:]
red = {"alpha"} if root else {"alpha", "beta"}
json.dump({**{s: s not in red for s in steps}, "_cmux_complete": True}, open(out, "w"))
EOF
echo "stub: done"
"""

STEP_INPUTS = r"""#!/usr/bin/env python3
import json
print(json.dumps({"run": {"alpha": "reached by a", "beta": "reached by b", "gamma": "reached by c"}}))
"""

# Stub: beta has a recorded base verdict (red on the base); alpha is left to re-run.
BASE_VERDICTS = r"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
sys.path.insert(0, os.environ["REAL_CI"])
import guard_base_verdicts as real
if sys.argv[1:2] == ["--merge"]:
    sys.exit(real.main(sys.argv[1:]))
args = dict(zip(sys.argv[1::2], sys.argv[2::2]))
with open(os.environ["CALL_LOG"], "a") as log:
    log.write("verdicts token=%s\n" % bool(os.environ.get("GH_TOKEN")))
if os.environ.get("VERDICTS_FAIL"):
    sys.exit(1)
out = Path(args["--out"])
out.write_text(json.dumps({"beta": False, "_cmux_complete": False}))
Path(str(out) + ".failures.json").write_text("{}")
for step in Path(args["--steps"]).read_text().split():
    if step != "beta":
        print(step)
"""


class GuardsReachedBaseVerdictsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, True)
        ci = self.dir / "scripts" / "ci"
        ci.mkdir(parents=True)
        shutil.copy(ROOT / "scripts/ci/guards_reached.sh", ci)
        shutil.copy(ROOT / "scripts/ci/guards_new_reds.py", ci)
        for name, body in (("guards-local.sh", GUARDS_LOCAL), ("guard_step_inputs.py", STEP_INPUTS),
                           ("guard_base_verdicts.py", BASE_VERDICTS)):
            (ci / name).write_text(body)
            (ci / name).chmod(0o755)
        git = ["git", "-C", str(self.dir), "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
        subprocess.run(["git", "init", "-q", str(self.dir)], check=True)
        subprocess.run([*git, "add", "-A"], check=True)
        subprocess.run([*git, "commit", "-qm", "base"], check=True)
        (self.dir / "x").write_text("x")
        subprocess.run([*git, "add", "-A"], check=True)
        subprocess.run([*git, "commit", "-qm", "head"], check=True)
        self.log = self.dir.parent / (self.dir.name + ".calls")
        self.addCleanup(lambda: self.log.unlink(missing_ok=True))

    def run_script(self, **env: str) -> tuple[subprocess.CompletedProcess, list[str]]:
        full = {**os.environ, "CALL_LOG": str(self.log), "REAL_CI": str(ROOT / "scripts/ci"),
                "GITHUB_REPOSITORY": "o/r", **env}
        for key in ("CI_GUARDS_REACHED_BASE_VERDICTS", "GH_TOKEN", "VERDICTS_FAIL"):
            if key not in env:
                full.pop(key, None)
        done = subprocess.run(["bash", str(self.dir / "scripts/ci/guards_reached.sh")], env=full,
                              capture_output=True, text=True)
        calls = self.log.read_text().splitlines() if self.log.exists() else []
        return done, calls

    def base_calls(self, calls: list[str]) -> list[str]:
        return [c.split(" ", 1)[1] for c in calls if c.split(" ", 1)[0].endswith("/base")]

    def test_default_reruns_every_red_and_reads_no_verdicts(self) -> None:
        done, calls = self.run_script()
        self.assertEqual(self.base_calls(calls), ["alpha beta"], done.stdout + done.stderr)
        self.assertFalse(any(c.startswith("verdicts") for c in calls))
        # beta is red on the head and green on the base: the change's red, so the step fails.
        self.assertNotEqual(done.returncode, 0, done.stdout + done.stderr)

    def test_on_reuses_recorded_verdicts_and_reruns_only_the_rest(self) -> None:
        done, calls = self.run_script(CI_GUARDS_REACHED_BASE_VERDICTS="1", GH_TOKEN="t")
        self.assertIn("verdicts token=True", calls)
        self.assertEqual(self.base_calls(calls), ["alpha"], done.stdout + done.stderr)
        self.assertIn("re-running 1 of the head's 2 red steps", done.stdout)
        # beta's recorded base verdict is red, alpha re-ran red: no red is new, so the step passes.
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)

    def test_a_failed_read_reruns_every_red(self) -> None:
        done, calls = self.run_script(CI_GUARDS_REACHED_BASE_VERDICTS="1", GH_TOKEN="t", VERDICTS_FAIL="1")
        self.assertEqual(self.base_calls(calls), ["alpha beta"], done.stdout + done.stderr)
        self.assertNotEqual(done.returncode, 0)


if __name__ == "__main__":
    unittest.main()
