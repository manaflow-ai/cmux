#!/usr/bin/env python3
"""Regression tests for https://github.com/manaflow-ai/cmux/issues/10230.

A custom `Claude Binary Path` script that resolves `claude` through PATH finds
cmux's own per-surface shim, so control re-enters `cmux-claude-wrapper` after it
has already injected its hook `--settings`. The wrapper must treat that re-entry
as a no-op: the injected settings must converge instead of growing one hook copy
per pass, and a user's own `--settings` must survive unchanged.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import stat
import time
import socket
import subprocess
import tempfile
from pathlib import Path

from node_runtime import ensure_node_on_path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_WRAPPER = ROOT / "Resources" / "bin" / "cmux-claude-wrapper"
CMUX_HOOK_FEED_COMMAND = "hooks feed --source claude"


def read_hook_pin() -> str:
    """The pin cmux marks its own hook commands with, read from the wrapper.

    Kept out of the tests as a literal so the two cannot drift: a wrapper that
    stops pinning, or pins with a different token, fails these tests instead of
    silently disabling hook ownership.
    """
    match = re.search(r"^cmux_claude_hook_pin='([^']+)'", SOURCE_WRAPPER.read_text(encoding="utf-8"), re.M)
    if match is None:
        raise AssertionError("cmux_claude_hook_pin is not defined in the wrapper")
    return match.group(1)


CMUX_HOOK_PIN = f"{read_hook_pin()} "


def read_state_tag() -> str:
    """The tag cmux stamps its re-entry state files with, read from the wrapper."""
    match = re.search(r"^cmux_claude_hook_state_tag='([^']+)'", SOURCE_WRAPPER.read_text(encoding="utf-8"), re.M)
    if match is None:
        raise AssertionError("cmux_claude_hook_state_tag is not defined in the wrapper")
    return match.group(1)


CMUX_STATE_TAG = read_state_tag()


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def settings_from_argv(argv: list[str]) -> dict | None:
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "--":
            return None
        if arg == "--settings" and index + 1 < len(argv):
            return json.loads(argv[index + 1])
        if arg.startswith("--settings="):
            return json.loads(arg[len("--settings=") :])
        index += 1
    return None


def count_cmux_hook_commands(settings: dict) -> int:
    total = 0
    for entries in (settings.get("hooks") or {}).values():
        for entry in entries:
            for hook in entry.get("hooks", []):
                if CMUX_HOOK_FEED_COMMAND in hook.get("command", ""):
                    total += 1
    return total


def collect_hooks(settings: dict) -> list[dict]:
    hooks: list[dict] = []
    for entries in (settings.get("hooks") or {}).values():
        for entry in entries:
            hooks.extend(entry.get("hooks", []))
    return hooks


def collect_hook_commands(settings: dict) -> list[str]:
    return [hook.get("command", "") for hook in collect_hooks(settings)]


class ReentryRun:
    def __init__(
        self,
        returncode: int,
        stderr: str,
        passes: list[list[str]],
        real_argv: list[str],
        state_entries: list[tuple[str, str]],
    ) -> None:
        self.returncode = returncode
        self.stderr = stderr
        self.passes = passes
        self.real_argv = real_argv
        # (name, kind) of what is left in the wrapper's state directory, sampled
        # before the fixture's temporary tree goes away.
        self.state_entries = state_entries


def run_reentry(
    *,
    argv: list[str],
    break_after: int | None,
    scrub_env_marker: bool = False,
    scrub_state_file: bool = False,
    reserialize_settings: bool = False,
    hostile_state_dir: Path | None = None,
    occupy_state_path: bool = False,
    seed_state_dir: int = 0,
    timeout: float = 30.0,
) -> ReentryRun:
    """Launch cmux's shim `claude` with a re-entrant custom Claude Binary Path.

    The custom binary path is a script that hands off to a launcher which
    resolves `claude` through PATH, exactly like the reporter's setup. PATH puts
    cmux's shim directory first, so every hand-off lands back in the wrapper.
    `break_after` passes lets the launcher escape the loop and reach the real
    binary; `None` keeps the loop running so the wrapper's guard has to stop it.
    `scrub_env_marker` drops the cmux re-entry env marker the way a launcher that
    rebuilds the environment would; `scrub_state_file` additionally deletes the
    per-process state file, leaving argv as the only re-entry signal.
    `reserialize_settings` re-encodes the --settings JSON with sorted keys, the
    way a launcher that parses and re-emits its arguments would, which moves the
    hooks object behind any large user-owned key that sorts before it.
    `hostile_state_dir` plants a symlink where the re-entry state directory
    belongs, pointing at that directory, the way a squatter in a shared /tmp
    would. `occupy_state_path` puts a fifo where the state file belongs, inside
    the wrapper's own verified directory, so the paths that write, read and
    delete it meet something that is not a regular file. `seed_state_dir` fills
    that directory with that many day-old pid-shaped entries plus one day-old
    file nobody named after a pid, to exercise the sweep.
    """

    with tempfile.TemporaryDirectory(prefix="cmux-claude-reentry-") as td:
        tmp = Path(td)
        shim_dir = tmp / "tmp" / "cmux-cli-shims" / "surface-reentry"
        launcher_dir = tmp / "launcher-bin"
        custom_dir = tmp / "custom-bin"
        real_dir = tmp / "real-bin"
        pass_dir = tmp / "passes"
        for directory in (shim_dir, launcher_dir, custom_dir, real_dir, pass_dir):
            directory.mkdir(parents=True, exist_ok=True)

        shim_claude = shim_dir / "claude"
        shutil.copy2(SOURCE_WRAPPER, shim_claude)
        shim_claude.chmod(0o755)

        fake_cmux = """#!/usr/bin/env bash
if [[ "${1:-}" == "--socket" ]]; then
  shift 2
fi
if [[ "${1:-}" == "ping" ]]; then
  exit 0
fi
exit 0
"""
        make_executable(shim_dir / "cmux", fake_cmux)

        real_argv_log = tmp / "real-argv.json"
        make_executable(
            real_dir / "claude",
            f"""#!/usr/bin/env python3
import json, sys
open({str(real_argv_log)!r}, "w").write(json.dumps(sys.argv[1:]))
""",
        )

        # Resolves `claude` through PATH the way `shutil.which` / `command -v` /
        # `execvp` do in a user launcher, which is what finds cmux's shim.
        break_after_literal = "None" if break_after is None else str(break_after)
        victim_literal = "None" if hostile_state_dir is None else repr(str(hostile_state_dir))
        occupy_literal = "True" if occupy_state_path else "False"
        scrub_literal = "True" if scrub_env_marker else "False"
        scrub_state_literal = "True" if scrub_state_file else "False"
        reserialize_literal = "True" if reserialize_settings else "False"
        make_executable(
            launcher_dir / "claude-launcher",
            f"""#!/usr/bin/env python3
import glob, json, os, shutil, stat, sys

pass_dir = {str(pass_dir)!r}
victim_dir = {victim_literal}
occupy_state_path = {occupy_literal}
break_after = {break_after_literal}
scrub_env_marker = {scrub_literal}
scrub_state_file = {scrub_state_literal}
reserialize_settings = {reserialize_literal}
argv = sys.argv[2:]
if victim_dir is not None:
    # Named after this pid, which is the pid the wrapper composes its state path
    # from: an unguarded write or delete through the planted symlink lands here.
    decoy = os.path.join(victim_dir, str(os.getpid()))
    if not os.path.exists(decoy):
        with open(decoy, "w") as handle:
            handle.write("decoy")
if occupy_state_path:
    state_dir = os.path.join(os.environ.get("TMPDIR", "/tmp"), "cmux-claude-hook-reentry-%d" % os.getuid())
    os.makedirs(state_dir, mode=0o700, exist_ok=True)
    state_path = os.path.join(state_dir, str(os.getpid()))
    if not os.path.exists(state_path) or not stat.S_ISFIFO(os.stat(state_path).st_mode):
        if os.path.exists(state_path):
            os.unlink(state_path)
        os.mkfifo(state_path)
if scrub_env_marker:
    for key in ("CMUX_CLAUDE_WRAPPER_HOOKS_INJECTED", "cmux_claude_wrapper_reexec_guard", "cmux_claude_wrapper_reexec_targets"):
        os.environ.pop(key, None)
if scrub_state_file:
    for name in glob.glob(os.path.join(os.environ.get("TMPDIR", "/tmp"), "cmux-claude-hook-reentry-*", "*")):
        os.unlink(name)
if reserialize_settings and "--settings" in argv:
    at = argv.index("--settings")
    if at + 1 < len(argv):
        argv[at + 1] = json.dumps(json.loads(argv[at + 1]), sort_keys=True)
index = len(os.listdir(pass_dir)) + 1
with open(os.path.join(pass_dir, "pass-%03d.json" % index), "w") as handle:
    json.dump(argv, handle)
if break_after is not None and index >= break_after:
    entries = [e for e in os.environ["PATH"].split(os.pathsep) if "cmux-cli-shims" not in e]
    os.environ["PATH"] = os.pathsep.join(entries)
target = shutil.which("claude")
if target is None:
    sys.stderr.write("launcher: claude not found\\n")
    raise SystemExit(127)
os.execv(target, ["claude"] + argv)
""",
        )

        custom_claude = custom_dir / "claude-custom"
        make_executable(
            custom_claude,
            f"""#!/bin/sh
exec {launcher_dir / "claude-launcher"} claude "$@"
""",
        )

        wrapper_tmpdir = tmp / "tmp"
        wrapper_tmpdir.mkdir(parents=True, exist_ok=True)
        if seed_state_dir:
            state_dir = wrapper_tmpdir / f"cmux-claude-hook-reentry-{os.getuid()}"
            state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
            stale = time.time() - 2 * 24 * 3600
            for index in range(seed_state_dir):
                entry = state_dir / str(900000 + index)
                entry.write_text(f"{CMUX_STATE_TAG} 1\n", encoding="utf-8")
                os.utime(entry, (stale, stale))
            for decoy_name, decoy_body in (("not-a-pid.txt", "keep me"), ("800001", "someone else's pid-shaped file")):
                decoy = state_dir / decoy_name
                decoy.write_text(decoy_body, encoding="utf-8")
                os.utime(decoy, (stale, stale))
        if hostile_state_dir is not None:
            (wrapper_tmpdir / f"cmux-claude-hook-reentry-{os.getuid()}").symlink_to(hostile_state_dir)

        socket_path = str(tmp / "cmux.sock")
        test_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        test_socket.bind(socket_path)

        # The wrapper folds a user's --settings into its own with node; without
        # node on PATH it falls back to emitting two --settings flags and the
        # merge under test never runs.
        node_dir = str(Path(ensure_node_on_path() or "/usr/bin/node").parent)
        env = {
            "HOME": str(tmp / "home"),
            "PATH": f"{shim_dir}:{launcher_dir}:{real_dir}:{node_dir}:/usr/bin:/bin",
            "TMPDIR": str(tmp / "tmp") + "/",
            "CMUX_SURFACE_ID": "surface:reentry",
            "CMUX_SOCKET_PATH": socket_path,
            "CMUX_CLAUDE_WRAPPER_SHIM": str(shim_claude),
            "CMUX_CLAUDE_WRAPPER_SHIM_ROOT": str(shim_dir),
            "CMUX_CUSTOM_CLAUDE_PATH": str(custom_claude),
        }
        (tmp / "home").mkdir(parents=True, exist_ok=True)

        try:
            proc = subprocess.run(
                [str(shim_claude), *argv],
                cwd=tmp,
                env=env,
                capture_output=True,
                text=True,
                timeout=timeout,
                check=False,
            )
            returncode = proc.returncode
            stderr = proc.stderr
        except subprocess.TimeoutExpired as expired:
            returncode = -1
            stderr = (expired.stderr or b"").decode("utf-8", "replace") if isinstance(expired.stderr, bytes) else (expired.stderr or "")
            stderr = f"TIMEOUT after {timeout}s\n{stderr}"
        finally:
            test_socket.close()

        passes = [json.loads(path.read_text(encoding="utf-8")) for path in sorted(pass_dir.iterdir())]
        real_argv = json.loads(real_argv_log.read_text(encoding="utf-8")) if real_argv_log.exists() else []
        state_dir = wrapper_tmpdir / f"cmux-claude-hook-reentry-{os.getuid()}"
        state_entries: list[tuple[str, str]] = []
        if state_dir.is_dir():
            for entry in sorted(state_dir.iterdir()):
                mode = entry.lstat().st_mode
                if stat.S_ISLNK(mode):
                    kind = "link"
                elif stat.S_ISFIFO(mode):
                    kind = "fifo"
                elif stat.S_ISDIR(mode):
                    kind = "dir"
                else:
                    kind = "file"
                state_entries.append((entry.name, kind))
        return ReentryRun(returncode, stderr, passes, real_argv, state_entries)


def test_reentry_does_not_duplicate_injected_hooks(failures: list[str]) -> None:
    run = run_reentry(argv=[], break_after=3)

    if len(run.passes) < 3:
        failures.append(f"expected at least 3 wrapper passes, got {len(run.passes)}: stderr={run.stderr!r}")
        return
    if not run.real_argv:
        failures.append(f"real claude never started: stderr={run.stderr!r}")
        return

    baseline = settings_from_argv(run.passes[0])
    if baseline is None:
        failures.append(f"first pass carried no --settings: {run.passes[0]!r}")
        return

    baseline_hook_count = count_cmux_hook_commands(baseline)
    if baseline_hook_count != 3:
        failures.append(f"expected 3 cmux hook-feed commands on first pass, got {baseline_hook_count}")

    for index, pass_argv in enumerate(run.passes[1:], start=2):
        settings = settings_from_argv(pass_argv)
        if settings is None:
            failures.append(f"pass {index} carried no --settings: {pass_argv!r}")
            continue
        hook_count = count_cmux_hook_commands(settings)
        if hook_count != baseline_hook_count:
            failures.append(
                f"pass {index} duplicated cmux hooks: {hook_count} hook-feed commands, expected {baseline_hook_count}"
            )
        if settings != baseline:
            failures.append(f"pass {index} settings diverged from the first pass")
        if pass_argv.count("--settings") != 1:
            failures.append(f"pass {index} carried {pass_argv.count('--settings')} --settings arguments, expected 1")
        if pass_argv.count("--session-id") > 1:
            failures.append(f"pass {index} carried {pass_argv.count('--session-id')} --session-id arguments")

    final_settings = settings_from_argv(run.real_argv)
    if final_settings is None:
        failures.append(f"real claude received no --settings: {run.real_argv!r}")
    elif count_cmux_hook_commands(final_settings) != baseline_hook_count:
        failures.append(
            "real claude received "
            f"{count_cmux_hook_commands(final_settings)} cmux hook-feed commands, expected {baseline_hook_count}"
        )


def test_reentry_preserves_user_settings(failures: list[str]) -> None:
    # Hooks the user authored that resemble cmux's own to increasing degrees:
    # same binary variable, then the same `hooks claude` shape, then the exact
    # command cmux injects with a different timeout, then a byte-identical copy
    # of an injected hook. None of them carries cmux's pin, so all four are the
    # user's and must survive every pass untouched.
    user_bin_hook = '"${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}" notify --title mine'
    user_hooks_claude_hook = '"${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}" hooks claude audit'
    cmux_stop_command = '"${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}" hooks claude stop'
    cmux_session_start_command = '"${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}" hooks claude session-start'
    user_settings = {
        "model": "user-selected-model",
        "hooks": {
            "Stop": [
                {
                    "matcher": "",
                    "hooks": [
                        {"type": "command", "command": "user-stop-hook", "timeout": 7},
                        {"type": "command", "command": user_bin_hook, "timeout": 7},
                        {"type": "command", "command": user_hooks_claude_hook, "timeout": 7},
                        {"type": "command", "command": cmux_stop_command, "timeout": 90},
                    ],
                }
            ],
            # Byte-identical to cmux's own SessionStart hook, pin excluded.
            "SessionStart": [
                {
                    "matcher": "",
                    "hooks": [
                        {"type": "command", "command": cmux_session_start_command, "timeout": 10},
                    ],
                }
            ],
        },
    }
    run = run_reentry(argv=["--settings", json.dumps(user_settings)], break_after=3)

    if len(run.passes) < 3:
        failures.append(f"expected at least 3 wrapper passes with user settings, got {len(run.passes)}: stderr={run.stderr!r}")
        return

    baseline = settings_from_argv(run.passes[0])
    if baseline is None:
        failures.append(f"first pass carried no --settings: {run.passes[0]!r}")
        return

    for index, pass_argv in enumerate(run.passes, start=1):
        settings = settings_from_argv(pass_argv)
        if settings is None:
            failures.append(f"pass {index} carried no --settings")
            continue
        if settings.get("model") != "user-selected-model":
            failures.append(f"pass {index} lost the user's model setting: {settings.get('model')!r}")
        hook_commands = collect_hook_commands(settings)
        user_hook_count = hook_commands.count("user-stop-hook")
        if user_hook_count != 1:
            failures.append(f"pass {index} carried {user_hook_count} copies of the user's hook, expected 1")
        for label, command in (("cmux-bin", user_bin_hook), ("hooks-claude", user_hooks_claude_hook)):
            count = hook_commands.count(command)
            if count != 1:
                failures.append(f"pass {index} carried {count} copies of the user's {label} hook, expected 1")
        user_timeouts = [
            hook.get("timeout")
            for hook in collect_hooks(settings)
            if hook.get("command") == cmux_stop_command and hook.get("timeout") == 90
        ]
        if len(user_timeouts) != 1:
            failures.append(
                f"pass {index} kept {len(user_timeouts)} copies of the user's own timeout on cmux's stop command, expected 1"
            )
        # The user's unpinned twin of an injected hook survives alongside cmux's
        # pinned one, exactly as it was written: two hooks run that command, one
        # pinned by cmux and one the user's, and the user's is byte-identical to
        # what they passed in.
        session_start_hooks = [
            hook for hook in collect_hooks(settings) if hook.get("command", "").endswith("hooks claude session-start")
        ]
        pinned = [hook for hook in session_start_hooks if hook.get("command", "").startswith(CMUX_HOOK_PIN)]
        unpinned = [hook for hook in session_start_hooks if not hook.get("command", "").startswith(CMUX_HOOK_PIN)]
        if unpinned != [{"type": "command", "command": cmux_session_start_command, "timeout": 10}]:
            failures.append(
                f"pass {index} did not keep the user's copy of cmux's session-start hook verbatim: {unpinned!r}"
            )
        if len(pinned) != 1:
            failures.append(
                f"pass {index} carried {len(pinned)} pinned session-start hooks alongside the user's copy, expected 1"
            )
        cmux_hook_count = count_cmux_hook_commands(settings)
        if cmux_hook_count != 3:
            failures.append(f"pass {index} carried {cmux_hook_count} cmux hook-feed commands, expected 3")
        if settings != baseline:
            failures.append(f"pass {index} settings diverged from the first pass")


def test_merge_converges_without_the_env_marker(failures: list[str]) -> None:
    """The merge alone must converge, so a launcher that rebuilds the
    environment still cannot grow the injected block one copy per pass."""

    user_settings = {"model": "user-selected-model"}
    run = run_reentry(
        argv=["--settings", json.dumps(user_settings)],
        break_after=3,
        scrub_env_marker=True,
        scrub_state_file=True,
    )

    if len(run.passes) < 3:
        failures.append(f"expected at least 3 wrapper passes without the env marker, got {len(run.passes)}: stderr={run.stderr!r}")
        return

    baseline = settings_from_argv(run.passes[0])
    if baseline is None:
        failures.append(f"first pass carried no --settings: {run.passes[0]!r}")
        return

    for index, pass_argv in enumerate(run.passes[1:], start=2):
        settings = settings_from_argv(pass_argv)
        if settings is None:
            failures.append(f"pass {index} carried no --settings without the env marker")
            continue
        hook_count = count_cmux_hook_commands(settings)
        if hook_count != 3:
            failures.append(f"pass {index} carried {hook_count} cmux hook-feed commands without the env marker, expected 3")
        if settings.get("model") != "user-selected-model":
            failures.append(f"pass {index} lost the user's model setting without the env marker")
        if settings != baseline:
            failures.append(f"pass {index} settings diverged from the first pass without the env marker")
        # settings_from_argv reads the first match, so argv growth has to be
        # asserted separately from payload convergence.
        if pass_argv.count("--settings") != 1:
            failures.append(
                f"pass {index} carried {pass_argv.count('--settings')} --settings arguments without the env marker, expected 1"
            )
        if pass_argv.count("--session-id") > 1:
            failures.append(
                f"pass {index} carried {pass_argv.count('--session-id')} --session-id arguments without the env marker"
            )


def test_hostile_state_directory_is_not_written_through(failures: list[str]) -> None:
    """With TMPDIR unset the state directory lands in a shared /tmp.

    A symlink planted at that path must not be followed: the wrapper has to do
    without its state file rather than write through someone else's link, and
    the launch has to proceed normally.
    """

    with tempfile.TemporaryDirectory(prefix="cmux-claude-reentry-victim-") as victim_dir:
        victim = Path(victim_dir)
        run = run_reentry(argv=[], break_after=3, hostile_state_dir=victim, timeout=30.0)

        # The launcher plants one decoy, named after the pid the wrapper composes
        # its state path from; nothing else may appear, and it must be untouched.
        planted = sorted(victim.iterdir())
        if len(planted) != 1 or planted[0].read_text(encoding="utf-8") != "decoy":
            failures.append(
                f"wrapper wrote through the planted symlink: {[(p.name, p.read_text(encoding='utf-8')) for p in planted]!r}"
            )
        if not run.real_argv:
            failures.append(f"real claude never started with a hostile state directory: {run.stderr!r}")
        if run.returncode != 0:
            failures.append(f"expected a clean launch with a hostile state directory, got {run.returncode}: {run.stderr!r}")


def test_hostile_state_directory_survives_the_guard_trip(failures: list[str]) -> None:
    """The cleanup path must refuse the planted link too, not just read and write.

    The guard deletes its state file when it trips, so this run lets the loop
    run to the limit. The launcher plants a decoy named after the pid the
    wrapper composes its state path from, which is exactly the file an
    unguarded write would overwrite or an unguarded delete would remove.
    """

    with tempfile.TemporaryDirectory(prefix="cmux-claude-reentry-victim-") as victim_dir:
        victim = Path(victim_dir)
        run = run_reentry(argv=[], break_after=None, hostile_state_dir=victim, timeout=30.0)

        if run.returncode == -1:
            failures.append(f"loop did not stop with a hostile state directory: {run.stderr!r}")
            return
        if run.returncode == 0:
            failures.append(f"expected a non-zero exit from the re-entry guard, got 0: {run.stderr!r}")
        decoys = sorted(path for path in victim.iterdir())
        if len(decoys) != 1:
            failures.append(f"victim directory changed through the planted symlink: {[p.name for p in decoys]!r}")
            return
        if decoys[0].read_text(encoding="utf-8") != "decoy":
            failures.append(f"wrapper wrote through the planted symlink: {decoys[0].read_text(encoding='utf-8')!r}")


def test_state_path_occupied_by_a_non_regular_file_is_left_alone(failures: list[str]) -> None:
    """Only a regular file cmux owns is written, read or deleted at that path.

    The launcher replaces the wrapper's state file with a fifo inside the
    wrapper's own verified directory. Writing to it would block the launch
    forever and deleting it would destroy something cmux did not create, so the
    wrapper has to leave it alone and still stop the loop on the env-side count.
    """

    run = run_reentry(argv=[], break_after=None, occupy_state_path=True, timeout=30.0)

    if run.returncode == -1:
        failures.append(f"a fifo at the state path stalled or unbounded the launch: {run.stderr!r}")
        return
    if run.returncode == 0:
        failures.append(f"expected a non-zero exit from the re-entry guard, got 0: {run.stderr!r}")
    if "Claude Binary Path" not in run.stderr:
        failures.append(f"expected the error to name Claude Binary Path, got: {run.stderr!r}")
    kinds = [kind for _, kind in run.state_entries]
    if kinds != ["fifo"]:
        failures.append(f"wrapper did not leave the fifo at its state path alone: {run.state_entries!r}")


def test_state_directory_sweep_only_removes_its_own_entries(failures: list[str]) -> None:
    """The sweep clears cmux's own stale entries and nothing else.

    Seeded past the sweep threshold with day-old tagged entries plus two day-old
    files another process of the same user could have left there -- one of them
    pid-shaped, so the name alone cannot tell them apart -- a launch has to
    collect its own litter and leave both strangers exactly where they are.
    """

    run = run_reentry(argv=[], break_after=3, seed_state_dir=300, timeout=30.0)

    if not run.real_argv:
        failures.append(f"real claude never started with a seeded state directory: {run.stderr!r}")
    names = [name for name, _ in run.state_entries]
    for decoy_name in ("not-a-pid.txt", "800001"):
        if decoy_name not in names:
            failures.append(
                f"sweep removed {decoy_name}, which cmux did not write: {names[:8]!r} ({len(names)} entries)"
            )
    seeded_left = [name for name in names if name.isdigit() and name.startswith("9")]
    if seeded_left:
        failures.append(f"sweep left {len(seeded_left)} of its own day-old entries behind: {seeded_left[:8]!r}")


def test_env_scrubbed_reentry_loop_is_stopped(failures: list[str]) -> None:
    """A launcher that rebuilds the environment must not unbound the loop.

    The env marker is gone on every pass, so the bound has to come from the
    state file this process wrote before handing off.
    """

    run = run_reentry(argv=[], break_after=None, scrub_env_marker=True, timeout=30.0)

    if run.returncode == -1:
        failures.append(
            f"a scrubbed environment defeated the loop guard: {run.stderr!r} after {len(run.passes)} passes"
        )
        return
    if run.returncode == 0:
        failures.append(f"expected a non-zero exit from the re-entry guard, got 0: {run.stderr!r}")
    if "Claude Binary Path" not in run.stderr:
        failures.append(f"expected the error to name Claude Binary Path, got: {run.stderr!r}")
    if len(run.passes) > 32:
        failures.append(f"re-entry guard allowed {len(run.passes)} passes without the env marker")


def test_reentry_guard_survives_a_reserializing_launcher(failures: list[str]) -> None:
    """The loop guard must not depend on where the pin lands in the payload.

    A launcher that parses and re-emits its arguments re-encodes the settings
    JSON; with a large user key that sorts before "hooks", cmux's pinned hook
    moves kilobytes into the value. A guard that only inspected the head of the
    value would stop recognising the re-entry and never bound the loop.
    """

    user_settings = {"aaa_large_user_key": "x" * 8192, "model": "user-selected-model"}
    run = run_reentry(
        argv=["--settings", json.dumps(user_settings)],
        break_after=None,
        reserialize_settings=True,
        timeout=30.0,
    )

    if run.returncode == -1:
        failures.append(
            f"re-serialized settings defeated the loop guard: {run.stderr!r} after {len(run.passes)} passes"
        )
        return
    if run.returncode == 0:
        failures.append(f"expected a non-zero exit from the re-entry guard, got 0: {run.stderr!r}")
    if "Claude Binary Path" not in run.stderr:
        failures.append(f"expected the error to name Claude Binary Path, got: {run.stderr!r}")
    if len(run.passes) > 32:
        failures.append(f"re-entry guard allowed {len(run.passes)} passes before stopping")
    if run.passes:
        settings = settings_from_argv(run.passes[-1])
        if settings is None:
            failures.append(f"last pass carried no --settings: {run.passes[-1]!r}")
        else:
            if settings.get("aaa_large_user_key") != "x" * 8192:
                failures.append("the user's large setting did not survive re-serialized re-entry")
            if count_cmux_hook_commands(settings) != 3:
                failures.append(
                    f"last pass carried {count_cmux_hook_commands(settings)} cmux hook-feed commands, expected 3"
                )


def test_unbounded_reentry_loop_is_stopped(failures: list[str]) -> None:
    run = run_reentry(argv=[], break_after=None, timeout=30.0)

    if run.returncode == -1:
        failures.append(f"wrapper never stopped the re-entry loop: {run.stderr!r} after {len(run.passes)} passes")
        return
    if run.returncode == 0:
        failures.append(f"expected a non-zero exit from the re-entry guard, got 0: {run.stderr!r}")
    if "cmux:" not in run.stderr:
        failures.append(f"expected an actionable cmux error on stderr, got: {run.stderr!r}")
    if "Claude Binary Path" not in run.stderr:
        failures.append(f"expected the error to name Claude Binary Path, got: {run.stderr!r}")
    if len(run.passes) > 32:
        failures.append(f"re-entry guard allowed {len(run.passes)} passes before stopping")


def main() -> int:
    if ensure_node_on_path() is None:
        print("SKIP: node runtime not found; the wrapper's --settings merge needs node")
        return 0
    failures: list[str] = []
    test_reentry_does_not_duplicate_injected_hooks(failures)
    test_reentry_preserves_user_settings(failures)
    test_merge_converges_without_the_env_marker(failures)
    test_unbounded_reentry_loop_is_stopped(failures)
    test_env_scrubbed_reentry_loop_is_stopped(failures)
    test_state_path_occupied_by_a_non_regular_file_is_left_alone(failures)
    test_state_directory_sweep_only_removes_its_own_entries(failures)
    test_hostile_state_directory_is_not_written_through(failures)
    test_hostile_state_directory_survives_the_guard_trip(failures)
    test_reentry_guard_survives_a_reserializing_launcher(failures)
    if failures:
        print("FAIL: claude wrapper --settings re-entry checks failed")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("PASS: claude wrapper --settings injection converges across re-entry")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
