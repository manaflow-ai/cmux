#!/usr/bin/env python3
"""machine-join-e2e.yml keeps the scope it was cleared for.

The workflow holds the repo's dev stack account and adds an OS user, so these
hold for good: manual dispatch only; feat-cmux-next only; top-level
`permissions: contents: read` and nothing else (no job-level grants); the stack
secrets reach exactly one step, through `env`; no `set -x`; the platform origin
is development's; the runner is an ephemeral Blacksmith label (never a runner
variable that can name a persistent host); the evidence check, the upload and
the disposable user's removal run under `always()`, the upload only when the
check found the evidence clean; nothing else is uploaded. The disposable
user's base is root:root 0755 before the user exists (acpmux refuses a state
directory with another user's ancestor), and the real binary joins with
malformed stdin as that user before any secret is in reach.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
from blacksmith_linux_sizes import blacksmith_route  # noqa: E402
WORKFLOW = ROOT / ".github/workflows/machine-join-e2e.yml"
SCRIPT = ROOT / "scripts/cmux-next/machine-join-e2e.ts"
DEV = "https://cmux-platform-development.debussy.workers.dev"
RUNS_ON = (
    "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || "
    + blacksmith_route("machine-join-e2e.yml", "e2e") + " }}"
)


def load() -> dict:
    # BaseLoader keeps `on` a string key and every scalar a string, as GitHub reads them.
    return yaml.load(WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)


def steps() -> list[dict]:
    return load()["jobs"]["e2e"]["steps"]


def step(name: str) -> dict:
    [found] = [s for s in steps() if s.get("name") == name]
    return found


class MachineJoinE2EWorkflow(unittest.TestCase):
    def test_manual_dispatch_only(self) -> None:
        self.assertEqual(list(load()["on"].keys()), ["workflow_dispatch"])
        self.assertEqual(sorted(load()["on"]["workflow_dispatch"]["inputs"]), ["acpmux_ref", "name"])

    def test_feat_cmux_next_only(self) -> None:
        job = load()["jobs"]["e2e"]
        self.assertEqual(job["if"], "github.ref == 'refs/heads/feat-cmux-next'")
        # An existing environment whose branch policy admits feat-cmux-next only.
        self.assertEqual(job["environment"], "cmux-next-vm-image-dev")
        self.assertIn("refs/heads/feat-cmux-next", steps()[0]["run"])
        self.assertIn("exit 1", steps()[0]["run"])

    def test_only_the_runs_own_commit_builds(self) -> None:
        # The build runs as the user that later holds the secrets: no other commit may build here.
        resolve = step("Resolve inputs")["run"]
        self.assertIn('"$ACPMUX_REF_INPUT" != "$GITHUB_SHA"', resolve)
        checkouts = [s for s in steps() if "actions/checkout" in s.get("uses", "")]
        self.assertEqual(len(checkouts), 1)
        self.assertNotIn("ref", checkouts[0].get("with", {}))
        self.assertEqual(step("Build acpmux")["working-directory"], "cmux-tui")

    def test_read_only_token(self) -> None:
        document = load()
        self.assertEqual(document["permissions"], {"contents": "read"})
        for name, job in document["jobs"].items():
            self.assertNotIn("permissions", job, name)

    def test_stack_secrets_reach_one_step_through_env(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertEqual(len(re.findall(r"\$\{\{\s*secrets\.", text)), 2)
        holders = [s for s in steps() if re.search(r"\$\{\{\s*secrets\.", str(s))]
        self.assertEqual([s["name"] for s in holders], ["Mint, join, verify and revoke"])
        mint = holders[0]
        self.assertEqual(mint["env"]["CMUX_UITEST_STACK_EMAIL"], "${{ secrets.CMUX_DOGFOOD_STACK_EMAIL }}")
        self.assertEqual(mint["env"]["CMUX_UITEST_STACK_PASSWORD"], "${{ secrets.CMUX_DOGFOOD_STACK_PASSWORD }}")
        self.assertNotIn("secrets", mint["run"])
        self.assertNotIn("CMUX_UITEST_STACK", mint["run"])

    def test_no_xtrace(self) -> None:
        for s in steps():
            self.assertNotRegex(s.get("run", ""), r"set -[a-z]*x|set -o xtrace|bash -x")

    def test_development_origin_only(self) -> None:
        job = load()["jobs"]["e2e"]
        self.assertEqual(job["env"]["HUB_ORIGIN"], DEV)
        script = SCRIPT.read_text(encoding="utf-8")
        self.assertIn(f'export const DEV_PLATFORM = "{DEV}"', script)
        self.assertIn("if (opts.origin !== DEV_PLATFORM)", script)

    def test_ephemeral_blacksmith_runner(self) -> None:
        job = load()["jobs"]["e2e"]
        self.assertEqual(job["runs-on"], RUNS_ON)
        self.assertNotIn("LINUX_RUNNER", job["runs-on"])
        self.assertIn("timeout-minutes", job)

    def test_cleanup_and_evidence_run_always(self) -> None:
        check = step("Check the evidence")
        self.assertTrue(check["if"].startswith("always()"))
        self.assertIn("cmj_|cmm_|eyJ", check["run"])
        self.assertIn("bearer|authorization", check["run"])
        self.assertIn("revokedListed", check["run"])
        # Values from the evidence reach ::error lines only as plain characters.
        self.assertIn("tr -cd 'A-Za-z0-9._:-'", check["run"])
        self.assertIn("tr -cd 'A-Za-z0-9 ._:;,()/-'", check["run"])
        upload = step("Upload the evidence")
        self.assertEqual(upload["if"], "always() && steps.evidence.outputs.clean == 'true'")
        remove = step("Remove the disposable user")
        self.assertTrue(remove["if"].startswith("always()"))
        self.assertIn("userdel --remove", remove["run"])
        self.assertIn('sudo -n -u "$JOIN_USER" -- /bin/kill -KILL -1', remove["run"])

    def test_disposable_base_is_roots_before_the_user_exists(self) -> None:
        # acpmux refuses a state directory whose ancestor another user owns; a runner-owned base also
        # leaves the binary's directory replaceable. root:root 0755 before useradd, then every ancestor checked.
        run = step("Create the disposable user")["run"]
        useradd = run.index("sudo useradd")
        chown = run.index('sudo chown root:root "$base"')
        chmod = run.index('sudo chmod 0755 "$base"')
        self.assertLess(chown, useradd)
        self.assertLess(chmod, useradd)
        self.assertNotRegex(run[:useradd], r"(?m)^\s*chmod ")
        # An empty home the user owns (no /etc/skel copy), made after the user exists.
        self.assertIn("--no-create-home", run)
        self.assertNotIn("--create-home --", run)
        self.assertLess(useradd, run.index('sudo install -d -o "$user" -g "$user" -m 0700 "$base/home"'))
        self.assertIn('for start in "$base/home" "$base/bin/acpmux"', run)
        self.assertIn("8#022", run)
        self.assertIn("8#1000", run)
        self.assertIn('[ "$owner" != 0 ] && [ "$owner" != "$uid" ]', run)
        # An extended ACL could grant the user write where the mode bits do not.
        self.assertIn('sudo ls -ld -- "$path"', run)
        self.assertIn('"${perms:10:1}" = +', run)

    def test_real_binary_smoke_runs_as_the_user_before_the_secrets(self) -> None:
        names = [s.get("name") for s in steps()]
        smoke_at = names.index("Smoke-test acpmux as the disposable user")
        self.assertLess(names.index("Create the disposable user"), smoke_at)
        self.assertLess(smoke_at, names.index("Mint, join, verify and revoke"))
        smoke = steps()[smoke_at]
        self.assertNotIn("secrets", str(smoke))
        self.assertNotIn("CMUX_UITEST_STACK", str(smoke))
        self.assertNotIn("if", smoke)
        run = smoke["run"]
        self.assertIn("printf 'not-a-join-token\\n' | sudo -n -u \"$JOIN_USER\"", run)
        self.assertIn("/usr/bin/env -i", run)
        self.assertIn('"$JOIN_BASE/bin/acpmux" host join --hub "$HUB_ORIGIN"', run)
        self.assertNotIn("cmj_", run)
        # GitHub runs `bash -e`: a bare `code=$?` after the expected exit 2 is never reached.
        self.assertIn('--json >"$out" 2>&1 || code=$?', run)
        self.assertNotRegex(run, r"(?m)^\s*code=\$\?")
        self.assertIn('if [ "$code" -eq 5 ]', run)
        self.assertIn('if [ "$code" -ne 2 ]', run)
        self.assertIn('"$JOIN_HOME/.acpmux"', run)
        # acpmux's output is printed only made plain, never raw: no line of it can start a workflow command.
        self.assertIn("sed -e 's/::/: :/g' -e 's/##\\[/## [/g' -- \"$out\"", run)
        self.assertNotRegex(run, r'(?m)^\s*cat\b')

    def test_only_the_evidence_is_uploaded(self) -> None:
        uploads = [s for s in steps() if "upload-artifact" in s.get("uses", "")]
        self.assertEqual(len(uploads), 1)
        self.assertEqual(uploads[0]["with"]["path"], "${{ runner.temp }}/machine-join-e2e/evidence.json")
        # No restored build cache in a job that later holds secrets.
        self.assertFalse([s for s in steps() if re.search(r"actions/cache|rust-cache", s.get("uses", ""))])


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
