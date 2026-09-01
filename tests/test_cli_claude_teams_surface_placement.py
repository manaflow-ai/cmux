#!/usr/bin/env python3
"""Regression coverage for Claude Teams teammate tabs in the caller workspace."""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import json
import os
import socketserver
import subprocess
import tempfile
import threading
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli

WORKSPACE_ID = "11111111-1111-4111-8111-111111111111"
PANE_ID = "33333333-3333-4333-8333-333333333333"
LEADER_SURFACE_ID = "44444444-4444-4444-8444-444444444444"
TEAMMATE_SURFACE_ID = "77777777-7777-4777-8777-777777777777"
OTHER_WORKSPACE_ID = "22222222-2222-4222-8222-222222222222"
ALIAS_SURFACE_ID = "88888888-8888-4888-8888-888888888888"
CONCURRENT_SURFACE_IDS = (
    "99999999-9999-4999-8999-999999999999",
    "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
)


class FakeState:
    def __init__(self, workspaces: list[dict[str, object]] | None = None) -> None:
        self.requests: list[tuple[str, dict[str, object]]] = []
        self.workspaces = workspaces or [
            {"id": WORKSPACE_ID, "ref": "workspace:1", "index": 1, "title": "team"}
        ]
        self.surface_create_lock = threading.Lock()
        self.surface_create_count = 0
        self.surfaces = [
            {
                "id": LEADER_SURFACE_ID,
                "ref": "surface:1",
                "pane_id": PANE_ID,
                "workspace_id": WORKSPACE_ID,
                "title": "leader",
            }
        ]

    def handle(self, method: str, params: dict[str, object]) -> dict[str, object]:
        self.requests.append((method, dict(params)))
        if method == "system.identify":
            return {
                "focused": {
                    "workspace_id": WORKSPACE_ID,
                    "pane_id": PANE_ID,
                    "surface_id": LEADER_SURFACE_ID,
                }
            }
        if method == "workspace.list":
            return {"workspaces": [dict(workspace) for workspace in self.workspaces]}
        if method == "pane.list":
            return {"panes": [{"id": PANE_ID, "ref": "pane:1", "index": 0}]}
        if method == "surface.current":
            return {
                "workspace_id": WORKSPACE_ID,
                "pane_id": PANE_ID,
                "surface_id": LEADER_SURFACE_ID,
            }
        if method == "surface.list":
            workspace_id = params.get("workspace_id")
            surfaces = [
                surface for surface in self.surfaces
                if workspace_id is None or surface.get("workspace_id", WORKSPACE_ID) == workspace_id
            ]
            return {"surfaces": [dict(surface) for surface in surfaces]}
        if method == "surface.create":
            with self.surface_create_lock:
                created_surface_id = (
                    TEAMMATE_SURFACE_ID
                    if self.surface_create_count == 0
                    else CONCURRENT_SURFACE_IDS[(self.surface_create_count - 1) % len(CONCURRENT_SURFACE_IDS)]
                )
                self.surface_create_count += 1
            self.surfaces.append(
                {
                    "id": created_surface_id,
                    "ref": "surface:2",
                    "pane_id": PANE_ID,
                    "workspace_id": WORKSPACE_ID,
                    "title": "teammate",
                }
            )
            return {
                "workspace_id": WORKSPACE_ID,
                "pane_id": PANE_ID,
                "surface_id": created_surface_id,
            }
        if method == "pane.surfaces":
            workspace_id = params.get("workspace_id")
            pane_id = params.get("pane_id")
            surfaces = [
                dict(surface) for surface in self.surfaces
                if surface.get("workspace_id", WORKSPACE_ID) == workspace_id
                and surface.get("pane_id") == pane_id
            ]
            if surfaces:
                surfaces[0]["selected"] = True
            return {"surfaces": surfaces}
        if method in {
            "surface.send_text",
            "surface.respawn",
            "surface.focus",
            "surface.close",
            "workspace.select",
            "workspace.close",
            "workspace.equalize_splits",
        }:
            return {"ok": True}
        raise RuntimeError(f"unsupported method: {method}")


class FakeServer(socketserver.ThreadingUnixStreamServer):
    allow_reuse_address = True

    def __init__(self, path: str, state: FakeState) -> None:
        self.state = state
        super().__init__(path, FakeHandler)


class FakeHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        while line := self.rfile.readline():
            decoded = line.decode("utf-8").rstrip("\r\n")
            capability_prefix = "_cmux_capability_v1 "
            if decoded.startswith(capability_prefix):
                envelope_parts = decoded.split(" ", 2)
                if len(envelope_parts) != 3 or not envelope_parts[1] or not envelope_parts[2]:
                    self.wfile.write(b"ERROR: malformed capability envelope\n")
                    self.wfile.flush()
                    continue
                decoded = envelope_parts[2]
            if decoded.startswith("auth "):
                self.wfile.write(b"OK\n")
                self.wfile.flush()
                continue
            request = json.loads(decoded)
            try:
                result = self.server.state.handle(  # type: ignore[attr-defined]
                    request["method"], request.get("params", {})
                )
                response = {"ok": True, "result": result, "id": request.get("id")}
            except Exception as exc:
                response = {
                    "ok": False,
                    "error": {"code": "not_found", "message": str(exc)},
                    "id": request.get("id"),
                }
            self.wfile.write((json.dumps(response) + "\n").encode("utf-8"))
            self.wfile.flush()


def run_cli(
    cli_path: str,
    socket_path: Path,
    home: Path,
    args: list[str],
    placement: str | None = "surface",
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.update(
        {
            "HOME": str(home),
            "CMUX_SOCKET_PATH": str(socket_path),
            "CMUX_WORKSPACE_ID": WORKSPACE_ID,
            "CMUX_SURFACE_ID": LEADER_SURFACE_ID,
            "TMUX_PANE": "%pane:1",
            "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
            # This is the launch snapshot that the claude-teams wrapper passes
            # to its tmux compatibility child and restored teammate processes.
        }
    )
    if placement is not None:
        env["CMUX_CLAUDE_TEAMS_SPAWN_PLACEMENT"] = placement
    return subprocess.run(
        [cli_path, "--socket", str(socket_path), *args],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=30,
    )


def write_alias_store(home: Path, alias: str, workspace_id: str, surface_id: str) -> Path:
    store_directory = home / ".cmuxterm"
    store_directory.mkdir(parents=True, exist_ok=True)
    store_path = store_directory / "tmux-compat-store.json"
    store_path.write_text(
        json.dumps(
            {
                "surfaceAliases": {
                    alias: {"workspaceId": workspace_id, "surfaceId": surface_id}
                }
            }
        ),
        encoding="utf-8",
    )
    return store_path


def assert_stale_alias_fails(
    cli_path: str,
    socket_path: Path,
    home: Path,
    state: FakeState,
    alias: str,
    command: list[str],
) -> None:
    before = len(state.requests)
    result = run_cli(cli_path, socket_path, home, command, placement=None)
    if result.returncode == 0:
        raise AssertionError(f"stale alias unexpectedly succeeded for {command!r}")
    mutations = {
        "workspace.select",
        "workspace.close",
        "surface.focus",
        "surface.close",
        "surface.respawn",
    }
    observed = [method for method, _ in state.requests[before:] if method in mutations]
    if observed:
        raise AssertionError(f"stale alias mutated state via {observed!r}")
    store_path = home / ".cmuxterm" / "tmux-compat-store.json"
    if store_path.exists():
        aliases = json.loads(store_path.read_text(encoding="utf-8")).get("surfaceAliases", {})
        if alias in aliases:
            raise AssertionError(f"stale alias was not removed for {command!r}")


def run_alias_freshness_regressions(cli_path: str) -> None:
    alias = "%cmux-surface-" + ALIAS_SURFACE_ID
    with tempfile.TemporaryDirectory(prefix="cmux-claude-teams-alias-") as td:
        root = Path(td)
        socket_path = root / "cmux.sock"
        home = root / "home"
        home.mkdir()
        state = FakeState()
        server = FakeServer(str(socket_path), state)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            # A cold store must not let the UUID-shaped token fall through to
            # normal pane/workspace resolution.
            cold = run_cli(
                cli_path,
                socket_path,
                home,
                ["__tmux-compat", "has-session", "-t", alias],
                placement=None,
            )
            if cold.returncode == 0:
                raise AssertionError("cold alias unexpectedly resolved")
            if any(method in {"workspace.select", "workspace.close"} for method, _ in state.requests):
                raise AssertionError("cold alias mutated a workspace")

            # A corrupt store must fail closed rather than silently treating the
            # embedded UUID as a physical pane ID.
            corrupt_directory = home / ".cmuxterm"
            corrupt_directory.mkdir(parents=True, exist_ok=True)
            (corrupt_directory / "tmux-compat-store.json").write_text("{not-json", encoding="utf-8")
            corrupt_before = len(state.requests)
            corrupt = run_cli(
                cli_path,
                socket_path,
                home,
                ["__tmux-compat", "select-window", "-t", alias],
                placement=None,
            )
            if corrupt.returncode == 0:
                raise AssertionError("corrupt alias store unexpectedly resolved")
            if any(
                method in {"workspace.select", "workspace.close"}
                for method, _ in state.requests[corrupt_before:]
            ):
                raise AssertionError("corrupt alias mutated a workspace")

            # A live workspace without the mapped surface is stale. Exercise
            # every workspace-target entrypoint and the surface respawn path.
            for command in [
                ["__tmux-compat", "select-window", "-t", alias],
                ["__tmux-compat", "kill-window", "-t", alias],
                ["__tmux-compat", "has-session", "-t", alias],
                ["__tmux-compat", "respawn-pane", "-k", "-t", alias, "echo", "again"],
            ]:
                write_alias_store(home, alias, WORKSPACE_ID, ALIAS_SURFACE_ID)
                assert_stale_alias_fails(cli_path, socket_path, home, state, alias, command)

            # A surface moved to another workspace is also stale: the stored
            # workspace remains the authority and must not be replaced by a
            # best-effort search elsewhere.
            moved_state = FakeState(
                workspaces=[
                    {"id": WORKSPACE_ID, "ref": "workspace:1", "index": 1, "title": "team"},
                    {"id": OTHER_WORKSPACE_ID, "ref": "workspace:2", "index": 2, "title": "moved"},
                ]
            )
            moved_state.surfaces.append(
                {
                    "id": ALIAS_SURFACE_ID,
                    "ref": "surface:2",
                    "pane_id": PANE_ID,
                    "workspace_id": OTHER_WORKSPACE_ID,
                    "title": "moved teammate",
                }
            )
            server.state = moved_state
            for command in [
                ["__tmux-compat", "select-window", "-t", alias],
                ["__tmux-compat", "kill-window", "-t", alias],
                ["__tmux-compat", "has-session", "-t", alias],
                ["__tmux-compat", "respawn-pane", "-k", "-t", alias, "echo", "again"],
            ]:
                write_alias_store(home, alias, WORKSPACE_ID, ALIAS_SURFACE_ID)
                assert_stale_alias_fails(cli_path, socket_path, home, moved_state, alias, command)

            # A workspace that disappeared is stale even when another workspace
            # remains available; never retarget the synthetic token by UUID.
            missing_workspace_state = FakeState(workspaces=[])
            server.state = missing_workspace_state
            for command in [
                ["__tmux-compat", "select-window", "-t", alias],
                ["__tmux-compat", "kill-window", "-t", alias],
                ["__tmux-compat", "has-session", "-t", alias],
                ["__tmux-compat", "respawn-pane", "-k", "-t", alias, "echo", "again"],
            ]:
                write_alias_store(home, alias, WORKSPACE_ID, ALIAS_SURFACE_ID)
                assert_stale_alias_fails(
                    cli_path, socket_path, home, missing_workspace_state, alias, command
                )
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)


def run_concurrent_alias_write_regression(cli_path: str) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-teams-concurrent-") as td:
        root = Path(td)
        socket_path = root / "cmux.sock"
        home = root / "home"
        home.mkdir()
        state = FakeState()
        server = FakeServer(str(socket_path), state)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            command = [
                "__tmux-compat",
                "new-window",
                "-d",
                "-P",
                "-F",
                "#{pane_id}",
                "--",
                "echo",
                "parallel",
            ]
            with ThreadPoolExecutor(max_workers=2) as executor:
                results = list(
                    executor.map(
                        lambda _: run_cli(cli_path, socket_path, home, command, placement="surface"),
                        range(2),
                    )
                )
            if any(result.returncode != 0 for result in results):
                raise AssertionError(f"concurrent new-window failed: {[result.stderr for result in results]!r}")
            aliases = [result.stdout.strip() for result in results]
            store_path = home / ".cmuxterm" / "tmux-compat-store.json"
            stored_aliases = json.loads(store_path.read_text(encoding="utf-8"))["surfaceAliases"]
            if not set(aliases).issubset(stored_aliases) or len(stored_aliases) != 2:
                raise AssertionError(f"concurrent alias writes lost an entry: {stored_aliases!r}")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    with tempfile.TemporaryDirectory(prefix="cmux-claude-teams-surface-") as td:
        root = Path(td)
        socket_path = root / "cmux.sock"
        home = root / "home"
        home.mkdir()
        state = FakeState()
        server = FakeServer(str(socket_path), state)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            created = run_cli(
                cli_path,
                socket_path,
                home,
                ["__tmux-compat", "new-window", "-d", "-P", "-F", "#{pane_id}", "--", "echo", "ready"],
            )
            if created.returncode != 0:
                print(f"FAIL: new-window failed: {created.stderr.strip()}")
                return 1

            alias = created.stdout.strip()
            if not alias.startswith("%cmux-surface-"):
                print(f"FAIL: expected a cmux surface pane alias, got {alias!r}")
                return 1

            create_requests = [params for method, params in state.requests if method == "surface.create"]
            if len(create_requests) != 1:
                print(f"FAIL: expected one surface.create, got {create_requests!r}")
                return 1
            create_params = create_requests[0]
            if create_params.get("workspace_id") != WORKSPACE_ID or create_params.get("pane_id") != PANE_ID:
                print(f"FAIL: surface.create targeted the wrong container: {create_params!r}")
                return 1
            startup_environment = create_params.get("startup_environment")
            if not isinstance(startup_environment, dict) or startup_environment.get("TMUX_PANE") != alias:
                print(f"FAIL: teammate surface did not receive TMUX_PANE={alias!r}: {create_params!r}")
                return 1
            if any(method == "workspace.create" for method, _ in state.requests):
                print("FAIL: surface placement unexpectedly created a sibling workspace")
                return 1

            respawned = run_cli(
                cli_path,
                socket_path,
                home,
                ["__tmux-compat", "respawn-pane", "-k", "-t", alias, "echo", "again"],
                placement=None,
            )
            if respawned.returncode != 0:
                print(f"FAIL: alias respawn failed: {respawned.stderr.strip()}")
                return 1
            respawn_requests = [params for method, params in state.requests if method == "surface.respawn"]
            if not respawn_requests or respawn_requests[-1].get("surface_id") != TEAMMATE_SURFACE_ID:
                print(f"FAIL: alias respawn targeted the wrong surface: {respawn_requests!r}")
                return 1
            if "CMUX_CLAUDE_TEAMS_SPAWN_PLACEMENT='surface'" not in str(respawn_requests[-1].get("command", "")):
                print(f"FAIL: alias respawn did not preserve surface placement: {respawn_requests!r}")
                return 1

            targeted_before = len(state.requests)
            targeted = run_cli(
                cli_path,
                socket_path,
                home,
                ["__tmux-compat", "new-window", "-t", "workspace:1", "echo", "ignored"],
                placement="surface",
            )
            if targeted.returncode == 0:
                print("FAIL: surface-placement new-window accepted unsupported -t")
                return 1
            if any(
                method in {"surface.create", "workspace.create"}
                for method, _ in state.requests[targeted_before:]
            ):
                print("FAIL: unsupported -t triggered a placement mutation")
                return 1
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    try:
        run_alias_freshness_regressions(cli_path)
        run_concurrent_alias_write_regression(cli_path)
    except AssertionError as exc:
        print(f"FAIL: alias freshness regression: {exc}")
        return 1

    print("PASS: Claude Teams can spawn teammate surfaces in the caller workspace")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
