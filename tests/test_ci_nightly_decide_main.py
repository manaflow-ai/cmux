"""nightly.yml decide-main: main's first-attempt decide on its own read budget, keyless decide forwards it."""
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/nightly.yml"
sys.path.insert(0, str(ROOT / "scripts/ci"))
import nightly_decide_script  # noqa: E402


def jobs() -> dict:
    return yaml.safe_load(WORKFLOW.read_text())["jobs"]


def step(job: dict, step_id: str) -> dict:
    return next(s for s in job["steps"] if s.get("id") == step_id)


class DecideMain(unittest.TestCase):
    def test_decide_main_runs_on_the_secret_jit_label(self) -> None:
        # It holds the route App key, so no variable may move it off the one-job secret JIT VM; the only
        # branch is the fork's (actionlint reads a bare custom label as unknown).
        self.assertEqual(jobs()["decide-main"]["runs-on"],
                         "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'cmux-gcp-secret-jit-x64' }}")

    def test_decide_holds_no_secret(self) -> None:
        body = yaml.safe_dump(jobs()["decide"], width=100000)
        self.assertNotRegex(body, r"secrets\.|private-key")

    def test_decide_forwards_every_output(self) -> None:
        decide, main = jobs()["decide"]["outputs"], jobs()["decide-main"]["outputs"]
        forwarded = {k for k, v in decide.items() if f"needs.decide-main.outputs.{k} ||" in v}
        self.assertEqual(set(main), forwarded)
        for key, value in main.items():
            self.assertEqual(value, f"${{{{ steps.decide.outputs.{key} }}}}")
        self.assertIn("decide-main", jobs()["decide"]["needs"])
        self.assertTrue(jobs()["decide"]["if"].startswith("${{ !cancelled() && "))

    def test_a_failed_decide_main_never_turns_the_run_red(self) -> None:
        steps = {s.get("id"): s for s in jobs()["decide-main"]["steps"] if s.get("id")}
        for step_id in ("read-token", "script", "decide"):
            self.assertIs(steps[step_id].get("continue-on-error"), True, step_id)
        self.assertEqual(steps["script"]["if"], "steps.read-token.outputs.token != ''")
        self.assertEqual(steps["decide"]["if"], "steps.script.outcome == 'success'")

    def test_decide_skips_its_steps_when_decide_main_decided(self) -> None:
        for s in jobs()["decide"]["steps"]:
            self.assertEqual(s.get("if"), "needs.decide-main.outputs.should_build == ''", s.get("name"))

    def test_the_step_env_is_decides(self) -> None:
        main_env = dict(step(jobs()["decide-main"], "decide")["env"])
        self.assertEqual(main_env.pop("SPARE_READ_TOKEN"), "${{ github.token }}")
        self.assertEqual(main_env, step(jobs()["decide"], "decide")["env"])

    def test_the_tick_slot_is_kept(self) -> None:
        group = jobs()["decide-main"]["concurrency"]["group"]
        self.assertIn("'nightly-main-tick-decide'", group)
        self.assertIs(jobs()["decide-main"]["concurrency"]["cancel-in-progress"], False)
        # A forwarding decide leaves the slot so it never evicts the next tick's pending decide-main.
        self.assertTrue(jobs()["decide"]["concurrency"]["group"].startswith(
            "${{ needs.decide-main.outputs.should_build != '' && format('nightly-decide-{0}', github.run_id) || "))

    def test_the_step_installs_the_wait_once_with_a_spare(self) -> None:
        call = step(jobs()["decide-main"], "decide")["with"]["script"]
        self.assertIn(f"if (process.env.GH_BUDGET_WAIT_JS) {nightly_decide_script.SPARE}", call)
        self.assertEqual(call.count(".install("), 1)

    def test_the_script_module_is_decides_script_without_its_install(self) -> None:
        script = step(jobs()["decide"], "decide")["with"]["script"]
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "decide.cjs"
            subprocess.run([sys.executable, str(ROOT / "scripts/ci/nightly_decide_script.py"), str(WORKFLOW), str(out)],
                           check=True)
            text = out.read_text()
            self.assertNotIn(".install(", text)
            self.assertEqual(text.replace(nightly_decide_script.STRIPPED,
                                          f"if (process.env.GH_BUDGET_WAIT_JS) {nightly_decide_script.INSTALL}"),
                             nightly_decide_script.module(script))
            node = subprocess.run(["node", "-e",
                                   "new Function(require('fs').readFileSync(process.argv[1], 'utf8'))", str(out)],
                                  capture_output=True, text=True)
            self.assertEqual(node.returncode, 0, node.stderr)

    def test_the_module_call_passes_what_the_script_uses(self) -> None:
        call = step(jobs()["decide-main"], "decide")["with"]["script"]
        self.assertIn(nightly_decide_script.ARGS, call)
        script = step(jobs()["decide"], "decide")["with"]["script"]
        for name in ("glob", "io", "fetch"):
            self.assertIsNone(re.search(rf"(?<![.\w]){name}\b", script), name)


if __name__ == "__main__":
    unittest.main()
