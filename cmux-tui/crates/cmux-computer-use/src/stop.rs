//! The person's Stop for one agent session (the cmux menu bar's Stop, the
//! worker's `session` control line). A stopped session acts no more until
//! the person resumes it:
//!
//! - its in-flight call ends at its next checkpoint (between the steps of a
//!   batch, between the keys of paced typing, between the captures of the
//!   settle wait), and returns [`STOPPED_CODE`] in place of its result;
//! - every later call returns [`STOPPED_CODE`] with [`STOPPED_MESSAGE`], which
//!   reaches the agent unchanged as the tool's error text;
//! - other sessions are unaffected, and the agent's terminal or chat keeps
//!   running: only its Computer Use stops.
//!
//! The list lives in memory: a restarted worker forgets it, as it forgets the
//! agent cursors.

use std::collections::HashSet;
use std::sync::RwLock;
use std::sync::atomic::{AtomicBool, Ordering};

use serde_json::json;

use crate::engine::ToolOutput;

/// The tool error code of a stopped session's calls.
pub const STOPPED_CODE: &str = "stopped_by_person";

/// What the agent reads when the person stopped it.
pub const STOPPED_MESSAGE: &str = "The person stopped this agent's Computer Use from the cmux menu bar. Do not retry or work around it; tell the person what you were doing and ask whether to continue.";

/// The cursor's caption when a stopped session's call is refused.
pub const STOPPED_CAPTION: &str = "Stopped";

/// The stopped sessions. `is_stopped` is one relaxed load while nothing is
/// stopped, so the checkpoints cost nothing in the common case.
#[derive(Default)]
pub struct Stops {
    any: AtomicBool,
    sessions: RwLock<HashSet<String>>,
}

impl Stops {
    /// Stops `session`; false when it already was.
    pub fn stop(&self, session: &str) -> bool {
        let mut sessions = self.sessions.write().unwrap_or_else(std::sync::PoisonError::into_inner);
        let added = sessions.insert(session.to_string());
        self.any.store(true, Ordering::Release);
        added
    }

    /// Resumes `session`; false when it was not stopped.
    pub fn resume(&self, session: &str) -> bool {
        let mut sessions = self.sessions.write().unwrap_or_else(std::sync::PoisonError::into_inner);
        let removed = sessions.remove(session);
        self.any.store(!sessions.is_empty(), Ordering::Release);
        removed
    }

    pub fn is_stopped(&self, session: &str) -> bool {
        self.any.load(Ordering::Acquire)
            && self
                .sessions
                .read()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .contains(session)
    }

    /// The stopped sessions, sorted.
    pub fn list(&self) -> Vec<String> {
        let mut list: Vec<String> = self
            .sessions
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter()
            .cloned()
            .collect();
        list.sort();
        list
    }

    /// A checkpoint: `Err` with the stopped error when `session` is stopped.
    pub fn check(&self, session: &str) -> Result<(), ToolOutput> {
        if self.is_stopped(session) { Err(stopped()) } else { Ok(()) }
    }
}

/// The error a stopped session's call returns.
pub fn stopped() -> ToolOutput {
    ToolOutput::error(STOPPED_CODE, STOPPED_MESSAGE)
}

/// The error for a call that was running when the person stopped it: it may
/// have acted before its checkpoint (`acted`), and says so.
pub fn stopped_in_flight(acted: bool) -> ToolOutput {
    let mut out = stopped();
    out.body["stopped_during_call"] = json!(true);
    out.body["acted_before_stop"] = json!(acted);
    out
}

#[cfg(test)]
#[path = "stop_tests.rs"]
mod tests;
