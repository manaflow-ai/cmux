#!/usr/bin/env python3
"""The cmux_next_ daemon tests that gate nightly-next run on Blacksmith 32 vCPU.

Leo, 2026-10-26: "I THOUGHT THESE COULD JUST GO ON LINUX".

cmux-tui-artifacts.yml's cmux-next-daemon-tests job is the nightly-next
promotion gate: its pass writes tree/<key>/daemon-tests.json
(publish-tree-tested), which request-nightly-next.sh requires. It ran on the
owned Macs (the promote pool the Release compile also needs, then the side
lane) and queued there for 20+ minutes while nightly-next waited. None of
the cmux_next_ tests is gated to macOS, and cmux-tui.yml's Linux job runs the
whole workspace, so the gate takes Blacksmith at 32 vCPU on every event and
attempt, and its pass writes the marker.

Leo, 2026-10-27: "ok do NOT label stuff as os=linux...". The job name, its
steps and the marker name no runner OS. Markers written before that carry an
"os" field; the promote reader checks only that a marker exists, so both
kinds promote (scripts/cmux-next/tests/request-nightly-next.test.sh).

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

from test_ci_tui_routes_avoid_nightly_label import (  # noqa: E402
    DAEMON_LABEL,
    LIGHT_LABEL,
    PIN_LABEL,
    PROMOTE_LABEL,
    SIDE_LABEL,
    contexts,
    route,
)

WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui-artifacts.yml"
SHADOW_WORKFLOW = ROOT / ".github" / "workflows" / "cmux-next-daemon-macos-shadow.yml"
GATE_LABEL = "blacksmith-32vcpu-ubuntu-2404"
JOB_NAME = "cmux_next_ daemon tests"
SHADOW = "cmux-next-daemon-macos-shadow"
MAC_ONLY_TESTS = ("no_keychain", "router_no_keychain", "remote_sandbox", "remote_sandbox_canary", "idle_wakeups")


def jobs() -> dict:
    return yaml.load(WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)["jobs"]


def shadow_workflow() -> dict:
    return yaml.load(SHADOW_WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)


def step(job: dict, name: str) -> dict:
    return next(s for s in job["steps"] if s.get("name") == name)


def flat(text: str) -> str:
    return " ".join(text.split())


class DaemonTestsGateTests(unittest.TestCase):
    def test_the_gate_runs_on_blacksmith_32_vcpu_whatever_the_pool_variables_say(self) -> None:
        runs_on = jobs()["cmux-next-daemon-tests"]["runs-on"]
        for overrides in ({}, {"CI_NEXT_DAEMON_POOL": DAEMON_LABEL}, {"CI_PIN_DAEMON_POOL": PIN_LABEL},
                          {"CI_PR_POOL_OWNED": ""}, {"CI_NEXT_PROMOTE_POOL": ""}):
            for context in contexts(**overrides):
                context["inputs.macos_runner"] = "blacksmith-6vcpu-macos-26"
                label = route(runs_on, context)
                if context["github.repository_owner"] != "manaflow-ai":
                    self.assertEqual(label, "ubuntu-24.04", context)
                else:
                    self.assertEqual(label, GATE_LABEL, (overrides, context))

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
        self.assertIn("cmux_next_", step(daemon, "cargo test cmux_next_")["run"])
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
        self.assertEqual(set(doc["on"]), {"push", "workflow_dispatch"})
        self.assertEqual(doc["on"]["push"]["branches"], ["feat-cmux-next"])
        self.assertEqual(doc["permissions"], {})
        self.assertEqual(doc["concurrency"]["cancel-in-progress"], "false")
        shadow = doc["jobs"][SHADOW]
        self.assertEqual(shadow["permissions"], {"contents": "read"})
        self.assertFalse(shadow["name"].startswith("cmux_next_ daemon tests"))
        run = flat(step(shadow, "cargo test the macOS-only daemon tests")["run"])
        for test in MAC_ONLY_TESTS:
            self.assertIn(f"--test {test}", run)

    def test_the_shadow_never_takes_an_owned_pool(self) -> None:
        runs_on = shadow_workflow()["jobs"][SHADOW]["runs-on"]
        self.assertNotIn("vars.", runs_on)
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

if __name__ == "__main__":
    unittest.main()
