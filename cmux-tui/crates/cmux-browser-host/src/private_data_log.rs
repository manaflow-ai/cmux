//! The record of private-data operations (private data P2; Lawrence via
//! ff, 2026-10-07: every cookie clear, restore and backup purge is logged,
//! with op, site, counts and restore id, never a cookie value).
//!
//! Three places get an entry:
//! - the session's policy log (policy op "log"; `session.blockedNavigations()`
//!   shows only its `blocked` entries) for the session's own clears and
//!   restores, written by the gate;
//! - the session's event path as [`EVENT`] (`browser.privateData`, the
//!   `browser.*` kind of the Agent activity event schema,
//!   plans/cmux-next/computer-use.md section 4), written by the gate;
//! - this host log, one per host process, which only the person (user
//!   origin) reads (`browser.cookieBackups.list` answers it as `log`). It
//!   holds every session's clears and restores and the person's purges: a
//!   purge is a host op with no session, so this is its only log.
//!
//! The host log keeps the newest [`MAX_ENTRIES`] entries.

use serde_json::Value;
use std::collections::VecDeque;
use std::sync::{Mutex, PoisonError};

/// The session event name of a private-data entry.
pub const EVENT: &str = "browser.privateData";

/// Entries the host log keeps.
pub const MAX_ENTRIES: usize = 1000;

/// The host's log of private-data operations.
#[derive(Debug, Default)]
pub struct PrivateDataLog {
    entries: Mutex<VecDeque<Value>>,
}

impl PrivateDataLog {
    /// Appends an entry, dropping the oldest past [`MAX_ENTRIES`].
    pub fn push(&self, entry: Value) {
        let mut entries = self.entries.lock().unwrap_or_else(PoisonError::into_inner);
        if entries.len() >= MAX_ENTRIES {
            entries.pop_front();
        }
        entries.push_back(entry);
    }

    /// The entries, oldest first.
    pub fn entries(&self) -> Vec<Value> {
        self.entries.lock().unwrap_or_else(PoisonError::into_inner).iter().cloned().collect()
    }
}
