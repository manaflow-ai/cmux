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
import re
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


class ExportGuardBehavior(unittest.TestCase):
    """Execute the actual shell and evaluate its workflow consumers, without running Swift."""

    def expression(self, expression: str, values: dict[str, str]) -> bool:
        expression = expression.removeprefix("${{ ").removesuffix(" }}")
        expression = re.sub(r"steps\.[a-z-]+\.(?:outputs\.)?[a-z-]+",
                            lambda match: repr(values.get(match[0], "")), expression)
        return bool(eval(expression.replace("&&", " and ").replace("||", " or "), {"__builtins__": {}}))

    def guard(self, *, actions: str = "false", settings: str = "false",
              action_outcome: str = "skipped", settings_outcome: str = "skipped",
              action_exports: str = "", settings_exports: str = "",
              artifact: str = "missing", settings_error: str = "", upload_outcome: str = "success") -> tuple:
        guard = step(PR, "action-exports", "Require generated exports")
        with tempfile.TemporaryDirectory() as tmp:
            temp = Path(tmp)
            if artifact != "missing":
                (temp / "action-exports").mkdir()
            if artifact == "file":
                (temp / "action-exports/export.json").write_text("changed\n")
            (temp / "settings-exports.txt").write_text(settings_error)
            output = temp / "output"
            result = run_step(guard["run"], temp, {
                "RUNNER_TEMP": tmp, "GITHUB_OUTPUT": str(output),
                "ACTIONS_REQUESTED": actions, "SETTINGS_REQUESTED": settings,
                "ACTIONS_OUTCOME": action_outcome, "SETTINGS_OUTCOME": settings_outcome,
                "ACTIONS_EXPORTS": action_exports, "SETTINGS_EXPORTS": settings_exports,
            })
            guard_outputs = dict(line.split("=", 1) for line in output.read_text().splitlines()) if output.exists() else {}
        values = {
            "steps.require-exports.outcome": "success" if result.returncode == 0 else "failure",
            "steps.require-exports.outputs.exports": guard_outputs.get("exports", ""),
            "steps.regenerate.outcome": action_outcome,
            "steps.settings.outcome": settings_outcome,
        }
        upload = next(s for s in PR["jobs"]["action-exports"]["steps"]
                      if s.get("uses", "").startswith("actions/upload-artifact@"))
        should_upload = self.expression(upload["if"], values)
        values["steps.upload-exports.outcome"] = upload_outcome if should_upload else "skipped"
        outputs = {key: self.expression(expr, values)
                   for key, expr in PR["jobs"]["action-exports"]["outputs"].items()}
        return result, outputs, should_upload

    def test_successful_requested_exports_can_be_verified_noops(self):
        for actions, settings in (("true", "false"), ("false", "true"), ("true", "true")):
            with self.subTest(actions=actions, settings=settings):
                result, outputs, upload = self.guard(
                    actions=actions, settings=settings,
                    action_outcome="success" if actions == "true" else "skipped",
                    settings_outcome="success" if settings == "true" else "skipped")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("::notice::", result.stdout)
                self.assertIn("no changed files", result.stdout)
                self.assertFalse(upload)
                self.assertEqual(outputs, {"exports": False, "verified": actions == "true",
                                           "settings-verified": settings == "true"})

    def test_requested_exporter_must_complete_successfully(self):
        for exporter in ("action", "settings"):
            for outcome in ("failure", "skipped", "cancelled"):
                with self.subTest(exporter=exporter, outcome=outcome):
                    kwargs = ({"actions": "true", "action_outcome": outcome, "action_exports": "true"}
                              if exporter == "action" else
                              {"settings": "true", "settings_outcome": outcome, "settings_exports": "true"})
                    result, outputs, upload = self.guard(**kwargs, artifact="file")
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(exporter + " exporter", result.stdout)
                    self.assertFalse(upload)
                    self.assertFalse(any(outputs.values()))

    def test_successful_changed_exports_upload_and_advertise_the_artifact(self):
        for actions, settings in (("true", "false"), ("false", "true"), ("true", "true")):
            for action_changed, settings_changed in ((True, False), (False, True), (True, True)):
                if (action_changed and actions != "true") or (settings_changed and settings != "true"):
                    continue
                with self.subTest(actions=actions, settings=settings, changed=(action_changed, settings_changed)):
                    result, outputs, upload = self.guard(
                        actions=actions, settings=settings,
                        action_outcome="success" if actions == "true" else "skipped",
                        settings_outcome="success" if settings == "true" else "skipped",
                        action_exports="true" if action_changed else "",
                        settings_exports="true" if settings_changed else "", artifact="file")
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertTrue(upload)
                    self.assertEqual(outputs, {"exports": True, "verified": actions == "true",
                                               "settings-verified": settings == "true"})

    def test_failed_or_skipped_upload_withholds_changed_exports_and_verification(self):
        for outcome in ("failure", "skipped", "cancelled"):
            with self.subTest(upload_outcome=outcome):
                result, outputs, upload = self.guard(
                    actions="true", settings="true", action_outcome="success", settings_outcome="success",
                    action_exports="true", artifact="file", upload_outcome=outcome)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue(upload)
                self.assertFalse(any(outputs.values()))

    def test_failed_settings_export_captures_its_missing_input_from_stderr(self):
        regenerate = step(PR, "action-exports", "Regenerate the settings exports")
        missing = "schemas/settings-export/" + "settings-schema.sources.sha256"
        with tempfile.TemporaryDirectory() as tmp:
            temp = Path(tmp)
            exporter = temp / "autofix/scripts/cmux-next/regenerate-settings-exports.sh"
            exporter.parent.mkdir(parents=True)
            exporter.write_text(f"#!/usr/bin/env bash\necho '::error::{missing} missing' >&2\nexit 1\n")
            exporter.chmod(0o755)
            result = run_step(regenerate["run"], temp,
                              {"RUNNER_TEMP": tmp, "GITHUB_OUTPUT": str(temp / "output")})
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(missing, (temp / "settings-exports.txt").read_text())

    def test_advertised_exports_with_missing_or_empty_artifact_fail(self):
        for artifact in ("missing", "empty"):
            with self.subTest(artifact=artifact):
                result, outputs, upload = self.guard(actions="true", action_outcome="success",
                                                    action_exports="true", artifact=artifact)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("uploaded no files", result.stdout)
                self.assertFalse(upload)
                self.assertFalse(any(outputs.values()))

    def test_mixed_success_and_missing_settings_input_cannot_advertise_an_artifact(self):
        missing = "schemas/settings-export/" + "settings-schema.sources.sha256"
        result, outputs, upload = self.guard(
            actions="true", settings="true", action_outcome="success", action_exports="true",
            settings_outcome="failure", artifact="file",
            settings_error=f"::error::{missing} was not written by the settings export\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(missing, result.stdout)
        self.assertFalse(upload)
        self.assertFalse(any(outputs.values()))


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
                    "GRAPH": "false", "STRINGS": "false", "SDK": "false", "CAPABILITIES": "false",
                    "SHORTCUTS": "false", "APPHOST": "false",
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


class FleetBundleHandsBackEveryExport(unittest.TestCase):
    """2026-10-25: a lane ran regenerate-settings-exports.sh as a fleet step for #24923. A step returns one
    --artifact file, so each run handed back one docs/mdm file, and nothing wrote the docs settings reference
    or the defaults snapshot. An OUT ending in .patch (the controller takes one relative OUT) packs every
    regenerated file into that one patch; a folder OUT gets what the bots expect and nothing more."""

    EXPORTS = (
        "docs/mdm/com.manaflow.cmux.json", "docs/mdm/com.manaflow.cmux.plist", "docs/mdm/com.manaflow.cmux.intune.plist",
        "docs/mdm/cmux-example.mobileconfig", "docs/mdm/managed-preferences.md",
        "schemas/settings/settings-schema.json",
    )
    FOLLOWERS = ("web/data/next-docs/settings-reference.generated.json", "schemas/defaults/cmux-next.json")

    def repo(self, rewrites: bool = True) -> tuple[Path, dict[str, str]]:
        work = Path(tempfile.mkdtemp())
        repo, bin_dir = work / "repo", work / "bin"
        for rel in ("scripts/cmux-next/regenerate-settings-exports.sh", "scripts/cmux-next/lib/fleet-only.sh",
                    "scripts/cmux-next/settings-exports.txt"):
            (repo / rel).parent.mkdir(parents=True, exist_ok=True)
            (repo / rel).write_bytes((ROOT / rel).read_bytes())
            (repo / rel).chmod(0o755)
        stubs = {
            "scripts/cmux-next/compile-string-catalogs.sh": "#!/usr/bin/env bash\nexit 0\n",
            "scripts/ci/defaults_guard.py": (
                "import sys\nfrom pathlib import Path\n"
                "if sys.argv[1] == 'snapshot': Path('schemas/defaults/cmux-next.json').write_text('new\\n')\n"),
            "web/scripts/export-next-docs.ts": "",
            "Packages/macOS/CmuxNext/Package.swift": "",
        }
        for rel, text in stubs.items():
            (repo / rel).parent.mkdir(parents=True, exist_ok=True)
            (repo / rel).write_text(text)
            (repo / rel).chmod(0o755)
        for rel in self.EXPORTS + self.FOLLOWERS:
            (repo / rel).parent.mkdir(parents=True, exist_ok=True)
            (repo / rel).write_text("old\n")
        bin_dir.mkdir()
        # swift test writes the exports from the package directory, as the export tests do.
        (bin_dir / "swift").write_text(
            "#!/usr/bin/env bash\n"
            'if [[ " $* " == *" --show-bin-path "* ]]; then echo /nonexistent; exit 0; fi\n'
            '[[ "$1" == test ]] || exit 0\n'
            "for f in " + " ".join(self.EXPORTS if rewrites else self.EXPORTS[1:])
            + '; do echo new > "../../../$f"; done\n')
        (bin_dir / "bun").write_text(
            '#!/usr/bin/env bash\necho "$*" > "$(git rev-parse --show-toplevel)/../bun-args"\n'
            "echo new > web/data/next-docs/settings-reference.generated.json\n")
        for tool in ("swift", "bun"):
            (bin_dir / tool).chmod(0o755)
        git = ["git", "-C", str(repo)]
        subprocess.run(git + ["init", "-q"], check=True)
        subprocess.run(git + ["add", "-A"], check=True)
        subprocess.run(git + ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "base"], check=True)
        env = {"PATH": f"{bin_dir}:{os.environ['PATH']}", "CMUX_CI_STEP_KEY": "test"}
        return repo, env

    def run_script(self, repo: Path, env: dict[str, str], *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(["bash", "scripts/cmux-next/regenerate-settings-exports.sh", *args], cwd=repo,
                              env={**os.environ, **env}, capture_output=True, text=True)

    def test_the_bundle_holds_every_export_and_the_files_that_follow_them(self):
        repo, env = self.repo()
        result = self.run_script(repo, env, "settings-exports.patch")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((repo.parent / "bun-args").read_text().split(), ["web/scripts/export-next-docs.ts", "--settings"])
        patch = repo / "settings-exports.patch"
        touched = subprocess.run(["git", "-C", str(repo), "apply", "--numstat", str(patch)], capture_output=True,
                                 text=True, check=True).stdout.split()[2::3]
        self.assertEqual(sorted(touched), sorted(self.EXPORTS + self.FOLLOWERS))
        # It applies on the step's commit.
        subprocess.run(["git", "-C", str(repo), "checkout", "-q", "--", "."], check=True)
        subprocess.run(["git", "-C", str(repo), "apply", "--index", str(patch)], check=True)
        for rel in self.EXPORTS + self.FOLLOWERS:
            self.assertEqual((repo / rel).read_text(), "new\n", rel)

    def test_without_the_bundle_the_bots_get_only_the_exports(self):
        repo, env = self.repo()
        result = self.run_script(repo, env, ".out")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((repo.parent / "bun-args").exists())
        for rel in self.FOLLOWERS:
            self.assertEqual((repo / rel).read_text(), "old\n", rel)
        self.assertEqual(sorted(str(p.relative_to(repo / ".out")) for p in (repo / ".out").rglob("*") if p.is_file()),
                         sorted(self.EXPORTS))

    def test_an_export_the_tests_did_not_rewrite_writes_no_bundle(self):
        """The stamp is gone, so a failed regeneration is caught by the marker instead: an export test
        that failed before it wrote leaves the old copy, which is not a fresh export."""
        repo, env = self.repo(rewrites=False)
        result = self.run_script(repo, env, "settings-exports.patch")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not rewrite", result.stdout + result.stderr)
        self.assertFalse((repo / "settings-exports.patch").exists())


if __name__ == "__main__":
    unittest.main()
