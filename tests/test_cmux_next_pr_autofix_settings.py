#!/usr/bin/env python3
"""A pull request that changes the Settings sources gets its settings exports from the PR autofix, and a
settings-only regeneration never rewrites the files that follow the action exports.

2026-10-19: #21814 got an autofix commit that dropped paletteKey.toggleActions from
web/data/cmux-shortcuts.generated.json. The PR changed only Settings sources; its Mac job regenerated the
settings exports into the action-exports artifact, and the repair step took any artifact as "the action
exports were regenerated", so it rewrote the docs shortcuts and the app-host files from the committed
plans/cmux-next/action-surfaces.json, which on that base was older than the committed shortcuts copy.
The shortcuts and app-host files follow the action exports only when this run regenerated them.

The step scripts run here as the workflows run them, with the generators stubbed: no network, no Mac.
"""
from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
PR = yaml.safe_load((ROOT / ".github/workflows/cmux-next-pr-autofix.yml").read_text())
BASE = yaml.safe_load((ROOT / ".github/workflows/cmux-next-base-autofix.yml").read_text())
SETTINGS_EXPORTS = (
    "docs/mdm/com.manaflow.cmux.json",
    "schemas/settings/settings-schema.json",
    "schemas/settings-export/settings-schema.sources.sha256",
)


def step(doc: dict, job: str, name: str) -> dict:
    return next(s for s in doc["jobs"][job]["steps"] if s.get("name") == name)


def run_step(script: str, cwd: Path, env: dict[str, str]) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", "-e", "-c", script], cwd=cwd, env={**os.environ, **env},
                          capture_output=True, text=True)


# A base-autofix.sh stand-in: records its arguments and names the flags the workflows grep for.
STUB_AUTOFIX = """#!/usr/bin/env bash
# --app-host) --unverified-exports) --unverified-settings-exports)
printf '%s\\n' "$@" > "$ARGS_OUT"
"""


class SettingsExportsRegenerateOnPullRequests(unittest.TestCase):
    def test_the_settings_area_starts_the_mac_job(self):
        areas = PR["jobs"]["action-areas"]
        self.assertIn("settings", areas["outputs"])
        self.assertIn("settings=", step(PR, "action-areas", "Changed areas")["run"])
        self.assertIn("needs.action-areas.outputs.settings == 'true'", PR["jobs"]["action-exports"]["if"])

    def test_the_mac_job_regenerates_the_settings_exports_into_the_artifact(self):
        regenerate = step(PR, "action-exports", "Regenerate the settings exports")
        self.assertEqual(regenerate["if"], "needs.action-areas.outputs.settings == 'true'")
        self.assertIn("regenerate-settings-exports.sh", regenerate["run"])
        outputs = PR["jobs"]["action-exports"]["outputs"]
        self.assertIn("steps.settings.outputs.exports", outputs["exports"])
        self.assertEqual(outputs["settings-verified"], "${{ steps.settings.outcome == 'success' }}")

        work = Path(tempfile.mkdtemp())
        temp = work / "runner-temp"
        autofix = temp / "autofix/scripts/cmux-next"
        autofix.mkdir(parents=True)
        stub = autofix / "regenerate-settings-exports.sh"
        stub.write_text("#!/usr/bin/env bash\nset -e\nfor f in " + " ".join(SETTINGS_EXPORTS) +
                        '; do mkdir -p "$1/$(dirname "$f")"; echo new > "$1/$f"; echo "regenerated: $f"; done\n')
        stub.chmod(0o755)
        output = work / "github-output"
        result = run_step(regenerate["run"], work, {"RUNNER_TEMP": str(temp), "GITHUB_OUTPUT": str(output)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("exports=true", output.read_text())
        for path in SETTINGS_EXPORTS:
            self.assertEqual((temp / "action-exports" / path).read_text(), "new\n", path)

    def test_the_repair_copies_them_in_and_rewrites_the_defaults_snapshot(self):
        download = step(PR, "repair", "Download the regenerated action exports")
        self.assertIn("needs.action-exports.outputs.exports == 'true'", download["if"])
        env = step(PR, "repair", "Repair")["env"]
        self.assertIn("needs.action-areas.outputs.settings", env["SETTINGS"])
        self.assertEqual(env["SETTINGS_VERIFIED"], "${{ needs.action-exports.outputs.settings-verified }}")


class SettingsOnlyArtifactLeavesTheActionFollowers(unittest.TestCase):
    """The docs shortcuts and app-host files are rewritten from action-surfaces.json: only when this run
    regenerated it (or the pull request changed their own inputs), never because settings exports arrived."""

    def repair_args(self, doc: dict, job: str, artifact: tuple[str, ...], **env: str) -> list[str]:
        work = Path(tempfile.mkdtemp())
        temp = work / "runner-temp"
        for path in artifact:
            (temp / "action-exports" / path).parent.mkdir(parents=True, exist_ok=True)
            (temp / "action-exports" / path).write_text("new\n")
        for stub in (temp / "autofix/scripts/cmux-next/base-autofix.sh", work / "scripts/cmux-next/base-autofix.sh"):
            stub.parent.mkdir(parents=True, exist_ok=True)
            stub.write_text(STUB_AUTOFIX)
            stub.chmod(0o755)
        # The base Repair step runs base-autofix-repair.sh (#23315), which calls the base-autofix.sh beside it.
        repair = work / "scripts/cmux-next/base-autofix-repair.sh"
        repair.write_text((ROOT / "scripts/cmux-next/base-autofix-repair.sh").read_text())
        repair.chmod(0o755)
        # The step's env names its runner paths; the test gives them under its own runner temp.
        step_env = {key: value.replace("${{ runner.temp }}", str(temp))
                    for key, value in (step(doc, job, "Repair").get("env") or {}).items()
                    if isinstance(value, str) and value.startswith("${{ runner.temp }}")}
        args_out = work / "args"
        base_env = {"RUNNER_TEMP": str(temp), "GITHUB_WORKSPACE": str(work), "GITHUB_STEP_SUMMARY": str(work / "summary"),
                    "GITHUB_SHA": "0" * 40, "AUTOFIX": str(temp / "autofix/scripts/cmux-next"), "ARGS_OUT": str(args_out),
                    "GRAPH": "false", "STRINGS": "false", "SDK": "false", "SHORTCUTS": "false", "APPHOST": "false",
                    "ACTIONS": "false", "EXPORTS_VERIFIED": "true", "SETTINGS": "true", "SETTINGS_VERIFIED": "true",
                    "RATCHETS": "false", "CLOUD": "false", "GHOSTTY": "false", "FMT": "false"}
        result = run_step(step(doc, job, "Repair")["run"], work, {**base_env, **step_env, **env})
        self.assertEqual(result.returncode, 0, result.stderr)
        return args_out.read_text().split("\n")

    def test_settings_exports_alone(self):
        # The base reports the skipped action step as verified (outcome != failure); the PR does not.
        for doc, job, verified in ((PR, "repair", "false"), (BASE, "autofix", "true")):
            with self.subTest(job=job):
                args = self.repair_args(doc, job, SETTINGS_EXPORTS, EXPORTS_VERIFIED=verified)
                self.assertIn("--generated", args)
                self.assertNotIn("--docs-shortcuts", args)
                self.assertNotIn("--app-host", args)
                self.assertNotIn("--unverified-settings-exports", args)

    def test_regenerated_action_exports_bring_the_followers(self):
        for doc, job in ((PR, "repair"), (BASE, "autofix")):
            with self.subTest(job=job):
                args = self.repair_args(doc, job, ("plans/cmux-next/action-surfaces.json", *SETTINGS_EXPORTS),
                                        ACTIONS="true", EXPORTS_VERIFIED="true")
                self.assertIn("--docs-shortcuts", args)
                self.assertIn("--app-host", args)

    def test_a_pull_request_that_changes_the_shortcut_inputs_still_rewrites_them(self):
        for doc, job in ((PR, "repair"), (BASE, "autofix")):
            with self.subTest(job=job):
                args = self.repair_args(doc, job, SETTINGS_EXPORTS, SHORTCUTS="true")
                self.assertIn("--docs-shortcuts", args)


if __name__ == "__main__":
    unittest.main()
