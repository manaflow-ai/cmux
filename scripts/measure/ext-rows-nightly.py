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
    """Composer slash commands (#43032): a `cmux.composer.command/1` command is in `apps.composer.list` (the
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


# Row name: (its function, the PRs that closed it in code). One entry per row; order is run order: each
# customize row replaces the last one's sample, activation first (it checks no view is open), the rows that
# open a tab last; ext_new uses folders of its own.
ROWS = {
    "activation": (row_activation, "#43018"),
    "opener": (row_opener, "#43007"),
    "composer": (row_composer, "#43032"),
    "chat_widget": (row_chat_widget, "#43030"),
    "ext_new": (row_ext_new, "#43371 #44828 #44877"),
    "newtab": (row_newtab, "#42998"),
    "web_pane": (row_web_pane, "#41546 #43033"),
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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", help="the running side-instance copy")
    parser.add_argument("--pid-file", help="the copy's pid file")
    parser.add_argument("--cli", help="a cmux binary, with --daemon-socket (no Mac app)")
    parser.add_argument("--daemon-socket")
    parser.add_argument("--control-socket")
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
        app_pid = int(Path(args.pid_file).read_text().strip())
        receipt |= {"app": str(app), "app_commit": reload_nightly.hot.app_commit(app)}
        control = reload_nightly.wait_until("the copy's control socket", time.monotonic() + 120,
                                            lambda: control_socket(app_pid, args.control_socket))
        # A workspace with a terminal starts the copy's daemon.
        reload_nightly.bench.rpc_at(control, "action.run", {"action": "workspace.newAtBottom"}, timeout=30)
        reload_nightly.bench.rpc_at(control, "action.run", {"action": "newSurface"}, timeout=30)
        daemon = reload_nightly.wait_until("the copy's daemon", time.monotonic() + 180,
                                           lambda: reload_nightly.hot.find_socket(app, cli))
    elif args.cli and args.daemon_socket:
        cli, daemon, control = Path(args.cli).resolve(), args.daemon_socket, args.control_socket
    else:
        parser.error("give --app and --pid-file, or --cli and --daemon-socket")
    receipt["version"] = subprocess.run([str(cli), "--version"], capture_output=True, text=True).stdout.strip()
    receipt |= {"daemon_socket": daemon, "control_socket": control}
    ctx = Ctx(cli=cli, daemon=daemon, customize=Path(args.customize), work=out / "work", control=control)
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
