//! Each terminal's last harness session, kept after the session ended (W3-H).
//!
//! An ended session leaves the agent roster, so `agent.list` no longer names
//! the harness session id that `cmux agent resume` needs. The daemon keeps the
//! last explicit session id that a hook reported for a terminal, with its
//! harness, and `session.snapshot` shows them on the terminal value's
//! `extra.agent_session_id` and `extra.agent`. Memory only: a daemon restart or
//! a closed terminal forgets them.

use super::*;

/// The last harness session of each terminal: its id and, when known, its harness.
pub(crate) type AgentLastSessions = HashMap<TerminalPublicId, (Arc<str>, Option<Arc<str>>)>;

impl Mux {
    /// Keeps `session_id` (and its `harness`) as the last harness session of `terminal`.
    pub(super) fn note_agent_session(
        &self,
        terminal: &TerminalPublicId,
        session_id: &str,
        harness: Option<&str>,
    ) {
        self.agent_last_sessions
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(terminal.clone(), (Arc::from(session_id), harness.map(Arc::from)));
    }

    /// Forgets the kept session of a closed terminal.
    pub(super) fn forget_agent_session(&self, terminal: &TerminalPublicId) {
        self.agent_last_sessions.lock().unwrap_or_else(PoisonError::into_inner).remove(terminal);
    }

    /// Every terminal's last harness session id and harness, keyed by terminal id, for the
    /// terminal value's `extra`. Read before a registry projection lock is taken: this lock
    /// is never held across another `Mux` lock.
    pub(crate) fn agent_last_sessions(&self) -> HashMap<String, (String, Option<String>)> {
        self.agent_last_sessions
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .map(|(terminal, (session, harness))| {
                (terminal.to_string(), (session.to_string(), harness.as_deref().map(str::to_owned)))
            })
            .collect()
    }
}

/// Adds `extra.agent_session_id` (and `extra.agent`, the harness) to a public terminal value
/// whose terminal has a kept harness session in `sessions` ([`Mux::agent_last_sessions`]).
/// Values without one stay as they are, so older readers see no change.
pub(crate) fn with_agent_session(
    mut terminal: Value,
    sessions: &HashMap<String, (String, Option<String>)>,
) -> Value {
    let Some((session, harness)) =
        terminal.get("id").and_then(Value::as_str).and_then(|id| sessions.get(id))
    else {
        return terminal;
    };
    let Some(object) = terminal.as_object_mut() else { return terminal };
    let extra = object.entry("extra").or_insert_with(|| Value::Object(Map::new()));
    if let Some(extra) = extra.as_object_mut() {
        extra.insert("agent_session_id".into(), Value::String(session.clone()));
        if let Some(harness) = harness {
            extra.insert("agent".into(), Value::String(harness.clone()));
        }
    }
    terminal
}
