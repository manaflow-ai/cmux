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
3. GIT_CONFIG_GLOBAL, pointed (when unset) at a temporary file that includes
   ~/.gitconfig and ~/.config/git/config and then sets OPT_OUT (without the
   includes when HOME is unset: git refuses to expand ~/ then). Receive-pack
   reads it too.

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
import os
import shutil
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

_GLOBAL_CONFIG_TEXT = (
    # The person's (or the fixture HOME's) own global config first, so OPT_OUT after it wins.
    "[include]\n\tpath = ~/.gitconfig\n\tpath = ~/.config/git/config\n" + CONFIG_FILE_OPT_OUT
)
_FALSE = {"false", "no", "off", "0"}


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


def _global_config_dir() -> str:
    folder = os.environ.get("CMUX_GIT_FIXTURE_GLOBAL_DIR")
    if folder and os.path.isfile(os.path.join(folder, "home.gitconfig")):
        return folder
    folder = tempfile.mkdtemp(prefix="git-fixture-")
    with open(os.path.join(folder, "home.gitconfig"), "w") as handle:
        handle.write(_GLOBAL_CONFIG_TEXT)
    # Git refuses an include of ~/ when HOME is unset, so an environment without HOME gets this one.
    with open(os.path.join(folder, "no-home.gitconfig"), "w") as handle:
        handle.write(CONFIG_FILE_OPT_OUT)
    atexit.register(shutil.rmtree, folder, True)
    os.environ["CMUX_GIT_FIXTURE_GLOBAL_DIR"] = folder
    return folder


_GLOBAL_DIR = _global_config_dir()
GLOBAL_CONFIG = os.path.join(_GLOBAL_DIR, "home.gitconfig")
GLOBAL_CONFIG_NO_HOME = os.path.join(_GLOBAL_DIR, "no-home.gitconfig")


def fixture_env(env: Mapping[str, str] | None = None) -> dict[str, str]:
    """A copy of env (default os.environ) with OPT_OUT pairs and, if it names none, a GIT_CONFIG_GLOBAL with OPT_OUT."""
    result = dict(os.environ if env is None else env)
    without_auto_maintenance(result)
    result.setdefault("GIT_CONFIG_GLOBAL", GLOBAL_CONFIG if result.get("HOME") else GLOBAL_CONFIG_NO_HOME)
    return result


def _git(args: list[str], cwd: str | os.PathLike[str] | None, env: Mapping[str, str] | None,
         timeout: float | None = None) -> None:
    result = subprocess.run(["git", *args], cwd=cwd, env=fixture_env(env), capture_output=True, text=True,
                            timeout=timeout, stdin=subprocess.DEVNULL)
    if result.returncode != 0:
        # CalledProcessError, as subprocess.run(check=True) raised before the fixtures moved here.
        raise subprocess.CalledProcessError(result.returncode, ["git", *args], result.stdout, result.stderr)


def opt_out_repo(path: str | os.PathLike[str], *, cwd: str | os.PathLike[str] | None = None,
                 env: Mapping[str, str] | None = None) -> None:
    """Write OPT_OUT into an existing repository's own config (work tree or bare)."""
    for key, value in OPT_OUT:
        _git(["-C", os.fspath(path), "config", key, value], cwd, env)


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


without_auto_maintenance(os.environ)
os.environ.setdefault("GIT_CONFIG_GLOBAL", GLOBAL_CONFIG if os.environ.get("HOME") else GLOBAL_CONFIG_NO_HOME)
