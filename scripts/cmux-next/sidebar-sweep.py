#!/usr/bin/env python3
"""Sidebar sweep (scratch, not for merge): seed groups and workspaces, then snapshot the
cmux NEXT sidebar in light, dark and glass: rows, hover cards, the overflow menu,
collapse and a held drag. Runs under `nx-remote --needs gui --app-from-fleet cmux`.
Every step writes a PNG and a JSON line to $NX_ARTIFACTS/sweep/."""
import json
import os
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(__file__))
journey = __import__("launch-connect-journey")
Client, connect, Tag, Launch = journey.Client, journey.connect, journey.Tag, journey.Launch

OUT = os.path.join(os.environ.get("NX_ARTIFACTS", "."), "sweep")
os.makedirs(OUT, exist_ok=True)
LOG = open(os.path.join(OUT, "steps.jsonl"), "a")


def log(step, **data):
    data["step"] = step
    LOG.write(json.dumps(data, default=str) + "\n")
    LOG.flush()
    print(step, json.dumps(data, default=str)[:400], flush=True)


class Args:
    out = OUT


def app_call(tag, method, params=None):
    client = connect(tag.socket, 20)
    try:
        return client.call(method, params or {})
    finally:
        client.close()


def raw(tag, op, params, key=None):
    args = ["raw", "operation", op, "--params-json", json.dumps(params)]
    if key:
        args += ["--mutation", "--idempotency-key", key]
    code, reply, err = tag.tui_json(*args)
    log("raw", op=op, params=params, code=code, reply=reply, err=err[-300:])
    return reply


def result(reply):
    return (reply or {}).get("result") or (reply or {}).get("data") or reply


def seed(tag):
    groups = {}
    for name, color in [("Work", "#3b82f6"), ("Infra", "#22c55e"), ("Empty group", None)]:
        params = {"name": name}
        if color:
            params["color"] = color
        reply = result(raw(tag, "workspace_group.create", params, f"sweep-group-{name}"))
        groups[name] = (reply or {}).get("id")
    placements = [("api-server", "Work"), ("web-client", "Work"), ("docs", "Work"),
                  ("deploy", "Infra"), ("scratch", None), ("a workspace with a rather long name that truncates", None)]
    for name, group in placements:
        created = result(raw(tag, "workspace.create", {"name": name, "initial_content": "terminal"}, f"sweep-ws-{name}"))
        workspace = (created or {}).get("workspace_id") or (created or {}).get("id")
        if isinstance(created, dict) and isinstance(created.get("workspace"), dict):
            workspace = created["workspace"].get("workspace_id") or created["workspace"].get("id")
        if group and workspace and groups.get(group):
            raw(tag, "workspace.place", {"workspace": workspace, "group": groups[group]}, f"sweep-place-{name}")
    return groups


def snap(tag, name):
    path = os.path.join(OUT, f"{name}.png")
    reply = app_call(tag, "debug.window_snapshot", {"kind": "main", "path": path, "webviews": False})
    log("snap", name=name, ok=reply.get("ok"), result=reply.get("result"), error=reply.get("error"))


def rows(tag, name):
    reply = app_call(tag, "debug.sidebar_rows", {})
    with open(os.path.join(OUT, f"rows-{name}.json"), "w") as out:
        json.dump(reply, out, indent=1, default=str)
    return reply.get("result") or {}


def mouse(tag, **params):
    reply = app_call(tag, "debug.mouse", params)
    log("mouse", params=params, ok=reply.get("ok"), error=reply.get("error"))
    return reply


def find_rows(report):
    """(kind, title, frame) for each sidebar row the report names, best effort over its shape."""
    found = []

    def walk(node):
        if isinstance(node, dict):
            frame = node.get("frame") or node.get("window_frame")
            title = node.get("title") or node.get("name") or node.get("label")
            if frame and title:
                found.append((node.get("kind") or node.get("type") or "", str(title), frame))
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    walk(report)
    return found


def center(frame):
    if isinstance(frame, dict):
        return frame.get("x", 0) + frame.get("width", 0) / 2, frame.get("y", 0) + frame.get("height", 0) / 2, frame
    if isinstance(frame, list) and len(frame) == 4:
        return frame[0] + frame[2] / 2, frame[1] + frame[3] / 2, {"x": frame[0], "y": frame[1], "width": frame[2], "height": frame[3]}
    return None


def sweep_variant(tag, variant, config, modes):
    with open(os.path.join(tag.scratch, "cmux.json"), "w") as out:
        json.dump(config, out)
    launch = Launch(tag)
    launch.wait_for(["workspace_content_shown", "sidebar_rows_shown"], 60)
    time.sleep(3)
    for mode in modes:
        app_call(tag, "debug.appearance", {"mode": mode})
        time.sleep(1.5)
        prefix = f"{variant}-{mode}"
        snap(tag, f"{prefix}-01-rest")
        report = rows(tag, prefix)
        listed = find_rows(report)
        log("rows", variant=prefix, rows=[(k, t, f) for k, t, f in listed][:40])
        by_title = {title: frame for _, title, frame in listed}
        for label, title in [("group-hover", "Work"), ("row-hover", "api-server"), ("empty-group-hover", "Empty group")]:
            point = center(by_title.get(title)) if title in by_title else None
            if not point:
                log("missing", title=title)
                continue
            x, y, frame = point
            mouse(tag, action="move", x=x, y=y)
            time.sleep(1.6)
            snap(tag, f"{prefix}-02-{label}")
            app_call(tag, "debug.hover_cards", {})
            if label == "row-hover":
                # The overflow button sits at the row's trailing edge.
                mouse(tag, action="click", x=frame["x"] + frame["width"] - 14, y=y)
                time.sleep(0.8)
                snap(tag, f"{prefix}-03-overflow-menu")
                app_call(tag, "debug.key", {"key": "escape"})
                time.sleep(0.4)
        mouse(tag, action="leave")
        if mode == modes[0] and "api-server" in by_title and "deploy" in by_title:
            x0, y0, _ = center(by_title["api-server"])
            x1, y1, _ = center(by_title["deploy"])
            mouse(tag, action="drag", x=x0, y=y0, to_x=x1, to_y=y1 + 4, steps=12, release=False)
            time.sleep(0.6)
            snap(tag, f"{prefix}-04-drag-held")
            mouse(tag, action="up", x=x0, y=y0)
            time.sleep(0.6)
        if "Work" in by_title:
            x, y, _ = center(by_title["Work"])
            mouse(tag, action="click", x=x, y=y)
            time.sleep(0.8)
            snap(tag, f"{prefix}-05-work-toggled")
            mouse(tag, action="click", x=x, y=y)
            time.sleep(0.6)
    launch.quit_keep_sessions()


def main():
    tag = Tag(Args)
    first = Launch(tag)
    first.wait_for(["workspace_content_shown"], 90)
    time.sleep(2)
    groups = seed(tag)
    log("seeded", groups=groups)
    time.sleep(2)
    first.quit_keep_sessions()
    sweep_variant(tag, "opaque", {}, ["light", "dark"])
    sweep_variant(tag, "glass", {"appearance": {"glassTransparency": 0.35, "backgroundBlur": "glass"}}, ["dark", "light"])
    stop = os.environ.get("NX_APP_STOP")
    if stop:
        subprocess.run([stop], timeout=180)


if __name__ == "__main__":
    main()
