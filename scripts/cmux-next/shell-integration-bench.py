#!/usr/bin/env python3
"""Shell integration costs nothing per prompt: forks per prompt and first-prompt time.

usage:
  python3 -I scripts/cmux-next/shell-integration-bench.py --app "/path/cmux NIGHTLY.app"
  python3 -I scripts/cmux-next/shell-integration-bench.py            # this checkout (needs ghostty-next)
  options: --shells zsh,bash,fish  --bash /opt/homebrew/bin/bash  --fish /opt/homebrew/bin/fish
           --require zsh,bash (default: the requested zsh and bash; --require= to allow skipping)
           --layouts app,daemon,daemon-bare  --reps 9  --cycles 20  --idle-s 1.2  --max-overhead-ms 15
           --json out.json
  fleet (with the fork guard and bash 5.2; exclusive for the first-prompt times):
    cmux-ci run --class exclusive --measurement --label measure \
      --script scripts/measure/shell-integration.sh --ref SHA

What it runs. Every shell starts the way a cmux-next terminal starts it: a login shell on a pty
(`-zsh`, `-bash --posix`, `-fish`, as the daemon's login(1) start does) with the environment the
app writes (GhosttyShellIntegration.apply, then BundledCLIEnvironment.apply, plus the daemon's
CMUX_TUI_AGENT_SHIMS): Ghostty's integration from ghostty-next under the app's
`<Resources>/cmux-cli-path` layer. Layout `app` is the app's own spawn (the bundle's
`ghostty/shell-integration`); layout `daemon` is a shell the cmux-tui daemon integrates (the same
Ghostty files with cmux-tui's agent shims appended, as shell_integration.rs writes them) under the
same layer, as the daemon wraps it when it knows the app's bundled CLI; layout `daemon-bare` is that
daemon-integrated shell with no layer and no bundled CLI (a daemon started outside the app, or one
whose `<Resources>/cmux-cli-path` is missing: cli_path::wrap then leaves the injection alone). The
daemon layouts rebuild the daemon's scripts from this checkout (daemon_integration reads the file list
and order from shell_integration.rs SCRIPTS, so they cannot drift); the guard on what the daemon really writes is cmux-tui-core's
shell_integration/fork_count_tests.rs, which materializes SCRIPTS and counts the same forks. Each
shell has an empty HOME whose only startup file sets a plain prompt, so the integration is the only
code that differs from the control: the same shell, same flags, without the integration env.
bash also runs with two more HOMEs whose .bashrc sets PROMPT_COMMAND the way prompt tools do, as a
string (`PROMPT_COMMAND='history -a'`) and as an array (`PROMPT_COMMAND=("history -a")`): those are
the branches where Ghostty's and cmux's hooks read PROMPT_COMMAND's type, and where the agent-shim
prompt hook must still run. After the counted cycles each integrated bash run moves PATH's front
(`PATH=/bin:$PATH`) and checks the next command sees the agent shim directory first again.

What it counts. Each run reads the shell's fork count four times: before the shell runs (it
starts behind a gate, a pipe its child reads before execve), at the first prompt, after `--cycles`
prompt cycles, and after `--idle-s` seconds idle at the prompt. On macOS the kernel counts the
forks of the shell alone (a kqueue NOTE_FORK knote on its pid, in place before the gate opens; the
shell's execve, which the knote must report after the gate opens, shows it is on the shell's pid),
so no other process on the host changes the count. That count has two limits. It is the shell's own
forks: a fork inside a subshell (a command substitution's) counts with the subshell, not here. And
the knote is EV_CLEAR, so forks between two reads of the kqueue (the bench reads it whenever it
wakes, the idle window included) merge into one event. A count of 0 is exact (every fork of a
descendant starts with one of the shell); a count above 0 is a lower bound, and the output marks
it ">=" (at least that many, when the control counts 0). Elsewhere a reading is a PID probe
(a forked child that exits at once): PIDs are handed out in sequence, so the gap counts every
process forked in the window, the shell's and the host's, and the minimum over `--reps` runs drops
the host's. A cycle types one command one key at a time (each key waits for its echo), presses
Return and waits for the next prompt, so keystrokes, preexec, precmd and the prompt all fall in
the window. Every other cycle changes directory, between a plain directory and a git repository
(`cd ~/g`, `true`, `cd ~/p`, `true`, ...), so work triggered by a cwd change or a repository is
counted too. The idle window is a fixed measurement window at the prompt (no input), so a timer or
watcher that wakes on its own (a once-a-second poll) forks in it; it hides no work. Integration
cost = min(integrated) minus min(control):
  startup forks   forks from the gate to the first prompt
  forks/cycle     (cycle-window forks) / cycles
  idle forks      forks in the idle window
  first prompt    median time from the gate to the first prompt, and its overhead over control

Pass (exit 0): for every shell that ran, startup forks <= 0, cycle-window forks <= budget x cycles
(no tolerance: the minimum over reps already drops host noise, so any extra fork is the shell's),
idle forks <= 0, the first-prompt overhead <= --max-overhead-ms, each integrated run wrote its
prompt marks (OSC 133;C per command; the OSC 2 title `true` for zsh and bash) with no shell error,
and every integrated bash run put the agent shim directory back in front. Budgets are 0 except
bash 4.4-5.2, where Ghostty runs its preexec hook from PS0 in a command substitution (the
only pre-command hook bash has before 5.3): 1 fork of the shell per command, whose subshell forks
once more for the history read (BASH_PS0_FORKS: 1 counted by the kernel, 2 in the PID gap). On
macOS that budget check is partial, and the result says so ("partial"): the kernel's count misses
every fork inside the PS0 subshell (an added `$(...)` or external command in __ghostty_preexec or
a hook it runs adds nothing there), and a merged event can hide a fork of the shell. The complete
bash 4.4-5.2 verdict is the PID gap (Linux; cmux-tui-core's fork-count test with bash 5.2, budget
2). The budget-0 checks (zsh, fish, bash 5.3, every startup and idle window) are exact on macOS
when the control counts 0. Exit 1 on a failure, 2 when no
shell could run or a `--require`d shell is missing (zsh and bash are required by default, so a host
with only Apple's /bin/bash 3.2, which Ghostty does not integrate, fails instead of skipping bash).
Noise (PID gap only): host spawns only make a count larger. An inflated integrated count shows a
fork that is not there (rerun). An inflated control minimum would understate the integration's
forks, so a result also fails when the control minimum is reached in fewer than max(2, reps/3)
reps: a baseline that only one rep hit is not the shell's own count. Rerun on an idle host when
that happens. The kernel's count (macOS) does not depend on other processes on the host.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import pty
import re
import select
import shutil
import signal
import statistics
import struct
import subprocess
import sys
import tempfile
import termios
import time
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SHIMS_SRC = ROOT / "cmux-tui/crates/cmux-tui-core/src/shell_integration"
SCRIPTS_RS = ROOT / "cmux-tui/crates/cmux-tui-core/src/shell_integration.rs"
GHOSTTY_NEXT_INTEGRATION = ROOT / "ghostty-next/src/shell-integration"
PROMPT = b"@@P@@ "
BARRIER = b"^"
KILL_LINE = b"\x15"
# The commands of the cycles, in turn: half change directory (a git repository, a plain one).
COMMANDS = (b"cd ~/g", b"true", b"cd ~/p", b"true")
ERRORS = (b"bad substitution", b"command not found", b"parse error", b"syntax error",
          b"fork failed", b"nknown command")
# Primary Device Attributes: what a shell asks (fish 4 at startup), and Ghostty's answer.
DA1_QUERIES = (b"\x1b[c", b"\x1b[0c")
DA1_REPLY = b"\x1b[?62;22c"
GHOSTTY_FEATURES = "cursor:blink,path,title"
DEFAULT_XDG = "/usr/local/share:/usr/share"
SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
# macOS: the kernel counts the shell's own forks (kqueue NOTE_FORK); elsewhere the PID gap.
KERNEL_COUNT = sys.platform == "darwin"
# Forks a reading adds to the next window (a PID probe is a process), and forks the shell itself
# adds to the startup window (its own spawn shows in the PID gap).
READ_COST = 0 if KERNEL_COUNT else 1
SPAWN_COST = 0 if KERNEL_COUNT else 1
# Ghostty's PS0 hook on bash 4.4-5.2, per command: its command substitution, and the history read
# that subshell forks (the kernel's count sees only the shell's own fork).
BASH_PS0_FORKS = 1 if KERNEL_COUNT else 2


class BenchError(Exception):
    pass


class PidWrapped(Exception):
    """The PID counter wrapped inside the run: its fork counts mean nothing."""


@dataclass
class Layout:
    """Where one spawn path finds its scripts."""
    name: str
    integration: Path  # Ghostty's shell-integration dir as the shell sees it
    cli_path: Path | None  # <Resources>/cmux-cli-path; None: no layer, no bundled CLI
    cli: Path | None       # <Resources>/bin/cmux
    ghostty_resources: Path


@dataclass
class Shell:
    name: str
    path: str
    version: str
    argv: list[str]          # control argv; the integrated bash adds --posix
    cycle_budget: int


@dataclass
class Run:
    startup_forks: int
    cycle_forks: int
    idle_forks: int
    first_prompt_ms: float
    output: bytes = field(repr=False, default=b"")
    shims_dir: str = ""


def probe_pid() -> int:
    """The PID of a child forked now: the system's PID counter at this moment."""
    pid = os.fork()
    if pid == 0:
        os._exit(0)
    os.waitpid(pid, 0)
    return pid


class Session:
    """One shell on a pty, driven by what it prints (no timed waits), and its fork count."""

    def __init__(self, path: str, argv: list[str], env: dict[str, str], timeout: float):
        self.timeout = timeout
        self.buf = b""
        self.da1_answered = 0
        self.forks = 0
        self.execs = 0
        self.gate_execs = 0
        self.kq = None
        # The PID counter before the shell (PID gap); the kernel's count starts at 0.
        self.start = 0 if KERNEL_COUNT else probe_pid()
        # The gate: the child waits for a byte before execve, so the count is in place first.
        gate_r, gate_w = os.pipe()
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            try:
                os.close(gate_w)
                os.read(gate_r, 1)
                fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 120, 0, 0))
                os.chdir(env["HOME"])
                os.execve(path, argv, env)
            finally:
                os._exit(127)
        os.close(gate_r)
        try:
            if KERNEL_COUNT:
                self.kq = select.kqueue()
                self.kq.control([select.kevent(self.pid, select.KQ_FILTER_PROC,
                                               select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                                               select.KQ_NOTE_FORK | select.KQ_NOTE_EXEC)], 0)
                # The child has not exec'd yet (it waits on the gate): the shell's execve must
                # come after this.
                self.drain()
                self.gate_execs = self.execs
        except BaseException:
            # Closing the gate unopened gives the child EOF: it exits through os._exit(127)
            # without exec, and is reaped here with its pty, before the error goes on.
            os.close(gate_w)
            if self.kq is not None:
                self.kq.close()
            os.waitpid(self.pid, 0)
            os.close(self.fd)
            raise
        self.started = time.perf_counter()
        os.write(gate_w, b"g")
        os.close(gate_w)

    def drain(self) -> None:
        """Counts the shell's fork and exec events so far (kernel count only)."""
        if self.kq is None:
            return
        while events := self.kq.control(None, 64, 0):
            for event in events:
                self.forks += bool(event.fflags & select.KQ_NOTE_FORK)
                self.execs += bool(event.fflags & select.KQ_NOTE_EXEC)

    def fork_count(self) -> int:
        """The shell's fork count now, every fork before this call included (its knote fires
        inside the fork, before the shell prints what the caller waited for)."""
        if not KERNEL_COUNT:
            return probe_pid()
        self.drain()
        if self.execs <= self.gate_execs:
            raise BenchError("the fork count saw no execve after the gate opened: it does not watch the shell")
        return self.forks

    def wait_for(self, done, what: str) -> None:
        deadline = time.monotonic() + self.timeout
        while not done(self.buf):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise BenchError(f"timed out waiting for {what}; last output: {self.tail()}")
            self.wake(remaining, what)

    def idle(self, seconds: float) -> None:
        """Stays at the prompt for `seconds` with no input (a fixed measurement window), reading
        the shell's output and its fork events as they come, as `wait_for` does."""
        deadline = time.monotonic() + seconds
        while (remaining := deadline - time.monotonic()) > 0:
            self.wake(remaining, "the end of the idle window")

    def wake(self, timeout: float, what: str) -> None:
        """Waits up to `timeout` for output or a fork event and takes what came."""
        # The kqueue too: a fork is read when it fires, so fewer merge with the next.
        watched = [self.fd] if self.kq is None else [self.fd, self.kq.fileno()]
        ready, _, _ = select.select(watched, [], [], timeout)
        self.drain()
        if self.fd not in ready:
            return
        try:
            data = os.read(self.fd, 65536)
        except OSError:
            data = b""
        if not data:
            raise BenchError(f"shell exited while waiting for {what}; last output: {self.tail()}")
        self.buf += data
        self.answer_device_attributes()

    def answer_device_attributes(self) -> None:
        """Answers each Primary Device Attributes query (CSI c) as Ghostty does.

        fish 4 asks at startup and waits up to 10 s for the answer, so a pty with no terminal
        behind it would add 10 s to every fish start (and to its first-prompt time)."""
        queries = sum(self.buf.count(query) for query in DA1_QUERIES)
        if queries > self.da1_answered:
            os.write(self.fd, DA1_REPLY * (queries - self.da1_answered))
            self.da1_answered = queries

    def tail(self) -> str:
        return self.buf[-600:].decode("utf-8", "replace").encode("unicode_escape").decode()

    def prompts(self) -> int:
        return self.buf.count(PROMPT)

    def type_key(self, key: bytes) -> None:
        mark = len(self.buf)
        os.write(self.fd, key)
        self.wait_for(lambda b: key in b[mark:], f"the echo of {key!r}")

    def barrier(self) -> None:
        """Returns once the line editor reads keys again: every prompt hook has run."""
        self.type_key(BARRIER)
        os.write(self.fd, KILL_LINE)

    def cycle(self, command: bytes) -> None:
        for key in command:
            self.type_key(bytes([key]))
        seen = self.prompts()
        os.write(self.fd, b"\r")
        self.wait_for(lambda b: b.count(PROMPT) > seen, "the next prompt")

    def close(self) -> None:
        try:
            os.write(self.fd, KILL_LINE + b"exit\r")
            self.wait_for(lambda b: False, "exit")
        except (BenchError, OSError):
            pass
        try:
            pid, _ = os.waitpid(self.pid, os.WNOHANG)
            if pid == 0:
                os.kill(self.pid, signal.SIGKILL)
                os.waitpid(self.pid, 0)
        except ChildProcessError:
            pass
        os.close(self.fd)
        if self.kq is not None:
            self.kq.close()


SHIM_PROBE = b"@@F@@"


def run_once(shell: Shell, argv: list[str], env: dict[str, str], cycles: int, idle_s: float,
             timeout: float, check_shims: bool = False) -> Run:
    session = Session(shell.path, argv, env, timeout)
    try:
        session.wait_for(lambda b: PROMPT in b, "the first prompt")
        first_prompt_ms = (time.perf_counter() - session.started) * 1000
        session.barrier()
        at_prompt = session.fork_count()
        for index in range(cycles):
            session.cycle(COMMANDS[index % len(COMMANDS)])
        session.barrier()
        after = session.fork_count()
        # A fixed measurement window at the prompt, not a wait for the shell: whatever the
        # integration starts on its own (a timer, a watcher) forks in it.
        session.idle(idle_s)
        idle_after = session.fork_count()
        if check_shims:
            # Outside the counted window. The agent shim hook runs at each prompt
            # (bash), so the command after the one that moves PATH's front sees
            # the shim directory first again.
            for line in (b"PATH=/bin:$PATH", b'echo "' + SHIM_PROBE + b'${PATH%%:*}' + SHIM_PROBE + b'"'):
                seen = session.prompts()
                os.write(session.fd, line + b"\r")
                session.wait_for(lambda b, seen=seen: b.count(PROMPT) > seen, "the prompt after a shim check")
    finally:
        session.close()
    # Each window excludes the reading that closes it; the startup one, in the PID gap, also
    # holds the shell itself.
    windows = (at_prompt - session.start - SPAWN_COST - READ_COST, after - at_prompt - READ_COST,
               idle_after - after - READ_COST)
    if min(windows) < 0:
        raise PidWrapped()
    return Run(*windows, first_prompt_ms, session.buf)


# The startup PROMPT_COMMAND of each bash HOME: none, a string, an array.
BASH_HOMES = {"plain": "", "pc-string": "PROMPT_COMMAND='history -a'\n",
              "pc-array": "PROMPT_COMMAND=(history\\ -a)\n"}


def write_home(home: Path, bash_extra: str = "") -> None:
    """A HOME whose startup files only set a prompt the bench can find (and, for
    bash, `bash_extra`), with the cycles' directories: `p` (plain) and `g` (a git repository,
    made without running git)."""
    home.mkdir(parents=True, exist_ok=True)
    (home / "p").mkdir(exist_ok=True)
    for sub in ("objects", "refs/heads"):
        (home / "g/.git" / sub).mkdir(parents=True, exist_ok=True)
    (home / "g/.git/HEAD").write_text("ref: refs/heads/main\n")
    prompt = PROMPT.decode()
    # An existing .zshrc also keeps zsh-newuser-install from asking questions.
    (home / ".zshrc").write_text(f"PS1='{prompt}'\nSAVEHIST=0\n")
    # A login bash reads .bash_profile; the common one sources .bashrc.
    (home / ".bash_profile").write_text('[ -r "$HOME/.bashrc" ] && . "$HOME/.bashrc"\n')
    (home / ".bashrc").write_text(f"PS1='{prompt}'\n{bash_extra}")
    fish = home / ".config/fish"
    fish.mkdir(parents=True, exist_ok=True)
    # fish starts its man-page completion generator in the background until this exists.
    (home / ".local/share/fish/generated_completions").mkdir(parents=True, exist_ok=True)
    (fish / "config.fish").write_text(
        "set -g fish_greeting ''\n"
        "set -g fish_autosuggestion_enabled 0\n"
        f"function fish_prompt; printf '%s' '{prompt}'; end\n"
        "function fish_right_prompt; end\n"
    )


def base_env(home: Path, shell: Shell) -> dict[str, str]:
    env = {
        "HOME": str(home),
        "USER": os.environ.get("USER", "bench"),
        "LOGNAME": os.environ.get("LOGNAME", os.environ.get("USER", "bench")),
        "PATH": SYSTEM_PATH,
        "SHELL": shell.path,
        "TERM": "xterm-256color",
        "LANG": "en_US.UTF-8",
    }
    if "TMPDIR" in os.environ:
        env["TMPDIR"] = os.environ["TMPDIR"]
    return env


def integrated_env(base: dict[str, str], shell: Shell, layout: Layout, shims: Path) -> dict[str, str]:
    """GhosttyShellIntegration.apply, then BundledCLIEnvironment.apply (the daemon's
    cli_path::wrap writes the same; neither for a layout without a layer), plus the daemon's
    agent shim directory."""
    env = dict(base)
    env["GHOSTTY_RESOURCES_DIR"] = str(layout.ghostty_resources)
    env["XDG_DATA_DIRS"] = f"{DEFAULT_XDG}:{layout.ghostty_resources}/.."
    env["GHOSTTY_SHELL_FEATURES"] = GHOSTTY_FEATURES
    integration = str(layout.integration)
    if shell.name == "zsh":
        env["ZDOTDIR"] = integration + "/zsh"
    elif shell.name == "bash":
        env["ENV"] = integration + "/bash/ghostty.bash"
        env["GHOSTTY_BASH_INJECT"] = "1"
        env["HISTFILE"] = base["HOME"] + "/.bash_history"
        env["GHOSTTY_BASH_UNEXPORT_HISTFILE"] = "1"
    elif shell.name == "fish":
        env["GHOSTTY_SHELL_INTEGRATION_XDG_DIR"] = integration
        env["XDG_DATA_DIRS"] = integration + ":" + env["XDG_DATA_DIRS"]
    env["CMUX_TUI_AGENT_SHIMS"] = str(shims)
    if layout.cli_path is None or layout.cli is None:
        env["PATH"] = f"{shims}:{SYSTEM_PATH}"
        return env
    env["PATH"] = f"{shims}:{layout.cli.parent}:{SYSTEM_PATH}"
    env["CMUX_BUNDLED_CLI_PATH"] = str(layout.cli)
    layer = str(layout.cli_path)
    if shell.name == "zsh":
        env["CMUX_CLI_ZSH_ZDOTDIR"] = env["ZDOTDIR"]
        env["ZDOTDIR"] = layer + "/zsh"
    elif shell.name == "bash":
        env["CMUX_CLI_BASH_ENV"] = env["ENV"]
        env["ENV"] = layer + "/bash/cmux-cli-path.bash"
    elif shell.name == "fish":
        env["CMUX_CLI_FISH_XDG_DIR"] = layer
        env["XDG_DATA_DIRS"] = layer + ":" + env["XDG_DATA_DIRS"]
    return env


def scripts_rs_entries() -> dict[str, list[Path]]:
    """shell_integration.rs SCRIPTS: each script's path and the files it concatenates, in order,
    as checkout paths (the daemon embeds them with include_str!)."""
    source = SCRIPTS_RS.read_text()
    match = re.search(r"const SCRIPTS: &\[Script\] = &\[(.*?)\n\];", source, re.S)
    if not match:
        raise BenchError(f"no `const SCRIPTS` array in {SCRIPTS_RS}")
    scripts: dict[str, list[Path]] = {}
    for block in match.group(1).split("Script {")[1:]:
        path = re.search(r'path:\s*"([^"]+)"', block)
        parts = re.findall(r'include_str!\(\s*"([^"]+)"\s*,?\s*\)', block)
        if not path or not parts:
            raise BenchError(f"cannot read a SCRIPTS entry in {SCRIPTS_RS}: {block.strip()[:120]}")
        scripts[path.group(1)] = [Path(os.path.normpath(SCRIPTS_RS.parent / part)) for part in parts]
    if not scripts:
        raise BenchError(f"SCRIPTS in {SCRIPTS_RS} is empty")
    return scripts


def daemon_integration(ghostty: Path, dest: Path) -> Path:
    """The scripts the cmux-tui daemon materializes, rebuilt from this checkout's SCRIPTS, with
    ghostty-next's files taken from `ghostty` (ghostty-next itself, or an app bundle's copy)."""
    for rel, parts in scripts_rs_entries().items():
        target = dest / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        text = []
        for part in parts:
            if part.is_relative_to(GHOSTTY_NEXT_INTEGRATION):
                part = ghostty / part.relative_to(GHOSTTY_NEXT_INTEGRATION)
            if not part.is_file():
                raise BenchError(f"{rel}: {part} (from shell_integration.rs SCRIPTS) is missing")
            text.append(part.read_text())
        target.write_text("".join(text))
    return dest


def source_resources(ghostty_integration: Path, dest: Path) -> Path:
    """A Contents/Resources made of this checkout's files, as bundle-ghostty-resources.sh lays them out."""
    resources = dest / "cmux DEV bench.app/Contents/Resources"
    (resources / "ghostty").mkdir(parents=True)
    (resources / "bin").mkdir()
    (resources / "ghostty/shell-integration").symlink_to(ghostty_integration)
    (resources / "cmux-cli-path").symlink_to(ROOT / "Resources/cmux-cli-path")
    cli = resources / "bin/cmux"
    cli.write_text("#!/bin/sh\nexit 0\n")
    cli.chmod(0o755)
    return resources


def version_of(path: str, name: str) -> str:
    if name == "bash":
        script = 'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"'
        return subprocess.run([path, "-c", script], capture_output=True, text=True, timeout=10).stdout.strip()
    out = subprocess.run([path, "--version"], capture_output=True, text=True, timeout=10).stdout
    match = re.search(r"(\d+)\.(\d+)(?:\.(\d+))?", out)
    return match.group(0) if match else "?"


def find_shells(names: list[str], bash_path: str | None,
                fish_path: str | None) -> tuple[list[Shell], dict[str, str]]:
    shells: list[Shell] = []
    skipped: dict[str, str] = {}
    for name in names:
        if name == "bash" and bash_path:
            candidates = [bash_path]
        elif name == "bash":
            candidates = ["/opt/homebrew/bin/bash", "/usr/local/bin/bash", shutil.which("bash") or ""]
        elif name == "fish" and fish_path:
            candidates = [fish_path]
        elif name == "fish":
            candidates = [shutil.which("fish") or "", "/opt/homebrew/bin/fish", "/usr/local/bin/fish"]
        else:
            candidates = ["/bin/zsh", shutil.which("zsh") or ""]
        path = next((c for c in candidates if c and os.access(c, os.X_OK)), None)
        if not path:
            skipped[name] = "not installed"
            continue
        if name == "bash" and sys.platform == "darwin" and path == "/bin/bash":
            skipped[name] = "only Apple's /bin/bash 3.2, which Ghostty does not integrate (pass --bash)"
            continue
        version = version_of(path, name)
        budget = 0
        if name == "bash":
            major, minor = (int(part) for part in (version.split(".") + ["0"])[:2])
            if (major, minor) < (4, 4):
                skipped[name] = f"bash {version}: older than 4.4"
                continue
            if (major, minor) < (5, 3):
                budget = BASH_PS0_FORKS
        login = "-" + os.path.basename(path)
        shells.append(Shell(name, path, version, [login], budget))
    return shells, skipped


def check_output(shell: Shell, run: Run, cycles: int) -> list[str]:
    problems = []
    for error in ERRORS:
        if error in run.output:
            index = run.output.index(error)
            context = run.output[max(0, index - 120):index + 60].decode("utf-8", "replace")
            problems.append(f"shell error {error.decode()!r}: {context.encode('unicode_escape').decode()}")
    marks = run.output.count(b"\x1b]133;C")
    if marks < cycles:
        problems.append(f"{marks} OSC 133;C marks for {cycles} commands (preexec did not run)")
    if shell.name in ("zsh", "bash") and b"\x1b]2;true\x07" not in run.output:
        problems.append("no OSC 2 title for the command (preexec title did not run)")
    if shell.name == "bash":
        front = shim_check_front(run)
        if front is None:
            problems.append("no shim check output")
        elif front != run.shims_dir:
            problems.append(f"after PATH=/bin:$PATH the next command saw {front!r} first, not the agent "
                            "shim directory (the agent-shim prompt hook did not run)")
    return problems


def shim_check_front(run: Run) -> str | None:
    """The PATH front the shim check printed (the expanded echo, not the typed line)."""
    match = re.search(re.escape(SHIM_PROBE) + rb"(/[^@\r\n]*)" + re.escape(SHIM_PROBE), run.output)
    return match.group(1).decode() if match else None


def stable_min(values: list[int], what: str, problems: list[str]) -> int:
    """The minimum, with a problem when too few reps reach it to call it the baseline."""
    low = min(values)
    hits = values.count(low)
    if hits < min(len(values), max(2, len(values) // 3)):
        problems.append(f"control {what} baseline unstable ({low} in {hits} of {len(values)} reps): host "
                        "noise may hide integration forks; rerun on an idle host")
    return low


def measure(shell: Shell, layout: Layout, home: Path, home_name: str, shims: Path, args) -> dict:
    control_env = base_env(home, shell)
    integrated = integrated_env(control_env, shell, layout, shims)
    integrated_argv = shell.argv + (["--posix"] if shell.name == "bash" else [])
    runs: dict[str, list[Run]] = {"control": [], "integrated": []}
    problems: list[str] = []
    for rep in range(args.warmup + args.reps):
        order = [("control", shell.argv, control_env), ("integrated", integrated_argv, integrated)]
        if rep % 2:
            order.reverse()
        for variant, argv, env in order:
            for attempt in range(3):
                try:
                    run = run_once(shell, argv, env, args.cycles, args.idle_s, args.timeout,
                                   check_shims=variant == "integrated" and shell.name == "bash")
                    run.shims_dir = str(shims)
                    break
                except PidWrapped:
                    if attempt == 2:
                        raise BenchError("the PID counter wrapped in three runs in a row")
            if variant == "integrated":
                problems += [p for p in check_output(shell, run, args.cycles) if p not in problems]
            if rep >= args.warmup:
                runs[variant].append(run)
    control, integ = runs["control"], runs["integrated"]
    control_startup = stable_min([r.startup_forks for r in control], "startup", problems)
    control_cycle = stable_min([r.cycle_forks for r in control], "cycle", problems)
    control_idle = stable_min([r.idle_forks for r in control], "idle", problems)
    startup = min(r.startup_forks for r in integ) - control_startup
    cycle_total = min(r.cycle_forks for r in integ) - control_cycle
    idle = min(r.idle_forks for r in integ) - control_idle
    per_cycle = cycle_total / args.cycles
    first_control = statistics.median(r.first_prompt_ms for r in control)
    first_integrated = statistics.median(r.first_prompt_ms for r in integ)
    overhead = first_integrated - first_control
    if startup > 0:
        problems.append(f"{startup} fork(s) from the spawn to the first prompt (budget 0)")
    if cycle_total > shell.cycle_budget * args.cycles:
        problems.append(f"{cycle_total} forks in {args.cycles} prompt cycles ({per_cycle:.2f} per cycle, "
                        f"budget {shell.cycle_budget})")
    if idle > 0:
        problems.append(f"{idle} fork(s) in {args.idle_s:g} s idle at the prompt (budget 0)")
    if overhead > args.max_overhead_ms:
        problems.append(f"first prompt {overhead:.1f} ms slower than without the integration "
                        f"(budget {args.max_overhead_ms:g} ms)")
    # A kernel count above 0 is a lower bound (merged events, no forks inside a subshell).
    lower_bound = KERNEL_COUNT and max(startup, cycle_total, idle) > 0
    return {
        "shell": shell.name, "path": shell.path, "version": shell.version, "layout": layout.name,
        "home": home_name, "startup_forks": startup, "forks_per_cycle": round(per_cycle, 2),
        "cycle_forks": cycle_total, "idle_forks": idle, "idle_s": args.idle_s,
        "cycle_budget": shell.cycle_budget,
        "control_startup_forks_min": control_startup,
        "integrated_startup_forks_min": min(r.startup_forks for r in integ),
        "control_cycle_forks_min": control_cycle,
        "control_idle_forks_min": control_idle,
        "first_prompt_ms": {"control": round(first_control, 1), "integrated": round(first_integrated, 1),
                            "overhead": round(overhead, 1),
                            "integrated_max": round(max(r.first_prompt_ms for r in integ), 1)},
        "counts_are_lower_bounds": lower_bound,
        "complete": not (KERNEL_COUNT and shell.cycle_budget > 0),
        "pass": not problems, "problems": problems,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--app", type=Path, help="a built cmux-next .app (default: this checkout's files)")
    parser.add_argument("--ghostty-integration", type=Path,
                        help="Ghostty's shell-integration dir (default: ghostty-next/src/shell-integration)")
    parser.add_argument("--shells", default="zsh,bash,fish")
    parser.add_argument("--require", default=None,
                        help="shells that must run (default: zsh and bash when requested; --require= for none)")
    parser.add_argument("--bash", help="the bash to run (default: Homebrew's, else PATH's)")
    parser.add_argument("--fish", help="the fish to run (default: PATH's, else Homebrew's)")
    parser.add_argument("--layouts", default="app,daemon,daemon-bare")
    parser.add_argument("--reps", type=int, default=9)
    parser.add_argument("--warmup", type=int, default=1)
    parser.add_argument("--cycles", type=int, default=20)
    parser.add_argument("--idle-s", type=float, default=1.2,
                        help="seconds idle at the prompt after the cycles (a 1 Hz poll forks in it)")
    parser.add_argument("--max-overhead-ms", type=float, default=15.0)
    parser.add_argument("--timeout", type=float, default=20.0, help="seconds per wait for the shell")
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()

    tmp = Path(tempfile.mkdtemp(prefix="cmux-shell-bench-"))
    try:
        if args.app:
            resources = args.app / "Contents/Resources"
        else:
            ghostty = args.ghostty_integration or ROOT / "ghostty-next/src/shell-integration"
            if not (ghostty / "zsh/ghostty-integration").is_file():
                print(f"error: no Ghostty shell integration at {ghostty} "
                      "(git submodule update --init ghostty-next, or pass --ghostty-integration/--app)",
                      file=sys.stderr)
                return 2
            resources = source_resources(ghostty.resolve(), tmp / "src")
        app_integration = resources / "ghostty/shell-integration"
        for needed in (app_integration / "zsh/ghostty-integration", resources / "cmux-cli-path/zsh/.zshenv",
                       resources / "bin/cmux"):
            if not needed.exists():
                print(f"error: {needed} is missing", file=sys.stderr)
                return 2
        # The daemon embeds ghostty-next's files (shell_integration.rs SCRIPTS); with --app and
        # no ghostty-next checkout, the bundle's copy of them.
        ghostty_source = args.ghostty_integration or GHOSTTY_NEXT_INTEGRATION
        if not (ghostty_source / "bash/ghostty.bash").is_file():
            ghostty_source = app_integration
        ghostty_source = ghostty_source.resolve()
        layouts = []
        daemon_scripts = None
        for name in args.layouts.split(","):
            layer, cli = resources / "cmux-cli-path", resources / "bin/cmux"
            if name == "app":
                integration = app_integration
            elif name in ("daemon", "daemon-bare"):
                if not (SHIMS_SRC / "agent-shims.bash").is_file():
                    print(f"note: no cmux-tui agent shims at {SHIMS_SRC}; {name} layout skipped")
                    continue
                if daemon_scripts is None:
                    try:
                        daemon_scripts = daemon_integration(ghostty_source, tmp / "daemon-integration")
                    except BenchError as error:
                        print(f"error: {error}", file=sys.stderr)
                        return 2
                integration = daemon_scripts
                if name == "daemon-bare":
                    layer = cli = None
            else:
                print(f"error: unknown layout {name}", file=sys.stderr)
                return 2
            layouts.append(Layout(name, integration, layer, cli, resources / "ghostty"))
        if args.app and (resources / "shell-integration").exists():
            print(f"note: {resources / 'shell-integration'} (the classic cmux integration) is in the bundle; "
                  "cmux-next injects only ghostty/shell-integration and cmux-cli-path")

        shims = tmp / "agent-shims"
        shims.mkdir()
        (shims / "codex").write_text("#!/bin/sh\nexit 0\n")
        (shims / "codex").chmod(0o755)

        names = [n for n in args.shells.split(",") if n]
        shells, skipped = find_shells(names, args.bash, args.fish)
        for name, why in skipped.items():
            print(f"SKIP {name}: {why}")
        required = ([n for n in names if n in ("zsh", "bash")] if args.require is None
                    else [n for n in args.require.split(",") if n])
        missing = [n for n in required if n in skipped]
        if not shells:
            print("FAIL: no shell could run", file=sys.stderr)
            return 2
        if missing:
            # Before measuring: a host without a bash Ghostty integrates cannot pass.
            print(f"FAIL: required shell(s) did not run: {', '.join(missing)} "
                  "(install one or pass --require= to allow it)", file=sys.stderr)
            return 2

        results = []
        for shell in shells:
            homes = BASH_HOMES if shell.name == "bash" else {"plain": ""}
            for home_name, bash_extra in homes.items():
                home = tmp / f"home-{shell.name}-{home_name}"
                write_home(home, bash_extra)
                for layout in layouts:
                    try:
                        results.append(measure(shell, layout, home, home_name, shims, args))
                    except BenchError as error:
                        results.append({"shell": shell.name, "path": shell.path, "version": shell.version,
                                        "layout": layout.name, "home": home_name, "pass": False,
                                        "problems": [str(error)]})

        method = "kernel count of the shell's own forks" if KERNEL_COUNT else "PID gap"
        print(f"\nhost: {os.uname().nodename} {sys.platform} {os.uname().release}; forks: {method}; "
              f"reps {args.reps} (min forks, median time), cycles {args.cycles}, idle {args.idle_s:g} s")
        print(f"{'shell':<16} {'layout':<11} {'home':<9} {'startup forks':>13} {'forks/cycle':>11} "
              f"{'idle forks':>10} {'first prompt ms (ctrl/int/+)':>30}  result")
        for r in results:
            label = f"{r['shell']} {r['version']}"
            if "first_prompt_ms" in r:
                fp = r["first_prompt_ms"]
                times = f"{fp['control']:.1f} / {fp['integrated']:.1f} / {fp['overhead']:+.1f}"
                # ">=": a kernel count above 0 (a lower bound).
                bound = ">=" if KERNEL_COUNT else ""
                startup = f"{bound if r['startup_forks'] > 0 else ''}{r['startup_forks']}"
                per_cycle = f"{bound if r['cycle_forks'] > 0 else ''}{r['forks_per_cycle']:.2f}"
                idle = f"{bound if r['idle_forks'] > 0 else ''}{r['idle_forks']}"
                verdict = "PASS" if r["pass"] else "FAIL"
                if not r["complete"]:
                    verdict += " (partial: the kernel count misses forks inside the PS0 subshell)"
                print(f"{label:<16} {r['layout']:<11} {r['home']:<9} {startup:>13} "
                      f"{per_cycle:>11} {idle:>10} {times:>30}  {verdict}")
            else:
                print(f"{label:<16} {r['layout']:<11} {r['home']:<9} {'-':>13} {'-':>11} {'-':>10} {'-':>30}  FAIL")
            for problem in r["problems"]:
                print(f"    {problem}")
        if args.json:
            args.json.write_text(json.dumps({"results": results, "skipped": skipped}, indent=2) + "\n")
        return 0 if all(r["pass"] for r in results) else 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
