#!/usr/bin/env python3
"""cmux v2 Python Client

A client library for programmatically controlling cmux via the Unix socket.

This client speaks the v2 JSON line protocol (one JSON request/response per line).
It intentionally mirrors the existing v1 Python client's convenience API so the
existing test suite can be ported with minimal churn.

Protocol:
  Request:  {"id": 1, "method": "surface.list", "params": {..}}
  Response: {"id": 1, "ok": true, "result": {...}}

Notes:
- v2 uses stable UUID handles for workspaces/panes/surfaces.
- For test convenience, this client accepts integer indexes for many methods and
  resolves them to IDs using list calls.
"""

import base64
import errno
import json
import os
import select
import socket
import time
import uuid
from typing import Any, Dict, List, Optional, Tuple, Union


class cmuxError(Exception):
    """Exception raised for cmux errors."""


def _default_socket_path() -> str:
    # Backwards/forward compatibility: some scripts export CMUX_SOCKET,
    # while the client historically used CMUX_SOCKET_PATH.
    override = os.environ.get("CMUX_SOCKET_PATH") or os.environ.get("CMUX_SOCKET")
    if override:
        return override
    candidates = ["/tmp/cmux-debug.sock", "/tmp/cmux.sock"]
    for path in candidates:
        if os.path.exists(path):
            return path
    return candidates[0]


def _looks_like_uuid(s: str) -> bool:
    try:
        uuid.UUID(s)
        return True
    except Exception:
        return False


def _looks_like_ref(s: str, kind: Optional[str] = None) -> bool:
    parts = s.split(":", 1)
    if len(parts) != 2:
        return False
    ref_kind, ordinal = parts[0].strip().lower(), parts[1].strip()
    if kind is not None and ref_kind != kind:
        return False
    if ref_kind not in {"window", "workspace", "pane", "surface"}:
        return False
    return ordinal.isdigit()


def _unescape_backslash_controls(s: str) -> str:
    """Interpret \n/\r/\t/\\ sequences in a string.

    v2 can carry raw newlines via JSON, but a lot of existing callsites use
    backslash escapes (because v1 was line-oriented). This keeps the API
    ergonomic for tests and scripts.
    """

    out: List[str] = []
    i = 0
    while i < len(s):
        ch = s[i]
        if ch != "\\" or i + 1 >= len(s):
            out.append(ch)
            i += 1
            continue

        nxt = s[i + 1]
        if nxt == "n":
            out.append("\n")
            i += 2
        elif nxt == "r":
            out.append("\r")
            i += 2
        elif nxt == "t":
            out.append("\t")
            i += 2
        elif nxt == "\\":
            out.append("\\")
            i += 2
        else:
            # Preserve unknown escapes literally.
            out.append(ch)
            i += 1
    return "".join(out)


class cmux:
    """Client for controlling cmux via the v2 JSON Unix socket."""

    DEFAULT_SOCKET_PATH = _default_socket_path()

    def __init__(self, socket_path: str = None):
        self.socket_path = socket_path or self.DEFAULT_SOCKET_PATH
        self._socket: Optional[socket.socket] = None
        self._recv_buffer: str = ""
        self._next_id: int = 1

    # ---------------------------------------------------------------------
    # Connection
    # ---------------------------------------------------------------------

    def connect(self) -> None:
        if self._socket is not None:
            return

        start = time.time()
        while not os.path.exists(self.socket_path):
            if time.time() - start >= 10.0:
                raise cmuxError(
                    f"Socket not found at {self.socket_path}. Is cmux running?"
                )
            time.sleep(0.1)

        last_error: Optional[socket.error] = None
        while True:
            self._socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                self._socket.connect(self.socket_path)
                self._socket.settimeout(10.0)
                return
            except socket.error as e:
                last_error = e
                try:
                    self._socket.close()
                except Exception:
                    pass
                self._socket = None
                if e.errno in (errno.ECONNREFUSED, errno.ENOENT) and time.time() - start < 10.0:
                    time.sleep(0.1)
                    continue
                raise cmuxError(f"Failed to connect: {e}")

    def close(self) -> None:
        if self._socket is not None:
            try:
                self._socket.close()
            finally:
                self._socket = None

    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()
        return False

    # ---------------------------------------------------------------------
    # Low-level protocol
    # ---------------------------------------------------------------------

    def _recv_line(self, timeout_s: float = 20.0) -> str:
        if self._socket is None:
            raise cmuxError("Not connected")

        if "\n" in self._recv_buffer:
            line, rest = self._recv_buffer.split("\n", 1)
            self._recv_buffer = rest
            return line

        deadline = time.time() + timeout_s
        while time.time() < deadline:
            remaining = max(0.0, deadline - time.time())
            ready, _, _ = select.select([self._socket], [], [], min(0.2, remaining))
            if not ready:
                continue

            chunk = self._socket.recv(8192)
            if not chunk:
                raise cmuxError("Socket closed")
            self._recv_buffer += chunk.decode("utf-8", errors="replace")

            if "\n" in self._recv_buffer:
                line, rest = self._recv_buffer.split("\n", 1)
                self._recv_buffer = rest
                return line

        raise cmuxError("Timed out waiting for response")

    def _call(self, method: str, params: Optional[Dict[str, Any]] = None, timeout_s: float = 20.0) -> Any:
        if self._socket is None:
            raise cmuxError("Not connected")

        req_id = self._next_id
        self._next_id += 1

        payload = {
            "id": req_id,
            "method": method,
            "params": params or {},
        }
        line = json.dumps(payload, separators=(",", ":")) + "\n"
        self._socket.sendall(line.encode("utf-8"))

        resp_line = self._recv_line(timeout_s=timeout_s)
        try:
            resp = json.loads(resp_line)
        except json.JSONDecodeError as e:
            raise cmuxError(f"Invalid JSON response: {e}: {resp_line[:200]}")

        if not isinstance(resp, dict):
            raise cmuxError(f"Invalid response type: {type(resp).__name__}")

        if resp.get("id") != req_id:
            raise cmuxError(f"Mismatched response id: expected {req_id}, got {resp.get('id')}")

        if resp.get("ok") is True:
            return resp.get("result")

        err = resp.get("error") or {}
        code = err.get("code") or "error"
        msg = err.get("message") or "Unknown error"
        data = err.get("data")
        if data is not None:
            raise cmuxError(f"{code}: {msg} ({data})")
        raise cmuxError(f"{code}: {msg}")

    # ---------------------------------------------------------------------
    # ID resolution helpers (index -> id)
    # ---------------------------------------------------------------------

    def _resolve_workspace_id(self, workspace: Union[str, int, None]) -> Optional[str]:
        if workspace is None:
            res = self._call("workspace.current")
            wsid = (res or {}).get("workspace_id")
            if not wsid:
                raise cmuxError("No workspace selected")
            return str(wsid)

        if isinstance(workspace, int):
            items = (self._call("workspace.list") or {}).get("workspaces") or []
            for row in items:
                if int(row.get("index", -1)) == workspace:
                    return str(row.get("id"))
            raise cmuxError(f"Workspace index not found: {workspace}")

        s = str(workspace).strip()
        if not s:
            return None
        if s.isdigit():
            return self._resolve_workspace_id(int(s))
        if _looks_like_ref(s, "workspace"):
            return s
        if not _looks_like_uuid(s):
            raise cmuxError(f"Invalid workspace id: {s}")
        return s

    def _resolve_surface_id(self, surface: Union[str, int, None], workspace_id: Optional[str] = None) -> Optional[str]:
        if surface is None:
            # Try fast-path via identify.
            ident = self._call("system.identify")
            focused = (ident or {}).get("focused") or {}
            sid = focused.get("surface_id") if isinstance(focused, dict) else None
            return None if sid in (None, "", {}) else str(sid)

        if isinstance(surface, int):
            params: Dict[str, Any] = {}
            if workspace_id:
                params["workspace_id"] = workspace_id
            items = (self._call("surface.list", params) or {}).get("surfaces") or []
            for row in items:
                if int(row.get("index", -1)) == surface:
                    return str(row.get("id"))
            raise cmuxError(f"Surface index not found: {surface}")

        s = str(surface).strip()
        if not s:
            return None
        if s.isdigit():
            return self._resolve_surface_id(int(s), workspace_id=workspace_id)
        if _looks_like_ref(s, "surface"):
            return s
        if not _looks_like_uuid(s):
            raise cmuxError(f"Invalid surface id: {s}")
        return s

    def _resolve_pane_id(self, pane: Union[str, int, None], workspace_id: Optional[str] = None) -> Optional[str]:
        if pane is None:
            ident = self._call("system.identify")
            focused = (ident or {}).get("focused") or {}
            pid = focused.get("pane_id") if isinstance(focused, dict) else None
            return None if pid in (None, "", {}) else str(pid)

        if isinstance(pane, int):
            params: Dict[str, Any] = {}
            if workspace_id:
                params["workspace_id"] = workspace_id
            items = (self._call("pane.list", params) or {}).get("panes") or []
            for row in items:
                if int(row.get("index", -1)) == pane:
                    return str(row.get("id"))
            raise cmuxError(f"Pane index not found: {pane}")

        s = str(pane).strip()
        if not s:
            return None
        if s.isdigit():
            return self._resolve_pane_id(int(s), workspace_id=workspace_id)
        if _looks_like_ref(s, "pane"):
            return s
        if not _looks_like_uuid(s):
            raise cmuxError(f"Invalid pane id: {s}")
        return s

    # ---------------------------------------------------------------------
    # System
    # ---------------------------------------------------------------------

    def ping(self) -> bool:
        res = self._call("system.ping")
        return bool((res or {}).get("pong"))

    def capabilities(self) -> dict:
        return dict(self._call("system.capabilities") or {})

    def identify(self, caller: Optional[dict] = None) -> dict:
        params: Dict[str, Any] = {}
        if caller is not None:
            params["caller"] = caller
        return dict(self._call("system.identify", params) or {})

    # ---------------------------------------------------------------------
    # Windows
    # ---------------------------------------------------------------------

    def list_windows(self) -> List[dict]:
        res = self._call("window.list") or {}
        return list(res.get("windows") or [])

    def current_window(self) -> str:
        res = self._call("window.current") or {}
        wid = res.get("window_id")
        if not wid:
            raise cmuxError(f"window.current returned no window_id: {res}")
        return str(wid)

    def new_window(self) -> str:
        res = self._call("window.create") or {}
        wid = res.get("window_id")
        if not wid:
            raise cmuxError(f"window.create returned no window_id: {res}")
        return str(wid)

    def focus_window(self, window_id: str) -> None:
        self._call("window.focus", {"window_id": str(window_id)})

    def close_window(self, window_id: str) -> None:
        self._call("window.close", {"window_id": str(window_id)})

    # ---------------------------------------------------------------------
    # Workspaces
    # ---------------------------------------------------------------------

    def list_workspaces(self, window_id: Optional[str] = None) -> List[Tuple[int, str, str, bool]]:
        params: Dict[str, Any] = {}
        if window_id is not None:
            params["window_id"] = str(window_id)
        res = self._call("workspace.list", params) or {}
        out: List[Tuple[int, str, str, bool]] = []
        for row in res.get("workspaces") or []:
            out.append((
                int(row.get("index", 0)),
                str(row.get("id")),
                str(row.get("title", "")),
                bool(row.get("selected", False)),
            ))
        return out

    def new_workspace(self, window_id: Optional[str] = None) -> str:
        params: Dict[str, Any] = {}
        if window_id is not None:
            params["window_id"] = str(window_id)
        res = self._call("workspace.create", params) or {}
        wsid = res.get("workspace_id")
        if not wsid:
            raise cmuxError(f"workspace.create returned no workspace_id: {res}")
        return str(wsid)

    def select_workspace(self, workspace: Union[str, int]) -> None:
        wsid = self._resolve_workspace_id(workspace)
        self._call("workspace.select", {"workspace_id": wsid})

    def rename_workspace(self, title: str, workspace: Union[str, int, None] = None) -> None:
        renamed = str(title).strip()
        if not renamed:
            raise cmuxError("rename_workspace requires a non-empty title")
        wsid = self._resolve_workspace_id(workspace)
        params: Dict[str, Any] = {"title": renamed}
        if wsid:
            params["workspace_id"] = wsid
        self._call("workspace.rename", params)

    def current_workspace(self) -> str:
        wsid = self._resolve_workspace_id(None)
        if not wsid:
            raise cmuxError("No current workspace")
        return wsid

    def next_workspace(self) -> str:
        res = self._call("workspace.next") or {}
        wsid = res.get("workspace_id")
        if not wsid:
            raise cmuxError(f"workspace.next returned no workspace_id: {res}")
        return str(wsid)

    def previous_workspace(self) -> str:
        res = self._call("workspace.previous") or {}
        wsid = res.get("workspace_id")
        if not wsid:
            raise cmuxError(f"workspace.previous returned no workspace_id: {res}")
        return str(wsid)

    def last_workspace(self) -> str:
        res = self._call("workspace.last") or {}
        wsid = res.get("workspace_id")
        if not wsid:
            raise cmuxError(f"workspace.last returned no workspace_id: {res}")
        return str(wsid)

    def move_workspace_to_window(self, workspace: Union[str, int], window_id: str, focus: bool = True) -> None:
        wsid = self._resolve_workspace_id(workspace)
        self._call(
            "workspace.move_to_window",
            {"workspace_id": wsid, "window_id": str(window_id), "focus": bool(focus)},
        )

    def reorder_workspace(
        self,
        workspace: Union[str, int],
        *,
        index: Optional[int] = None,
        before_workspace: Union[str, int, None] = None,
        after_workspace: Union[str, int, None] = None,
        window_id: Optional[str] = None,
    ) -> None:
        wsid = self._resolve_workspace_id(workspace)
        params: Dict[str, Any] = {"workspace_id": wsid}

        targets = 0
        if index is not None:
            params["index"] = int(index)
            targets += 1
        if before_workspace is not None:
            params["before_workspace_id"] = self._resolve_workspace_id(before_workspace)
            targets += 1
        if after_workspace is not None:
            params["after_workspace_id"] = self._resolve_workspace_id(after_workspace)
            targets += 1
        if targets != 1:
            raise cmuxError("reorder_workspace requires exactly one target: index|before_workspace|after_workspace")

        if window_id is not None:
            params["window_id"] = str(window_id)

        self._call("workspace.reorder", params)

    def close_workspace(self, workspace_id: str) -> None:
        wsid = self._resolve_workspace_id(workspace_id)
        self._call("workspace.close", {"workspace_id": wsid})

    # Backwards-compatible aliases
    def list_tabs(self) -> List[Tuple[int, str, str, bool]]:
        return self.list_workspaces()

    def new_tab(self) -> str:
        return self.new_workspace()

    def close_tab(self, workspace_id: str) -> None:
        return self.close_workspace(workspace_id)

    def select_tab(self, workspace: Union[str, int]) -> None:
        return self.select_workspace(workspace)

    def current_tab(self) -> str:
        return self.current_workspace()

    # ---------------------------------------------------------------------
    # Surfaces / panes
    # ---------------------------------------------------------------------

    def list_surfaces(self, workspace: Union[str, int, None] = None) -> List[Tuple[int, str, bool]]:
        params: Dict[str, Any] = {}
        if workspace is not None:
            wsid = self._resolve_workspace_id(workspace)
            params["workspace_id"] = wsid
        res = self._call("surface.list", params) or {}
        out: List[Tuple[int, str, bool]] = []
        for row in res.get("surfaces") or []:
            out.append((
                int(row.get("index", 0)),
                str(row.get("id")),
                bool(row.get("focused", False)),
            ))
        return out

    def focus_surface(self, surface: Union[str, int]) -> None:
        sid = self._resolve_surface_id(surface)
        if not sid:
            raise cmuxError(f"Invalid surface: {surface!r}")
        self._call("surface.focus", {"surface_id": sid})

    def focus_surface_by_panel(self, surface_id: str) -> None:
        # In v2, surface_id is the panel UUID.
        self.focus_surface(surface_id)

    def new_split(self, direction: str) -> str:
        res = self._call("surface.split", {"direction": direction}) or {}
        sid = res.get("surface_id")
        if not sid:
            raise cmuxError(f"surface.split returned no surface_id: {res}")
        return str(sid)

    def drag_surface_to_split(self, surface: Union[str, int], direction: str) -> None:
        sid = self._resolve_surface_id(surface)
        if not sid:
            raise cmuxError(f"Invalid surface: {surface!r}")
        self._call("surface.drag_to_split", {"surface_id": sid, "direction": direction})

    def new_pane(self, direction: str = "right", panel_type: str = "terminal", url: str = None) -> str:
        params: Dict[str, Any] = {"direction": direction, "type": panel_type}
        if url:
            params["url"] = url
        res = self._call("pane.create", params) or {}
        sid = res.get("surface_id")
        if not sid:
            raise cmuxError(f"pane.create returned no surface_id: {res}")
        return str(sid)

    def new_surface(self, pane: Union[str, int, None] = None, panel_type: str = "terminal", url: str = None) -> str:
        params: Dict[str, Any] = {"type": panel_type}
        if pane is not None:
            pid = self._resolve_pane_id(pane)
            if not pid:
                raise cmuxError(f"Invalid pane: {pane!r}")
            params["pane_id"] = pid
        if url:
            params["url"] = url
        res = self._call("surface.create", params) or {}
        sid = res.get("surface_id")
        if not sid:
            raise cmuxError(f"surface.create returned no surface_id: {res}")
        return str(sid)

    def close_surface(self, surface: Union[str, int, None] = None) -> None:
        params: Dict[str, Any] = {}
        if surface is not None:
            sid = self._resolve_surface_id(surface)
            if not sid:
                raise cmuxError(f"Invalid surface: {surface!r}")
            params["surface_id"] = sid
        self._call("surface.close", params)

    def move_surface(
        self,
        surface: Union[str, int],
        *,
        pane: Union[str, int, None] = None,
        workspace: Union[str, int, None] = None,
        window_id: Optional[str] = None,
        before_surface: Union[str, int, None] = None,
        after_surface: Union[str, int, None] = None,
        index: Optional[int] = None,
        focus: bool = True,
    ) -> None:
        sid = self._resolve_surface_id(surface)
        if not sid:
            raise cmuxError(f"Invalid surface: {surface!r}")

        params: Dict[str, Any] = {"surface_id": sid, "focus": bool(focus)}
        if pane is not None:
            pid = self._resolve_pane_id(pane)
            if not pid:
                raise cmuxError(f"Invalid pane: {pane!r}")
            params["pane_id"] = pid
        if workspace is not None:
            wsid = self._resolve_workspace_id(workspace)
            if not wsid:
                raise cmuxError(f"Invalid workspace: {workspace!r}")
            params["workspace_id"] = wsid
        if window_id is not None:
            params["window_id"] = str(window_id)
        if before_surface is not None:
            before_id = self._resolve_surface_id(before_surface)
            if not before_id:
                raise cmuxError(f"Invalid before_surface: {before_surface!r}")
            params["before_surface_id"] = before_id
        if after_surface is not None:
            after_id = self._resolve_surface_id(after_surface)
            if not after_id:
                raise cmuxError(f"Invalid after_surface: {after_surface!r}")
            params["after_surface_id"] = after_id
        if index is not None:
            params["index"] = int(index)

        self._call("surface.move", params)

    def reorder_surface(
        self,
        surface: Union[str, int],
        *,
        index: Optional[int] = None,
        before_surface: Union[str, int, None] = None,
        after_surface: Union[str, int, None] = None,
    ) -> None:
        sid = self._resolve_surface_id(surface)
        if not sid:
            raise cmuxError(f"Invalid surface: {surface!r}")

        params: Dict[str, Any] = {"surface_id": sid}
        targets = 0
        if index is not None:
            params["index"] = int(index)
            targets += 1
        if before_surface is not None:
            before_id = self._resolve_surface_id(before_surface)
            if not before_id:
                raise cmuxError(f"Invalid before_surface: {before_surface!r}")
            params["before_surface_id"] = before_id
            targets += 1
        if after_surface is not None:
            after_id = self._resolve_surface_id(after_surface)
            if not after_id:
                raise cmuxError(f"Invalid after_surface: {after_surface!r}")
            params["after_surface_id"] = after_id
            targets += 1
        if targets != 1:
            raise cmuxError("reorder_surface requires exactly one target: index|before_surface|after_surface")

        self._call("surface.reorder", params)

    def trigger_flash(self, surface: Union[str, int, None] = None) -> None:
        params: Dict[str, Any] = {}
        if surface is not None:
            sid = self._resolve_surface_id(surface)
            if not sid:
                raise cmuxError(f"Invalid surface: {surface!r}")
            params["surface_id"] = sid
        self._call("surface.trigger_flash", params)

    def refresh_surfaces(self, workspace: Union[str, int, None] = None) -> None:
        params: Dict[str, Any] = {}
        if workspace is not None:
            wsid = self._resolve_workspace_id(workspace)
            params["workspace_id"] = wsid
        self._call("surface.refresh", params)

    def surface_health(self, workspace: Union[str, int, None] = None) -> List[dict]:
        params: Dict[str, Any] = {}
        if workspace is not None:
            wsid = self._resolve_workspace_id(workspace)
            params["workspace_id"] = wsid
        res = self._call("surface.health", params) or {}
        return list(res.get("surfaces") or [])

    def clear_history(self, surface: Union[str, int, None] = None, workspace: Union[str, int, None] = None) -> None:
        params: Dict[str, Any] = {}
        if workspace is not None:
            wsid = self._resolve_workspace_id(workspace)
            params["workspace_id"] = wsid
        if surface is not None:
            sid = self._resolve_surface_id(surface, workspace_id=params.get("workspace_id"))
            if not sid:
                raise cmuxError(f"Invalid surface: {surface!r}")
            params["surface_id"] = sid
        self._call("surface.clear_history", params)

    # ---------------------------------------------------------------------
    # Pane commands
    # ---------------------------------------------------------------------

    def list_panes(self) -> List[Tuple[int, str, int, bool]]:
        res = self._call("pane.list") or {}
        out: List[Tuple[int, str, int, bool]] = []
        for row in res.get("panes") or []:
            out.append((
                int(row.get("index", 0)),
                str(row.get("id")),
                int(row.get("surface_count", 0)),
                bool(row.get("focused", False)),
            ))
        return out

    def focus_pane(self, pane: Union[str, int]) -> None:
        pid = self._resolve_pane_id(pane)
        if not pid:
            raise cmuxError(f"Invalid pane: {pane!r}")
        self._call("pane.focus", {"pane_id": pid})

    def list_pane_surfaces(self, pane: Union[str, int, None] = None) -> List[Tuple[int, str, str, bool]]:
        params: Dict[str, Any] = {}
        if pane is not None:
            pid = self._resolve_pane_id(pane)
            params["pane_id"] = pid
        res = self._call("pane.surfaces", params) or {}
        out: List[Tuple[int, str, str, bool]] = []
        for row in res.get("surfaces") or []:
            out.append((
                int(row.get("index", 0)),
                str(row.get("id")),
                str(row.get("title", "")),
                bool(row.get("selected", False)),
            ))
        return out

    def swap_pane(self, pane: Union[str, int], target_pane: Union[str, int], focus: bool = True) -> None:
        source = self._resolve_pane_id(pane)
        target = self._resolve_pane_id(target_pane)
        if not source or not target:
            raise cmuxError(f"Invalid panes: pane={pane!r}, target_pane={target_pane!r}")
        self._call("pane.swap", {"pane_id": source, "target_pane_id": target, "focus": bool(focus)})

    def break_pane(self, pane: Union[str, int, None] = None, surface: Union[str, int, None] = None, focus: bool = True) -> str:
        params: Dict[str, Any] = {"focus": bool(focus)}
        if pane is not None:
            pid = self._resolve_pane_id(pane)
            if not pid:
                raise cmuxError(f"Invalid pane: {pane!r}")
            params["pane_id"] = pid
        if surface is not None:
            sid = self._resolve_surface_id(surface)
            if not sid:
                raise cmuxError(f"Invalid surface: {surface!r}")
            params["surface_id"] = sid
        res = self._call("pane.break", params) or {}
        wsid = res.get("workspace_id")
        if not wsid:
            raise cmuxError(f"pane.break returned no workspace_id: {res}")
        return str(wsid)

    def join_pane(
        self,
        target_pane: Union[str, int],
        pane: Union[str, int, None] = None,
        surface: Union[str, int, None] = None,
        focus: bool = True,
    ) -> None:
        target = self._resolve_pane_id(target_pane)
        if not target:
            raise cmuxError(f"Invalid target_pane: {target_pane!r}")
        params: Dict[str, Any] = {"target_pane_id": target, "focus": bool(focus)}
        if pane is not None:
            source = self._resolve_pane_id(pane)
            if not source:
                raise cmuxError(f"Invalid pane: {pane!r}")
            params["pane_id"] = source
        if surface is not None:
            sid = self._resolve_surface_id(surface)
            if not sid:
                raise cmuxError(f"Invalid surface: {surface!r}")
            params["surface_id"] = sid
        self._call("pane.join", params)

    def last_pane(self) -> str:
        res = self._call("pane.last") or {}
        pid = res.get("pane_id")
        if not pid:
            raise cmuxError(f"pane.last returned no pane_id: {res}")
        return str(pid)

    # ---------------------------------------------------------------------
    # Input
    # ---------------------------------------------------------------------

    def send(self, text: str) -> None:
        text2 = _unescape_backslash_controls(text)
        self._call("surface.send_text", {"text": text2})

    def send_surface(self, surface: Union[str, int], text: str) -> None:
        sid = self._resolve_surface_id(surface)
        if not sid:
            raise cmuxError(f"Invalid surface: {surface!r}")
        text2 = _unescape_backslash_controls(text)
        self._call("surface.send_text", {"surface_id": sid, "text": text2})

    def send_key(self, key: str) -> None:
        self._call("surface.send_key", {"key": key})

    def send_key_surface(self, surface: Union[str, int], key: str) -> None:
        sid = self._resolve_surface_id(surface)
        if not sid:
            raise cmuxError(f"Invalid surface: {surface!r}")
        self._call("surface.send_key", {"surface_id": sid, "key": key})

    def send_ctrl_c(self) -> None:
        self.send_key("ctrl-c")

    def send_ctrl_d(self) -> None:
        self.send_key("ctrl-d")

    # ---------------------------------------------------------------------
    # Notifications
    # ---------------------------------------------------------------------

    def notify(self, title: str, subtitle: str = "", body: str = "") -> None:
        self._call("notification.create", {"title": title, "subtitle": subtitle, "body": body})

    def notify_surface(self, surface: Union[str, int], title: str, subtitle: str = "", body: str = "") -> None:
        sid = self._resolve_surface_id(surface)
        if not sid:
            raise cmuxError(f"Invalid surface: {surface!r}")
        self._call(
            "notification.create_for_surface",
            {"surface_id": sid, "title": title, "subtitle": subtitle, "body": body},
        )

    def list_notifications(self) -> list[dict]:
        res = self._call("notification.list") or {}
        return list(res.get("notifications") or [])

    def clear_notifications(self) -> None:
        self._call("notification.clear")

    def set_app_focus(self, active: Union[bool, None]) -> None:
        if active is None:
            state = "clear"
        else:
            state = "active" if active else "inactive"
        self._call("app.focus_override.set", {"state": state})

    def simulate_app_active(self) -> None:
        self._call("app.simulate_active")

    # Debug-only: focus via notification flow
    def focus_notification(self, workspace: Union[str, int], surface: Union[str, int, None] = None) -> None:
        wsid = self._resolve_workspace_id(workspace)
        params: Dict[str, Any] = {"workspace_id": wsid}
        if surface is not None:
            sid = self._resolve_surface_id(surface, workspace_id=wsid)
            params["surface_id"] = sid
        self._call("debug.notification.focus", params)

    # ---------------------------------------------------------------------
    # Browser
    # ---------------------------------------------------------------------

    def open_browser(self, url: str = None) -> str:
        params: Dict[str, Any] = {}
        if url:
            params["url"] = url
        res = self._call("browser.open_split", params) or {}
        sid = res.get("surface_id")
        if not sid:
            raise cmuxError(f"browser.open_split returned no surface_id: {res}")
        return str(sid)

    def navigate(self, panel_id: str, url: str) -> None:
        sid = self._resolve_surface_id(panel_id)
        if not sid:
            raise cmuxError(f"Invalid surface: {panel_id!r}")
        self._call("browser.navigate", {"surface_id": sid, "url": url})

    def browser_back(self, panel_id: str) -> None:
        sid = self._resolve_surface_id(panel_id)
        self._call("browser.back", {"surface_id": sid})

    def browser_forward(self, panel_id: str) -> None:
        sid = self._resolve_surface_id(panel_id)
        self._call("browser.forward", {"surface_id": sid})

    def browser_reload(self, panel_id: str) -> None:
        sid = self._resolve_surface_id(panel_id)
        self._call("browser.reload", {"surface_id": sid})

    def get_url(self, panel_id: str) -> str:
        sid = self._resolve_surface_id(panel_id)
        res = self._call("browser.url.get", {"surface_id": sid}) or {}
        return str(res.get("url") or "")

    def focus_webview(self, panel_id: str) -> None:
        sid = self._resolve_surface_id(panel_id)
        self._call("browser.focus_webview", {"surface_id": sid})

    def is_webview_focused(self, panel_id: str) -> bool:
        sid = self._resolve_surface_id(panel_id)
        res = self._call("browser.is_webview_focused", {"surface_id": sid}) or {}
        return bool(res.get("focused"))

    def wait_for_webview_focus(self, panel_id: str, timeout_s: float = 2.0) -> None:
        start = time.time()
        while time.time() - start < timeout_s:
            if self.is_webview_focused(panel_id):
                return
            time.sleep(0.05)
        raise cmuxError(f"Timed out waiting for webview focus: {panel_id}")

    # ---------------------------------------------------------------------
    # Debug / test-only
    # ---------------------------------------------------------------------

    def set_shortcut(self, name: str, combo: str) -> None:
        self._call("debug.shortcut.set", {"name": name, "combo": combo})

    def simulate_shortcut(self, combo: str) -> None:
        self._call("debug.shortcut.simulate", {"combo": combo})

    def simulate_type(self, text: str) -> None:
        text2 = _unescape_backslash_controls(text)
        self._call("debug.type", {"text": text2})

    def activate_app(self) -> None:
        self._call("debug.app.activate")

    def is_terminal_focused(self, panel: Union[str, int]) -> bool:
        sid = self._resolve_surface_id(panel)
        res = self._call("debug.terminal.is_focused", {"surface_id": sid}) or {}
        return bool(res.get("focused"))

    def read_terminal_text(self, panel: Union[str, int, None] = None) -> str:
        params: Dict[str, Any] = {}
        if panel is not None:
            sid = self._resolve_surface_id(panel)
            params["surface_id"] = sid
        try:
            res = self._call("surface.read_text", params) or {}
            if "text" in res:
                return str(res.get("text") or "")
            b64 = str(res.get("base64") or "")
            raw = base64.b64decode(b64) if b64 else b""
            return raw.decode("utf-8", errors="replace")
        except cmuxError as exc:
            # Back-compat for older builds that only expose the debug method.
            if "method_not_found" not in str(exc):
                raise

        res = self._call("debug.terminal.read_text", params) or {}
        b64 = str(res.get("base64") or "")
        raw = base64.b64decode(b64) if b64 else b""
        return raw.decode("utf-8", errors="replace")

    def render_stats(self, panel: Union[str, int, None] = None) -> dict:
        params: Dict[str, Any] = {}
        if panel is not None:
            sid = self._resolve_surface_id(panel)
            params["surface_id"] = sid
        res = self._call("debug.terminal.render_stats", params) or {}
        # Server wraps the underlying stats object under "stats".
        return dict(res.get("stats") or {})

    def layout_debug(self) -> dict:
        res = self._call("debug.layout") or {}
        # Server wraps LayoutDebugResponse under "layout".
        return dict(res.get("layout") or {})

    def panel_snapshot_reset(self, panel: Union[str, int]) -> None:
        sid = self._resolve_surface_id(panel)
        self._call("debug.panel_snapshot.reset", {"surface_id": sid})

    def panel_snapshot(self, panel: Union[str, int], label: str = "") -> dict:
        sid = self._resolve_surface_id(panel)
        params: Dict[str, Any] = {"surface_id": sid}
        if label:
            params["label"] = label
        res = dict(self._call("debug.panel_snapshot", params) or {})
        # Normalize key to match the v1 client (panel_id).
        if "panel_id" not in res and "surface_id" in res:
            res["panel_id"] = res.get("surface_id")
        return res

    def bonsplit_underflow_count(self) -> int:
        res = self._call("debug.bonsplit_underflow.count") or {}
        return int(res.get("count") or 0)

    def reset_bonsplit_underflow_count(self) -> None:
        self._call("debug.bonsplit_underflow.reset")

    def empty_panel_count(self) -> int:
        res = self._call("debug.empty_panel.count") or {}
        return int(res.get("count") or 0)

    def reset_empty_panel_count(self) -> None:
        self._call("debug.empty_panel.reset")

    def flash_count(self, surface: Union[str, int]) -> int:
        sid = self._resolve_surface_id(surface)
        res = self._call("debug.flash.count", {"surface_id": sid}) or {}
        return int(res.get("count") or 0)

    def reset_flash_counts(self) -> None:
        self._call("debug.flash.reset")

    def screenshot(self, label: str = "") -> dict:
        params: Dict[str, Any] = {}
        if label:
            params["label"] = label
        return dict(self._call("debug.window.screenshot", params) or {})


def main() -> None:
    import argparse

    parser = argparse.ArgumentParser(description="cmux v2 socket client")
    parser.add_argument("-s", "--socket", default=cmux.DEFAULT_SOCKET_PATH, help="Socket path")
    parser.add_argument("--method", help="v2 method name")
    parser.add_argument("--params", default="{}", help="JSON params")

    args = parser.parse_args()

    with cmux(args.socket) as c:
        if not args.method:
            # Minimal smoke.
            print(json.dumps(c.capabilities(), indent=2, sort_keys=True))
            return
        params = json.loads(args.params)
        print(json.dumps(c._call(args.method, params), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
