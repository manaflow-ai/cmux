#!/usr/bin/env python3
"""Run only inside an isolated cmux capture terminal; never on the lane host.

Modes: setup, consent, preview, verify. All reads and mutations target the
capture clone. Every operation is one bounded call; this script never polls.
CLI --json prints the result itself (wire.rs print_local_success), not {data:…}.
"""
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import sqlite3
import stat
import subprocess
import sys
import uuid


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


home_input = Path(os.environ["HOME"])
require(home_input.is_absolute() and not home_input.is_symlink(), "HOME must be absolute and not a symlink")
require(str(home_input) == os.environ.get("CMUX_CAPTURE_SHELL_HOME"), "HOME is not the capture lease HOME")
home = home_input.resolve()
require(home.name == "home" and home.stat().st_uid == os.getuid(), "HOME is not an owned capture home")
require(home != Path(pwd.getpwuid(os.getuid()).pw_dir).resolve(), "Refusing the account HOME")
cli = Path(os.environ["CMUX_BUNDLED_CLI_PATH"]).resolve(strict=True)
require(cli.parts[-4:] == ("Contents", "Resources", "bin", "cmux"), "CLI is not app-bundled")
bundle = cli.parents[3]
require(bundle.is_relative_to(home.parent), "CLI bundle is outside this capture lease")
with (bundle / "Contents/Info.plist").open("rb") as stream:
    bundle_id = plistlib.load(stream)["CFBundleIdentifier"]
require(re.fullmatch(r"[A-Za-z0-9.-]+\.cap(?:host|slot[0-9]+)", bundle_id), "Not a capture bundle")
require(os.environ.get("CMUX_BUNDLE_ID") == bundle_id, "Terminal belongs to another bundle")
app_socket = os.environ["CMUX_SOCKET_PATH"]
daemon_socket = Path(os.environ["CMUX_TUI_SOCKET"])
require(daemon_socket.is_absolute(), "Daemon socket must be an explicit absolute path")
daemon_stat = daemon_socket.stat()
require(stat.S_ISSOCK(daemon_stat.st_mode) and daemon_stat.st_uid == os.getuid(), "Daemon route is not an owned live socket")
state_root = Path(os.environ["CMUX_TUI_STATE_DIR"]).resolve(strict=True)
require(state_root.is_dir() and state_root.is_relative_to(home), "Daemon state root escapes isolated HOME")
terminal_id = os.environ["CMUX_TUI_TERMINAL_ID"]
require(terminal_id.startswith("term_"), "Fixture must run in a real daemon terminal")
for override in ("ACPMUX_HOME", "CMUX_NEXT_ACPMUX_ATTACH", "CMUX_NEXT_ACPMUX_ROOT"):
    if os.environ.get(override):
        require(Path(os.environ[override]).resolve().is_relative_to(home), override + " escapes capture HOME")
daemon_env = {key: value for key, value in os.environ.items() if not key.startswith("CMUX_")}
daemon_env["CMUX_TUI_STATE_DIR"] = str(state_root)
root = home / "import-any-tool-fixture"
linked = root / "capture-import"
receipt = root / "receipt.json"


def command(args, env=None):
    if args[0] == "/usr/bin/git":
        # A capture must never inherit a caller's repository or hook routing.
        env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        env.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
                    "GIT_CONFIG_SYSTEM": os.devnull, "GIT_TERMINAL_PROMPT": "0"})
    result = subprocess.run(args, env=env, capture_output=True, text=True, timeout=35)
    # Do not export raw errors: they can contain the lease's absolute path.
    require(result.returncode == 0, "Command failed: " + Path(args[0]).name + " (exit " + str(result.returncode) + ")")
    return result.stdout


def daemon(*args):
    # Explicit --socket wins before every default/env/Chief route in wire/socket.rs.
    # Preserve the capture daemon's exact state root; never select a personal default.
    return json.loads(command([str(cli), "--json", "--socket", str(daemon_socket), *args], daemon_env))


def rpc(method, params=None):
    answer = json.loads(command([str(cli), "--json", "--app-socket", app_socket,
                                 "app", "call", method, json.dumps(params or {})]))
    require(not isinstance(answer, dict) or not answer.get("error"), "App RPC returned an error: " + method)
    return answer


identity = rpc("system.identify")
require(identity.get("bundle_id") == bundle_id, "App socket belongs to another bundle")


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)


# Two independent read paths must name this exact terminal before any fixture
# filesystem writes or project.observe mutation. The app mapper emits terminal_id
# from the same daemon terminal model; terminal status returns its daemon record.
require(terminal_id in set(strings(rpc("snapshot.get"))), "Capture app does not own this terminal")
require(terminal_id in set(strings(daemon("terminal", terminal_id, "status"))),
        "Explicit daemon route does not own the capture app terminal")


def plan():
    value = daemon("raw", "operation", "conductor_import.plan", "--params-json", "{}")
    require(not value.get("error") and isinstance(value.get("plan"), dict), "No usable real import plan")
    require(value.get("has_conductor") is False, "Expected generic import without Conductor")
    projects = value["plan"]["projects"]
    matches = [item for project in projects for item in project["workspaces"]
               if item.get("path") and Path(item["path"]).resolve() == linked.resolve()]
    require(len(matches) == 1, "Expected exactly one matching linked worktree")
    require("codex" in json.dumps(value.get("tool_sources", {})), "Plan lacks the Codex source")
    return value, matches[0]


def load_receipt():
    require(receipt.is_file() and receipt.resolve().is_relative_to(home), "Missing owned fixture receipt")
    return json.loads(receipt.read_text())


def save(value):
    receipt.write_text(json.dumps(value, indent=2) + "\n")


def ledger_entry(source_id):
    # DaemonLauncher passes its exact state root into terminalEnvironment.
    # Each session has one immediate child directory; never search host HOME.
    children = list(state_root.iterdir())
    require(len(children) <= 64, "Unexpectedly large capture state root")
    matches = []
    for child in children:
        database = child / "workspace-registry.sqlite3"
        if child.is_symlink() or not child.is_dir() or not database.is_file():
            continue
        require(not database.is_symlink() and database.resolve().is_relative_to(home), "Registry escapes isolated HOME")
        with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=3) as connection:
            connection.execute("PRAGMA query_only=ON")
            exists = connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='conductor_import_ledger'").fetchone()
            if not exists:
                continue
            row = connection.execute("SELECT ledger_json FROM conductor_import_ledger WHERE id=1").fetchone()
            if not row:
                continue
            ledger = json.loads(row[0])
            item = ledger.get("workspaces", {}).get(source_id)
            if item:
                matches.append((ledger, item))
    require(len(matches) == 1, "Expected exactly one real ledger entry for fixture")
    return matches[0]


def dialog(identifier, button):
    data = load_receipt()
    found = [item for item in rpc("debug.dialog")["dialogs"]
             if item.get("identifier") == identifier and item.get("visible") is True]
    require(len(found) == 1, "Expected one real dialog: " + identifier)
    current = found[0]
    if button == "import":
        text = json.dumps(current)
        require("capture-import" in text, "Preview does not name the linked worktree")
        require("conductor" not in str(current.get("title", "")).lower(), "Generic preview still has Conductor title")
    data[button + "_dialog"] = {"identifier": identifier, "title": current.get("title"),
                                "lines": current.get("lines")}
    save(data)
    require(rpc("debug.dialog", {"id": current["id"], "press": button}).get("pressed") is True,
            "Native dialog button was not pressed")


mode = sys.argv[1]
if mode == "setup":
    require(not root.exists(), "Fixture already exists; use a new capture lease")
    # Read only capture-local source settings; reject an externally routed source.
    codex = Path(os.environ.get("CODEX_HOME", str(home / ".codex")))
    require(codex.is_absolute() and codex.resolve().is_relative_to(home), "CODEX_HOME escapes capture HOME")
    root.mkdir(mode=0o700)
    # The standalone clip embeds this source once. Install it only after both routing
    # checks above; subsequent steps verify its digest before loading the same helper.
    fixture_source = globals().get("_fixture_source")
    require(isinstance(fixture_source, bytes), "Setup requires the generated clip bootstrap")
    with (root / "capture.py").open("xb") as stream:
        stream.write(fixture_source)
    (root / "capture.py").chmod(0o600)
    main = root / "main"
    command(["/usr/bin/git", "init", "--initial-branch=main", str(main)])
    (main / "README.md").write_text("Synthetic linked-worktree import fixture.\n")
    command(["/usr/bin/git", "-C", str(main), "add", "README.md"])
    command(["/usr/bin/git", "-C", str(main), "-c", "user.name=Capture Fixture", "-c",
             "user.email=capture@example.invalid", "-c", "commit.gpgsign=false",
             "commit", "-m", "Create isolated import fixture"])
    command(["/usr/bin/git", "-C", str(main), "worktree", "add", "-b", "capture-import", str(linked)])
    stamp = datetime.datetime.now(datetime.timezone.utc)
    session_id = str(uuid.uuid4())
    directory = codex / "sessions" / stamp.strftime("%Y/%m/%d")
    require(directory.resolve().is_relative_to(home), "Rollout directory escapes capture HOME")
    directory.mkdir(parents=True, exist_ok=True)
    rollout = directory / ("rollout-" + stamp.strftime("%Y-%m-%dT%H-%M-%S-") + session_id + ".jsonl")
    records = [
        {"timestamp": stamp.isoformat(), "type": "session_meta", "payload": {
            "id": session_id, "timestamp": stamp.isoformat(), "cwd": str(linked), "originator": "codex_cli_rs"}},
        {"timestamp": stamp.isoformat(), "type": "event_msg", "payload": {
            "type": "user_message", "message": "Inspect this synthetic linked worktree."}}
    ]
    with rollout.open("x") as stream:
        for record in records:
            stream.write(json.dumps(record, separators=(",", ":")) + "\n")
    params = {"source": "codex", "entries": [{"path": str(linked), "last_used_ms": str(int(stamp.timestamp() * 1000))}], "complete": False}
    daemon("raw", "operation", "project.observe", "--params-json", json.dumps(params),
           "--mutation", "--idempotency-key", "capture-import-" + session_id)
    value, item = plan()
    require(item["disposition"]["kind"] == "adopt", "Fixture is not offered for adoption")
    save({"setup": "passed", "routing": "explicit socket, matching app and daemon terminal, isolated state root",
          "rollout_relative": str(rollout.relative_to(home)),
          "rollout_sha256": hashlib.sha256(rollout.read_bytes()).hexdigest(),
          "source_workspace": item["id"], "before_disposition": "adopt"})
elif mode == "consent":
    dialog("cmux.dialog.importCard", "confirm")
elif mode == "preview":
    dialog("cmux.dialog.conductorImport", "import")
elif mode == "verify":
    data = load_receipt()
    value, item = plan()
    require(item["id"] == data["source_workspace"], "Source identity changed")
    require(item["disposition"]["kind"] == "already-imported", "Ledger did not retain completed adoption")
    workspace = item["disposition"]["cmux_workspace"]
    ledger, entry = ledger_entry(data["source_workspace"])
    require(entry.get("stage") == "done" and entry.get("cmux_workspace") == workspace,
            "Persisted ledger does not confirm this completed workspace")
    workspaces = daemon("workspace", "list")
    require(workspace in json.dumps(workspaces), "Ledger workspace is not open in the bundled daemon")
    original = home / data["rollout_relative"]
    require(hashlib.sha256(original.read_bytes()).hexdigest() == data["rollout_sha256"], "Original rollout changed")
    require((linked / ".git").is_file(), "Original linked worktree was replaced")
    again, repeated = plan()
    require(repeated["disposition"] == item["disposition"], "Repeated plan is not idempotent")
    after_ledger, after_entry = ledger_entry(data["source_workspace"])
    require(after_ledger == ledger and after_entry == entry, "Repeated dry run changed the stored ledger")
    require(command(["/usr/bin/git", "-C", str(linked), "status", "--porcelain"]).strip() == "", "Fixture worktree changed")
    data.update({"verification": "passed", "after_disposition": "already-imported", "cmux_workspace": workspace,
                 "ledger_stage": "done", "ledger_read": "sqlite-mode-ro",
                 "repeated_plan": "unchanged", "original_rollout": "unchanged", "worktree": "clean",
                 "coverage": "project.observe relay to real Settings import and persistent ledger"})
    save(data)
    print("\033[2J\033[HImport readback PASS: real preview, open workspace, persisted done ledger, unchanged source.")
else:
    raise RuntimeError("Unknown mode")
