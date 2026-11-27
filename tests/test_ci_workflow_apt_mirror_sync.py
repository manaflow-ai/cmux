#!/usr/bin/env python3
"""Ratchet: an apt install in a workflow survives a Debian mirror that is mid-sync.

Handbook install-on-a-stale-package-list (mirror-sync section). On 2026-11-27, 10 false reds in 24 h were
"Swift packages on Linux" failing `apt-get update -qq && apt-get install ...` with "E: Failed to fetch <url>
File has unexpected size ... Mirror sync in progress?": a rerun a minute later was green. Fix at the class:

  * scripts/ci/apt-retry.sh runs update + install with Acquire::Retries and, only on a mirror-sync message
    (unexpected size, Hash Sum mismatch, ...), updates and installs again; any other failure stays red at once.
  * a line in .github/ that runs `apt-get update` must carry Acquire::Retries, or be in LEGACY below.

LEGACY counts the bare `apt-get update` lines that predate this ratchet, per file. A file may not gain one; a
file that loses one must lower its number here (the test says so), so the list only shrinks.
"""

from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "apt-retry.sh"

LEGACY = {
    ".github/actions/pr-media-publish/action.yml": 1,
    ".github/workflows/app-ffi-release.yml": 1,
    ".github/workflows/app-store-shelf.yml": 1,
    ".github/workflows/backend.yml": 1,
    ".github/workflows/cloud-capture-provision.yml": 1,
    ".github/workflows/cloud-chat-proof.yml": 1,
    ".github/workflows/cloud-chief-machine.yml": 1,
    ".github/workflows/cloud-chief-start.yml": 1,
    ".github/workflows/cloud-harness-matrix.yml": 1,
    ".github/workflows/cloud-journey-pr.yml": 2,
    ".github/workflows/cloud-journey-prod.yml": 2,
    ".github/workflows/cloud-resume-matrix.yml": 1,
    ".github/workflows/cloudflare-relay.yml": 1,
    ".github/workflows/cmux-browser-host-chromium.yml": 1,
    ".github/workflows/cmux-duress.yml": 1,
    ".github/workflows/cmux-next-base-autofix.yml": 1,
    ".github/workflows/cmux-next-car-guards.yml": 1,
    ".github/workflows/cmux-next-fast-gates.yml": 1,
    ".github/workflows/cmux-next-hot-verify.yml": 1,
    ".github/workflows/cmux-next-iphone-clips.yml": 1,
    ".github/workflows/cmux-next-media.yml": 2,
    ".github/workflows/cmux-next-pr-autofix.yml": 1,
    ".github/workflows/cmux-next-shell-integration.yml": 1,
    ".github/workflows/cmux-next-source-archive.yml": 1,
    ".github/workflows/cmux-next.yml": 1,
    ".github/workflows/cmux-tui-headless-debug.yml": 1,
    ".github/workflows/cmux-tui-sdks.yml": 4,
    ".github/workflows/cmux-tui-testbox-warmup.yml": 1,
    ".github/workflows/cmux-tui-windows-check.yml": 1,
    ".github/workflows/cmux-tui.yml": 6,
    ".github/workflows/cmux-vm-secrets-seal.yml": 1,
    ".github/workflows/fast-checks.yml": 1,
    ".github/workflows/gateway-e2e.yml": 1,
    ".github/workflows/internal-token-staging.yml": 1,
    ".github/workflows/ios-link-ffi-linux.yml": 1,
    ".github/workflows/migrate-journey-pr.yml": 1,
    ".github/workflows/nightly.yml": 1,
    ".github/workflows/pool-build-path.yml": 1,
    ".github/workflows/repro-capsule-journey.yml": 1,
    ".github/workflows/rfd0135-gates.yml": 1,
    ".github/workflows/rust-workspaces.yml": 1,
    ".github/workflows/screen-share-drop-gate.yml": 1,
    ".github/workflows/sdk-publish-crates.yml": 1,
    ".github/workflows/sdk-publish-go.yml": 1,
    ".github/workflows/sdk-publish-java.yml": 1,
    ".github/workflows/sdk-publish-npm.yml": 1,
    ".github/workflows/sdk-publish-python.yml": 1,
    ".github/workflows/tailnet-stable-node-move.yml": 1,
}


def bare_update_lines(path: Path) -> int:
    count = 0
    for line in path.read_text(encoding="utf-8").splitlines():
        if "apt-get update" in line and "Acquire::Retries" not in line and not line.lstrip().startswith("#"):
            count += 1
    return count


class WorkflowRatchet(unittest.TestCase):
    def test_no_new_bare_apt_get_update(self) -> None:
        files = sorted((ROOT / ".github" / "workflows").glob("*.yml")) + sorted((ROOT / ".github" / "actions").glob("*/action.yml"))
        problems = []
        for path in files:
            rel = path.relative_to(ROOT).as_posix()
            found, allowed = bare_update_lines(path), LEGACY.get(rel, 0)
            if found > allowed:
                problems.append(f"{rel}: {found} bare `apt-get update` (allowed {allowed}); use `bash scripts/ci/apt-retry.sh -y PKG...` "
                                "after a checkout, else add `-o Acquire::Retries=3` and retry the step's update+install")
            elif found < allowed:
                problems.append(f"{rel}: {found} bare `apt-get update` left, LEGACY says {allowed}; lower it (or delete the entry)")
        self.assertEqual(problems, [], "\n" + "\n".join(problems))

    def test_the_swift_linux_installs_use_the_retrying_script(self) -> None:
        text = (ROOT / ".github" / "workflows" / "swift-linux-packages.yml").read_text(encoding="utf-8")
        self.assertNotIn("apt-get update", text)
        self.assertIn("scripts/ci/apt-retry.sh", text)


def write_stub(directory: Path, name: str, body: str) -> None:
    path = directory / name
    path.write_text("#!/usr/bin/env bash\n" + body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class AptRetryScript(unittest.TestCase):
    def run_script(self, update_failures: list[str], install_error: str = "") -> tuple[int, int, str]:
        """Run with an apt-get stub whose first updates print the given errors and fail."""
        with tempfile.TemporaryDirectory() as tmp:
            stubs = Path(tmp) / "bin"
            stubs.mkdir()
            state = Path(tmp) / "updates"
            state.write_text("0", encoding="utf-8")
            installs = Path(tmp) / "installs"
            installs.write_text("", encoding="utf-8")
            errors = Path(tmp) / "errors"
            errors.write_text("\n".join(update_failures), encoding="utf-8")
            write_stub(stubs, "apt-get", f"""
if [ "$1" = update ]; then
  n=$(cat {state}); echo $((n + 1)) > {state}
  line=$(sed -n "$((n + 1))p" {errors})
  [ -n "$line" ] && {{ echo "$line" >&2; exit 100; }}
  exit 0
fi
echo "$*" >> {installs}
[ -n "{install_error}" ] && {{ echo "{install_error}" >&2; exit 100; }}
exit 0
""")
            write_stub(stubs, "sudo", 'shift; exec "$@"\n')
            write_stub(stubs, "id", 'echo 0\n')
            write_stub(stubs, "sleep", "exit 0\n")
            env = {**os.environ, "PATH": f"{stubs}:/usr/bin:/bin", "APT_RETRY_PAUSE_S": "0"}
            result = subprocess.run(["bash", str(SCRIPT), "-y", "python3"], env=env, text=True,
                                    capture_output=True, check=False)
            return result.returncode, int(state.read_text()), installs.read_text()

    def test_clean_run_updates_and_installs_once(self) -> None:
        rc, updates, installs = self.run_script([])
        self.assertEqual((rc, updates), (0, 1))
        self.assertIn("-y python3", installs)

    def test_mirror_sync_is_retried_with_a_fresh_update(self) -> None:
        err = "E: Failed to fetch http://archive.ubuntu.com/x File has unexpected size (1 != 2). Mirror sync in progress?"
        rc, updates, _ = self.run_script([err, err])
        self.assertEqual((rc, updates), (0, 3))

    def test_a_mirror_that_never_settles_stays_red(self) -> None:
        err = "E: Failed to fetch http://archive.ubuntu.com/x Hash Sum mismatch"
        rc, updates, _ = self.run_script([err] * 10)
        self.assertEqual((rc, updates), (100, 4))

    def test_a_real_failure_is_not_retried(self) -> None:
        rc, updates, _ = self.run_script([], install_error="E: Unable to locate package nonesuch")
        self.assertEqual((rc, updates), (100, 1))


if __name__ == "__main__":
    unittest.main()
