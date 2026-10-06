#!/usr/bin/env python3
"""Merge per-tag Chief histories into the one Chief home (once).

Before the Chief home (plans/cmux-next/home-state-ownership.md), every DEV tag
kept its own Chief: an OptChat memory and host state in ~/.cmux/mux/tags/<tag>
and a Chief conversation in that tag's daemon store
(~/Library/Application Support/cmux/tags/<tag>/tui/<session>/conversations.sqlite3).
This tool builds the Chief home (~/.cmux/chief/default by default) from them:

- one Chief conversation in the Chief owner's store
  (<home>/tui/<session dir of cmux-chief-<hash>>/conversations.sqlite3), with
  every source's Chief messages in one order and their ids, authors, times and
  client ids kept;
- one OptChat memory (<home>/optchat/chat): the source memory with the most
  entries, copied with its git history and summaries, plus every human message
  no memory holds yet (a message a tag's host never logged), appended with its
  own time, so the chat and the memory hold the same human messages in the
  same order; several non-empty memories are interleaved by time into a fresh
  log whose summaries the compactor rebuilds;
- host.json bound to that conversation with every message logged.

Sources are only read (from copies of their SQLite files). --apply writes the
Chief home through a staging directory, then renames it into place, and keeps
a copy of each source in <home>/migration-backup/<time>/. A Chief home that
already has history is refused; a finished migration is recorded in
<home>/migration.json, and running it again with unchanged sources does
nothing.

Default: a dry run that prints the plan and counts. Usage:
  chief-home-migrate.py [--tag hmchief --tag hmchief3 ... | --tag-glob 'hmchief*']
                        [--into ~/.cmux/chief/default] [--apply] [--json]
  chief-home-migrate.py --source NAME=MUX_HOME:DB ...   (tests, explicit paths)
"""
import argparse
import datetime as dt
import fnmatch
import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time

AGENT = "agent_mux"
CHAT_TABLES = ("message", "op_ledger", "op_ledger_v2", "read_cursor", "agent_guard", "agent_token",
               "create_ledger", "conversation", "meta")


# ---- names shared with the app and cmux-tui ------------------------------------------------

def chief_session(root):
    """ChiefHome.sessionName: cmux-chief-<FNV-1a 32 of the standardized root path>."""
    h = 0x811C9DC5
    for b in os.path.normpath(os.path.abspath(root)).encode():
        h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF
    return "cmux-chief-%08x" % h


def session_component(session):
    """cmux-tui workspace_registry::session_storage_component."""
    readable, h = "", 0xCBF29CE484222325
    for b in session.encode():
        h = ((h ^ b) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
        if len(readable) < 48:
            readable += chr(b) if (chr(b).isascii() and (chr(b).isalnum() or chr(b) in "-_")) else "_"
    return "%s-%016x" % (readable or "session", h)


def tag_sources(tags, user_home):
    support = os.path.join(user_home, "Library/Application Support/cmux/tags")
    out = []
    for tag in tags:
        session = "cmux-app-" + tag
        db = os.path.join(support, tag, "tui", session_component(session), "conversations.sqlite3")
        out.append((tag, os.path.join(user_home, ".cmux/mux/tags", tag), db))
    return out


# ---- reading a source -----------------------------------------------------------------------

def parse_time(text):
    text = text.replace("Z", "+00:00")
    return dt.datetime.fromisoformat(text).timestamp()


def read_db(path, scratch):
    """The Chief conversation and everything else of one store, read from a copy."""
    if not os.path.exists(path):
        return None
    copy = os.path.join(scratch, hashlib.sha1(path.encode()).hexdigest())
    os.makedirs(copy, exist_ok=True)
    for suffix in ("", "-wal", "-shm"):
        if os.path.exists(path + suffix):
            shutil.copy2(path + suffix, os.path.join(copy, "c.sqlite3" + suffix))
    db = sqlite3.connect(os.path.join(copy, "c.sqlite3"))
    db.row_factory = sqlite3.Row
    rows = lambda sql, *a: [dict(r) for r in db.execute(sql, a)]
    convs = rows("select * from conversation")
    with_agent = [c for c in convs if any(p.get("id") == AGENT for p in json.loads(c["participants_json"]))]
    chief = min(with_agent, key=lambda c: (c["created_at"], c["id"])) if with_agent else None
    out = {
        "schema": [r["sql"] for r in rows("select sql from sqlite_master where sql is not null and name not like 'sqlite_%' order by rowid")],
        "meta": rows("select * from meta"),
        "chief": chief,
        "others": [c for c in convs if not chief or c["id"] != chief["id"]],
        "messages": {c["id"]: rows("select seq, id, message_json from message where conversation = ? order by seq", c["id"]) for c in convs},
        "cursors": rows("select * from read_cursor"),
        "ledger": rows("select * from op_ledger"),
        "ledger2": rows("select * from op_ledger_v2"),
        "create": rows("select * from create_ledger"),
        "guard": rows("select * from agent_guard"),
        "sha256": hashlib.sha256(b"".join(open(os.path.join(copy, "c.sqlite3" + s), "rb").read()
                                         for s in ("", "-wal") if os.path.exists(os.path.join(copy, "c.sqlite3" + s)))).hexdigest(),
    }
    db.close()
    return out


def read_log(chat):
    entries = []
    main = os.path.join(chat, "main")
    for name in sorted(os.listdir(main)) if os.path.isdir(main) else []:
        if name.endswith(".jsonl"):
            for line in open(os.path.join(main, name), encoding="utf-8"):
                if line.strip():
                    entries.append(json.loads(line))
    entries.sort(key=lambda e: e["i"])
    tree = 0
    tdir = os.path.join(chat, "tree")
    for name in os.listdir(tdir) if os.path.isdir(tdir) else []:
        tree += sum(1 for line in open(os.path.join(tdir, name), encoding="utf-8") if line.strip())
    return entries, tree


def host_running(mux_home):
    """Read-only: the pid in the host lock text, when that process is an optchat-chief host."""
    try:
        pid = int(open(os.path.join(mux_home, "state", "host.lock")).read().split()[0])
    except (OSError, ValueError, IndexError):
        return None
    try:
        os.kill(pid, 0)
    except OSError:
        return None
    comm = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True).stdout
    return pid if "optchat-chief" in comm or "mux" in comm else None


def owner_running(into):
    """Read-only: whether the Chief home's conversation owner answers on its socket."""
    import socket
    temp = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip() or "/tmp/"
    path = os.path.join(temp, "cmux-tui-%d" % os.getuid(), chief_session(into) + ".sock")
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(1)
            s.connect(path)
        return path
    except OSError:
        return None


def read_source(name, mux_home, db_path, scratch):
    log, tree = read_log(os.path.join(mux_home, "optchat", "chat"))
    host = {}
    try:
        host = json.load(open(os.path.join(mux_home, "optchat", "host.json")))
    except (OSError, ValueError):
        pass
    db = read_db(db_path, scratch)
    src = {"name": name, "mux_home": mux_home, "db_path": db_path, "db": db, "log": log, "tree": tree,
           "host": host, "host_pid": host_running(mux_home)}
    chief = db and db["chief"]
    src["chief_messages"] = []
    if chief:
        logged = host.get("logged_seq", 0) if host.get("conversation") == chief["id"] else 0
        for row in db["messages"][chief["id"]]:
            m = json.loads(row["message_json"])
            author = m.get("author", "")
            kind = "human" if author.startswith("user_") else (
                "reply" if (m.get("client_msg_id") or "").startswith("turn:") else "notice")
            src["chief_messages"].append({"source": name, "seq": row["seq"], "id": row["id"], "json": m,
                                          "kind": kind, "time": parse_time(m["created_at"]),
                                          "logged": kind == "human" and row["seq"] <= logged})
    return src


# ---- the merge ------------------------------------------------------------------------------

def plan(sources):
    with_chief = [s for s in sources if s["db"] and s["db"]["chief"]]
    if not with_chief and not any(s["log"] for s in sources):
        return {"empty": True}
    base = max(sources, key=lambda s: (len(s["log"]), len(s["chief_messages"]),
                                       -parse_time(s["db"]["chief"]["created_at"]) if s["db"] and s["db"]["chief"] else 0))
    rank = {s["name"]: k for k, s in enumerate(sources)}
    seen_ids, seen_keys, duplicates, merged = set(), set(), [], []
    for m in sorted((m for s in sources for m in s["chief_messages"]),
                    key=lambda m: (m["time"], rank[m["source"]], m["seq"])):
        key = (m["json"].get("author"), m["json"].get("client_msg_id"))
        if m["id"] in seen_ids or (key[1] and key in seen_keys):
            duplicates.append(m)
            continue
        seen_ids.add(m["id"])
        seen_keys.add(key)
        merged.append(m)
    logs = [s for s in sources if s["log"]]
    if len(logs) <= 1:
        log_mode = "copy" if logs else "fresh"
        log_base = logs[0] if logs else None
        # The memory's last message: a logged human message or a reply of the
        # source whose memory is copied.
        held = [m["time"] for m in merged if m["source"] == (log_base or {}).get("name")
                and ((m["kind"] == "human" and m["logged"]) or m["kind"] == "reply")]
        last_logged = max(held) if held else float("-inf")
    else:
        log_mode, log_base, last_logged = "interleave", None, float("-inf")
    # Memory order wins: an unlogged human message dated before the last
    # message the memory already holds moves after it (with what follows it
    # from the same source), so the chat and the memory never disagree.
    def in_memory(m):
        if log_mode == "copy":
            return m["logged"] and m["source"] == log_base["name"]
        return log_mode == "interleave" and m["logged"]
    unlogged = [m for m in merged if m["kind"] == "human" and not in_memory(m)]
    moved = [m for m in unlogged if m["time"] < last_logged] if log_mode == "copy" else []
    if moved:
        # Each moves to just after the memory's last message, keeping the
        # order among the messages that move; the memory appends them alike.
        moved_ids = {m["id"] for m in moved}
        effective = lambda m: last_logged if m["id"] in moved_ids else m["time"]
        merged = sorted(merged, key=lambda m: (effective(m), m["id"] in moved_ids, m["time"]))
        unlogged = [m for m in merged if m in unlogged]
    orphan_replies = [m for m in merged if m["kind"] == "reply" and (log_mode == "fresh" or (log_mode == "copy" and m["source"] != log_base["name"]))]
    chief = base["db"]["chief"] if base["db"] and base["db"]["chief"] else (with_chief[0]["db"]["chief"] if with_chief else {"id": None})
    return {"empty": False, "base": base, "chief_id": chief["id"], "merged": merged, "duplicates": duplicates, "log_mode": log_mode,
            "log_base": log_base, "unlogged": unlogged, "moved": moved, "orphan_replies": orphan_replies}


def local_iso(seconds):
    return dt.datetime.fromtimestamp(seconds).astimezone().isoformat(timespec="milliseconds")


def main_line(i, kind, text, date):
    return json.dumps({"i": i, "kind": kind, "text": text, "size": len(kind.encode()) + 2 + len(text.encode()),
                       "date": date}, ensure_ascii=False, separators=(",", ":")) + "\n"


def message_text(m):
    return "\n".join(p.get("text", "") for p in m["json"].get("parts", []) if p.get("type") == "text")


# ---- writing --------------------------------------------------------------------------------

def write_log(p, chat):
    os.makedirs(os.path.join(chat, "main"), exist_ok=True)
    os.makedirs(os.path.join(chat, "tree"), exist_ok=True)
    if p["log_mode"] == "copy":
        src = os.path.join(p["log_base"]["mux_home"], "optchat", "chat")
        shutil.rmtree(chat)
        shutil.copytree(src, chat, ignore=shutil.ignore_patterns("lock", "takeover.flock", "*.tmp*"))
        entries = list(p["log_base"]["log"])
    elif p["log_mode"] == "interleave":
        entries = sorted((e for s in p["sources"] for e in s["log"]), key=lambda e: parse_time(e["date"]))
        entries = [dict(e, i=k) for k, e in enumerate(entries)]
        for e in entries:
            with open(os.path.join(chat, "main", e["date"][:10] + ".jsonl"), "a", encoding="utf-8") as f:
                f.write(main_line(e["i"], e["kind"], e["text"], e["date"]))
    else:
        entries = []
    appended = 0
    for m in p["unlogged"]:
        date = local_iso(m["time"])
        with open(os.path.join(chat, "main", date[:10] + ".jsonl"), "a", encoding="utf-8") as f:
            f.write(main_line(len(entries) + appended, "user", message_text(m), date))
        appended += 1
    if shutil.which("git"):
        if not os.path.isdir(os.path.join(chat, ".git")):
            subprocess.run(["git", "init", "-q", chat], check=True)
        subprocess.run(["git", "-C", chat, "add", "-A"], check=True)
        subprocess.run(["git", "-C", chat, "-c", "user.name=cmux", "-c", "user.email=cmux@localhost", "commit", "-q",
                        "--allow-empty", "-m", "migrate: Chief home from %s" % ", ".join(s["name"] for s in p["sources"])],
                       check=True)
    return len(entries) + appended


def write_db(p, path):
    base_db = p["base"]["db"] or next(s["db"] for s in p["sources"] if s["db"])
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    db = sqlite3.connect(path)
    for sql in base_db["schema"]:
        db.execute(sql)
    for row in base_db["meta"]:
        db.execute("insert into meta(key, value) values (?, ?)", (row["key"], row["value"]))
    chief_src = p["base"]["db"]["chief"] if p["base"]["db"] and p["base"]["db"]["chief"] else \
        next(s["db"]["chief"] for s in p["sources"] if s["db"] and s["db"]["chief"])
    chief_id, merged = chief_src["id"], p["merged"]
    new_seq = {}
    for seq, m in enumerate(merged, 1):
        body = dict(m["json"], conversation=chief_id, seq=seq)
        new_seq[(m["source"], m["seq"])] = seq
        db.execute("insert into message(conversation, seq, id, message_json) values (?, ?, ?, ?)",
                   (chief_id, seq, m["id"], json.dumps(body, ensure_ascii=False, separators=(",", ":"))))
    n = len(merged)
    created = min(s["db"]["chief"]["created_at"] for s in p["sources"] if s["db"] and s["db"]["chief"])
    updated = merged[-1]["json"]["created_at"] if merged else chief_src["updated_at"]
    db.execute("insert into conversation(id, title, participants_json, last_seq, rev, created_at, updated_at) values (?,?,?,?,?,?,?)",
               (chief_id, chief_src["title"], chief_src["participants_json"], n, n + 1, created, updated))
    cursors = {AGENT: n}
    for s in p["sources"]:
        if not (s["db"] and s["db"]["chief"]):
            continue
        for c in s["db"]["cursors"]:
            if c["conversation"] == s["db"]["chief"]["id"] and c["participant"] != AGENT:
                mapped = max([v for (src, seq), v in new_seq.items() if src == s["name"] and seq <= c["seq"]], default=0)
                cursors[c["participant"]] = max(cursors.get(c["participant"], 0), mapped)
    for who, seq in cursors.items():
        db.execute("insert into read_cursor(conversation, participant, seq) values (?, ?, ?)", (chief_id, who, seq))
    streak, last_agent = 0, None
    for m in reversed(merged):
        if m["json"].get("author") != AGENT:
            break
        streak += 1
        last_agent = last_agent or m["json"]["created_at"]
    db.execute("insert into agent_guard(conversation, agent_text_streak, last_agent_text_at) values (?, ?, ?)",
               (chief_id, streak, last_agent))
    chief_ids = {s["db"]["chief"]["id"] for s in p["sources"] if s["db"] and s["db"]["chief"]}
    keys = set()
    for s in p["sources"]:
        if not s["db"]:
            continue
        for row in s["db"]["create"]:
            conv = chief_id if row["conversation"] in chief_ids else row["conversation"]
            if row["idempotency_key"] not in keys:
                keys.add(row["idempotency_key"])
                db.execute("insert into create_ledger(idempotency_key, fingerprint, conversation) values (?, ?, ?)",
                           (row["idempotency_key"], row["fingerprint"], conv))
        # Other conversations (not the Chief) move as they are.
        for c in s["db"]["others"]:
            if db.execute("select 1 from conversation where id = ?", (c["id"],)).fetchone():
                continue
            db.execute("insert into conversation values (:id, :title, :participants_json, :last_seq, :rev, :created_at, :updated_at)", c)
            for row in s["db"]["messages"][c["id"]]:
                db.execute("insert into message values (?, ?, ?, ?)", (c["id"], row["seq"], row["id"], row["message_json"]))
            for table, rows in (("read_cursor", s["db"]["cursors"]), ("op_ledger", s["db"]["ledger"]),
                                ("op_ledger_v2", s["db"]["ledger2"]), ("agent_guard", s["db"]["guard"])):
                for row in rows:
                    if row["conversation"] == c["id"]:
                        cols = ", ".join(row)
                        db.execute("insert into %s (%s) values (%s)" % (table, cols, ", ".join("?" * len(row))), tuple(row.values()))
    db.commit()
    db.close()
    os.chmod(path, 0o600)
    return chief_id


def apply(p, into, user_home):
    stamp = time.strftime("%Y%m%d-%H%M%S")
    parent = os.path.dirname(os.path.normpath(into))
    os.makedirs(parent, exist_ok=True)
    stage = tempfile.mkdtemp(prefix=".chief-migrating-", dir=parent)
    os.chmod(stage, 0o700)
    session = chief_session(into)
    db_path = os.path.join(stage, "tui", session_component(session), "conversations.sqlite3")
    chief_id = write_db(p, db_path)
    optchat = os.path.join(stage, "optchat")
    os.makedirs(optchat, mode=0o700)
    entries = write_log(p, os.path.join(optchat, "chat"))
    host = {"conversation": chief_id, "logged_seq": len(p["merged"]), "outbox": [], "turn": None,
            "children": {}, "orphans": []}
    with open(os.path.join(optchat, "host.json"), "w") as f:
        json.dump(host, f)
    os.chmod(os.path.join(optchat, "host.json"), 0o600)
    for name in ("AGENTS.md", "engine.json"):
        src = os.path.join(p["base"]["mux_home"], "optchat", name)
        if os.path.exists(src):
            shutil.copy2(src, os.path.join(optchat, name))
    backup = os.path.join(stage, "migration-backup", stamp)
    for s in p["sources"]:
        dest = os.path.join(backup, s["name"])
        if os.path.isdir(s["mux_home"]):
            shutil.copytree(s["mux_home"], os.path.join(dest, "mux-home"), symlinks=True,
                            ignore=shutil.ignore_patterns("*.sock", "lock", "takeover.flock"))
        os.makedirs(os.path.join(dest, "conversations"), exist_ok=True)
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(s["db_path"] + suffix):
                shutil.copy2(s["db_path"] + suffix, os.path.join(dest, "conversations"))
    record = {"migrated_at": stamp, "session": session, "conversation": chief_id, "messages": len(p["merged"]),
              "log_entries": entries, "sources": [{"name": s["name"], "mux_home": s["mux_home"], "db": s["db_path"],
                                                   "db_sha256": s["db"] and s["db"]["sha256"], "log_entries": len(s["log"])}
                                                  for s in p["sources"]]}
    with open(os.path.join(stage, "migration.json"), "w") as f:
        json.dump(record, f, indent=2)
    if os.path.exists(into):
        os.rename(into, os.path.join(parent, ".chief-replaced-%s-%s" % (os.path.basename(into), stamp)))
    os.rename(stage, into)
    return record


# ---- checks and report ----------------------------------------------------------------------

def target_state(into):
    """Whether the Chief home has history of its own (then it is refused)."""
    record = os.path.join(into, "migration.json")
    if os.path.exists(record):
        return "migrated", json.load(open(record))
    log, _ = read_log(os.path.join(into, "optchat", "chat"))
    session = chief_session(into)
    db = os.path.join(into, "tui", session_component(session), "conversations.sqlite3")
    humans = 0
    if os.path.exists(db):
        with tempfile.TemporaryDirectory() as scratch:
            data = read_db(db, scratch)
            humans = sum(1 for rows in data["messages"].values() for r in rows
                         if json.loads(r["message_json"]).get("author", "").startswith("user_"))
    if log or humans:
        return "history", {"log_entries": len(log), "human_messages": humans}
    return ("empty" if os.path.exists(into) else "absent"), None


def report(sources, p, into, state):
    lines = ["Chief home: %s (owner session %s)" % (into, chief_session(into)),
             "Chief home now: %s%s" % (state[0], "" if not state[1] else " " + json.dumps(state[1])), "", "Sources:"]
    for s in sources:
        msgs = s["chief_messages"]
        count = lambda k: sum(1 for m in msgs if m["kind"] == k)
        kinds = {}
        for e in s["log"]:
            kinds[e["kind"]] = kinds.get(e["kind"], 0) + 1
        others = len(s["db"]["others"]) if s["db"] else 0
        lines.append("  %-10s conversation %s: %d messages (%d human, %d replies, %d notices), %d other conversations"
                     % (s["name"], s["db"]["chief"]["id"] if s["db"] and s["db"]["chief"] else "-", len(msgs),
                        count("human"), count("reply"), count("notice"), others))
        lines.append("             memory: %d entries %s, %d summaries; host logged_seq %s; children %d; outbox %d; turn %s; host %s"
                     % (len(s["log"]), json.dumps(kinds, sort_keys=True), s["tree"], s["host"].get("logged_seq", "-"),
                        len(s["host"].get("children") or {}), len(s["host"].get("outbox") or []),
                        "pending" if s["host"].get("turn") else "none",
                        "RUNNING pid %d" % s["host_pid"] if s["host_pid"] else "stopped"))
    if p["empty"]:
        lines += ["", "Nothing to merge."]
        return "\n".join(lines)
    lines += ["", "Plan:",
              "  conversation: %s (from %s), %d messages, %d duplicates dropped"
              % (p["chief_id"], p["base"]["name"], len(p["merged"]), len(p["duplicates"])),
              "  memory: %s%s; %d human messages no memory held are appended (%s)"
              % (p["log_mode"], " of " + p["log_base"]["name"] if p["log_base"] else "", len(p["unlogged"]),
                 ", ".join("%s seq %d" % (m["source"], m["seq"]) for m in p["unlogged"]) or "none")]
    if p["log_mode"] == "interleave":
        lines.append("  memory summaries are dropped; the compactor rebuilds them at the next host start")
    if p["moved"]:
        lines.append("  %d messages move after the memory's last message so the chat and the memory agree" % len(p["moved"]))
    if p["orphan_replies"]:
        lines.append("  WARNING: %d Chief replies are in no memory; they stay in the chat only" % len(p["orphan_replies"]))
    lines.append("  order (time, source, author: text):")
    for m in p["merged"]:
        lines.append("    %s %-9s %-10s %s" % (local_iso(m["time"])[:19], m["source"], m["json"].get("author"),
                                             message_text(m).replace("\n", " ")[:70]))
    dropped = sum(len(s["host"].get("children") or {}) for s in sources)
    if dropped:
        lines.append("  %d subagent records stay with their tag's acpmux and are not carried" % dropped)
    if owner_running(into):
        lines.append("  BLOCKER for --apply: the Chief home's conversation owner runs; quit the build that opened it")
    running = [s["name"] for s in sources if s["host_pid"]]
    if running:
        lines.append("  BLOCKER for --apply: hosts still run for %s (quit those builds; a host outlives its app: stop it by pid)" % ", ".join(running))
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tag", action="append", default=[])
    ap.add_argument("--tag-glob")
    ap.add_argument("--source", action="append", default=[], help="NAME=MUX_HOME:DB")
    ap.add_argument("--into")
    ap.add_argument("--user-home", default=os.path.expanduser("~"))
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--json", action="store_true")
    opts = ap.parse_args(argv)
    into = os.path.normpath(os.path.abspath(opts.into or os.path.join(opts.user_home, ".cmux/chief/default")))
    tags = list(opts.tag)
    if opts.tag_glob:
        root = os.path.join(opts.user_home, ".cmux/mux/tags")
        tags += sorted(t for t in os.listdir(root) if fnmatch.fnmatch(t, opts.tag_glob) and t not in tags) if os.path.isdir(root) else []
    triples = tag_sources(tags, opts.user_home)
    for spec in opts.source:
        name, rest = spec.split("=", 1)
        mux_home, db = rest.split(":", 1)
        triples.append((name, mux_home, db))
    if not triples:
        ap.error("name sources with --tag, --tag-glob or --source")
    with tempfile.TemporaryDirectory() as scratch:
        sources = [read_source(n, m, d, scratch) for n, m, d in triples]
        p = plan(sources)
        if not p["empty"]:
            p["sources"] = sources
        state = target_state(into)
        if state[0] == "migrated":
            same = {(r["name"], r["db_sha256"], r["log_entries"]) for r in state[1]["sources"]} == \
                   {(s["name"], s["db"] and s["db"]["sha256"], len(s["log"])) for s in sources}
            print("Already migrated at %s%s." % (state[1]["migrated_at"], "" if same else
                  "; the sources changed since (new messages in an old tag stay there)"))
            return 0 if same else 3
        text = report(sources, p, into, state)
        if opts.json:
            print(json.dumps({"into": into, "state": state[0], "report": text.splitlines()}, indent=2))
        else:
            print(text)
        if not opts.apply:
            print("\nDry run: nothing was written. Apply with the same arguments and --apply.")
            return 0
        if p["empty"]:
            return 0
        if state[0] == "history":
            print("Refused: the Chief home already has history of its own.", file=sys.stderr)
            return 4
        if any(s["host_pid"] for s in sources) or host_running(into):
            print("Refused: a Chief host still runs; stop it first.", file=sys.stderr)
            return 5
        if owner_running(into):
            print("Refused: the Chief home's conversation owner runs (a build with the Chief home opened Home); "
                  "quit it and stop that cmux-tui session first.", file=sys.stderr)
            return 6
        record = apply(p, into, opts.user_home)
        print("\nMigrated: %d messages, %d memory entries into %s." % (record["messages"], record["log_entries"], into))
    return 0


if __name__ == "__main__":
    sys.exit(main())
