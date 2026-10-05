#!/usr/bin/env python3
"""Execute production Swift context reader on isolated transcript/SQLite fixtures.

Compiles actual Foundation-only reader, input and redaction sources. No app is
started. This scoped behavioral check does not replace an app build.
"""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]


def run(*argv, **kwargs):
    return subprocess.run(argv, check=True, text=True, capture_output=True, **kwargs)


def main():
    with tempfile.TemporaryDirectory(prefix="cmux-context-fixtures-") as tmp:
        temp = Path(tmp)
        home = temp / "home"
        home.mkdir()
        modules = [
            ("CmuxExtensionKit", list((ROOT / "Packages/macOS/CmuxExtensionKit/Sources/CmuxExtensionKit/Sidebar").glob("CmuxSidebarContextTag*.swift"))),
            ("CmuxSentryScrubbing", list((ROOT / "Packages/Shared/CmuxSentryTelemetry/Sources/CmuxSentryScrubbing").glob("*.swift"))),
        ]
        for name, sources in modules:
            run("xcrun", "swiftc", "-swift-version", "6", "-emit-library", "-emit-module", "-module-name", name,
                "-emit-module-path", str(temp / (name + ".swiftmodule")),
                "-o", str(temp / ("lib" + name + ".dylib")), *map(str, sources))
        entry = temp / "main.swift"
        entry.write_text('''import Foundation
let args = CommandLine.arguments
let reader = SidebarOrganizationContextReader(homeDirectory: URL(fileURLWithPath: args[1]))
let session = SidebarOrganizationInput.Session(toolId: args[2], sessionId: args[3], directory: nil, title: "Fixture", context: nil)
let result = reader.read(session, maximumCharacters: Int(args[4])!)
print(String(data: try JSONEncoder().encode(result), encoding: .utf8)!)
''')
        binary = temp / "reader"
        run("xcrun", "swiftc", "-swift-version", "6", "-I", str(temp), "-L", str(temp),
            "-lCmuxExtensionKit", "-lCmuxSentryScrubbing", "-Xlinker", "-rpath", "-Xlinker", str(temp),
            str(ROOT / "Sources/SidebarOrganizationInput.swift"),
            str(ROOT / "Sources/SidebarOrganizationContextReader.swift"), str(entry), "-o", str(binary))
        env = {key: value for key, value in os.environ.items() if key not in ["XDG_DATA_HOME", "COMMANDCODE_DIR"]}

        def read(tool, sid, limit=6000):
            return json.loads(run(str(binary), str(home), tool, sid, str(limit), env=env).stdout)

        def jsonl(path, rows):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("".join(json.dumps(row) + "\n" for row in rows))

        checks = []

        def check(name, passed):
            checks.append((name, bool(passed)))

        sid = str(uuid.uuid4())
        codex = home / (".codex/sessions/rollout-" + sid + ".jsonl")
        codex_rows = [
            {"type": "session_meta", "payload": {"id": sid}},
            {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"text": "x" * 8000}]}}
        ]
        jsonl(codex, codex_rows)
        value = read("codex", sid, 100)
        check("codex bounded exact SID", value and len(value["recentMessages"][0]["text"]) == 100)
        jsonl(codex, [{"type": "session_meta", "payload": {"id": str(uuid.uuid4())}}, *codex_rows[1:]])
        check("codex header mismatch rejected", read("codex", sid) is None)
        cmd = home / (".commandcode/projects/project/" + sid + ".jsonl")
        cmd_rows = [
            {"type": "session", "id": sid, "cwd": "/fixture"},
            {"type": "message", "message": {"role": "user", "content": "Latest inventory intent"}},
            {"type": "message", "message": {"role": "assistant", "content": [{"type": "text", "text": "contact person@example.com password=secretvalue"}]}},
            {"type": "compaction", "summary": "Ignored old summary"}
        ]
        jsonl(cmd, cmd_rows)
        value = read("commandcode", sid, 60)
        texts = [m["text"] for m in (value or {}).get("recentMessages", [])]
        check("command code exact SID supported", bool(texts))
        check("command code redacted and bounded", bool(texts) and sum(map(len, texts)) <= 60 and "person@example.com" not in "".join(texts) and "secretvalue" not in "".join(texts))
        jsonl(cmd, [{"type": "session", "id": str(uuid.uuid4())}, *cmd_rows[1:]])
        check("command code header mismatch rejected", read("commandcode", sid) is None)
        jsonl(cmd, cmd_rows)
        duplicate = home / (".commandcode/projects/other/" + sid + ".jsonl")
        jsonl(duplicate, cmd_rows)
        check("command code duplicate rejected", read("commandcode", sid) is None)
        duplicate.unlink()
        path = home / ".local/share/opencode/opencode.db"
        path.parent.mkdir(parents=True)
        with sqlite3.connect(path) as db:
            db.executescript("CREATE TABLE session(id TEXT PRIMARY KEY); CREATE TABLE message(id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT); CREATE TABLE part(id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, data TEXT);")
            db.executemany("INSERT INTO session VALUES(?)", [("ses_exact",), ("ses_other",)])
            db.executemany("INSERT INTO message VALUES(?,?,?,?)", [("m1", "ses_exact", 1, json.dumps({"role": "user"})), ("m2", "ses_other", 2, json.dumps({"role": "user"})), ("m3", "ses_exact", 3, json.dumps({"role": "assistant"}))])
            db.executemany("INSERT INTO part VALUES(?,?,?,?)", [("p1", "m1", "ses_exact", json.dumps({"type": "text", "text": "Exact project context"})), ("p2", "m2", "ses_other", json.dumps({"type": "text", "text": "Sibling must not leak"})), ("p3", "m3", "ses_other", json.dumps({"type": "text", "text": "Foreign part must not leak"})), ("p4", "m3", "ses_exact", json.dumps({"type": "tool", "text": "Tool must not leak"}))])
        original = path.read_bytes()
        value = read("opencode", "ses_exact")
        texts = [m["text"] for m in (value or {}).get("recentMessages", [])]
        check("opencode exact SID text only", texts == ["Exact project context"])
        check("opencode wrong SID rejected", read("opencode", "ses_missing") is None)
        check("opencode alias supported", read("opencode-go", "ses_exact") == value and value is not None)
        check("opencode database unchanged", path.read_bytes() == original)
        check("invalid SID rejected", read("opencode", "../ses_exact") is None)
        check("unknown tool rejected", read("unsupported", sid) is None)
        check("zero budget rejected", read("commandcode", sid, 0) is None)
        for name, passed in checks:
            print(("PASS " if passed else "FAIL ") + name)
        print(json.dumps({"passed": sum(p for _, p in checks), "failed": sum(not p for _, p in checks)}))
        return 0 if all(p for _, p in checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
