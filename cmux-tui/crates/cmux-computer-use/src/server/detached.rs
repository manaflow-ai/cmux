//! Sessions that call with no presence connection (`session/attach`): the
//! `cmux computer-use call` CLI, one process per call, and calls another
//! machine relays (`remote:<machine>:<key>`). Nothing closes for them, so
//! their state (the element ids they were shown, their last looks) would
//! otherwise live as long as the worker. A session here ends once it made no
//! call for [`DETACHED_IDLE`], and the least recently used ones end first
//! when more than [`DETACHED_MAX`] are kept.
//!
//! A session with an open attach is never ended here: its attach's close
//! ends it.

use std::collections::HashMap;
use std::time::{Duration, Instant};

/// A detached session ends after this long with no call.
pub const DETACHED_IDLE: Duration = Duration::from_secs(30 * 60);
/// The most detached sessions kept at once.
pub const DETACHED_MAX: usize = 32;

/// Detached sessions and when each last called.
#[derive(Default)]
pub struct Detached {
    last: HashMap<String, Instant>,
    pending: HashMap<String, u64>,
    next_ticket: u64,
}

impl Detached {
    /// `session` called at `now`; `is_attached` says whether a session has an
    /// open attach (those are not tracked: their attach ends them). The
    /// sessions that end now (idle past [`DETACHED_IDLE`], or the oldest
    /// past [`DETACHED_MAX`]), never `session` itself and never an attached
    /// one.
    pub fn touch(
        &mut self,
        session: &str,
        now: Instant,
        is_attached: impl Fn(&str) -> bool,
    ) -> Vec<(String, u64)> {
        self.pending.remove(session);
        self.last.insert(session.to_string(), now);
        // One that attached since its last call is its attach's to end.
        self.last.retain(|s, _| !is_attached(s));
        let mut ended: Vec<String> = self
            .last
            .iter()
            .filter(|(s, at)| {
                s.as_str() != session && now.saturating_duration_since(**at) >= DETACHED_IDLE
            })
            .map(|(s, _)| s.clone())
            .collect();
        for s in &ended {
            self.last.remove(s);
        }
        if self.last.len() > DETACHED_MAX {
            let mut by_age: Vec<(String, Instant)> =
                self.last.iter().map(|(s, at)| (s.clone(), *at)).collect();
            by_age.sort_by_key(|(_, at)| *at);
            let over = self.last.len() - DETACHED_MAX;
            for (s, _) in by_age.into_iter().filter(|(s, _)| s != session).take(over) {
                self.last.remove(&s);
                ended.push(s);
            }
        }
        ended.sort();
        ended
            .into_iter()
            .map(|session| {
                self.next_ticket += 1;
                self.pending.insert(session.clone(), self.next_ticket);
                (session, self.next_ticket)
            })
            .collect()
    }

    /// Claims a queued expiry only while no later call or end invalidated it.
    pub fn take_expiry(&mut self, session: &str, ticket: u64) -> bool {
        if self.pending.get(session) != Some(&ticket) {
            return false;
        }
        self.pending.remove(session);
        true
    }

    /// The session ended another way (`session/end`): forget it.
    pub fn forget(&mut self, session: &str) {
        self.last.remove(session);
        self.pending.remove(session);
    }

    #[cfg(test)]
    pub fn len(&self) -> usize {
        self.last.len()
    }

    #[cfg(test)]
    pub fn contains(&self, session: &str) -> bool {
        self.last.contains_key(session)
    }
}

#[cfg(test)]
#[path = "detached_tests.rs"]
mod tests;
