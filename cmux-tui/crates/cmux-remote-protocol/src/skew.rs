//! Version skew between a client and a daemon built from different commits.
//!
//! A peer one release ahead sends request, response, or event shapes this
//! build does not know. Each one is that message's problem, never the
//! channel's: a request this daemon cannot decode gets an
//! `unsupported-request` error under its own id, a response this client cannot
//! decode fails only the request that asked for it, and a process event of an
//! unknown type is skipped. Before this, any one of them closed the whole
//! workspace RPC channel, and the client's reconnect read a full snapshot.
//!
//! [`SkewCounters`] counts each case and each channel reset a skew would have
//! caused, so the before and after are the same number read two ways.

use std::sync::atomic::{AtomicU64, Ordering};

use serde::Deserialize;

use crate::RequestId;

/// Error code of a request whose body this daemon cannot decode.
pub const UNSUPPORTED_REQUEST: &str = "unsupported-request";
/// Error code of a response whose body this client cannot decode.
pub const UNSUPPORTED_RESPONSE: &str = "unsupported-response";

/// The `type` tags of [`crate::ProcessEvent`] this build decodes.
pub const KNOWN_PROCESS_EVENT_TYPES: &[&str] =
    &["stdout", "stderr", "output-truncated", "replay-gap", "exit"];

#[derive(Deserialize)]
struct IdOnly {
    id: RequestId,
}

/// The request id of an encoded request or response whose body did not
/// decode, so the error can go back under that id instead of closing the
/// channel. `None` when even the id is unreadable: that peer is broken, not
/// newer.
pub fn message_id(encoded: &[u8]) -> Option<RequestId> {
    serde_json::from_slice::<IdOnly>(encoded).ok().map(|message| message.id)
}

#[derive(Deserialize)]
struct EventTypeOnly {
    event: TypeOnly,
}

#[derive(Deserialize)]
struct TypeOnly {
    #[serde(rename = "type")]
    kind: String,
}

/// The type of an encoded [`crate::RpcEvent`] when it is one this build does
/// not know (a newer daemon's event), so the stream skips it. `None` for a
/// known type, which must decode, or for a message that is not an event.
pub fn unknown_process_event_type(encoded: &[u8]) -> Option<String> {
    let event = serde_json::from_slice::<EventTypeOnly>(encoded).ok()?.event;
    (!KNOWN_PROCESS_EVENT_TYPES.contains(&event.kind.as_str())).then_some(event.kind)
}

/// Process-wide skew tally. Every field counts one message that before this
/// would have reset its channel (and so cost the client one snapshot reload).
#[derive(Debug, Default)]
pub struct SkewCounters {
    unsupported_requests: AtomicU64,
    unsupported_responses: AtomicU64,
    skipped_events: AtomicU64,
    channel_resets: AtomicU64,
}

/// A point-in-time copy of [`SkewCounters`].
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, serde::Serialize)]
pub struct SkewTally {
    /// Requests a daemon answered `unsupported-request` instead of closing.
    pub unsupported_requests: u64,
    /// Responses a client failed alone instead of closing the channel.
    pub unsupported_responses: u64,
    /// Process events of an unknown type a client skipped.
    pub skipped_events: u64,
    /// Channels still closed by an undecodable message (no readable id).
    pub channel_resets: u64,
}

impl SkewTally {
    /// Messages a skewed peer sent that no longer reset a channel.
    pub const fn absorbed(&self) -> u64 {
        self.unsupported_requests + self.unsupported_responses + self.skipped_events
    }
}

impl SkewCounters {
    pub const fn new() -> Self {
        Self {
            unsupported_requests: AtomicU64::new(0),
            unsupported_responses: AtomicU64::new(0),
            skipped_events: AtomicU64::new(0),
            channel_resets: AtomicU64::new(0),
        }
    }

    pub fn unsupported_request(&self) {
        self.unsupported_requests.fetch_add(1, Ordering::Relaxed);
    }

    pub fn unsupported_response(&self) {
        self.unsupported_responses.fetch_add(1, Ordering::Relaxed);
    }

    pub fn skipped_event(&self) {
        self.skipped_events.fetch_add(1, Ordering::Relaxed);
    }

    pub fn channel_reset(&self) {
        self.channel_resets.fetch_add(1, Ordering::Relaxed);
    }

    pub fn tally(&self) -> SkewTally {
        SkewTally {
            unsupported_requests: self.unsupported_requests.load(Ordering::Relaxed),
            unsupported_responses: self.unsupported_responses.load(Ordering::Relaxed),
            skipped_events: self.skipped_events.load(Ordering::Relaxed),
            channel_resets: self.channel_resets.load(Ordering::Relaxed),
        }
    }
}

/// The tally of this process.
pub static SKEW: SkewCounters = SkewCounters::new();

#[cfg(test)]
#[path = "skew_tests.rs"]
mod tests;
