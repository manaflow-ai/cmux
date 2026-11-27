#!/usr/bin/env python3
"""machine-join-e2e.yml keeps the scope it was cleared for.

The workflow holds the repo's dev stack account and adds an OS user, so these
hold for good: manual dispatch only; feat-cmux-next only; top-level
`permissions: contents: read` and nothing else (no job-level grants); the stack
secrets (the account and the share's guest account) reach exactly one step,
through `env`; no `set -x`; the platform origin
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
import workflow_jobs  # noqa: E402
WORKFLOW = ROOT / ".github/workflows/machine-vault-e2e.yml"
JOB = "machine_join"
SCRIPT = ROOT / "scripts/cmux-next/machine-join-e2e.ts"
DEV = "https://cmux-platform-development.debussy.workers.dev"
# The linux_8 pool it read, frozen to its label (scripts/ci/one_linux_label.py; no runs-on reads a variable).
RUNS_ON = "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'cmux-fleet-linux-x64' }}"


def load() -> dict:
    # BaseLoader keeps `on` a string key and every scalar a string, as GitHub reads them.
    return yaml.load(WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)


def steps() -> list[dict]:
    return load()["jobs"][JOB]["steps"]


def step(name: str) -> dict:
    [found] = [s for s in steps() if s.get("name") == name]
    return found


class MachineJoinE2EWorkflow(unittest.TestCase):
    def test_manual_dispatch_only(self) -> None:
        self.assertEqual(list(load()["on"].keys()), ["workflow_dispatch"])
        inputs = load()["on"]["workflow_dispatch"]["inputs"]
        self.assertEqual(sorted(inputs), ["acpmux_ref", "bench", "calls", "join_channel", "model", "name", "share", "share_install", "suite"])
        self.assertEqual((inputs["suite"]["default"], inputs["suite"]["options"]), ("machine-vault", ["billing", "machine-join", "machine-vault"]))
        bench = load()["on"]["workflow_dispatch"]["inputs"]["bench"]
        self.assertEqual(bench["default"], "none")
        self.assertEqual(bench["options"], ["none", "deps", "deps-slow"])

    def test_feat_cmux_next_only(self) -> None:
        job = load()["jobs"][JOB]
        self.assertEqual(job["if"], "github.ref == 'refs/heads/feat-cmux-next' && inputs.suite == 'machine-join'")
        # An existing environment whose branch policy admits feat-cmux-next only.
        self.assertEqual(workflow_jobs.resolve(job).environment, {"name": "cmux-next-vm-image-dev", "deployment": "false"})
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
        self.assertEqual(len(re.findall(r"\$\{\{\s*secrets\.", text)), 4)
        self.assertEqual(
            workflow_jobs.secret_names(load()["jobs"][JOB]),
            {"CMUX_DOGFOOD_STACK_EMAIL", "CMUX_DOGFOOD_STACK_PASSWORD", "CMUX_DOGFOOD_GUEST_STACK_EMAIL", "CMUX_DOGFOOD_GUEST_STACK_PASSWORD"},
        )
        for name, job in load()["jobs"].items():
            outside_steps = workflow_jobs.copy_job(job, {"steps": workflow_jobs.DROP}) if name == JOB else job
            self.assertEqual(workflow_jobs.secret_names(outside_steps), set(), name)
        holders = [s for s in steps() if workflow_jobs.secret_names(s)]
        self.assertEqual([s["name"] for s in holders], ["Mint, join, verify and revoke"])
        mint = holders[0]
        self.assertEqual(mint["env"]["CMUX_UITEST_STACK_EMAIL"], "${{ secrets.CMUX_DOGFOOD_STACK_EMAIL }}")
        self.assertEqual(mint["env"]["CMUX_UITEST_STACK_PASSWORD"], "${{ secrets.CMUX_DOGFOOD_STACK_PASSWORD }}")
        # The share's second account (cloud-capture-provision.yml's guest, sealed to the same environment):
        # it must not see the joined machine, and the hub must refuse its request for it.
        self.assertEqual(mint["env"]["CMUX_UITEST_GUEST_STACK_EMAIL"], "${{ secrets.CMUX_DOGFOOD_GUEST_STACK_EMAIL }}")
        self.assertEqual(mint["env"]["CMUX_UITEST_GUEST_STACK_PASSWORD"], "${{ secrets.CMUX_DOGFOOD_GUEST_STACK_PASSWORD }}")
        self.assertNotIn("secrets", mint["run"])
        self.assertNotIn("CMUX_UITEST_STACK", mint["run"])
        self.assertNotIn("CMUX_UITEST_GUEST", mint["run"])

    def test_no_xtrace(self) -> None:
        for s in steps():
            self.assertNotRegex(s.get("run", ""), r"set -[a-z]*x|set -o xtrace|bash -x")

    def test_development_origin_only(self) -> None:
        document = load()
        self.assertEqual(workflow_jobs.effective_env(document, document["jobs"][JOB])["HUB_ORIGIN"], DEV)
        script = SCRIPT.read_text(encoding="utf-8")
        self.assertIn(f'export const DEV_PLATFORM = "{DEV}"', script)
        self.assertIn("if (opts.origin !== DEV_PLATFORM)", script)

    def test_ephemeral_blacksmith_runner(self) -> None:
        job = load()["jobs"][JOB]
        cells = workflow_jobs.runs_on_cells(job)
        self.assertEqual(cells, [RUNS_ON])
        self.assertNotIn("LINUX_RUNNER", "\n".join(cells))
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

    def test_bench_is_opt_in_and_secret_free(self) -> None:
        # The bench's files are laid out with no secret in reach, only for bench=deps, and the bench
        # script itself is root-owned beside acpmux, so the disposable user cannot change what runs.
        prep = step("Prepare the dependency bench")
        self.assertEqual(prep["if"], "startsWith(inputs.bench, 'deps')")
        self.assertNotIn("secrets", str(prep))
        self.assertIn('sudo install -o root -g root -m 0755 scripts/cmux-next/deps-bench.sh "$JOIN_BASE/bin/deps-bench.sh"', prep["run"])
        self.assertIn('sudo chown -R root:root "$JOIN_BASE/toolchain"', prep["run"])
        names = [s.get("name") for s in steps()]
        self.assertLess(names.index("Prepare the dependency bench"), names.index("Mint, join, verify and revoke"))
        mint = step("Mint, join, verify and revoke")
        self.assertEqual(mint["env"]["BENCH"], "${{ inputs.bench }}")
        self.assertIn('bench=(--bench "$JOIN_BASE/bin/deps-bench.sh")', mint["run"])
        self.assertIn("deps | deps-slow)", mint["run"])
        # Every cache the bench fills is under the base, never in the home the harness scans.
        script = (ROOT / "scripts/cmux-next/deps-bench.sh").read_text(encoding="utf-8")
        for var in ("CARGO_HOME", "BUN_INSTALL", "BUN_INSTALL_CACHE_DIR", "XDG_CACHE_HOME", "TMPDIR"):
            self.assertRegex(script, rf'export {var}="\$bench/')
        self.assertNotIn("$HOME", script)

    def test_share_is_opt_in_secret_free_and_development_only(self) -> None:
        # Off by default; every share step is gated on it, holds no secret, and runs before the mint step.
        share = load()["on"]["workflow_dispatch"]["inputs"]["share"]
        self.assertEqual((share["type"], share["default"]), ("boolean", "false"))
        names = [s.get("name") for s in steps()]
        for name in ("Install the share's display server", "Build cmux-rd", "Prepare the share"):
            s = step(name)
            self.assertEqual(s["if"], "inputs.share", name)
            self.assertNotIn("secrets", str(s), name)
            self.assertNotIn("CMUX_UITEST_STACK", str(s), name)
            self.assertLess(names.index(name), names.index("Mint, join, verify and revoke"), name)
        # cmux-rd from the run's commit only (the one checkout), with the release features.
        build = step("Build cmux-rd")["run"]
        self.assertIn("--manifest-path \"$manifest\" --no-default-features --features openh264,link --bin cmux-rd", build)
        self.assertIn("--locked", build)
        # Root-owned beside acpmux; the joined home only links to it, where the host's user unit runs it.
        prep = step("Prepare the share")["run"]
        self.assertIn('sudo install -o root -g root -m 0755 "$CMUX_RD_BIN" "$JOIN_BASE/bin/cmux-rd"', prep)
        self.assertIn('ln -s "$1" "$HOME/.local/bin/cmux-rd"', prep)
        # The viewer is a disposable user of its own, recorded before it exists so its removal always runs.
        self.assertLess(prep.index('echo "viewer=$viewer"'), prep.index("sudo useradd"))
        self.assertIn('sudo loginctl enable-linger "$JOIN_USER"', prep)
        # The user manager is started explicitly and its own socket waited for (not the optional session bus);
        # nothing of the host is run directly.
        self.assertLess(prep.index('sudo loginctl enable-linger "$JOIN_USER"'), prep.index('systemctl start "$manager"'))
        self.assertIn('private="/run/user/$JOIN_UID/systemd/private"', prep)
        self.assertNotIn("linux-host", prep)
        # Nothing of the share runs on the joined machine: the daemon sets the host up itself, so no step
        # (and not the harness) runs `linux-host enable` or hands cmux-rd an ACPMUX_HOME.
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertNotIn("linux-host enable", text)
        self.assertNotIn("ACPMUX_HOME", text)
        self.assertNotIn('"linux-host", "enable"', script := SCRIPT.read_text(encoding="utf-8"))
        self.assertNotIn("ACPMUX_HOME=", script)
        # /run/user/UID is the joined user's (0700): the runner's own `[ -S ]` never sees inside it (run
        # 44039047306 read "no" with the socket there), so every test of it runs as root. The manager is judged
        # by is-active, not by its start's exit status (1 there, with the manager up).
        self.assertNotRegex(prep, r'\[ !? ?-S "\$(private|bus)" \]')
        self.assertIn('sudo test -S "$private"', prep)
        self.assertIn('sudo systemctl is-active --quiet "$manager"', prep)
        self.assertNotIn('systemctl start "$manager" && started=1', prep)
        # The development device hub only, in the workflow and the script.
        document = load()
        self.assertEqual(workflow_jobs.effective_env(document, document["jobs"]["e2e"])["DEVICE_HUB"], "https://cmux-device-hub-dev.debussy.workers.dev")
        script = SCRIPT.read_text(encoding="utf-8")
        self.assertIn('export const DEV_DEVICE_HUB = "https://cmux-device-hub-dev.debussy.workers.dev"', script)
        self.assertIn("if (sh.hub !== DEV_DEVICE_HUB)", script)
        mint = step("Mint, join, verify and revoke")
        self.assertEqual(mint["env"]["SHARE"], "${{ inputs.share }}")
        self.assertIn('if [ "$SHARE" = true ]; then', mint["run"])
        self.assertIn('--device-hub "$DEVICE_HUB"', mint["run"])
        # The viewer and the joined user's lingering user manager are removed always, the viewer before the base.
        viewer = step("Remove the viewer user")
        self.assertEqual(viewer["if"], "always() && steps.share.outputs.viewer != ''")
        self.assertIn('sudo userdel --remove "$VIEWER_USER"', viewer["run"])
        self.assertLess(names.index("Remove the viewer user"), names.index("Remove the disposable user"))
        remove = step("Remove the disposable user")["run"]
        self.assertLess(remove.index('sudo loginctl disable-linger "$JOIN_USER"'), remove.index("/bin/kill -KILL -1"))

    def test_share_install_channel_tests_the_join_install_path(self) -> None:
        # build (the default) keeps placing the run's cmux-rd, which tests the commit; channel places none,
        # and the join line's own cmux-rd step installs it from the channel, checked against its sha256.
        share_install = load()["on"]["workflow_dispatch"]["inputs"]["share_install"]
        self.assertEqual((share_install["type"], share_install["default"]), ("choice", "build"))
        self.assertEqual(share_install["options"], ["build", "channel"])
        resolve = step("Resolve inputs")
        self.assertEqual(resolve["env"]["SHARE_INSTALL"], "${{ inputs.share_install }}")
        self.assertIn('if [ "$SHARE_INSTALL" = channel ] && [ "$SHARE" != true ]; then', resolve["run"])
        prep = step("Prepare the share")
        self.assertEqual(prep["env"]["SHARE_INSTALL"], "${{ inputs.share_install }}")
        run = prep["run"]
        channel = run.index('if [ "$SHARE_INSTALL" = channel ]; then')
        otherwise = run.index("else", channel)
        done = run.index("fi\n", run.index('ln -s "$1" "$HOME/.local/bin/cmux-rd"'))
        # The link is only in the build branch; the viewer's root-owned copy is made in both.
        self.assertLess(otherwise, run.index('ln -s "$1" "$HOME/.local/bin/cmux-rd"'))
        self.assertLess(run.index('ln -s "$1" "$HOME/.local/bin/cmux-rd"'), done)
        self.assertLess(run.index('sudo install -o root -g root -m 0755 "$CMUX_RD_BIN" "$JOIN_BASE/bin/cmux-rd"'), channel)
        branch = run[channel:otherwise]
        # The join script from the run's own checkout, root-owned beside acpmux; the channel's sha256 for this
        # machine's gnu build, from files.cmux.com over https, or the run stops before any secret.
        self.assertIn('sudo install -o root -g root -m 0644 cmux-tui/scripts/machine-join.sh "$JOIN_BASE/bin/machine-join.sh"', branch)
        self.assertIn("https://files.cmux.com/cmux-tui/channels/feat-cmux-next.json", branch)
        self.assertIn("--proto '=https'", branch)
        self.assertIn('"cmux-tui-rd-$rd_target"', branch)
        self.assertIn("x86_64-unknown-linux-gnu", branch)
        self.assertIn("aarch64-unknown-linux-gnu", branch)
        self.assertIn('[ "${#rd_sha}" -ne 64 ]', branch)
        self.assertIn('echo "rd_sha256=$rd_sha" >> "$GITHUB_OUTPUT"', branch)
        self.assertNotIn("ln -s", branch)
        mint = step("Mint, join, verify and revoke")
        self.assertEqual(mint["env"]["SHARE_INSTALL"], "${{ inputs.share_install }}")
        self.assertEqual(mint["env"]["RD_SHA256"], "${{ steps.share.outputs.rd_sha256 }}")
        self.assertIn('share+=(--share-install-script "$JOIN_BASE/bin/machine-join.sh" --share-rd-sha256 "$RD_SHA256")', mint["run"])
        # The harness runs the script's cmux-rd step as the joined user and checks what it left.
        script = SCRIPT.read_text(encoding="utf-8")
        self.assertIn('"CMUX_JOIN_STEP=cmux-rd"', script)
        self.assertIn('"--share-install-script"', script)
        join = (ROOT / "cmux-tui/scripts/machine-join.sh").read_text(encoding="utf-8")
        self.assertIn("'' | signin | cmux-rd) ;;", join)

    def test_only_the_evidence_is_uploaded(self) -> None:
        uploads = [s for s in steps() if "upload-artifact" in s.get("uses", "")]
        self.assertEqual(len(uploads), 1)
        self.assertEqual(uploads[0]["with"]["path"], "${{ runner.temp }}/machine-join-e2e/evidence.json")
        # No restored build cache in a job that later holds secrets.
        self.assertFalse([s for s in steps() if re.search(r"actions/cache|rust-cache", s.get("uses", ""))])


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
