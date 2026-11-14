#!/usr/bin/env python3
"""tests/git_fixture_env.py and scripts/cmux-next/tests/lib/git-fixture.sh reach the receiving side of a push.

Git's local transport starts `git receive-pack` with GIT_CONFIG_COUNT cleared, and receive-pack starts its own
detached `git maintenance run --auto` in the bare repository (cmux#40871, Codex F3). A pre-receive hook in the
bare repository records what receive-pack sees; it must see maintenance.auto=false and gc.auto=0 even when the
pushing side's environment carries none of the opt-out. Run: python3 -I tests/test_git_fixture_env.py
"""
import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("git_fixture_env", ROOT / "tests" / "git_fixture_env.py")
git_fixture_env = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(git_fixture_env)

HOOK = """#!/bin/sh
{
  printf 'count=%s\\n' "${GIT_CONFIG_COUNT:-unset}"
  printf 'maintenance.auto=%s\\n' "$(git config maintenance.auto)"
  printf 'gc.auto=%s\\n' "$(git config gc.auto)"
  printf 'receive.autogc=%s\\n' "$(git config receive.autogc)"
} > "$RECORD"
cat >/dev/null
"""


class ReceiverSeesOptOut(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.record = self.root / "record"
        # The worst case: the pusher's environment has none of the helper's GIT_CONFIG_* pairs and no global
        # config (stripped here on purpose), so only the bare repository's own config can turn maintenance off
        # on the receiving side.
        self.bare_env = {key: value for key, value in git_fixture_env.fixture_env().items()
                         if not key.startswith("GIT_")}
        self.bare_env.update(HOME=str(self.root), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1",
                             GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t",
                             GIT_COMMITTER_EMAIL="t@t", RECORD=str(self.record))
        self.bare_env.pop("CMUX_GIT_FIXTURE_GLOBAL_DIR", None)

    def git(self, *args, cwd):
        return subprocess.run(["git", *args], cwd=cwd, env=self.bare_env, check=True, capture_output=True,
                              text=True, stdin=subprocess.DEVNULL).stdout

    def hook(self, bare: Path):
        hook = bare / "hooks" / "pre-receive"
        hook.write_text(HOOK)
        hook.chmod(0o755)

    def push_and_read(self, bare: Path, env: dict | None = None) -> dict:
        work = git_fixture_env.init_repo(self.root / "work", "-b", "main", env=self.bare_env)
        (work / "a").write_text("a\n")
        self.git("add", "a", cwd=work)
        self.git("commit", "-q", "-m", "a", cwd=work)
        # A new branch on the receiver, so a seeded remote's own main never makes it a non-fast-forward.
        subprocess.run(["git", "push", "-q", str(bare), "main:refs/heads/incoming"], cwd=work, env=env or self.bare_env, check=True,
                       capture_output=True, text=True, stdin=subprocess.DEVNULL)
        return dict(line.split("=", 1) for line in self.record.read_text().splitlines())

    def test_control_env_pairs_do_not_reach_the_receiver(self):
        # The pusher carries the GIT_CONFIG_* opt-out; a bare repository without it in its own config still
        # sees none: the hole repository config closes. receive.autogc stays false so the control itself
        # starts no maintenance.
        bare = git_fixture_env.init_repo(self.root / "plain.git", "--bare", env=self.bare_env)
        for key in ("maintenance.auto", "gc.auto"):
            self.git("-C", str(bare), "config", "--unset", key, cwd=self.root)
        self.hook(bare)
        pusher = git_fixture_env.without_auto_maintenance(dict(self.bare_env))
        seen = self.push_and_read(bare, env=pusher)
        print(f"receiver (control, env pairs only): {seen}")
        self.assertEqual(seen["count"], "unset", seen)
        self.assertEqual(seen["maintenance.auto"], "", seen)

    def test_python_init_repo_bare_receiver_sees_opt_out(self):
        bare = git_fixture_env.init_repo(self.root / "remote.git", "--bare", "-b", "main", env=self.bare_env)
        self.hook(bare)
        seen = self.push_and_read(bare)
        print(f"receiver (init_repo): {seen}")
        self.assertEqual(seen["maintenance.auto"], "false", seen)
        self.assertEqual(seen["gc.auto"], "0", seen)
        self.assertEqual(seen["receive.autogc"], "false", seen)

    def test_python_clone_repo_bare_receiver_sees_opt_out(self):
        seed = git_fixture_env.init_repo(self.root / "seed", "-b", "main", env=self.bare_env)
        self.git("commit", "-q", "--allow-empty", "-m", "seed", cwd=seed)
        bare = git_fixture_env.clone_repo(seed, self.root / "clone.git", "--bare", env=self.bare_env)
        self.hook(bare)
        seen = self.push_and_read(bare)
        print(f"receiver (clone_repo): {seen}")
        self.assertEqual(seen["maintenance.auto"], "false", seen)
        self.assertEqual(seen["gc.auto"], "0", seen)

    def test_shell_git_fixture_init_bare_receiver_sees_opt_out(self):
        bare = self.root / "shell.git"
        lib = ROOT / "scripts/cmux-next/tests/lib/git-fixture.sh"
        subprocess.run(["bash", "-c", 'source "$1" && git_fixture_init --bare -b main "$2"', "_", str(lib), str(bare)],
                       env=self.bare_env, check=True, capture_output=True, text=True, stdin=subprocess.DEVNULL)
        self.hook(bare)
        seen = self.push_and_read(bare)
        print(f"receiver (git_fixture_init): {seen}")
        self.assertEqual(seen["maintenance.auto"], "false", seen)
        self.assertEqual(seen["gc.auto"], "0", seen)

    def test_shell_git_fixture_clone_bare_receiver_sees_opt_out(self):
        seed = git_fixture_env.init_repo(self.root / "seed", "-b", "main", env=self.bare_env)
        self.git("commit", "-q", "--allow-empty", "-m", "seed", cwd=seed)
        bare = self.root / "shell-clone.git"
        lib = ROOT / "scripts/cmux-next/tests/lib/git-fixture.sh"
        subprocess.run(["bash", "-c", 'source "$1" && git_fixture_clone --bare "$2" "$3"', "_", str(lib), str(seed),
                        str(bare)], env=self.bare_env, check=True, capture_output=True, text=True,
                       stdin=subprocess.DEVNULL)
        self.hook(bare)
        seen = self.push_and_read(bare)
        self.assertEqual(seen["maintenance.auto"], "false", seen)


class EnvironmentLayers(unittest.TestCase):
    def test_fixture_env_restores_what_a_filtered_env_drops(self):
        scratch = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": "/nonexistent-home"}
        env = git_fixture_env.fixture_env(scratch)
        pairs = {env[f"GIT_CONFIG_KEY_{i}"]: env[f"GIT_CONFIG_VALUE_{i}"] for i in range(int(env["GIT_CONFIG_COUNT"]))}
        self.assertEqual(pairs, dict(git_fixture_env.OPT_OUT))
        no_home = git_fixture_env.fixture_env({"PATH": scratch["PATH"]})
        for case in (env, no_home):
            out = subprocess.run(["git", "config", "--global", "maintenance.auto"], env=case, capture_output=True,
                                 text=True, stdin=subprocess.DEVNULL)
            self.assertEqual(out.stdout.strip(), "false", out.stderr)

    def test_fixture_env_keeps_a_named_global_config(self):
        env = git_fixture_env.fixture_env({"GIT_CONFIG_GLOBAL": os.devnull})
        self.assertEqual(env["GIT_CONFIG_GLOBAL"], os.devnull)

    def test_without_auto_maintenance_is_idempotent(self):
        env = git_fixture_env.without_auto_maintenance({})
        again = git_fixture_env.without_auto_maintenance(dict(env))
        self.assertEqual(env, again)


if __name__ == "__main__":
    unittest.main()
