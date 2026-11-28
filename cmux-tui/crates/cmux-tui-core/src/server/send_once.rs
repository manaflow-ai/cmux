//! `send-key-v1`: `send` takes an optional `key`, so a client that does not know whether its
//! `send` arrived (the link dropped after the write, before the reply) can send the same input
//! again with the same key, and the terminal gets it once.
//!
//! The phone used to put such text back in its composer instead; a second Send then typed it
//! twice when the first had in fact arrived (a command run twice). With a key, the daemon
//! remembers the keys it applied and answers a repeat with the same success reply, writing
//! nothing.
//!
//! The keys are remembered daemon-wide (a resend may come on another connection, after the
//! phone reattached), bounded in count ([`MAX_KEYS`]) and age ([`TTL`]). A `send` without a key
//! is unchanged. A key is claimed before the write and forgotten only when the write is known
//! not to have happened, so a repeat that races the first one (the first still being written)
//! is not written twice either.

use std::collections::HashMap;
use std::collections::VecDeque;
use std::sync::Mutex;
use std::sync::OnceLock;
use std::time::Duration;
use std::time::Instant;

/// Advertised in `identify`'s capabilities: `send` takes `key`.
pub(super) const SEND_KEY_CAPABILITY: &str = "send-key-v1";
/// How long an applied key is remembered. A client resends within its own input hold (10 s on
/// the phone); this leaves a wide margin.
pub(super) const TTL: Duration = Duration::from_secs(600);
/// How many keys are remembered; past it the oldest goes first.
pub(super) const MAX_KEYS: usize = 1024;
/// A longer key is refused (a key is an id, not a payload).
pub(super) const MAX_KEY_LEN: usize = 128;

/// Applied keys, oldest first in `order`.
pub(super) struct SentKeys {
    at: HashMap<String, Instant>,
    order: VecDeque<(String, Instant)>,
    ttl: Duration,
    max: usize,
}

impl SentKeys {
    pub(super) fn new(ttl: Duration, max: usize) -> Self {
        Self { at: HashMap::new(), order: VecDeque::new(), ttl, max: max.max(1) }
    }

    /// True when `key` is new (the caller writes); false when it was already applied within the
    /// TTL (the caller writes nothing and answers success).
    pub(super) fn claim(&mut self, key: &str, now: Instant) -> bool {
        self.expire(now);
        if self.at.contains_key(key) {
            return false;
        }
        while self.at.len() >= self.max {
            let Some((old, at)) = self.order.pop_front() else { break };
            if self.at.get(&old) == Some(&at) {
                self.at.remove(&old);
            }
        }
        self.at.insert(key.to_owned(), now);
        self.order.push_back((key.to_owned(), now));
        true
    }

    /// The claimed write did not happen: a later `send` with this key writes.
    pub(super) fn forget(&mut self, key: &str) {
        self.at.remove(key);
    }

    #[cfg(test)]
    pub(super) fn len(&self) -> usize {
        self.at.len()
    }

    fn expire(&mut self, now: Instant) {
        while let Some((key, at)) = self.order.front() {
            if now.saturating_duration_since(*at) < self.ttl {
                break;
            }
            if self.at.get(key) == Some(at) {
                self.at.remove(key);
            }
            self.order.pop_front();
        }
    }
}

/// The daemon's applied keys.
pub(super) fn sent_keys() -> &'static Mutex<SentKeys> {
    static KEYS: OnceLock<Mutex<SentKeys>> = OnceLock::new();
    KEYS.get_or_init(|| Mutex::new(SentKeys::new(TTL, MAX_KEYS)))
}

#[cfg(test)]
#[path = "send_once_tests.rs"]
mod tests;
