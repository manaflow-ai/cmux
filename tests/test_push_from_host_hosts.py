#!/usr/bin/env python3
"""push-from-host.sh falls through its ordered host list to the first host that answers SSH and holds the clone.

2026-11-12T00:40Z: cmux-lawrence-2, the only default host, stopped answering SSH (office power), and every sparse
worktree push the web lint sends to push-from-host.sh failed with "no host answers". The default is now an ordered
list (DEFAULT_HOSTS), each `HOST[:REPO]`. These tests run the script with a fake `ssh` on PATH and `--which-host`,
which prints the chosen `HOST REPO` and exits before anything is bundled or pushed.
"""
from __future__ import annotations

import os
import re
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "cmux-next" / "push-from-host.sh"

# The fake ssh: hosts named in DOWN exit 255 (no answer); hosts in NOCLONE answer but have no clone (exit 1).
# Every call is logged so a test can see the order the hosts were tried in.
FAKE_SSH = textwrap.dedent("""\
    #!/bin/bash
    host=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o) shift 2 ;;
            *) host="$1"; shift; break ;;
        esac
    done
    printf '%s %s\\n' "$host" "$*" >> "$FAKE_SSH_LOG"
    for h in $FAKE_SSH_DOWN; do [[ "$h" == "$host" ]] && exit 255; done
    for h in $FAKE_SSH_NOCLONE; do [[ "$h" == "$host" ]] && exit 1; done
    exit 0
""")


def default_hosts() -> list[str]:
    match = re.search(r"^DEFAULT_HOSTS=\(([^)]*)\)", SCRIPT.read_text(), re.M)
    assert match, "push-from-host.sh has no DEFAULT_HOSTS=(...) line"
    return match.group(1).split()


class PushFromHostHostsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = Path(tempfile.mkdtemp(prefix="push-from-host-test-"))
        self.addCleanup(subprocess.run, ["rm", "-rf", str(self.dir)])
        bin_dir = self.dir / "bin"
        bin_dir.mkdir()
        ssh = bin_dir / "ssh"
        ssh.write_text(FAKE_SSH)
        ssh.chmod(ssh.stat().st_mode | stat.S_IXUSR)
        self.log = self.dir / "ssh.log"
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("CMUX_PUSH_HOST")}
        self.env.update(PATH=f"{bin_dir}:{os.environ['PATH']}", FAKE_SSH_LOG=str(self.log),
                        FAKE_SSH_DOWN="", FAKE_SSH_NOCLONE="")

    def run_script(self, *args: str, **env: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["bash", str(SCRIPT), "--which-host", *args, "feat-cmux-next"],
                              env={**self.env, **env}, capture_output=True, text=True, timeout=30)

    def tried(self) -> list[str]:
        return [line.split()[0] for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_defaults_are_an_ordered_list_of_more_than_one_host(self):
        hosts = default_hosts()
        self.assertGreaterEqual(len(hosts), 2, "one default host is a single point of failure")
        self.assertEqual(len({h.split(":")[0] for h in hosts}), len(hosts), "a host is listed twice")
        for spec in hosts:
            self.assertRegex(spec, r"^[A-Za-z0-9._@-]+(:[A-Za-z0-9._/-]+)?$")

    def test_first_default_that_answers_is_used(self):
        hosts = default_hosts()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        first, _, repo = hosts[0].partition(":")
        self.assertEqual(result.stdout.split()[0], first)
        self.assertEqual(self.tried(), [first], "a host after the first that answered was probed")

    def test_a_down_default_falls_through_to_the_next(self):
        hosts = default_hosts()
        down = hosts[0].split(":")[0]
        nxt, _, repo = hosts[1].partition(":")
        result = self.run_script(FAKE_SSH_DOWN=down)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split(), [nxt, repo or "fun/cmux"])
        self.assertEqual(self.tried(), [down, nxt])
        self.assertIn(f"{down} does not answer SSH", result.stderr)

    def test_a_host_without_the_clone_falls_through(self):
        result = self.run_script("--host", "a:fun/cmux", "--host", "b:Projects/cmux", FAKE_SSH_NOCLONE="a")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split(), ["b", "Projects/cmux"])
        self.assertIn("a has no clone at ~/fun/cmux", result.stderr)

    def test_every_host_down_is_exit_2_naming_them_all(self):
        result = self.run_script("--host", "a", "--host", "b", FAKE_SSH_DOWN="a b")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.tried(), ["a", "b"])
        self.assertIn("no host answers SSH (a b)", result.stderr)

    def test_env_list_and_repo_override_still_work(self):
        result = self.run_script(CMUX_PUSH_HOST="x y", CMUX_PUSH_HOST_REPO="src/cmux", FAKE_SSH_DOWN="x")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split(), ["y", "src/cmux"])

    def test_a_host_spec_with_shell_characters_is_refused(self):
        result = self.run_script("--host", "a;rm")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.tried(), [])
        result = self.run_script("--host", "a:$(x)")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.tried(), [])


if __name__ == "__main__":
    unittest.main()
