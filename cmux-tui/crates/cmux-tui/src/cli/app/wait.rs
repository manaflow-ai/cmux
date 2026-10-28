//! A request that may wait long for the app (an `action.run` that waits for
//! its work, a page wait, a screenshot): progress on stderr while it waits,
//! and a timeout that says who did not answer, where, and what to run next.

use std::io::IsTerminal as _;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::mpsc::{self, RecvTimeoutError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::{
    GlobalArgs, OutputMode, SCREENSHOT_TIMEOUT, command_socket, request_with_retry, safe_to_resend,
};

/// Only the long waits (a screenshot's 35 s, a waiting run's 45 s) show
/// notes; a 5 s control-plane read answers or fails before a note helps.
const LONG_WAIT: Duration = SCREENSHOT_TIMEOUT;
/// No note for a wait shorter than this.
const FIRST_NOTE_AFTER: Duration = Duration::from_secs(2);
const NOTE_EVERY: Duration = Duration::from_secs(5);
/// The waits before each new connection after the app dropped one.
const RECONNECT_BACKOFF: [Duration; 2] = [Duration::from_millis(200), Duration::from_millis(800)];

/// [`request_with_retry`] with progress notes while it waits; a transport
/// failure is the `app.transport` error to print, typed by [`timed_out`]
/// when the app took the request and never answered.
pub(super) fn request(
    global: &GlobalArgs,
    stream: &mut UnixStream,
    method: &str,
    params: &Value,
    timeout: Option<Duration>,
) -> Result<Result<Value, Value>, Value> {
    let long = timeout.is_some_and(|timeout| timeout >= LONG_WAIT);
    let timeout = effective_timeout(timeout);
    let what = waiting_for(method, params);
    let template = crate::localization::catalog().app_control.waiting_progress;
    let progress = Progress::start(&what, template, timeout.filter(|_| long), global.output);
    let mut response = request_with_retry(stream, method, params, timeout);
    // A dropped connection (the app restarted its control server, or closed
    // it under load) is healed: a new connection, the same request. A keyed
    // run carries its idempotency key, so the app replays or joins it.
    for wait in RECONNECT_BACKOFF {
        let Err(error) = &response else { break };
        if timeout.is_some_and(|timeout| *error == timeout_message(timeout))
            || !safe_to_resend(method, params)
        {
            break;
        }
        cmux_blocking::thread::sleep(wait);
        let Ok(fresh) = super::connect_command(global) else { break };
        *stream = fresh;
        response = request_with_retry(stream, method, params, timeout);
    }
    let waited = progress.finish();
    response.map_err(|error| match timeout {
        Some(timeout) if error == timeout_message(timeout) => {
            let socket = command_socket(global).ok().map(|socket| socket.path);
            timed_out(socket.as_deref(), &next_command(global), method, &what, timeout, waited)
        }
        _ => {
            json!({ "code": "app.transport", "message": error, "details": {}, "retryable": false })
        }
    })
}

/// The "app did not answer within N s" text of a read that timed out.
pub(super) fn timeout_message(timeout: Duration) -> String {
    let messages = &crate::localization::catalog().app_control;
    messages.timeout.replace("{seconds}", &timeout.as_secs().to_string())
}

/// `timeout`, or the test build's `CMUX_TEST_APP_WAIT_TIMEOUT_MS` for a
/// request that has one (a release build ignores it).
fn effective_timeout(timeout: Option<Duration>) -> Option<Duration> {
    #[cfg(debug_assertions)]
    if timeout.is_some()
        && let Some(ms) = std::env::var("CMUX_TEST_APP_WAIT_TIMEOUT_MS")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
    {
        return Some(Duration::from_millis(ms));
    }
    timeout
}

/// What to run when the app does not answer: `cmux identify` asks the app
/// the cheapest question there is, over the route this call took
/// (`--app-socket`, `--socket` or `--session`), so it reaches the same app.
fn next_command(global: &GlobalArgs) -> String {
    let route = if let Some(path) = &global.app_socket {
        format!(" --app-socket {}", quote(&path.to_string_lossy()))
    } else if let Some(path) = &global.socket {
        format!(" --socket {}", quote(&path.to_string_lossy()))
    } else if let Some(session) = &global.session {
        format!(" --session {}", quote(session))
    } else {
        String::new()
    };
    format!("cmux{route} identify")
}

/// `value` as one shell word: unchanged when it has only safe characters.
fn quote(value: &str) -> String {
    let safe = |c: char| c.is_ascii_alphanumeric() || "/._-:@%+=,".contains(c);
    if !value.is_empty() && value.chars().all(safe) {
        return value.to_owned();
    }
    format!("'{}'", value.replace('\'', "'\\''"))
}

/// What the app is asked to do: the action of an `action.run`, else the
/// method.
fn waiting_for(method: &str, params: &Value) -> String {
    match params.get("action").and_then(Value::as_str) {
        Some(action) if method == "action.run" => action.to_owned(),
        _ => method.to_owned(),
    }
}

/// Progress notes for a wait that is not one app request (`cmux agents
/// wait`): the same notes, shown from the same threshold, with `template`'s
/// words. They stop when the returned value is dropped.
pub(in crate::cli) fn notes(
    what: &str,
    template: &'static str,
    timeout: Duration,
    output: OutputMode,
) -> Progress {
    Progress::start(what, template, Some(timeout).filter(|timeout| *timeout >= LONG_WAIT), output)
}

/// Prints a progress note every few seconds while a request waits, until it
/// is dropped. Notes go to stderr in human output, and in JSON output only
/// when stderr is a terminal, so a piped JSON error is never mixed with them.
pub(in crate::cli) struct Progress {
    started: Instant,
    stop: Option<mpsc::Sender<()>>,
    thread: Option<JoinHandle<()>>,
}

impl Progress {
    fn start(
        what: &str,
        template: &'static str,
        timeout: Option<Duration>,
        output: OutputMode,
    ) -> Self {
        let started = Instant::now();
        let shows = match output {
            OutputMode::Human => true,
            OutputMode::Json | OutputMode::JsonLines => std::io::stderr().is_terminal(),
            OutputMode::Quiet => false,
        };
        let Some(total) = timeout.filter(|total| shows && *total > FIRST_NOTE_AFTER) else {
            return Self { started, stop: None, thread: None };
        };
        let (stop, stopped) = mpsc::channel::<()>();
        let what = what.to_owned();
        let spawned = std::thread::Builder::new().name("app-wait-notes".into()).spawn(move || {
            let mut next = FIRST_NOTE_AFTER;
            while next < total {
                let left = next.saturating_sub(started.elapsed());
                match crate::blocking::sync::recv_timeout(&stopped, left) {
                    Err(RecvTimeoutError::Timeout) => {}
                    Ok(()) | Err(RecvTimeoutError::Disconnected) => return,
                }
                eprintln!(
                    "{}",
                    template
                        .replace("{what}", &what)
                        .replace("{elapsed}", &started.elapsed().as_secs().to_string())
                        .replace("{total}", &total.as_secs().to_string())
                );
                next += NOTE_EVERY;
            }
        });
        // No thread, no notes: the request itself still runs.
        match spawned {
            Ok(thread) => Self { started, stop: Some(stop), thread: Some(thread) },
            Err(_) => Self { started, stop: None, thread: None },
        }
    }

    /// Stops the notes before the answer or the error is printed.
    fn finish(mut self) -> Duration {
        self.stop_notes();
        self.started.elapsed()
    }

    fn stop_notes(&mut self) {
        drop(self.stop.take());
        if let Some(thread) = self.thread.take() {
            let _ = crate::blocking::thread::join(thread);
        }
    }
}

impl Drop for Progress {
    fn drop(&mut self) {
        self.stop_notes();
    }
}

/// The `app.transport` error of a request the app took and never answered:
/// the owner, the socket, the request, the wait and the next command, as
/// fields of `details` beside the message.
fn timed_out(
    socket: Option<&Path>,
    next: &str,
    method: &str,
    what: &str,
    timeout: Duration,
    waited: Duration,
) -> Value {
    let messages = &crate::localization::catalog().app_control;
    let socket = socket.map(|path| path.display().to_string());
    let message = messages
        .timeout_next
        .replace("{path}", socket.as_deref().unwrap_or("?"))
        .replace("{what}", what)
        .replace("{seconds}", &timeout.as_secs().to_string())
        .replace("{next}", next);
    json!({
        "code": "app.transport",
        "message": message,
        "details": {
            "owner": "app",
            "socket": socket,
            "method": method,
            "waiting_for": what,
            "timeout_seconds": timeout.as_secs(),
            "waited_seconds": waited.as_secs(),
            "next_command": next,
        },
        "retryable": false,
    })
}
