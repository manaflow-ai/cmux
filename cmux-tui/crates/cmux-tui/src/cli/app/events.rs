//! `cmux app events`: one `events.stream` request, then each event line the
//! app sends is printed until the app or the reader stops, until
//! `--timeout` runs out (exit 124), or, with `--until` / `--match`
//! (cli/event_match.rs), until the first matching event (exit 0). Kept out
//! of app.rs for its line budget.

use std::io::{ErrorKind, Read, Write};
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::super::OutputMode;
use super::super::event_match::EventMatch;
use super::{failure, send_line};

/// The exit code of a wait whose time ran out, as timeout(1) has it.
const TIMEOUT_EXIT: i32 = 124;

/// When `cmux events` stops on its own: `None`/`None` streams until the app
/// closes the stream or the process is interrupted.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(in crate::cli) struct EventsWait {
    pub until: Option<EventMatch>,
    pub timeout: Option<Duration>,
}

/// `events.stream`: one JSON event per line until the app closes the
/// stream, the timeout passes or the event waited for arrives. Blocking
/// reads, each with the time left as its deadline, no polling.
pub(super) fn stream_events(
    stream: &mut UnixStream,
    params: Value,
    wait: &EventsWait,
    output: OutputMode,
) -> i32 {
    let started = Instant::now();
    let deadline = wait.timeout.map(|timeout| started + timeout);
    if let Err(error) =
        send_line(stream, &json!({ "id": 1, "method": "events.stream", "params": params }))
    {
        return failure("app.transport", &error, output, 3);
    }
    let mut lines = match stream.try_clone() {
        Ok(reader) => Lines { reader, pending: Vec::new(), deadline },
        Err(error) => return failure("app.transport", &error.to_string(), output, 3),
    };
    // The connect's `system.ping` left its reply timeout on the socket: a
    // stream with no --timeout has none, however long the app stays quiet.
    if deadline.is_none()
        && let Err(error) = lines.reader.set_read_timeout(None)
    {
        return failure("app.transport", &error.to_string(), output, 3);
    }
    let mut stdout = std::io::stdout().lock();
    // The last `seq` the app sent, matching or not: where a rerun resumes.
    let mut last_seq: Option<u64> = None;
    loop {
        let line = match lines.next_line() {
            Ok(Some(line)) => line,
            Ok(None) => break,
            Err(ReadEnd::TimedOut) => return timed_out(wait, started, output),
            Err(ReadEnd::Failed) => return 3,
        };
        let text = line.trim_end_matches(['\n', '\r']);
        let Ok(value) = serde_json::from_str::<Value>(text) else { continue };
        if let Some(seq) = value.get("seq").and_then(Value::as_u64) {
            last_seq = Some(seq);
        }
        if value.get("ok").and_then(Value::as_bool) == Some(false) {
            let error = value.get("error").cloned().unwrap_or(Value::Null);
            return super::super::wire::print_local_error(&error, output, 1);
        }
        let matched = match &wait.until {
            // A wait prints only the event it waited for.
            Some(until) => {
                let name = value.get("name").and_then(Value::as_str);
                if value.get("type").and_then(Value::as_str) != Some("event")
                    || !until.matches(name, &value)
                {
                    continue;
                }
                true
            }
            None => false,
        };
        let written = match output {
            OutputMode::Quiet => Ok(()),
            _ => writeln!(stdout, "{text}").and_then(|()| stdout.flush()),
        };
        if matched || written.is_err() {
            return 0;
        }
    }
    match &wait.until {
        // The app closed the stream (it quit or restarted) before the event.
        Some(_) => {
            let resume = match last_seq {
                Some(seq) => format!("run the same cmux events command again with --after {seq}"),
                None => "no event came before it closed; run the same cmux events command again"
                    .to_owned(),
            };
            let message = format!(
                "the app closed the event stream before a matching event; {resume} to resume"
            );
            failure("events.closed", &message, output, 1)
        }
        None => 0,
    }
}

/// Why [`Lines::next_line`] gave no line.
enum ReadEnd {
    TimedOut,
    Failed,
}

/// The stream's lines, read with the deadline checked before every socket
/// read, so a frame that arrives a few bytes at a time cannot outlast it
/// (`read_line` gives each of its reads the whole time left).
struct Lines {
    reader: UnixStream,
    pending: Vec<u8>,
    deadline: Option<Instant>,
}

impl Lines {
    /// The next line with its newline, the last bytes when the stream ends
    /// without one, or `None` at the end.
    fn next_line(&mut self) -> Result<Option<String>, ReadEnd> {
        let mut chunk = [0_u8; 8192];
        loop {
            if let Some(end) = self.pending.iter().position(|&byte| byte == b'\n') {
                let rest = self.pending.split_off(end.saturating_add(1));
                let line = std::mem::replace(&mut self.pending, rest);
                return Ok(Some(String::from_utf8_lossy(&line).into_owned()));
            }
            if let Some(deadline) = self.deadline {
                let left = deadline.saturating_duration_since(Instant::now());
                // A zero read timeout means "block forever" to the socket.
                if left.is_zero() || self.reader.set_read_timeout(Some(left)).is_err() {
                    return Err(ReadEnd::TimedOut);
                }
            }
            match self.reader.read(&mut chunk) {
                Ok(0) if self.pending.is_empty() => return Ok(None),
                Ok(0) => {
                    let line = std::mem::take(&mut self.pending);
                    return Ok(Some(String::from_utf8_lossy(&line).into_owned()));
                }
                Ok(read) => self.pending.extend_from_slice(chunk.get(..read).unwrap_or_default()),
                Err(error) if error.kind() == ErrorKind::Interrupted => {}
                Err(error)
                    if matches!(error.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) =>
                {
                    return Err(ReadEnd::TimedOut);
                }
                Err(_) => return Err(ReadEnd::Failed),
            }
        }
    }
}

/// The deadline passed: a JSON record `{type: "timeout", timed_out: true,
/// waited_ms, until?}` on stdout for --json and --jsonl, a line on stderr
/// for a person; exit 124.
fn timed_out(wait: &EventsWait, started: Instant, output: OutputMode) -> i32 {
    let waited_ms = wait.timeout.unwrap_or_else(|| started.elapsed()).as_millis();
    let mut record = json!({
        "type": "timeout",
        "timed_out": true,
        "waited_ms": waited_ms.to_string(),
    });
    if let (Some(until), Some(object)) = (&wait.until, record.as_object_mut()) {
        object.insert("until".into(), until.describe());
    }
    match output {
        OutputMode::Json | OutputMode::JsonLines => {
            let mut stdout = std::io::stdout().lock();
            let _ = writeln!(stdout, "{record}").and_then(|()| stdout.flush());
        }
        OutputMode::Human => {
            let what = if wait.until.is_some() { "no matching event" } else { "no more events" };
            eprintln!("events: {what} in {waited_ms} ms (timed out, exit 124)");
        }
        OutputMode::Quiet => {}
    }
    TIMEOUT_EXIT
}
