#!/usr/bin/env python3
from __future__ import annotations

import argparse
import atexit
import json
import os
import sys
import time
from typing import Any, Optional


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tests_v2"))

from cmux import cmux, cmuxError  # type: ignore

PREVIEW_REFRESH_INTERVAL_MS = 5_000


def daemonize(pid_file: str | None, log_file: str | None) -> None:
    first_pid = os.fork()
    if first_pid > 0:
        os.waitpid(first_pid, 0)
        raise SystemExit(0)

    os.setsid()

    second_pid = os.fork()
    if second_pid > 0:
        os._exit(0)

    os.chdir("/")
    os.umask(0)

    stdin_fd = os.open(os.devnull, os.O_RDONLY)
    try:
        os.dup2(stdin_fd, 0)
    finally:
        os.close(stdin_fd)

    if log_file:
        log_fd = os.open(log_file, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    else:
        log_fd = os.open(os.devnull, os.O_WRONLY)
    try:
        os.dup2(log_fd, 1)
        os.dup2(log_fd, 2)
    finally:
        if log_fd > 2:
            os.close(log_fd)

    write_pid_file(pid_file)


def write_pid_file(pid_file: str | None) -> None:
    if not pid_file:
        return

    with open(pid_file, "w", encoding="utf-8") as handle:
        handle.write(f"{os.getpid()}\n")

    def cleanup() -> None:
        try:
            os.remove(pid_file)
        except FileNotFoundError:
            pass

    atexit.register(cleanup)


def extract_preview(text: str) -> str:
    lines = [line.strip() for line in text.splitlines()]
    meaningful = [
        line for line in lines
        if line and not line.startswith("Last login:")
    ]
    if not meaningful:
        return "No recent activity"
    return meaningful[-1]


def choose_surface_id(client: cmux, workspace_id: str) -> Optional[str]:
    surfaces = client.list_surfaces(workspace_id)
    if not surfaces:
        return None
    for _, surface_id, focused in surfaces:
        if focused:
            return surface_id
    return surfaces[0][1]


def read_preview(client: cmux, surface_id: str) -> str:
    try:
        return extract_preview(client.read_terminal_text(surface_id))
    except Exception:
        return "No recent activity"


def build_payload(
    client: cmux,
    relay_port: int,
    machine_id: str,
    auto_open: bool,
    sort_dates_ms: dict[str, int],
    preview_cache: dict[str, str],
    preview_refresh_ms: dict[str, int],
) -> dict[str, Any]:
    workspaces = client.list_workspaces()
    try:
        current_workspace_id = client.current_workspace()
    except Exception:
        current_workspace_id = workspaces[0][1] if workspaces else ""
    now_ms = int(time.time() * 1000)
    next_sort_ms = now_ms
    active_workspace_ids = {workspace_id for _, workspace_id, _, _ in workspaces}
    stale_workspace_ids = [workspace_id for workspace_id in sort_dates_ms if workspace_id not in active_workspace_ids]
    for workspace_id in stale_workspace_ids:
        sort_dates_ms.pop(workspace_id, None)
        preview_cache.pop(workspace_id, None)
        preview_refresh_ms.pop(workspace_id, None)

    workspace_items: list[dict[str, Any]] = []
    current_surface_id = ""

    for index, workspace_id, title, selected in workspaces:
        surface_id = choose_surface_id(client, workspace_id)
        if not surface_id:
            continue
        if workspace_id not in sort_dates_ms:
            sort_dates_ms[workspace_id] = next_sort_ms - index
        refresh_due = (
            workspace_id not in preview_cache or
            workspace_id not in preview_refresh_ms or
            (now_ms - preview_refresh_ms[workspace_id]) >= PREVIEW_REFRESH_INTERVAL_MS
        )
        if refresh_due:
            preview_cache[workspace_id] = read_preview(client, surface_id)
            preview_refresh_ms[workspace_id] = now_ms
        if workspace_id == current_workspace_id or (selected and not current_surface_id):
            current_surface_id = surface_id
        workspace_items.append({
            "workspace_id": workspace_id,
            "session_id": surface_id,
            "machine_id": machine_id,
            "title": title.strip() or surface_id,
            "preview": preview_cache.get(workspace_id, "No recent activity"),
            "accessory_label": "Desktop",
            "unread_count": 0,
            "sort_date_ms": sort_dates_ms[workspace_id],
        })

    if not current_surface_id and workspace_items:
        current_surface_id = str(workspace_items[0]["session_id"])

    payload: dict[str, Any] = {
        "host": "127.0.0.1",
        "port": relay_port,
        "session_id": current_surface_id,
        "workspace_items": workspace_items,
    }
    if auto_open and current_surface_id:
        payload["auto_open_session_id"] = current_surface_id
    return payload


def write_payload(path: str, payload: dict[str, Any]) -> None:
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app-socket", required=True)
    parser.add_argument("--config-path", required=True)
    parser.add_argument("--relay-port", type=int, required=True)
    parser.add_argument("--machine-id", required=True)
    parser.add_argument("--auto-open", action="store_true")
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--poll-interval", type=float, default=0.5)
    parser.add_argument("--daemonize", action="store_true")
    parser.add_argument("--pid-file")
    parser.add_argument("--log-file")
    args = parser.parse_args()

    client = cmux(args.app_socket)
    last_payload = ""
    sort_dates_ms: dict[str, int] = {}
    preview_cache: dict[str, str] = {}
    preview_refresh_ms: dict[str, int] = {}

    if args.daemonize:
        daemonize(pid_file=args.pid_file, log_file=args.log_file)
    elif args.pid_file:
        write_pid_file(args.pid_file)

    try:
        while True:
            try:
                client.connect()
                payload = build_payload(
                    client,
                    relay_port=args.relay_port,
                    machine_id=args.machine_id,
                    auto_open=args.auto_open,
                    sort_dates_ms=sort_dates_ms,
                    preview_cache=preview_cache,
                    preview_refresh_ms=preview_refresh_ms,
                )
                encoded = json.dumps(payload, separators=(",", ":"), sort_keys=True)
                if encoded != last_payload:
                    write_payload(args.config_path, payload)
                    last_payload = encoded
                    current_session = payload.get("session_id", "")
                    print(
                        f"updated items={len(payload.get('workspace_items', []))} "
                        f"current_session={current_session}"
                    )
                    sys.stdout.flush()
                if args.once:
                    return 0
            except (cmuxError, OSError, json.JSONDecodeError) as exc:
                print(f"warning: sync failed: {exc}", file=sys.stderr)
                sys.stderr.flush()
            finally:
                client.close()

            if args.once:
                return 1
            time.sleep(args.poll_interval)
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
