#!/usr/bin/env python3
"""The nightly-next canary's mode toggle and its one-week auto flip
(scripts/ci/nightly_next_canary_mode.py), and that both canaries use it."""
from __future__ import annotations

import datetime as dt
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/nightly_next_canary_mode.py"
spec = importlib.util.spec_from_file_location("canary_mode", SCRIPT)
mode = importlib.util.module_from_spec(spec)
sys.modules["canary_mode"] = mode
spec.loader.exec_module(mode)

UTC = dt.timezone.utc
AFTER = "2026-10-27T16:00:00Z"
FLIP = dt.datetime(2026, 10, 27, 16, tzinfo=UTC)


def at(days: float) -> dt.datetime:
    return FLIP + dt.timedelta(days=days)


def never_read(_since):
    raise AssertionError("the report week must not be read")


def entries(*items):
    return lambda _since: list(items)


class ToggleTests(unittest.TestCase):
    def test_explicit_values_win_and_read_nothing(self):
        for value in ("report", "enforce", "off", " Enforce "):
            got, why = mode.resolve(value, AFTER, at(30), never_read)
            self.assertEqual(got, value.strip().lower())
            self.assertIn("NIGHTLY_NEXT_CANARY=", why)

    def test_unknown_value_is_refused(self):
        with self.assertRaises(mode.BadValue):
            mode.resolve("enfroce", AFTER, at(1), never_read)

    def test_never_keeps_report(self):
        self.assertEqual(mode.resolve("", "never", at(100), never_read)[0], "report")


class AutoFlipTests(unittest.TestCase):
    def test_before_the_date_reports(self):
        for value in ("", "auto"):
            got, why = mode.resolve(value, AFTER, at(-0.01), never_read)
            self.assertEqual(got, "report")
            self.assertIn("until 2026-10-27T16:00Z", why)

    def test_after_a_clean_week_enforces(self):
        older = (at(-8), "cmux NEXT build 1 failed the canary twice: run")  # before the week
        later = (at(1), "cmux NEXT build 3 failed the canary twice: run")   # after the flip
        chatter = (at(-2), "looked at it, flake")                            # not a failure entry
        got, why = mode.resolve("", AFTER, at(2), entries(older, later, chatter))
        self.assertEqual(got, "enforce", why)

    def test_a_failure_in_the_report_week_holds_report(self):
        bad = (at(-3), "cmux NEXT build 3947430561301 failed the canary twice: https://x")
        got, why = mode.resolve("auto", AFTER, at(5), entries(bad))
        self.assertEqual(got, "report")
        self.assertIn("1 build(s)", why)
        self.assertIn("set NIGHTLY_NEXT_CANARY=enforce", why)

    def test_the_decision_does_not_flap_later(self):
        bad = (at(-3), "cmux NEXT build 9 failed the canary twice")
        for later in (1, 10, 100):
            self.assertEqual(mode.resolve("", AFTER, at(later), entries(bad))[0], "report")

    def test_a_read_failure_stays_in_report(self):
        def broken(_since):
            raise OSError("HTTP 502")
        got, why = mode.resolve("", AFTER, at(1), broken)
        self.assertEqual(got, "report")
        self.assertIn("HTTP 502", why)

    def test_default_date_is_used_when_empty(self):
        default = mode.parse_when("")
        self.assertEqual(default, mode.parse_when(mode.DEFAULT_ENFORCE_AFTER))
        self.assertEqual(mode.resolve("", "", default - dt.timedelta(minutes=1), never_read)[0], "report")

    def test_date_only_values_are_utc_midnight(self):
        self.assertEqual(mode.parse_when("2026-11-01"), dt.datetime(2026, 11, 1, tzinfo=UTC))
        with self.assertRaises(mode.BadValue):
            mode.parse_when("next week")


class CliTests(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), "resolve", *args],
                              capture_output=True, text=True, env={"PATH": "/usr/bin:/bin"})

    def test_prints_github_outputs(self):
        out = self.run_cli("--value", "", "--enforce-after", AFTER, "--now", "2026-10-21T00:00:00Z")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertRegex(out.stdout, r"(?m)^mode=report$")
        self.assertRegex(out.stdout, r"(?m)^why=auto: report until ")

    def test_typo_exits_2(self):
        self.assertEqual(self.run_cli("--value", "on").returncode, 2)


class WiringTests(unittest.TestCase):
    canary = (ROOT / ".github/workflows/nightly-next-canary.yml").read_text()
    nightly = (ROOT / ".github/workflows/nightly.yml").read_text()

    def test_post_publication_verifier_uses_the_compatibility_mode(self):
        self.assertIn("scripts/ci/nightly_next_canary_mode.py resolve", self.canary)
        self.assertIn("NIGHTLY_NEXT_CANARY_ENFORCE_AFTER: ${{ vars.NIGHTLY_NEXT_CANARY_ENFORCE_AFTER }}", self.canary)
        self.assertNotIn("smoke-signed-app-cli.sh", self.canary)
        self.assertNotIn("nightly-next-rollback.yml", self.canary)

    def test_pre_publication_runtime_canary_is_removed(self):
        block = self.nightly[self.nightly.index("  verify-signed-nightly:"):]
        block = block[:block.index("\n  verify-final-dmg-nightly:")] if "\n  verify-final-dmg-nightly:" in block else block
        self.assertNotIn("nightly_next_canary_mode.py resolve", block)
        self.assertNotIn("smoke-signed-app-cli.sh", block)
        self.assertNotIn("smoke-launch-macos-app.sh", block)
        self.assertNotIn("issues: read", block)
        self.assertIn("verify-diff-sidecar-artifact.sh", block)


class VerdictDurabilityTests(unittest.TestCase):
    """A scheduled tick marks a build checked only once its verdict is durable:
    a runner or download error records no verdict, and a failed dispatch of
    nightly-next-verdict.yml fails the run and leaves the build for the next tick."""

    jobs = yaml.safe_load((ROOT / ".github/workflows/nightly-next-canary.yml").read_text())["jobs"]

    def step(self, job: str, name: str) -> dict:
        steps = [s for s in self.jobs[job]["steps"] if s.get("name") == name]
        self.assertEqual(len(steps), 1, f"{job}: {name}")
        return steps[0]

    def run_step(self, job: str, name: str, env: dict[str, str], outcomes: dict[str, str] | None = None,
                 path: Path | None = None) -> tuple[subprocess.CompletedProcess, str]:
        script = self.step(job, name)["run"]
        for step_id, outcome in (outcomes or {}).items():
            script = script.replace("${{ steps.%s.outcome }}" % step_id, outcome)
        self.assertNotIn("${{", script)
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "output"
            output.touch()
            full = {"PATH": f"{path}:/usr/bin:/bin" if path else "/usr/bin:/bin", "GITHUB_OUTPUT": str(output),
                    "GITHUB_STEP_SUMMARY": str(Path(tmp) / "summary"), "GITHUB_REPOSITORY": "manaflow-ai/cmux",
                    "GITHUB_RUN_ID": "1", **env}
            # A run step with no `shell:` runs under GitHub's default bash, with errexit on.
            step_file = Path(tmp) / "step.sh"
            step_file.write_text(script)
            result = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", str(step_file)],
                                    env=full, cwd=tmp, capture_output=True, text=True, timeout=60)
            return result, output.read_text()

    def record(self, app: str, app_class: str = "") -> str:
        result, output = self.run_step("canary", "Record the static artifact verdict",
                                       {"BUILD": "4100", "APP_OUTCOME": app, "APP_CLASS": app_class}, {"app": app})
        self.assertEqual(result.returncode, 0, result.stderr)
        return output

    def test_only_the_artifact_check_decides_the_verdict(self):
        self.assertIn("verdict=pass", self.record("success"))
        self.assertIn("verdict=fail", self.record("failure", "invalid"))
        # A failure the step did not class as an artifact rejection is none.
        self.assertNotIn("verdict=", self.record("failure"))

    def test_a_runner_or_download_error_records_no_verdict(self):
        # Select Xcode or the download failed, so the artifact step never ran.
        for outcome in ("skipped", "cancelled"):
            self.assertNotIn("verdict=", self.record(outcome), outcome)

    def artifact(self, tools: dict[str, str], length: str = "5", runner_temp: str = "") -> tuple[str, str]:
        """Run "Check Gatekeeper and the notary tickets" against stub Apple tools
        (name -> bash body; a missing name is a tool that is not installed) and
        a 5-byte DMG, then feed its outcome to the recorder. Returns the
        artifact step's outcome and the recorder's GITHUB_OUTPUT. RUNNER_TEMP
        names a directory under the temporary one when given."""
        with tempfile.TemporaryDirectory() as root:
            tmp = str(Path(root) / runner_temp) if runner_temp else root
            Path(tmp).mkdir(parents=True, exist_ok=True)
            bin_dir = Path(tmp) / "bin"
            bin_dir.mkdir()
            (Path(tmp) / "canary.dmg").write_bytes(b"12345")
            # python3 runs nightly_next_artifact_check.py; it passes unless a test stubs it.
            stubs = {"stat": 'echo "$(wc -c < "${@: -1}" | tr -d " ")"', "python3": "exit 0", **tools}
            for name, body in stubs.items():
                (bin_dir / name).write_text(f"#!/bin/bash\n{body}\n")
                (bin_dir / name).chmod(0o755)
            result, output = self.run_step("canary", "Check Gatekeeper and the notary tickets",
                                           {"BUILD": "4100", "DMG_LENGTH": length, "RUNNER_TEMP": tmp,
                                            "DMG_ED_SIGNATURE": "c2ln", "SOURCE_COMMIT": "a" * 40,
                                            "SOURCE_COMMIT_FROM": "its signed release notes"}, path=bin_dir)
            self.step_log = result.stdout + result.stderr
            outcome = "success" if result.returncode == 0 else "failure"
            app_class = next((l.split("=", 1)[1] for l in output.splitlines() if l.startswith("class=")), "")
            recorded, verdict_output = self.run_step("canary", "Record the static artifact verdict",
                                                     {"BUILD": "4100", "APP_OUTCOME": outcome, "APP_CLASS": app_class},
                                                     {"app": outcome})
            self.assertEqual(recorded.returncode, 0, recorded.stderr)
            return outcome, verdict_output

    # nightly_next_artifact_check.py SUBCOMMAND (python3 -I SCRIPT SUBCOMMAND ...) runs BODY; others pass.
    @staticmethod
    def artifact_check(subcommand: str, body: str) -> str:
        return f'if [ "$3" = {subcommand} ]; then {body}; fi; exit 0'

    # hdiutil attach that mounts a DMG holding one app at the -mountpoint.
    ATTACH = 'while [ $# -gt 0 ]; do [ "$1" = -mountpoint ] && mkdir -p "$2/cmux NEXT.app"; shift; done'

    def assert_no_verdict(self, tools: dict[str, str], why: str, reason: str = "could not be checked") -> None:
        outcome, output = self.artifact(tools)
        self.assertEqual(outcome, "failure", why)
        self.assertNotIn("verdict=", output, why)
        self.assertIn(reason, self.step_log, why)
        # No verdict: the verdict job (dispatch and checked marker) never runs.
        self.assertIn("needs.canary.outputs.verdict != ''", self.jobs["verdict"]["if"])

    def assert_fail(self, tools: dict[str, str], why: str, length: str = "5", runner_temp: str = "") -> None:
        outcome, output = self.artifact(tools, length, runner_temp)
        self.assertEqual(outcome, "failure", why)
        self.assertIn("verdict=fail", output, why)

    def test_a_tooling_error_in_the_artifact_step_records_no_verdict(self):
        # A runner or download error is none: the next scheduled tick retries it.
        self.assert_no_verdict({"xcrun": 'echo "xcrun: error: unable to find utility \\"stapler\\", not a developer tool or in PATH" >&2; exit 72'},
                               "missing Apple tooling")
        self.assert_no_verdict({"xcrun": "exit 0", "hdiutil": 'echo "hdiutil: attach failed - Resource busy" >&2; exit 1'},
                               "hdiutil attach")
        self.assert_no_verdict({"xcrun": 'echo "Error Domain=NSURLErrorDomain Code=-1009 \\"The Internet connection appears to be offline.\\"" >&2; exit 65'},
                               "stapler could not reach Apple")
        self.assert_no_verdict({"xcrun": "exit 0", "hdiutil": self.ATTACH,
                                "spctl": 'echo "spctl: assessment could not complete: a network error occurred" >&2; exit 3'},
                               "spctl could not reach Apple")
        self.assert_no_verdict({"xcrun": "exit 0", "hdiutil": self.ATTACH, "spctl": "exit 1"},
                               "an spctl failure with no definite rejection")
        self.assert_no_verdict({"python3": self.artifact_check("dmg", 'echo "Traceback (most recent call last):" >&2; exit 1')},
                               "the DMG check crashed", "the DMG's bytes failed without a definite rejection")
        self.assert_no_verdict({"xcrun": "exit 0", "hdiutil": self.ATTACH,
                                "python3": self.artifact_check("commit", 'echo "OSError: [Errno 5] Input/output error" >&2; exit 1')},
                               "the commit check crashed", "the app's source commit failed without a definite rejection")

    def test_only_a_definite_artifact_rejection_records_fail(self):
        self.assert_fail({"xcrun": 'echo "canary.dmg does not have a ticket stapled to it." >&2; exit 65'},
                         "no stapled ticket")
        self.assert_fail({"xcrun": 'echo "The validate action failed! Error 65." >&2; exit 65'},
                         "a stapled ticket that does not validate")
        self.assert_fail({"xcrun": "exit 0", "hdiutil": self.ATTACH,
                          "spctl": 'echo "${@: -1}: rejected" >&2; echo "source=Unnotarized Developer ID" >&2; exit 3'},
                         "Gatekeeper rejected the app")
        # The runner's own paths are in the tools' output; a word in them is not an unreachable service.
        self.assert_fail({"xcrun": "exit 0", "hdiutil": self.ATTACH,
                          "spctl": 'echo "${@: -1}: rejected" >&2; echo "source=Unnotarized Developer ID" >&2; exit 3'},
                         "Gatekeeper rejected the app on a runner whose path names a server", runner_temp="build-server/network/_temp")
        self.assert_fail({"xcrun": 'echo "${@: -1} does not have a ticket stapled to it." >&2; exit 65'},
                         "no stapled ticket on a runner whose path names a server", runner_temp="build-server/_temp")
        self.assert_fail({"xcrun": "exit 0"}, "a length mismatch", length="6")
        self.assert_fail({"xcrun": "exit 0", "hdiutil": "exit 0"}, "no app in the DMG")
        self.assert_fail({"python3": self.artifact_check(
                              "dmg", "echo \"::error title=nightly-next DMG::canary.dmg: the feed's edSignature does not verify\" >&2; exit 1")},
                         "the edSignature does not verify over the DMG")
        self.assert_fail({"xcrun": "exit 0", "hdiutil": self.ATTACH, "python3": self.artifact_check(
                              "commit", 'echo "::error title=nightly-next app commit::the app was built from abc1234" >&2; exit 1')},
                         "the app was built from another commit")

    def test_a_length_mismatch_is_an_artifact_failure(self):
        self.assertNotIn("DMG_LENGTH", self.step("canary", "Download the feed's DMG")["run"])
        self.assertIn("DMG_LENGTH", self.step("canary", "Check Gatekeeper and the notary tickets")["run"])

    def test_a_build_is_marked_checked_only_after_its_verdict_dispatch(self):
        uses = [s.get("uses", "") for s in self.jobs["canary"]["steps"]]
        self.assertFalse(any(u.startswith("actions/cache/save@") for u in uses), "the canary job saves the marker")
        steps = self.jobs["verdict"]["steps"]
        names = [s.get("name") for s in steps]
        dispatch = names.index("Write the verdict to R2")
        save = next(i for i, s in enumerate(steps) if s.get("uses", "").startswith("actions/cache/save@"))
        self.assertLess(dispatch, save)
        for s in steps[dispatch + 1:save + 1]:
            self.assertEqual(s.get("if"), "success()", s.get("name"))
        self.assertEqual(steps[save]["with"]["key"], "${{ env.CANARY_CACHE_PREFIX }}${{ needs.pick.outputs.build }}")

    def durable(self, document: str | None) -> str:
        """Run the pick job's durable-verdict read against a `curl` that serves
        this verdicts/<build>.json body (None: the document is missing)."""
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir = Path(tmp)
            if document is not None:
                (bin_dir / "doc").write_text(document)
            (bin_dir / "curl").write_text(f"""#!/bin/bash
out=
while [ $# -gt 0 ]; do [ "$1" = -o ] && {{ out=$2; shift; }}; shift; done
[ -f {tmp}/doc ] || {{ echo "curl: (22) 404" >&2; exit 22; }}
cp {tmp}/doc "$out"
""")
            (bin_dir / "curl").chmod(0o755)
            result, output = self.run_step("pick", "Read the build's durable verdict",
                                           {"BUILD": "4100", "NIGHTLY_NEXT_FEED": "https://x/nightly-next/next/appcast-arm64.xml"},
                                           path=bin_dir)
            self.assertEqual(result.returncode, 0, result.stderr)
            return output

    def test_a_step_writes_nothing_where_the_tests_run(self):
        # The durable-verdict step downloads verdict.json into its working
        # folder; run from a checkout, it must not leave the file there.
        with tempfile.TemporaryDirectory() as here:
            before = os.getcwd()
            os.chdir(here)
            try:
                self.durable('{"build": "4100", "verdict": "pass"}')
            finally:
                os.chdir(before)
            self.assertEqual(os.listdir(here), [])

    def test_a_marked_build_is_checked_only_while_its_verdict_document_exists(self):
        # The dispatch was accepted, but nightly-next-verdict.yml failed before
        # its upload: the marker alone must not suppress the build forever.
        self.assertIn("written=true", self.durable('{"build": "4100", "verdict": "pass"}'))
        self.assertIn("written=true", self.durable('{"build": "4100", "verdict": "fail"}'))
        self.assertNotIn("written=", self.durable(None))
        self.assertNotIn("written=", self.durable('{"build": "4099", "verdict": "pass"}'))
        self.assertNotIn("written=", self.durable("not json"))
        checked = self.jobs["pick"]["outputs"]["checked"]
        self.assertIn("steps.seen.outputs.cache-hit == 'true'", checked)
        self.assertIn("steps.durable.outputs.written == 'true'", checked)

    def dispatch(self, *answers: str) -> subprocess.CompletedProcess:
        """Run the dispatch step against a `gh` that gives these answers in turn
        (`ok`, or the error text it prints before exiting 1)."""
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir = Path(tmp)
            for i, answer in enumerate(answers):
                (bin_dir / f"answer{i}").write_text(answer)
            (bin_dir / "gh").write_text(f"""#!/bin/bash
n=$(cat {tmp}/count 2>/dev/null || echo 0); echo $((n + 1)) > {tmp}/count
answer="$(cat {tmp}/answer$n 2>/dev/null || echo 'no more answers')"
[ "$answer" = ok ] && exit 0
echo "$answer" >&2; exit 1
""")
            (bin_dir / "sleep").write_text("#!/bin/bash\nexit 0\n")
            for tool in ("gh", "sleep"):
                (bin_dir / tool).chmod(0o755)
            result, _ = self.run_step("verdict", "Write the verdict to R2",
                                      {"GH_TOKEN": "t", "BUILD": "4100", "VERDICT": "pass"}, path=bin_dir)
            result.calls = int((bin_dir / "count").read_text())
            return result

    def test_a_failed_dispatch_fails_the_verdict_job(self):
        result = self.dispatch("HTTP 422: Workflow does not have 'workflow_dispatch' trigger")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.calls, 1)

    def test_a_rate_limited_dispatch_is_retried(self):
        limited = "HTTP 403: API rate limit exceeded for installation"
        result = self.dispatch(limited, "ok")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.calls, 2)
        result = self.dispatch(limited, limited, limited)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.calls, 3)

    def test_the_dispatch_succeeds_on_the_first_answer(self):
        result = self.dispatch("ok")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.calls, 1)


if __name__ == "__main__":
    unittest.main()
