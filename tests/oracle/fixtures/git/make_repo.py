#!/usr/bin/env python3
"""Git repositories for oracle cases, built from a JSON fixture under the case root (p15-oracle-068).

A case whose `fixture.repo` is NAME gets `tests/oracle/fixtures/git/NAME.json` built under
`$CASE_ROOT/repos/` before its first step: the driver calls `build_for_case` with the case, its state root
and its hermetic environment (hermetic_env.py, p15-oracle-200). Such a case requires the case-v1
capability `git_repo`; a product offers it only once its driver makes that call. Stdlib only, Python 3.9+,
safe under `python3 -I`.

This module owns the repository folder of a case (ROOT_TOKEN, REPOS_DIR, REPOS_ROOT) and the local-remote
rule (`require_local_remote`); gen_daemon_ops.py imports them from here, and hermetic_env.py is to do the same.

Chrome reference: depot_tools testing_support/git_test_utils.py builds each test repository from a
schema (GitRepoSchema) with the author and committer date of every commit taken from a fixed start and
stepped per commit, so a test sees the same commit ids on every run; testing_support/fake_repos.py keeps
the origin a local repository the test owns. Here:

- every commit's author and committer date is `epoch` plus one minute per commit, in fixture order, and
  the identity is the fixture's, so commit ids are the same on every run and every host;
- `origin` is a bare repository under `$CASE_ROOT/repos/`, the only remote; after the build every fetch and
  push URL of every repository is checked to be a path under the case root (`check_local_remotes`);
- the hermetic git settings are written into each repository's own config, not only the environment:
  git.commit and git.push run git with every inherited GIT_* variable dropped
  (cmux-tui-core/src/git_ops/user_run.rs `environment()`), so for them only the repository's config
  stands between git and the machine's /etc/gitconfig: a fixed identity, no signing, an empty hooks
  folder, only the file transport, no automatic gc.

Layout of a fixture NAME: the work checkout `repos/NAME` on `branch`, its origin `repos/<origin>`, and
each linked worktree `repos/<path>` on its own branch with `branch.<branch>.cmuxBase` recorded as
git.worktree.create records it (git_ops/worktree.rs). `dirty` edits tracked files of the work checkout
without staging them; `untracked` adds files git does not track.

    python3 -I tests/oracle/fixtures/git/make_repo.py --build ROOT [--name oracle]   # build under ROOT
    python3 -I tests/oracle/fixtures/git/make_repo.py --selftest                      # needs git on PATH
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
import unittest
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Dict, List, Mapping, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
# Case values write the case's state root as ROOT_TOKEN; its generated repositories are under REPOS_ROOT.
ROOT_TOKEN = "$CASE_ROOT"
REPOS_DIR = "repos"
REPOS_ROOT = f"{ROOT_TOKEN}/{REPOS_DIR}"
SECONDS_PER_COMMIT = 60
# Where a case-less build (--build, the self test) finds git; a driver passes the case's own PATH.
DEFAULT_PATH = "/usr/local/bin:/usr/bin:/bin"

NAME = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
BRANCH = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}(/[a-z0-9][a-z0-9-]{0,63})?$")
FILE_PART = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$")
FIXTURE_KEYS = frozenset({"$comment", "name", "branch", "epoch", "identity", "origin", "commits", "worktrees",
                          "dirty", "untracked"})

Runner = Callable[..., "subprocess.CompletedProcess[str]"]


class FixtureError(Exception):
    """A fixture file that cannot describe a hermetic repository, or a build that did not make one."""


@dataclass(frozen=True)
class Commit:
    message: str
    files: Tuple[Tuple[str, str], ...]
    pushed: bool


@dataclass(frozen=True)
class Worktree:
    path: str
    branch: str
    base: str
    commits: Tuple[Commit, ...]


@dataclass(frozen=True)
class RepoFixture:
    name: str
    branch: str
    epoch: int
    identity: Tuple[str, str]
    origin: str
    commits: Tuple[Commit, ...]
    worktrees: Tuple[Worktree, ...]
    dirty: Tuple[Tuple[str, str], ...]
    untracked: Tuple[Tuple[str, str], ...]

    @classmethod
    def load(cls, name: str, directory: Path = HERE) -> "RepoFixture":
        if not isinstance(name, str) or not NAME.match(name):
            raise FixtureError(f"repository fixture name {name!r} is not a slug")
        path = directory / f"{name}.json"
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            raise FixtureError(f"{path}: {error}") from None
        return cls.parse(data, str(path), name)

    @classmethod
    def parse(cls, data: Any, where: str, name: str) -> "RepoFixture":
        if not isinstance(data, dict) or not set(data) <= FIXTURE_KEYS:
            raise FixtureError(f"{where}: an object with only {sorted(FIXTURE_KEYS)}")
        if data.get("name") != name:
            raise FixtureError(f"{where}: name is {data.get('name')!r}, not the file's {name!r}")
        branch = data.get("branch")
        if not isinstance(branch, str) or not BRANCH.match(branch):
            raise FixtureError(f"{where}: branch {branch!r} is not a plain branch name")
        epoch = data.get("epoch")
        if not isinstance(epoch, int) or isinstance(epoch, bool) or epoch <= 0:
            raise FixtureError(f"{where}: epoch is a positive Unix time in seconds")
        identity = data.get("identity")
        if not (isinstance(identity, dict) and set(identity) == {"name", "email"}
                and all(isinstance(v, str) and v and "\n" not in v for v in identity.values())):
            raise FixtureError(f"{where}: identity is {{name, email}}")
        origin = data.get("origin")
        if not (isinstance(origin, str) and origin.endswith(".git") and NAME.match(origin[:-4])):
            raise FixtureError(f"{where}: origin {origin!r} is not <slug>.git: a bare repository beside the checkout")
        commits = tuple(_commit(item, f"{where}: commits[{i}]") for i, item in enumerate(_list(data, "commits", where)))
        if not commits:
            raise FixtureError(f"{where}: commits has at least one commit")
        pushed = [commit.pushed for commit in commits]
        if pushed != sorted(pushed, reverse=True):
            raise FixtureError(f"{where}: the pushed commits come first: origin has a prefix of {branch}")
        worktrees = tuple(_worktree(item, f"{where}: worktrees[{i}]", branch)
                          for i, item in enumerate(_list(data, "worktrees", where)))
        dirty, untracked = _files(data.get("dirty", {}), f"{where}: dirty"), _files(data.get("untracked", {}), f"{where}: untracked")
        tracked = {path for commit in commits for path, _ in commit.files}
        if any(path not in tracked for path, _ in dirty):
            raise FixtureError(f"{where}: dirty edits only files a commit tracks")
        if any(path in tracked for path, _ in untracked):
            raise FixtureError(f"{where}: untracked names only files no commit tracks")
        taken = [name, origin] + [worktree.path for worktree in worktrees]
        if len(set(taken)) != len(taken):
            raise FixtureError(f"{where}: the checkout, origin and worktree folders differ")
        return cls(name, branch, epoch, (identity["name"], identity["email"]), origin, commits, worktrees, dirty, untracked)

    def tokens(self) -> Dict[str, str]:
        """The fixture's folders as case values write them (under ROOT_TOKEN)."""
        paths = {"work": f"{REPOS_ROOT}/{self.name}", "origin": f"{REPOS_ROOT}/{self.origin}"}
        paths.update({f"worktree:{w.branch}": f"{REPOS_ROOT}/{w.path}" for w in self.worktrees})
        return paths

    def commit_count(self) -> int:
        return len(self.commits) + sum(len(worktree.commits) for worktree in self.worktrees)


def _list(data: Mapping[str, Any], key: str, where: str) -> List[Any]:
    value = data.get(key, [])
    if not isinstance(value, list):
        raise FixtureError(f"{where}: {key} is a list")
    return value


def _relative(path: Any, where: str) -> str:
    """A relative file path inside the checkout: plain parts, no `..`, nothing in .git."""
    parts = path.split("/") if isinstance(path, str) else []
    if not parts or not all(FILE_PART.match(part) for part in parts) or parts[0] == ".git":
        raise FixtureError(f"{where}: {path!r} is not a plain relative file path")
    return path


def _files(value: Any, where: str) -> Tuple[Tuple[str, str], ...]:
    if not isinstance(value, dict) or not all(isinstance(text, str) for text in value.values()):
        raise FixtureError(f"{where}: an object of relative path to file text")
    return tuple(sorted((_relative(path, where), text) for path, text in value.items()))


def _commit(item: Any, where: str, pushable: bool = True) -> Commit:
    keys = {"message", "files", "pushed"} if pushable else {"message", "files"}
    if not isinstance(item, dict) or not set(item) <= keys or "message" not in item:
        raise FixtureError(f"{where}: a commit is {sorted(keys)}")
    message = item["message"]
    if not isinstance(message, str) or not message.strip() or message.startswith("#"):
        raise FixtureError(f"{where}: message is a non-empty subject")
    files = _files(item.get("files", {}), f"{where}.files")
    if not files:
        raise FixtureError(f"{where}: a commit changes at least one file")
    pushed = item.get("pushed", False)
    if not isinstance(pushed, bool):
        raise FixtureError(f"{where}: pushed is a boolean")
    return Commit(message, files, pushed)


def _worktree(item: Any, where: str, main: str) -> Worktree:
    if not isinstance(item, dict) or set(item) != {"path", "branch", "base", "commits"}:
        raise FixtureError(f"{where}: a worktree is {{path, branch, base, commits}}")
    path, branch, base = item["path"], item["branch"], item["base"]
    if not isinstance(path, str) or not NAME.match(path):
        raise FixtureError(f"{where}: path {path!r} is a slug beside the checkout")
    if not isinstance(branch, str) or not BRANCH.match(branch) or branch == main:
        raise FixtureError(f"{where}: branch {branch!r} is a new plain branch name")
    if base != main:
        raise FixtureError(f"{where}: base is the checkout's branch {main!r}, where the worktree branch starts")
    if not isinstance(item["commits"], list):
        raise FixtureError(f"{where}: commits is a list")
    commits = tuple(_commit(c, f"{where}.commits[{i}]", pushable=False) for i, c in enumerate(item["commits"]))
    return Worktree(path, branch, base, commits)


# ---------------------------------------------------------------------------------------------- build


@dataclass(frozen=True)
class Built:
    """What a build made: folders, and each commit's id in fixture order (main, then each worktree)."""

    work: Path
    origin: Path
    worktrees: Tuple[Path, ...]
    commits: Tuple[str, ...]


def repository_config(fixture: RepoFixture, hooks: Path) -> Tuple[Tuple[str, str], ...]:
    """The repository-local config: what git.commit and git.push need, since they drop every GIT_* variable."""
    return (
        ("user.name", fixture.identity[0]),
        ("user.email", fixture.identity[1]),
        ("commit.gpgsign", "false"),
        ("tag.gpgsign", "false"),
        ("core.hooksPath", str(hooks)),  # an empty folder: no hook runs, not even one /etc/gitconfig names
        ("core.autocrlf", "false"),
        ("protocol.allow", "never"),  # only the local transport below; a remote URL fails at once
        ("protocol.file.allow", "always"),
        ("gc.auto", "0"),
        ("maintenance.auto", "false"),
    )


class Builder:
    def __init__(self, fixture: RepoFixture, case_root: Path, env: Mapping[str, str], run: Runner):
        self.fixture = fixture
        self.root = Path(case_root).resolve()
        self.run = run
        name, email = fixture.identity
        # The caller's environment without its git state, then the fixture's: no global or system config,
        # no prompt, the fixture identity. Each commit adds its own dates.
        self.env = {key: value for key, value in env.items() if not key.startswith("GIT_")}
        self.env.setdefault("PATH", DEFAULT_PATH)
        self.env.update({"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0",
                         "GIT_AUTHOR_NAME": name, "GIT_AUTHOR_EMAIL": email,
                         "GIT_COMMITTER_NAME": name, "GIT_COMMITTER_EMAIL": email})
        self.ticks = 0

    def git(self, cwd: Path, *argv: str, env: Optional[Mapping[str, str]] = None) -> str:
        proc = self.run(["git", *argv], cwd=str(cwd), env={**self.env, **(env or {})}, capture_output=True, text=True,
                        timeout=60, check=False, stdin=subprocess.DEVNULL)
        if proc.returncode != 0:
            raise FixtureError(f"git {' '.join(argv)} in {cwd}: {proc.stderr.strip()}")
        return proc.stdout

    def commit(self, checkout: Path, commit: Commit) -> str:
        for relative, text in commit.files:
            target = checkout / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text, encoding="utf-8")
        self.git(checkout, "add", "--", *(relative for relative, _ in commit.files))
        date = f"{self.fixture.epoch + self.ticks * SECONDS_PER_COMMIT} +0000"
        self.ticks += 1
        self.git(checkout, "commit", "-q", "--no-verify", "-m", commit.message,
                 env={"GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date})
        return self.git(checkout, "rev-parse", "HEAD").strip()

    def build(self) -> Built:
        fixture = self.fixture
        repos = self.root / REPOS_DIR
        work, origin = repos / fixture.name, repos / fixture.origin
        worktrees = tuple(repos / worktree.path for worktree in fixture.worktrees)
        for path in (work, origin, *worktrees):
            if path.exists():
                raise FixtureError(f"{path}: exists; a case builds its repository once on a fresh state root")
        repos.mkdir(parents=True, exist_ok=True)
        # An empty template: no sample hooks, no description, the same files on every host.
        self.git(repos, "init", "-q", "--bare", "--template=", f"--initial-branch={fixture.branch}", str(origin))
        self.git(repos, "init", "-q", "--template=", f"--initial-branch={fixture.branch}", str(work))
        for repository, hooks in ((origin, origin / "hooks"), (work, work / ".git" / "hooks")):
            hooks.mkdir(exist_ok=True)
            for key, value in repository_config(fixture, hooks):
                self.git(repository, "config", key, value)
        self.git(work, "remote", "add", "origin", str(origin))
        ids: List[str] = []
        for commit in fixture.commits:
            ids.append(self.commit(work, commit))
            if commit.pushed:
                self.git(work, "push", "-q", "--no-verify", "-u", "origin", f"HEAD:refs/heads/{fixture.branch}")
        for spec, path in zip(fixture.worktrees, worktrees):
            self.git(work, "worktree", "add", "-q", "-b", spec.branch, str(path), spec.base)
            # git.worktree.create records its base so git.worktree.apply finds the merge base (git_ops/worktree.rs).
            self.git(work, "config", f"branch.{spec.branch}.cmuxBase", spec.base)
            ids.extend(self.commit(path, commit) for commit in spec.commits)
        for relative, text in fixture.dirty + fixture.untracked:
            (work / relative).parent.mkdir(parents=True, exist_ok=True)
            (work / relative).write_text(text, encoding="utf-8")
        for repository in (work, origin, *worktrees):
            check_local_remotes(self, repository)
        return Built(work, origin, worktrees, tuple(ids))


def under(path: Path, case_root: Path) -> bool:
    resolved, root = Path(path).resolve(), Path(case_root).resolve()
    return resolved == root or root in resolved.parents


def require_local_remote(url: str, case_root: Path) -> Path:
    """The folder of a remote URL that is a path under the case root, or FixtureError: no other host, no
    folder outside the case. The one copy of this rule; hermetic_env.py (p15-oracle-200) imports it."""
    path = Path(url[len("file://"):] if url.startswith("file:///") else url)
    if not path.is_absolute() or url.startswith("//"):
        raise FixtureError(f"remote {url!r} is not a local path under the case root")
    if not under(path, case_root):
        raise FixtureError(f"remote {url!r} is outside the case root {Path(case_root).resolve()}")
    return path.resolve()


def require_case_home(env: Mapping[str, str], case_root: Path) -> Path:
    """The case's HOME, a folder under its state root, or FixtureError. git.worktree.create writes
    ~/.cmux/worktrees/<repo>/<name> (git_ops/worktree.rs, platform::home_dir()): with a shared HOME,
    parallel cases take each other's worktree names and leave branches in the runner's own home."""
    home = env.get("HOME") or ""
    root = Path(case_root).resolve()
    if not Path(home).is_absolute() or not under(Path(home), root) or Path(home).resolve() == root:
        raise FixtureError(f"HOME {home!r} is not a folder under the case root {root}: "
                           "git.worktree.create writes under ~/.cmux/worktrees")
    return Path(home).resolve()


def check_local_remotes(builder: Builder, repository: Path) -> Dict[str, List[Path]]:
    """Every fetch and push URL of every remote of `repository`, each a path under the case root."""
    remotes: Dict[str, List[Path]] = {}
    for name in builder.git(repository, "remote").split():
        for flag in ((), ("--push",)):
            for url in builder.git(repository, "remote", "get-url", "--all", *flag, name).splitlines():
                if url:
                    remotes.setdefault(name, []).append(require_local_remote(url, builder.root))
    return remotes


def build(fixture: RepoFixture, case_root: Path, env: Mapping[str, str], *, run: Runner = subprocess.run) -> Built:
    return Builder(fixture, case_root, env, run).build()


def build_for_case(case: Mapping[str, Any], case_root: Path, env: Mapping[str, str], *,
                   run: Runner = subprocess.run, directory: Path = HERE) -> Optional[Built]:
    """The driver's hook: builds the case's `fixture.repo` under its state root before the first step, or
    does nothing for a case without one. The case's HOME must be its own folder under the state root."""
    name = (case.get("fixture") or {}).get("repo")
    if name is None:
        return None
    require_case_home(env, case_root)
    return build(RepoFixture.load(name, directory), case_root, env, run=run)


# ------------------------------------------------------------------------------------------ self test


class MakeRepoSelfTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.fixture = RepoFixture.load("oracle")

    def root(self, name: str) -> Path:
        path = Path(self.tmp.name) / name
        path.mkdir()
        return path

    def env(self, root: Path) -> Dict[str, str]:
        return {"PATH": DEFAULT_PATH, "HOME": str(root / "home"), "LANG": "C.UTF-8", "TZ": "UTC"}

    def git(self, cwd: Path, *argv: str, env: Optional[Mapping[str, str]] = None) -> str:
        return subprocess.run(["git", *argv], cwd=str(cwd), env=dict(env or self.env(cwd)), capture_output=True,
                              text=True, check=True).stdout.strip("\n")

    def test_two_builds_make_the_same_commits_with_the_fixed_dates(self) -> None:
        first = build(self.fixture, self.root("a"), self.env(self.root("ha")))
        second = build(self.fixture, self.root("b"), {**self.env(self.root("hb")), "GIT_AUTHOR_DATE": "@1 +0000",
                                                      "GIT_AUTHOR_NAME": "someone else"})
        self.assertEqual(first.commits, second.commits)
        self.assertEqual(len(first.commits), self.fixture.commit_count())
        dates = self.git(first.work, "log", "--all", "--reverse", "--format=%at %ct %an <%ae>", env=self.env(first.work))
        expected = [f"{t} {t} cmux oracle <oracle@localhost>"
                    for t in (self.fixture.epoch + i * SECONDS_PER_COMMIT for i in range(self.fixture.commit_count()))]
        self.assertEqual(dates.splitlines(), expected)

    def test_the_state_each_git_operation_needs(self) -> None:
        root = self.root("r")
        built = build(self.fixture, root, self.env(root))
        env = self.env(root)
        self.assertEqual(built.work, (root / "repos" / "oracle").resolve())
        self.assertEqual(self.git(built.work, "rev-list", "--count", "origin/main..main", env=env), "1", "git.push")
        self.assertEqual(self.git(built.work, "status", "--porcelain", env=env).splitlines(),
                         [" M notes.txt", "?? scratch.txt"], "git.commit paths, git.checkpoint.create")
        feature = built.worktrees[0]
        self.assertEqual(self.git(feature, "symbolic-ref", "--short", "HEAD", env=env), "cmux/feature")
        self.assertEqual(self.git(feature, "config", "--get", "branch.cmux/feature.cmuxBase", env=env), "main")
        self.assertEqual(self.git(feature, "rev-list", "--count", "main..HEAD", env=env), "1", "git.worktree.apply")
        self.assertEqual(self.git(feature, "status", "--porcelain", env=env), "", "a clean worktree")
        self.assertEqual(list((built.work / ".git" / "hooks").iterdir()), [], "an empty hooks folder")

    def test_every_remote_is_a_bare_repository_under_the_case_root(self) -> None:
        root = self.root("r")
        built = build(self.fixture, root, self.env(root))
        builder = Builder(self.fixture, root, self.env(root), subprocess.run)
        self.assertEqual(check_local_remotes(builder, built.work), {"origin": [built.origin, built.origin]}, "fetch and push URL")
        self.assertEqual(self.git(built.origin, "rev-parse", "--is-bare-repository", env=self.env(root)), "true")
        for url in ("git@github.com:manaflow-ai/cmux.git", "https://example.invalid/x.git", "/srv/x.git",
                    f"{root}/../elsewhere.git", "file://host/srv/x.git", "x.git"):
            with self.subTest(url=url):
                self.git(built.work, "remote", "add", "other", url, env=self.env(root))
                with self.assertRaisesRegex(FixtureError, "remote"):
                    check_local_remotes(builder, built.work)
                self.git(built.work, "remote", "remove", "other", env=self.env(root))

    def test_a_commit_without_any_git_variable_uses_the_repository_config(self) -> None:
        """git.commit and git.push drop every inherited GIT_* variable (git_ops/user_run.rs): the identity
        and the no-hook, no-signing settings must come from the repository itself."""
        root = self.root("r")
        built = build(self.fixture, root, self.env(root))
        bare_env = {"PATH": DEFAULT_PATH, "HOME": str(root / "home"), "LANG": "C.UTF-8"}
        self.git(built.work, "commit", "-q", "-m", "daemon commit", "--", "notes.txt", env=bare_env)
        self.assertEqual(self.git(built.work, "log", "-1", "--format=%an <%ae> %G?", env=bare_env),
                         "cmux oracle <oracle@localhost> N")
        self.git(built.work, "push", "-q", "origin", "main", env=bare_env)
        self.assertEqual(self.git(built.work, "rev-list", "--count", "origin/main..main", env=bare_env), "0")

    def test_build_for_case_reads_fixture_repo(self) -> None:
        root = self.root("r")
        self.assertIsNone(build_for_case({"fixture": {"seed": "s"}}, root, self.env(root)))
        built = build_for_case({"fixture": {"seed": "s", "repo": "oracle"}}, root, self.env(root))
        self.assertIsNotNone(built)
        with self.assertRaisesRegex(FixtureError, "exists"):
            build_for_case({"fixture": {"repo": "oracle"}}, root, self.env(root))
        other = self.root("s")
        with self.assertRaisesRegex(FixtureError, "no-such"):
            build_for_case({"fixture": {"repo": "no-such"}}, other, self.env(other))

    def test_build_for_case_needs_a_home_under_the_case_root(self) -> None:
        """git.worktree.create writes under ~/.cmux/worktrees (git_ops/worktree.rs): a case whose HOME is the
        runner's or another case's is refused before anything is built."""
        root, elsewhere = self.root("r"), self.root("elsewhere")
        case = {"fixture": {"repo": "oracle"}}
        for home in (None, "", "home", str(elsewhere / "home"), str(root), f"{root}/home/../../elsewhere"):
            env = {key: value for key, value in self.env(root).items() if key != "HOME"}
            if home is not None:
                env["HOME"] = home
            with self.subTest(home=home), self.assertRaisesRegex(FixtureError, "HOME .* is not a folder under"):
                build_for_case(case, root, env)
        self.assertFalse((root / REPOS_DIR).exists(), "nothing is built for a refused case")
        self.assertIsNotNone(build_for_case(case, root, self.env(root)))

    def test_the_tokens_name_the_built_folders(self) -> None:
        root = self.root("r")
        built = build(self.fixture, root, self.env(root))
        tokens = {key: Path(value.replace(ROOT_TOKEN, str(root.resolve()))) for key, value in self.fixture.tokens().items()}
        self.assertEqual(tokens, {"work": built.work, "origin": built.origin, "worktree:cmux/feature": built.worktrees[0]})

    def test_bad_fixtures_are_refused(self) -> None:
        good = json.loads((HERE / "oracle.json").read_text(encoding="utf-8"))

        def variant(**changes: Any) -> Dict[str, Any]:
            data = json.loads(json.dumps(good))
            data.update(changes)
            return data

        cases = {
            "files outside": variant(dirty={"../x": "x"}),
            "into .git": variant(untracked={".git/config": "x"}),
            "unknown key": variant(remote="https://example.invalid/x.git"),
            "url origin": variant(origin="https://example.invalid/x.git"),
            "dirty untracked": variant(dirty={"nope.txt": "x"}),
            "untracked tracked": variant(untracked={"notes.txt": "x"}),
            "pushed after unpushed": variant(commits=[{"message": "a", "files": {"a": "a"}},
                                                      {"message": "b", "files": {"b": "b"}, "pushed": True}]),
            "empty commit": variant(commits=[{"message": "a", "files": {}}]),
            "worktree on main": variant(worktrees=[{"path": "w", "branch": "main", "base": "main", "commits": []}]),
            "name mismatch": variant(name="other"),
            "bool epoch": variant(epoch=True),
        }
        for label, data in cases.items():
            with self.subTest(label), self.assertRaises(FixtureError):
                RepoFixture.parse(data, label, "oracle")
        self.assertEqual(RepoFixture.parse(good, "good", "oracle"), self.fixture)


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--build", type=Path, metavar="ROOT", help="build the fixture under ROOT/repos")
    parser.add_argument("--name", default="oracle", help="the fixture (tests/oracle/fixtures/git/NAME.json)")
    parser.add_argument("--selftest", action="store_true", help="run the self tests (needs git on PATH)")
    args = parser.parse_args(argv)
    if args.selftest:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(MakeRepoSelfTest)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    if args.build is None:
        parser.error("give --build ROOT or --selftest")
    try:
        built = build(RepoFixture.load(args.name), args.build, {"PATH": DEFAULT_PATH, "HOME": str(args.build / "home"),
                                                                 "LANG": "C.UTF-8", "TZ": "UTC"})
    except FixtureError as error:
        print(f"make_repo: {error}", file=sys.stderr)
        return 2
    print(json.dumps({"work": str(built.work), "origin": str(built.origin),
                      "worktrees": [str(path) for path in built.worktrees], "commits": list(built.commits)}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
