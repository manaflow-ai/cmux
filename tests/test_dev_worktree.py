"""scripts/cmux_worktree.py makes a worktree from clones of a clean seed checkout.

A plain `git worktree add` of feat-cmux-next writes 1.3 GiB and takes about 16 s;
on 2026-11-20 this Mac held 203 such worktrees with 461 GiB free. Cloned files
share the seed's blocks, and the index the tool writes must carry the clones'
own stat data: an index that names the right blobs with stale stat data makes
git re-hash every file (14 s on feat-cmux-next) and `git diff-files` lists
every file as changed. These tests run the tool as agents do and read git's
verdict: the worktree is at the commit asked for, clean, and its index is
fresh (`git diff-files --quiet` with no refresh); on macOS its unchanged files
are clones of the seed's (same physical block). `dedupe` does the same for
existing worktrees, never touching a changed file; `gc` removes only landed,
clean, idle worktrees and reports the rest; `--cargo` seeds a Rust target
from a sibling's, less its `incremental` folders, and skips one being built.
"""

from __future__ import annotations

import fcntl
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "scripts" / "cmux_worktree.py"

_spec = importlib.util.spec_from_file_location("git_fixture_env", Path(__file__).resolve().parent / "git_fixture_env.py")
git_fixture_env = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(git_fixture_env)

DARWIN = sys.platform == "darwin"
BIG = 64 * 1024  # a file big enough to own whole blocks


def git(cwd: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(cwd), *args], text=True, capture_output=True, check=check,
                          env=git_fixture_env.fixture_env())


def tool(repo: Path, seed: Path, *args: str, env: dict | None = None) -> subprocess.CompletedProcess:
    full_env = git_fixture_env.fixture_env()
    full_env.update(env or {})
    return subprocess.run([sys.executable, "-I", str(TOOL), "-C", str(repo), "--seed-dir", str(seed), *args],
                          text=True, capture_output=True, env=full_env)


def physical_offset(path: Path) -> int | None:
    if not DARWIN:
        return None
    fd = os.open(path, os.O_RDONLY)
    try:
        import struct
        return struct.unpack("=Iqq", fcntl.fcntl(fd, 49, b"\0" * 20))[2]  # F_LOG2PHYS
    finally:
        os.close(fd)


def volume_clones(folder: Path) -> bool:
    """Whether folder's volume has clones: APFS, or a Linux reflink file system (not ext4 or tmpfs).
    Where it has none, `add` checks out as git does and makes no seed."""
    if DARWIN:
        return True
    probe, copy = folder / ".probe", folder / ".probe-copy"
    probe.write_bytes(b"x")
    try:
        return subprocess.run(["cp", "--reflink=always", str(probe), str(copy)], capture_output=True).returncode == 0
    finally:
        probe.unlink(missing_ok=True)
        copy.unlink(missing_ok=True)


def age(worktree: Path, days: float) -> None:
    """Make a worktree look last used `days` ago (its index, HEAD and reflog times)."""
    gdir = Path(git(worktree, "rev-parse", "--path-format=absolute", "--git-dir").stdout.strip())
    when = time.time() - days * 86400
    for name in ("index", "HEAD", "logs/HEAD"):
        if (gdir / name).exists():
            os.utime(gdir / name, (when, when))


class Fixture:
    """A repository with an origin, two commits on main (S, then C), and a seed path."""

    def __init__(self, tmp: Path):
        self.tmp = tmp
        self.origin = tmp / "origin.git"
        self.repo = tmp / "repo"
        self.seed = tmp / "cache" / "seed"
        git_fixture_env.init_repo(self.origin, "--bare", "-q")
        git_fixture_env.init_repo(self.repo, "-q", "-b", "main")
        git(self.repo, "config", "user.email", "t@example.com")
        git(self.repo, "config", "user.name", "t")
        git(self.repo, "config", "core.hooksPath", "/dev/null")
        (self.repo / "src").mkdir()
        (self.repo / "src" / "big.bin").write_bytes(os.urandom(BIG))
        (self.repo / "src" / "edit.txt").write_text("one\n")
        (self.repo / "gone.txt").write_text("deleted in C\n")
        run = self.repo / "run.sh"
        run.write_text("#!/bin/sh\necho hi\n")
        run.chmod(0o755)
        os.symlink("src/edit.txt", self.repo / "link")
        (self.repo / ".gitignore").write_text("target/\nnode_modules/\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-qm", "S")
        self.s = git(self.repo, "rev-parse", "HEAD").stdout.strip()
        (self.repo / "src" / "edit.txt").write_text("two\n")
        (self.repo / "gone.txt").unlink()
        (self.repo / "new.txt").write_text("added in C\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-qm", "C")
        self.c = git(self.repo, "rev-parse", "HEAD").stdout.strip()
        git(self.repo, "remote", "add", "origin", str(self.origin))
        git(self.repo, "push", "-q", "origin", "main")
        git(self.repo, "fetch", "-q", "origin")


class AddTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.f = Fixture(Path(self._tmp.name).resolve())

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def assert_clean_fresh(self, worktree: Path) -> None:
        # Stat-only: an index with stale stat data lists every file here.
        files = git(worktree, "diff-files", "--name-only", check=False)
        self.assertEqual(files.returncode, 0, files.stderr)
        self.assertEqual(files.stdout, "", "the index's stat data does not match the files")
        self.assertEqual(git(worktree, "status", "--porcelain").stdout, "")

    def test_add_clones_the_seed_and_moves_it_to_the_commit(self) -> None:
        seeded = tool(self.f.repo, self.f.seed, "seed", self.f.s)
        self.assertEqual(seeded.returncode, 0, seeded.stderr)
        dest = self.f.tmp / "wt"
        result = tool(self.f.repo, self.f.seed, "add", "--json", "-b", "feature", str(dest), self.f.c)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        if volume_clones(self.f.tmp):
            self.assertEqual(report["method"], "clone", report)
            self.assertEqual(report["seed_commit"], self.f.s)
            self.assertEqual(report["files_written"], 3)  # edit.txt, gone.txt, new.txt
        else:
            self.assertEqual(report["method"], "checkout", "a volume without clones would copy every byte")
        self.assertEqual(git(dest, "rev-parse", "HEAD").stdout.strip(), self.f.c)
        self.assertEqual(git(dest, "symbolic-ref", "HEAD").stdout.strip(), "refs/heads/feature")
        self.assert_clean_fresh(dest)
        self.assertEqual((dest / "src" / "edit.txt").read_text(), "two\n")
        self.assertFalse((dest / "gone.txt").exists())
        self.assertEqual((dest / "new.txt").read_text(), "added in C\n")
        self.assertTrue(os.access(dest / "run.sh", os.X_OK))
        self.assertEqual(os.readlink(dest / "link"), "src/edit.txt")
        if DARWIN:
            self.assertEqual(physical_offset(dest / "src" / "big.bin"), physical_offset(self.f.seed / "src" / "big.bin"),
                             "an unchanged file is not a clone of the seed's")
        # The seed stays clean, so the next add clones it too.
        self.assertEqual(git(self.f.seed, "status", "--porcelain", "--ignored").stdout, "")

    def test_add_makes_the_seed_when_there_is_none(self) -> None:
        dest = self.f.tmp / "wt"
        result = tool(self.f.repo, self.f.seed, "add", "--json", "--detach", str(dest), "origin/main")
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        if not volume_clones(self.f.tmp):
            self.assertEqual(report["method"], "checkout", report)
            self.assertFalse(self.f.seed.exists(), "a seed (a full copy) was made where clones are not possible")
            self.assert_clean_fresh(dest)
            return
        self.assertEqual(report["method"], "clone", report)
        self.assertEqual(report["files_written"], 0)
        self.assert_clean_fresh(dest)
        self.assertIn("locked", git(self.f.repo, "worktree", "list", "--porcelain").stdout)

        # The cache was emptied: the next add makes the seed again.
        subprocess.run(["rm", "-rf", str(self.f.seed)], check=True)
        again = tool(self.f.repo, self.f.seed, "add", "--json", "--detach", str(self.f.tmp / "wt2"), "origin/main")
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(json.loads(again.stdout)["method"], "clone", again.stdout)
        self.assert_clean_fresh(self.f.tmp / "wt2")

    def test_add_checks_out_when_it_cannot_clone(self) -> None:
        dest = self.f.tmp / "wt"
        result = tool(self.f.repo, self.f.seed, "add", "--json", "-b", "plain", str(dest), self.f.c,
                      env={"CMUX_WORKTREE_NO_CLONE": "1"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["method"], "checkout")
        self.assert_clean_fresh(dest)
        self.assertEqual((dest / "src" / "edit.txt").read_text(), "two\n")

    def test_cargo_target_is_seeded_from_a_sibling_less_incremental(self) -> None:
        (self.f.repo / "rust-toolchain.toml").write_text('[toolchain]\nchannel = "1.95.0"\n')
        git(self.f.repo, "add", "-A")
        git(self.f.repo, "commit", "-qm", "toolchain")
        sibling = self.f.tmp / "sibling"
        git(self.f.repo, "worktree", "add", "-q", "--detach", str(sibling), "HEAD")
        debug = sibling / "src" / "target" / "debug"
        (debug / "deps").mkdir(parents=True)
        (debug / "deps" / "libserde-1.rlib").write_bytes(b"rlib")
        (debug / "incremental" / "mine-1").mkdir(parents=True)
        (debug / ".cargo-lock").write_text("")
        dest = self.f.tmp / "wt"
        result = tool(self.f.repo, self.f.seed, "add", "--json", "--cargo", "src", "--detach", str(dest), "HEAD")
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["cargo"][0].get("from"), str(sibling / "src" / "target"), report)
        self.assertEqual((dest / "src" / "target" / "debug" / "deps" / "libserde-1.rlib").read_bytes(), b"rlib")
        self.assertFalse((dest / "src" / "target" / "debug" / "incremental").exists())

        # A sibling cargo is building (it holds the lock): not used.
        busy = self.f.tmp / "wt2"
        fd = os.open(debug / ".cargo-lock", os.O_RDWR)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            (dest / "src" / "target").rename(self.f.tmp / "moved-target")  # leave only the busy sibling
            result = tool(self.f.repo, self.f.seed, "add", "--json", "--cargo", "src", "--detach", str(busy), "HEAD")
        finally:
            os.close(fd)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("from", json.loads(result.stdout)["cargo"][0])
        self.assertFalse((busy / "src" / "target").exists())


class GitCowTests(unittest.TestCase):
    """Installed as `git-cow` on PATH, the tool is `git cow`: `git worktree add`'s arguments and
    defaults (the commit is HEAD, a bare path names a new branch), with the files cloned."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.f = Fixture(Path(self._tmp.name).resolve())
        self.bin = self.f.tmp / "bin"
        self.bin.mkdir()
        os.symlink(TOOL, self.bin / "git-cow")
        # The commit cmux_worktree.py's own `add` would default to: `git cow` must ignore it.
        git(self.f.repo, "push", "-q", "origin", f"{self.f.s}:refs/heads/feat-cmux-next")
        git(self.f.repo, "fetch", "-q", "origin")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def cow(self, *args: str, env: dict | None = None) -> subprocess.CompletedProcess:
        full_env = git_fixture_env.fixture_env()
        full_env["PATH"] = f"{self.bin}{os.pathsep}{full_env.get('PATH', os.defpath)}"
        full_env["CMUX_WORKTREE_SEED_DIR"] = str(self.f.seed)
        full_env.update(env or {})
        return subprocess.run(["git", "cow", *args], cwd=self.f.repo, text=True, capture_output=True, env=full_env)

    def registered(self) -> dict:
        out = git(self.f.repo, "worktree", "list", "--porcelain").stdout
        return {block.split("\n")[0][len("worktree "):]: block for block in out.strip().split("\n\n")}

    def test_add_b_is_registered_at_head_and_shares_the_seeds_blocks(self) -> None:
        dest = self.f.tmp / "wt"
        result = self.cow("add", "--no-track", "-b", "feature", "../wt")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(dest), self.registered())
        self.assertIn("branch refs/heads/feature", self.registered()[str(dest)])
        self.assertEqual(git(dest, "rev-parse", "HEAD").stdout.strip(), self.f.c, "git cow bases on HEAD, as git does")
        self.assertEqual(git(self.f.repo, "rev-parse", "feature").stdout.strip(), self.f.c)
        self.assertEqual(git(dest, "diff-files", "--name-only").stdout, "", "the index's stat data is stale")
        self.assertEqual(git(dest, "status", "--porcelain").stdout, "")
        self.assertEqual(git(self.f.repo, "config", "--get", "branch.feature.remote", check=False).stdout, "")
        if DARWIN:
            self.assertTrue((self.f.seed / ".git").is_file(), "no seed was made on APFS")
            self.assertEqual(physical_offset(dest / "src" / "big.bin"), physical_offset(self.f.seed / "src" / "big.bin"),
                             "an unchanged file is not a clone of the seed's")

    def test_a_bare_path_makes_the_branch_it_names(self) -> None:
        result = self.cow("add", str(self.f.tmp / "topic"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("branch refs/heads/topic", self.registered()[str(self.f.tmp / "topic")])
        self.assertEqual(git(self.f.repo, "rev-parse", "topic").stdout.strip(), self.f.c)

    def test_an_existing_branch_is_checked_out(self) -> None:
        git(self.f.repo, "branch", "old", self.f.s)
        result = self.cow("add", str(self.f.tmp / "old-wt"), "old")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("branch refs/heads/old", self.registered()[str(self.f.tmp / "old-wt")])
        self.assertTrue((self.f.tmp / "old-wt" / "gone.txt").exists())

    def test_what_it_cannot_clone_is_a_plain_worktree_and_no_seed(self) -> None:
        for number, env in enumerate(({"GIT_COW": "0"}, {"CMUX_WORKTREE_NO_CLONE": "1"})):
            dest = self.f.tmp / f"plain-{number}"
            result = self.cow("add", "--detach", str(dest), "HEAD", env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(str(dest), self.registered())
            self.assertEqual(git(dest, "status", "--porcelain").stdout, "")
            self.assertFalse(self.f.seed.exists(), f"{env}: a seed was made for a plain worktree")

    @unittest.skipIf(DARWIN, "a volume without reflinks: Linux ext4 or overlay")
    def test_a_volume_without_reflinks_gets_a_plain_checkout_and_no_seed(self) -> None:
        probe = self.f.tmp / "probe"
        probe.write_text("x")
        reflinks = subprocess.run(["cp", "--reflink=always", str(probe), str(self.f.tmp / "probe2")],
                                  capture_output=True).returncode == 0
        if reflinks:
            self.skipTest("this volume has reflinks")
        result = self.cow("add", "--detach", str(self.f.tmp / "wt"), "HEAD")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.f.seed.exists(), "a seed (a full copy) was made where clones are not possible")
        self.assertEqual(git(self.f.tmp / "wt", "status", "--porcelain").stdout, "")

    def test_a_failed_add_leaves_no_worktree_and_no_branch(self) -> None:
        # read-tree fails: the index lock is taken (another git), as a full disk or a stop would fail it.
        hooks = self.f.tmp / "hooks"
        hooks.mkdir()
        dest = self.f.tmp / "broken"
        result = self.cow("add", "-b", "broken", str(dest), env={"CMUX_WORKTREE_NO_CLONE": "1",
                                                                "GIT_INDEX_FILE": "/nonexistent/dir/index"})
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn(str(dest), self.registered())
        self.assertFalse(dest.exists(), "a half-made worktree folder stayed")
        self.assertEqual(git(self.f.repo, "branch", "--list", "broken").stdout, "", "the branch the add made stayed")

    def test_the_post_checkout_hook_runs_as_for_git_worktree_add(self) -> None:
        hooks = self.f.tmp / "hooks"
        hooks.mkdir()
        hook = hooks / "post-checkout"
        hook.write_text(f"#!/bin/sh\necho \"$(pwd -P) $1 $2 $3\" >> {self.f.tmp / 'hook.log'}\n")
        hook.chmod(0o755)
        git(self.f.repo, "config", "core.hooksPath", str(hooks))
        result = self.cow("add", "--detach", str(self.f.tmp / "hooked"))
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = (self.f.tmp / "hook.log").read_text().splitlines()
        self.assertIn(f"{self.f.tmp / 'hooked'} {'0' * 40} {self.f.c} 1", lines)

    def test_other_commands_are_git_worktrees(self) -> None:
        self.assertEqual(self.cow("add", "-b", "x", str(self.f.tmp / "x")).returncode, 0)
        listed = self.cow("list", "--porcelain")
        self.assertEqual(listed.returncode, 0, listed.stderr)
        self.assertIn(str(self.f.tmp / "x"), listed.stdout)
        removed = self.cow("remove", str(self.f.tmp / "x"))
        self.assertEqual(removed.returncode, 0, removed.stderr)
        self.assertNotIn(str(self.f.tmp / "x"), self.registered())
        version = self.cow("--version")
        self.assertEqual(version.returncode, 0, version.stderr)
        self.assertTrue(version.stdout.startswith("git-cow "), version.stdout)

    def test_remove_never_collects_an_overlay_checkout_that_is_not_mounted(self) -> None:
        # A `wt new` overlay checkout after a reboot, which git has let go of: its folder shows only the .git file,
        # its files are in its layer (<parent>/.wt-overlay/<name>/u). `git cow remove` finishes a mounted one git
        # unregistered (cmuxterm-hq's tests/test_git_cow.py mounts it for real); this one must stay, every file kept.
        target = self.f.tmp / "rebooted"
        self.assertEqual(self.cow("add", "-b", "rebooted", str(target)).returncode, 0)
        layer = self.f.tmp / ".wt-overlay" / "rebooted"
        (layer / "u").mkdir(parents=True)
        (layer / "u" / "mine.txt").write_text("work\n")
        (layer / "mount.json").write_text(json.dumps({"target": str(target), "upper": str(layer / "u")}))
        gitdir = Path(git(target, "rev-parse", "--absolute-git-dir").stdout.strip())
        subprocess.run(["rm", "-rf", "--", str(gitdir)], check=True)
        removed = self.cow("remove", str(target))
        self.assertNotEqual(removed.returncode, 0)
        self.assertIn("not mounted", removed.stderr)
        self.assertEqual((layer / "u" / "mine.txt").read_text(), "work\n")
        self.assertTrue(target.is_dir())


def load_tool():
    spec = importlib.util.spec_from_file_location("cmux_worktree_under_test", TOOL)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # its dataclasses look their module up by name
    spec.loader.exec_module(module)
    return module


@unittest.skipUnless(Path("/proc/self/fd").is_dir(), "reads holders from /proc")
class MountHolderTests(unittest.TestCase):
    """A lazy `umount -l` leaves the overlay alive until its holders let go: git cow names them, never silently."""

    def test_names_the_processes_with_a_cwd_or_an_open_file_inside(self) -> None:
        tool_module = load_tool()
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp).resolve() / "lane--held"
            (target / "sub").mkdir(parents=True)
            (target / "open.txt").write_text("x\n")
            outside = Path(tmp).resolve() / "lane--held-not"  # a sibling whose name starts with TARGET's
            outside.mkdir()
            in_cwd = subprocess.Popen(["sleep", "60"], cwd=target / "sub")
            out_cwd = subprocess.Popen(["sleep", "60"], cwd=outside)
            with open(target / "open.txt", encoding="utf-8") as handle:
                in_fd = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"],
                                         pass_fds=(handle.fileno(),), cwd=tmp)
            try:
                time.sleep(0.2)  # sleep-ok: let the children exec before /proc is read
                held, _ = tool_module.mount_holders(target)
            finally:
                for child in (in_cwd, out_cwd, in_fd):
                    child.kill()
                    child.wait()
        text = "\n".join(held)
        self.assertIn(f"{in_cwd.pid} (sleep: cwd)", text)
        self.assertRegex(text, rf"{in_fd.pid} \([^:]+: fd \d+\)")
        self.assertNotIn(f"{out_cwd.pid} (", text)

    def test_counts_the_processes_it_could_not_read(self) -> None:
        if os.geteuid() == 0:
            self.skipTest("root reads every process")
        tool_module = load_tool()
        with tempfile.TemporaryDirectory() as tmp:
            proc = Path(tmp) / "proc"
            hidden = proc / "4242"
            (hidden / "fd").mkdir(parents=True)
            os.chmod(hidden / "fd", 0)
            try:
                held, unreadable = tool_module.mount_holders(Path("/no/such/lane"), proc=proc)
            finally:
                os.chmod(hidden / "fd", 0o700)
        self.assertEqual((held, unreadable), ([], 1))

    def test_the_lazy_note_says_umount_l_and_names_holders_or_says_it_could_not_look(self) -> None:
        tool_module = load_tool()
        target = Path("/w/lane--x")
        named = tool_module.lazy_unmount_note(target, ["17 (zsh: cwd)"], 0)
        self.assertIn("umount -l", named)
        self.assertIn("still held by 17 (zsh: cwd)", named)
        blind = tool_module.lazy_unmount_note(target, [], 3)
        self.assertIn("no holder this user can see", blind)
        self.assertIn("3 process(es) this user cannot read", blind)
        self.assertIn(f"fuser -vm {target}", blind)


@unittest.skipUnless(DARWIN, "dedupe needs APFS clones")
class DedupeTests(unittest.TestCase):
    def test_dedupe_clones_unchanged_files_and_leaves_changed_ones(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            f = Fixture(Path(tmp).resolve())
            self.assertEqual(tool(f.repo, f.seed, "seed", f.c).returncode, 0)
            old = f.tmp / "old"
            git(f.repo, "worktree", "add", "-q", "--detach", str(old), f.c)
            (old / "src" / "edit.txt").write_text("my edit\n")
            time.sleep(1.1)  # sleep-ok: an mtime tick; files older than the index, in whole seconds: not racily clean
            git(old, "update-index", "-q", "--really-refresh", check=False)  # as an agent's status would
            before = physical_offset(old / "src" / "big.bin")
            self.assertNotEqual(before, physical_offset(f.seed / "src" / "big.bin"))
            mtime = (old / "src" / "big.bin").stat().st_mtime_ns

            listed = tool(f.repo, f.seed, "dedupe", "--json", "--only", str(old))
            self.assertEqual(listed.returncode, 0, listed.stderr)
            self.assertGreaterEqual(json.loads(listed.stdout)[0]["files"], 1)
            self.assertEqual(physical_offset(old / "src" / "big.bin"), before, "listing changed a file")

            applied = tool(f.repo, f.seed, "dedupe", "--json", "--apply", "--only", str(old))
            self.assertEqual(applied.returncode, 0, applied.stderr)
            self.assertEqual(physical_offset(old / "src" / "big.bin"), physical_offset(f.seed / "src" / "big.bin"))
            self.assertEqual((old / "src" / "big.bin").stat().st_mtime_ns, mtime)
            self.assertEqual((old / "src" / "edit.txt").read_text(), "my edit\n")
            self.assertEqual(git(old, "diff-files", "--name-only").stdout, "src/edit.txt\n")
            self.assertEqual(git(old, "status", "--porcelain").stdout, " M src/edit.txt\n")


    def test_a_stopped_dedupe_leaves_no_lock_and_no_half_clone(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            f = Fixture(Path(tmp).resolve())
            many = f.repo / "many"
            many.mkdir()
            for number in range(20000):
                (many / f"f{number}.txt").write_text(f"{number}\n" * 64)
            git(f.repo, "add", "-A")
            git(f.repo, "commit", "-qm", "many")
            self.assertEqual(tool(f.repo, f.seed, "seed", "HEAD").returncode, 0)
            old = f.tmp / "old"
            git(f.repo, "worktree", "add", "-q", "--detach", str(old), "HEAD")
            time.sleep(1.1)  # sleep-ok: an mtime tick; files older than the index, in whole seconds: not racily clean
            git(old, "update-index", "-q", "--really-refresh", check=False)
            first = old / "many" / "f0.txt"
            first_inode = first.stat().st_ino
            env = git_fixture_env.fixture_env()
            proc = subprocess.Popen([sys.executable, "-I", str(TOOL), "-C", str(f.repo), "--seed-dir", str(f.seed),
                                     "dedupe", "--apply", "--only", str(old)], env=env,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            gdir = Path(git(old, "rev-parse", "--path-format=absolute", "--git-dir").stdout.strip())
            deadline = time.monotonic() + 60
            while not (gdir / "index.lock").exists() and proc.poll() is None and time.monotonic() < deadline:
                time.sleep(0.01)  # until it holds the index: stopped while it clones
            # Until its first clone is in place (os.replace gives many/f0.txt a new inode): stopped mid-clone.
            while first.stat().st_ino == first_inode and proc.poll() is None and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertIsNone(proc.poll(), "dedupe ended before it could be stopped; make the fixture bigger")
            proc.terminate()
            proc.wait(timeout=60)
            self.assertFalse((gdir / "index.lock").exists(), "a stopped dedupe left the index locked")
            self.assertEqual(list(old.rglob("*.cmux-dedupe")), [])
            self.assertEqual(git(old, "status", "--porcelain").stdout, "")
            self.assertEqual((old / "many" / "f17.txt").read_text(), "17\n" * 64)


class StatMatchTests(unittest.TestCase):
    def test_a_new_device_number_alone_is_not_a_change(self) -> None:
        spec = importlib.util.spec_from_file_location("cmux_worktree", TOOL)
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module  # its dataclasses look their module up
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "f"
            path.write_text("x")
            fresh = module.stat_fields(os.lstat(path), 0o100644)
            renumbered = list(fresh)
            renumbered[4] += 1  # the volume's st_dev after a restart
            self.assertTrue(module.same_stat(fresh, renumbered))
            moved = list(fresh)
            moved[5] += 1  # another inode: a different file
            self.assertFalse(module.same_stat(fresh, moved))


class GcTests(unittest.TestCase):
    def test_gc_removes_only_landed_clean_idle_worktrees(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            f = Fixture(Path(tmp).resolve())
            wts = {name: f.tmp / name for name in ("landed", "recent", "untracked", "unpushed", "gone")}
            for name, path in wts.items():
                git(f.repo, "worktree", "add", "-q", "-b", name, str(path), "origin/main")
            (wts["untracked"] / "notes.md").write_text("keep me\n")
            (wts["unpushed"] / "work.txt").write_text("work\n")
            git(wts["unpushed"], "add", "work.txt")
            git(wts["unpushed"], "commit", "-qm", "unpushed work")
            subprocess.run(["rm", "-rf", str(wts["gone"])], check=True)
            for name in ("landed", "untracked", "unpushed"):
                age(wts[name], 10)

            listed = tool(f.repo, f.seed, "gc", "--json", "--landing", "origin/main")
            self.assertEqual(listed.returncode, 0, listed.stderr)
            verdicts = {Path(e["worktree"]).name: e for e in json.loads(listed.stdout)}
            self.assertEqual(verdicts["landed"]["verdict"], "remove")
            self.assertEqual(verdicts["recent"]["verdict"], "keep")
            self.assertEqual(verdicts["untracked"]["verdict"], "keep")
            self.assertEqual(verdicts["unpushed"]["verdict"], "keep")
            self.assertEqual(verdicts["unpushed"]["unpushed"], 1)
            self.assertEqual(verdicts["gone"]["verdict"], "prune")
            self.assertEqual(verdicts["repo"]["verdict"], "keep")
            self.assertTrue(wts["landed"].exists(), "listing removed a worktree")

            applied = tool(f.repo, f.seed, "gc", "--json", "--apply", "--landing", "origin/main")
            self.assertEqual(applied.returncode, 0, applied.stderr)
            self.assertFalse(wts["landed"].exists())
            for name in ("recent", "untracked", "unpushed"):
                self.assertTrue(wts[name].exists(), name)
            self.assertEqual((wts["untracked"] / "notes.md").read_text(), "keep me\n")
            listing = git(f.repo, "worktree", "list", "--porcelain").stdout
            self.assertNotIn(str(wts["gone"]), listing)
            self.assertNotIn(str(wts["landed"]), listing)


if __name__ == "__main__":
    unittest.main()
