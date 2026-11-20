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
    let stream =
        UnixStream::connect(socket).map_err(|error| Failure::Link(format!("connect: {error}")))?;
    let mut writer = stream.try_clone().map_err(|error| Failure::Link(error.to_string()))?;
    let mut lines = BufReader::new(stream);
    // Pushes that came while an answer was awaited (a page after the attach): handled after the pages, in order.
    let mut early: Vec<Value> = Vec::new();
    let mut ask = |id: &str,
                   request: Value,
                   lines: &mut BufReader<UnixStream>,
                   early: &mut Vec<Value>|
     -> Result<Value, Failure> {
        let mut line = request.to_string();
        line.push('\n');
        writer.write_all(line.as_bytes()).map_err(|error| Failure::Link(error.to_string()))?;
        loop {
            let answer =
                next(lines, deadline)?.ok_or_else(|| Failure::Link("the link closed".into()))?;
            if answer.get("id").and_then(Value::as_str) != Some(id) {
                if answer.get("event").is_some() {
                    early.push(answer);
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
    };
    let identity =
        ask("identify", json!({"id": "identify", "cmd": "identify"}), &mut lines, &mut early)?;
    let serves = identity
        .get("capabilities")
        .and_then(Value::as_array)
        .is_some_and(|names| names.iter().any(|name| name == ATTACH));
    if !serves {
        return Err(Failure::Link(
            "the machine's daemon does not serve agent-session-attach".into(),
        ));
    }
    let mut got = Got { records: Vec::new(), last_seq: after, ended: None };
    let page = ask(
        "attach",
        json!({"id": "attach", "cmd": "agent-session-attach", "surface": surface, "after_seq": after, "limit": PAGE}),
        &mut lines,
        &mut early,
    )?;
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
    let _ = ask(
        "view",
        json!({"id": "view", "cmd": "agent-session-view", "surface": surface, "visible": false}),
        &mut lines,
        &mut early,
    );
    // A long log before the attach: the rest in pages, each after the newest seq read.
    let mut more = page.get("hasMore") == Some(&Value::Bool(true));
    while more && got.ended.is_none() {
        let id = format!("events-{}", got.last_seq);
        let page = ask(
            &id,
            json!({"id": id, "cmd": "agent-session-events", "surface": surface, "after_seq": got.last_seq, "limit": PAGE}),
            &mut lines,
            &mut early,
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
    for line in early {
        if got.ended.is_none() {
            got.push(&line);
        }
    }
    while got.ended.is_none() {
        let Ok(line) = next(&mut lines, deadline) else { break };
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
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;

    /// A daemon on a socket that answers `identify` and `agent-session-attach` (the page), then pushes `pushed`.
    fn daemon(
        capabilities: &[&str],
        page: Value,
        pushed: Vec<Value>,
    ) -> (tempfile::TempDir, std::path::PathBuf) {
        serve(capabilities, page, json!({"events": [], "hasMore": false}), pushed)
    }

    /// A daemon whose attach page has more and whose every `agent-session-events` page is `events`.
    fn daemon_paging(events: Value) -> (tempfile::TempDir, std::path::PathBuf) {
        serve(&[ATTACH], json!({"events": [], "hasMore": true}), events, vec![])
    }

    fn serve(
        capabilities: &[&str],
        page: Value,
        events: Value,
        pushed: Vec<Value>,
    ) -> (tempfile::TempDir, std::path::PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("link.sock");
        let listener = UnixListener::bind(&path).unwrap();
        let capabilities: Vec<String> =
            capabilities.iter().map(|name| (*name).to_owned()).collect();
        std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut writer = stream.try_clone().unwrap();
            let mut lines = BufReader::new(stream);
            let mut line = String::new();
            while lines.read_line(&mut line).unwrap_or(0) > 0 {
                let request: Value = serde_json::from_str(line.trim()).unwrap();
                line.clear();
                let id = request["id"].clone();
                let data = match request["cmd"].as_str() {
                    Some("identify") => json!({"capabilities": capabilities}),
                    Some("agent-session-attach") => page.clone(),
                    Some("agent-session-events") => events.clone(),
                    _ => json!({}),
                };
                writeln!(writer, "{}", json!({"id": id, "ok": true, "data": data})).unwrap();
                if request["cmd"] == "agent-session-attach" {
                    for push in &pushed {
                        writeln!(writer, "{push}").unwrap();
                    }
                }
            }
        });
        (dir, path)
    }

    #[test]
    fn the_turn_ends_at_its_turn_end_with_every_record_after_the_seq() {
        let record = |seq: u64, dir: &str, kind: &str| json!({"seq": seq, "dir": dir, "kind": kind, "msg": {}});
        let page = json!({"events": [record(1, "mux", "user_message"), record(2, "in", "notification")], "hasMore": false});
        let pushed = vec![
            json!({"event": "agent-session-record", "surface": 7, "record": record(2, "in", "notification")}),
            json!({"event": "agent-session-record", "surface": 7, "record": record(3, "mux", "turn_end")}),
            json!({"event": "agent-session-record", "surface": 7, "record": record(4, "mux", "user_message")}),
        ];
        let (_dir, path) = daemon(&[ATTACH], page, pushed);
        let answer = observe(&path, 7, 0, Duration::from_secs(5)).unwrap();
        assert_eq!(answer["ended"], "turn_end");
        assert_eq!(answer["last_seq"], 3);
        let seqs: Vec<u64> = answer["records"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["seq"].as_u64().unwrap())
            .collect();
        assert_eq!(seqs, [1, 2, 3], "each record once, none after the turn's end");
    }

    #[test]
    fn a_permission_ends_the_wait_and_a_quiet_link_times_out() {
        let (_dir, path) = daemon(
            &[ATTACH],
            json!({"events": [], "hasMore": false}),
            vec![json!({"event": "agent-session-permission", "surface": 7, "request": {}})],
        );
        assert_eq!(observe(&path, 7, 0, Duration::from_secs(5)).unwrap()["ended"], "permission");
        let (_dir, path) = daemon(&[ATTACH], json!({"events": [], "hasMore": false}), vec![]);
        assert_eq!(observe(&path, 7, 0, Duration::from_millis(200)).unwrap()["ended"], "timeout");
    }

    #[test]
    fn a_failed_turn_ends_the_wait_without_a_turn_end() {
        let record = |seq: u64, kind: &str, msg: Value| json!({"seq": seq, "dir": "mux", "kind": kind, "msg": msg});
        let page = json!({"events": [record(1, "user_message", json!({}))], "hasMore": false});
        let pushed = vec![json!({"event": "agent-session-record", "surface": 7,
                                 "record": record(2, "turn_error", json!({"error": "agent process closed"}))})];
        let (_dir, path) = daemon(&[ATTACH], page, pushed);
        let answer = observe(&path, 7, 0, Duration::from_secs(5)).unwrap();
        assert_eq!(
            (answer["ended"].as_str(), answer["last_seq"].as_u64()),
            (Some("turn_end"), Some(2))
        );
        let failed = record(3, "turn_result", json!({"status": "failed", "error": "e"}));
        assert_eq!(turn_ended(&failed), Some(Some(&json!({"status": "failed", "error": "e"}))));
        assert_eq!(turn_ended(&record(3, "turn_result", json!({"status": "completed"}))), None);
    }

    #[test]
    fn pages_follow_the_attach_and_pushes_during_them_are_kept() {
        let record =
            |seq: u64, kind: &str| json!({"seq": seq, "dir": "mux", "kind": kind, "msg": {}});
        // The attach answers one page with more; the fake's events answer is empty with no more, then the pushes.
        let page = json!({"events": [record(1, "user_message")], "hasMore": true});
        let pushed = vec![
            json!({"event": "agent-session-record", "surface": 7, "record": record(2, "turn_end")}),
        ];
        let (_dir, path) = daemon(&[ATTACH], page, pushed);
        let answer = observe(&path, 7, 0, Duration::from_secs(5)).unwrap();
        assert_eq!(
            answer["ended"], "turn_end",
            "the push that came while the page was asked ends the wait"
        );
        assert_eq!(answer["last_seq"], 2);
    }

    #[test]
    fn a_permission_pending_at_the_attach_ends_the_wait() {
        let page = json!({"session": {"pending": [{"permissionId": "p1"}]}, "events": [], "hasMore": false});
        let (_dir, path) = daemon(&[ATTACH], page, vec![]);
        assert_eq!(observe(&path, 7, 0, Duration::from_secs(5)).unwrap()["ended"], "permission");
        let page = json!({"session": {"pending": []}, "events": [], "hasMore": false});
        let (_dir, path) = daemon(&[ATTACH], page, vec![]);
        assert_eq!(observe(&path, 7, 0, Duration::from_millis(200)).unwrap()["ended"], "timeout");
    }

    #[test]
    fn a_replay_page_that_cannot_advance_hands_the_turn_to_exec() {
        // The attach page has more; the fake's events answer reads nothing, again with more.
        let (_dir, path) = daemon_paging(json!({"events": [], "hasMore": true}));
        assert!(matches!(observe(&path, 7, 0, Duration::from_secs(5)), Err(Failure::Link(_))));
    }

    #[test]
    fn a_daemon_without_attach_is_refused_before_any_attach() {
        let (_dir, path) = daemon(&["workspace-registry-v1"], json!({}), vec![]);
        assert!(observe(&path, 7, 0, Duration::from_secs(5)).is_err());
        assert!(
            observe(Path::new("/nonexistent/link.sock"), 7, 0, Duration::from_secs(1)).is_err()
        );
    }
}
