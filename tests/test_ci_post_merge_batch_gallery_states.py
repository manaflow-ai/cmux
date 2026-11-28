"""A gallery-health bisect probe renders only the states red on its origin batch run.

Probes ("probe gallery-health health at SHA") rendered the whole gallery over ~22 shards each, ~16k runner-min a
day (11-27). The batch's red shards now name their red states (gallery-health.yml "Name the red states for a bisect
probe"), the batch judge sends them with the bisect's probes (post_merge_batch.py red_states), and a probe's plan
renders those states alone: one shard. A shard that names none (a crash, no health.json) or a missing file keeps
the whole render, as before.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import post_merge_batch as pmb  # noqa: E402

GALLERY = ROOT / ".github" / "workflows" / "gallery-health.yml"
POST_MERGE = ROOT / ".github" / "workflows" / pmb.WORKFLOW
SHA = "a" * 40
GOOD = "b" * 40


def workflow(path: Path) -> dict:
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def job_step(path: Path, job: str, name: str) -> dict:
    found = [s for s in workflow(path)["jobs"][job]["steps"] if s.get("name") == name]
    if not found:
        raise AssertionError(f"{path.name}'s {job} job has no step named {name!r}")
    return found[0]


def verdicts(*legs: tuple[int, str]) -> dict[str, tuple[str, str]]:
    out = {f"gallery-health / health ({n})": ("gallery-health", c) for n, c in legs}
    out["gallery-health / plan"] = ("gallery-health", "success")
    out["web / Web tests (1/4)"] = ("web", "failure")
    return out


class RedStatesTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="gallery-reds-")
        self.dir = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def write(self, shard: int, *lines: str) -> None:
        (self.dir / f"reds-{shard}.txt").write_text("".join(f"{line}\n" for line in lines))

    def test_every_red_leg_states_are_one_sorted_list(self) -> None:
        self.write(3, "b.entry#two", "a.entry#one")
        self.write(7, "a.entry#one", "c.entry#")
        got = pmb.red_states("gallery-health", "gallery-health / health (3)", verdicts((3, "failure"), (7, "failure"), (1, "success")), self.dir)
        self.assertEqual(got, "a.entry#one,b.entry#two,c.entry#")

    def test_a_leg_with_no_list_keeps_the_whole_render(self) -> None:
        self.write(3, "a.entry#one")
        self.assertEqual(pmb.red_states("gallery-health", "gallery-health / health (3)", verdicts((3, "failure"), (7, "failure")), self.dir), "")
        self.write(7, pmb.WHOLE)
        self.assertEqual(pmb.red_states("gallery-health", "gallery-health / health (3)", verdicts((3, "failure"), (7, "failure")), self.dir), "")
        self.write(7, "")
        self.assertEqual(pmb.red_states("gallery-health", "gallery-health / health (3)", verdicts((3, "failure"), (7, "failure")), self.dir), "")
        self.write(7, "no-hash-here")
        self.assertEqual(pmb.red_states("gallery-health", "gallery-health / health (3)", verdicts((3, "failure"), (7, "failure")), self.dir), "")

    def test_a_setup_red_leg_adds_no_state_but_an_unknown_one_keeps_the_whole_render(self) -> None:
        self.write(3, "a.entry#one")
        reds = verdicts((3, "failure"), (7, "failure"))
        setup = {"gallery-health / health (7)": frozenset({"Install the webviews packages"})}
        self.assertEqual(pmb.red_states("gallery-health", "gallery-health / health (3)", reds, self.dir, setup), "a.entry#one")
        judged = {"gallery-health / health (7)": frozenset({pmb.GALLERY_JUDGE_STEP})}
        self.assertEqual(pmb.red_states("gallery-health", "gallery-health / health (3)", reds, self.dir, judged), "")
        self.assertEqual(pmb.red_states("gallery-health", "gallery-health / health (3)", reds, self.dir, {}), "")

    def test_other_suites_no_dir_and_long_lists_keep_the_whole_render(self) -> None:
        self.write(3, "a.entry#one")
        self.assertEqual(pmb.red_states("web", "web / Web tests (1/4)", verdicts((3, "failure")), self.dir), "")
        self.assertEqual(pmb.red_states("gallery-health", "gallery-health / health (3)", verdicts((3, "failure")), None), "")
        self.assertEqual(pmb.red_states("gallery-health", "gallery-health / health (3)", verdicts((3, "failure")), self.dir / "missing"), "")
        self.write(3, *(f"entry.{n:05d}#variant" for n in range(pmb.STATES_CAP // 10)))
        self.assertEqual(pmb.red_states("gallery-health", "gallery-health / health (3)", verdicts((3, "failure")), self.dir), "")


class ProbeStatesTest(unittest.TestCase):
    def probe(self, **extra) -> pmb.Probe:
        return pmb.Probe("gallery-health", "gallery-health / health (3)", "health", SHA, GOOD, "", "123", step="Judge", **extra)

    def test_the_states_go_in_the_dispatch_and_the_title(self) -> None:
        probe = self.probe(states="a#1,b#2")
        self.assertEqual(probe.inputs()["states"], "a#1,b#2")
        self.assertEqual(len(probe.states_key), 10)
        self.assertEqual(probe.inputs()["states_key"], probe.states_key)
        self.assertEqual(pmb.probe_title(probe), f"probe gallery-health health at {SHA} states {probe.states_key}")
        # No states: the dispatch and title are as before.
        whole = self.probe()
        self.assertNotIn("states", whole.inputs())
        self.assertNotIn("states_key", whole.inputs())
        self.assertEqual(pmb.probe_title(whole), f"probe gallery-health health at {SHA}")
        # Within the dispatch's 25 inputs.
        self.assertLessEqual(len(workflow(POST_MERGE)[True]["workflow_dispatch"]["inputs"]), 25)

    def test_every_probe_of_the_chain_keeps_the_states(self) -> None:
        commits = [GOOD, "c" * 40, "d" * 40, "e" * 40, SHA]
        step, nxt = pmb.next_step(self.probe(states="a#1"), "failure", commits)
        self.assertEqual(step, "probe")
        self.assertEqual(nxt.states, "a#1")
        step, again = pmb.next_step(self.probe(states="a#1"), "", commits)
        self.assertEqual((step, again.states), ("retry", "a#1"))
        stuck = pmb.stuck_probe("gallery-health / health (3)", "gallery-health", "health", GOOD, SHA, "123", commits, "Judge", "a#1")
        self.assertEqual(stuck.states, "a#1")

    def test_a_states_probe_reads_a_whole_render_verdict_at_the_commit(self) -> None:
        whole = pmb.probe_title(self.probe())
        runs = [{"id": 9, "display_title": whole, "status": "completed"}]
        jobs = lambda rid: ({"gallery-health / health (3)": ("gallery-health", "failure")}, True)  # noqa: E731
        known = pmb.known_verdict(runs, self.probe(states="a#1"), jobs)
        self.assertIsNotNone(known)
        self.assertEqual(known[0], "failure")

    def test_the_plan_passes_the_states_to_the_suite(self) -> None:
        with tempfile.TemporaryDirectory(prefix="pmb-plan-") as tmp:
            out = Path(tmp) / "out"
            out.write_text("")
            code = pmb.main(["plan", "--mode", "probe", "--suite", "gallery-health", "--job", "gallery-health / health (3)",
                             "--only", "health", "--probe-sha", SHA, "--good", GOOD, "--reuse", "12345",
                             "--states", "a#1,b#2", "--github-output", str(out), "--summary", os.devnull])
            self.assertEqual(code, 0)
            self.assertIn("states=a#1,b#2", out.read_text())


class WorkflowWiringTest(unittest.TestCase):
    def test_the_post_merge_workflow_carries_the_states(self) -> None:
        wf = workflow(POST_MERGE)
        inputs = wf[True]["workflow_dispatch"]["inputs"]
        self.assertIn("states", inputs)
        self.assertIn("states_key", inputs)
        self.assertIn("format(' states {0}', inputs.states_key)", wf["run-name"])
        self.assertEqual(wf["jobs"]["gallery-health"]["with"]["states"], "${{ needs.plan.outputs.states }}")
        self.assertEqual(wf["jobs"]["plan"]["outputs"]["states"], "${{ steps.plan.outputs.states }}")
        self.assertIn('--states "$STATES"', job_step(POST_MERGE, "plan", "Plan the suites")["run"])
        judge = job_step(POST_MERGE, "judge", "Judge the run")
        self.assertIn('--states "$STATES" --reds-dir "$GALLERY_REDS_DIR"', judge["run"])
        download = job_step(POST_MERGE, "judge", "Download gallery-health's red states")
        self.assertTrue(download.get("continue-on-error"))
        self.assertEqual(download["with"]["pattern"], "gallery-reds-*")
        self.assertEqual(download["with"]["path"], "${{ runner.temp }}/gallery-reds")
        self.assertEqual(judge["env"]["GALLERY_REDS_DIR"], "${{ runner.temp }}/gallery-reds")
        upload = job_step(GALLERY, "health", "Upload the red states for a bisect probe")
        self.assertEqual(upload["with"]["name"], "gallery-reds-${{ matrix.shard }}")
        self.assertIn("inputs.sha != ''", upload["if"])


def run_step(step: dict, env: dict[str, str], cwd: Path) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", "-c", step["run"]], cwd=cwd, env={**os.environ, **env}, capture_output=True, text=True)


class GalleryStepsTest(unittest.TestCase):
    def test_a_probe_plans_the_states_entries_alone(self) -> None:
        step = job_step(GALLERY, "plan", "Choose the entries to render")
        self.assertEqual(step["env"]["STATES"], "${{ inputs.states }}")
        with tempfile.TemporaryDirectory(prefix="gallery-plan-") as tmp:
            out = Path(tmp) / "out"
            out.write_text("")
            done = run_step(step, {"STATES": "agent-pane.composer#idle,agent-pane.composer#busy,sidebar.row#", "GITHUB_OUTPUT": str(out),
                                   "RUNNER_TEMP": tmp, "EVENT": "workflow_dispatch"}, Path(tmp))
            self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
            self.assertEqual(dict(line.split("=", 1) for line in out.read_text().splitlines()),
                             {"all": "false", "ids": "agent-pane.composer,sidebar.row"})
            done = run_step(step, {"STATES": "not a state", "GITHUB_OUTPUT": str(out), "RUNNER_TEMP": tmp}, Path(tmp))
            self.assertNotEqual(done.returncode, 0)

    def test_the_size_and_render_keep_only_the_named_states(self) -> None:
        size = job_step(GALLERY, "plan", "Size the matrix to the cases")
        render = job_step(GALLERY, "health", "Render the gallery and judge it")
        self.assertEqual(size["env"]["STATES"], "${{ inputs.states }}")
        self.assertEqual(render["env"]["STATES"], "${{ inputs.states }}")
        self.assertIn('if [ -n "${STATES:-}" ]', render["run"])
        cases = [{"params": {"entry": e, "variant": v}} for e in ("a", "a-wide") for v in ("one", "two") for _ in range(3)]
        with tempfile.TemporaryDirectory(prefix="gallery-size-") as tmp:
            root = Path(tmp)
            (root / "webviews").mkdir()
            (root / "bin").mkdir()
            (root / "cases.json").write_text(json.dumps(cases))
            (root / "bin/bun").write_text(f"#!/bin/sh\nwhile [ $# -gt 0 ]; do [ \"$1\" = --out ] && cp {root / 'cases.json'} \"$2\"; shift; done\n")
            (root / "bin/bun").chmod(0o755)
            out = root / "out"
            out.write_text("")
            env = {"PATH": f"{root / 'bin'}:{os.environ['PATH']}", "RUNNER_TEMP": tmp, "GITHUB_OUTPUT": str(out),
                   "ALL": "false", "IDS": "a", "STATES": "a#two,a-wide#one", "EVENT": "workflow_dispatch",
                   **{k: str(v) for k, v in size["env"].items() if k.startswith("MAX_")}}
            done = run_step(size, env, root)
            self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
            values = dict(line.split("=", 1) for line in out.read_text().splitlines())
            self.assertEqual(values["cases"], "6")
            self.assertEqual(json.loads(values["shards"]), [0])
            kept = json.loads((root / "manifest.json").read_text())
            self.assertEqual({(c["params"]["entry"], c["params"]["variant"]) for c in kept}, {("a", "two"), ("a-wide", "one")})

    def test_a_red_shard_names_its_states_or_whole(self) -> None:
        step = job_step(GALLERY, "health", "Name the red states for a bisect probe")
        self.assertTrue(step.get("continue-on-error"))
        self.assertIn("inputs.sha != ''", step["if"])
        self.assertIn("steps.render.outcome == 'failure'", step["if"])
        with tempfile.TemporaryDirectory(prefix="gallery-reds-") as tmp:
            root = Path(tmp)
            (root / "scripts/ci").mkdir(parents=True)
            (root / "scripts/ci/test_reds.py").write_text((ROOT / "scripts/ci/test_reds.py").read_text())
            env = {"RUNNER_TEMP": tmp, "SHARD": "4"}
            done = run_step(step, env, root)
            self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
            self.assertEqual((root / "reds/reds-4.txt").read_text(), "WHOLE\n", "no health.json: the whole render")
            (root / "health").mkdir()
            (root / "health/health.json").write_text(json.dumps({
                "fresh": [{"state": "b#two", "reason": "overflow 12px"}, {"state": "a#one", "reason": "clipped"}],
                "known": [], "slow": []}))
            done = run_step(step, env, root)
            self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
            self.assertEqual((root / "reds/reds-4.txt").read_text(), "a#one\nb#two\n")


if __name__ == "__main__":
    unittest.main()


class BunTmpdirTest(unittest.TestCase):
    """6 of 22 gallery-health shards of batch run 46058976708 failed at bun install with "EACCES accessing temporary
    directory" on hetzner runners: the bun restore step gives every later bun step a temp dir under RUNNER_TEMP."""

    def run_restore(self, tmp: str, **extra: str) -> str:
        env_file = Path(tmp) / "env"
        env_file.write_text("")
        env = {k: v for k, v in os.environ.items() if k != "BUN_TMPDIR"}
        env |= {"RUNNER_TEMP": tmp, "GITHUB_ENV": str(env_file), "RUNNER_NAME": "hetzner-1-14", "HOME": tmp,
                "GITHUB_ACTIONS": "true", **extra}
        done = subprocess.run(["bash", str(ROOT / "scripts/ci/toolchain-r2.sh"), "restore", "bun", "1.4.4"],
                              env=env, capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        return env_file.read_text()

    def test_the_bun_restore_sets_a_writable_temp_dir_on_any_runner(self) -> None:
        with tempfile.TemporaryDirectory(prefix="bun-tmpdir-") as tmp:
            self.assertEqual(self.run_restore(tmp), f"BUN_TMPDIR={tmp}/bun-tmp\n")
            self.assertTrue((Path(tmp) / "bun-tmp").is_dir())
            # One already set is kept.
            self.assertEqual(self.run_restore(tmp, BUN_TMPDIR="/somewhere"), "")
