//! The one daemon connection `cmux ext dev` keeps open: requests go out on
//! it, and its replies and events (`apps-changed`, `apps-reload-failed`,
//! `apps-scene`, `apps-log`, ...) come back as [`Wake::Daemon`] on the same
//! channel the folder watch and Ctrl-C wake, so one thread waits on all of
//! them with no timer and no poll.

use std::io::{BufRead, BufReader, Write};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};

use cmux_tui_core::platform::transport;
use serde_json::{Value, json};

use super::super::GlobalArgs;
use super::Field as _;

/// How long one request may take to answer.
pub(super) const REQUEST_DEADLINE: Duration = Duration::from_secs(15);

/// What woke the dev loop.
#[derive(Debug)]
pub(super) enum Wake {
    /// A file under the extension folder changed (already filtered).
    Files,
    /// One line from the daemon: a reply or an event.
    Daemon(Value),
    /// The daemon closed the connection.
    DaemonGone,
    /// Ctrl-C (SIGINT, SIGTERM or SIGHUP).
    Interrupt,
    /// The install the person was asked to confirm ended (`true` installed).
    Installed(bool),
}

/// How a wait ended when it did not get what it waited for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Stop {
    Timeout,
    Gone,
    Interrupted,
}

/// The connection and the loop's channel.
pub(super) struct Daemon {
    writer: Box<dyn transport::Stream>,
    wakes: Receiver<Wake>,
    next_id: u64,
    /// A file change seen while waiting for the daemon: the loop runs again.
    pub(super) files_changed: bool,
    /// `apps-log` lines of the followed apps seen since the last `take_logs`.
    logs: Vec<Value>,
    /// Print each log line as it comes (`ext dev` without `--once`).
    pub(super) echo_logs: bool,
}

impl Daemon {
    /// Connects to the session daemon `global` names and starts the reader.
    pub(super) fn connect(
        global: &GlobalArgs,
        sender: Sender<Wake>,
        wakes: Receiver<Wake>,
    ) -> Result<Self, String> {
        let (socket, derived) = crate::cli::wire::resolve_socket_with_origin(global)
            .map_err(|error| crate::cli::wire::resolve_failure_message(&error))?;
        let stream = cmux_tui_core::server::connect_session_socket(&socket, derived)
            .map_err(|error| crate::cli::wire::connect_failure(&socket, &error))?;
        Self::over(stream, sender, wakes).map_err(|error| error.to_string())
    }

    /// The loop over an open stream (tests hand in a fake daemon's socket).
    pub(super) fn over(
        stream: Box<dyn transport::Stream>,
        sender: Sender<Wake>,
        wakes: Receiver<Wake>,
    ) -> std::io::Result<Self> {
        let reader = stream.try_clone_box()?;
        std::thread::Builder::new().name("cmux-ext-daemon".into()).spawn(move || {
            let mut lines = BufReader::new(reader);
            loop {
                let mut line = String::new();
                match lines.read_line(&mut line) {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {
                        let Ok(value) = serde_json::from_str::<Value>(&line) else { continue };
                        if sender.send(Wake::Daemon(value)).is_err() {
                            return;
                        }
                    }
                }
            }
            let _ = sender.send(Wake::DaemonGone);
        })?;
        Ok(Self {
            writer: stream,
            wakes,
            next_id: 0,
            files_changed: false,
            logs: Vec::new(),
            echo_logs: false,
        })
    }

    /// Sends `request` (its `id` is set here) and returns the id.
    pub(super) fn send(&mut self, mut request: Value) -> Result<String, Stop> {
        self.next_id += 1;
        let id = format!("ext-dev-{}", self.next_id);
        if let Some(object) = request.as_object_mut() {
            object.insert("id".into(), json!(id));
        }
        let mut line = request.to_string();
        line.push('\n');
        self.writer.write_all(line.as_bytes()).map_err(|_| Stop::Gone)?;
        Ok(id)
    }

    /// Sends `request` and waits for its answer: `Ok(data)`, or the error
    /// as `code: message`.
    pub(super) fn call(&mut self, request: Value) -> Result<Result<Value, String>, Stop> {
        let id = self.send(request)?;
        self.wait(Instant::now() + REQUEST_DEADLINE, |value| {
            (value.get("id").and_then(Value::as_str) == Some(id.as_str())).then(|| answer(value))
        })
    }

    /// Waits until `pick` returns something for a daemon line, the deadline
    /// passes, the daemon goes away or the person presses Ctrl-C. File
    /// changes on the way are remembered (`files_changed`); log lines are
    /// kept (and printed when `echo_logs`).
    pub(super) fn wait<T>(
        &mut self,
        deadline: Instant,
        mut pick: impl FnMut(&Value) -> Option<T>,
    ) -> Result<T, Stop> {
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            let wake = match self.wakes.recv_timeout(left) {
                Ok(wake) => wake,
                Err(RecvTimeoutError::Timeout) => return Err(Stop::Timeout),
                Err(RecvTimeoutError::Disconnected) => return Err(Stop::Gone),
            };
            match wake {
                Wake::Files => self.files_changed = true,
                Wake::Daemon(value) => {
                    self.note_log(&value);
                    if let Some(found) = pick(&value) {
                        return Ok(found);
                    }
                }
                Wake::DaemonGone => return Err(Stop::Gone),
                Wake::Interrupt => return Err(Stop::Interrupted),
                Wake::Installed(installed) => print_installed(installed),
            }
        }
    }

    /// The next wake with no deadline (the idle loop): no timer runs.
    pub(super) fn next_wake(&mut self) -> Option<Wake> {
        let wake = self.wakes.recv().ok()?;
        if let Wake::Daemon(value) = &wake {
            self.note_log(value);
        }
        Some(wake)
    }

    /// The next wake within `timeout` (the debounce after a file change).
    pub(super) fn next_wake_within(&mut self, timeout: Duration) -> Option<Wake> {
        let wake = self.wakes.recv_timeout(timeout).ok()?;
        if let Wake::Daemon(value) = &wake {
            self.note_log(value);
        }
        Some(wake)
    }

    /// Daemon lines already queued, handled as `wait` would, without
    /// waiting: what came before a sync is not its answer.
    pub(super) fn drain(&mut self) -> Option<Stop> {
        while let Ok(wake) = self.wakes.try_recv() {
            match wake {
                Wake::Files => self.files_changed = true,
                Wake::Daemon(value) => self.note_log(&value),
                Wake::DaemonGone => return Some(Stop::Gone),
                Wake::Interrupt => return Some(Stop::Interrupted),
                Wake::Installed(installed) => print_installed(installed),
            }
        }
        None
    }

    pub(super) fn take_logs(&mut self) -> Vec<Value> {
        std::mem::take(&mut self.logs)
    }

    fn note_log(&mut self, value: &Value) {
        if value.get("event").and_then(Value::as_str) != Some("apps-log") {
            return;
        }
        let line = json!({
            "app": value.field("app"), "level": value.field("level"), "message": value.field("message"),
        });
        if self.echo_logs {
            println!(
                "  {} [{}] {}",
                line.field("app").as_str().unwrap_or(""),
                line.field("level").as_str().unwrap_or(""),
                line.field("message").as_str().unwrap_or("")
            );
        }
        if self.logs.len() < 200 {
            self.logs.push(line);
        }
    }
}

pub(super) fn print_installed(installed: bool) {
    if installed {
        println!("installed: it shows where cmux places it (the sidebar for a section)");
    } else {
        println!("not installed: it keeps loading as a preview (`cmux apps install` to try again)");
    }
}

/// A reply's data, or its error as `code: message`.
fn answer(value: &Value) -> Result<Value, String> {
    if value.get("ok").and_then(Value::as_bool) == Some(true) {
        return Ok(value.get("data").cloned().unwrap_or(Value::Null));
    }
    Err(format!(
        "{}: {}",
        value.get("error_code").and_then(Value::as_str).unwrap_or("error"),
        value.get("error").and_then(Value::as_str).unwrap_or("")
    ))
}
