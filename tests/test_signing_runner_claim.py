#!/usr/bin/env python3
"""Behavioral coverage for main's owned-Mac signing claim and keychain cleanup.

Carried from feat-cmux-next's tests/test_ci_signing_owned_mac.py. With
vars.CI_CLASSIC_NIGHTLY_MINI set, main's nightly.yml signs on cmux15's trusted
signing runner (glaeda-trusted-next-signing; tests/test_classic_nightly_one_mini.py
holds the routes). Such a job must, before any credential is in reach:

1. start with CLAIM_GATE (inline, before the checkout): on an owned Mac it fails
   without glaeda's whole-mini claim (GLAEDA_JOB_CLAIM=exclusive) from a hook
   scripts/ci/glaeda-signing-hooks.txt lists, read at the run's own commit;
2. run scripts/ci/signing-runner-claim.sh (the same check, and it removes a
   signing keychain a killed job left) before every step that names a secret;
3. make its keychain with scripts/ci/signing-keychain.sh create, which restarts
   the user's trustd agent so codesign reads the new keychain, and delete it in
   an `if: always()` step, which puts the user's keychain search list back (an
   owned Mac outlives the job).

On an ephemeral runner (Blacksmith, the route while the variable is unset) the
gate and the claim script do nothing.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLAIM = "scripts/ci/signing-runner-claim.sh"
SIGNING_HOOKS_FILE = ROOT / "scripts/ci/glaeda-signing-hooks.txt"
SIGNING_HOOKS = [line.split()[0] for line in SIGNING_HOOKS_FILE.read_text().splitlines()
                 if line.strip() and not line.startswith("#")]
FIRST_SIGNING_HOOK = "2695209c13db5fe7514daf76d3e8e547b9569ad9a545225e52f7e07dd83d69e4"
OLD_HOOK = "fb0442d31e23f01326118b7d6be2effd0ba91bff9a0b59c62016c39bc23116da"
# The hook cmux15 runs (glaeda 99d1e407, #1847, sha256 of ~/glaeda-runner/scripts/glaeda-cmux-runner-hook there on
# 2026-11-05). glaeda's hook refuses a signing job whose commit does not list its sha (glaeda #1761), so main lists it.
CMUX15_HOOK = "aff786ca089a05cef2627a80d7fe4da0393a4814fc9619aca0e7384263d37ad9"
CLAIM_GATE_NAME = "Hold the whole Mac before any credential"
CLAIM_GATE_ID = "claim-gate"
# The first step of a main nightly signing job that can reach an owned Mac, word for word: it needs no checkout.
CLAIM_GATE = f"""owned=""
case "${{RUNNER_NAME:-}}" in *-glaeda|*-glaeda-*) owned=1 ;; esac
if [ -d /Users/Shared/cmux-build-fleet ]; then owned=1; fi
if [ -n "$owned" ]; then
  if [ "${{GLAEDA_JOB_CLAIM:-}}" != exclusive ]; then
    echo "::error title=Signing runner::This owned Mac did not give the job the whole mini, so this job fails before any credential is in reach."
    exit 1
  fi
  hooks=$(curl -fsS --proto '=https' --retry 3 --max-time 20 \\
    "https://raw.githubusercontent.com/${{GITHUB_REPOSITORY}}/${{GITHUB_SHA}}/scripts/ci/glaeda-signing-hooks.txt") || hooks=""
  hook="${{GLAEDA_HOOK_SHA256:-}}"
  listed=""
  if [[ "$hook" =~ ^[0-9a-f]{{64}}$ ]]; then
    while read -r sha _; do if [ "$sha" = "$hook" ]; then listed=1; fi; done <<< "$hooks"
  fi
  if [ -z "$listed" ]; then
    echo "::error title=Signing runner::glaeda hook ${{hook:-unnamed}} is not one scripts/ci/glaeda-signing-hooks.txt lists, so this job fails before any credential is in reach."
    exit 1
  fi
  echo "claim=owned" >> "$GITHUB_OUTPUT"
fi
"""


class ClaimScriptTests(unittest.TestCase):
    def run_claim(self, tmp: Path, **env: str) -> subprocess.CompletedProcess:
        security = tmp / "security"
        security.write_text('#!/bin/sh\n[ "$1" = delete-keychain ] && rm -f "$KEYCHAINS/$2-db"\n'
                            'echo "$@" >> "$KEYCHAINS/calls"\n')
        security.chmod(0o755)
        environ = {"PATH": "/usr/bin:/bin", "HOME": os.fspath(tmp), "KEYCHAINS": os.fspath(tmp / "keychains"),
                   "CMUX_SECURITY_TOOL": os.fspath(security), "CMUX_KEYCHAIN_DIR": os.fspath(tmp / "keychains"),
                   "CMUX_FLEET_DIR": os.fspath(tmp / "no-fleet"), **env}
        return subprocess.run(["bash", os.fspath(ROOT / CLAIM)], env=environ, capture_output=True, text=True,
                              timeout=30, check=False)

    def test_claim(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            (tmp / "keychains").mkdir()
            ephemeral = self.run_claim(tmp, RUNNER_NAME="blacksmith-6vcpu-macos-26-abc")
            self.assertEqual(ephemeral.returncode, 0, ephemeral.stdout + ephemeral.stderr)
            self.assertIn("is ephemeral", ephemeral.stdout)
            for env in ({"RUNNER_NAME": "cmux12-glaeda-3"}, {"RUNNER_NAME": "cmux12-glaeda"},
                        {"RUNNER_NAME": "mini", "CMUX_FLEET_DIR": raw},
                        {"RUNNER_NAME": "cmux12-glaeda", "GLAEDA_JOB_CLAIM": "light"}):
                with self.subTest(env):
                    refused = self.run_claim(tmp, **env)
                    self.assertEqual(refused.returncode, 1, refused.stdout)
                    self.assertIn("did not give the job the whole mini", refused.stdout)
            for sha in ("", OLD_HOOK, SIGNING_HOOKS[0][:12], "x" * 64, ".*", ".*.*", "[0-9a-f]*",
                        SIGNING_HOOKS[0] + " ", "#", SIGNING_HOOKS[0][:63] + "."):
                with self.subTest(sha=sha):
                    refused = self.run_claim(tmp, RUNNER_NAME="cmux12-glaeda-3", GLAEDA_JOB_CLAIM="exclusive",
                                             GLAEDA_HOOK_SHA256=sha)
                    self.assertEqual(refused.returncode, 1, refused.stdout)
                    self.assertIn("is not one", refused.stdout)
            for sha in SIGNING_HOOKS:
                with self.subTest(listed=sha):
                    passed = self.run_claim(tmp, RUNNER_NAME="cmux12-glaeda-3", GLAEDA_JOB_CLAIM="exclusive",
                                            GLAEDA_HOOK_SHA256=sha)
                    self.assertEqual(passed.returncode, 0, passed.stdout + passed.stderr)
            (tmp / "keychains" / "build.keychain-db").write_text("left by a killed job")
            claimed = self.run_claim(tmp, RUNNER_NAME="cmux12-glaeda-3", GLAEDA_JOB_CLAIM="exclusive",
                                     GLAEDA_HOOK_SHA256=FIRST_SIGNING_HOOK)
            self.assertEqual(claimed.returncode, 0, claimed.stdout + claimed.stderr)
            self.assertIn("holds the whole mini", claimed.stdout)
            self.assertIn("removed the signing keychain build.keychain", claimed.stdout)
            self.assertFalse((tmp / "keychains" / "build.keychain-db").exists())


class SearchListTests(unittest.TestCase):
    """delete puts back the user search list create replaced, and falls back to the login keychain when create could
    not read it or nothing it saw is left, so an owned Mac never keeps the deleted signing keychain as its list."""

    def delete(self, tmp: Path) -> list[str]:
        security = tmp / "security"
        security.write_text('#!/bin/sh\necho "$@" >> "$CALLS"\n')
        security.chmod(0o755)
        env = {"PATH": "/usr/bin:/bin", "HOME": os.fspath(tmp), "CALLS": os.fspath(tmp / "calls"),
               "CMUX_SECURITY_TOOL": os.fspath(security), "CMUX_KEYCHAIN_DIR": os.fspath(tmp / "keychains"),
               "CMUX_SIGNING_KEYCHAIN_STATE_DIR": os.fspath(tmp / "state")}
        done = subprocess.run(["bash", os.fspath(ROOT / "scripts/ci/signing-keychain.sh"), "delete"], env=env,
                              capture_output=True, text=True, timeout=30, check=False)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        calls = (tmp / "calls").read_text().splitlines() if (tmp / "calls").exists() else []
        (tmp / "calls").unlink(missing_ok=True)
        return [call for call in calls if call.startswith("list-keychains")]

    def test_search_list(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            (tmp / "keychains").mkdir()
            state = tmp / "state"
            state.mkdir()
            login = tmp / "keychains" / "login.keychain-db"
            login.write_text("")
            other = tmp / "keychains" / "other.keychain-db"
            other.write_text("")
            (state / "search-list").write_text(f"{login}\n{other}\n{tmp}/gone.keychain-db\n")
            self.assertEqual(self.delete(tmp), [f"list-keychains -d user -s {login} {other}"])
            self.assertFalse((state / "search-list").exists())
            (state / "search-list.failed").write_text("")
            self.assertEqual(self.delete(tmp), [f"list-keychains -d user -s {login}"], "the capture failed")
            self.assertFalse((state / "search-list.failed").exists())
            (state / "search-list").write_text(f"{tmp}/gone.keychain-db\n")
            self.assertEqual(self.delete(tmp), [f"list-keychains -d user -s {login}"], "nothing it saw is left")
            self.assertEqual(self.delete(tmp), [], "no create in this job: the list is left alone")


class TrustAgentRefreshTests(unittest.TestCase):
    """create restarts the user's trustd agent after the signing keychain joins the search list. An agent running since
    boot never reads a keychain added later, and codesign then fails with errSecInternalComponent ("unable to build
    chain to self-signed root"; two owned minis, every sign-nightly-identity-legacy job, 2026-10-31)."""

    def create(self, tmp: Path, launchctl_script: str) -> tuple[subprocess.CompletedProcess, list[str]]:
        bin_dir = tmp / "bin"
        bin_dir.mkdir(exist_ok=True)
        stubs = {
            # find-certificate -p: the two Developer ID intermediates import-apple-developer-id-intermediates.sh counts
            "security": '#!/bin/sh\necho "security $*" >> "$CALLS"\n'
                        'case "$1" in find-certificate) printf "%s\\n%s\\n" "-----END CERTIFICATE-----" '
                        '"-----END CERTIFICATE-----";; esac\nexit 0\n',
            "launchctl": launchctl_script,
            "uuidgen": "#!/bin/sh\necho 00000000-0000-0000-0000-000000000000\n",
        }
        for name, body in stubs.items():
            (bin_dir / name).write_text(body)
            (bin_dir / name).chmod(0o755)
        env = {"PATH": f"{bin_dir}:/usr/bin:/bin", "HOME": os.fspath(tmp), "CALLS": os.fspath(tmp / "calls"),
               "CMUX_SECURITY_TOOL": os.fspath(bin_dir / "security"),
               "CMUX_LAUNCHCTL_TOOL": os.fspath(bin_dir / "launchctl"),
               "CMUX_KEYCHAIN_DIR": os.fspath(tmp / "keychains"),
               "CMUX_SIGNING_KEYCHAIN_STATE_DIR": os.fspath(tmp / "state"), "RUNNER_TEMP": os.fspath(tmp),
               "APPLE_CERTIFICATE_BASE64": "cDEy", "APPLE_CERTIFICATE_PASSWORD": "pw"}
        done = subprocess.run(["bash", os.fspath(ROOT / "scripts/ci/signing-keychain.sh"), "create"], env=env,
                              capture_output=True, text=True, timeout=30, check=False)
        calls = (tmp / "calls").read_text().splitlines() if (tmp / "calls").exists() else []
        (tmp / "calls").unlink(missing_ok=True)
        return done, calls

    def test_the_agent_restarts_after_the_keychain_joins_the_search_list(self) -> None:
        uid = os.getuid()
        service = f"user/{uid}/com.apple.trustd.agent"
        with tempfile.TemporaryDirectory() as raw:
            done, calls = self.create(Path(raw), '#!/bin/sh\necho "launchctl $*" >> "$CALLS"\nexit 0\n')
            self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
            self.assertIn(f"launchctl kickstart -k {service}", calls)
            self.assertLess(calls.index("security list-keychains -d user -s build.keychain"),
                            calls.index(f"launchctl kickstart -k {service}"),
                            "the agent must start again after the search list names the signing keychain")
            self.assertIn("Restarted the trustd agent", done.stdout)
        with tempfile.TemporaryDirectory() as raw:
            # kickstart refused: the pid launchd reports for the label is stopped, and launchd starts it again
            sleeper = subprocess.Popen(["sleep", "30"])
            try:
                script = ('#!/bin/sh\necho "launchctl $*" >> "$CALLS"\n'
                          '[ "$1" = kickstart ] && exit 150\n'
                          f'[ "$1" = print ] && printf "\\tstate = running\\n\\tpid = {sleeper.pid}\\n"\nexit 0\n')
                done, calls = self.create(Path(raw), script)
                self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
                self.assertEqual(sleeper.wait(timeout=10), -15, "the agent launchd names gets SIGTERM")
                self.assertIn(f"pid {sleeper.pid}", done.stdout)
            finally:
                if sleeper.poll() is None:
                    sleeper.kill()
        with tempfile.TemporaryDirectory() as raw:
            done, calls = self.create(Path(raw), '#!/bin/sh\nexit 1\n')
            self.assertEqual(done.returncode, 0, "best effort: a refusal never fails the signing step")
            self.assertIn("could not restart the trustd agent", done.stderr)
            self.assertIn("Signing keychain build.keychain is ready", done.stdout)


class ClaimGateTests(unittest.TestCase):
    def test_gate(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            output = Path(raw) / "output"
            # curl stands in for raw.githubusercontent.com: it serves this tree's glaeda-signing-hooks.txt for
            # the run's own commit only, records the URL it was asked for, and fails as a 404 for anything else.
            bin_dir = Path(raw) / "bin"
            bin_dir.mkdir()
            served = Path(raw) / "served"
            asked = Path(raw) / "asked"
            curl = bin_dir / "curl"
            curl.write_text('#!/bin/sh\nfor a; do url="$a"; done\necho "$url" >> "$ASKED"\n'
                            '[ "$url" = "$WANT" ] && [ -f "$SERVED" ] && exec cat "$SERVED"\nexit 22\n')
            curl.chmod(0o755)
            run_env = {"GITHUB_REPOSITORY": "manaflow-ai/cmux", "GITHUB_SHA": "a" * 40}
            want = (f"https://raw.githubusercontent.com/{run_env['GITHUB_REPOSITORY']}/{run_env['GITHUB_SHA']}/"
                    "scripts/ci/glaeda-signing-hooks.txt")

            def gate(**env: str) -> subprocess.CompletedProcess:
                output.write_text("")
                return subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", CLAIM_GATE],
                                      env={"PATH": f"{bin_dir}:/usr/bin:/bin", "GITHUB_OUTPUT": os.fspath(output),
                                           "ASKED": os.fspath(asked), "SERVED": os.fspath(served), "WANT": want,
                                           **run_env, **env},
                                      capture_output=True, text=True, timeout=30, check=False)

            served.write_text(SIGNING_HOOKS_FILE.read_text())

            fleet = Path("/Users/Shared/cmux-build-fleet").is_dir()
            if not fleet:
                self.assertEqual(gate(RUNNER_NAME="blacksmith-6vcpu-macos-26-abc").returncode, 0)
                self.assertEqual(output.read_text(), "", "an ephemeral runner claims nothing")
            for env in ({"RUNNER_NAME": "cmux12-glaeda-3"},
                        {"RUNNER_NAME": "cmux12-glaeda", "GLAEDA_JOB_CLAIM": "light", "GLAEDA_HOOK_SHA256": FIRST_SIGNING_HOOK}):
                with self.subTest(env):
                    refused = gate(**env)
                    self.assertEqual(refused.returncode, 1, refused.stdout)
                    self.assertIn("did not give the job the whole mini", refused.stdout)
                    self.assertEqual(output.read_text(), "")
            owned = {"RUNNER_NAME": "cmux12-glaeda-3", "GLAEDA_JOB_CLAIM": "exclusive"}
            for sha in (None, "", OLD_HOOK, FIRST_SIGNING_HOOK[:12], FIRST_SIGNING_HOOK + "0", "x" * 64):
                with self.subTest(sha=sha):
                    refused = gate(**owned, **({} if sha is None else {"GLAEDA_HOOK_SHA256": sha}))
                    self.assertEqual(refused.returncode, 1, refused.stdout)
                    self.assertIn("is not one scripts/ci/glaeda-signing-hooks.txt lists", refused.stdout)
                    self.assertEqual(output.read_text(), "", "a refused owned attempt claims nothing")
            for sha in SIGNING_HOOKS:
                with self.subTest(sha=sha):
                    passed = gate(**owned, GLAEDA_HOOK_SHA256=sha)
                    self.assertEqual(passed.returncode, 0, passed.stdout + passed.stderr)
                    self.assertEqual(output.read_text(), "claim=owned\n")
            self.assertEqual(set(asked.read_text().split()), {want}, "the list is read at the run's own commit only")
            self.assertIn(FIRST_SIGNING_HOOK, SIGNING_HOOKS, "the hook with the leftover-process check passes")
            self.assertNotIn(OLD_HOOK, SIGNING_HOOKS, "the hook from before it is refused")
            # The list read at the run's commit is the one that counts: a hook it adds passes with no workflow edit,
            # a hook it lacks (or a list that cannot be read) is refused.
            new_hook = "b" * 64
            served.write_text(SIGNING_HOOKS_FILE.read_text() + f"{new_hook} a hook glaeda pinned later\n")
            self.assertEqual(gate(**owned, GLAEDA_HOOK_SHA256=new_hook).returncode, 0)
            self.assertEqual(output.read_text(), "claim=owned\n")
            served.write_text(f"# only a note\n{new_hook}\n")
            refused = gate(**owned, GLAEDA_HOOK_SHA256=FIRST_SIGNING_HOOK)
            self.assertEqual(refused.returncode, 1, "a hook the run's commit does not list is refused")
            self.assertEqual(output.read_text(), "")
            served.unlink()
            refused = gate(**owned, GLAEDA_HOOK_SHA256=FIRST_SIGNING_HOOK)
            self.assertEqual(refused.returncode, 1, "an unreadable list refuses")
            self.assertIn("is not one scripts/ci/glaeda-signing-hooks.txt lists", refused.stdout)
            self.assertEqual(output.read_text(), "")
            for sha in ("#", ""):
                with self.subTest(note_line=sha):
                    served.write_text("# a note\n\n")
                    self.assertEqual(gate(**owned, GLAEDA_HOOK_SHA256=sha).returncode, 1)
            self.assertEqual(gate(**owned, GLAEDA_HOOK_SHA256=new_hook,
                                  GITHUB_SHA="c" * 40).returncode, 1, "another commit's list is never read")


class Cmux15HookTests(unittest.TestCase):
    def test_the_hook_cmux15_runs_is_listed(self) -> None:
        self.assertIn(CMUX15_HOOK, SIGNING_HOOKS)
        self.assertIn(FIRST_SIGNING_HOOK, SIGNING_HOOKS)
        self.assertNotIn(OLD_HOOK, SIGNING_HOOKS)


if __name__ == "__main__":
    unittest.main()
