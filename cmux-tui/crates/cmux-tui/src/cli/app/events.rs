//! `cmux app events`: one `events.stream` request, then each event line the
//! app sends is printed until the app or the reader stops, until
//! `--timeout` runs out (exit 124), or, with `--until` / `--match`
//! (cli/event_match.rs), until the first matching event (exit 0). Kept out
//! of app.rs for its line budget.

use std::io::{BufRead, BufReader, ErrorKind, Write};
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
/// reads with the time left as their deadline, no polling.
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
    let mut reader = match stream.try_clone() {
        Ok(reader) => BufReader::new(reader),
        Err(error) => return failure("app.transport", &error.to_string(), output, 3),
    };
    let mut stdout = std::io::stdout().lock();
    let mut line = String::new();
    loop {
        if let Some(deadline) = deadline {
            let left = deadline.saturating_duration_since(Instant::now());
            // A zero read timeout means "block forever" to the socket.
            if left.is_zero() || reader.get_ref().set_read_timeout(Some(left)).is_err() {
                return timed_out(wait, started, output);
            }
        }
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => break,
            Ok(_) => {}
            Err(error) if matches!(error.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {
                return timed_out(wait, started, output);
            }
            Err(_) => return 3,
        }
        let text = line.trim_end_matches(['\n', '\r']);
        let Ok(value) = serde_json::from_str::<Value>(text) else { continue };
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
        Some(_) => failure(
            "events.closed",
            "the app closed the event stream before a matching event; run the same cmux events \
             command again with --after <last seq> to resume",
            output,
            1,
        ),
        None => 0,
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
