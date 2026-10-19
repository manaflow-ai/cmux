//! The `cmux.wire/1` stream mirror for the phone apps (object-sync phase 1,
//! plans/cmux-next/object-sync/DESIGN.md): the same engine as the Mac
//! daemon's (`cmux_cloud_wire::StreamMirror`), so every client applies,
//! buffers, resyncs and settles one way.
//!
//! Frames cross as JSON text, exactly as the socket carries them: Swift and
//! Kotlin hand each owner frame of the stream to [`OwnershipMirror::receive`]
//! and send every returned frame. The app owns the socket and the clock
//! (`now_ms`); the mirror does no I/O.

use std::fmt;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use cmux_mobile_core::wire::{ClientOut, Origin, OwnerFrame, OwnerUnreachable, StreamMirror};
use serde_json::Value;

/// Why the mirror refused a call.
#[derive(Debug, PartialEq, Eq, uniffi::Error)]
pub enum OwnershipMirrorError {
    /// JSON that is not a frame, a value or an origin the contract accepts.
    Invalid { detail: String },
    /// A new op while the owner is unreachable: refused, nothing queues.
    OwnerUnreachable,
}

impl fmt::Display for OwnershipMirrorError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Invalid { detail } => write!(f, "invalid cmux.wire/1 JSON: {detail}"),
            Self::OwnerUnreachable => f.write_str(&OwnerUnreachable.to_string()),
        }
    }
}

impl std::error::Error for OwnershipMirrorError {}

impl From<serde_json::Error> for OwnershipMirrorError {
    fn from(error: serde_json::Error) -> Self {
        Self::Invalid { detail: error.to_string() }
    }
}

/// One intent of the log.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct OwnershipIntent {
    pub idempotency_key: String,
    pub op: String,
    pub params_json: String,
}

/// The mirror as a view renders it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct OwnershipMirrorView {
    pub seq: u64,
    pub state_json: String,
    /// `{table: {key: {key, n, row}}}`.
    pub rows_json: String,
    /// Not decided yet, in issue order: render as pending.
    pub pending: Vec<OwnershipIntent>,
    /// Outlived the TTL undecided: show as not sent.
    pub expired: Vec<OwnershipIntent>,
    pub connected: bool,
    pub awaiting_snapshot: bool,
    pub desyncs: u64,
}

/// What one owner frame did.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct OwnershipStep {
    /// Frames to send now, in order.
    pub send: Vec<String>,
    /// Events and snapshots applied (0: the view did not move).
    pub applied: u32,
}

/// A new intent: its key and the frame to send.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct OwnershipIssued {
    pub idempotency_key: String,
    pub send: Vec<String>,
}

/// How to subscribe on a new connection.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct OwnershipResume {
    /// `subscribe {after_seq}` when set; otherwise subscribe fresh.
    pub after_seq: Option<u64>,
    /// Pending intents to send after the subscribe, with their keys.
    pub send: Vec<String>,
}

/// One stream's confirmed mirror and intent log.
#[derive(uniffi::Object)]
pub struct OwnershipMirror {
    inner: Mutex<StreamMirror>,
}

fn frames(out: Vec<ClientOut>) -> Vec<String> {
    out.iter().map(|frame| frame.to_value().to_string()).collect()
}

fn intents(list: &[cmux_mobile_core::wire::mirror::Intent]) -> Vec<OwnershipIntent> {
    list.iter()
        .map(|intent| OwnershipIntent {
            idempotency_key: intent.idempotency_key.clone(),
            op: intent.op.clone(),
            params_json: intent.params.to_string(),
        })
        .collect()
}

impl OwnershipMirror {
    fn lock(&self) -> MutexGuard<'_, StreamMirror> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

#[uniffi::export]
impl OwnershipMirror {
    /// `key_prefix` must be unique per client and stable for the life of its
    /// intent log (an install id and a random part); `initial_json` is the
    /// head before the first snapshot.
    #[uniffi::constructor]
    pub fn new(
        key_prefix: String,
        initial_json: String,
    ) -> Result<Arc<Self>, OwnershipMirrorError> {
        let initial: Value = serde_json::from_str(&initial_json)?;
        Ok(Arc::new(Self { inner: Mutex::new(StreamMirror::new(key_prefix, initial)) }))
    }

    pub fn view(&self) -> OwnershipMirrorView {
        let mirror = self.lock();
        OwnershipMirrorView {
            seq: mirror.seq(),
            state_json: mirror.state().to_string(),
            rows_json: mirror.rows().dump().to_string(),
            pending: intents(mirror.pending()),
            expired: intents(mirror.expired()),
            connected: mirror.is_connected(),
            awaiting_snapshot: mirror.is_awaiting_snapshot(),
            desyncs: mirror.desyncs(),
        }
    }

    /// One owner frame of this stream (route frames by `stream`: one mirror
    /// per stream). A frame of another kind is ignored.
    pub fn receive(&self, frame_json: String) -> Result<OwnershipStep, OwnershipMirrorError> {
        let frame = OwnerFrame::from_value(serde_json::from_str(&frame_json)?)?;
        let received = self.lock().receive_applied(frame);
        Ok(OwnershipStep {
            send: frames(received.send),
            applied: u32::try_from(received.applied.len()).unwrap_or(u32::MAX),
        })
    }

    /// Issues a typed intent. `origin` is the wire value (`user`, `cli`,
    /// `mcp`, `script`, `remote`).
    pub fn issue(
        &self,
        op: String,
        params_json: String,
        origin: String,
        now_ms: i64,
    ) -> Result<OwnershipIssued, OwnershipMirrorError> {
        let params: Value = serde_json::from_str(&params_json)?;
        let origin: Origin = serde_json::from_value(Value::String(origin))?;
        let (key, out) = self
            .lock()
            .issue(&op, params, origin, now_ms)
            .map_err(|_| OwnershipMirrorError::OwnerUnreachable)?;
        Ok(OwnershipIssued { idempotency_key: key, send: frames(out) })
    }

    /// Timeout resend of one pending intent with the same key.
    pub fn retry(&self, idempotency_key: String, now_ms: i64) -> Vec<String> {
        frames(self.lock().retry(&idempotency_key, now_ms))
    }

    pub fn disconnect(&self) {
        self.lock().disconnect();
    }

    /// The socket is back on a client that keeps its subscription: resend
    /// pending intents, then ask for a snapshot.
    pub fn reconnect(&self, now_ms: i64) -> Vec<String> {
        frames(self.lock().reconnect(now_ms))
    }

    /// A new socket subscribes: where to resume and what to resend.
    pub fn resume(&self, now_ms: i64) -> OwnershipResume {
        let resume = self.lock().resume(now_ms);
        OwnershipResume { after_seq: resume.after_seq, send: frames(resume.send) }
    }

    /// Asks for a snapshot unless one is asked for (a frame the app could
    /// not render).
    pub fn resync(&self) -> Vec<String> {
        frames(self.lock().resync())
    }

    /// Moves intents older than the TTL from pending to expired.
    pub fn expire_stale(&self, now_ms: i64) {
        self.lock().expire_stale(now_ms);
    }

    /// Keys settled ok since the last call (each reported once).
    pub fn take_settled_ok(&self) -> Vec<String> {
        self.lock().take_settled_ok().into_iter().collect()
    }

    /// Another principal signed in: forget the stream and the log.
    pub fn reset(&self, initial_json: String) -> Result<(), OwnershipMirrorError> {
        let initial: Value = serde_json::from_str(&initial_json)?;
        self.lock().reset(initial);
        Ok(())
    }
}
