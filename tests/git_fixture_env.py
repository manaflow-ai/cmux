"""Keep git from leaving a background writer in temporary fixture repositories.

git commit, fetch, and clone start `git maintenance run --auto --detach`,
which can outlive the command and still be writing into `.git` when a
TemporaryDirectory is removed ("Directory not empty: '.git'"). The opt-out
(OPT_OUT: maintenance.auto=false, gc.auto=0, receive.autogc=false) reaches git
three ways, because each one alone has a hole:

1. Repository config. `init_repo` and `clone_repo` write OPT_OUT into the new
   repository's own config, work repositories and bare remotes alike. This is
   the one that always holds: git reads it whatever environment a fixture
   builds, and it is what a push into a local bare repository sees. Git's local
   transport starts `git receive-pack` with GIT_CONFIG_COUNT and
   GIT_CONFIG_PARAMETERS cleared, and receive-pack then starts its own detached
   maintenance in the bare repository (objects/maintenance.lock left
   "Directory not empty: 'objects'" in test_cmux_next_prepush_gate.py on
   2026-11-03).
2. GIT_CONFIG_COUNT/KEY/VALUE in os.environ, set when this module loads, for
   repositories the code under test makes itself.
3. GIT_CONFIG_GLOBAL, pointed (when unset; an empty value means no global
   config and is kept) at a file in a fresh private folder (tempfile.mkdtemp,
   removed at exit; never a predictable path another user could plant) that includes
   the person's global config files in plain git's order ($XDG_CONFIG_HOME/git/config,
   then ~/.gitconfig) and then sets OPT_OUT (global_config_text). Which files, and
   in what order, is asked of git (global_config_files), not re-implemented, and
   the shell helper writes what `python3 -I tests/git_fixture_env.py
   --global-config-text` prints, so the two cannot drift. Receive-pack reads it too.

A fixture that builds an environment from scratch (or filters GIT_* out of
os.environ) drops 2 and 3; pass it through `fixture_env`.

Load this module by path, never `import git_fixture_env`: tests run as
`python3 -I` have no script directory on sys.path. Shell tests source
scripts/cmux-next/tests/lib/git-fixture.sh, which has the same API
(git_fixture_init, git_fixture_clone). scripts/check-test-determinism.py's
git-temp-repo-maintenance, git-fixture-env-dropped and
git-bare-repo-unmanaged rules fail a test that skips this module.
"""

from __future__ import annotations

import atexit
import contextlib
import hashlib
import os
import shutil
import stat
import subprocess
import tempfile
from collections.abc import Mapping, MutableMapping
from pathlib import Path

# Applied in this order; the receiver side needs receive.autogc as well.
OPT_OUT: tuple[tuple[str, str], ...] = (
    ("maintenance.auto", "false"),
    ("gc.auto", "0"),
    ("receive.autogc", "false"),
)

# Config-file text with OPT_OUT, for a fixture that writes its own config file.
CONFIG_FILE_OPT_OUT = "[maintenance]\n\tauto = false\n[gc]\n\tauto = 0\n[receive]\n\tautogc = false\n"

_FALSE = {"false", "no", "off", "0"}


# Variables that point git at another repository, index, object store or config file. A test run from inside a
# git hook (pre-commit, pre-push) inherits GIT_DIR, GIT_INDEX_FILE and friends, and a fixture's `git -C TMP commit`
# then writes the hook's repository instead of TMP; an inherited GIT_CONFIG takes `git config` writes. The list is
# git's own (`git rev-parse --local-env-vars`: what git clears when it enters another repository), asked at load,
# without the -c pairs (GIT_CONFIG_PARAMETERS, GIT_CONFIG_COUNT: settings, not a location; the opt-out rides on
# them). The fallback is that list as git 2.55 prints it.
_REDIRECT_FALLBACK = (
    "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CONFIG", "GIT_OBJECT_DIRECTORY", "GIT_DIR", "GIT_WORK_TREE",
    "GIT_IMPLICIT_WORK_TREE", "GIT_GRAFT_FILE", "GIT_INDEX_FILE", "GIT_NO_REPLACE_OBJECTS", "GIT_REPLACE_REF_BASE",
    "GIT_PREFIX", "GIT_SHALLOW_FILE", "GIT_COMMON_DIR",
)
_SETTINGS = ("GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT")


def _local_env_vars() -> tuple[str, ...]:
    git = shutil.which("git")
    if git is None:
        return _REDIRECT_FALLBACK
    probe = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    try:
        result = subprocess.run((git, "rev-parse", "--local-env-vars"), env=probe, cwd=os.sep, capture_output=True,
                                text=True, stdin=subprocess.DEVNULL, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return _REDIRECT_FALLBACK
    names = tuple(name for name in result.stdout.split() if name not in _SETTINGS)
    return names if result.returncode == 0 and names else _REDIRECT_FALLBACK


REPO_REDIRECTS = _local_env_vars()


def without_redirects(env: MutableMapping[str, str]) -> MutableMapping[str, str]:
    """Drop REPO_REDIRECTS from env, in place: git then finds the repository from -C or the cwd, as a fixture means."""
    for name in REPO_REDIRECTS:
        env.pop(name, None)
    return env


def write_env(env: Mapping[str, str] | None = None) -> dict[str, str]:
    """The env for `git config --local` writes into a fixture repository: no redirect, no inherited -c pair
    (GIT_CONFIG_COUNT/KEY_*/VALUE_*, GIT_CONFIG_PARAMETERS), no global or system config."""
    result = {key: value for key, value in (os.environ if env is None else env).items()
              if not key.startswith(("GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_"))}
    without_redirects(result)
    for name in (*_SETTINGS, "GIT_CONFIG_SYSTEM"):
        result.pop(name, None)
    result.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
    return result


def without_auto_maintenance(env: MutableMapping[str, str]) -> MutableMapping[str, str]:
    """Append OPT_OUT to env's GIT_CONFIG_* pairs (each key once), in place."""
    count = int(env.get("GIT_CONFIG_COUNT") or 0)
    last: dict[str, str] = {}
    for index in range(count):
        key = env.get(f"GIT_CONFIG_KEY_{index}")
        if key is not None:
            last[key] = env.get(f"GIT_CONFIG_VALUE_{index}", "")
    for key, value in OPT_OUT:
        # Git uses the last entry for a key, so only a trailing opt-out is enough.
        if last.get(key, "").strip().lower() in _FALSE:
            continue
        env[f"GIT_CONFIG_KEY_{count}"] = key
        env[f"GIT_CONFIG_VALUE_{count}"] = value
        count += 1
    env["GIT_CONFIG_COUNT"] = str(count)
    return env


def _private_dir(folder: str) -> bool:
    """True when folder is a real directory (not a symlink) owned by this user with mode 0700."""
    try:
        info = os.lstat(folder)
    except OSError:
        return False
    return stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700


def _global_config_dir() -> str:
    # An inherited folder is used only when it is private to us: a shared or planted one (another user's, a
    # symlink, a world-writable one) could hold a config that adds core.hooksPath (cmux#40871 Codex F1).
    folder = os.environ.get("CMUX_GIT_FIXTURE_GLOBAL_DIR")
    if folder and _private_dir(folder):
        return folder
    folder = tempfile.mkdtemp(prefix="git-fixture-")  # mode 0700, a fresh unpredictable name
    atexit.register(shutil.rmtree, folder, True)
    os.environ["CMUX_GIT_FIXTURE_GLOBAL_DIR"] = folder
    return folder


def _quoted(path: str) -> str:
    return '"' + path.replace("\\", "\\\\").replace('"', '\\"') + '"'


# Every scope, so git itself says which top-level files are global and in what order. Not `--global`: for
# reading, `git config --global --list` reads only ~/.gitconfig when that file exists (git 2.55), not the
# XDG file before it.
_PROBE = ("config", "--list", "--show-scope", "--show-origin", "--name-only", "--no-includes", "-z")
# The git on PATH when this module loads: a fake `git` a test puts on PATH later never answers the probe.
_PROBE_GIT = shutil.which("git")


_GLOBAL_INPUTS = ("HOME", "XDG_CONFIG_HOME")


def _absolute_inputs(env: Mapping[str, str]) -> dict[str, str]:
    """env's HOME and XDG_CONFIG_HOME (those set and non-empty), each made absolute against this process's cwd.

    Plain git resolves a relative one against the cwd it runs in, but an [include] path in the fixture file
    resolves against that file's private folder, so a relative path written there names nothing (Codex on
    cmux#40939 at d4422bca).
    """
    return {key: os.path.abspath(env[key]) for key in _GLOBAL_INPUTS if env.get(key)}


def global_config_files(env: Mapping[str, str]) -> list[str]:
    """The global config files plain git reads under env, in the order it reads them (the last one wins).

    Asked of git, never re-implemented: with no GIT_* set (so no GIT_CONFIG_GLOBAL) and outside any repository,
    `git config --list --show-scope --show-origin --no-includes` names the file of each entry; the global-scope
    ones, in order, are $XDG_CONFIG_HOME/git/config (~/.config/git/config when it is unset) and then
    ~/.gitconfig. Their own include and includeIf lines are left to git through the [include] of each file. A
    file that is missing or holds no key adds nothing either way; when git cannot answer, the list is empty.
    A relative HOME or XDG_CONFIG_HOME counts from this process's cwd, as for plain git run here; every path
    returned is absolute.
    """
    if _PROBE_GIT is None:
        return []
    probe = {key: value for key, value in env.items() if not key.startswith("GIT_")}
    # The probe runs in / (outside any repository), so hand it the caller's cwd-relative inputs made absolute.
    probe.update(_absolute_inputs(env))
    try:
        result = subprocess.run((_PROBE_GIT, *_PROBE), env=probe, cwd=os.sep, capture_output=True,
                                stdin=subprocess.DEVNULL, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return []
    if result.returncode != 0:
        return []
    files: list[str] = []
    # -z: scope NUL origin NUL key NUL, entry after entry.
    fields = result.stdout.split(b"\0")
    for index in range(0, len(fields) - 2, 3):
        scope, origin = fields[index], fields[index + 1]
        if scope == b"global" and origin.startswith(b"file:"):
            path = os.path.abspath(os.fsdecode(origin[len(b"file:"):]))
            if path not in files:
                files.append(path)
    return files


def global_config_text(env: Mapping[str, str]) -> str:
    """GIT_CONFIG_GLOBAL text that reads env's global config files as plain git does (global_config_files),
    each by absolute [include] path, then OPT_OUT last. With no global file it holds OPT_OUT alone."""
    includes = "".join(f"[include]\n\tpath = {_quoted(path)}\n" for path in global_config_files(env))
    return includes + CONFIG_FILE_OPT_OUT


def global_config_for(env: Mapping[str, str]) -> str:
    """Path of a GIT_CONFIG_GLOBAL file with global_config_text(env); one file per distinct text."""
    return _config_file(global_config_text(env))


def _config_file(text: str) -> str:
    folder = _global_config_dir()
    path = os.path.join(folder, hashlib.sha256(text.encode()).hexdigest()[:16] + ".gitconfig")
    if not os.path.isfile(path):
        # A fresh name per writer (mkstemp, same folder), then an atomic rename: two threads or processes
        # writing the same text never share a partial file, so neither can rename the other's away mid-write
        # (`{path}.{pid}` was one name per process: FileNotFoundError under threads).
        handle, partial = tempfile.mkstemp(dir=folder, prefix=".partial-", suffix=".gitconfig")
        try:
            with os.fdopen(handle, "w") as stream:
                stream.write(text)
            os.replace(partial, path)
        except BaseException:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(partial)
            raise
    return path


_LOADED_INPUTS = _absolute_inputs(os.environ)
GLOBAL_CONFIG = global_config_for(os.environ) if __name__ != "__main__" else ""


def fixture_env(env: Mapping[str, str] | None = None) -> dict[str, str]:
    """A copy of env (default os.environ) without REPO_REDIRECTS, with OPT_OUT pairs and, if it names none, a
    GIT_CONFIG_GLOBAL with OPT_OUT."""
    result = dict(os.environ if env is None else env)
    without_redirects(result)
    without_auto_maintenance(result)
    if "GIT_CONFIG_GLOBAL" not in result:
        # This env's own global files (its HOME and XDG_CONFIG_HOME), as git reads them; the one made at load
        # when those match, so most calls cost no probe.
        same = _absolute_inputs(result) == _LOADED_INPUTS
        result["GIT_CONFIG_GLOBAL"] = GLOBAL_CONFIG if same and GLOBAL_CONFIG else global_config_for(result)
    return result


def _git(args: list[str], cwd: str | os.PathLike[str] | None, env: Mapping[str, str] | None,
         timeout: float | None = None, *, write: bool = False) -> None:
    run_env = write_env(env) if write else fixture_env(env)
    result = subprocess.run(["git", *args], cwd=cwd, env=run_env, capture_output=True, text=True,
                            timeout=timeout, stdin=subprocess.DEVNULL)
    if result.returncode != 0:
        # CalledProcessError, as subprocess.run(check=True) raised before the fixtures moved here.
        raise subprocess.CalledProcessError(result.returncode, ["git", *args], result.stdout, result.stderr)


def opt_out_repo(path: str | os.PathLike[str], *, cwd: str | os.PathLike[str] | None = None,
                 env: Mapping[str, str] | None = None) -> None:
    """Write OPT_OUT into an existing repository's own config (work tree or bare), with write_env: an inherited
    GIT_DIR or GIT_CONFIG never takes the write."""
    for key, value in OPT_OUT:
        _git(["-C", os.fspath(path), "config", "--local", key, value], cwd, env, write=True)


def init_repo(path: str | os.PathLike[str], *args: str, cwd: str | os.PathLike[str] | None = None,
              env: Mapping[str, str] | None = None) -> Path:
    """`git init -q *args path`, then OPT_OUT in its config. Pass "--bare", "-b", "main" and so on as args."""
    _git(["init", "-q", *args, os.fspath(path)], cwd, env)
    opt_out_repo(path, cwd=cwd, env=env)
    return Path(cwd or ".", path)


def clone_repo(source: str | os.PathLike[str], dest: str | os.PathLike[str], *args: str,
               cwd: str | os.PathLike[str] | None = None, env: Mapping[str, str] | None = None,
               timeout: float | None = None) -> Path:
    """`git clone -q *args source dest` with OPT_OUT written into the clone's config before it runs."""
    config = [part for key, value in OPT_OUT for part in ("-c", f"{key}={value}")]
    _git(["clone", "-q", *config, *args, os.fspath(source), os.fspath(dest)], cwd, env, timeout)
    return Path(cwd or ".", dest)


if __name__ == "__main__":
    # The shell helper's one source of truth: print the text and touch nothing (no folder, no os.environ change).
    import sys

    if sys.argv[1:] != ["--global-config-text"]:
        sys.exit("usage: python3 -I tests/git_fixture_env.py --global-config-text")
    sys.stdout.write(global_config_text(os.environ))
else:
    without_redirects(os.environ)
    without_auto_maintenance(os.environ)
    os.environ.setdefault("GIT_CONFIG_GLOBAL", GLOBAL_CONFIG)
