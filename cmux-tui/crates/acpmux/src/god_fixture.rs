//! A god home and a small one, the same shape, for every bench home (W0, 2026-11-12). Leo's
//! coordinator chat holds 81k messages, its Claude JSONL is 1.09 GB and its acpmux store 4.1 GB;
//! his daemon listed 525 chats and 26 peers' rows (10,848, about 75 keys each). On it the daemon
//! grew to 11 GB within 15 minutes of its start and took 93 s from socket-ready to "agents may
//! spawn". Leo, 2026-11-12: "even if a chat is long, there should be no percievable difference".
//!
//! [`Shape::god`] is that home; [`Shape::small`] is the same shape at a size no bench notices.
//! `ACPMUX_GOD_SCALE` (a fraction, `0.1`) shrinks the god chats for a quick run. A bench compares
//! the two in one harness: the god p95 must be at most 1.2x the small one's
//! (`docs/handbook/perf-regresses-on-degenerate-sessions.md` in cmuxterm-hq).
//!
//! - [`write_home`]: an acpmux home (`<home>/sessions`, through the store, so segments and
//!   indexes are the store's own) holding the god chat and `chats - 1` others, and each chat's
//!   Claude Code transcript under `<claude>/projects`.
//! - [`peer_row`]: one row of a peer's list with exactly `row_keys` keys, as a link reads it.
//! - [`peer_meta`]: a session record for a peer hub to list, shaped like a busy Claude chat's.

use serde_json::{Value, json};
use std::io::{self, BufWriter, Write};
use std::path::{Path, PathBuf};

/// The sizes of one home.
#[derive(Clone, Debug)]
pub struct Shape {
    pub name: &'static str,
    /// Chats in the store and in the Claude projects folder, the god chat among them.
    pub chats: usize,
    /// Messages in the god chat (lines of its Claude JSONL, turns of four in its acpmux log).
    pub god_messages: usize,
    /// Bytes of the god chat's Claude JSONL; its acpmux log is about the same.
    pub god_bytes: u64,
    /// Messages in each other chat.
    pub chat_messages: usize,
    pub peers: usize,
    pub peer_rows: usize,
    /// Top-level keys of each peer row.
    pub row_keys: usize,
}

impl Shape {
    /// Leo's home on 2026-11-12.
    pub fn god() -> Self {
        Self {
            name: "god",
            chats: 525,
            god_messages: 80_000,
            god_bytes: 1 << 30,
            chat_messages: 40,
            peers: 26,
            peer_rows: 400,
            row_keys: 75,
        }
    }

    /// The same shape, small: a chat of 200 messages and 2 MB, 5 chats, 2 peers of 20 rows.
    pub fn small() -> Self {
        Self {
            name: "small",
            chats: 5,
            god_messages: 200,
            god_bytes: 2 << 20,
            chat_messages: 40,
            peers: 2,
            peer_rows: 20,
            row_keys: 75,
        }
    }

    /// Summary changes for the connection pressure gate. Even small must fill
    /// the 4 MiB queue twice; god still sends its full 1 GiB.
    pub fn connection_change_bytes(&self) -> u64 {
        self.god_bytes.max(8 << 20)
    }

    /// [`Self::god`] times `ACPMUX_GOD_SCALE` (default 1): its messages, bytes and chats. The
    /// peers stay whole: their rows are the heap's suspect (26 x 400 x 75 keys).
    pub fn god_from_env() -> Self {
        let scale = std::env::var("ACPMUX_GOD_SCALE")
            .ok()
            .and_then(|v| v.parse::<f64>().ok())
            .filter(|s| *s > 0.0 && *s <= 1.0)
            .unwrap_or(1.0);
        let god = Self::god();
        let by = |n: usize| ((n as f64 * scale).ceil() as usize).max(1);
        Self {
            chats: by(god.chats),
            god_messages: by(god.god_messages),
            god_bytes: (god.god_bytes as f64 * scale) as u64,
            ..god
        }
    }
}

/// What [`write_home`] made.
#[derive(Clone, Debug)]
pub struct Home {
    /// The acpmux id of the god chat.
    pub god: String,
    /// The acpmux ids of the other chats.
    pub others: Vec<String>,
    /// The god chat's Claude JSONL.
    pub god_jsonl: PathBuf,
    /// Bytes written: the god chat's acpmux log and its JSONL.
    pub god_log_bytes: u64,
    pub god_jsonl_bytes: u64,
}

const AT: u64 = 1_791_540_000_000;

/// The acpmux id of chat `index` of `shape`: chat 0 is the god chat.
pub fn chat_id(index: usize) -> String {
    format!("01a1d000-0000-7000-8000-{index:012}")
}

/// The Claude session id of chat `index`.
pub fn agent_session_id(index: usize) -> String {
    format!("00000000-0000-4000-8000-{index:012}")
}

/// A session record shaped like a busy Claude chat's: config options, modes, tools, a preview,
/// and the last turn.
pub fn session_meta(
    id: &str,
    name: &str,
    cwd: &str,
    agent_session: &str,
    last_seq: u64,
    at: u64,
) -> Value {
    let options: Vec<Value> = (0..5)
        .map(|o| {
            json!({"category": if o == 0 { "model" } else { "other" }, "currentValue": "claude-opus-5-5",
                   "id": format!("opt{o}"), "name": format!("Option {o}"), "type": "select",
                   "options": (0..21).map(|c| json!({"name": format!("Choice {c} of option {o}"), "value": format!("v{o}-{c}")})).collect::<Vec<_>>()})
        })
        .collect();
    json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": name, "harness": "claude",
        "harnessArgv": ["claude"], "cwd": cwd, "agentSessionId": agent_session,
        "status": "idle", "createdAt": at, "updatedAt": at + 5_000, "lastSeq": last_seq,
        "eventCount": last_seq, "turnCount": last_seq / 4,
        "agentInfo": {"name": "claude-stdio", "title": "Claude Code", "version": null},
        "agentCapabilities": {"loadSession": true, "promptCapabilities": {"embeddedContext": true, "image": true}},
        "modes": {"availableModes": [{"id": "default", "name": "Default"}, {"id": "plan", "name": "Plan"}], "currentModeId": "default"},
        "configOptions": options,
        "title": format!("{name}: the coordinator of every lane"), "lastPrompt": "p".repeat(400),
        "preview": "y".repeat(600),
        "usage": {"sessionUpdate": "usage_update", "size": 200000, "used": 141234},
        "tags": {"cmux.chief": {"value": "2e448bc2"}, "cmux.chief.role": {"value": "coordinator"}},
        "lastTurn": {"endedAt": at + 5_000, "status": "completed", "stopReason": "end_turn", "turnId": format!("t-{id}")},
        "tools": {"rows": (0..12).map(|i| json!({"id": format!("mcp__cmux__tool_{i}"), "name": format!("tool_{i}"), "kind": "mcp", "source": "server", "enabled": true, "canToggle": true})).collect::<Vec<_>>(), "mutable": true},
    })
}

/// A peer hub's session record `index` (`peer_meta` for an in-process peer's store).
pub fn peer_meta(peer: &str, index: usize) -> Value {
    let id = format!("{peer}-{index:05}");
    session_meta(
        &id,
        &format!("{peer} lane {index}"),
        &format!("/home/agent/work/{peer}/{index}"),
        &agent_session_id(index),
        400,
        AT + index as u64,
    )
}

/// Row `index` of `peer`'s list with exactly `keys` top-level keys: the ids, status and times a
/// real row has, then plan, tags and counters, then short fields to the count.
pub fn peer_row(peer: &str, index: usize, keys: usize) -> Value {
    let mut row = serde_json::Map::new();
    let base = [
        ("sessionId", json!(format!("{peer}-{index:05}"))),
        ("name", json!(format!("{peer} lane {index}"))),
        ("harness", json!("claude")),
        ("cwd", json!(format!("/home/agent/work/{peer}/{index}"))),
        ("status", json!(if index.is_multiple_of(3) { "running" } else { "idle" })),
        ("createdAt", json!(AT)),
        ("updatedAt", json!(AT + index as u64)),
        (
            "title",
            json!(format!("lane {index}: the god fixture's row, a long title {}", "t".repeat(120))),
        ),
        ("lastPrompt", json!("p".repeat(300))),
        ("preview", json!("y".repeat(400))),
        ("agentSessionId", json!(agent_session_id(index))),
        ("planStep", json!({"step": 3, "of": 7, "text": "x".repeat(200)})),
        (
            "tags",
            json!({"cmux.lane": {"value": format!("w{index}")}, "cmux.chief.role": {"value": "lane"}}),
        ),
        ("usage", json!({"size": 200000, "used": 41234 + index})),
        (
            "lastTurn",
            json!({"endedAt": AT + 5_000, "status": "completed", "stopReason": "end_turn"}),
        ),
    ];
    for (k, v) in base.into_iter().take(keys) {
        row.insert(k.to_owned(), v);
    }
    let mut n = 0;
    while row.len() < keys {
        row.insert(format!("field{n:02}"), json!(format!("value {n} of row {index}")));
        n += 1;
    }
    Value::Object(row)
}

/// One chat's records: `messages` messages in turns of four (the prompt, a tool call, its output,
/// the answer), the output padded so the log is about `bytes`. Returns the bytes and the last seq.
fn append_log(
    store: &dyn crate::store::Store,
    id: &str,
    messages: usize,
    bytes: u64,
) -> io::Result<(u64, u64)> {
    let turns = messages.div_ceil(4).max(1);
    let pad = (bytes / turns as u64).saturating_sub(700) as usize;
    let output = "o".repeat(pad);
    let (mut seq, mut written) = (0u64, 0u64);
    let mut put = |kind: &str, dir: &str, msg: Value| -> io::Result<()> {
        seq += 1;
        let rec = crate::store::EventRecord {
            seq,
            at: AT + seq,
            dir: dir.into(),
            kind: kind.into(),
            msg,
            host_seq: None,
        };
        written += serde_json::to_string(&rec).map(|t| t.len() as u64 + 1).unwrap_or(0);
        store.append(id, &rec).map_err(|e| io::Error::other(e.to_string()))
    };
    let update = |update: Value| json!({"method": "session/update", "params": {"sessionId": id, "update": update}});
    for turn in 0..turns {
        let call = format!("call_{turn}");
        put("user_message", "mux", json!({"text": format!("prompt {turn}: what next?")}))?;
        put(
            "tool_call",
            "in",
            update(json!({"sessionUpdate": "tool_call", "toolCallId": call,
            "title": "cargo test", "kind": "execute", "status": "in_progress"})),
        )?;
        put(
            "tool_call_update",
            "in",
            update(json!({"sessionUpdate": "tool_call_update",
            "toolCallId": call, "status": "completed", "rawOutput": {"exit_code": 0},
            "content": [{"type": "content", "content": {"type": "text", "text": output}}]})),
        )?;
        put(
            "agent_message_chunk",
            "in",
            update(json!({"sessionUpdate": "agent_message_chunk",
            "content": {"type": "text", "text": format!("answer {turn}: done, next step follows")}})),
        )?;
    }
    Ok((written, seq))
}

/// A Claude Code transcript of `messages` lines and about `bytes`: a person's prompt, the
/// assistant's tool use, its result (padded) and the assistant's answer, in turn.
pub fn write_claude_jsonl(
    path: &Path,
    session: &str,
    cwd: &str,
    messages: usize,
    bytes: u64,
) -> io::Result<u64> {
    std::fs::create_dir_all(path.parent().unwrap_or(Path::new(".")))?;
    let mut out = BufWriter::with_capacity(1 << 20, std::fs::File::create(path)?);
    let pad = (bytes / messages.max(1) as u64 * 4).saturating_sub(1_200) as usize;
    let result = "r".repeat(pad);
    let mut written = 0u64;
    let mut parent = Value::Null;
    for i in 0..messages {
        let uuid = format!("00000000-0000-4000-9000-{i:012}");
        let (m, s) = (i / 60 % 60, i % 60);
        let stamp =
            format!("2026-10-{:02}T{:02}:{m:02}:{s:02}.000Z", 1 + i / 86_400 % 28, i / 3_600 % 24);
        let call = format!("toolu_{:020}", i / 4);
        let (kind, message) = match i % 4 {
            0 => (
                "user",
                json!({"role": "user", "content": format!("prompt {}: what next?", i / 4)}),
            ),
            1 => (
                "assistant",
                json!({"role": "assistant", "model": "claude-opus-5-5", "content": [
                {"type": "tool_use", "id": call, "name": "Bash", "input": {"command": "cargo test"}}]}),
            ),
            2 => (
                "user",
                json!({"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": call, "content": result}]}),
            ),
            _ => (
                "assistant",
                json!({"role": "assistant", "model": "claude-opus-5-5", "content": [
                {"type": "text", "text": format!("answer {}: done, next step follows", i / 4)}]}),
            ),
        };
        let line = json!({"type": kind, "isSidechain": false, "cwd": cwd, "sessionId": session,
            "uuid": uuid, "parentUuid": parent, "timestamp": stamp, "message": message});
        let text = line.to_string();
        out.write_all(text.as_bytes())?;
        out.write_all(b"\n")?;
        written += text.len() as u64 + 1;
        parent = json!(uuid);
    }
    out.flush()?;
    Ok(written)
}

/// The acpmux home `home` (its `sessions` through the store) and the Claude home `claude` (its
/// `projects`) of `shape`. Each chat works in a folder under `work` (50 of them, made here), so
/// its agent can start.
pub fn write_home(home: &Path, claude: &Path, work: &Path, shape: &Shape) -> io::Result<Home> {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Local;
    let store =
        crate::store::open(&cfg.store, home).map_err(|e| io::Error::other(e.to_string()))?;
    let projects = claude.join("projects");
    let mut made = Home {
        god: chat_id(0),
        others: Vec::new(),
        god_jsonl: PathBuf::new(),
        god_log_bytes: 0,
        god_jsonl_bytes: 0,
    };
    for index in 0..shape.chats.max(1) {
        let id = chat_id(index);
        let god = index == 0;
        let (messages, bytes) = if god {
            (shape.god_messages, shape.god_bytes)
        } else {
            (shape.chat_messages, 64 << 10)
        };
        let (log_bytes, last_seq) = append_log(store.as_ref(), &id, messages, bytes)?;
        let name = if god { "god".to_owned() } else { format!("chat-{index}") };
        let session = agent_session_id(index);
        let folder = work.join(format!("p{}", index % 50));
        std::fs::create_dir_all(&folder)?;
        let cwd = folder.to_string_lossy().into_owned();
        let meta = session_meta(&id, &name, &cwd, &session, last_seq, AT + index as u64);
        let meta = serde_json::from_value(meta).map_err(io::Error::other)?;
        store.save(&meta).map_err(|e| io::Error::other(e.to_string()))?;
        // Claude Code's project folder: the working folder with every `/` and `.` as `-`.
        let project = cwd.replace(['/', '.'], "-");
        let jsonl = projects.join(project).join(format!("{session}.jsonl"));
        let jsonl_bytes = write_claude_jsonl(&jsonl, &session, &cwd, messages, bytes)?;
        if god {
            (made.god_jsonl, made.god_log_bytes, made.god_jsonl_bytes) =
                (jsonl, log_bytes, jsonl_bytes);
        } else {
            made.others.push(id);
        }
    }
    store.flush().map_err(|e| io::Error::other(e.to_string()))?;
    Ok(made)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_peer_row_has_exactly_its_keys() {
        for keys in [3, 15, 75] {
            let row = peer_row("p", 7, keys);
            assert_eq!(row.as_object().unwrap().len(), keys);
            assert_eq!(row["sessionId"], "p-00007");
        }
    }

    #[test]
    fn the_small_home_is_the_god_shape_at_its_size() {
        let dir = tempfile::tempdir().unwrap();
        let (home, claude) = (dir.path().join("acpmux"), dir.path().join("claude"));
        let shape = Shape::small();
        let made = write_home(&home, &claude, &dir.path().join("work"), &shape).unwrap();
        assert_eq!(made.others.len(), shape.chats - 1);
        let jsonl = std::fs::read_to_string(&made.god_jsonl).unwrap();
        assert_eq!(jsonl.lines().count(), shape.god_messages);
        // Within 10% of the bytes asked for, the JSONL and the log alike.
        let near = |got: u64| got.abs_diff(shape.god_bytes) * 10 <= shape.god_bytes;
        assert!(near(made.god_jsonl_bytes), "{} of {}", made.god_jsonl_bytes, shape.god_bytes);
        assert!(near(made.god_log_bytes), "{} of {}", made.god_log_bytes, shape.god_bytes);
        let mut cfg = crate::config::Config::default();
        cfg.store.mode = crate::config::StoreMode::Local;
        let store = crate::store::open(&cfg.store, &home).unwrap();
        let metas = store.list().unwrap();
        assert_eq!(metas.len(), shape.chats);
        let god = metas.iter().find(|m| m.id == made.god).unwrap();
        assert_eq!(god.last_seq, shape.god_messages as u64);
    }
}
