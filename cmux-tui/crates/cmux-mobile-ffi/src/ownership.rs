//! The `cmux.wire/1` stream mirror for the phone apps (object-sync phase 1,
//! plans/cmux-next/object-sync/DESIGN.md): the same engine as the Mac
//! daemon's (`cmux_cloud_wire::StreamMirror`), so every client applies,
//! buffers, resyncs and settles one way.
//!
//! Frames cross as JSON text, exactly as the socket carries them: Swift and
//! Kotlin hand each owner frame of the stream to [`OwnershipMirror::receive`]
//! and send every returned frame. The app owns the socket and the clock
//! (`now_ms`); the mirror does no I/O. The view is observed, never polled:
//! [`OwnershipMirror::set_listener`] delivers the new view after every call
//! that changed it.
//!
//! A frame that does not decode is handled here, not in the app: an event
//! asks for a snapshot, and a snapshot is asked for again after a backoff
//! (`snapshot_retry_at_ms`; call [`OwnershipMirror::snapshot_retry_due`]
//! then). After the last attempt `reconnect` is set: the app closes the
//! socket and subscribes again on a new one ([`OwnershipMirror::resume`]).

use std::fmt;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use cmux_mobile_core::wire::{ClientOut, Origin, OwnerUnreachable, SnapshotRetry, StreamMirror};
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
    /// The wire value (`user`, `cli`, `mcp`, `script`, `remote`).
    pub origin: String,
}

/// The mirror as a view renders it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct OwnershipMirrorView {
    /// Grows by one with every change the listener is told about; when
    /// several threads call one mirror, keep the view with the highest.
    pub generation: u64,
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
    /// Snapshots in a row that did not decode (0: the last one did).
    pub snapshot_failures: u32,
    /// When the next snapshot request is due (ms), after one that did not decode.
    pub snapshot_retry_at_ms: Option<i64>,
}

/// What one owner frame did.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct OwnershipStep {
    /// Frames to send now, in order.
    pub send: Vec<String>,
    /// Events and snapshots applied (0: the view did not move).
    pub applied: u32,
    /// A snapshot did not decode: call `snapshot_retry_due` at this time (ms).
    pub snapshot_retry_at_ms: Option<i64>,
    /// Every snapshot attempt failed: close the socket and resume on a new one.
    pub reconnect: bool,
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
    /// The subscribe's `pending` keys, when not empty (the owner then
    /// answers with a snapshot that settles them).
    pub pending: Vec<String>,
    /// Pending intents to send after the subscribe, with their keys.
    pub send: Vec<String>,
}

/// Receives the mirror's view after every call that changed it (an applied
/// frame, a new, settled or expired intent, a connection change, a snapshot
/// retry). Swift and Kotlin implement it. Delivery happens on the calling
/// thread after the mirror's lock is released, so the listener may call the
/// mirror again; with several calling threads, keep the highest `generation`.
#[uniffi::export(with_foreign)]
pub trait OwnershipMirrorListener: Send + Sync {
    fn on_change(&self, view: OwnershipMirrorView);
}

struct Inner {
    mirror: StreamMirror,
    listener: Option<Arc<dyn OwnershipMirrorListener>>,
    generation: u64,
    /// The view the listener has (none without a listener): an applied
    /// frame that leaves the view equal is not told.
    told: Option<OwnershipMirrorView>,
}

/// What a view shows, short of the head and rows (which move only with an
/// applied frame): two calls with equal marks and nothing applied leave the
/// view unchanged.
#[derive(PartialEq, Eq)]
struct Mark {
    seq: u64,
    pending: Vec<String>,
    expired: Vec<String>,
    connected: bool,
    awaiting: bool,
    desyncs: u64,
    snapshot_failures: u32,
    snapshot_retry_at: Option<i64>,
}

impl Mark {
    fn of(mirror: &StreamMirror) -> Self {
        let keys = |list: &[cmux_mobile_core::wire::mirror::Intent]| {
            list.iter().map(|intent| intent.idempotency_key.clone()).collect()
        };
        Self {
            seq: mirror.seq(),
            pending: keys(mirror.pending()),
            expired: keys(mirror.expired()),
            connected: mirror.is_connected(),
            awaiting: mirror.is_awaiting_snapshot(),
            desyncs: mirror.desyncs(),
            snapshot_failures: mirror.snapshot_failures(),
            snapshot_retry_at: mirror.snapshot_retry_at(),
        }
    }
}

/// One stream's confirmed mirror and intent log.
#[derive(uniffi::Object)]
pub struct OwnershipMirror {
    inner: Mutex<Inner>,
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
            origin: serde_json::to_value(intent.origin)
                .ok()
                .and_then(|v| v.as_str().map(str::to_owned))
                .unwrap_or_default(),
        })
        .collect()
}

fn view_of(mirror: &StreamMirror, generation: u64) -> OwnershipMirrorView {
    OwnershipMirrorView {
        generation,
        seq: mirror.seq(),
        state_json: mirror.state().to_string(),
        rows_json: mirror.rows().dump().to_string(),
        pending: intents(mirror.pending()),
        expired: intents(mirror.expired()),
        connected: mirror.is_connected(),
        awaiting_snapshot: mirror.is_awaiting_snapshot(),
        desyncs: mirror.desyncs(),
        snapshot_failures: mirror.snapshot_failures(),
        snapshot_retry_at_ms: mirror.snapshot_retry_at(),
    }
}

/// What a call did to the view: `Applied` when frames applied (the head or
/// rows may have moved), `Marked` to compare the cheap marks, `Always` for a
/// call that replaces the head. A possible change is then checked against
/// the view the listener has, so it is told only real changes.
enum Moved {
    Applied(bool),
    Marked,
    Always,
}

impl OwnershipMirror {
    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Runs one call on the mirror and tells the listener when the view
    /// changed, after the lock is released.
    fn mutate<T>(&self, call: impl FnOnce(&mut StreamMirror) -> (T, Moved)) -> T {
        let (value, delivery) = {
            let mut inner = self.lock();
            let before = Mark::of(&inner.mirror);
            let (value, moved) = call(&mut inner.mirror);
            let maybe = match moved {
                Moved::Always | Moved::Applied(true) => true,
                Moved::Applied(false) | Moved::Marked => Mark::of(&inner.mirror) != before,
            };
            let mut delivery = None;
            if maybe {
                let view = view_of(&inner.mirror, inner.generation + 1);
                let same = inner.told.as_ref().is_some_and(|told| {
                    OwnershipMirrorView { generation: view.generation, ..told.clone() } == view
                });
                if !same {
                    inner.generation = view.generation;
                    if let Some(listener) = inner.listener.clone() {
                        inner.told = Some(view.clone());
                        delivery = Some((listener, view));
                    }
                }
            }
            (value, delivery)
        };
        if let Some((listener, view)) = delivery {
            listener.on_change(view);
        }
        value
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
        let mirror = StreamMirror::new(key_prefix, initial);
        let inner = Inner { mirror, listener: None, generation: 0, told: None };
        Ok(Arc::new(Self { inner: Mutex::new(inner) }))
    }

    /// The view now (to render once when a screen opens; later changes
    /// come through the listener).
    pub fn view(&self) -> OwnershipMirrorView {
        let inner = self.lock();
        view_of(&inner.mirror, inner.generation)
    }

    /// Replaces the listener; `None` removes it. It is told about changes
    /// after this call, not about the view now (read [`Self::view`]).
    pub fn set_listener(&self, listener: Option<Arc<dyn OwnershipMirrorListener>>) {
        let mut inner = self.lock();
        inner.told = listener.as_ref().map(|_| view_of(&inner.mirror, inner.generation));
        inner.listener = listener;
    }

    /// One owner frame of this stream (route frames by `stream`: one mirror
    /// per stream). A frame of another kind is ignored; a known frame whose
    /// fields do not decode is handled (see the module notes). `Invalid`
    /// means the text is not JSON.
    pub fn receive(
        &self,
        frame_json: String,
        now_ms: i64,
    ) -> Result<OwnershipStep, OwnershipMirrorError> {
        let frame: Value = serde_json::from_str(&frame_json)?;
        let received = self.mutate(|mirror| {
            let received = mirror.receive_value(frame, now_ms);
            let applied = !received.applied.is_empty();
            (received, Moved::Applied(applied))
        });
        Ok(OwnershipStep {
            send: frames(received.send),
            applied: u32::try_from(received.applied.len()).unwrap_or(u32::MAX),
            snapshot_retry_at_ms: match received.snapshot_retry {
                Some(SnapshotRetry::At(at)) => Some(at),
                _ => None,
            },
            reconnect: received.snapshot_retry == Some(SnapshotRetry::Exhausted),
        })
    }

    /// The snapshot request of a snapshot that did not decode, once its
    /// backoff ended (nothing before that, or after a new snapshot).
    pub fn snapshot_retry_due(&self, now_ms: i64) -> Vec<String> {
        frames(self.mutate(|mirror| (mirror.snapshot_retry_due(now_ms), Moved::Marked)))
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
            .mutate(|mirror| (mirror.issue(&op, params, origin, now_ms), Moved::Marked))
            .map_err(|_| OwnershipMirrorError::OwnerUnreachable)?;
        Ok(OwnershipIssued { idempotency_key: key, send: frames(out) })
    }

    /// Timeout resend of one pending intent with the same key.
    pub fn retry(&self, idempotency_key: String, now_ms: i64) -> Vec<String> {
        frames(self.mutate(|mirror| (mirror.retry(&idempotency_key, now_ms), Moved::Marked)))
    }

    pub fn disconnect(&self) {
        self.mutate(|mirror| (mirror.disconnect(), Moved::Marked));
    }

    /// The socket is back on a client that keeps its subscription: resend
    /// pending intents, then ask for a snapshot.
    pub fn reconnect(&self, now_ms: i64) -> Vec<String> {
        frames(self.mutate(|mirror| (mirror.reconnect(now_ms), Moved::Marked)))
    }

    /// A new socket subscribes: where to resume and what to resend.
    pub fn resume(&self, now_ms: i64) -> OwnershipResume {
        let resume = self.mutate(|mirror| (mirror.resume(now_ms), Moved::Marked));
        OwnershipResume {
            after_seq: resume.after_seq,
            pending: resume.pending,
            send: frames(resume.send),
        }
    }

    /// Asks for a snapshot unless one is asked for (a frame the app could
    /// not render).
    pub fn resync(&self) -> Vec<String> {
        frames(self.mutate(|mirror| (mirror.resync(), Moved::Marked)))
    }

    /// Moves intents older than the TTL from pending to expired.
    pub fn expire_stale(&self, now_ms: i64) {
        self.mutate(|mirror| (mirror.expire_stale(now_ms), Moved::Marked));
    }

    /// Keys settled ok since the last call (each reported once).
    pub fn take_settled_ok(&self) -> Vec<String> {
        self.lock().mirror.take_settled_ok().into_iter().collect()
    }

    /// Another principal signed in: forget the stream and the log.
    pub fn reset(&self, initial_json: String) -> Result<(), OwnershipMirrorError> {
        let initial: Value = serde_json::from_str(&initial_json)?;
        self.mutate(|mirror| (mirror.reset(initial), Moved::Always));
        Ok(())
    }
}
