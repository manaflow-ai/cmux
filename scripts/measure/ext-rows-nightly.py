#!/usr/bin/env python3
"""The app half of scripts/measure/ext-rows-nightly.sh: a NIGHTLY read-back of extension rows closed in code.

    ext-rows-nightly.py --app APP --pid-file F --customize DIR --out DIR [--rows a,b,...]
    ext-rows-nightly.py --cli CMUX --daemon-socket S --customize DIR --out DIR [--rows ...]   (no Mac app)

APP is a running side-instance copy of the NIGHTLY (its own bundle id, data, daemon and customize folder; the
person's own app is never asked anything). Everything goes through the copy's own bundled CLI: `cmux ext new`,
`cmux ext shot --json`, `cmux settings set`, and the daemon ops through `cmux-tui raw command` (the same binary
under the name that has the `raw` scope; a direct socket line when that name refuses). The Mac app's control
socket is used only for what the CLI has no verb for (an action run, `apps.views`, `snapshot.get`), found by
the copy's pid. No clicks.

A row is one function `row_<name>(ctx) -> dict` in ROWS. It installs or scaffolds a sample (an extension's
manifest written to the copy's own customize folder installs it with no consent card: the customize app is
the person's own, cmux-tui-core apps/local_reload.rs), performs the row's action, and returns `ok` plus the
evidence (op answers, the `ext shot --json` scene, the window's `apps.views` words). A later row is one more
function and one more ROWS entry. `--rows` picks some; a row that needs the Mac app is skipped without it.

Prints `EXT_ROWS_NIGHTLY {json}` (the receipt) and writes OUT/receipt.json. Exit 0 only when every row run passed.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CUSTOMIZE_APP = "local/customize"
# The kinds `ext new` made at the matrix re-score (cli/ext/scaffold.rs KINDS); the copy's own list wins.
KNOWN_KINDS = ["sidebar", "section", "session-info", "pane", "newtab", "widget", "command"]


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


# The side-instance plumbing ext-reload-nightly.py already has: the copy's control socket by pid, one CLI
# call with its JSON answer, the scene in an `ext shot --json` answer.
reload_nightly = load("ext_reload_nightly", ROOT / "scripts/measure/ext-reload-nightly.py")
cli_json, scene_of, control_socket = reload_nightly.cli_json, reload_nightly.scene_of, reload_nightly.control_socket


@dataclass
class Ctx:
    cli: Path
    daemon: str
    customize: Path
    work: Path
    control: str | None = None
    token: str = field(default_factory=lambda: f"rows{int(time.time())}")
    raw_cli: Path | None = None
    version_seq: int = 0
    mcp_config: Path | None = None
    # The side-instance copy and its pid file (none with --cli): a row that relaunches the copy needs both.
    app: Path | None = None
    pid_file: Path | None = None

    @property
    def globals_(self) -> list[str]:
        out = ["--socket", self.daemon]
        return out + (["--app-socket", self.control] if self.control else [])

    def ext(self, args: list[str], timeout: float = 300) -> dict:
        return cli_json(self.cli, self.globals_, args, timeout=timeout)

    def rpc(self, method: str, params: dict | None = None, timeout: float = 30):
        if not self.control:
            return {"error": "no Mac app control socket"}
        return reload_nightly.bench.rpc_at(self.control, method, params or {}, timeout=timeout)


# ---- daemon ops ----------------------------------------------------------------------------------------

def socket_op(path: str, request: dict, timeout: float = 15) -> dict:
    """One request line on the daemon socket and its reply (events skipped)."""
    request = {"id": "ext-rows", **request}
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(timeout)
    try:
        conn.connect(path)
        conn.sendall((json.dumps(request) + "\n").encode())
        buf = b""
        while True:
            chunk = conn.recv(1 << 20)
            if not chunk:
                return {"ok": False, "error": "socket closed before a reply"}
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                try:
                    value = json.loads(line)
                except ValueError:
                    continue
                if isinstance(value, dict) and value.get("id") == request["id"]:
                    return value
    except OSError as error:
        return {"ok": False, "error": f"socket: {error}"}
    finally:
        conn.close()


def op(ctx: Ctx, request: dict) -> dict:
    """A daemon op through the CLI (`cmux-tui raw command --request-json`), as `{ok, data | error, via}`."""
    if ctx.raw_cli:
        argv = [str(ctx.raw_cli), "--socket", ctx.daemon, "raw", "command", "--request-json",
                json.dumps({"id": "ext-rows", **request}), "--json"]
        try:
            run = subprocess.run(argv, capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired):
            run = None
        # `--json` prints the events the connection gets (`apps-changed`) as lines before the answer, and an
        # error as one envelope line on stderr.
        stdout = last_json(run.stdout, skip_events=True) if run else None
        if run and run.returncode == 0 and stdout is not None:
            return {"ok": True, "data": stdout, "via": "cli"}
        error = last_json(run.stderr) if run else None
        if run and run.returncode != 0 and isinstance(error, dict):
            return {"ok": False, "error": error, "via": "cli"}
    reply = socket_op(ctx.daemon, request)
    reply["via"] = "socket"
    return reply


def last_json(text: str, skip_events: bool = False):
    """The last line of `text` that is JSON (and not an `{event: ...}` line when `skip_events`)."""
    for line in reversed((text or "").strip().splitlines()):
        try:
            value = json.loads(line)
        except ValueError:
            continue
        if skip_events and isinstance(value, dict) and "event" in value:
            continue
        return value
    return None


def store_op(ctx: Ctx, name: str, args: dict | None = None) -> dict:
    return op(ctx, {"cmd": "apps-store", "op": name, "args": args or {}})


def app_record(ctx: Ctx, app: str = CUSTOMIZE_APP) -> dict | None:
    reply = op(ctx, {"cmd": "apps-list"})
    data = reply.get("data") or {}
    apps = data.get("apps") if isinstance(data, dict) else data
    for record in apps or []:
        if isinstance(record, dict) and record.get("id") == app:
            return record
    return None


def logs_with(ctx: Ctx, word: str, wait: float = 20, app: str = CUSTOMIZE_APP) -> list[str]:
    """The app's log lines holding `word` (`apps-logs`), waited for up to `wait` seconds."""
    deadline = time.monotonic() + wait
    while True:
        reply = op(ctx, {"cmd": "apps-logs", "app": app})
        lines = [str(line.get("message", line)) if isinstance(line, dict) else str(line)
                 for line in ((reply.get("data") or {}).get("lines") or [])]
        found = [line for line in lines if word in line]
        if found or time.monotonic() > deadline:
            return found[-5:]
        time.sleep(0.5)


def wait_for(probe, wait: float = 20, step: float = 0.5):
    deadline = time.monotonic() + wait
    while True:
        value = probe()
        if value or time.monotonic() > deadline:
            return value
        time.sleep(step)


# ---- samples -------------------------------------------------------------------------------------------

def install_customize(ctx: Ctx, manifest: dict, files: dict[str, str]) -> dict:
    """Writes a sample into the copy's customize folder (script first, manifest last, as a save would), asks
    the daemon to read it now (`apps-reload-local`), and waits until `apps-list` holds this version."""
    ctx.version_seq += 1
    version = f"1.0.{ctx.version_seq}"
    manifest = {"manifestVersion": 2, "id": CUSTOMIZE_APP, "version": version, "engines": {"cmux": "^2.0"},
                **manifest}
    for entry in ctx.customize.iterdir() if ctx.customize.exists() else []:
        shutil.rmtree(entry) if entry.is_dir() else entry.unlink()
    ctx.customize.mkdir(parents=True, exist_ok=True)
    for rel, text in files.items():
        path = ctx.customize / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    (ctx.customize / "cmux-app.json").write_text(json.dumps(manifest, indent=2))
    reload_reply = op(ctx, {"cmd": "apps-reload-local", "folders": [str(ctx.customize)]})
    record = wait_for(lambda: (r := app_record(ctx)) and r.get("version") == version and r, wait=30)
    installed = bool(record) and record.get("installed") is True
    return {"version": version, "reload": reload_reply, "installed": installed,
            "record": {k: record.get(k) for k in ("id", "version", "installed", "enabled", "hidden", "grants",
                                                  "web_pages") if k in record} if record else None}


def views(ctx: Ctx, interface: str | None = None) -> list[dict]:
    """The window's open views of the customize app (`apps.views`), non-preview, of `interface`."""
    reply = ctx.rpc("apps.views", {"app": CUSTOMIZE_APP}, timeout=10)
    found = reply.get("views") if isinstance(reply, dict) else None
    return [v for v in found or [] if not v.get("preview") and (interface is None or v.get("interface") == interface)]


# ---- rows ----------------------------------------------------------------------------------------------

def row_activation(ctx: Ctx) -> dict:
    """Background activation (#43018): an `onStartup` app with no view runs its top-level code; its log line
    (`apps-logs`) is the proof, and the window has no view of it open."""
    word = f"{ctx.token}-activated"
    install = install_customize(ctx, {"name": "Rows activation", "description": "Runs with no view.",
                                      "runtime": {"main": "main.js"}, "activation": ["onStartup"]},
                                {"main.js": f"console.log({json.dumps(word)});\nglobalThis.__cmuxAppExports = {{}};\n"})
    logged = logs_with(ctx, word)
    out = {"install": install, "log_lines": logged}
    checks = {"installed": install["installed"], "ran_with_no_view": bool(logged)}
    if ctx.control:
        out["views"] = views(ctx)
        checks["no_view_open"] = not out["views"]
    return {"checks": checks, **out}


def row_opener(ctx: Ctx) -> dict:
    """Link openers (#43007): a `cmux.opener/1` app takes a matching link (`apps-open-link`, the op a terminal
    link click sends) and its export runs with the URL; a link it does not match stays cmux's."""
    word = f"{ctx.token}-opened"
    url, other = f"https://rows-probe.example/browse/{ctx.token}", "https://other.example/x"
    install = install_customize(ctx, {
        "name": "Rows opener", "description": "Takes rows-probe links.", "runtime": {"main": "main.js"},
        "implements": {"cmux.opener/1": {"export": "openLink",
                                         "options": {"urls": ["https://rows-probe.example/browse/*"]}}}},
        {"main.js": ("function openLink(args) {\n"
                     f"  console.log({json.dumps(word)} + ' ' + args.url)\n  return {{}}\n}}\n"
                     "globalThis.__cmuxAppExports = { openLink }\n")})
    taken = op(ctx, {"cmd": "apps-open-link", "url": url})
    passed = op(ctx, {"cmd": "apps-open-link", "url": other})
    logged = logs_with(ctx, word)
    data, other_data = taken.get("data") or {}, passed.get("data") or {}
    return {"checks": {"installed": install["installed"],
                       "handled_by_app": data.get("handled") is True and data.get("app") == CUSTOMIZE_APP,
                       "export_ran_with_url": any(url in line for line in logged),
                       "other_link_not_taken": other_data.get("handled") is False},
            "install": install, "open_link": taken, "open_other": passed, "log_lines": logged,
            # Read at feat-cmux-next 12a69373c48: AppsClient.openLink's only caller is TerminalHostDelegate
            # (terminal link clicks); agent chat links go to LinkRouter, so no chat path reaches the opener.
            "chat_links": {"path": False, "why": "no chat link click reaches apps-open-link; only terminal links do"}}


def row_composer(ctx: Ctx) -> dict:
    """Composer slash commands (#43032) and `@` mentions (#49239): a `cmux.composer.command/1` command is in `apps.composer.list` (the
    `/` menu's source) and a `cmux.composer.mention/1` item answers `apps.composer.mentions`."""
    name = f"rows{ctx.token[-6:]}"
    install = install_customize(ctx, {"name": "Rows composer", "description": "A slash command and a mention.",
        "implements": {
            "cmux.composer.command/1": {"options": {"commands": [
                {"name": name, "description": "Rows probe", "insert": f"{ctx.token} slash"}]}},
            "cmux.composer.mention/1": {"options": {"prefix": "rowsprobe", "items": [
                {"id": "R-1", "label": f"R-1 {ctx.token}", "insert": "R-1"}]}}}}, {})
    listed = wait_for(lambda: (r := store_op(ctx, "apps.composer.list")) and
                      any(c.get("name") == name for c in (r.get("data") or {}).get("commands") or []) and r, wait=15) \
        or store_op(ctx, "apps.composer.list")
    mentions = store_op(ctx, "apps.composer.mentions", {"query": "r-1", "prefix": "rowsprobe"})
    commands = [c for c in (listed.get("data") or {}).get("commands") or [] if c.get("app") == CUSTOMIZE_APP]
    found = [m for m in (mentions.get("data") or {}).get("mentions") or [] if m.get("app") == CUSTOMIZE_APP]
    return {"checks": {"installed": install["installed"],
                       "slash_command_listed": any(c.get("name") == name for c in commands),
                       "mention_answered": any(m.get("id") == "R-1" for m in found)},
            "install": install, "commands": commands, "mentions": found,
            "composer_list_ok": listed.get("ok"), "mentions_ok": mentions.get("ok")}


def row_chat_widget(ctx: Ctx) -> dict:
    """Chat-widget routing (#43030, the daemon op only; the transcript does not draw it yet): a tool call whose
    name matches a `cmux.chat.widget/1` app routes to it (`apps.chat_widgets.route`); another does not."""
    install = install_customize(ctx, {
        "name": "Rows chat widget", "description": "A card for rowsprobe tools.", "runtime": {"main": "main.js"},
        "implements": {"cmux.chat.widget/1": {"export": "renderCard", "title": "Rows card", "symbol": "square",
                                              "options": {"tools": ["mcp__rowsprobe__*"]}}}},
        {"main.js": ("function renderCard() { return VStack([Text('rows card')]) }\n"
                     "globalThis.__cmuxAppExports = { renderCard }\n")})
    tool = store_op(ctx, "apps.chat_widgets.route", {"key": f"chat#{ctx.token}",
                                                     "tool": {"name": "mcp__rowsprobe__get_thing", "status": "completed"}})
    other = store_op(ctx, "apps.chat_widgets.route", {"key": f"chat#{ctx.token}-2", "tool": {"name": "other_tool"}})
    by_app = store_op(ctx, "apps.chat_widgets.route", {"key": f"m#{ctx.token}", "app": CUSTOMIZE_APP,
                                                       "props": {"n": 1}})
    widget = lambda r: (r.get("data") or {}).get("widget") if isinstance(r.get("data"), dict) else None  # noqa: E731
    return {"checks": {"installed": install["installed"],
                       "tool_routes_to_app": (widget(tool) or {}).get("app") == CUSTOMIZE_APP,
                       "other_tool_not_routed": tool.get("ok") is not False and other.get("ok") is True
                       and widget(other) is None,
                       "app_route_answers": (widget(by_app) or {}).get("app") == CUSTOMIZE_APP},
            "install": install, "route_tool": tool, "route_other": other, "route_app": by_app}


def row_newtab(ctx: Ctx) -> dict:
    """The New Tab page (#42998): with `tabs.newTabApp` naming a `cmux.newtab/1` app (`cmux settings set`), a
    new tab mounts it: the window's `apps.views` holds a cmux.newtab/1 view with its words, and the render
    export ran (`apps-logs`)."""
    word = f"{ctx.token} new tab"
    install = install_customize(ctx, {
        "name": "Rows new tab", "description": "A New Tab page.", "runtime": {"main": "main.js"},
        "implements": {"cmux.newtab/1": {"export": "renderNewTab", "title": "Rows new tab", "symbol": "house"}}},
        {"main.js": ("function renderNewTab() {\n"
                     f"  console.log({json.dumps(word)} + ' rendered')\n"
                     f"  return VStack([Panel({{ title: 'Rows' }}, [Text({json.dumps(word)})])])\n}}\n"
                     "globalThis.__cmuxAppExports = { renderNewTab }\n")})
    setting = ctx.ext(["settings", "set", "tabs.newTabApp", CUSTOMIZE_APP], timeout=30)
    opened = ctx.rpc("action.run", {"action": "workspace.newAtBottom", "focus": True}, timeout=30)
    shown = wait_for(lambda: [v for v in views(ctx, "cmux.newtab/1")
                              if any(word in t for t in v.get("texts") or [])], wait=20)
    logged = logs_with(ctx, word, wait=5)
    return {"checks": {"installed": install["installed"], "setting_set": setting.get("exit") == 0,
                       "new_tab_shows_page": bool(shown) or bool(logged)},
            "install": install, "settings_set": setting, "open": opened,
            "views": shown or views(ctx), "log_lines": logged}


row_newtab.needs_app = True


def row_web_pane(ctx: Ctx) -> dict:
    """Web panes (#41546 Rust, #43033 Mac host): a `cmux.pane/1` with `web` lists its page (`apps-list`
    `web_pages`) and `app.open` opens it as a page tab (`snapshot.get` topology holds `app:local/customize`)."""
    html = (f"<!doctype html><html><head><title>{ctx.token} web pane</title></head>"
            f"<body><h1>{ctx.token} web pane</h1></body></html>\n")
    install = install_customize(ctx, {
        "name": "Rows web pane", "description": "A web pane.", "runtime": {"web": {"root": "web"}},
        "implements": {"cmux.pane/1": {"web": "web/index.html", "title": "Rows web pane", "symbol": "globe"}},
        "activation": ["onInterface:cmux.pane/1"], "files": ["web/"]}, {"web/index.html": html})
    record = app_record(ctx) or {}
    pages = record.get("web_pages") or []
    opened = ctx.rpc("action.run", {"action": "app.open", "args": {"app": CUSTOMIZE_APP}}, timeout=30)
    tab = f"app:{CUSTOMIZE_APP}"
    snapshot = wait_for(lambda: (s := ctx.rpc("snapshot.get", {}, timeout=15)) and tab in json.dumps(s) and s,
                        wait=15)
    return {"checks": {"installed": install["installed"],
                       "web_page_listed": any(p.get("interface") == "cmux.pane/1" for p in pages
                                              if isinstance(p, dict)),
                       "open_answered": isinstance(opened, dict) and "error" not in opened,
                       "page_tab_open": bool(snapshot)},
            "install": install, "web_pages": pages, "open": opened,
            "page_tab": find_tab(snapshot, tab) if snapshot else None,
            "note": "the page's own load is not observable from outside the app in a release build"}


row_web_pane.needs_app = True


def find_tab(value, page: str):
    if isinstance(value, dict):
        if value.get("page") == page:
            return value
        value = list(value.values())
    if isinstance(value, list):
        for item in value:
            found = find_tab(item, page)
            if found:
                return found
    return None


def new_kinds(ctx: Ctx) -> list[str]:
    """The kinds the copy's `ext new` makes, from its own refusal of an unknown kind (`--kind X: one of ...`)."""
    run = cli_json(ctx.cli, [], ["ext", "new", "rows-kinds", "--kind", "no-such-kind"], timeout=30)
    text = run.get("stderr") or run.get("output") or ""
    match = re.search(r"one of ([a-z, -]+)", text)
    kinds = [k.strip() for k in match.group(1).split(",") if k.strip()] if match else []
    return kinds or KNOWN_KINDS


def row_ext_new(ctx: Ctx) -> dict:
    """`ext new` for every kind (#43371, #44828, #44877): each scaffold is a git repo with a manifest, and
    `ext shot --json` loads it in the copy's daemon (`ext dev --once` with no install) and prints its scene."""
    kinds, per_kind = new_kinds(ctx), {}
    for kind in kinds:
        folder = ctx.work / f"new-{kind}"
        shutil.rmtree(folder, ignore_errors=True)
        made = ctx.ext(["ext", "new", f"rows-{kind}", "--kind", kind, "--dir", str(folder), "--json"], timeout=60)
        shot = ctx.ext(["ext", "shot", str(folder), "--json", "--out", str(ctx.work / f"new-{kind}.png")])
        answer = shot.get("json") if isinstance(shot.get("json"), dict) else {}
        # A preview loads with no picture (`phase: shot`, no errors). With the Mac app the scene must be drawn
        # too; a headless daemon (the Linux run) mounts no preview, so its scene is empty.
        loaded = answer.get("ok") is True or (answer.get("phase") == "shot" and not answer.get("errors"))
        loaded = loaded and (bool(scene_of(shot)) or not ctx.control or kind == "command")
        per_kind[kind] = {
            "ok": made.get("exit") == 0 and (folder / "cmux-app.json").is_file() and (folder / ".git").exists()
            and loaded,
            "new_exit": made.get("exit"), "repo": (folder / ".git").exists(),
            "load": {k: answer.get(k) for k in ("ok", "phase", "app", "errors", "placed", "web", "shot", "next")},
            "scene": scene_of(shot)[:20], "shot_exit": shot.get("exit"),
            **({"new_error": made.get("stderr") or made.get("output")} if made.get("exit") != 0 else {}),
            **({"shot_error": shot.get("stderr") or shot.get("output")} if not loaded else {})}
    return {"checks": {f"kind_{k}": v["ok"] for k, v in per_kind.items()} | {"kinds_listed": bool(kinds)},
            "kinds": kinds, "per_kind": per_kind}

SIDE = Path(__file__).resolve().parents[2] / "scripts/cmux-next/side-instance.sh"


def side_relaunch(ctx: Ctx, between=None) -> dict:
    """Stops the side copy (the app, its daemon and helpers), runs `between()` while nothing of it runs, launches
    it again and attaches ctx to the new control and daemon sockets."""
    name, side_root = ctx.pid_file.parent.name, ctx.pid_file.parent.parent
    env = os.environ | {"CMUX_SIDE_ROOT": str(side_root)}
    stop = subprocess.run([str(SIDE), "stop", name], capture_output=True, text=True, env=env, timeout=120)
    done = between() if between else None
    launch = subprocess.run([str(SIDE), "launch", name], capture_output=True, text=True, env=env, timeout=180)
    ctx.control, ctx.daemon = attach_copy(ctx.app, ctx.cli, ctx.pid_file, ctx.control)
    return {"stop": stop.returncode, "between": done, "launch": launch.returncode,
            "launch_err": launch.stderr[-400:]}


def daemon_session_dirs(ctx: Ctx, since: float = 0.0) -> list[Path]:
    """The copy's daemon session folders: `builds/<key>/tui/<session>` of its own build key (the side marker's
    `key=`, cmux-agent-pane-policy build_identity.rs `daemon_state_dir`), where the apps supervisor keeps its
    state (cmux-tui-core apps.rs `session_state_directory`)."""
    marker = (ctx.pid_file.parent / ".side-instance").read_text()
    key = re.search(r"^key=(.+)$", marker, re.M).group(1).strip()
    root = Path.home() / "Library/Application Support/cmux-next/builds" / key / "tui"
    dirs = sorted(p for p in root.iterdir() if p.is_dir()) if root.is_dir() else []
    return dirs or apps_state_dirs(since)


def apps_state_dirs(since: float) -> list[Path]:
    """Session folders whose `apps.json` (the apps store, next to `apps-widgets-layout.json`; safe_mode.rs
    `LAUNCHES_FILE`) names the customize app and was written since `since`: where this run's install landed,
    wherever the copy's build identity put its daemon state (`builds/<key>/tui`, `tags/<tag>/tui`, or the
    shared root of a NIGHTLY-keyed copy; build_identity.rs `daemon_state_dir`)."""
    support = Path.home() / "Library/Application Support"
    found: list[Path] = []
    for top in ("cmux-next", "cmux", "cmux-tui"):
        base = support / top
        if not base.is_dir():
            continue
        for here, subdirs, files in os.walk(base):
            if len(Path(here).relative_to(base).parts) >= 5:
                subdirs[:] = []
            subdirs[:] = [d for d in subdirs if d not in ("host-exe", "apps", "node_modules", "WebKit")]
            if "apps.json" not in files:
                continue
            state = Path(here) / "apps.json"
            try:
                if state.stat().st_mtime >= since and CUSTOMIZE_APP in state.read_text(errors="replace"):
                    found.append(Path(here))
            except OSError:
                continue
    return sorted(set(found))


def row_widget(ctx: Ctx) -> dict:
    """Widgets (#45106 Mac and web, on the daemon's `apps.widgets.*`): a `cmux.widget/1` extension is offered for
    both places (`apps.widgets.list`), and an op from outside the app cannot place it (only a person's gesture
    may, `apps.origin`). The placed tiles a person would add are then seeded as the daemon saves them
    (`apps-widgets-layout.json` in the copy's own session folder, the copy stopped), and after a relaunch the
    sidebar and a New Tab page draw the widget: its render export ran for each place (`apps-logs`, the mount
    context's `place`) or the window's `apps.views` holds its words. Relaunches the copy: run it last."""
    word = f"{ctx.token} widget"
    started = time.time() - 5
    install = install_customize(ctx, {
        "name": "Rows widget", "description": "A widget.", "runtime": {"main": "main.js"},
        "implements": {"cmux.widget/1": {"export": "renderWidget", "title": "Rows widget", "symbol": "square",
                                         "options": {"sizes": ["small", "medium"], "defaultSize": "small",
                                                     "places": ["newtab", "sidebar"]}}}},
        {"main.js": ("function renderWidget(ctx) {\n"
                     "  const place = (ctx && ctx.place) || 'unknown'\n"
                     f"  console.log({json.dumps(word)} + ' ' + place)\n"
                     f"  return VStack([Text({json.dumps(word)} + ' ' + place)])\n}}\n"
                     "globalThis.__cmuxAppExports = { renderWidget }\n")})

    def listed(place: str) -> dict:
        return store_op(ctx, "apps.widgets.list", {"place": place})

    def offered(reply: dict) -> bool:
        return any(w.get("app") == CUSTOMIZE_APP for w in ((reply.get("data") or {}).get("widgets") or []))

    offers = {place: listed(place) for place in ("sidebar", "newtab")}
    self_place = store_op(ctx, "apps.widgets.layout.edit", {
        "place": "sidebar", "edit": {"op": "add", "app": CUSTOMIZE_APP}, "idempotency_key": f"{ctx.token}-self"})
    tiles = {"sidebar": "w901", "newtab": "w902"}
    layout = {"revision": 1, "next": 903,
              **{place: [{"instance": tile, "app": CUSTOMIZE_APP, "size": "small"}] for place, tile in tiles.items()}}
    dirs = daemon_session_dirs(ctx, started)

    def seed() -> list[str]:
        for d in dirs:
            (d / "apps-widgets-layout.json").write_text(json.dumps(layout, indent=2))
        return [str(d) for d in dirs]

    relaunch = side_relaunch(ctx, seed) if dirs else {
        "skipped": "no daemon session folder: none under builds/<key>/tui, and no apps.json naming the customize app "
                   "written this row under ~/Library/Application Support/{cmux-next,cmux,cmux-tui}"}
    placed = {place: listed(place) for place in tiles}
    # A New Tab page shows the New Tab widget grid.
    opened = ctx.rpc("action.run", {"action": "workspace.newAtBottom", "focus": True}, timeout=30)
    drawn = {}
    for place in tiles:
        text = f"{word} {place}"
        shown = wait_for(lambda: [v for v in views(ctx, "cmux.widget/1")
                                  if any(text in t for t in v.get("texts") or [])], wait=20)
        drawn[place] = {"views": shown, "log_lines": logs_with(ctx, text, wait=5)}
    return {"checks": {"installed": install["installed"],
                       "offered_for_sidebar": offered(offers["sidebar"]),
                       "offered_for_newtab": offered(offers["newtab"]),
                       "op_cannot_place_it": self_place.get("ok") is not True,
                       "layout_read": all(tile in json.dumps(placed[p]) for p, tile in tiles.items()),
                       "sidebar_draws_it": bool(drawn["sidebar"]["views"] or drawn["sidebar"]["log_lines"]),
                       "newtab_draws_it": bool(drawn["newtab"]["views"] or drawn["newtab"]["log_lines"])},
            "install": install, "offers": offers, "self_place": self_place, "relaunch": relaunch,
            "placed": placed, "open": opened, "drawn": drawn, "views": views(ctx)}


row_widget.needs_app = True


def row_background_events(ctx: Ctx) -> dict:
    """Background workers (#43018, #49223): an `onEvent:workspace.changed` app with no view open subscribes at
    init and counts the workspace events three new workspaces make (`apps-logs`), with no view of it open."""
    word = f"{ctx.token}-bg"
    install = install_customize(ctx, {
        "name": "Rows background", "description": "Counts workspace events with no view.",
        "runtime": {"main": "main.js"}, "activation": ["onEvent:workspace.changed"],
        "scopes": {"workspace:read": "Count workspace changes."}},
        {"main.js": ("let n = 0\n"
                     f"cmux.events.on('workspace.changed', () => {{ n += 1; console.log({json.dumps(word)} + ' event ' + n) }})\n"
                     f"console.log({json.dumps(word)} + ' subscribed')\n"
                     "globalThis.__cmuxAppExports = {}\n")})
    subscribed = logs_with(ctx, f"{word} subscribed")
    made = [ctx.rpc("action.run", {"action": "workspace.newAtBottom"}, timeout=30) for _ in range(3)]
    counted = wait_for(lambda: (lines := logs_with(ctx, f"{word} event", wait=0)) and
                       any(line.endswith(" event 3") or re.search(r" event ([3-9]|\d\d+)$", line) for line in lines)
                       and lines, wait=20) or logs_with(ctx, f"{word} event", wait=0)
    open_views = views(ctx)
    return {"checks": {"installed": install["installed"], "subscribed_with_no_view": bool(subscribed),
                       "counted_three_events": bool(counted) and any(re.search(r" event ([3-9]|\d\d+)$", line)
                                                                     for line in counted),
                       "no_view_open": not open_views},
            "install": install, "subscribed": subscribed, "event_lines": counted, "new_workspaces": made,
            "views": open_views}


row_background_events.needs_app = True


def row_status(ctx: Ctx) -> dict:
    """Status items (#47317): a `cmux.status/1` app is listed by `apps.status.list` in the titlebar, the Mac
    mounts it (its render export runs, `apps-logs`), and a saved manifest that moves it to the menu bar and
    retitles it is the next answer, with no relaunch."""
    word = f"{ctx.token} status"

    def sample(title: str, placement: str) -> dict:
        return install_customize(ctx, {
            "name": "Rows status", "description": "A status item.", "runtime": {"main": "main.js"},
            "implements": {"cmux.status/1": {"export": "renderStatus", "title": title, "symbol": "bolt",
                                             "options": {"placement": placement}}}},
            {"main.js": ("function renderStatus() {\n"
                         f"  console.log({json.dumps(word)} + ' rendered')\n"
                         f"  return HStack([Text({json.dumps(title)})])\n}}\n"
                         "globalThis.__cmuxAppExports = { renderStatus }\n")})

    def listed(title: str, place: str):
        def probe():
            reply = store_op(ctx, "apps.status.list")
            items = [i for i in (reply.get("data") or {}).get("items") or [] if i.get("app") == CUSTOMIZE_APP]
            return items if any(i.get("title") == title and i.get("place") == place for i in items) else None
        return wait_for(probe, wait=15)

    first = sample(f"Rows {ctx.token[-4:]}", "titlebar")
    in_titlebar = listed(f"Rows {ctx.token[-4:]}", "titlebar")
    rendered = logs_with(ctx, f"{word} rendered") if ctx.control else []
    status_views = views(ctx, "cmux.status/1") if ctx.control else []
    second = sample(f"Moved {ctx.token[-4:]}", "menuBar")
    in_menu = listed(f"Moved {ctx.token[-4:]}", "menuBar")
    checks = {"installed": first["installed"] and second["installed"], "listed_in_titlebar": bool(in_titlebar),
              "save_moved_and_retitled": bool(in_menu)}
    if ctx.control:
        checks["mounted_by_mac"] = bool(rendered) or bool(status_views)
    return {"checks": checks, "install": [first, second], "titlebar": in_titlebar, "menu_bar": in_menu,
            "log_lines": rendered, "views": status_views}


def op_sample(ctx: Ctx, name: str, extra: dict, op_extra: dict | None = None) -> tuple[dict, str, str]:
    """Installs a customize app with one catalog op (`local.customize.<verb>`, export `go`) that logs its
    args with a token word; `extra` adds manifest keys (`cli`, `contributes`), `op_extra` catalog keys."""
    verb, word = f"probe{ctx.token[-6:]}", f"{ctx.token}-{name}-ran"
    op_name = f"local.customize.{verb}"
    catalog = {"family": "local.customize", "owner": f"app:{CUSTOMIZE_APP}", "operations": [{
        "name": op_name, "owner": f"app:{CUSTOMIZE_APP}", "class": "read", "risk": "read",
        "idempotency": "forbidden", "focuses": False,
        "input": {"type": "object", "additionalProperties": True, "properties": {}, "required": []},
        "docs": f"Rows probe for {name}.", "since": "local.customize/1", "export": "go", **(op_extra or {})}]}
    install = install_customize(ctx, {"name": f"Rows {name}", "description": f"A {name} probe.",
                                      "runtime": {"main": "main.js"}, "catalog": "catalog.json", **extra},
                                {"catalog.json": json.dumps(catalog, indent=2),
                                 "main.js": ("function go(args) {\n"
                                             f"  console.log({json.dumps(word)} + ' ' + JSON.stringify(args || {{}}))\n"
                                             f"  return {{ ran: {json.dumps(word)} }}\n}}\n"
                                             "globalThis.__cmuxAppExports = { go }\n")})
    return install, op_name, word


def first_workspace(snapshot) -> str | None:
    """The first workspace id in a `snapshot.get` answer (its `workspaces` list, wherever it nests)."""
    if isinstance(snapshot, dict):
        for item in snapshot.get("workspaces") or []:
            if isinstance(item, dict) and item.get("id"):
                return str(item["id"])
        snapshot = list(snapshot.values())
    if isinstance(snapshot, list):
        for item in snapshot:
            found = first_workspace(item)
            if found:
                return found
    return None


def menu_target_passed(logged: list[str], word: str, workspace: str | None, ran: dict) -> bool:
    # action.run exposes the workspace's public id and its key. app.menu.run passes the key to the op.
    resolved = ran.get("resolved") or {}
    if not workspace or resolved.get("id") != workspace or resolved.get("kind") != "workspace":
        return False
    for line in logged:
        try:
            args = json.loads(line.partition(word + " ")[2])
        except ValueError:
            continue
        target = args.get("target") if isinstance(args, dict) else None
        if isinstance(target, dict) and target.get("kind") == "workspace" and target.get("id") and (
                target["id"] == workspace or target["id"] == resolved.get("key")):
            return True
    return False


def row_menus(ctx: Ctx) -> dict:
    """Context menus on cmux's own surfaces (#43006): a manifest's `contributes.menus` row for the sidebar
    workspace menu is in `apps-list` (what the Mac's menu builder reads at each right-click), and the action
    that row runs (`app.menu.run` with the app, the item and the right-clicked workspace, the same action a
    click sends) runs the app's op with the workspace as `args.target`. No click: the row's own action."""
    title = f"Copy branch {ctx.token[-4:]}"
    install, op_name, word = op_sample(ctx, "menus", {"contributes": {"menus": [
        {"id": "copy-branch", "target": "workspace", "title": title, "op": f"local.customize.probe{ctx.token[-6:]}"}]}})
    record = app_record(ctx) or {}
    rows = (((record.get("manifest") or {}).get("contributes") or {}).get("menus")) or []
    workspace = first_workspace(ctx.rpc("snapshot.get", {}, timeout=15))
    ran = ctx.rpc("action.run", {"action": "app.menu.run", "target": f"workspace:{workspace}",
                                 "args": {"app": CUSTOMIZE_APP, "item": "copy-branch"}}, timeout=30) \
        if workspace else {"error": "no workspace in snapshot.get"}
    logged = logs_with(ctx, word)
    return {"checks": {"installed": install["installed"],
                       "menu_row_listed": any(r.get("id") == "copy-branch" and r.get("title") == title
                                              for r in rows if isinstance(r, dict)),
                       "row_action_ran_op": bool(logged),
                       "target_passed": menu_target_passed(logged, word, workspace, ran)},
            "install": install, "menus": rows, "op": op_name, "workspace": workspace, "run": ran,
            "log_lines": logged}


row_menus.needs_app = True


def row_mcp_tools(ctx: Ctx) -> dict:
    """Agent tools from an extension (#43031): an op whose catalog says `mcp.expose: "default"` is a tool in
    the copy's own `cmux mcp serve` (`tools/list`), and `tools/call` runs it in the app (`apps-logs`)."""
    # The CLI is a child of the probe, so it needs the copy's config path explicitly.
    config = ctx.mcp_config
    if config is None:
        config = ctx.work / "mcp-settings.json"
        config.write_text(json.dumps({"agents": {"cmuxMcp": "on"}}))
    install, op_name, word = op_sample(ctx, "mcp", {}, {"mcp": {"expose": "default"}})
    tool = op_name.replace(".", "_").replace("-", "_")
    lines = [{"jsonrpc": "2.0", "id": 1, "method": "initialize",
              "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                         "clientInfo": {"name": "ext-rows-nightly", "version": "1"}}},
             {"jsonrpc": "2.0", "method": "notifications/initialized"},
             {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
             {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": tool, "arguments": {}}}]
    try:
        run = subprocess.run([str(ctx.cli), *ctx.globals_, "mcp", "serve", "--all-tools"],
                             env=os.environ | {"CMUX_NEXT_CONFIG_FILE": str(config.resolve())},
                             input="".join(json.dumps(line) + "\n" for line in lines), capture_output=True,
                             text=True, timeout=60)
        stdout, stderr, exit_ = run.stdout, run.stderr[-2000:], run.returncode
    except (OSError, subprocess.TimeoutExpired) as error:
        stdout, stderr, exit_ = "", str(error), None
    answers = {}
    for line in stdout.splitlines():
        try:
            value = json.loads(line)
        except ValueError:
            continue
        if isinstance(value, dict) and value.get("id") in (1, 2, 3):
            answers[value["id"]] = value
    listed = [t for t in ((answers.get(2) or {}).get("result") or {}).get("tools") or [] if t.get("name") == tool]
    called = answers.get(3) or {}
    logged = logs_with(ctx, word)
    return {"checks": {"installed": install["installed"], "tool_listed": bool(listed),
                       "call_answered": "result" in called and not (called.get("result") or {}).get("isError"),
                       "op_ran": bool(logged)},
            "install": install, "tool": tool, "listed": listed, "call": called, "mcp_exit": exit_,
            "mcp_stderr": stderr, "log_lines": logged}


def row_cli_name(ctx: Ctx) -> dict:
    """Plugin CLI subcommands (#43012): with `cli.name` in the manifest and a `cli.path` on an op, the copy's
    own `cmux <name> <path>` runs that op in the app (`apps-logs`); a path the app lacks is refused."""
    name = f"rows{ctx.token[-6:]}"
    install, op_name, word = op_sample(ctx, "cli", {"cli": {"name": name}}, {"cli": {"path": "go", "visible": True}})
    ran = cli_json(ctx.cli, ["--socket", ctx.daemon], [name, "go"], timeout=60)
    unknown = cli_json(ctx.cli, ["--socket", ctx.daemon], [name, "no-such-verb"], timeout=60)
    logged = logs_with(ctx, word)
    return {"checks": {"installed": install["installed"], "cli_ran": ran.get("exit") == 0, "op_ran": bool(logged),
                       "unknown_path_refused": unknown.get("exit") not in (0, None)},
            "install": install, "cli_name": name, "op": op_name, "run": ran, "unknown": unknown,
            "log_lines": logged}


def row_settings(ctx: Ctx) -> dict:
    """Extension settings (#43022): a manifest `settings` schema is listed by `apps.settings.list` with its
    defaults, the running host gets those values at init (its `cmux.app.settings()` logged, `apps-logs`), and a
    change from outside the app is refused: `apps.settings.set` is the person's own (Settings > Extensions, the
    verified app connection, Gate A2), so neither a plain CLI call nor one claiming origin `user` stores it, and
    the listed values stay the defaults."""
    word = f"{ctx.token}-settings"
    defaults = {"greeting": f"Hi {ctx.token[-4:]}", "limit": 10}
    install = install_customize(ctx, {
        "name": "Rows settings", "description": "Reads its own settings.", "runtime": {"main": "main.js"},
        "activation": ["onStartup"],
        "settings": {"type": "object", "properties": {
            "greeting": {"type": "string", "title": "Greeting", "default": defaults["greeting"], "maxLength": 40},
            "limit": {"type": "integer", "title": "Limit", "minimum": 1, "maximum": 50,
                      "default": defaults["limit"]}}}},
        {"main.js": (f"console.log({json.dumps(word)} + ' init ' + JSON.stringify(cmux.app.settings()))\n"
                     "globalThis.__cmuxAppExports = {}\n")})

    def listed():
        reply = store_op(ctx, "apps.settings.list")
        rows = [a for a in (reply.get("data") or {}).get("apps") or [] if a.get("app") == CUSTOMIZE_APP]
        return rows[0] if rows else None

    row = wait_for(listed, wait=15) or {}
    init = logs_with(ctx, f"{word} init")
    change = {"limit": 25}
    plain = store_op(ctx, "apps.settings.set", {"app": CUSTOMIZE_APP, "values": change,
                                                "idempotency_key": f"{ctx.token}-set"})
    claimed = op(ctx, {"cmd": "apps-store", "origin": "user", "op": "apps.settings.set",
                       "args": {"app": CUSTOMIZE_APP, "values": change, "idempotency_key": f"{ctx.token}-user"}})
    after = listed() or {}
    properties = (row.get("schema") or {}).get("properties") or {}
    return {"checks": {"installed": install["installed"],
                       "listed_with_schema": set(defaults) <= set(properties),
                       "defaults_listed": all((row.get("values") or {}).get(k) == v for k, v in defaults.items()),
                       "host_got_defaults": any(json.dumps(defaults["greeting"]) in line for line in init),
                       "cli_set_refused": plain.get("ok") is not True,
                       "claimed_user_set_refused": claimed.get("ok") is not True,
                       "values_unchanged": (after.get("values") or {}).get("limit") == defaults["limit"]},
            "install": install, "listed": row, "log_lines": init, "set": plain, "set_as_user": claimed,
            "after": after}


def row_git_install(ctx: Ctx) -> dict:
    """Installs from a source (#42068 `cmux ext add SOURCE`, #44897 git references), with no network: a local
    folder (an `ext new` scaffold, itself a git repo) loads through `ext add` in the copy's daemon without
    installing, and only https repository references are taken. `ext add file://...` is refused, as are
    `catalog.get` (the consent card's fetch) of a `file://` URL, an `http://` URL ("only https repositories
    install") and an https URL on a host that is not a public name; none of them fetches. A pinned https
    install and `apps.update`'s `apps.update.needs_consent` need the network and a fetched app: not here."""
    folder = ctx.work / "git-src"
    shutil.rmtree(folder, ignore_errors=True)
    made = ctx.ext(["ext", "new", f"rows-git{ctx.token[-4:]}", "--kind", "section", "--dir", str(folder),
                    "--json"], timeout=60)
    added = ctx.ext(["ext", "add", str(folder), "--json", "--no-install"], timeout=120)
    answer = added.get("json") if isinstance(added.get("json"), dict) else {}
    by_file = ctx.ext(["ext", "add", folder.as_uri(), "--json", "--no-install"], timeout=60)

    def staged(reference: str) -> dict:
        return store_op(ctx, "apps.catalog.get", {"app": reference})

    stages = {"file": staged(folder.as_uri()), "http": staged("http://example.com/owner/repo"),
              "private_host": staged("https://localhost/owner/repo")}

    def said(reply: dict, text: str) -> bool:
        return reply.get("ok") is not True and text in json.dumps(reply.get("error"))

    return {"checks": {"scaffolded": made.get("exit") == 0 and (folder / ".git").exists(),
                       "folder_added": added.get("exit") == 0 and answer.get("ok") is not False
                       and bool(answer.get("app")),
                       "file_url_add_refused": by_file.get("exit") not in (0, None),
                       "file_url_not_staged": stages["file"].get("ok") is not True,
                       "http_refused_https_only": said(stages["http"], "only https"),
                       "private_host_refused": said(stages["private_host"], "public host")},
            "new": {k: made.get(k) for k in ("exit", "json", "stderr")}, "add": added, "add_file_url": by_file,
            "catalog_get": stages}


def row_toolbar(ctx: Ctx) -> dict:
    """Toolbar items (#47325): a manifest's `contributes.toolbarItems` button whose action is one of the app's
    own catalog ops is listed by `apps.toolbar.list` (the daemon answer the Mac toolbar draws) with that op and
    its args, and a saved manifest that retitles it is the next answer, with no relaunch. The click runs as the
    person (`apps-run` origin `user`, the verified app only), so the CLI claiming it is refused."""
    def sample(title: str) -> tuple[dict, str, str]:
        verb = f"probe{ctx.token[-6:]}"
        return op_sample(ctx, "toolbar", {"contributes": {"toolbarItems": [{
            "id": "rows", "kind": "button", "title": title, "icon": {"symbol": "star"},
            "action": {"op": f"local.customize.{verb}", "args": {"from": "toolbar"}}, "order": 20}]}})

    def listed(title: str):
        def probe():
            reply = store_op(ctx, "apps.toolbar.list")
            items = [i for i in (reply.get("data") or {}).get("items") or [] if i.get("app") == CUSTOMIZE_APP]
            return items if any(i.get("title") == title for i in items) else None
        return wait_for(probe, wait=15)

    first_title, second_title = f"Rows {ctx.token[-4:]}", f"Retitled {ctx.token[-4:]}"
    first, op_name, word = sample(first_title)
    shown = listed(first_title) or []
    claimed = op(ctx, {"cmd": "apps-run", "origin": "user", "app": CUSTOMIZE_APP, "op": op_name,
                       "args": {"from": "toolbar"}})
    second, _, _ = sample(second_title)
    retitled = listed(second_title) or []
    return {"checks": {"installed": first["installed"] and second["installed"],
                       "listed_with_its_op": any(i.get("op") == op_name and (i.get("args") or {}).get("from")
                                                 == "toolbar" for i in shown),
                       "save_retitled": bool(retitled),
                       "cli_click_as_person_refused": claimed.get("ok") is not True},
            "install": [first, second], "op": op_name, "listed": shown, "retitled": retitled,
            "run_as_user": claimed}


def row_overlay(ctx: Ctx) -> dict:
    """Overlays (#43014): an app whose `cmux.pane/1` declares `presentation.overlay` opens one only from the
    person's gesture. An `apps-mount` on the overlay surface from the CLI is refused (`apps.overlay_gesture`),
    and so is one claiming origin `user` (the verified app only); nothing floats in front of the person."""
    word = f"{ctx.token} overlay"
    install = install_customize(ctx, {
        "name": "Rows overlay", "description": "An overlay pane.", "runtime": {"main": "main.js"},
        "implements": {"cmux.pane/1": {"export": "renderPane", "title": "Rows overlay"}},
        "presentation": {"overlay": {"width": 360, "height": 240}}},
        {"main.js": ("function renderPane() {\n"
                     f"  console.log({json.dumps(word)} + ' rendered')\n"
                     f"  return VStack([Text({json.dumps(word)})])\n}}\n"
                     "globalThis.__cmuxAppExports = { renderPane }\n")})
    context = {"surface": "overlay", "contribution": f"{CUSTOMIZE_APP}#cmux.pane/1"}
    mount = {"cmd": "apps-mount", "app": CUSTOMIZE_APP, "interface": "cmux.pane/1", "context": context}
    plain = op(ctx, {**mount, "mount_id": f"{ctx.token}-o1"})
    claimed = op(ctx, {**mount, "origin": "user", "mount_id": f"{ctx.token}-o2"})
    for reply, mount_id in ((plain, "o1"), (claimed, "o2")):
        if reply.get("ok") is True:
            op(ctx, {"cmd": "apps-unmount", "mount_id": f"{ctx.token}-{mount_id}"})
    return {"checks": {"installed": install["installed"],
                       "cli_overlay_refused": plain.get("ok") is not True
                       and "apps.overlay_gesture" in json.dumps(plain.get("error")),
                       "claimed_user_overlay_refused": claimed.get("ok") is not True},
            "install": install, "mount": plain, "mount_as_user": claimed,
            "log_lines": logs_with(ctx, f"{word} rendered", wait=2)}


FORK_APP = "widget-clock"


def row_fork(ctx: Ctx) -> dict:
    """Forkable built-ins (#43005): a first-party app copied as a user's fork (first-party-apps/fork-check.ts's
    rewrite: id `local/fork-<name>`, its catalog ops' owner) loads in the copy's daemon from its own folder
    with `ext shot --json` (`ext dev --once`, no install) and draws its scene."""
    source = ROOT / "first-party-apps" / FORK_APP
    folder = ctx.work / f"fork-{FORK_APP}"
    shutil.rmtree(folder, ignore_errors=True)
    shutil.copytree(source, folder, ignore=shutil.ignore_patterns("node_modules", "test", "preview", "screenshots"))
    fork_id = f"local/fork-{FORK_APP}"
    manifest_path = folder / "cmux-app.json"
    manifest = json.loads(manifest_path.read_text())
    original = manifest.get("id")
    manifest["id"] = fork_id
    manifest.pop("$schema", None)
    manifest.pop("screenshots", None)
    manifest_path.write_text(json.dumps(manifest, indent=2))
    catalog = manifest.get("catalog")
    if isinstance(catalog, str) and (folder / catalog).is_file():
        data = json.loads((folder / catalog).read_text())
        for entry in data.get("operations") or []:
            if isinstance(entry, dict) and "owner" in entry:
                entry["owner"] = f"app:{fork_id}"
        if "owner" in data:
            data["owner"] = f"app:{fork_id}"
        (folder / catalog).write_text(json.dumps(data, indent=2))
    shot = ctx.ext(["ext", "shot", str(folder), "--json", "--out", str(ctx.work / f"fork-{FORK_APP}.png")])
    answer = shot.get("json") if isinstance(shot.get("json"), dict) else {}
    loaded = answer.get("ok") is True or (answer.get("phase") == "shot" and not answer.get("errors"))
    scene = scene_of(shot)
    return {"checks": {"forked": original != fork_id, "fork_loaded": loaded,
                       "scene_drawn": bool(scene) or not ctx.control},
            "app": FORK_APP, "original_id": original, "fork_id": fork_id,
            "load": {k: answer.get(k) for k in ("ok", "phase", "app", "errors", "placed", "shot", "next")},
            "scene": scene[:20], "shot_exit": shot.get("exit"),
            **({"shot_error": shot.get("stderr") or shot.get("output")} if not loaded else {})}


# Row name: (its function, the PRs that closed it in code). One entry per row; order is run order: each
# customize row replaces the last one's sample, activation first (it checks no view is open), the rows that
# open a tab last; ext_new uses folders of its own; widget relaunches the copy, so it runs last.
ROWS = {
    "activation": (row_activation, "#43018"),
    "opener": (row_opener, "#43007"),
    "composer": (row_composer, "#43032 #49239"),
    "chat_widget": (row_chat_widget, "#43030"),
    "background_events": (row_background_events, "#43018 #49223"),
    "status": (row_status, "#47317"),
    "menus": (row_menus, "#43006"),
    "mcp_tools": (row_mcp_tools, "#43031"),
    "cli_name": (row_cli_name, "#43012"),
    "fork": (row_fork, "#43005"),
    "ext_new": (row_ext_new, "#43371 #44828 #44877"),
    "newtab": (row_newtab, "#42998"),
    "web_pane": (row_web_pane, "#41546 #43033"),
    "widget": (row_widget, "#45106"),
    "settings": (row_settings, "#43022"),
    "git_install": (row_git_install, "#42068 #44897"),
    "toolbar": (row_toolbar, "#47325"),
    "overlay": (row_overlay, "#43014"),
}


def run_rows(ctx: Ctx, names: list[str]) -> dict:
    rows = {}
    for name in names:
        fn, prs = ROWS[name]
        if getattr(fn, "needs_app", False) and not ctx.control:
            rows[name] = {"ok": None, "prs": prs, "skipped": "needs the Mac app's control socket"}
            continue
        started = time.monotonic()
        try:
            result = fn(ctx)
        except Exception as error:  # a row's failure is its own; the rest still run
            result = {"checks": {"ran": False}, "error": f"{type(error).__name__}: {error}"}
        result["ok"] = bool(result.get("checks")) and all(result["checks"].values())
        rows[name] = {"ok": result.pop("ok"), "prs": prs, "ms": round((time.monotonic() - started) * 1000), **result}
        print(f"EXT_ROWS_NIGHTLY row {name} ok={rows[name]['ok']} {json.dumps(rows[name]['checks'])}", flush=True)
    return rows


def raw_cli_for(cli: Path, work: Path) -> Path:
    """The bundled binary under the `cmux-tui` name (the `raw` scope is that name's): the bundle's own when
    it has one, else a link to `cmux` in WORK."""
    beside = cli.parent / "cmux-tui"
    if beside.exists():
        return beside
    link = work / "bin/cmux-tui"
    link.parent.mkdir(parents=True, exist_ok=True)
    if not link.exists():
        link.symlink_to(cli)
    return link


def attach_copy(app: Path, cli: Path, pid_file: Path, socket_hint: str | None = None) -> tuple[str, str]:
    """The running copy's control socket and daemon socket, the daemon started by a workspace with a terminal."""
    app_pid = int(pid_file.read_text().strip())
    control = reload_nightly.wait_until("the copy's control socket", time.monotonic() + 120,
                                        lambda: control_socket(app_pid, socket_hint))
    reload_nightly.bench.rpc_at(control, "action.run", {"action": "workspace.newAtBottom"}, timeout=30)
    reload_nightly.bench.rpc_at(control, "action.run", {"action": "newSurface"}, timeout=30)
    daemon = reload_nightly.wait_until("the copy's daemon", time.monotonic() + 180,
                                       lambda: reload_nightly.hot.find_socket(app, cli))
    return control, daemon


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", help="the running side-instance copy")
    parser.add_argument("--pid-file", help="the copy's pid file")
    parser.add_argument("--cli", help="a cmux binary, with --daemon-socket (no Mac app)")
    parser.add_argument("--daemon-socket")
    parser.add_argument("--control-socket")
    parser.add_argument("--mcp-config", type=Path, help="the private settings file prepared for the MCP probe")
    parser.add_argument("--customize", required=True, help="the copy's own customize folder")
    parser.add_argument("--out", required=True)
    parser.add_argument("--rows", default=",".join(ROWS))
    args = parser.parse_args()
    names = [n for n in args.rows.split(",") if n]
    unknown = [n for n in names if n not in ROWS]
    if unknown:
        parser.error(f"unknown rows {unknown}; rows are {', '.join(ROWS)}")
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    receipt: dict = {"host": os.uname().nodename, "rows_asked": names}
    if args.app:
        app = Path(args.app)
        cli = (app / reload_nightly.hot.BIN / "cmux").resolve()
        receipt |= {"app": str(app), **reload_nightly.hot.app_commit_receipt(app)}
        control, daemon = attach_copy(app, cli, Path(args.pid_file), args.control_socket)
    elif args.cli and args.daemon_socket:
        cli, daemon, control = Path(args.cli).resolve(), args.daemon_socket, args.control_socket
    else:
        parser.error("give --app and --pid-file, or --cli and --daemon-socket")
    receipt["version"] = subprocess.run([str(cli), "--version"], capture_output=True, text=True).stdout.strip()
    receipt |= {"daemon_socket": daemon, "control_socket": control}
    ctx = Ctx(cli=cli, daemon=daemon, customize=Path(args.customize), work=out / "work", control=control,
              mcp_config=args.mcp_config,
              app=Path(args.app) if args.app else None, pid_file=Path(args.pid_file) if args.pid_file else None)
    ctx.work.mkdir(parents=True, exist_ok=True)
    ctx.raw_cli = raw_cli_for(cli, ctx.work)
    receipt["token"] = ctx.token
    receipt["rows"] = run_rows(ctx, names)
    ran = [r for r in receipt["rows"].values() if r["ok"] is not None]
    receipt["ok"] = bool(ran) and all(r["ok"] for r in ran)
    receipt["passed"] = sorted(n for n, r in receipt["rows"].items() if r["ok"])
    receipt["failed"] = sorted(n for n, r in receipt["rows"].items() if r["ok"] is False)
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2))
    print("EXT_ROWS_NIGHTLY " + json.dumps(receipt), flush=True)
    return 0 if receipt["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
