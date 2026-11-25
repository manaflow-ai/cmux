#!/usr/bin/env python3
"""An agent wrapper must get past a mise shim that hands the launch back.

mise keeps a shim, a symlink to its own binary, for every tool any of its
runtimes has installed. Where no version of the tool is selected, the shim
runs the next same-named executable on PATH outside its own directory, and in
a cmux terminal that is cmux's per-surface shim. The wrapper then has to take
the executable after mise's shim instead of choosing that shim again. A tool
that replaces itself by name is not a hand-back and must still run again.
"""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

from node_runtime import ensure_node_on_path
from test_claude_wrapper_hooks import NATIVE_FAKE_CLAUDE_C, generated_claude_hook_settings


ROOT = Path(__file__).resolve().parents[1]
WRAPPER_DIR = ROOT / "Resources" / "bin"
SURFACE_ID = "0F0E0D0C-0B0A-4908-8706-050403020100"
PI_EXTENSION_MARKER = "cmux-pi-session-extension-marker v4"
CODEX_INJECTED_ARG = "cmux_test_hook_marker=1"
# The stand-in shim gives up with this code once one process comes back to it
# FALLBACK_LIMIT times, the way mise reports "shim fallback recursion detected".
FALLBACK_LOOP_EXIT_CODE = 98
FALLBACK_LIMIT = 3


@dataclass(frozen=True)
class Agent:
    command: str
    wrapper: str
    shim_variable: str
    custom_path_variable: str | None
    session_args: tuple[str, ...]
    # The cmux CLI call each wrapper makes once while preparing a session launch.
    preparation_call: str
    # Hermes starts `--version` and other administrative commands with cmux's
    # shims already off PATH, so only a session launch can come back to it.
    needs_session_launch: bool = False


AGENTS = (
    Agent(
        "codex",
        "cmux-codex-wrapper",
        "CMUX_CODEX_WRAPPER_SHIM",
        "CMUX_CUSTOM_CODEX_PATH",
        ("fix the bug",),
        "hooks codex inject-args",
    ),
    Agent(
        "claude",
        "cmux-claude-wrapper",
        "CMUX_CLAUDE_WRAPPER_SHIM",
        "CMUX_CUSTOM_CLAUDE_PATH",
        ("fix the bug",),
        # The wrapper's socket check. It also asks for hook settings, but
        # under a one-second watchdog that a loaded machine can trip.
        "ping",
    ),
    Agent(
        "amp",
        "cmux-amp-wrapper",
        "CMUX_AMP_WRAPPER_SHIM",
        "CMUX_CUSTOM_AMP_PATH",
        ("fix the bug",),
        "hooks amp install --yes",
    ),
    Agent("pi", "cmux-pi-wrapper", "CMUX_PI_WRAPPER_SHIM", None, ("fix the bug",), "hooks pi extension-source"),
    Agent(
        "hermes",
        "cmux-hermes-agent-wrapper",
        "CMUX_HERMES_AGENT_WRAPPER_SHIM",
        "CMUX_CUSTOM_HERMES_AGENT_PATH",
        ("chat",),
        "hooks hermes-agent install --yes",
        needs_session_launch=True,
    ),
)
AGENTS_BY_COMMAND = {agent.command: agent for agent in AGENTS}

VERSION_MANAGER = f"""#!/bin/bash
# Stand-in for mise, started through one of its shims. With a version selected
# it puts that install ahead of its shim directory on PATH and runs the tool
# from it. With none it runs the next same-named executable outside the shim's
# directory, and like mise it hands PATH on with duplicate entries dropped.
name="${{0##*/}}"
self_dir="$(cd "$(dirname "$0")" && pwd)"
printf '%s\\n' "$$" >> "$VERSION_MANAGER_SHIM_LOG"
count=0
if [[ "${{VERSION_MANAGER_SHIM_CHAIN:-}}" == "$$:"* ]]; then
    count="${{VERSION_MANAGER_SHIM_CHAIN#*:}}"
fi
if (( count >= {FALLBACK_LIMIT} )); then
    echo "version-manager shim: fallback recursion detected for $name" >&2
    exit {FALLBACK_LOOP_EXIT_CODE}
fi
export VERSION_MANAGER_SHIM_CHAIN="$$:$((count + 1))"
if [[ -n "${{VERSION_MANAGER_SELECTED_DIR:-}}" ]]; then
    export PATH="${{PATH/$self_dir/$VERSION_MANAGER_SELECTED_DIR:$self_dir}}"
    exec "$VERSION_MANAGER_SELECTED_DIR/$name" "$@"
fi
if [[ -n "${{ORPHAN_FIFO:-}}" && ! -e "$ORPHAN_FIFO.reached" ]]; then
    # Hand the launch back only once the process that started it has gone.
    : > "$ORPHAN_FIFO.reached"
    echo reached > "$ORPHAN_FIFO"
    while [[ "$(ps -o ppid= -p $$ | tr -d ' ')" == "$ORPHAN_LAUNCHER_PID" ]]; do :; done
fi
IFS=:
deduplicated=""
for directory in $PATH; do
    case ":$deduplicated:" in
        *":$directory:"*) continue ;;
    esac
    deduplicated="${{deduplicated:+$deduplicated:}}$directory"
done
export PATH="$deduplicated"
for directory in $PATH; do
    [[ "$directory" == "$self_dir" ]] && continue
    if [[ -x "$directory/$name" ]]; then
        exec "$directory/$name" "$@"
    fi
done
echo "version-manager shim: $name not found" >&2
exit 127
"""

# One line per run: the executable that ran, then every argument, tab-separated.
RECORDING_AGENT = """#!/bin/bash
name="${0##*/}"
{
    printf '%s' "$0"
    for argument in "$@"; do
        printf '\\t%s' "$argument"
    done
    printf '\\n'
} >> "$AGENT_RUN_LOG"
if [[ -n "${AGENT_LAUNCH_EXECUTABLE_LOG:-}" ]]; then
    printf '%s\n' "${CMUX_AGENT_LAUNCH_EXECUTABLE-__UNSET__}" > "$AGENT_LAUNCH_EXECUTABLE_LOG"
fi
if [[ -n "${AGENT_CMUX_VARIABLES_LOG:-}" ]]; then
    printf '%s\n' "${!CMUX_@}" > "$AGENT_CMUX_VARIABLES_LOG"
fi
if [[ "${AGENT_STARTS_CHILD:-}" == "1" ]]; then
    AGENT_STARTS_CHILD=0 "$name" --version || exit 1
fi
if [[ -n "${AGENT_REPLACES_ITSELF:-}" ]]; then
    # In place and by name, the way Hermes restarts itself.
    mode="$AGENT_REPLACES_ITSELF"
    unset AGENT_REPLACES_ITSELF
    if [[ "$mode" == "same-arguments" ]]; then
        exec "$name" "$@"
    fi
    exec "$name" "$@" --replaced
fi
exit 0
"""

# Starts the agent in the background and leaves once the version manager has
# the launch, as `(agent &)` in a script does. The hand-back then reaches a
# wrapper whose parent has gone.
ORPHANING_LAUNCHER = """#!/bin/bash
export ORPHAN_LAUNCHER_PID=$$
"$@" &
read -r _ < "$ORPHAN_FIFO"
exit 0
"""

FAKE_CMUX = f"""#!/bin/bash
if [[ "${{1:-}}" == "--socket" ]]; then
    shift 2
fi
printf '%s\\n' "$*" >> "$FAKE_CMUX_CALL_LOG"
case "$*" in
    "hooks codex inject-args")
        printf '%s\\0%s\\0' '-c' '{CODEX_INJECTED_ARG}'
        ;;
    "hooks pi extension-source")
        printf '%s\\n' '// {PI_EXTENSION_MARKER}'
        ;;
    "hooks claude inject-settings")
        printf '%s' "$FAKE_GENERATED_CLAUDE_HOOK_SETTINGS"
        ;;
esac
exit 0
"""


def node_executable() -> str | None:
    """The Node binary itself. `node` on PATH may be a version manager's shim,
    which stops resolving once it is linked into a fixture directory."""
    node = ensure_node_on_path()
    if node is None:
        return None
    resolved = subprocess.run(
        [node, "-e", "process.stdout.write(process.execPath)"],
        capture_output=True,
        text=True,
        check=False,
    )
    return resolved.stdout if resolved.returncode == 0 and resolved.stdout else None


def write_executable(path: Path, contents: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(contents, encoding="utf-8")
    path.chmod(0o755)


class Fixture:
    """A cmux surface shim, a version-manager shim and an installed agent, in PATH order."""

    def __init__(
        self,
        root: Path,
        agent: Agent,
        *,
        agent_installed: bool = True,
        node: str | None = None,
    ) -> None:
        self.root = root
        self.agent = agent
        self.shim_root = root / "home" / ".cmuxterm" / "cmux-cli-shims" / SURFACE_ID
        self.version_manager_dir = root / "version-manager" / "shims"
        self.installed_dir = root / "installed"
        self.tools_dir = root / "tools"
        self.version_manager_log = root / "version-manager-shim.log"
        self.agent_log = root / "agent-runs.log"
        self.cmux_log = root / "cmux-calls.log"
        (root / "tmp").mkdir(parents=True)
        self.installed_dir.mkdir()

        self.cmux_shim = self.shim_root / agent.command
        write_executable(
            self.cmux_shim,
            "#!/bin/bash\n"
            f"export {agent.shim_variable}='{self.cmux_shim}'\n"
            f"export {agent.shim_variable}_ROOT='{self.shim_root}'\n"
            f"exec '{WRAPPER_DIR / agent.wrapper}' \"$@\"\n",
        )
        # A shim is a symlink to the version manager's own binary, as mise makes them.
        version_manager = root / "version-manager" / "bin" / "mise"
        write_executable(version_manager, VERSION_MANAGER)
        self.version_manager_shim = self.version_manager_dir / agent.command
        self.version_manager_dir.mkdir(parents=True)
        self.version_manager_shim.symlink_to(version_manager)
        self.installed_agent = self.installed_dir / agent.command
        if agent_installed:
            write_executable(self.installed_agent, RECORDING_AGENT)
        self.fake_cmux = self.tools_dir / "cmux"
        write_executable(self.fake_cmux, FAKE_CMUX)
        if node is not None:
            # Linked alone, so the directory Node lives in, which can hold real
            # agents, stays off the fixture's PATH.
            (self.tools_dir / "node").symlink_to(node)

    def environment(self) -> dict[str, str]:
        return {
            "HOME": str(self.root / "home"),
            "TMPDIR": str(self.root / "tmp"),
            # The repeated entry is what a real PATH often has, and what the
            # version manager drops when it hands a launch on.
            "PATH": f"{self.shim_root}:{self.version_manager_dir}:{self.installed_dir}:/usr/bin:/bin:/usr/bin",
            "VERSION_MANAGER_SHIM_LOG": str(self.version_manager_log),
            "AGENT_RUN_LOG": str(self.agent_log),
            "FAKE_CMUX_CALL_LOG": str(self.cmux_log),
        }

    def cmux_terminal_environment(self, socket_path: Path) -> dict[str, str]:
        environment = self.environment()
        environment["PATH"] = environment["PATH"].replace("/usr/bin:/bin", f"{self.tools_dir}:/usr/bin:/bin")
        environment.update(
            {
                "CMUX_SURFACE_ID": SURFACE_ID,
                "CMUX_SOCKET_PATH": str(socket_path),
                "CMUX_BUNDLED_CLI_PATH": str(self.fake_cmux),
                "PI_CODING_AGENT_DIR": str(self.root / "pi-agent"),
                "HERMES_HOME": str(self.root / "hermes-home"),
                # The hook installers run under short deadlines; a loaded
                # machine must not turn their exact-once counts into a miss.
                "CMUX_AMP_HOOK_INSTALL_TIMEOUT_SECONDS": "30",
                "CMUX_HERMES_AGENT_HOOK_INSTALL_TIMEOUT_SECONDS": "30",
                "FAKE_GENERATED_CLAUDE_HOOK_SETTINGS": generated_claude_hook_settings(),
            }
        )
        return environment

    def run(self, environment: dict[str, str], *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(self.cmux_shim), *args],
            env=environment,
            cwd=self.root,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )

    def runs(self) -> list[list[str]]:
        """Every agent run as [executable, argument, ...], in order."""
        if not self.agent_log.exists():
            return []
        return [line.split("\t") for line in self.agent_log.read_text(encoding="utf-8").splitlines()]

    def agent_runs(self) -> list[list[str]]:
        """The arguments of each run of the agent installed after the shim."""
        return [run[1:] for run in self.runs() if run[0] == str(self.installed_agent)]

    def path_without_version_manager(self) -> str:
        return f"{self.shim_root}:{self.installed_dir}:{self.tools_dir}:/usr/bin:/bin:/usr/bin"

    def launch(self, *, child: bool = False, **overrides: str) -> tuple[subprocess.CompletedProcess[str], list[str]]:
        """Start the agent the way that can come back to its wrapper, and return the arguments used."""
        if self.agent.needs_session_launch:
            environment = self.cmux_terminal_environment(self.root / "no-cmux.sock")
            arguments = list(self.agent.session_args)
        else:
            environment = self.environment()
            arguments = ["--version"]
        environment.update(overrides)
        if child:
            environment["AGENT_STARTS_CHILD"] = "1"
        return self.run(environment, *arguments), arguments

    def version_manager_shim_pids(self) -> list[str]:
        if not self.version_manager_log.exists():
            return []
        return self.version_manager_log.read_text(encoding="utf-8").split()

    def cmux_calls(self) -> list[str]:
        if not self.cmux_log.exists():
            return []
        return self.cmux_log.read_text(encoding="utf-8").splitlines()


def describe(result: subprocess.CompletedProcess[str]) -> str:
    return f"exit {result.returncode}, stdout {result.stdout!r}, stderr {result.stderr!r}"


def check_fallback_reaches_installed_agent(agent: Agent, failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix=f"cmux-vm-{agent.command}-") as directory:
        fixture = Fixture(Path(directory), agent)
        result, arguments = fixture.launch()
        if result.returncode != 0 or fixture.agent_runs() != [arguments]:
            failures.append(
                f"{agent.command}: the installed agent after a version-manager shim did not run once "
                f"with the original arguments: runs {fixture.runs()!r}, {describe(result)}"
            )
        if len(fixture.version_manager_shim_pids()) != 1:
            failures.append(
                f"{agent.command}: the wrapper chose the version-manager shim "
                f"{len(fixture.version_manager_shim_pids())} times, expected once"
            )


def check_selected_version_still_runs(agent: Agent, failures: list[str]) -> None:
    """Where the version manager has a version selected, its tool runs, not the one after it."""
    with tempfile.TemporaryDirectory(prefix=f"cmux-vm-{agent.command}-") as directory:
        fixture = Fixture(Path(directory), agent)
        selected_dir = fixture.root / "version-manager" / "installs"
        selected_agent = selected_dir / agent.command
        write_executable(selected_agent, RECORDING_AGENT)
        result, arguments = fixture.launch(VERSION_MANAGER_SELECTED_DIR=str(selected_dir))
        if result.returncode != 0 or fixture.runs() != [[str(selected_agent), *arguments]]:
            failures.append(
                f"{agent.command}: expected only the version manager's selected tool to run: "
                f"runs {fixture.runs()!r}, {describe(result)}"
            )


def check_missing_agent_is_reported_by_the_shim(agent: Agent, failures: list[str]) -> None:
    """With nothing after the shim, the version manager's own error is the one the user gets."""
    with tempfile.TemporaryDirectory(prefix=f"cmux-vm-{agent.command}-") as directory:
        fixture = Fixture(Path(directory), agent, agent_installed=False)
        result, _ = fixture.launch()
        if result.returncode != FALLBACK_LOOP_EXIT_CODE or "fallback recursion detected" not in result.stderr:
            failures.append(
                f"{agent.command}: expected the version manager to report the launch it cannot "
                f"resolve, got {describe(result)}"
            )


def check_tool_replacing_itself_runs_again(agent: Agent, failures: list[str]) -> None:
    """A tool that restarts in place by name is a new launch of the same tool, not a hand-back."""
    scenarios = (
        # (name, version manager on PATH, version selected, other install, replacement arguments)
        ("no version manager", False, False, True, "same-arguments"),
        ("no version manager, second install", False, False, True, "same-arguments"),
        ("after a fallback", True, False, True, "same-arguments"),
        ("selected version, other arguments", True, True, True, "other-arguments"),
        ("selected version, same arguments", True, True, True, "same-arguments"),
        ("selected version, no other install", True, True, False, "same-arguments"),
    )
    for name, version_manager_on_path, selected, other_install, replacement in scenarios:
        with tempfile.TemporaryDirectory(prefix=f"cmux-vm-{agent.command}-") as directory:
            fixture = Fixture(Path(directory), agent, agent_installed=other_install)
            overrides = {"AGENT_REPLACES_ITSELF": replacement}
            expected_tool = fixture.installed_agent
            if not version_manager_on_path:
                overrides["PATH"] = fixture.path_without_version_manager()
            if "second install" in name:
                # An ordinary install is never skipped, whatever follows it.
                second_install_dir = fixture.root / "second-install"
                write_executable(second_install_dir / agent.command, RECORDING_AGENT)
                overrides["PATH"] = f"{overrides['PATH']}:{second_install_dir}"
            if selected:
                selected_dir = fixture.root / "version-manager" / "installs"
                expected_tool = selected_dir / agent.command
                write_executable(expected_tool, RECORDING_AGENT)
                overrides["VERSION_MANAGER_SELECTED_DIR"] = str(selected_dir)
            result, arguments = fixture.launch(**overrides)
            second = arguments if replacement == "same-arguments" else [*arguments, "--replaced"]
            runs = fixture.runs()
            tools = [run[0] for run in runs]
            if (
                result.returncode != 0
                or tools != [str(expected_tool)] * 2
                or runs[0][-len(arguments):] != arguments
                or runs[1][-len(second):] != second
            ):
                failures.append(
                    f"{agent.command}: a tool replacing itself by name ({name}) did not run again: "
                    f"runs {runs!r}, {describe(result)}"
                )


def check_child_launch_resolves_again(agent: Agent, failures: list[str]) -> None:
    """A process the agent starts is a new launch: it goes through the version manager again."""
    with tempfile.TemporaryDirectory(prefix=f"cmux-vm-{agent.command}-") as directory:
        fixture = Fixture(Path(directory), agent)
        result, _ = fixture.launch(child=True)
        pids = fixture.version_manager_shim_pids()
        if result.returncode != 0 or len(fixture.agent_runs()) != 2 or len(pids) != 2 or len(set(pids)) != 2:
            failures.append(
                f"{agent.command}: expected the agent and the child it starts to each pass the "
                f"version-manager shim once: shim pids {pids!r}, runs {fixture.agent_runs()!r}, {describe(result)}"
            )


def check_passthrough_after_fallback_keeps_cmux_variables_out(agent: Agent, failures: list[str]) -> None:
    """`--version` in a cmux terminal reaches the tool without cmux's variables, fallback or not."""
    with tempfile.TemporaryDirectory(prefix=f"cmux-vm-{agent.command}-") as directory:
        fixture = Fixture(Path(directory), agent)
        variables_log = fixture.root / "cmux-variables.log"
        environment = fixture.cmux_terminal_environment(fixture.root / "no-cmux.sock")
        environment["AGENT_CMUX_VARIABLES_LOG"] = str(variables_log)
        result = fixture.run(environment, "--version")
        variables = variables_log.read_text(encoding="utf-8").split() if variables_log.exists() else ["__NOT_RUN__"]
        if result.returncode != 0 or variables:
            failures.append(
                f"{agent.command}: a passthrough launch after a fallback carried cmux variables "
                f"{variables!r}: {describe(result)}"
            )


def check_custom_path_shim_falls_back(agent: Agent, failures: list[str]) -> None:
    if agent.custom_path_variable is None:
        return
    with tempfile.TemporaryDirectory(prefix=f"cmux-vm-{agent.command}-") as directory:
        fixture = Fixture(Path(directory), agent)
        # The configured path names the shim and PATH does not list its directory.
        result, arguments = fixture.launch(
            **{
                agent.custom_path_variable: str(fixture.version_manager_shim),
                "PATH": fixture.path_without_version_manager(),
            }
        )
        if result.returncode != 0 or fixture.agent_runs() != [arguments]:
            failures.append(
                f"{agent.command}: a configured path that is a version-manager shim did not reach "
                f"the installed agent: runs {fixture.runs()!r}, {describe(result)}"
            )


def check_session_launch_is_prepared_once(agent: Agent, node: str | None, failures: list[str]) -> None:
    """In a cmux terminal the hooks cmux adds reach the installed agent exactly once."""
    with tempfile.TemporaryDirectory(prefix=f"cmux-vm-{agent.command}-") as directory:
        fixture = Fixture(Path(directory), agent, node=node)
        # Bound, never accepted: the Claude wrapper only checks that the socket exists.
        socket_path = fixture.root / "cmux.sock"
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        launch_executable_log = fixture.root / "launch-executable.log"
        environment = fixture.cmux_terminal_environment(socket_path)
        environment["AGENT_LAUNCH_EXECUTABLE_LOG"] = str(launch_executable_log)
        try:
            listener.bind(str(socket_path))
            result = fixture.run(environment, *agent.session_args)
        finally:
            listener.close()

        runs = fixture.agent_runs()
        if result.returncode != 0 or len(runs) != 1:
            failures.append(
                f"{agent.command}: a session launch through a version-manager shim did not start "
                f"the installed agent once: runs {runs!r}, {describe(result)}"
            )
            return
        # cmux resumes a session with the executable captured here. It has to
        # be the agent that ran, not the shim that handed the launch back,
        # which may be gone by then. Pi's extension captures its own.
        launch_executable = launch_executable_log.read_text(encoding="utf-8").strip()
        if agent.command != "pi" and launch_executable != str(fixture.installed_agent):
            failures.append(
                f"{agent.command}: the captured launch executable is {launch_executable!r}, "
                f"expected the installed agent {str(fixture.installed_agent)!r}"
            )
        arguments = runs[0]
        if arguments[-len(agent.session_args):] != list(agent.session_args):
            failures.append(f"{agent.command}: session arguments changed: {arguments!r}")

        calls = fixture.cmux_calls()
        if agent.command == "codex":
            if arguments.count(CODEX_INJECTED_ARG) != 1 or calls.count("hooks codex inject-args") != 1:
                failures.append(f"codex: hook arguments were not added once: {arguments!r}, cmux calls {calls!r}")
        elif agent.command == "claude":
            if (
                arguments.count("--settings") != 1
                or arguments.count("--session-id") != 1
                or calls.count(agent.preparation_call) != 1
            ):
                failures.append(
                    f"claude: session id and hook settings were not added once: {arguments!r}, cmux calls {calls!r}"
                )
        elif agent.command == "pi":
            if arguments.count("-e") != 1:
                failures.append(f"pi: the cmux extension was not added once: {arguments!r}")
        elif agent.command == "amp":
            if calls.count("hooks amp install --yes") != 1:
                failures.append(f"amp: the hook installer did not run once: {calls!r}")
        elif agent.command == "hermes":
            if calls.count("hooks hermes-agent install --yes") != 1:
                failures.append(f"hermes: the hook installer did not run once: {calls!r}")


def check_hand_back_to_an_orphaned_launch_is_prepared_once(agent: Agent, node: str | None, failures: list[str]) -> None:
    """A launch whose parent exits while the version manager has it is still one launch."""
    with tempfile.TemporaryDirectory(prefix=f"cmux-vm-{agent.command}-") as directory:
        fixture = Fixture(Path(directory), agent, node=node)
        launcher = fixture.root / "orphaning-launcher"
        write_executable(launcher, ORPHANING_LAUNCHER)
        fifo = fixture.root / "version-manager-reached.fifo"
        os.mkfifo(fifo)
        socket_path = fixture.root / "cmux.sock"
        environment = fixture.cmux_terminal_environment(socket_path)
        environment["ORPHAN_FIFO"] = str(fifo)
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            listener.bind(str(socket_path))
            # Returns once the orphaned launch has closed the output pipes too.
            result = subprocess.run(
                [str(launcher), str(fixture.cmux_shim), *agent.session_args],
                env=environment,
                cwd=fixture.root,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=120,
                check=False,
            )
        finally:
            listener.close()

        runs = fixture.agent_runs()
        prepared = fixture.cmux_calls().count(agent.preparation_call)
        if len(runs) != 1 or prepared != 1 or len(fixture.version_manager_shim_pids()) != 1:
            failures.append(
                f"{agent.command}: a launch orphaned during the hand-back was not prepared and started "
                f"once: prepared {prepared}, shim passes {len(fixture.version_manager_shim_pids())}, "
                f"runs {runs!r}, {describe(result)}"
            )


def check_claude_loop_guard_survives_a_fallback(failures: list[str]) -> None:
    """A second shim that runs `claude` by name still ends at the wrapper's loop guard.

    Whether that shim replaces itself or starts a child, every pass goes
    through the version manager again, so the fallback must neither reset the
    wrapper's count of shim hops nor put an older count back.
    """
    agent = AGENTS_BY_COMMAND["claude"]
    runaway_exit_code = 96
    for name, run_claude in (("replacing", 'exec claude "$@"'), ("spawning", 'command claude "$@"')):
        with tempfile.TemporaryDirectory(prefix="cmux-vm-claude-") as directory:
            fixture = Fixture(Path(directory), agent)
            second_shim_dir = fixture.root / "second-shim"
            write_executable(
                second_shim_dir / "claude",
                "#!/bin/bash\n"
                'depth="${SECOND_SHIM_DEPTH:-0}"\n'
                f"if (( depth >= 40 )); then exit {runaway_exit_code}; fi\n"
                "export SECOND_SHIM_DEPTH=$((depth + 1))\n"
                f"{run_claude}\n",
            )
            environment = fixture.environment()
            environment["PATH"] = (
                f"{fixture.shim_root}:{fixture.version_manager_dir}:{second_shim_dir}"
                f":{fixture.installed_dir}:/usr/bin:/bin"
            )
            result = fixture.run(environment, "--version")
            if result.returncode != 126 or "possible infinite claude shim loop" not in result.stderr:
                failures.append(
                    f"claude: a {name} shim behind a version-manager shim did not end at the loop guard: "
                    f"{describe(result)[:600]}"
                )
            if fixture.agent_runs():
                failures.append(f"claude: the {name} shim case reached the installed agent: {fixture.runs()!r}")


def check_restart_of_a_selected_version_is_prepared_again(agent: Agent, node: str | None, failures: list[str]) -> None:
    """A tool the version manager did start, restarting itself by name, is a new launch.

    Only a hand-back may reuse the first pass's preparation. Here the process,
    its parent and the arguments are all unchanged; what tells the two apart
    is the PATH the version manager gave the tool.
    """
    with tempfile.TemporaryDirectory(prefix=f"cmux-vm-{agent.command}-") as directory:
        fixture = Fixture(Path(directory), agent, node=node)
        selected_dir = fixture.root / "version-manager" / "installs"
        selected_agent = selected_dir / agent.command
        write_executable(selected_agent, RECORDING_AGENT)
        socket_path = fixture.root / "cmux.sock"
        environment = fixture.cmux_terminal_environment(socket_path)
        environment["VERSION_MANAGER_SELECTED_DIR"] = str(selected_dir)
        environment["AGENT_REPLACES_ITSELF"] = "same-arguments"
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            listener.bind(str(socket_path))
            result = fixture.run(environment, *agent.session_args)
        finally:
            listener.close()
        tools = [run[0] for run in fixture.runs()]
        prepared = fixture.cmux_calls().count(agent.preparation_call)
        if result.returncode != 0 or tools != [str(selected_agent)] * 2 or prepared != 2:
            failures.append(
                f"{agent.command}: a selected version restarting itself was not launched and prepared "
                f"twice: prepared {prepared}, runs {fixture.runs()!r}, {describe(result)}"
            )


def check_native_claude_after_shim_gets_no_node_preload(node: str, failures: list[str]) -> None:
    """The preload cmux adds for a Node claude must not reach a native claude found after the shim."""
    agent = AGENTS_BY_COMMAND["claude"]
    if shutil.which("cc") is None:
        failures.append("claude: cc is required to build the native claude stand-in")
        return
    with tempfile.TemporaryDirectory(prefix="cmux-vm-claude-") as directory:
        fixture = Fixture(Path(directory), agent, agent_installed=False, node=node)
        source = fixture.root / "native-claude.c"
        source.write_text(NATIVE_FAKE_CLAUDE_C, encoding="utf-8")
        compiled = subprocess.run(
            ["cc", "-o", str(fixture.installed_agent), str(source)],
            capture_output=True,
            text=True,
            check=False,
        )
        if compiled.returncode != 0:
            failures.append(f"claude: cc could not build the native claude stand-in: {compiled.stderr}")
            return

        socket_path = fixture.root / "cmux.sock"
        node_options_log = fixture.root / "node-options.log"
        child_node_options_log = fixture.root / "child-node-options.log"
        args_log = fixture.root / "native-args.log"
        environment = fixture.cmux_terminal_environment(socket_path)
        environment.update(
            {
                "FAKE_REAL_NODE_OPTIONS_LOG": str(node_options_log),
                "FAKE_REAL_CHILD_NODE_OPTIONS_LOG": str(child_node_options_log),
                "FAKE_REAL_ARGS_LOG": str(args_log),
            }
        )
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            listener.bind(str(socket_path))
            result = fixture.run(environment, *agent.session_args)
        finally:
            listener.close()

        seen = [
            log.read_text(encoding="utf-8").strip() if log.exists() else "__NOT_RUN__"
            for log in (node_options_log, child_node_options_log)
        ]
        arguments = args_log.read_text(encoding="utf-8").splitlines() if args_log.exists() else []
        if result.returncode != 0 or seen != ["__UNSET__", "__UNSET__"]:
            failures.append(
                f"claude: a native claude after a version-manager shim saw NODE_OPTIONS {seen!r}, "
                f"expected it unset for claude and its child: {describe(result)}"
            )
        if arguments.count("--settings") != 1:
            failures.append(f"claude: native claude after the shim lost its hook settings: {arguments!r}")


def main() -> int:
    failures: list[str] = []
    skipped = ""
    # The Claude wrapper merges its hook settings with Node.
    node = node_executable()
    for agent in AGENTS:
        check_fallback_reaches_installed_agent(agent, failures)
        check_selected_version_still_runs(agent, failures)
        check_missing_agent_is_reported_by_the_shim(agent, failures)
        check_tool_replacing_itself_runs_again(agent, failures)
        check_child_launch_resolves_again(agent, failures)
        check_custom_path_shim_falls_back(agent, failures)
        if agent.command in ("codex", "claude"):
            # The two wrappers whose passthrough clears cmux's variables.
            check_passthrough_after_fallback_keeps_cmux_variables_out(agent, failures)
        if agent.command == "claude" and node is None:
            skipped = " (claude session launch and native claude checks skipped: node not found)"
            continue
        check_session_launch_is_prepared_once(agent, node, failures)
        check_hand_back_to_an_orphaned_launch_is_prepared_once(agent, node, failures)
        check_restart_of_a_selected_version_is_prepared_again(agent, node, failures)
    check_claude_loop_guard_survives_a_fallback(failures)
    if node is not None:
        check_native_claude_after_shim_gets_no_node_preload(node, failures)

    if failures:
        print(f"FAIL: {len(failures)} check(s) failed")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print(f"PASS: {len(AGENTS)} agent wrappers fall back past a version-manager shim{skipped}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
