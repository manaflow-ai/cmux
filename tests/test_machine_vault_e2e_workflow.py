#!/usr/bin/env python3
"""machine-vault-e2e.yml keeps the scope it was cleared for.

The workflow holds the repo's dev stack account and the team's Claude subscription login, adds a macOS
user and opens ssh to it, so these hold for good: manual dispatch only; feat-cmux-next only; top-level
`permissions: contents: read` and nothing else; the three secrets reach exactly one step, through `env`;
no Anthropic API key at all, and the Claude login never goes to the vault (only to the user's ssh stdin);
no `set -x`; the platform origin is development's; the runner is an ephemeral Blacksmith macOS VM read
from RUNNER_POOLS (never a runner variable that can name a persistent Mac); the channel must contain the
vault's merge before any secret is in reach; the user, its keychain and its ssh key are made before the
secrets and removed under `always()`; the evidence check and upload run under `always()`, the upload only
when the check found the evidence clean; nothing else is uploaded.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/machine-vault-e2e.yml"
SCRIPT = ROOT / "scripts/cmux-next/machine-vault-e2e.ts"
DEV = "https://cmux-platform-development.debussy.workers.dev"
RUNS_ON = "${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || fromJSON(vars.RUNNER_POOLS).macos_26 }}"
RUN_STEP = "Vault, join, agent and cleanup"
VAULT_MERGE = "4cfaaa8d3891d43b3e237c70b0dbf701feb92de2"
MACHINE_ADD_MERGE = "657906ec79ebd3704cdf6be709e3a206be438754"


def load() -> dict:
    # BaseLoader keeps `on` a string key and every scalar a string, as GitHub reads them.
    return yaml.load(WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)


def steps() -> list[dict]:
    return load()["jobs"]["e2e"]["steps"]


def step(name: str) -> dict:
    [found] = [s for s in steps() if s.get("name") == name]
    return found


def names() -> list[str]:
    return [s.get("name", "") for s in steps()]


class MachineVaultE2EWorkflow(unittest.TestCase):
    def test_manual_dispatch_only(self) -> None:
        self.assertEqual(list(load()["on"].keys()), ["workflow_dispatch"])
        inputs = load()["on"]["workflow_dispatch"]["inputs"]
        self.assertEqual(sorted(inputs), ["join_channel", "model"])
        # The model stub by default; the team's login only on a model: real dispatch (the canary).
        self.assertEqual((inputs["model"]["default"], inputs["model"]["options"]), ("stub", ["stub", "real"]))
        self.assertEqual(inputs["join_channel"]["default"], "feat-cmux-next")

    def test_feat_cmux_next_only(self) -> None:
        job = load()["jobs"]["e2e"]
        self.assertEqual(job["if"], "github.ref == 'refs/heads/feat-cmux-next'")
        self.assertEqual(job["environment"], "cmux-next-vm-image-dev")
        self.assertIn("refs/heads/feat-cmux-next", steps()[0]["run"])
        self.assertIn("exit 1", steps()[0]["run"])

    def test_the_published_cli_checked_and_nothing_compiled(self) -> None:
        checkouts = [s for s in steps() if "actions/checkout" in s.get("uses", "")]
        self.assertEqual(len(checkouts), 1)
        self.assertNotIn("ref", checkouts[0].get("with", {}))
        self.assertEqual(checkouts[0]["with"]["persist-credentials"], "false")
        cli = step("Download the published cmux CLI")
        self.assertNotIn("secrets", str(cli))
        self.assertEqual(cli["env"]["MACHINE_ADD_MERGE"], MACHINE_ADD_MERGE)
        self.assertIn("git rev-list --first-parent -n 30 HEAD", cli["run"])
        self.assertIn('"$got" != "$want"', cli["run"])
        self.assertIn("ahead", cli["run"])
        self.assertLess(names().index("Download the published cmux CLI"), names().index(RUN_STEP))
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertNotIn("cargo build", text)
        self.assertNotIn("setup-cmux-tui-rust", text)

    def test_read_only_token(self) -> None:
        document = load()
        self.assertEqual(document["permissions"], {"contents": "read"})
        for name, job in document["jobs"].items():
            self.assertNotIn("permissions", job, name)

    def test_secrets_reach_one_step_through_env(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertEqual(len(re.findall(r"\bsecrets\.[A-Z]", text)), 3)
        holders = [s for s in steps() if re.search(r"\$\{\{\s*secrets\.", str(s))]
        self.assertEqual([s["name"] for s in holders], [RUN_STEP])
        run = holders[0]
        self.assertEqual(run["env"]["CMUX_UITEST_STACK_EMAIL"], "${{ secrets.CMUX_DOGFOOD_STACK_EMAIL }}")
        self.assertEqual(run["env"]["CMUX_UITEST_STACK_PASSWORD"], "${{ secrets.CMUX_DOGFOOD_STACK_PASSWORD }}")
        # The subscription login reaches the run only on a model: real dispatch (the canary).
        self.assertEqual(run["env"]["CLAUDE_CODE_OAUTH_TOKEN"], "${{ inputs.model == 'real' && secrets.CLAUDE_CODE_OAUTH_TOKEN || '' }}")
        self.assertNotIn("secrets", run["run"])
        self.assertNotIn("CMUX_UITEST_STACK", run["run"])
        self.assertNotIn("CLAUDE_CODE_OAUTH_TOKEN", run["run"])
        self.assertNotIn("ANTHROPIC", run["run"])
        self.assertTrue(run["run"].strip().startswith("exec bun scripts/cmux-next/machine-vault-e2e.ts"))

    def test_no_api_key_and_the_login_never_in_the_vault(self) -> None:
        for path in (WORKFLOW, SCRIPT):
            text = path.read_text(encoding="utf-8")
            self.assertNotIn("CMUX_E2E_ANTHROPIC_API_KEY", text, path)
            self.assertNotIn("ANTHROPIC_API_KEY", text, path)
            self.assertNotIn("auth.json", text, path)
        script = SCRIPT.read_text(encoding="utf-8")
        # The vault only ever gets the nonce; the login is held (masked) and given to one ssh stdin.
        self.assertEqual(re.findall(r'"vault", "set", (\w+)', script), ["NONCE_VAR"])
        self.assertNotRegex(script, r'vault[^\n]*LOGIN_VAR')
        self.assertIn('export const LOGIN_VAR = "CLAUDE_CODE_OAUTH_TOKEN"', script)
        self.assertIn("hold(login)", script)
        self.assertLess(script.index("env.CLAUDE_CODE_OAUTH_TOKEN"), script.index("hold(login)"))
        self.assertIn("sshUser(agentScript(stubUrl), `${login}\\n`", script)
        self.assertIn("IFS= read -r ${LOGIN_VAR}", script)
        self.assertIn("unset ${LOGIN_VAR}", script)
        # Cleanup confirms the processes that held it are gone; the scans count its hits.
        self.assertIn("a process that held the Claude login is still running after cleanup", script)
        self.assertIn('"the home holds the Claude login"', script)
        self.assertIn('"the output holds the Claude login"', script)

    def test_one_run_at_a_time(self) -> None:
        self.assertEqual(load()["concurrency"], {"group": "machine-vault-e2e", "cancel-in-progress": "false"})
        self.assertIn("is already in this account's vault", SCRIPT.read_text(encoding="utf-8"))

    def test_no_xtrace(self) -> None:
        for s in steps():
            self.assertNotRegex(s.get("run", ""), r"set -[a-z]*x|set -o xtrace|bash -x")

    def test_development_origin_only(self) -> None:
        job = load()["jobs"]["e2e"]
        self.assertEqual(job["env"]["HUB_ORIGIN"], DEV)
        script = SCRIPT.read_text(encoding="utf-8")
        self.assertIn(f'export const DEV_PLATFORM = "{DEV}"', script)
        self.assertIn("if (opts.origin !== DEV_PLATFORM)", script)

    def test_ephemeral_macos_runner(self) -> None:
        job = load()["jobs"]["e2e"]
        self.assertEqual(job["runs-on"], RUNS_ON)
        self.assertNotRegex(job["runs-on"], r"vars\.(?!RUNNER_POOLS)")
        self.assertIn("timeout-minutes", job)

    def test_channel_must_carry_the_vault_before_secrets(self) -> None:
        gate = step("Refuse a channel without the vault")
        self.assertEqual(gate["env"]["VAULT_MERGE"], VAULT_MERGE)
        self.assertIn("ahead", gate["run"])
        self.assertIn("identical", gate["run"])
        self.assertIn("^[a-z0-9][a-z0-9-]{0,62}$", gate["run"])
        self.assertLess(names().index("Refuse a channel without the vault"), names().index(RUN_STEP))
        # And the run itself checks the installed acpmux's capability.
        self.assertIn('export const VAULT_CAPABILITY = "machine.vault.pull.v1"', SCRIPT.read_text(encoding="utf-8"))

    def test_disposable_user_made_before_the_secrets(self) -> None:
        create = step("Create the disposable user")
        self.assertLess(names().index("Create the disposable user"), names().index(RUN_STEP))
        self.assertNotIn("secrets", str(create))
        run = create["run"]
        # Outputs before the user exists, so removal runs whatever fails after.
        self.assertLess(run.index('echo "user=$user"'), run.index("sysadminctl -addUser"))
        self.assertIn("sudo -n sysadminctl -addUser", run)
        # Throwaway passwords are masked as soon as they exist.
        self.assertLess(run.index('echo "::add-mask::$password"'), run.index("sysadminctl -addUser"))
        self.assertIn('echo "::add-mask::$keychain_password"', run)
        # A login keychain the way a GUI login makes one, as the user.
        for line in ("security create-keychain", "security default-keychain -d user -s", "security unlock-keychain"):
            self.assertIn(line, run)
        # The ssh key: private half in the runner's private work dir, public half the user's only key.
        self.assertIn('ssh-keygen -q -t ed25519 -N \'\'', run)
        self.assertIn('"$home/.ssh/authorized_keys"', run)
        self.assertIn("StrictHostKeyChecking=accept-new", run)
        self.assertIn("chmod 0700 \"$work\"", run)

    def test_cleanup_and_evidence_run_always(self) -> None:
        check = step("Check the evidence")
        self.assertTrue(check["if"].startswith("always()"))
        self.assertIn("cmj_|cmm_|sk-ant-|eyJ", check["run"])
        # The evidence grep catches the Claude login's shape (sk-ant-oat01-...) and an API key's.
        pattern = re.search(r"grep -Eqi '([^']+)'", check["run"]).group(1)
        for fake in ("sk-ant-oat01-FAKEvalue", "sk-ant-api03-FAKEvalue"):
            self.assertRegex(fake, re.compile(pattern, re.I))
        self.assertIn("bearer|authorization", check["run"])
        self.assertIn("tr -cd 'A-Za-z0-9 ._:;,()/-'", check["run"])
        upload = step("Upload the evidence")
        self.assertEqual(upload["if"], "always() && steps.evidence.outputs.clean == 'true'")
        remove = step("Remove the disposable user")
        self.assertEqual(remove["if"], "always() && steps.user.outputs.user != ''")
        self.assertIn('sudo -n -u "$VAULT_USER" -- /bin/kill -KILL -1', remove["run"])
        self.assertIn('sysadminctl -deleteUser "$VAULT_USER"', remove["run"])
        # Removal only ever names this run's paths.
        self.assertIn("/Users/cmuxvault*) sudo -n rm -rf", remove["run"])
        self.assertIn('"$RUNNER_TEMP"/machine-vault-e2e.*) rm -rf', remove["run"])
        self.assertEqual(names()[-1], "Remove the disposable user")

    def test_script_cleans_up_in_finally(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")
        for needle in (
            "/v1/machines/credentials/${encodeURIComponent(id)}/revoke",
            '"vault", "rm"',
            'op("install.revoke"',
            "deps.removeFile(tokenFile)",
            "await cleanup()",
            # Cleanup waits for everything the main flow had in flight, and its failures fail the run.
            "await settlePending()",
            "stopChildren.abort()",
            'found.push("could not revoke the run\'s cmux install")',
            "is still in the vault after cleanup",
            # The join's machine is revoked by id and confirmed on the list; the sign-out is required too.
            "if (direct) await revoke(direct",
            "is still live after cleanup",
            'found.push("could not sign out the run\'s Stack session")',
            # A cancel's cleanup fits the runner's grace (SIGINT, SIGTERM 7.5 s later, then SIGKILL).
            "cancelBy = cancelAt + CANCEL_BUDGET_MS",
            "process.exit(130), CANCEL_EXIT_MS",
        ):
            self.assertIn(needle, script)

    def test_only_the_evidence_is_uploaded(self) -> None:
        uploads = [s for s in steps() if "upload-artifact" in s.get("uses", "")]
        self.assertEqual(len(uploads), 1)
        self.assertEqual(uploads[0]["with"]["path"], "${{ runner.temp }}/machine-vault-e2e-evidence/evidence.json")
        self.assertFalse([s for s in steps() if re.search(r"actions/cache|rust-cache", s.get("uses", ""))])


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
