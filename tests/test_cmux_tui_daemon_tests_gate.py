#!/usr/bin/env python3
"""The cmux_next_ daemon tests run on the shared Linux runner.

Leo, 2026-10-26: "I THOUGHT THESE COULD JUST GO ON LINUX".

cmux-tui-artifacts.yml's cmux-next-daemon-tests job gates the feat-cmux-next
channel: its pass writes tree/<key>/daemon-tests.json (publish-tree-tested),
which point-feat-channel requires. Until 2026-10-28 nightly-next promotion
required it too; now the tree-commit marker follows the publish (Leo,
2026-10-23: "we want no smoke tests"). It ran on the
owned Macs (the promote pool the Release compile also needs, then the side
lane) and queued there for 20+ minutes while nightly-next waited. None of
the cmux_next_ tests is gated to macOS, and cmux-tui.yml's Linux job runs the
whole workspace, so the gate takes Linux and its pass writes the marker.

Leo, 2026-10-27: "ok do NOT label stuff as os=linux...". The job name, its
steps and the marker name no runner OS. Markers written before that carry an
"os" field; its readers (cmux-tui-point-channel.sh, tree-commit-marker.sh
daemon-tested) check only that a marker exists, so both kinds count.

The tests that genuinely need macOS (acpmux's Keychain and Seatbelt tests,
the idle wakeup counter) run in their own workflow,
cmux-next-daemon-macos-shadow.yml: it gates nothing, and a Mac queue there
never keeps an artifacts run in progress.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
import workflow_jobs  # noqa: E402

from test_ci_tui_routes_avoid_nightly_label import (  # noqa: E402
    DAEMON_LABEL,
    LIGHT_LABEL,
    PROMOTE_LABEL,
    SIDE_LABEL,
    contexts,
    route,
)

WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui-artifacts.yml"
SHADOW_WORKFLOW = ROOT / ".github" / "workflows" / "cmux-next-daemon-macos-shadow.yml"
JOB_NAME = "cmux_next_ daemon tests"
SHADOW = "cmux-next-daemon-macos-shadow"
MAC_ONLY_TESTS = ("no_keychain", "router_no_keychain", "remote_sandbox", "remote_sandbox_canary", "idle_wakeups")


def jobs() -> dict:
    return yaml.load(WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)["jobs"]


def shadow_workflow() -> dict:
    return yaml.load(SHADOW_WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)


def sole_runs_on(job: dict) -> str:
    """The one runs-on a job without a matrix writes, as written (workflow_jobs.runs_on_cells)."""
    cells = workflow_jobs.runs_on_cells(job)
    assert cells is not None and len(cells) == 1, cells
    return cells[0]


def step(job: dict, name: str) -> dict:
    return next(s for s in job["steps"] if s.get("name") == name)


def flat(text: str) -> str:
    return " ".join(text.split())


class DaemonTestsGateTests(unittest.TestCase):
    def test_the_gate_runs_on_the_shared_linux_label_on_every_attempt(self) -> None:
        runs_on = sole_runs_on(jobs()["cmux-next-daemon-tests"])
        for context in contexts():
            expected = "cmux-linux" if context["github.repository_owner"] == "manaflow-ai" else "ubuntu-24.04"
            self.assertEqual(route(runs_on, context), expected, context)

    def test_the_job_keeps_its_id_and_setup(self) -> None:
        daemon = jobs()["cmux-next-daemon-tests"]
        # cmux_tui_publisher_testing.py finds the job by its name's prefix.
        self.assertEqual(daemon["name"], JOB_NAME)
        self.assertNotIn("runner_os", daemon["outputs"])
        for s in daemon["steps"]:
            self.assertNotIn("linux", s.get("name", "").lower(), s.get("name"))
        deps = step(daemon, "Install the build dependencies")
        self.assertIn("runner.os == 'Linux'", deps["if"])
        self.assertIn("libclang-dev", deps["run"])
        cache = step(daemon, "Cache cargo build")["with"]
        self.assertIn("'cmux-tui-linux'", cache["shared-key"])
        self.assertEqual(cache["cache-all-crates"], "true")
        self.assertIn("scripts/ci/cmux-next-daemon-tests.sh", step(daemon, "cargo test cmux_next_")["run"])
        script = (ROOT / "scripts/ci/cmux-next-daemon-tests.sh").read_text(encoding="utf-8")
        self.assertIn("--locked cmux_next_", script)
        self.assertNotIn("continue-on-error", daemon)

    def test_a_pass_writes_the_marker_without_naming_an_os(self) -> None:
        tested = jobs()["publish-tree-tested"]
        condition = flat(tested["if"])
        self.assertNotIn("runner_os", condition)
        self.assertIn("needs.cmux-next-daemon-tests.result == 'success'", condition)
        self.assertIn("needs.cmux-next-daemon-tests.outputs.key == needs.tree-preflight.outputs.key", condition)
        self.assertNotIn(SHADOW, tested["needs"])
        env = step(tested, "Write the daemon-tests marker")["env"]
        self.assertNotIn("TESTED_OS", env)
        script = (ROOT / "scripts/ci/cmux-tui-mark-daemon-tested.sh").read_text(encoding="utf-8")
        self.assertNotIn("TESTED_OS", script)
        self.assertNotIn('"os"]', script)

    def test_the_macos_shadow_is_its_own_workflow_and_gates_nothing(self) -> None:
        # Inside the artifacts run a queued Mac kept the tree owner's run in
        # progress and stalled the runs deferring to it.
        self.assertNotIn(SHADOW, jobs())
        self.assertNotIn(SHADOW, WORKFLOW.read_text(encoding="utf-8").split("\njobs:\n", 1)[1].replace(
            "cmux-next-daemon-macos-shadow.yml", ""))
        doc = shadow_workflow()
        # workflow_dispatch only since 2026-11-21 (ci-time-map: nothing waits for it).
        self.assertEqual(set(doc["on"]), {"workflow_dispatch"})
        self.assertEqual(doc["permissions"], {})
        self.assertEqual(doc["concurrency"]["cancel-in-progress"], "false")
        shadow = doc["jobs"][SHADOW]
        self.assertEqual(shadow["permissions"], {"contents": "read"})
        self.assertFalse(shadow["name"].startswith("cmux_next_ daemon tests"))
        run = flat(step(shadow, "cargo test the macOS-only daemon tests")["run"])
        for test in MAC_ONLY_TESTS:
            # cmux-tui's integration tests are one binary since #56928: idle_wakeups is a module of `--test it`.
            self.assertTrue(f"--test {test}" in run or f"--test it -- {test}::" in run, test)

    def test_the_shadow_never_takes_an_owned_pool(self) -> None:
        runs_on = sole_runs_on(shadow_workflow()["jobs"][SHADOW])
        self.assertNotIn("vars.MACOS_RUNNER", runs_on)
        self.assertIn("fromJSON(vars.RUNNER_POOLS).macos_15", runs_on)
        self.assertNotIn("inputs.", runs_on)
        for daemon in ("", DAEMON_LABEL, PROMOTE_LABEL, LIGHT_LABEL, SIDE_LABEL):
            for context in contexts(CI_NEXT_DAEMON_POOL=daemon):
                label = route(runs_on, context)
                expected = "blacksmith-6vcpu-macos-15" if context["github.repository_owner"] == "manaflow-ai" else "macos-26"
                self.assertEqual(label, expected, (daemon, context))

    def test_a_run_waiting_on_the_marker_path_skips_the_tests_once_the_tree_is_marked(self) -> None:
        # A marker-path run pending in its key's concurrency group ran the
        # tests again after the run ahead of it wrote the marker.
        daemon = jobs()["cmux-next-daemon-tests"]
        ids = [s.get("id") for s in daemon["steps"]]
        self.assertLess(ids.index("current"), ids.index("marked"))
        self.assertLess(ids.index("marked"), ids.index("key"))
        marked = daemon["steps"][ids.index("marked")]
        condition = flat(marked["if"])
        self.assertIn("--location", marked["run"])
        self.assertIn('[[ "$code" == 200 ]]', marked["run"])
        for part in ("steps.current.outputs.stale != 'true'", "github.event_name == 'push'",
                     "github.ref != 'refs/heads/main'",
                     "(needs.tree-preflight.outputs.tree_ready == 'true' || needs.tree-owner-wait.outputs.unmarked == 'true')"):
            self.assertIn(part, condition)
        # The key output stays set, so publish-tree-tested and the request still run.
        self.assertNotIn("steps.marked", str(daemon["steps"][ids.index("key")].get("if")))
        for later in daemon["steps"][ids.index("key") + 1:]:
            self.assertIn("steps.marked.outputs.marked != 'true'", str(later.get("if")), later.get("name"))

        key, legacy = "a" * 40, "b" * 40
        # The fake curl answers each key's marker with the given status (404
        # when absent) the way `-w '%{http_code}'` prints it; a redirect that
        # was not followed to a 200 must not count as a marker.
        for codes, want in (({key: 200, legacy: 200}, True), ({key: 200}, False), ({legacy: 200}, False),
                            ({}, False), ({key: 302, legacy: 302}, False), ({key: 200, legacy: 301}, False),
                            ({key: 500, legacy: 200}, False)):
            with tempfile.TemporaryDirectory() as tmp:
                curl = Path(tmp) / "curl"
                curl.write_text("#!/usr/bin/env bash\n"
                                "for arg; do url=$arg; done\n"
                                + "".join(f'[[ "$url" == */tree/{k}/daemon-tests.json\\?* ]] && {{ printf {c}; exit 0; }}\n'
                                          for k, c in sorted(codes.items()))
                                + "printf 404\n", encoding="utf-8")
                curl.chmod(0o755)
                output = Path(tmp) / "output"
                output.touch()
                env = dict(os.environ, PATH=f"{tmp}:{os.environ['PATH']}", KEY=key, LEGACY_KEY=legacy,
                           RUN_ID="1", GITHUB_RUN_ATTEMPT="1", GITHUB_OUTPUT=str(output))
                subprocess.run(["bash", "-c", marked["run"]], env=env, check=True, capture_output=True)
                self.assertEqual("marked=true" in output.read_text(encoding="utf-8"), want, codes)
    def test_every_feat_run_points_at_a_tested_tree_the_channel_skipped(self) -> None:
        # Leo, 2026-11-23: "we own/should own the in-between". The point no longer waits on one run's own tree.
        point = jobs()["point-feat-channel"]
        keep = step(point, "Point the channel at any tested tree it skipped (channel keeper)")
        self.assertEqual(flat(keep["if"]), "${{ !cancelled() }}")
        self.assertIn("cmux_tui_channel_keeper.py drive --point-only", keep["run"])
        for name in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "R2_ENDPOINT", "GH_TOKEN"):
            self.assertIn(name, keep["env"])
        checkout = next(s for s in point["steps"] if str(s.get("uses", "")).startswith("actions/checkout@"))
        self.assertGreaterEqual(int(checkout["with"]["fetch-depth"]), 300)


    def test_the_job_frees_its_own_build_need_before_the_caches_land(self) -> None:
        # Six cold runs on 2026-11-26 lost their pool runner "No space left on device" in cargo test: the
        # pool's start hook cleans only under one job's need (17 GiB) and this build writes a ~20 GiB target.
        daemon = jobs()["cmux-next-daemon-tests"]
        names = [s.get("name") for s in daemon["steps"]]
        free = step(daemon, "Free this job's build need on a pool runner")
        self.assertLess(names.index(free["name"]), names.index("Cache cargo build"))
        self.assertLess(names.index(free["name"]), names.index("Make room for the cargo build (disk floor)"))
        self.assertEqual(free["continue-on-error"], "true")
        self.assertIn("steps.marked.outputs.marked != 'true'", free["if"])
        with tempfile.TemporaryDirectory() as tmp:
            seen = Path(tmp) / "seen"
            hook = Path(tmp) / "cmux-disk-floor.sh"
            hook.write_text(f'#!/usr/bin/env bash\necho "$1 $CMUX_DISK_JOB_BYTES" > {seen}\nexit 3\n', encoding="utf-8")
            hook.chmod(0o755)
            run = free["run"].replace("/opt/cmux-disk-floor.sh", str(hook))
            env = dict(os.environ, GITHUB_WORKSPACE=tmp)
            subprocess.run(["bash", "-e", "-c", run], env=env, check=True, capture_output=True)
            phase, need = seen.read_text(encoding="utf-8").split()
            self.assertEqual(phase, "started")
            self.assertGreater(int(need), 17 << 30)
            # Off the pool (no hook) the step does nothing and passes.
            subprocess.run(["bash", "-e", "-c", free["run"].replace("/opt/cmux-disk-floor.sh", str(Path(tmp) / "absent"))],
                           env=env, check=True, capture_output=True)



TARGET_SCRIPT = ROOT / "scripts" / "ci" / "cmux-tui-test-target.sh"
# A fake df: the target's disk shows FREE_KIB_WITH_TARGET while cmux-tui/target exists, FREE_KIB_WITHOUT after.
FAKE_DF = """#!/usr/bin/env bash
path="${@: -1}"
if [[ -d "$FAKE_REPO/cmux-tui/target" ]]; then kib="$FREE_KIB_WITH_TARGET"; else kib="$FREE_KIB_WITHOUT"; fi
[[ "$path" == "$FAKE_REPO"* ]] || kib="$FREE_KIB_TMP"
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
echo "fake 999999999 1 $kib 1% /"
"""
GIB = 1024 * 1024


class DaemonTestsDiskFloorTests(unittest.TestCase):
    """Run 45737327859 (2026-11-26): a reused pool workspace ran out of disk 14 min into the build."""

    def floor(self, with_target: int, without: int, tmp: int) -> tuple[subprocess.CompletedProcess, bool]:
        with tempfile.TemporaryDirectory() as tmpdir:
            repo = Path(tmpdir) / "repo"
            (repo / "scripts" / "ci").mkdir(parents=True)
            (repo / "scripts" / "ci" / "cmux-tui-test-target.sh").write_text(TARGET_SCRIPT.read_text(encoding="utf-8"))
            (repo / "cmux-tui" / "target" / "debug" / "incremental").mkdir(parents=True)
            (repo / "cmux-tui" / "rust-toolchain.toml").write_text("[toolchain]\n")
            bin_dir = Path(tmpdir) / "bin"
            bin_dir.mkdir()
            (bin_dir / "df").write_text(FAKE_DF)
            (bin_dir / "df").chmod(0o755)
            env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", FAKE_REPO=str(repo),
                       FREE_KIB_WITH_TARGET=str(with_target * GIB), FREE_KIB_WITHOUT=str(without * GIB),
                       FREE_KIB_TMP=str(tmp * GIB), TMPDIR=str(Path(tmpdir) / "elsewhere"),
                       GITHUB_ACTIONS="true", GITHUB_REPOSITORY="manaflow-ai/cmux")
            env.pop("CARGO_TARGET_DIR", None)
            result = subprocess.run(["bash", str(repo / "scripts" / "ci" / "cmux-tui-test-target.sh"), "floor"],
                                    env=env, capture_output=True, text=True, timeout=60)
            return result, (repo / "cmux-tui" / "target").is_dir()

    def test_enough_disk_keeps_the_warm_target(self) -> None:
        result, kept = self.floor(with_target=80, without=80, tmp=80)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(kept)

    def test_a_full_disk_drops_the_leftover_target_and_builds(self) -> None:
        result, kept = self.floor(with_target=3, without=60, tmp=80)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(kept, result.stdout)

    def test_a_disk_still_full_after_cleaning_fails_fast(self) -> None:
        result, _ = self.floor(with_target=3, without=5, tmp=80)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("under the floor", result.stderr)

    def test_the_job_runs_the_floor_before_any_cache_restore(self) -> None:
        names = [s.get("name") for s in jobs()["cmux-next-daemon-tests"]["steps"]]
        floor = names.index("Make room for the cargo build (disk floor)")
        self.assertLess(floor, names.index("Cache cargo build"))
        self.assertLess(floor, names.index("Restore the cargo build from the CI cache bucket"))
        self.assertIn("cmux-tui-test-target.sh floor", step(jobs()["cmux-next-daemon-tests"], names[floor])["run"])


if __name__ == "__main__":
    unittest.main()
