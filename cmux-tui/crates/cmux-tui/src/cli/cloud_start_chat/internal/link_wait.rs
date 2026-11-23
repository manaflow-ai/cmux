//! A Cloud chat's turn, pushed over the machine's existing link (Leo, 2026-11-10: "have we figured out where the
//! 26.5 seconds were yet?"; the two trailing `cloud exec` polls of `acp wait` and `acp last` took 1091 + 2590 ms).
//!
//! The app holds the machine's link and answers its stream socket (`cloud.machine_stream {machine}` →
//! `{socket}`): a local Unix socket each connection of which reaches the machine's session daemon over that link,
//! the way the app's own chat pane attaches. This side does the rest, in Rust: `identify`, then
//! `agent-session-attach` on the chat's tab (cmux-tui/spec/commands.md "Agent session attach"; it only reads: a
//! link connection is the machine's Native owner carrier, which admits attach but not `agent-session-observe`), and
//! the records pushed after it until the turn ends (a `mux` `turn_end`), the agent asks a permission, the attachment
//! closes, or the wait passes.

use std::io::{BufRead as _, BufReader, Write as _};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, Instant};

use cmux_lifeline::vm::{Attached, Ready, Unidentified, Vm};
use serde_json::{Value, json};

/// The capability a daemon serves `agent-session-attach` under.
const ATTACH: &str = "agent-session-attach-v1";
/// Records asked per page.
const PAGE: u64 = 500;
/// At most this many records in one wait; a longer turn's next wait starts after the last one.
pub(crate) const KEPT: usize = 2000;

/// One wait's answer: `{records, last_seq, ended}`, `ended` one of `turn_end`, `permission`, `closed`, `more` or
/// `timeout`. An error is a link this side could not read (no socket, no capability, a refusal), or
/// [`Failure::Timeout`] when the wait passed before the attach answered.
pub(crate) fn observe(
    socket: &Path,
    surface: u64,
    after: u64,
    wait: Duration,
) -> Result<Value, Failure> {
    let deadline = Instant::now() + wait;
    let connection = connect(socket, deadline)?;
    let ready = identify(connection)?;
    let (attached, page) = attach(ready, surface, after)?;
    follow(attached, page, surface, after, deadline)
}

/// Event requests require a completed attachment, including replay pages and
/// the view hint. The phase orchestrator cannot start them on a merely ready VM.
fn follow(
    mut attached: Vm<Attached, Link>,
    page: Value,
    surface: u64,
    after: u64,
    deadline: Instant,
) -> Result<Value, Failure> {
    let mut got = Got { records: Vec::new(), last_seq: after, ended: None };
    got.page(&page);
    // A permission asked before the attach is in the attach's session summary (`session.pending`, as `acpmux
    // run`'s permission read), not pushed again.
    if got.ended.is_none()
        && page
            .pointer("/session/pending")
            .and_then(Value::as_array)
            .is_some_and(|asks| !asks.is_empty())
    {
        got.ended = Some("permission");
    }
    // A waiter, not a viewer: the chat's unread state stays the person's (`agent-session-view`, acpmux
    // `server/view.rs`). A daemon that refuses it still answers the wait.
    let _ = attached.payload_mut().ask(
        "view",
        json!({"id": "view", "cmd": "agent-session-view", "surface": surface, "visible": false}),
    );
    // A long log before the attach: the rest in pages, each after the newest seq read.
    let mut more = page.get("hasMore") == Some(&Value::Bool(true));
    while more && got.ended.is_none() {
        let id = format!("events-{}", got.last_seq);
        let page = attached.payload_mut().ask(
            &id,
            json!({"id": id, "cmd": "agent-session-events", "surface": surface, "after_seq": got.last_seq, "limit": PAGE}),
        )?;
        let before = got.last_seq;
        got.page(&page);
        more = page.get("hasMore") == Some(&Value::Bool(true));
        // A page that reads nothing new (one record over the page's 8 MiB cap) cannot advance, and the turn's end
        // may be behind it: the link cannot read this turn, so exec does.
        if more && got.last_seq == before {
            return Err(Failure::Link("a replay page made no progress".into()));
        }
    }
    for line in std::mem::take(&mut attached.payload_mut().early) {
        if got.ended.is_none() {
            got.push(&line);
        }
    }
    while got.ended.is_none() {
        let Ok(line) = next(&mut attached.payload_mut().lines, deadline) else { break };
        let Some(line) = line else {
            got.ended = Some("closed");
            break;
        };
        got.push(&line);
    }
    Ok(
        json!({"records": got.records, "last_seq": got.last_seq, "ended": got.ended.unwrap_or("timeout")}),
    )
}

/// The transport belongs to the lifecycle capability, including messages pushed
/// before the attach reply. Dropping a failed or cancelled step closes it.
struct Link {
    writer: UnixStream,
    lines: BufReader<UnixStream>,
    early: Vec<Value>,
    deadline: Instant,
}

impl Link {
    fn ask(&mut self, id: &str, request: Value) -> Result<Value, Failure> {
        let mut line = request.to_string();
        line.push('\n');
        self.writer.write_all(line.as_bytes()).map_err(|error| Failure::Link(error.to_string()))?;
        loop {
            let answer = next(&mut self.lines, self.deadline)?
                .ok_or_else(|| Failure::Link("the link closed".into()))?;
            if answer.get("id").and_then(Value::as_str) != Some(id) {
                if answer.get("event").is_some() {
                    self.early.push(answer);
                }
                continue;
            }
            if answer.get("ok") == Some(&Value::Bool(false)) {
                return Err(Failure::Link(format!(
                    "{id} refused: {}",
                    answer.get("error").unwrap_or(&Value::Null)
                )));
            }
            return Ok(answer.get("data").cloned().unwrap_or(Value::Null));
        }
    }
}

fn connect(socket: &Path, deadline: Instant) -> Result<Vm<Unidentified, Link>, Failure> {
    let stream =
        UnixStream::connect(socket).map_err(|error| Failure::Link(format!("connect: {error}")))?;
    let writer = stream.try_clone().map_err(|error| Failure::Link(error.to_string()))?;
    Ok(Vm::connected(Link { writer, lines: BufReader::new(stream), early: Vec::new(), deadline }))
}

fn identify(mut connection: Vm<Unidentified, Link>) -> Result<Vm<Ready, Link>, Failure> {
    let identity =
        connection.payload_mut().ask("identify", json!({"id": "identify", "cmd": "identify"}))?;
    let serves = identity
        .get("capabilities")
        .and_then(Value::as_array)
        .is_some_and(|names| names.iter().any(|name| name == ATTACH));
    if !serves {
        return Err(Failure::Link(
            "the machine's daemon does not serve agent-session-attach".into(),
        ));
    }
    Ok(connection.ready())
}

fn attach(
    mut ready: Vm<Ready, Link>,
    surface: u64,
    after: u64,
) -> Result<(Vm<Attached, Link>, Value), Failure> {
    let page = ready.payload_mut().ask(
        "attach",
        json!({"id": "attach", "cmd": "agent-session-attach", "surface": surface, "after_seq": after, "limit": PAGE}),
    )?;
    Ok((ready.attach(), page))
}

/// The longest prompt the daemon's `agent-session-prompt` takes (spec: 64 KiB).
pub(crate) const PROMPT_BYTES: usize = 64 * 1024;

/// What a prompt sent over the link came to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum SendFailure {
    /// Nothing reached the chat: no socket, no capability, a refusal. The same prompt may go another way.
    NotSent(String),
    /// The prompt frame was written and no answer came: it may have been taken, so it is not sent again.
    Unsure(String),
}

/// One prompt to the chat tab `surface` over the machine's link (`identify`, `agent-session-attach` with a
/// one-record page, `agent-session-prompt`): one round trip on the link the app already holds, instead of a
/// `cloud exec` that starts two processes on the machine. Answers the daemon's `{prompt_id, turn_id, queued}`.
pub(crate) fn send(
    socket: &Path,
    surface: u64,
    prompt_id: &str,
    text: &str,
    wait: Duration,
) -> Result<Value, SendFailure> {
    let deadline = Instant::now() + wait;
    let stream = UnixStream::connect(socket)
        .map_err(|error| SendFailure::NotSent(format!("connect: {error}")))?;
    let mut writer = stream.try_clone().map_err(|error| SendFailure::NotSent(error.to_string()))?;
    let mut lines = BufReader::new(stream);
    let mut ask = |request: Value, sent: bool| -> Result<Value, SendFailure> {
        let id = request.get("id").and_then(Value::as_str).unwrap_or_default().to_owned();
        let fail = |reason: String| {
            if sent { SendFailure::Unsure(reason) } else { SendFailure::NotSent(reason) }
        };
        let mut line = request.to_string();
        line.push('\n');
        writer.write_all(line.as_bytes()).map_err(|error| fail(error.to_string()))?;
        loop {
            let answer = next(&mut lines, deadline)
                .map_err(|error| fail(format!("{error:?}")))?
                .ok_or_else(|| fail("the link closed".into()))?;
            if answer.get("id").and_then(Value::as_str) != Some(id.as_str()) {
                continue;
            }
            if answer.get("ok") == Some(&Value::Bool(false)) {
                // A refusal is an answer: the prompt did not go in.
                return Err(SendFailure::NotSent(format!(
                    "{id} refused: {}",
                    answer.get("error").unwrap_or(&Value::Null)
                )));
            }
            return Ok(answer.get("data").cloned().unwrap_or(Value::Null));
        }
    };
    let identity = ask(json!({"id": "identify", "cmd": "identify"}), false)?;
    let serves = identity
        .get("capabilities")
        .and_then(Value::as_array)
        .is_some_and(|names| names.iter().any(|name| name == ATTACH));
    if !serves {
        return Err(SendFailure::NotSent(
            "the machine's daemon does not serve agent-session-attach".into(),
        ));
    }
    ask(
        json!({"id": "attach", "cmd": "agent-session-attach", "surface": surface, "limit": 1}),
        false,
    )?;
    ask(
        json!({"id": "prompt", "cmd": "agent-session-prompt", "surface": surface,
               "prompt_id": prompt_id, "text": text}),
        true,
    )
}

/// The chat tab's handle on the machine's daemon, from `cloud start-session`'s answer (its `surface_id`): what the
/// pushed wait attaches to. None from an app that answers none.
pub(crate) fn chat_tab(started: &Value) -> Option<u64> {
    let id = started.get("surface_id")?;
    id.as_str().and_then(|id| id.parse().ok()).or_else(|| id.as_u64())
}

/// Why a wait read no answer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Failure {
    /// The wait passed first.
    Timeout,
    /// The link could not be read: its reason.
    Link(String),
}

/// The next JSON line before `deadline`: None at the link's end, [`Failure::Timeout`] once the deadline passed.
fn next(lines: &mut BufReader<UnixStream>, deadline: Instant) -> Result<Option<Value>, Failure> {
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Err(Failure::Timeout);
        }
        lines
            .get_ref()
            .set_read_timeout(Some(left))
            .map_err(|error| Failure::Link(error.to_string()))?;
        let mut line = String::new();
        match lines.read_line(&mut line) {
            Ok(0) => return Ok(None),
            Ok(_) => {
                if let Ok(value) = serde_json::from_str::<Value>(line.trim()) {
                    return Ok(Some(value));
                }
            }
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                return Err(Failure::Timeout);
            }
            Err(error) => return Err(Failure::Link(error.to_string())),
        }
    }
}

/// A record that ends a turn (as acpmux's own wait reads them, `acpmux/src/cli/steer_reply.rs`): `Some(None)` for a
/// `turn_end`, `Some(Some(record's msg))` for a failed turn (a `turn_error`, or a `turn_result` whose status is
/// `failed`: such a turn writes no `turn_end`).
pub(crate) fn turn_ended(record: &Value) -> Option<Option<&Value>> {
    if record.get("dir").and_then(Value::as_str) != Some("mux") {
        return None;
    }
    let msg = record.get("msg");
    match record.get("kind").and_then(Value::as_str)? {
        "turn_end" => Some(None),
        "turn_error" => Some(Some(msg.unwrap_or(&Value::Null))),
        "turn_result"
            if msg.and_then(|msg| msg.get("status")).and_then(Value::as_str) == Some("failed") =>
        {
            Some(msg)
        }
        _ => None,
    }
}

/// The records after the caller's seq, each once.
pub(crate) struct Got {
    pub records: Vec<Value>,
    pub last_seq: u64,
    pub ended: Option<&'static str>,
}

impl Got {
    /// One pushed line: a record, a permission or the attachment's close.
    fn push(&mut self, line: &Value) {
        match line.get("event").and_then(Value::as_str) {
            Some("agent-session-record") => {
                if let Some(record) = line.get("record") {
                    self.add(record);
                }
            }
            Some("agent-session-permission") => self.ended = Some("permission"),
            Some("agent-session-closed") => self.ended = Some("closed"),
            _ => {}
        }
    }

    fn page(&mut self, page: &Value) {
        for record in page.get("events").and_then(Value::as_array).into_iter().flatten() {
            if self.ended.is_some() {
                break;
            }
            self.add(record);
        }
    }

    pub(crate) fn add(&mut self, record: &Value) {
        let seq = record.get("seq").and_then(Value::as_u64).unwrap_or(0);
        if seq <= self.last_seq {
            return;
        }
        self.last_seq = seq;
        self.records.push(record.clone());
        if turn_ended(record).is_some() {
            self.ended = Some("turn_end");
        } else if self.records.len() >= KEPT {
            self.ended = Some("more");
        }
    }
}

#[cfg(test)]
#[path = "link_wait_tests.rs"]
mod tests;
