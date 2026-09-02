#!/usr/bin/env python3
"""Regression coverage for Claude Teams teammate tabs in the caller workspace."""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import json
import shlex
import tempfile
import threading
from pathlib import Path

from claude_teams_surface_placement_test_support import (
    ALIAS_SURFACE_ID,
    FakeServer,
    FakeState,
    OTHER_WORKSPACE_ID,
    PANE_ID,
    run_targetless_window_action_regressions,
    TEAMMATE_SURFACE_ID,
    WORKSPACE_ID,
    run_cli,
)
from claude_teams_test_utils import resolve_cmux_cli


def shell_export_value(command: object, key: str) -> str | None:
    """Return an exported value from a shell-wrapped command."""
    if not isinstance(command, str):
        return None
    try:
        argv = shlex.split(command)
    except ValueError:
        return None
    if len(argv) < 3 or argv[0] != "/bin/sh" or argv[1] != "-lc":
        return None
    for statement in argv[2].split(";"):
        try:
            tokens = shlex.split(statement.strip())
        except ValueError:
            continue
        if len(tokens) == 2 and tokens[0] == "export" and tokens[1].startswith(f"{key}="):
            return tokens[1][len(key) + 1 :]
    return None


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


def assert_surface_window_action(
    cli_path: str,
    socket_path: Path,
    home: Path,
    state: FakeState,
    alias: str,
    command: list[str],
    expected_method: str,
    forbidden_method: str,
    expected_params: dict[str, object] | None = None,
) -> None:
    before = len(state.requests)
    result = run_cli(cli_path, socket_path, home, command, placement=None)
    if result.returncode != 0:
        raise AssertionError(f"{command[1]} failed: {result.stderr.strip()}")
    expected = {
        "workspace_id": WORKSPACE_ID,
        "surface_id": TEAMMATE_SURFACE_ID,
    }
    expected.update(expected_params or {})
    requests = state.requests[before:]
    if not any(
        method == expected_method
        and all(params.get(key) == value for key, value in expected.items())
        for method, params in requests
    ):
        raise AssertionError(
            f"{command[1]} did not use {expected_method} with {expected!r}: {requests!r}"
        )
    if any(method == forbidden_method for method, _ in requests):
        raise AssertionError(f"{command[1]} incorrectly used {forbidden_method}: {requests!r}")


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


def run_alias_persistence_failure_regression(cli_path: str) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-teams-store-failure-") as td:
        root = Path(td)
        socket_path = root / "cmux.sock"
        home = root / "home"
        home.mkdir()
        (home / ".cmuxterm").write_text("blocks alias store creation", encoding="utf-8")
        state = FakeState()
        server = FakeServer(str(socket_path), state)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            result = run_cli(
                cli_path,
                socket_path,
                home,
                ["__tmux-compat", "new-window", "-d", "--", "echo", "orphan"],
            )
            if result.returncode == 0:
                raise AssertionError("new-window succeeded despite an unwritable alias store")
            closes = [params for method, params in state.requests if method == "surface.close"]
            if not closes or closes[-1] != {
                "workspace_id": WORKSPACE_ID,
                "surface_id": TEAMMATE_SURFACE_ID,
            }:
                raise AssertionError(f"alias persistence failure leaked its surface: {state.requests!r}")
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
            placement = shell_export_value(
                respawn_requests[-1].get("command"),
                "CMUX_CLAUDE_TEAMS_SPAWN_PLACEMENT",
            )
            if placement != "surface":
                print(f"FAIL: alias respawn did not preserve surface placement: {respawn_requests!r}")
                return 1

            assert_surface_window_action(
                cli_path,
                socket_path,
                home,
                state,
                alias,
                ["__tmux-compat", "select-window", "-t", alias],
                "surface.focus",
                "workspace.select",
            )
            assert_surface_window_action(
                cli_path,
                socket_path,
                home,
                state,
                alias,
                ["__tmux-compat", "rename-window", "-t", alias, "reviewed teammate"],
                "tab.action",
                "workspace.rename",
                {"action": "rename", "title": "reviewed teammate"},
            )

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
            assert_surface_window_action(
                cli_path,
                socket_path,
                home,
                state,
                alias,
                ["__tmux-compat", "kill-window", "-t", alias],
                "surface.close",
                "workspace.close",
            )
            stored_aliases = json.loads(
                (home / ".cmuxterm" / "tmux-compat-store.json").read_text(encoding="utf-8")
            ).get("surfaceAliases", {})
            if alias in stored_aliases:
                print(f"FAIL: kill-window left its surface alias behind: {stored_aliases!r}")
                return 1
        except AssertionError as exc:
            print(f"FAIL: surface window action regression: {exc}")
            return 1
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    try:
        run_targetless_window_action_regressions(cli_path)
        run_alias_freshness_regressions(cli_path)
        run_concurrent_alias_write_regression(cli_path)
        run_alias_persistence_failure_regression(cli_path)
    except AssertionError as exc:
        print(f"FAIL: surface placement regression: {exc}")
        return 1

    print("PASS: Claude Teams can spawn teammate surfaces in the caller workspace")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
