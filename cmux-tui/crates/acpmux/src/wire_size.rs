//! A watch on the size of outgoing messages: the next one too large to send is seen coming.
//!
//! Every capped send measures its line already ([`Message::bounded_line`], the list replies'
//! `Conn::send_serialized`); it hands the length here. A line under [`NEAR_CAP_BYTES`] (three
//! quarters of [`MAX_MESSAGE_BYTES`]) costs one comparison. One at or above it is counted
//! (`nearCap` while it still fits, `tooLarge` once it is refused), remembered as the last, and
//! warned of in the journal at most once a minute per method and kind, so a hot path near the
//! cap cannot flood it. `_acpmux/status` reports the counts as `largeMessages`. This only
//! observes: the cap stays the safety rail.

use std::collections::BTreeMap;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::rpc::{MAX_MESSAGE_BYTES, Message};

/// Three quarters of [`MAX_MESSAGE_BYTES`]: a message this large is counted and warned of.
pub const NEAR_CAP_BYTES: usize = MAX_MESSAGE_BYTES / 4 * 3;

/// At most one warning per method and kind (near the cap, too large) in this long.
const WARN_EVERY: Duration = Duration::from_secs(60);

/// At most this many methods remembered for [`WARN_EVERY`]; a label can come from a peer.
const WARN_KEYS: usize = 256;

/// What a message is, for its label: a request's or notification's method, or a reply, to the
/// request it answers when the sender knows it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum What<'a> {
    Method(&'a str),
    ReplyTo(&'a str),
    Reply,
}

impl<'a> What<'a> {
    /// `msg`'s label; `reply_to` is the method of the request a response answers, if known.
    pub fn of(msg: &'a Message, reply_to: Option<&'a str>) -> Self {
        match (msg.method(), reply_to) {
            (Some(method), _) => What::Method(method),
            (None, Some(method)) => What::ReplyTo(method),
            (None, None) => What::Reply,
        }
    }

    pub fn label(self) -> String {
        match self {
            What::Method(method) => method.to_owned(),
            What::ReplyTo(method) => format!("reply to {method}"),
            What::Reply => "reply".to_owned(),
        }
    }
}

/// The last message counted.
struct Last {
    what: String,
    bytes: usize,
    at_ms: u64,
    too_large: bool,
}

struct Inner {
    last: Option<Last>,
    /// When each (too large, label) was last warned of.
    warned: BTreeMap<(bool, String), Instant>,
}

/// The counts; [`global`] is this daemon's.
pub struct SizeWatch {
    near_cap: AtomicU64,
    too_large: AtomicU64,
    inner: Mutex<Inner>,
}

impl Default for SizeWatch {
    fn default() -> Self {
        Self::new()
    }
}

impl SizeWatch {
    pub const fn new() -> Self {
        Self {
            near_cap: AtomicU64::new(0),
            too_large: AtomicU64::new(0),
            inner: Mutex::new(Inner { last: None, warned: BTreeMap::new() }),
        }
    }

    /// A line of `bytes` for `what` went out (or, over [`MAX_MESSAGE_BYTES`], was refused).
    /// True when this call warned in the journal.
    pub fn observe(&self, what: What<'_>, bytes: usize) -> bool {
        if bytes < NEAR_CAP_BYTES {
            return false;
        }
        self.observe_at(what, bytes, Instant::now())
    }

    fn observe_at(&self, what: What<'_>, bytes: usize, now: Instant) -> bool {
        if bytes < NEAR_CAP_BYTES {
            return false;
        }
        let too_large = bytes > MAX_MESSAGE_BYTES;
        let count = if too_large { &self.too_large } else { &self.near_cap };
        count.fetch_add(1, Ordering::Relaxed);
        let label = what.label();
        let warn = {
            let mut inner = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            inner.last =
                Some(Last { what: label.clone(), bytes, at_ms: crate::store::now_ms(), too_large });
            let key = (too_large, label);
            let due = inner
                .warned
                .get(&key)
                .is_none_or(|at| now.saturating_duration_since(*at) >= WARN_EVERY);
            // A key new to a full set: the expired ones go first; while every one is still in
            // its quiet minute, the new key waits too (counted, not warned), and no method's
            // quiet minute is cut short to make room.
            if due && !inner.warned.contains_key(&key) && inner.warned.len() >= WARN_KEYS {
                inner.warned.retain(|_, at| now.saturating_duration_since(*at) < WARN_EVERY);
            }
            let room = inner.warned.contains_key(&key) || inner.warned.len() < WARN_KEYS;
            let warn = due && room;
            if warn {
                inner.warned.insert(key.clone(), now);
            }
            warn.then_some(key.1)
        };
        let Some(method) = warn else {
            return false;
        };
        let limit = MAX_MESSAGE_BYTES;
        if too_large {
            tracing::warn!(
                method,
                bytes,
                limit,
                "refused a message too large to send (at most one warning a minute per method)"
            );
        } else {
            tracing::warn!(
                method,
                bytes,
                limit,
                near = NEAR_CAP_BYTES,
                "sent a message near the per-message cap (at most one warning a minute per method)"
            );
        }
        true
    }

    /// `largeMessages` in `_acpmux/status`.
    pub fn status(&self) -> Value {
        let inner = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let last = inner.last.as_ref();
        json!({
            "nearCap": self.near_cap.load(Ordering::Relaxed),
            "tooLarge": self.too_large.load(Ordering::Relaxed),
            "nearCapBytes": NEAR_CAP_BYTES,
            "limit": MAX_MESSAGE_BYTES,
            "lastMethod": last.map(|l| l.what.clone()),
            "lastBytes": last.map(|l| l.bytes),
            "lastAt": last.map(|l| l.at_ms),
            "lastTooLarge": last.map(|l| l.too_large),
        })
    }

    #[cfg(test)]
    fn warned_len(&self) -> usize {
        self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner).warned.len()
    }
}

static GLOBAL: SizeWatch = SizeWatch::new();

/// This daemon's watch: every capped send in the process counts here.
pub fn global() -> &'static SizeWatch {
    &GLOBAL
}

/// [`SizeWatch::observe`] on [`global`].
pub fn observe(what: What<'_>, bytes: usize) -> bool {
    GLOBAL.observe(what, bytes)
}

#[cfg(test)]
#[path = "wire_size_tests.rs"]
mod tests;
