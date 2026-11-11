#!/usr/bin/env python3
"""The git fixture helpers keep their GIT_CONFIG_GLOBAL file where no other user can plant or swap it.

cmux#40871 (Codex F1, security): at 40d04402 scripts/cmux-next/tests/lib/git-fixture.sh used
${TMPDIR:-/tmp}/cmux-git-fixture-$UID-v1.gitconfig, a predictable name in a shared folder, and reused a file
already there. Another user could precreate it, or change it after a test sourced the helper, adding
core.hooksPath: an injected pre-commit hook then ran in every fixture repository. tests/git_fixture_env.py
trusted any inherited CMUX_GIT_FIXTURE_GLOBAL_DIR holding a home.gitconfig. Both now write only inside a fresh
private folder (mktemp -d / tempfile.mkdtemp: ours, mode 0700, not a symlink) and remove it at exit.
Codex F2: an explicitly empty GIT_CONFIG_GLOBAL (no global config) is kept, not replaced.
Run: python3 -I tests/test_git_fixture_tmp_safety.py
"""
import importlib.util
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "tests" / "git_fixture_env.py"
LIB = ROOT / "scripts/cmux-next/tests/lib/git-fixture.sh"
_spec = importlib.util.spec_from_file_location("git_fixture_env", HELPER)
git_fixture_env = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(git_fixture_env)

PYTHON_VICTIM = """
import importlib.util, os, subprocess, sys
spec = importlib.util.spec_from_file_location("git_fixture_env", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(os.environ.get("GIT_CONFIG_GLOBAL", "<unset>"))
print(module.fixture_env().get("GIT_CONFIG_GLOBAL", "<unset>"))
if len(sys.argv) > 2:
    repo = module.init_repo(sys.argv[2], "-b", "main")
    subprocess.run(["git", "commit", "-q", "--allow-empty", "-m", "x"], cwd=repo, env=module.fixture_env(),
                   check=True, capture_output=True)
"""


class SharedTempAttack(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        # The shared temp folder another user can write (sticky and world-writable, like /tmp).
        self.shared = self.root / "shared-tmp"
        self.shared.mkdir()
        self.shared.chmod(0o1777)
        self.marker = self.root / "PWNED"
        hooks = self.root / "evil-hooks"
        hooks.mkdir()
        (hooks / "pre-commit").write_text(f"#!/bin/sh\necho injected > '{self.marker}'\n")
        (hooks / "pre-commit").chmod(0o755)
        self.evil = f"[core]\n\thooksPath = {hooks}\n"
        self.predictable = self.shared / f"cmux-git-fixture-{os.getuid()}-v1.gitconfig"
        (self.root / "home").mkdir()
        # A session with no opt-out of its own: the helper under test must make it.
        self.env = {key: value for key, value in git_fixture_env.fixture_env().items()
                    if not key.startswith("GIT_") and key != "CMUX_GIT_FIXTURE_GLOBAL_DIR"}
        self.env.update(HOME=str(self.root / "home"), TMPDIR=str(self.shared), GIT_CONFIG_NOSYSTEM="1",
                        GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t",
                        GIT_COMMITTER_EMAIL="t@t", EVIL=self.evil, PREDICTABLE=str(self.predictable))

    def bash(self, script: str, env: dict | None = None) -> subprocess.CompletedProcess:
        return subprocess.run(["bash", "-c", script, "_", str(LIB)], env=env or self.env, cwd=self.root,
                              capture_output=True, text=True, stdin=subprocess.DEVNULL)

    def assert_private(self, config: str, recorded: str):
        """recorded: the folder's `kind uid mode` as the process saw it while it ran (it is gone after exit)."""
        self.assertNotEqual(Path(config), self.predictable)
        self.assertEqual(recorded.split(), ["dir", str(os.getuid()), "700"], f"{config}: {recorded}")

    def test_shell_ignores_a_planted_then_swapped_shared_config(self):
        self.predictable.write_text(self.evil)
        self.predictable.chmod(0o666)
        done = self.bash(
            'source "$1" || exit 9\n'
            'printf "%s\\n" "$GIT_CONFIG_GLOBAL" > global-path\n'
            # Ownership and mode of the folder while the shell runs (Linux stat, else BSD stat).
            'd=$(dirname "$GIT_CONFIG_GLOBAL"); [[ -d "$d" && ! -L "$d" ]] && k=dir || k=other\n'
            '{ echo "$k $(stat -c "%u %a" "$d" 2>/dev/null || stat -f "%u %Lp" "$d")"; } > global-stat\n'
            # The other user rewrites the shared file after the test sourced the helper (Codex's repro).
            'printf "%s" "$EVIL" > "$PREDICTABLE" 2>/dev/null || true\n'
            'git_fixture_init -b main repo && cd repo && git commit -q --allow-empty -m x\n')
        self.assertEqual(done.returncode, 0, done.stderr)
        config = (self.root / "global-path").read_text().strip()
        print(f"shell GIT_CONFIG_GLOBAL={config}; hook ran={self.marker.exists()}")
        self.assertFalse(self.marker.exists(), "a hook planted through the shared temp folder ran")
        self.assert_private(config, (self.root / "global-stat").read_text())
        self.assertFalse(Path(config).parent.exists(), "the private folder outlived the shell")

    def test_shell_keeps_an_earlier_exit_trap(self):
        done = self.bash('trap "echo earlier > earlier-ran" EXIT\nsource "$1"\n'
                         'printf "%s\\n" "$GIT_CONFIG_GLOBAL" > global-path\n')
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertTrue((self.root / "earlier-ran").exists(), "the helper replaced an existing EXIT trap")
        self.assertFalse(Path((self.root / "global-path").read_text().strip()).parent.exists())

    def test_shell_keeps_an_explicitly_empty_global_config(self):
        env = dict(self.env, GIT_CONFIG_GLOBAL="")
        done = self.bash('source "$1"\nprintf "[%s]" "${GIT_CONFIG_GLOBAL-unset}"', env)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout, "[]", "an empty GIT_CONFIG_GLOBAL (no global config) was replaced")

    def python_victim(self, env: dict, repo: bool = True) -> list[str]:
        args = [sys.executable, "-I", "-c", PYTHON_VICTIM, str(HELPER)] + ([str(self.root / "repo")] if repo else [])
        done = subprocess.run(args, env=env, cwd=self.root, capture_output=True, text=True,
                              stdin=subprocess.DEVNULL)
        self.assertEqual(done.returncode, 0, done.stderr)
        return done.stdout.split("\n")[:2]

    def test_python_rejects_an_untrusted_inherited_dir(self):
        cases = {}
        open_dir = self.shared / "world-writable"
        open_dir.mkdir()
        open_dir.chmod(0o777)
        cases["mode 0777"] = open_dir
        readable = self.shared / "group-readable"
        readable.mkdir()
        readable.chmod(0o755)
        cases["mode 0755"] = readable
        private = self.root / "private-target"
        private.mkdir()
        private.chmod(0o700)
        link = self.shared / "link"
        link.symlink_to(private)
        cases["symlink"] = link
        for case, folder in cases.items():
            with self.subTest(case):
                (folder / "home.gitconfig").write_text(self.evil)
                self.marker.unlink(missing_ok=True)
                subprocess.run(["rm", "-rf", str(self.root / "repo")], check=True)
                loaded, fixture = self.python_victim(dict(self.env, CMUX_GIT_FIXTURE_GLOBAL_DIR=str(folder)))
                print(f"python ({case}) GIT_CONFIG_GLOBAL={loaded}; hook ran={self.marker.exists()}")
                self.assertFalse(self.marker.exists(), f"{case}: a hook planted in the inherited folder ran")
                for config in (loaded, fixture):
                    self.assertNotEqual(Path(config).parent, folder)
                    self.assertNotEqual(Path(config).parent.resolve(), private)

    def test_python_child_reuses_the_parents_private_dir_which_is_removed_at_exit(self):
        child = ("import importlib.util, os, sys\n"
                 "spec = importlib.util.spec_from_file_location('git_fixture_env', sys.argv[1])\n"
                 "module = importlib.util.module_from_spec(spec)\nspec.loader.exec_module(module)\n"
                 "print(os.path.dirname(module.GLOBAL_CONFIG))\n")
        parent = ("import importlib.util, os, stat, subprocess, sys\n"
                  "spec = importlib.util.spec_from_file_location('git_fixture_env', sys.argv[1])\n"
                  "module = importlib.util.module_from_spec(spec)\nspec.loader.exec_module(module)\n"
                  "folder = os.path.dirname(module.GLOBAL_CONFIG)\ninfo = os.lstat(folder)\n"
                  "print(folder)\nprint(stat.S_ISDIR(info.st_mode), info.st_uid == os.getuid(), oct(stat.S_IMODE(info.st_mode)))\n"
                  "print(subprocess.run([sys.executable, '-I', '-c', sys.argv[2], sys.argv[1]], capture_output=True,"
                  " text=True, check=True).stdout.strip())\n")
        done = subprocess.run([sys.executable, "-I", "-c", parent, str(HELPER), child], env=self.env, cwd=self.root,
                              capture_output=True, text=True, stdin=subprocess.DEVNULL)
        self.assertEqual(done.returncode, 0, done.stderr)
        folder, info, child_folder = done.stdout.splitlines()
        self.assertEqual(info, "True True 0o700", folder)
        self.assertEqual(child_folder, folder, "a child did not reuse its parent's private folder")
        self.assertFalse(Path(folder).exists(), "the helper's private folder outlived the process")

    def test_python_keeps_an_explicitly_empty_global_config(self):
        loaded, fixture = self.python_victim(dict(self.env, GIT_CONFIG_GLOBAL=""), repo=False)
        self.assertEqual((loaded, fixture), ("", ""))


if __name__ == "__main__":
    unittest.main()
