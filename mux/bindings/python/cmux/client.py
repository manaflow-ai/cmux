from __future__ import annotations

import base64
import json
import os
import socket
import tempfile
import threading
from dataclasses import dataclass
from typing import Any, Dict, Iterator, List, Optional


class CmuxError(Exception):
    pass


class CommandError(CmuxError):
    def __init__(self, message: str, response: Optional[Dict[str, Any]] = None):
        super().__init__(message)
        self.message = message
        self.response = response


class CmuxConnectionError(CmuxError):
    pass


class ProtocolError(CmuxError):
    pass


class TimeoutError(CmuxError):
    pass


@dataclass(frozen=True)
class EmptyResult:
    pass


@dataclass(frozen=True)
class IdentifyResult:
    app: str
    version: str
    protocol: int
    session: str
    pid: int


@dataclass(frozen=True)
class SurfaceResult:
    surface: int


@dataclass(frozen=True)
class ReadScreenResult:
    text: str


@dataclass(frozen=True)
class VtStateResult:
    cols: int
    rows: int
    data: str

    @property
    def replay_bytes(self) -> bytes:
        return base64.b64decode(self.data)


@dataclass(frozen=True)
class Size:
    cols: int
    rows: int


@dataclass(frozen=True)
class Layout:
    type: str
    pane: Optional[int] = None
    dir: Optional[str] = None
    ratio: Optional[float] = None
    a: Optional["Layout"] = None
    b: Optional["Layout"] = None


@dataclass(frozen=True)
class Tab:
    surface: int
    kind: str
    browser_source: Optional[str]
    name: Optional[str]
    title: str
    size: Optional[Size]
    dead: bool


@dataclass(frozen=True)
class Pane:
    id: int
    name: Optional[str]
    active_tab: int
    tabs: List[Tab]
    dead: bool = False


@dataclass(frozen=True)
class Screen:
    id: int
    name: Optional[str]
    active: bool
    active_pane: int
    layout: Layout
    panes: List[Pane]


@dataclass(frozen=True)
class Workspace:
    id: int
    name: str
    active: bool
    screens: List[Screen]


@dataclass(frozen=True)
class Tree:
    workspaces: List[Workspace]


@dataclass(frozen=True)
class Event:
    event: str
    raw: Dict[str, Any]
    surface: Optional[int] = None
    cols: Optional[int] = None
    rows: Optional[int] = None
    data: Optional[str] = None
    replay: Optional[str] = None

    @property
    def bytes_data(self) -> Optional[bytes]:
        payload = self.data if self.data is not None else self.replay
        return base64.b64decode(payload) if payload is not None else None


class _JsonLineConnection:
    def __init__(self, path: str, timeout: float):
        self.path = path
        self.timeout = timeout
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        try:
            self.sock.connect(path)
        except OSError as exc:
            self.sock.close()
            raise CmuxConnectionError(f"cannot connect to session socket {path}: {exc}") from exc
        self.reader = self.sock.makefile("r", encoding="utf-8", newline="\n")
        self._lock = threading.Lock()

    def send(self, value: Dict[str, Any]) -> None:
        line = json.dumps(value, separators=(",", ":")).encode("utf-8") + b"\n"
        with self._lock:
            try:
                self.sock.sendall(line)
            except OSError as exc:
                raise CmuxConnectionError(f"socket write failed: {exc}") from exc

    def recv(self) -> Dict[str, Any]:
        try:
            line = self.reader.readline()
        except socket.timeout as exc:
            raise TimeoutError("session did not respond") from exc
        except OSError as exc:
            raise CmuxConnectionError(f"socket read failed: {exc}") from exc
        if line == "":
            raise CmuxConnectionError("session socket closed")
        try:
            return json.loads(line)
        except json.JSONDecodeError as exc:
            raise ProtocolError(f"bad JSON from server: {exc}") from exc

    def close(self) -> None:
        try:
            self.reader.close()
        finally:
            self.sock.close()


class _Stream:
    def __init__(self, client: "CmuxClient", request: Dict[str, Any]):
        self._client = client
        self._conn = _JsonLineConnection(client.socket_path, client.timeout)
        self._queue: List[Event] = []
        self._closed = False
        self.response: Optional[Dict[str, Any]] = None
        request = dict(request)
        if "id" not in request:
            request["id"] = client._next_id()
        request_id = request["id"]
        self._conn.send(request)
        while True:
            value = self._conn.recv()
            if "event" in value:
                self._queue.append(_parse_event(value))
                continue
            if value.get("id") != request_id:
                continue
            if value.get("ok") is True:
                self.response = value
                break
            raise CommandError(value.get("error", "unknown error"), value)

    def __iter__(self) -> "_Stream":
        return self

    def __next__(self) -> Event:
        if self._closed:
            raise StopIteration
        if self._queue:
            return self._queue.pop(0)
        value = self._conn.recv()
        if "event" not in value:
            return self.__next__()
        event = _parse_event(value)
        if event.event == "detached":
            self.close()
        return event

    def close(self) -> None:
        if not self._closed:
            self._closed = True
            self._conn.close()


class EventStream(_Stream):
    pass


class AttachStream(_Stream):
    pass


class CmuxClient:
    def __init__(
        self,
        socket_path: Optional[str] = None,
        session: str = "main",
        timeout: float = 10.0,
        allow_protocol_v6_attach: bool = False,
    ):
        self.socket_path = socket_path or default_socket_path(session)
        self.timeout = timeout
        self.allow_protocol_v6_attach = allow_protocol_v6_attach
        self._conn = _JsonLineConnection(self.socket_path, timeout)
        self._next_request_id = 1
        self._id_lock = threading.Lock()
        self._protocol: Optional[int] = None

    def __enter__(self) -> "CmuxClient":
        return self

    def __exit__(self, exc_type: object, exc: object, tb: object) -> None:
        self.close()

    def close(self) -> None:
        self._conn.close()

    def _next_id(self) -> int:
        with self._id_lock:
            value = self._next_request_id
            self._next_request_id += 1
            return value

    def request(self, cmd: str, **params: Any) -> Dict[str, Any]:
        payload = {"id": self._next_id(), "cmd": cmd}
        payload.update({key: value for key, value in params.items() if value is not None})
        request_id = payload["id"]
        self._conn.send(payload)
        while True:
            response = self._conn.recv()
            if "event" in response:
                continue
            if response.get("id") not in (request_id, None):
                continue
            return response

    def _request(self, cmd: str, **params: Any) -> Dict[str, Any]:
        response = self.request(cmd, **params)
        if response.get("ok") is True:
            return response.get("data", {})
        raise CommandError(response.get("error", "unknown error"), response)

    def identify(self) -> IdentifyResult:
        data = self._request("identify")
        result = IdentifyResult(
            app=str(data["app"]),
            version=str(data["version"]),
            protocol=int(data["protocol"]),
            session=str(data["session"]),
            pid=int(data["pid"]),
        )
        self._protocol = result.protocol
        return result

    def list_workspaces(self) -> Tree:
        return _parse_tree(self._request("list-workspaces"))

    def export_layout(self, screen: Optional[int] = None) -> Dict[str, Any]:
        return self._request("export-layout", screen=screen)

    def apply_layout(
        self,
        layout: Dict[str, Any],
        workspace: Optional[int] = None,
        name: Optional[str] = None,
    ) -> Dict[str, Any]:
        return self._request("apply-layout", workspace=workspace, name=name, layout=layout)

    def send(
        self,
        surface: int,
        text: Optional[str] = None,
        bytes_data: Optional[bytes | str] = None,
    ) -> EmptyResult:
        encoded: Optional[str]
        if isinstance(bytes_data, bytes):
            encoded = base64.b64encode(bytes_data).decode("ascii")
        else:
            encoded = bytes_data
        self._request("send", surface=surface, text=text, bytes=encoded)
        return EmptyResult()

    def read_screen(self, surface: int) -> ReadScreenResult:
        data = self._request("read-screen", surface=surface)
        return ReadScreenResult(text=str(data["text"]))

    def vt_state(self, surface: int) -> VtStateResult:
        data = self._request("vt-state", surface=surface)
        return VtStateResult(cols=int(data["cols"]), rows=int(data["rows"]), data=str(data["data"]))

    def new_tab(
        self,
        pane: Optional[int] = None,
        cwd: Optional[str] = None,
        cols: Optional[int] = None,
        rows: Optional[int] = None,
    ) -> SurfaceResult:
        return SurfaceResult(int(self._request("new-tab", pane=pane, cwd=cwd, cols=cols, rows=rows)["surface"]))

    def new_browser_tab(
        self,
        url: str,
        pane: Optional[int] = None,
        cols: Optional[int] = None,
        rows: Optional[int] = None,
    ) -> SurfaceResult:
        return SurfaceResult(int(self._request("new-browser-tab", url=url, pane=pane, cols=cols, rows=rows)["surface"]))

    def new_workspace(
        self,
        name: Optional[str] = None,
        cols: Optional[int] = None,
        rows: Optional[int] = None,
    ) -> SurfaceResult:
        return SurfaceResult(int(self._request("new-workspace", name=name, cols=cols, rows=rows)["surface"]))

    def new_screen(
        self,
        workspace: Optional[int] = None,
        cols: Optional[int] = None,
        rows: Optional[int] = None,
    ) -> SurfaceResult:
        return SurfaceResult(int(self._request("new-screen", workspace=workspace, cols=cols, rows=rows)["surface"]))

    def split(
        self,
        pane: int,
        dir: str,
        cols: Optional[int] = None,
        rows: Optional[int] = None,
    ) -> SurfaceResult:
        return SurfaceResult(int(self._request("split", pane=pane, dir=dir, cols=cols, rows=rows)["surface"]))

    def set_ratio(self, pane: int, dir: str, ratio: float) -> EmptyResult:
        self._request("set-ratio", pane=pane, dir=dir, ratio=ratio)
        return EmptyResult()

    def pane_neighbor(self, pane: int, dir: str) -> Dict[str, Any]:
        return self._request("pane-neighbor", pane=pane, dir=dir)

    def focus_direction(self, dir: str, pane: Optional[int] = None) -> Dict[str, Any]:
        return self._request("focus-direction", pane=pane, dir=dir)

    def swap_pane(
        self,
        pane: int,
        dir: Optional[str] = None,
        target: Optional[int] = None,
    ) -> EmptyResult:
        self._request("swap-pane", pane=pane, dir=dir, target=target)
        return EmptyResult()

    def zoom_pane(self, pane: Optional[int] = None, mode: Optional[str] = None) -> Dict[str, Any]:
        return self._request("zoom-pane", pane=pane, mode=mode)

    def process_info(self, surface: int) -> Dict[str, Any]:
        return self._request("process-info", surface=surface)

    def set_default_colors(self, fg: Optional[str] = None, bg: Optional[str] = None) -> EmptyResult:
        self._request("set-default-colors", fg=fg, bg=bg)
        return EmptyResult()

    def close_surface(self, surface: int) -> EmptyResult:
        self._request("close-surface", surface=surface)
        return EmptyResult()

    def close_pane(self, pane: int) -> EmptyResult:
        self._request("close-pane", pane=pane)
        return EmptyResult()

    def close_screen(self, screen: int) -> EmptyResult:
        self._request("close-screen", screen=screen)
        return EmptyResult()

    def close_workspace(self, workspace: int) -> EmptyResult:
        self._request("close-workspace", workspace=workspace)
        return EmptyResult()

    def rename_pane(self, pane: int, name: str) -> EmptyResult:
        self._request("rename-pane", pane=pane, name=name)
        return EmptyResult()

    def rename_surface(self, surface: int, name: str) -> EmptyResult:
        self._request("rename-surface", surface=surface, name=name)
        return EmptyResult()

    def rename_screen(self, screen: int, name: str) -> EmptyResult:
        self._request("rename-screen", screen=screen, name=name)
        return EmptyResult()

    def rename_workspace(self, workspace: int, name: str) -> EmptyResult:
        self._request("rename-workspace", workspace=workspace, name=name)
        return EmptyResult()

    def resize_surface(self, surface: int, cols: int, rows: int) -> EmptyResult:
        self._request("resize-surface", surface=surface, cols=cols, rows=rows)
        return EmptyResult()

    def focus_pane(self, pane: int) -> EmptyResult:
        self._request("focus-pane", pane=pane)
        return EmptyResult()

    def select_tab(
        self,
        pane: Optional[int] = None,
        index: Optional[int] = None,
        delta: Optional[int] = None,
    ) -> EmptyResult:
        self._request("select-tab", pane=pane, index=index, delta=delta)
        return EmptyResult()

    def select_screen(self, index: Optional[int] = None, delta: Optional[int] = None) -> EmptyResult:
        self._request("select-screen", index=index, delta=delta)
        return EmptyResult()

    def select_workspace(self, index: Optional[int] = None, delta: Optional[int] = None) -> EmptyResult:
        self._request("select-workspace", index=index, delta=delta)
        return EmptyResult()

    def move_tab(self, surface: int, pane: int, index: int) -> EmptyResult:
        self._request("move-tab", surface=surface, pane=pane, index=index)
        return EmptyResult()

    def move_workspace(self, workspace: int, index: int) -> EmptyResult:
        self._request("move-workspace", workspace=workspace, index=index)
        return EmptyResult()

    def scroll_surface(self, surface: int, delta: int) -> EmptyResult:
        self._request("scroll-surface", surface=surface, delta=delta)
        return EmptyResult()

    def subscribe(self) -> EventStream:
        return EventStream(self, {"cmd": "subscribe"})

    def subscribe_with_request(self, request: Dict[str, Any]) -> EventStream:
        return EventStream(self, request)

    def attach_surface(self, surface: int) -> AttachStream:
        protocol = self._protocol if self._protocol is not None else self.identify().protocol
        if protocol > 5 and not self.allow_protocol_v6_attach:
            raise ProtocolError("protocol v6 attach streams require resized replay handling")
        return AttachStream(self, {"cmd": "attach-surface", "surface": surface})


def default_socket_path(session: str) -> str:
    base = os.environ.get("TMPDIR") or tempfile.gettempdir()
    return os.path.join(base, f"cmux-mux-{os.getuid()}", f"{session}.sock")


def _parse_tree(data: Dict[str, Any]) -> Tree:
    return Tree(workspaces=[_parse_workspace(item) for item in data.get("workspaces", [])])


def _parse_workspace(value: Dict[str, Any]) -> Workspace:
    return Workspace(
        id=int(value.get("id", 0)),
        name=str(value.get("name", "")),
        active=bool(value.get("active", False)),
        screens=[_parse_screen(item) for item in value.get("screens", [])],
    )


def _parse_screen(value: Dict[str, Any]) -> Screen:
    return Screen(
        id=int(value.get("id", 0)),
        name=value.get("name"),
        active=bool(value.get("active", False)),
        active_pane=int(value.get("active_pane", 0)),
        layout=_parse_layout(value.get("layout", {"type": "leaf", "pane": 0})),
        panes=[_parse_pane(item) for item in value.get("panes", [])],
    )


def _parse_layout(value: Dict[str, Any]) -> Layout:
    if value.get("type") == "split":
        return Layout(
            type="split",
            dir=value.get("dir"),
            ratio=float(value.get("ratio", 0.0)),
            a=_parse_layout(value.get("a", {})),
            b=_parse_layout(value.get("b", {})),
        )
    return Layout(type="leaf", pane=int(value.get("pane", 0)))


def _parse_pane(value: Dict[str, Any]) -> Pane:
    if value.get("dead") is True and "tabs" not in value:
        return Pane(id=int(value.get("id", 0)), name=None, active_tab=0, tabs=[], dead=True)
    return Pane(
        id=int(value.get("id", 0)),
        name=value.get("name"),
        active_tab=int(value.get("active_tab", 0)),
        tabs=[_parse_tab(item) for item in value.get("tabs", [])],
        dead=bool(value.get("dead", False)),
    )


def _parse_tab(value: Dict[str, Any]) -> Tab:
    size_value = value.get("size")
    size = None
    if isinstance(size_value, dict):
        size = Size(cols=int(size_value.get("cols", 0)), rows=int(size_value.get("rows", 0)))
    return Tab(
        surface=int(value.get("surface", 0)),
        kind=str(value.get("kind", "pty")),
        browser_source=value.get("browser_source"),
        name=value.get("name"),
        title=str(value.get("title", "")),
        size=size,
        dead=bool(value.get("dead", False)),
    )


def _parse_event(value: Dict[str, Any]) -> Event:
    return Event(
        event=str(value.get("event", "")),
        raw=value,
        surface=value.get("surface"),
        cols=value.get("cols"),
        rows=value.get("rows"),
        data=value.get("data"),
        replay=value.get("replay"),
    )
