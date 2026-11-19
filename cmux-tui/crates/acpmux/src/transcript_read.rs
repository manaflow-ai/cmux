//! `_acpmux/transcript_read {sessionId? | harnessSessionId?, line? | turn?, subagent?, before?,
//! after?, tools?, maxBytes?, host?}`, `acpmux search --show` and the agents' `transcript_read`
//! tool: the text around a `transcript_search` hit (Leo, 2026-11-18: "shouldn't you be able to
//! like have better tools for finding stuff?"). A hit names a session, a line and a turn; this
//! reads the message there whole and unescaped and up to `before` and `after` messages next to it,
//! or (`turn`) every message of that turn and up to `before` and `after` turns next to it, from
//! the same index (`acpmux_transcript_search::read`), never more than `maxBytes` of text.
//!
//! Answer: `{host, sessionId, harness, file, subagent, lines, turns, files: [{file, subagent,
//! lines, turns}], messages: [{line, turn, at, role, text, anchor, capped?, cut?}], moreBefore,
//! moreAfter, truncated, bytes, tookMs}`. `file` is the transcript's file name (a subagent's is
//! what `subagent` names); `anchor` marks the messages at the line or in the turn asked for.
//!
//! The caller names a session, never a path: the daemon finds the session's transcripts as the
//! search does (`Roots::session`) and reads only what the index holds of them. What a chat said
//! is its person's: the daemon answers this on its own socket, to the app and to its peers only,
//! as `_acpmux/transcript_search`.

use std::sync::Mutex;
use std::time::Instant;

use acpmux_transcript_search::{self as ts, read as tr};
use serde_json::{Value, json};

use crate::json_put::put;
use crate::transcript_search::index_path;

pub const DEFAULT_AROUND: usize = 2;

/// What the `transcript_search` tool's text ends with when it found something.
pub const SEARCH_HINT: &str = "Read a hit whole, with the messages around it: transcript_read \
{session: its session id, line: its line} (and subagent, host as the hit names them); turn \
instead of line reads that whole turn.\n";

/// The agents' `transcript_read` tool (`acpmux_mcp.rs`).
pub fn mcp_tool() -> Value {
    json!({
        "name": "transcript_read",
        "description": "Read what was said where a transcript_search hit is: the message at its line whole (as written, unescaped; a tool call or its output too) and the messages next to it, or (turn) every message of one turn. Give the hit's session and line, and its subagent and host when it names them. `acpmux search --show SESSION:LINE` on the command line.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "session": {"type": "string", "description": "The hit's session id (a Claude Code or Codex session), or self (this chat), a name or an acpmux session id."},
                "line": {"type": "integer", "minimum": 1, "description": "The hit's line: read the message there."},
                "turn": {"type": "integer", "minimum": 0, "description": "Instead of line: every message of this turn (the hit's turn)."},
                "before": {"type": "integer", "minimum": 0, "maximum": acpmux_transcript_search::read::MAX_AROUND, "description": "How many messages (with turn: turns) before it to read too. Default 2 with line, 0 with turn."},
                "after": {"type": "integer", "minimum": 0, "maximum": acpmux_transcript_search::read::MAX_AROUND, "description": "How many messages (with turn: turns) after it. Default 2 with line, 0 with turn."},
                "subagent": {"type": "string", "description": "The subagent transcript the hit is in, by the name the hit shows (agent-...)."},
                "tools": {"type": "boolean", "description": "false: leave tool calls and their output out of the messages around it. Default true."},
                "maxBytes": {"type": "integer", "minimum": 1, "maximum": acpmux_transcript_search::read::MAX_BYTES, "description": "The most text to return (default 32768)."},
                "host": {"type": "string", "description": "The peer the hit is on, when it names one."}
            },
            "required": ["session"]
        }
    })
}

/// One read, as the wire names it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Params {
    /// An acpmux session (id, name): the daemon finds its harness session.
    pub session: Option<String>,
    /// A harness session id (a Claude Code session, a Codex thread) itself.
    pub harness_session: Option<String>,
    pub subagent: Option<String>,
    pub line: Option<u64>,
    pub turn: Option<u32>,
    pub before: Option<usize>,
    pub after: Option<usize>,
    pub tools: Option<bool>,
    pub max_bytes: Option<usize>,
    /// A peer's name: read there; none (or this machine's name, or `local`): here.
    pub host: Option<String>,
}

impl Params {
    pub fn from_value(v: &Value) -> Result<Self, String> {
        let text = |k: &str| {
            v.get(k)
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
        };
        let count = |k: &str| v.get(k).and_then(Value::as_u64).map(|n| n as usize);
        let p = Self {
            session: text("sessionId"),
            harness_session: text("harnessSessionId"),
            subagent: text("subagent"),
            line: v.get("line").and_then(Value::as_u64),
            turn: v.get("turn").and_then(Value::as_u64).map(|t| t.min(u64::from(u32::MAX)) as u32),
            before: count("before"),
            after: count("after"),
            tools: v.get("tools").and_then(Value::as_bool),
            max_bytes: count("maxBytes"),
            host: text("host"),
        };
        if p.session.is_none() && p.harness_session.is_none() {
            return Err("sessionId or harnessSessionId is required".into());
        }
        match (p.line, p.turn) {
            (None, None) => {
                Err("line or turn is required (a transcript_search hit has both)".into())
            }
            (Some(_), Some(_)) => Err("give line or turn, not both".into()),
            (Some(0), _) => Err("line counts from 1".into()),
            _ if p.host.as_deref() == Some("all") => {
                Err("a read is of one machine: host is a peer's name (the hit's host)".into())
            }
            _ => Ok(p),
        }
    }

    pub fn to_value(&self) -> Value {
        let mut v = json!({});
        let mut set = |k: &str, x: Value| {
            if !x.is_null() {
                put(&mut v, k, x);
            }
        };
        set("sessionId", json!(self.session));
        set("harnessSessionId", json!(self.harness_session));
        set("subagent", json!(self.subagent));
        set("line", json!(self.line));
        set("turn", json!(self.turn));
        set("before", json!(self.before));
        set("after", json!(self.after));
        set("tools", json!(self.tools));
        set("maxBytes", json!(self.max_bytes));
        set("host", json!(self.host));
        v
    }

    /// The read of harness session `session`. A line reads [`DEFAULT_AROUND`] messages each side
    /// unless told otherwise; a turn reads that turn only.
    pub fn query(&self, session: &str) -> tr::ReadQuery {
        let (at, around) = match (self.line, self.turn) {
            (Some(line), _) => (tr::At::Line(line), DEFAULT_AROUND),
            (None, turn) => (tr::At::Turn(turn.unwrap_or(1)), 0),
        };
        let mut q = tr::ReadQuery::new(session, at);
        q.subagent = self.subagent.clone();
        q.before = self.before.unwrap_or(around).min(tr::MAX_AROUND);
        q.after = self.after.unwrap_or(around).min(tr::MAX_AROUND);
        q.tools = self.tools.unwrap_or(true);
        q.max_bytes = self.max_bytes.unwrap_or(tr::DEFAULT_MAX_BYTES).clamp(1, tr::MAX_BYTES);
        q
    }
}

/// Why a read answered nothing.
#[derive(Debug)]
pub enum Error {
    /// No such session, transcript, line or turn here.
    NotFound(String),
    Other(String),
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotFound(m) | Self::Other(m) => f.write_str(m),
        }
    }
}

/// This process's connections: the index (to catch the session's transcripts up first) and a
/// reader of it, each opened on first use.
static INDEX: Mutex<Option<ts::Index>> = Mutex::new(None);
static READER: Mutex<Option<tr::Reader>> = Mutex::new(None);

/// One read of this machine's transcripts of harness session `session`. Blocking: it first reads
/// what the session's transcripts appended since the index last did.
pub fn read_here(
    p: &Params,
    session: &str,
    roots: &ts::Roots,
    host: Option<&str>,
) -> Result<Value, Error> {
    let started = Instant::now();
    {
        let mut index = INDEX.lock().unwrap_or_else(|e| e.into_inner());
        if index.is_none() {
            *index = Some(ts::Index::open(&index_path()).map_err(other)?);
        }
        if let Some(index) = index.as_ref() {
            catch_up(index, session, roots)?;
        }
    }
    let mut reader = READER.lock().unwrap_or_else(|e| e.into_inner());
    if reader.is_none() {
        *reader = Some(tr::Reader::open(&index_path()).map_err(other)?);
    }
    let Some(reader) = reader.as_ref() else { return Err(Error::Other("not open".into())) };
    read_with(reader, p, session, host, started)
}

fn other(e: ts::Error) -> Error {
    Error::Other(format!("transcript index: {e}"))
}

/// Reads what the transcripts of `session` appended since the index last did.
fn catch_up(index: &ts::Index, session: &str, roots: &ts::Roots) -> Result<(), Error> {
    for source in roots.session(session) {
        index.catch_up(&source).map_err(other)?;
    }
    Ok(())
}

/// The read of a caught-up index, as the wire answers it.
fn read_with(
    reader: &tr::Reader,
    p: &Params,
    session: &str,
    host: Option<&str>,
    started: Instant,
) -> Result<Value, Error> {
    let read = reader.read(&p.query(session)).map_err(|e| match e {
        tr::ReadError::NotFound(m) => Error::NotFound(m),
        tr::ReadError::Index(e) => other(e),
    })?;
    Ok(answer(&read, session, host, started.elapsed().as_millis() as u64))
}

/// The wire answer of `read`.
pub fn answer(read: &tr::Read, session: &str, host: Option<&str>, took_ms: u64) -> Value {
    let bytes: usize = read.messages.iter().map(|m| m.text.len()).sum();
    let messages: Vec<Value> = read
        .messages
        .iter()
        .map(|m| {
            let mut v = json!({
                "line": m.line,
                "turn": m.turn,
                "at": m.at_ms,
                "role": m.role.as_str(),
                "text": m.text,
                "anchor": m.anchor,
            });
            if m.capped {
                put(&mut v, "capped", json!(true));
            }
            if m.cut {
                put(&mut v, "cut", json!(true));
            }
            v
        })
        .collect();
    json!({
        "host": host,
        "sessionId": session,
        "harness": read.file.harness.as_str(),
        "file": read.file.name,
        "subagent": read.file.subagent,
        "lines": read.file.lines,
        "turns": read.file.turns,
        "files": read.files.iter().map(|f| json!({
            "file": f.name, "subagent": f.subagent, "lines": f.lines, "turns": f.turns,
        })).collect::<Vec<_>>(),
        "messages": messages,
        "moreBefore": read.more_before,
        "moreAfter": read.more_after,
        "truncated": read.truncated,
        "bytes": bytes,
        "tookMs": took_ms,
    })
}

/// What `acpmux search --show` prints and the `transcript_read` tool answers as text: a header,
/// then each message with its place, its text indented as written.
pub fn text(answer: &Value) -> String {
    let field = |k: &str| answer[k].as_str().unwrap_or_default();
    let host = answer["host"].as_str().map(|h| format!("{h}/")).unwrap_or_default();
    let sub = if answer["subagent"] == true {
        format!(" (subagent {})", field("file"))
    } else {
        String::new()
    };
    let mut out = format!(
        "{host}{}{sub}  {}  {} lines, {} turns\n",
        field("sessionId"),
        field("harness"),
        answer["lines"].as_u64().unwrap_or(0),
        answer["turns"].as_u64().unwrap_or(0),
    );
    if answer["moreBefore"] == true {
        out.push_str("    (earlier messages not shown)\n");
    }
    out.push('\n');
    for m in answer["messages"].as_array().into_iter().flatten() {
        let when = m["at"]
            .as_u64()
            .map(|at| format!("{} ago", crate::cli::output::age(at)))
            .unwrap_or_else(|| "-".into());
        let mark = if m["anchor"] == true { "> " } else { "  " };
        let mut notes = Vec::new();
        if m["capped"] == true {
            notes.push("the index keeps only its start");
        }
        if m["cut"] == true {
            notes.push("cut to maxBytes");
        }
        let notes =
            if notes.is_empty() { String::new() } else { format!("  ({})", notes.join(", ")) };
        out.push_str(&format!(
            "{mark}line {}  turn {}  {when}  {}{notes}\n",
            m["line"].as_u64().unwrap_or(0),
            m["turn"].as_u64().unwrap_or(0),
            m["role"].as_str().unwrap_or_default(),
        ));
        for line in m["text"].as_str().unwrap_or_default().lines() {
            out.push_str("    ");
            out.push_str(line);
            out.push('\n');
        }
        out.push('\n');
    }
    let mut tail = Vec::new();
    if answer["moreAfter"] == true {
        tail.push("later messages not shown");
    }
    if answer["truncated"] == true {
        tail.push("some left out to stay within maxBytes: ask for fewer, or a larger maxBytes");
    }
    if !tail.is_empty() {
        out.push_str(&format!("({})\n", tail.join("; ")));
    }
    let subagents: Vec<&str> = answer["files"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|f| f["subagent"] == true)
        .filter_map(|f| f["file"].as_str())
        .collect();
    if !subagents.is_empty() && answer["subagent"] != true {
        out.push_str(&format!("(subagent transcripts: {})\n", subagents.join(", ")));
    }
    out
}

#[cfg(test)]
#[path = "transcript_read_tests.rs"]
mod tests;
