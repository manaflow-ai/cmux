//! The seams to the services that persist the records. Each is a trait, so cmux can run against
//! [`crate::fake`] in tests and against the hosted services once phase 1 wires them.
//!
//! - [`ForumBackend`]: the hosted forum, the durable record of threads and messages.
//! - [`RoomBackend`]: RFD 0115's rooms, the live session record and who holds which role in it.
//! - [`PresenceBackend`]: RFD 0141's opt-in presence. A lease: read only, never written to the forum.

use std::fmt;

use serde::{Deserialize, Serialize};

use crate::model::{Message, Thread};
use crate::presence::Participant;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BackendError {
    /// Not admitted, or the credential lacks the grant.
    Forbidden(String),
    NotFound(String),
    /// Unreachable or failing; retry with the same idempotency key.
    Unavailable(String),
}

impl fmt::Display for BackendError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Forbidden(m) => write!(f, "forbidden: {m}"),
            Self::NotFound(m) => write!(f, "not found: {m}"),
            Self::Unavailable(m) => write!(f, "unavailable: {m}"),
        }
    }
}

impl std::error::Error for BackendError {}

/// A message as the forum holds it: its place in the thread's log and the key that dedupes a resend.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StoredMessage {
    pub seq: u64,
    pub idempotency_key: String,
    pub message: Message,
}

/// What a post did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Posted {
    pub stored: StoredMessage,
    /// The key was seen before: this is the first post's record and nothing new was written.
    pub duplicate: bool,
}

pub trait ForumBackend {
    fn thread(&self, id: &str) -> Result<Thread, BackendError>;

    /// Create or replace a thread record (revision bumps are the caller's).
    fn put_thread(&self, thread: Thread) -> Result<(), BackendError>;

    /// Append to the message's thread. The forum dedupes on `idempotency_key`: a repeat returns the
    /// first post's record with `duplicate` set.
    fn post(&self, idempotency_key: &str, message: Message) -> Result<Posted, BackendError>;

    /// The thread's messages after `after`, oldest first.
    fn messages(&self, thread_id: &str, after: u64) -> Result<Vec<StoredMessage>, BackendError>;
}

/// A role in a live room, as the share registry grants it: `view` watches, `talk` also prompts.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RoomRole {
    View,
    Talk,
}

/// A live session's room: its stable id and who is admitted.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Room {
    pub session_id: String,
    pub owner_id: String,
    /// Principal id to role. The daemon is the authority; a revoke removes the entry.
    pub members: Vec<(String, RoomRole)>,
}

pub trait RoomBackend {
    fn room(&self, session_id: &str) -> Result<Room, BackendError>;
}

pub trait PresenceBackend {
    /// Who is here in `scope` (a chat, a workspace, a team) as of `now_ms`.
    fn here(&self, scope: &str, now_ms: u64) -> Vec<Participant>;
}
