# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Manaflow, Inc.
"""cmux Computer Use as an AgentEnv computer driver, for an X11 desktop on Linux (amd64), with macOS laid out.

Agents get what cmux's own Computer Use MCP server, ``cmux computer-use mcp --primary``, serves at the pinned cmux
build (``mcp.json``): its instructions and its 17 tools (list_windows, get_ui_tree, screenshot, click, type_text,
press_key, scroll, set_value, perform_action, drag, wait, batch, launch_app and the rest), each call forwarded to a
server of the caller's own, kept for that caller's MCP session, since cmux keeps a Computer Use session's approvals
and its agent cursor per server. The server reaches the cmux daemon, which runs on the computer as a service this file
starts when run as a script: once X answers, ``cmux daemon ensure`` with ``CMUX_CU_HEADLESS=0``, so cmux treats the
display as one a person may be watching (the bench's background condition puts a user there) and never takes the
headless shortcut of XTest input, which moves the real pointer and focus. The daemon starts the Computer Use worker
in the session, as it does on a person's desktop, with cmux's shipped policy (Full access, the default deny list,
foreground input off, pause on takeover, the agent cursor drawn).

The computer/v1 operations (``computer_*``, ``computer-ready``, recording, gate 3's probe) are ``X11Driver``'s: mss
captures the screen and XTEST sends the input, from the driver's own process, as the reference driver and
agent-desktop's Linux driver do. They never go through cmux, so the framework's own input can't be mistaken for the
agent's.

On macOS (arm64, a VM bundle such as ``macos-26``) the layout is in place but unverified: the cmux CLI and the signed
cmux Remote (dev).app, which holds the TCC grants (Accessibility, Post Event, Screen Recording) and runs the worker,
and ``MacOSDriver`` for the computer/v1 operations. See README.md.

It needs ``agentenv-framework-protocol[computer,x11]`` on Linux, ``[computer,macos]`` on macOS, and the cmux binary
the install unpacks into ``bin/``."""
from __future__ import annotations

import asyncio
import contextlib
import functools
import hashlib
import json
import os
import re
import select
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, AsyncIterator, Callable

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from mcp.shared.exceptions import McpError
from mcp.types import CallToolResult, InitializeResult, TextContent

from agentenv_protocol import ForwardedTool, ToolContext, computer, server_instructions
from agentenv_protocol.computer import ReadyCheck, computer_driver

MACOS = sys.platform == "darwin"
OSDriver = computer.MacOSDriver if MACOS else computer.X11Driver

HERE = Path(__file__).resolve().parent
#: cmux's executable: on Linux the one install.sh unpacks beside this file; on macOS the CLI the install links.
EXECUTABLE = Path("/usr/local/bin/cmux") if MACOS else HERE / "bin" / "cmux"
#: The sha256 of the pinned cmux executable for each platform: cmux-tui at the commit README.md names, built on rbx
#: with ``--portable`` (``CMUX_GHOSTTY_VT_ZIG_CPU=baseline``). macOS has no pin yet.
EXECUTABLES = {
    "linux/amd64": "2bfd61db56ac755470269b743b05a8f2e7c24866e75a4f2ae93caf0d31f9ad32",
}
#: What ``cmux computer-use mcp --primary`` says at connect and lists at the pinned build.
MANIFEST = HERE / "mcp.json"
#: Whether a person may be watching the display, which the worker reads: 0, so background input never moves the real
#: pointer or focus.
ATTENDED = {"CMUX_CU_HEADLESS": "0"}
#: What of the driver's environment cmux gets: the session user's own and the session's display and bus, never a
#: deploy's values.
KEPT = ("HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "TMPDIR", "DISPLAY", "XAUTHORITY", "XDG_RUNTIME_DIR",
        "XDG_SESSION_TYPE", "XDG_CURRENT_DESKTOP", "DBUS_SESSION_BUS_ADDRESS", "CMUX_TUI_STATE_DIR")
PATH = "/usr/bin:/bin:/usr/sbin:/sbin" if MACOS else "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
#: The label the person sees on the agent's cursor, and the prefix of each caller's Computer Use session.
LABEL, SESSION_PREFIX = "AgentEnv agent", "agentenv"
#: How long a caller's server is kept unused before it's closed, since nothing says when an MCP session ends; how
#: many are kept at most, the least recently used closed first; how often idle ones are looked for; and how long a
#: closed one has to end.
IDLE_S, MAX_SERVERS, SWEEP_S, CLOSE_TIMEOUT_S = 1800, 8, 60, 10
#: How long a ``cmux daemon`` command has to finish.
DAEMON_TIMEOUT_S = 60
#: The MCP error code for a server whose connection closed.
CONNECTION_CLOSED = -32000


@computer_driver(name="cmux",
                 supports=[{"os": {"type": "linux", "display": ["x11"]}, "arch": ["amd64"]},
                           {"os": {"type": "macos", "display": ["aqua"]}, "arch": ["arm64"]}])
class CmuxDriver(OSDriver):
    notes = ("cmux Computer Use works in the background: it never takes the user's keyboard focus or pointer, and a "
             "blue cmux cursor shows where it acts. Its tools are the cmux-computer-use server's; act on element ids "
             "from get_ui_tree where you can.")

    def __init__(self) -> None:
        super().__init__()
        self._pinned: list[ReadyCheck] | None = None
        #: Each caller's server, the least recently used first.
        self._servers: dict[str | None, _Server] = {}
        self._sweeper: asyncio.Task | None = None
        self._closing: set[asyncio.Task] = set()

    def forwarded_tools(self) -> list[ForwardedTool]:
        return [ForwardedTool.listed(t, functools.partial(self._forward, t["name"])) for t in _manifest()["tools"]]

    @server_instructions
    def cmux_instructions(self) -> str:
        return _manifest()["instructions"]

    async def ready_checks(self) -> list[ReadyCheck]:
        """cmux's executable, its daemon, and what its server says, lists and reports, checked until they pass once;
        and the OS driver's own checks (XTEST on Linux, the TCC permissions on macOS) every time."""
        if self._pinned is None or not all(check.ok for check in self._pinned):
            self._pinned = await self._pinned_checks()
        return [*self._pinned, *await super().ready_checks()]

    async def _forward(self, tool: str, /, **arguments: Any) -> CallToolResult:
        """A call to one of cmux's tools on the caller's own server, answered as cmux answers it. Nothing here awaits
        before the call is queued, so calls a session makes together find one server."""
        caller = ToolContext.current().caller.session
        server = self._servers.pop(caller, None) or _Server(functools.partial(self._open, caller))
        self._evict(keep=MAX_SERVERS - 1)
        self._servers[caller] = server
        if self._sweeper is None or self._sweeper.done():
            self._sweeper = asyncio.create_task(self._sweep())
        try:
            return await server.call(tool, arguments)
        except Exception as e:
            return CallToolResult(isError=True, content=[TextContent(type="text", text=(
                f"cmux's Computer Use server failed before it answered, so {tool} may have run: {_reason(e)}"))])

    def _evict(self, keep: int = MAX_SERVERS) -> None:
        now = time.monotonic()
        free = [caller for caller, server in self._servers.items() if not server.busy]
        idle = [caller for caller in free if now - self._servers[caller].used > IDLE_S]
        over = max(0, len(self._servers) - len(idle) - keep)
        spare = [caller for caller in free if caller not in idle][:over]
        for caller in [*idle, *spare]:
            closing = asyncio.create_task(self._servers.pop(caller).close())
            self._closing.add(closing)
            closing.add_done_callback(self._closing.discard)

    async def _sweep(self) -> None:
        while self._servers:
            await asyncio.sleep(SWEEP_S)
            self._evict()

    @contextlib.asynccontextmanager
    async def _open(self, caller: str | None) -> AsyncIterator[tuple[ClientSession, InitializeResult]]:
        """``cmux computer-use mcp --primary`` for ``caller``'s Computer Use session, connected and initialized, with
        what it said at connect; it ends with the block, as closing its stdin ends it."""
        session = f"{SESSION_PREFIX}-{hashlib.sha256(str(caller).encode()).hexdigest()[:16]}"
        server = StdioServerParameters(command=str(EXECUTABLE), args=["computer-use", "mcp", "--primary"],
                                       env={**_environment(), "ACPMUX_COMPUTER_USE_SESSION": session,
                                            "ACPMUX_COMPUTER_USE_LABEL": LABEL})
        async with stdio_client(server) as (read, write), ClientSession(read, write) as client:
            yield client, await client.initialize()

    async def _pinned_checks(self) -> list[ReadyCheck]:
        key = f"{self.platform.os}/{self.platform.arch}"
        pinned = EXECUTABLES.get(key)
        digest = await asyncio.to_thread(_digest, EXECUTABLE)
        if pinned is None:
            ok, said = digest is not None, f"no pin for {key}; {EXECUTABLE} is {digest or 'missing'}"
        else:
            ok, said = digest == pinned, ("the pinned cmux build" if digest == pinned else
                                          f"{EXECUTABLE} is {digest or 'missing'}, not the pinned {pinned}")
        checks = [ReadyCheck("cmux", ok, said)]
        if not ok:
            return checks
        code, out = await _cmux("daemon", "status")
        checks.append(ReadyCheck("cmux daemon", code == 0, _first_lines(out) or f"it exited {code}"))
        if code != 0:
            return checks
        try:
            async with self._open("ready") as (client, initialized):
                listed = (await client.list_tools()).tools
                status = await client.call_tool("status", {})
        except Exception as e:
            return [*checks, ReadyCheck("cmux tools", False, f"cmux computer-use mcp didn't answer: {_reason(e)}")]
        running = {t.name: t.model_dump(mode="json", exclude_none=True) for t in listed}
        manifest = {t["name"]: t for t in _manifest()["tools"]}
        changed = ["instructions"] if initialized.instructions != _manifest()["instructions"] else []
        changed += sorted(name for name in running.keys() | manifest.keys() if name not in running or
                          name not in manifest or any(running[name].get(k) != v for k, v in manifest[name].items()))
        checks.append(ReadyCheck("cmux tools", not changed, f"its instructions and {len(running)} tools, as pinned"
                                 if not changed else f"these differ from {MANIFEST.name}: {', '.join(changed)}"))
        checks.append(_status_check(status))
        return checks


def _status_check(result: CallToolResult) -> ReadyCheck:
    """That cmux's worker answers ``status`` on this desktop, with what it needs granted."""
    text = " ".join(c.text for c in result.content if isinstance(c, TextContent))
    try:
        status = json.loads(text)
    except ValueError:
        return ReadyCheck("cmux worker", False, f"status answered {text[:300]!r}")
    if result.isError:
        return ReadyCheck("cmux worker", False, text[:300])
    permissions = status.get("permissions") or {}
    missing = sorted(name for name, state in permissions.items() if state not in ("granted", "not_needed"))
    platform = status.get("platform") or {}
    said = (f"{status.get('engine')} {status.get('version')} on {platform.get('display_server')} "
            f"({platform.get('detail')}), mode {status.get('mode')}, foreground "
            f"{'allowed' if status.get('allow_foreground') else 'off'}")
    return ReadyCheck("cmux worker", not missing, said if not missing else f"{said}; not granted: {missing}")


class _Server:
    """A caller's ``cmux computer-use mcp``, one at a time, held open by a task of its own, since a stdio client is
    entered and left in one task, and reached from any through that server's queue, one call at a time. A server that
    stops is let go, and the next call starts one afresh; ``close`` ends it for good."""

    def __init__(self, open_server: Callable[[], contextlib.AbstractAsyncContextManager]) -> None:
        self._open = open_server
        self._calls: asyncio.Queue | None = None
        self._serving: set[asyncio.Task] = set()
        self.used, self.busy = time.monotonic(), 0

    async def call(self, tool: str, arguments: dict) -> CallToolResult:
        if self._calls is None:
            self._calls = asyncio.Queue()
            serving = asyncio.create_task(self._serve(self._calls))
            self._serving.add(serving)
            serving.add_done_callback(self._serving.discard)
        answer = asyncio.get_running_loop().create_future()
        self.busy += 1
        try:
            self._calls.put_nowait((tool, arguments, answer))
            return await answer
        finally:
            self.busy -= 1
            self.used = time.monotonic()

    async def close(self) -> None:
        if self._calls is not None:
            self._calls.put_nowait(None)
            self._calls = None
        if serving := set(self._serving):
            _, late = await asyncio.wait(serving, timeout=CLOSE_TIMEOUT_S)
            for task in late:
                task.cancel()

    async def _serve(self, calls: asyncio.Queue) -> None:
        stopped: BaseException = ConnectionError("cmux computer-use mcp stopped")
        try:
            async with self._open() as (client, _):
                try:
                    while (call := await calls.get()) is not None:
                        tool, arguments, answer = call
                        if answer.done():
                            continue
                        try:
                            result = await client.call_tool(tool, arguments)
                        except McpError as e:
                            _settle(answer, error=e)
                            if e.error.code == CONNECTION_CLOSED:
                                raise
                            continue
                        except Exception as e:
                            _settle(answer, error=e)
                            raise
                        _settle(answer, result=result)
                finally:
                    self._let_go(calls)
        except Exception as e:
            stopped = e
        finally:
            self._let_go(calls)
            while not calls.empty():
                if (call := calls.get_nowait()) is not None:
                    _settle(call[-1], error=stopped)

    def _let_go(self, calls: asyncio.Queue) -> None:
        if self._calls is calls:
            self._calls = None


def _settle(answer: asyncio.Future, *, result: Any = None, error: BaseException | None = None) -> None:
    if answer.done():
        return
    if error is not None:
        answer.set_exception(error)
    else:
        answer.set_result(result)


def _reason(e: BaseException) -> str:
    """What failed, under the task groups the MCP client wraps it in."""
    while isinstance(e, BaseExceptionGroup) and len(e.exceptions) == 1:
        e = e.exceptions[0]
    return f"{type(e).__name__}: {e}"


@functools.cache
def _manifest() -> dict:
    return json.loads(MANIFEST.read_text(encoding="utf-8"))


def _environment() -> dict[str, str]:
    return {**{name: os.environ[name] for name in KEPT if os.environ.get(name)}, "PATH": PATH, **ATTENDED}


def _digest(path: Path) -> str | None:
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None


def _first_lines(text: str, n: int = 6) -> str:
    return "; ".join(line.strip() for line in text.strip().splitlines()[:n])


async def _cmux(*words: str) -> tuple[int, str]:
    process = await asyncio.create_subprocess_exec(str(EXECUTABLE), *words, stdin=asyncio.subprocess.DEVNULL,
                                                   stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
                                                   env=_environment())
    try:
        out, _ = await asyncio.wait_for(process.communicate(), DAEMON_TIMEOUT_S)
    except TimeoutError:
        process.kill()
        await process.wait()
        return 124, f"cmux {' '.join(words)} didn't finish within {DAEMON_TIMEOUT_S} s"
    return process.returncode, out.decode(errors="replace")


def _daemon() -> None:
    """The ``daemon`` service: once X answers, the cmux daemon started from the session user's home with
    ``CMUX_CU_HEADLESS=0``, then held until it exits, so the service's supervisor starts it again; a stop ends it."""
    socket = Path(f"/tmp/.X11-unix/X{os.environ['DISPLAY'].lstrip(':').partition('.')[0]}")
    while not socket.is_socket():
        time.sleep(0.2)
    os.chdir(Path.home())
    env = _environment()
    started = subprocess.run([str(EXECUTABLE), "daemon", "ensure"], env=env, capture_output=True, text=True,
                             timeout=DAEMON_TIMEOUT_S)
    sys.stdout.write(started.stdout + started.stderr)
    sys.stdout.flush()
    if started.returncode != 0:
        sys.exit(started.returncode)
    pid = int(re.search(r"^pid\s+(\d+)", started.stdout, re.M).group(1))

    def stop(*_: Any) -> None:
        subprocess.run([str(EXECUTABLE), "daemon", "stop"], env=env, timeout=DAEMON_TIMEOUT_S)
        sys.exit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        fd = os.pidfd_open(pid)
    except ProcessLookupError:
        sys.exit(f"the cmux daemon {pid} exited as it started")
    select.select([fd], [], [])
    sys.exit(f"the cmux daemon {pid} exited")


if __name__ == "__main__":
    _daemon()
