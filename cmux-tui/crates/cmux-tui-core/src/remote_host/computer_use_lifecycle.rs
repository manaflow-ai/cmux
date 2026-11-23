//! Computer Use's lifecycle signals and live preview, between the daemon and
//! cmux Remote's Computer Use worker (cmux-computer-use `server.rs`,
//! `preview.rs`):
//!
//! - An agent's turn ended (a terminal agent's hook moved it to idle or
//!   done, `agent_reports.rs`; an agent chat's turn, acpmux through
//!   `computer-use-idle`): the worker's `session/idle` ends that session's
//!   Computer Use, so its cursor hides and its preview turns done. Sent only
//!   when the worker's activity lists such a session acting, to a worker that
//!   already runs: a turn end never starts cmux Remote.
//! - While any agent acts, the daemon holds one `preview/watch` connection to
//!   the worker and sends each preview line on as the mux's
//!   `computer-use-preview` event, with the cmux surface the agent runs in
//!   (`terminal:<terminal id>:<pid>` is a terminal pane's agent, any other key
//!   an agent chat's session id). The connection ends with the worker; the
//!   next activity opens a new one.

use std::sync::Arc;
use std::sync::atomic::Ordering;

use cmux_computer_use::client::Connection;
use serde_json::{Value, json};

use super::{Inner, RemoteHostSupervisor};
use crate::mux::Mux;

impl RemoteHostSupervisor {
    /// Whether the worker's last activity lists `session` (or, with
    /// `prefix`, a session that starts with it) as acting.
    fn acting(&self, session: &str, prefix: bool) -> bool {
        let activity = super::lock(&self.inner.activity);
        activity.as_array().is_some_and(|rows| {
            rows.iter()
                .filter_map(|row| row["session"].as_str())
                .any(|key| if prefix { key.starts_with(session) } else { key == session })
        })
    }
}

/// The worker's socket and secret, from a host that already runs (never
/// starts one). Never call it on the host's reader thread.
fn running_endpoint(inner: &Inner) -> Option<(String, String)> {
    let connection = match &*super::lock(&inner.state) {
        super::State::Running(connection) => Arc::clone(connection),
        super::State::Idle => return None,
    };
    let answer = connection.call("computer_use.endpoint", json!({"wait_ms": 0})).ok()?;
    ready(&answer)
}

fn ready(answer: &Value) -> Option<(String, String)> {
    if answer["state"] != "ready" {
        return None;
    }
    Some((answer["socket"].as_str()?.to_string(), answer["secret"].as_str()?.to_string()))
}

/// The cmux surface an agent's Computer Use session key names.
pub(crate) fn surface_of(session: &str) -> Value {
    match session.strip_prefix("terminal:").and_then(|rest| rest.rsplit_once(':')) {
        Some((terminal, _pid)) if !terminal.is_empty() => json!({"terminal": terminal}),
        _ => json!({"chat": session}),
    }
}

impl Mux {
    /// An agent's turn ended: `session` (or, with `prefix`, every session
    /// whose key starts with it) is no longer using Computer Use. Returns at
    /// once; the worker is told on a thread of its own.
    pub(crate) fn computer_use_turn_ended(&self, session: String, prefix: bool) {
        let host = &self.control_clients.remote_host;
        if session.is_empty() || !host.acting(&session, prefix) {
            return;
        }
        let inner = Arc::clone(&host.inner);
        let _ = std::thread::Builder::new().name("cu-turn-ended".into()).spawn(move || {
            let Some(endpoint) = running_endpoint(&inner) else { return };
            let request =
                json!({"id": 1, "method": "session/idle", "session": session, "prefix": prefix});
            if let Err(error) =
                cmux_computer_use::client::request(&endpoint.0, &endpoint.1, &request)
            {
                eprintln!("cmux-tui: Computer Use: could not end {session}'s turn: {error}");
            }
        });
    }

    /// Opens the daemon's `preview/watch` connection to the worker unless
    /// one is open. Returns at once.
    pub(crate) fn ensure_computer_use_preview(self: &Arc<Self>) {
        let inner = Arc::clone(&self.control_clients.remote_host.inner);
        if inner.preview_watching.swap(true, Ordering::SeqCst) {
            return;
        }
        let mux = Arc::downgrade(self);
        let spawned = std::thread::Builder::new().name("cu-preview".into()).spawn({
            let inner = Arc::clone(&inner);
            move || {
                if let Err(error) = watch(&mux, &inner) {
                    eprintln!("cmux-tui: Computer Use preview: {error}");
                }
                inner.preview_watching.store(false, Ordering::SeqCst);
            }
        });
        if spawned.is_err() {
            inner.preview_watching.store(false, Ordering::SeqCst);
        }
    }
}

/// The watch: every preview line on as `computer-use-preview`, until the
/// worker closes the connection.
fn watch(mux: &std::sync::Weak<Mux>, inner: &Inner) -> std::io::Result<()> {
    let endpoint = running_endpoint(inner)
        .ok_or_else(|| std::io::Error::other("no Computer Use worker runs"))?;
    let mut connection = Connection::open(&endpoint.0, &endpoint.1)?;
    let answer = connection.request(&json!({"id": 1, "method": "preview/watch"}))?;
    if answer.get("ok").and_then(Value::as_bool) != Some(true) {
        return Err(std::io::Error::other(answer.to_string()));
    }
    connection.unbounded()?;
    loop {
        let mut line = match connection.read() {
            Ok(line) => line,
            Err(error) if error.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(()),
            Err(error) => return Err(error),
        };
        if line.get("event").and_then(Value::as_str) != Some("preview") {
            continue;
        }
        let Some(mux) = mux.upgrade() else { return Ok(()) };
        let session = line.get("session").and_then(Value::as_str).unwrap_or_default().to_string();
        // A preview line is an object (its "event" field matched above).
        let Some(fields) = line.as_object_mut() else { continue };
        fields.insert("event".to_owned(), json!("computer-use-preview"));
        fields.insert("surface".to_owned(), surface_of(&session));
        mux.emit(crate::MuxEvent::ComputerUsePreview(Arc::new(line)));
    }
}

#[cfg(test)]
#[path = "computer_use_lifecycle_tests.rs"]
mod tests;
