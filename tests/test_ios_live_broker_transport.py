#!/usr/bin/env python3
"""scripts/ios-live/ios-live reaches the slot Macs through the lane-gh broker relay.

Regression: the client sent host.sh in the command, gzipped and base64'd, whenever that was under 200000 bytes.
host.sh grew to 40402 bytes, the command to over 18000, and the broker relay, which takes at most 16384 bytes and
carries no stdin, refused every ios-live command from a lane VM ("cmd must be 1 to 16384 bytes of text").

The client now names a commit on origin, and the host reads host.sh at that commit from its own git. Here a stand-in
`reach` refuses any command over 16384 bytes and gives the host no stdin; host.sh is a stub padded to 100 KB that
reports what it got, and the host's "fleet mirror" and "GitHub" are local bare repos.
"""
from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLIENT_SRC = ROOT / "scripts" / "ios-live" / "ios-live"
CAP = 16384
SESSION_VARS = ("IOS_LIVE_OWNER", "CLAUDE_CODE_SESSION_ID", "CLAUDE_SESSION_ID", "CODEX_THREAD_ID",
                "CODEX_SESSION_ID", "IOS_LIVE_HOST", "IOS_LIVE_AT", "IOS_LIVE_PERSON", "IOS_LIVE_REPO_URL")

# reach HOST CMD: the broker relay. Over CAP bytes it refuses, as the relay does; it never passes stdin on.
REACH = f"""#!/usr/bin/env bash
shift
cmd="$*"
n="$(printf %s "$cmd" | wc -c | tr -d ' ')"
echo "$n" >>"$FAKE_REACH_LOG"
if (( n < 1 || n > {CAP} )); then
  echo "reach: fakehost: the broker relay refused: refused: cmd must be 1 to {CAP} bytes of text" >&2
  exit 1
fi
HOME="$FAKE_HOST_HOME" CMUX_CI_STEP_GLAEDA_MIRROR_DIR="$FAKE_MIRROR_DIR" exec bash -c "$cmd" </dev/null
"""

# The host.sh the host runs: says which copy it is and echoes its args; for swift it hashes the patch it was handed.
STUB = """#!/usr/bin/env bash
echo "stub=$STUB_TAG"
echo "args=$*"
case "$1" in
  slots) printf '1\\tnot up\\tfree\\n' ;;
  swift|swap) shasum -a 256 "$HOME/$4" | cut -d' ' -f1 ;;
esac
"""


def git(cwd: Path, *args: str) -> str:
    env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t",
               GIT_COMMITTER_EMAIL="t@t", GIT_CONFIG_NOSYSTEM="1")
    return subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True, text=True,
                          env=env).stdout.strip()


def stub(tag: str, pad: int) -> str:
    body = STUB.replace("$STUB_TAG", tag)
    line = "# padding " + "x" * 90 + "\n"
    while len(body) < pad:
        body += line
    return body


class IosLiveBrokerTransport(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="ios-live-broker-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        (bin_dir / "reach").write_text(REACH)
        (bin_dir / "reach").chmod(0o755)
        self.log = self.tmp / "reach.log"
        self.host_home = self.tmp / "host-home"
        self.host_home.mkdir()
        # GitHub: what is pushed. The fleet mirror: a full clone the host reads from without a fetch.
        self.github = self.tmp / "github.git"
        git(self.tmp, "init", "-q", "--bare", "-b", "feat-cmux-next", str(self.github))
        git(self.github, "config", "uploadpack.allowFilter", "true")
        git(self.github, "config", "uploadpack.allowAnySHA1InWant", "true")
        self.co = self.tmp / "checkout"
        git(self.tmp, "init", "-q", "-b", "feat-cmux-next", str(self.co))
        (self.co / "scripts" / "ios-live").mkdir(parents=True)
        shutil.copy(CLIENT_SRC, self.co / "scripts" / "ios-live" / "ios-live")
        (self.co / "cmux-next-ios").mkdir()
        (self.co / "cmux-next-ios" / "A.swift").write_text("let a = 1\n")
        self.commit_host_sh("base", 100_000)
        self.mirror_dir = self.tmp / "fleet-git"
        self.mirror_dir.mkdir()
        git(self.tmp, "clone", "-q", "--mirror", str(self.github), str(self.mirror_dir / "cmux.git"))
        self.env = {k: v for k, v in os.environ.items() if k not in SESSION_VARS}
        self.env.update(PATH=f"{bin_dir}{os.pathsep}{os.environ['PATH']}", FAKE_HOST_HOME=str(self.host_home),
                        FAKE_MIRROR_DIR=str(self.mirror_dir), FAKE_REACH_LOG=str(self.log),
                        XDG_CACHE_HOME=str(self.tmp / "cache"), IOS_LIVE_HOSTS="fakehost",
                        IOS_LIVE_SLOTS_PER_HOST="3", IOS_LIVE_REPO_URL=f"file://{self.github}",
                        IOS_LIVE_OWNER="tester")

    def commit_host_sh(self, tag: str, pad: int) -> str:
        (self.co / "scripts" / "ios-live" / "host.sh").write_text(stub(tag, pad))
        git(self.co, "add", "-A")
        git(self.co, "commit", "-q", "-m", tag)
        if not git(self.co, "remote"):
            git(self.co, "remote", "add", "origin", str(self.github))
        git(self.co, "push", "-q", "origin", "HEAD:feat-cmux-next")
        git(self.co, "fetch", "-q", "origin")
        return git(self.co, "rev-parse", "HEAD")

    def run_client(self, *args: str, **extra: str) -> subprocess.CompletedProcess:
        self.log.write_text("")
        return subprocess.run([str(self.co / "scripts" / "ios-live" / "ios-live"), *args], cwd=self.co,
                              env=dict(self.env, **extra), capture_output=True, text=True, timeout=60,
                              stdin=subprocess.DEVNULL)

    def sizes(self) -> list[int]:
        return [int(x) for x in self.log.read_text().split()]

    def ok(self, *args: str, **extra: str) -> subprocess.CompletedProcess:
        r = self.run_client(*args, **extra)
        self.assertEqual(r.returncode, 0, f"ios-live {' '.join(args)}: {r.stdout}\n{r.stderr}")
        for n in self.sizes():
            self.assertLessEqual(n, CAP)
        return r

    def test_command_size_does_not_grow_with_host_sh(self) -> None:
        self.assertGreaterEqual((self.co / "scripts/ios-live/host.sh").stat().st_size, 100_000)
        r = self.ok("slots")
        self.assertIn("fakehost/1\tnot up\tfree", r.stdout)
        self.assertEqual(r.stderr, "")
        big = self.sizes()
        self.assertEqual(len(big), 1)  # one round trip
        # The same command with a 2 KB host.sh is exactly as long: only the sha differs, and it is fixed length.
        self.commit_host_sh("small", 2_000)
        self.ok("slots")
        self.assertEqual(self.sizes(), big)
        self.assertLess(big[0], 4096)

    def test_cached_by_sha_then_no_git_needed(self) -> None:
        sha = git(self.co, "rev-parse", "HEAD")
        self.ok("status", IOS_LIVE_AT="fakehost/1")
        cached = self.host_home / "ios-live" / "bin" / sha / "host.sh"
        self.assertEqual(cached.read_text(), (self.co / "scripts/ios-live/host.sh").read_text())
        # With the mirror gone and GitHub unreachable, the cached copy still answers.
        shutil.rmtree(self.mirror_dir)
        r = self.ok("status", IOS_LIVE_AT="fakehost/1", IOS_LIVE_REPO_URL="file:///nonexistent")
        self.assertIn("stub=base", r.stdout)

    def test_fresh_push_the_mirror_lacks_comes_from_github(self) -> None:
        self.commit_host_sh("pushed", 100_000)  # on GitHub, not in the fleet mirror
        r = self.ok("status", IOS_LIVE_AT="fakehost/1")
        self.assertIn("stub=pushed", r.stdout)
        self.assertTrue((self.host_home / "ios-live" / "hostsh.git").is_dir())

    def test_unpushed_host_sh_says_which_copy_runs(self) -> None:
        sha = git(self.co, "rev-parse", "HEAD")
        (self.co / "scripts/ios-live/host.sh").write_text(stub("local-edit", 100_000))
        r = self.ok("status", IOS_LIVE_AT="fakehost/1")
        self.assertIn("stub=base", r.stdout)
        self.assertIn(f"ios-live: host.sh at {sha[:12]} is used; push your host.sh change to try it", r.stderr)

    def test_unknown_sha_fails_loudly(self) -> None:
        shutil.rmtree(self.mirror_dir)
        r = self.run_client("status", IOS_LIVE_AT="fakehost/1", IOS_LIVE_REPO_URL="file:///nonexistent")
        self.assertEqual(r.returncode, 69, r.stdout + r.stderr)
        self.assertIn("the host has no host.sh at", r.stderr)

    def test_patch_rides_in_the_command_under_the_cap(self) -> None:
        (self.co / "cmux-next-ios" / "A.swift").write_text("let a = 2\n" + "// edit\n" * 300)
        r = self.ok("swift", IOS_LIVE_AT="fakehost/1")
        diff = git(self.co, "diff", "--binary", "HEAD") + "\n"
        self.assertIn(hashlib.sha256(diff.encode()).hexdigest(), r.stdout)
        self.assertIn("args=swift tester", r.stdout)

    def test_patch_over_the_cap_is_refused_before_reach(self) -> None:
        (self.co / "cmux-next-ios" / "Big.swift").write_text(os.urandom(12_000).hex())
        r = self.run_client("swap", IOS_LIVE_AT="fakehost/1")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("the broker relay takes at most 16384", r.stderr)
        self.assertIn("ios-live up YOUR_SHA", r.stderr)
        self.assertEqual(self.sizes(), [])


if __name__ == "__main__":
    sys.exit(unittest.main())
