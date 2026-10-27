#!/usr/bin/env python3
"""The one place that builds the environment of an oracle case (p15-oracle-200).

Chromium's browser_tests start every test from a fresh profile directory, a fixed locale and time zone,
no network but `net::EmbeddedTestServer` on loopback, and no background fetches
(chrome/test/base/in_process_browser_test.cc, net/test/embedded_test_server/embedded_test_server.h,
`--disable-background-networking` in chrome/common/chrome_switches.cc). This module does the same:

- an `env -i` base: nothing of the harness's environment reaches a case, only the names below;
- per-case HOME, XDG_*, TMPDIR, CMUX_TUI_CONFIG, CMUX_NEXT_CONFIG_FILE, CMUX_TUI_STATE_DIR,
  CMUX_TUI_SOCKET and CMUX_TUI_LOG_FILE under the case's state root (`/tmp/o/<run6>/<case6>`);
- TZ=UTC, LANG=C.UTF-8, SHELL=/bin/sh with a fixed PS1, no login-shell start, agent hooks, telemetry
  and the update check off, CMUX_TUI_OFFLINE=1 (owner_start/background_checks.rs: no feature-flag or
  registry fetch);
- git without the person's config: GIT_CONFIG_GLOBAL=/dev/null, GIT_CONFIG_NOSYSTEM=1, an empty
  core.hooksPath, no signing, only the file transport, a fixed identity and dates, and a local bare
  origin for every generated repository (`local_bare_origin`); `require_local_remote` refuses any
  other remote, for the generators (gen_daemon_ops.py, p15-oracle-060);
- the one harness name a case keeps: LLVM_PROFILE_FILE, where an instrumented build writes its counters
  (linux_run.sh run --coverage, p15-oracle-190; Chromium's testing/test_env.py hands it to every test
  process). It changes where counters go, never what the binary does;
- on Linux, every process of a case runs in its own network namespace with only loopback up: `unshare
  -rn` brings `lo` up as namespace root, then a nested user namespace maps the caller's uid and gid
  back, so the daemon runs as the same uid as without isolation (its /tmp/cmux-hd-<uid> and
  /tmp/cmux-th-<uid> paths, its non-root code paths).

driver_daemon.py (p15-oracle-023), driver_app.py (p15-oracle-047) and gen_daemon_ops.py
(p15-oracle-060) take their environment from here and nowhere else; `--audit` checks that. Each
driver puts `CaseEnv.receipt()` (or `app_session(...)["receipt"]`) in its case result, so a
receipt lists the environment the case ran with.

    python3 -I scripts/cmux-next/oracle/hermetic_env.py --probe          # can this host isolate a case?
    python3 -I scripts/cmux-next/oracle/hermetic_env.py --print ROOT     # the env of a case at ROOT
    python3 -I scripts/cmux-next/oracle/hermetic_env.py --audit          # drivers build no env
    python3 -I scripts/cmux-next/oracle/hermetic_env_test.py             # unit tests
"""

from __future__ import annotations

import argparse
import ast
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.parse
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, List, Mapping, Optional, Sequence, Tuple

TASK = "p15-oracle-200"
HERE = Path(__file__).resolve().parent

# sun_path is 104 bytes on Darwin and 108 on Linux; spec 3G keeps a margin.
MAX_SOCKET_PATH_BYTES = 100
ROOT_TOKEN = "$CASE_ROOT"
FIXED_PS1 = "$ "
# A fixed author and committer date: generated repositories get the same commit ids on every run.
GIT_DATE = "2026-01-01T00:00:00Z"
GIT_IDENTITY = ("cmux oracle", "oracle@localhost")
PATH_BY_PLATFORM = {
    "linux": "/usr/local/bin:/usr/bin:/bin",
    "mac": "/usr/bin:/bin:/usr/sbin:/sbin",
}
# Where the probe looks for unshare(1) and ip(8); the case PATH has no sbin.
TOOL_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
ISOLATION_MODES = ("netns", "auto", "none")

# The layout of a case root. driver_daemon.py's CasePaths reads these names.
SOCKET_NAME = "s.sock"
STATE_DIR = "state"
HOME_DIR = "home"
RUN_DIR = "run"
TMP_DIR = "tmp"
REPOS_DIR = "repos"

# git config for every case, passed as GIT_CONFIG_COUNT/KEY/VALUE so no file is read or written.
GIT_CONFIG: Tuple[Tuple[str, str], ...] = (
    ("core.hooksPath", ""),  # an empty hooksPath runs no hook, not even the repository's own
    ("commit.gpgsign", "false"),
    ("tag.gpgsign", "false"),
    ("init.defaultBranch", "main"),
    ("protocol.allow", "never"),  # only the local transport below; a remote URL fails at once
    ("protocol.file.allow", "always"),
    ("user.name", GIT_IDENTITY[0]),
    ("user.email", GIT_IDENTITY[1]),
)


class HermeticError(Exception):
    """A case environment that cannot be built as the oracle requires."""


class SocketPathTooLong(HermeticError):
    pass


class NonLocalRemote(HermeticError):
    pass


class NetworkIsolationUnavailable(HermeticError):
    pass


def caller_ids() -> Tuple[int, int]:
    """The uid and gid every case process runs as (Windows has neither: -1)."""
    return getattr(os, "getuid", lambda: -1)(), getattr(os, "getgid", lambda: -1)()


@dataclass(frozen=True)
class Isolation:
    """How the processes of a case are kept off the network.

    `kind` is "netns" (Linux, netns_prefix) or "none"; `prefix` goes before every argv of the case;
    `uid` and `gid` are the ids the case processes run as (the caller's, with or without a namespace).
    """

    kind: str
    prefix: Tuple[str, ...]
    reason: str
    uid: int = field(default_factory=lambda: caller_ids()[0])
    gid: int = field(default_factory=lambda: caller_ids()[1])

    def describe(self) -> Dict[str, Any]:
        return {"kind": self.kind, "prefix": list(self.prefix), "reason": self.reason, "uid": self.uid,
                "gid": self.gid}

    @classmethod
    def from_description(cls, data: Mapping[str, Any]) -> "Isolation":
        """The inverse of describe(), for a driver that hands the session's isolation to a worker."""
        kind = data.get("kind")
        if kind not in ("netns", "none"):
            raise HermeticError(f"unknown isolation kind {kind!r}")
        uid, gid = data.get("uid"), data.get("gid")
        if not isinstance(uid, int) or not isinstance(gid, int):
            raise HermeticError(f"isolation description without an integer uid and gid: {dict(data)!r}")
        return cls(str(kind), tuple(str(word) for word in data.get("prefix") or ()), str(data.get("reason") or ""),
                   uid, gid)


NO_ISOLATION_REQUESTED = Isolation("none", (), "isolation none was asked for")

Runner = Callable[..., "subprocess.CompletedProcess[str]"]


def netns_prefix(unshare: str, ip: str, uid: int, gid: int) -> Tuple[str, ...]:
    """A new network namespace whose only device `lo` starts down, with the caller's uid inside it.

    `unshare -rn` (a user namespace, so no privilege is needed) makes the shell root of the namespace,
    so it can bring `lo` up; the nested `unshare -U --map-user --map-group` maps the caller's uid and
    gid back and runs the case's argv in place (same pid, inherited descriptors). Without the nested
    namespace the daemon would run as uid 0: shared /tmp/cmux-hd-0 and /tmp/cmux-th-0 directories and
    its root-only code paths.
    """
    drop = f'exec {unshare} -U --map-user={uid} --map-group={gid} -- "$@"'
    return (unshare, "-rn", "--", "/bin/sh", "-c", f"{ip} link set lo up && {drop}", "oracle-netns")


def probe_isolation(
    platform: str,
    *,
    required: bool = True,
    run: Runner = subprocess.run,
    which: Callable[[str], Optional[str]] = lambda name: shutil.which(name, path=TOOL_PATH),
    ids: Callable[[], Tuple[int, int]] = caller_ids,
) -> Isolation:
    """Isolation for `platform`, checked once per run (oracle.py) or per driver command.

    Linux: runs `id -u` under the netns prefix and requires the caller's uid back. When the host
    refuses unprivileged user namespaces
    (Ubuntu's kernel.apparmor_restrict_unprivileged_userns=1) this raises NetworkIsolationUnavailable,
    unless `required` is False, which gives kind "none" with the refusal as its reason; a receipt
    then shows that the run was not network-isolated. Darwin has no unprivileged namespace: the
    app product relies on CMUX_TUI_OFFLINE and loopback-only cases (case-v1 noRemoteUrl).
    """
    if platform != "linux":
        return Isolation("none", (), f"{platform} has no unprivileged network namespace")
    uid, gid = ids()
    tools = {name: which(name) for name in ("unshare", "ip", "id")}
    missing = [name for name, path in tools.items() if not path]
    refusal: Optional[str] = None
    prefix: Tuple[str, ...] = ()
    if missing:
        refusal = f"no {missing[0]} in {TOOL_PATH}"
    else:
        prefix = netns_prefix(str(tools["unshare"]), str(tools["ip"]), uid, gid)
        try:
            proc = run([*prefix, str(tools["id"]), "-u"], capture_output=True, text=True, timeout=30, check=False,
                       env={})
            if proc.returncode != 0:
                refusal = proc.stderr.strip() or f"exit {proc.returncode}"
            elif proc.stdout.strip() != str(uid):
                refusal = f"a case would run as uid {proc.stdout.strip()!r}, not {uid}"
        except (OSError, subprocess.TimeoutExpired) as error:
            refusal = str(error)
    if refusal is None:
        return Isolation("netns", prefix, "unshare -rn, loopback only, the caller's uid mapped back", uid, gid)
    reason = (
        f"unshare -rn refused: {refusal}. Allow unprivileged user namespaces "
        "(sysctl kernel.apparmor_restrict_unprivileged_userns=0, or an AppArmor profile for unshare)"
    )
    if required:
        raise NetworkIsolationUnavailable(reason)
    return Isolation("none", (), reason)


def isolation_for(mode: str, platform: str, *, run: Runner = subprocess.run, **kwargs: Any) -> Isolation:
    """A driver's session isolation: "netns" (Linux default; refuses a host without it), "auto" (netns
    when the host allows it, else none with the reason) or "none" (asked for; the receipt says so)."""
    if mode not in ISOLATION_MODES:
        raise HermeticError(f"isolation {mode!r} is not one of {', '.join(ISOLATION_MODES)}")
    if mode == "none":
        return NO_ISOLATION_REQUESTED
    return probe_isolation(platform, required=mode == "netns" and platform == "linux", run=run, **kwargs)


def git_config_env(pairs: Sequence[Tuple[str, str]] = GIT_CONFIG) -> Dict[str, str]:
    env = {"GIT_CONFIG_COUNT": str(len(pairs))}
    for index, (key, value) in enumerate(pairs):
        env[f"GIT_CONFIG_KEY_{index}"] = key
        env[f"GIT_CONFIG_VALUE_{index}"] = value
    return env


def git_env() -> Dict[str, str]:
    """Every git variable a case gets: no global or system config, no prompt, fixed identity and dates."""
    name, email = GIT_IDENTITY
    return {
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_AUTHOR_NAME": name,
        "GIT_AUTHOR_EMAIL": email,
        "GIT_COMMITTER_NAME": name,
        "GIT_COMMITTER_EMAIL": email,
        "GIT_AUTHOR_DATE": GIT_DATE,
        "GIT_COMMITTER_DATE": GIT_DATE,
        **git_config_env(),
    }


# Where an instrumented binary writes its counters; the only name a case takes from the harness.
PROFILE_FILE_VAR = "LLVM_PROFILE_FILE"


def profile_env(environ: Mapping[str, str] = os.environ) -> Dict[str, str]:
    """The harness's LLVM_PROFILE_FILE for a coverage run (linux_run.sh run --coverage), else nothing."""
    value = environ.get(PROFILE_FILE_VAR, "")
    if not value:
        return {}
    if not os.path.isabs(value):
        raise HermeticError(f"{PROFILE_FILE_VAR}={value!r} is not absolute: a case runs in its own root")
    return {PROFILE_FILE_VAR: value}


# The account-name variables. A daemon case gets fixed ones; the app keeps bench_launch's.
ACCOUNT_IDENTITY = ("USER", "LOGNAME")


def identity_env() -> Dict[str, str]:
    """The account name of a daemon case: fixed, so a receipt or snapshot never names the host's user."""
    return {name: "oracle" for name in ACCOUNT_IDENTITY}


def quiet_env() -> Dict[str, str]:
    """Locale, shell and the switches that keep cmux-tui from reaching out or changing the shell."""
    return {
        "TZ": "UTC",
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "TERM": "xterm-256color",
        "SHELL": "/bin/sh",
        "PS1": FIXED_PS1,
        # cmux-tui-core login_shell.rs: the shell does not start as a login shell.
        "CMUX_TUI_NO_LOGIN_SHELL": "1",
        # claude_wrapper.rs / codex_wrapper.rs: no agent hook injection.
        "CMUX_TUI_CLAUDE_HOOKS_DISABLED": "1",
        "CMUX_TUI_CODEX_HOOKS_DISABLED": "1",
        # update_notice.rs and owner_start/crash_forward.rs.
        "CMUX_TUI_UPDATE_CHECK": "off",
        "CMUX_TUI_TELEMETRY": "off",
        "DO_NOT_TRACK": "1",
        # owner_start/background_checks.rs: no feature-flag or registry fetch at all.
        "CMUX_TUI_OFFLINE": "1",
    }


@dataclass(frozen=True)
class CaseEnv:
    """The environment, paths and isolation of one daemon case."""

    root: Path
    env: Mapping[str, str]
    isolation: Isolation
    dirs: Tuple[Path, ...] = field(default=(), repr=False)

    @property
    def home(self) -> Path:
        return Path(self.env["HOME"])

    @property
    def socket(self) -> Path:
        return Path(self.env["CMUX_TUI_SOCKET"])

    @property
    def state_dir(self) -> Path:
        return Path(self.env["CMUX_TUI_STATE_DIR"])

    @property
    def log_file(self) -> Path:
        return Path(self.env["CMUX_TUI_LOG_FILE"])

    @property
    def cwd(self) -> Path:
        return self.root

    def command(self, argv: Sequence[str]) -> List[str]:
        """`argv` inside the case's isolation (the netns prefix on Linux)."""
        return [*self.isolation.prefix, *argv]

    def run(self, argv: Sequence[str], *, timeout: float = 60, run: Runner = subprocess.run, **kwargs: Any):
        """Runs `argv` with exactly this environment, in the case root and the case's isolation."""
        return run(
            self.command(argv), env=dict(self.env), cwd=str(self.cwd), timeout=timeout,
            capture_output=True, text=True, check=False, **kwargs,
        )

    def prepare(self) -> "CaseEnv":
        """Creates the case directories (the runtime one private, as XDG requires)."""
        for path in self.dirs:
            path.mkdir(parents=True, exist_ok=True)
        os.chmod(self.env["XDG_RUNTIME_DIR"], 0o700)
        return self

    def receipt(self) -> Dict[str, Any]:
        """The environment for a receipt: every name and value, the case root written ROOT_TOKEN."""
        root = str(self.root)
        return {
            "task": TASK,
            "env": {key: value.replace(root, ROOT_TOKEN) for key, value in sorted(self.env.items())},
            "isolation": self.isolation.describe(),
        }


def daemon_case(
    state_root: Path,
    isolation: Isolation,
    *,
    platform: str = "linux",
    seed: Optional[str] = None,
    switches: Optional[str] = None,
    extra: Optional[Mapping[str, str]] = None,
) -> CaseEnv:
    """The whole environment of one daemon case at `state_root`; `.prepare()` creates its directories.

    `seed` is the case's fixture.seed (CMUX_TUI_ORACLE_SEED, p15-oracle-185), `switches` the encoded
    CMUX_TUI_SWITCHES value (switches.py, p15-oracle-049); both are left out when None. `extra` adds
    a driver's own names (its process marker); a name this module sets is refused there.
    """
    root = Path(state_root)
    if not root.is_absolute():
        raise HermeticError(f"state root {root} is not absolute")
    home = root / HOME_DIR
    run_dir = root / RUN_DIR
    state = root / STATE_DIR
    socket_path = root / SOCKET_NAME
    length = len(os.fsencode(str(socket_path)))
    if length > MAX_SOCKET_PATH_BYTES:
        raise SocketPathTooLong(f"socket path {socket_path} is {length} bytes, over {MAX_SOCKET_PATH_BYTES}")
    env = {
        "PATH": PATH_BY_PLATFORM.get(platform, PATH_BY_PLATFORM["linux"]),
        "HOME": str(home),
        "XDG_CONFIG_HOME": str(home / ".config"),
        "XDG_DATA_HOME": str(home / ".local" / "share"),
        "XDG_STATE_HOME": str(home / ".local" / "state"),
        "XDG_CACHE_HOME": str(home / ".cache"),
        "XDG_RUNTIME_DIR": str(run_dir),
        "TMPDIR": str(root / TMP_DIR),
        "CMUX_TUI_CONFIG": str(root / "config.json"),
        "CMUX_NEXT_CONFIG_FILE": str(root / "cmux-next.json"),
        "CMUX_TUI_STATE_DIR": str(state),
        "CMUX_TUI_LOG_FILE": str(root / "client.log"),
        "CMUX_TUI_SOCKET": str(socket_path),
        # terminal_host_runtime/sys/unix.rs: hosts bind in a per-install directory, not a shared one
        # (honored by debug-assertion builds such as --profile oracle).
        "CMUX_TUI_TEST_HOST_INSTALL_ENDPOINT": "1",
        **identity_env(),
        **quiet_env(),
        **git_env(),
        **profile_env(),
    }
    if seed is not None:
        env["CMUX_TUI_ORACLE_SEED"] = seed
    if switches is not None:
        env["CMUX_TUI_SWITCHES"] = switches
    for key, value in (extra or {}).items():
        if key in env or not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
            raise HermeticError(f"extra variable {key!r} is owned by hermetic_env.py or not a plain name")
        env[key] = value
    dirs = (home, home / ".config", home / ".local" / "share", home / ".local" / "state", home / ".cache",
            run_dir, state, root / TMP_DIR, root / REPOS_DIR)
    return CaseEnv(root, env, isolation, dirs)


def app_session(
    scratch: Path, *, seed: Optional[str] = None, switches: Optional[str] = None
) -> Dict[str, Any]:
    """What driver_app.py passes as `BenchApp(env=...)`, and the receipt of it.

    The app keeps bench_launch's HOME, USER, LOGNAME and socket (its control socket and TagTeardown are
    found from the account's home; DaemonLauncher and TerminalEnvironment key on the account's name) and
    runs several cases per launch, so only the names below are fixed per session.
    The app strips every inherited CMUX_TUI_* name before it starts its daemon
    (LaunchIdentity.stripInheritedEnvironment); the daemon variables reach it only through the
    CMUX_NEXT_* knobs the app forwards (DaemonDiagnosticKnobs, p15-oracle-180), so the receipt says
    which of them the app does not get.
    """
    env: Dict[str, str] = {
        **{key: value for key, value in quiet_env().items() if not key.startswith("CMUX_TUI_")},
        **git_env(),
        "CMUX_NEXT_CHIEF_HOME": str(Path(scratch) / "chief"),
    }
    if seed is not None:
        env["CMUX_NEXT_ORACLE_SEED"] = seed
    if switches is not None:
        env["CMUX_NEXT_SWITCHES"] = switches
    receipt = {
        "task": TASK,
        "env": dict(sorted(env.items())),
        "isolation": Isolation("none", (), "the app runs on a fleet Mac").describe(),
        "daemon_env_not_forwarded": sorted(key for key in quiet_env() if key.startswith("CMUX_TUI_")),
    }
    return {"env": env, "receipt": receipt}


# ---- generated repositories -------------------------------------------------------------------------


def require_local_remote(url: str, case_root: Path) -> Path:
    """The path of a git remote that is local to the case, or NonLocalRemote.

    Accepted: an absolute path or a file:/// URL (empty or localhost host) under `case_root`. Refused:
    every other scheme, scp-style `host:path`, a relative path, and paths outside the case.
    """
    root = Path(case_root).resolve()
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme == "file":
        if parsed.netloc not in ("", "localhost"):
            raise NonLocalRemote(f"remote {url!r} names host {parsed.netloc!r}")
        path = Path(urllib.parse.unquote(parsed.path))
    elif parsed.scheme == "" and url.startswith("/") and not url.startswith("//"):
        path = Path(url)
    else:
        raise NonLocalRemote(f"remote {url!r} is not a local path or file:/// URL")
    resolved = path.resolve()
    if resolved != root and root not in resolved.parents:
        raise NonLocalRemote(f"remote {url!r} is outside the case root")
    return resolved


def check_repo_remotes(case: CaseEnv, repo: Path, *, run: Runner = subprocess.run) -> Dict[str, List[Path]]:
    """Every remote of `repo` (fetch and push URLs), each checked by require_local_remote."""
    listed = case.run(["git", "-C", str(repo), "remote"], run=run)
    if listed.returncode != 0:
        raise HermeticError(f"git remote in {repo}: {listed.stderr.strip()}")
    remotes: Dict[str, List[Path]] = {}
    for name in listed.stdout.split():
        for flag in ([], ["--push"]):
            got = case.run(["git", "-C", str(repo), "remote", "get-url", "--all", *flag, name], run=run)
            if got.returncode != 0:
                raise HermeticError(f"git remote get-url {name} in {repo}: {got.stderr.strip()}")
            for url in got.stdout.splitlines():
                if url:
                    remotes.setdefault(name, []).append(require_local_remote(url, case.root))
    return remotes


def local_bare_origin(
    case: CaseEnv, name: str, files: Mapping[str, str], *, run: Runner = subprocess.run
) -> Tuple[Path, Path]:
    """A work repository `repos/<name>` with one commit of `files`, whose origin is the bare
    `repos/<name>.git` and whose main tracks origin/main. Returns (work, bare)."""
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", name) or name.endswith(".git"):
        raise HermeticError(f"repository name {name!r} is not a plain name")
    bare = case.root / REPOS_DIR / f"{name}.git"
    work = case.root / REPOS_DIR / name
    for argv in (["git", "init", "-q", "--bare", str(bare)], ["git", "init", "-q", str(work)]):
        _git(case, argv, run)
    for relative, text in sorted(files.items()):
        target = (work / relative).resolve()
        if work.resolve() not in target.parents:
            raise HermeticError(f"fixture file {relative!r} is outside {work}")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
    for argv in (
        ["git", "-C", str(work), "add", "-A"],
        ["git", "-C", str(work), "commit", "-q", "--allow-empty", "-m", "fixture"],
        ["git", "-C", str(work), "remote", "add", "origin", str(bare)],
        ["git", "-C", str(work), "push", "-q", "-u", "origin", "main"],
    ):
        _git(case, argv, run)
    check_repo_remotes(case, work, run=run)
    return work, bare


def _git(case: CaseEnv, argv: Sequence[str], run: Runner) -> None:
    proc = case.run(argv, run=run)
    if proc.returncode != 0:
        raise HermeticError(f"{' '.join(argv)}: {proc.stderr.strip()}")


# ---- audit ------------------------------------------------------------------------------------------

# Files that must take their environment from this module, with their spec tasks.
AUDITED = {"driver_daemon.py": "p15-oracle-023", "driver_app.py": "p15-oracle-047",
           "gen_daemon_ops.py": "p15-oracle-060"}
FORBIDDEN = (
    (re.compile(r"\bos\.environ\b|\bos\.getenv\b|\bputenv\b"), "reads or changes the harness environment"),
    (re.compile(r"""["'](HOME|PATH|XDG_[A-Z_]+|TMPDIR|TZ|LANG|LC_ALL|SHELL|PS1|GIT_[A-Z_]+|CMUX_TUI_[A-Z_]+)["']"""),
     "names a variable hermetic_env.py owns"),
)
# Calls that start a process; without `env=` the child inherits the whole harness environment.
SUBPROCESS_SPAWNS = frozenset({"Popen", "run", "call", "check_call", "check_output", "getoutput", "getstatusoutput"})
OS_SPAWN_PREFIXES = ("exec", "spawn", "posix_spawn", "system", "popen")
# Processes that are no case's, by file, keyed by the argv's first word as the source writes it: the
# driver's own worker (it builds each case's env here) and the process-table readers of the I6 proof.
NOT_CASE_PROCESSES: Dict[str, frozenset] = {
    "driver_daemon.py": frozenset({"sys.executable", "'ps'", "'pgrep'"}),
    # host_meta's hw.model read for the snapshot's meta.host.
    "driver_app.py": frozenset({"'/usr/sbin/sysctl'"}),
}


def _spawn_name(call: ast.Call) -> Optional[str]:
    func = call.func
    if not (isinstance(func, ast.Attribute) and isinstance(func.value, ast.Name)):
        return None
    if func.value.id == "subprocess" and func.attr in SUBPROCESS_SPAWNS:
        return f"subprocess.{func.attr}"
    if func.value.id == "os" and func.attr.startswith(OS_SPAWN_PREFIXES):
        return f"os.{func.attr}"
    return None


def _argv_head(call: ast.Call) -> str:
    if not call.args:
        return ""
    first = call.args[0]
    if isinstance(first, (ast.List, ast.Tuple)) and first.elts:
        first = first.elts[0]
    if isinstance(first, ast.Starred):
        first = first.value
    return ast.unparse(first)


def spawn_findings(name: str, text: str) -> List[str]:
    """Process starts in `text` with the harness's environment: an os.exec*/spawn*/system call, or a
    subprocess call without `env=` whose argv is not listed in NOT_CASE_PROCESSES."""
    try:
        tree = ast.parse(text, filename=name)
    except SyntaxError as error:
        return [f"{name}:{error.lineno}: does not parse: {error.msg}"]
    allowed = NOT_CASE_PROCESSES.get(name, frozenset())
    findings = []
    for node in ast.walk(tree):
        spawn = _spawn_name(node) if isinstance(node, ast.Call) else None
        if spawn is None:
            continue
        if spawn.startswith("os."):
            findings.append(f"{name}:{node.lineno}: {spawn} starts a process outside CaseEnv")
        elif not any(keyword.arg == "env" for keyword in node.keywords) and _argv_head(node) not in allowed:
            findings.append(f"{name}:{node.lineno}: {spawn}({_argv_head(node) or '...'}, ...) without env= "
                            "inherits the harness environment")
    return findings


def audit(folder: Path = HERE) -> Tuple[List[str], List[str]]:
    """(findings, notes). Findings: lines of the audited files that build an environment themselves or
    start a process with the harness's. Notes: each audited file, or that it is not on this branch."""
    findings: List[str] = []
    notes: List[str] = []
    for name, task in AUDITED.items():
        path = folder / name
        if not path.exists():
            notes.append(f"{name}: not present ({task}), not audited")
            continue
        text = path.read_text(encoding="utf-8")
        for number, line in enumerate(text.splitlines(), 1):
            for pattern, why in FORBIDDEN:
                if pattern.search(line):
                    findings.append(f"{name}:{number}: {why}: {line.strip()}")
        findings.extend(spawn_findings(name, text))
        notes.append(f"{name}: audited")
    return findings, notes


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--probe", action="store_true", help="report whether this host can isolate a case")
    group.add_argument("--print", type=Path, metavar="ROOT", help="print the receipt of a daemon case at ROOT")
    group.add_argument("--audit", action="store_true", help="refuse drivers that build their own environment")
    parser.add_argument("--platform", default="linux" if sys.platform.startswith("linux") else "mac")
    args = parser.parse_args(argv)
    if args.probe:
        try:
            isolation = probe_isolation(args.platform)
        except NetworkIsolationUnavailable as error:
            print(f"hermetic_env: {error}", file=sys.stderr)
            return 1
        print(json.dumps(isolation.describe(), indent=2))
        return 0
    if args.print:
        isolation = probe_isolation(args.platform, required=False)
        print(json.dumps(daemon_case(args.print, isolation, platform=args.platform).receipt(), indent=2))
        return 0
    findings, notes = audit()
    for note in notes:
        print(note)
    for finding in findings:
        print(finding, file=sys.stderr)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
