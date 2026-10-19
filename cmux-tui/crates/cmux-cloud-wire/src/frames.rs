//! Socket frames of the `cmux.wire/1` ownership protocol
//! (backend/packages/ownership/src/types.ts; spec sync-and-transport.md
//! section 3). Every owner speaks them: the Durable Objects on
//! `/v1/wire/*`, and later the daemon's host-homed streams through `HostDO`
//! (plans/cmux-next/object-sync DESIGN.md section 6).
//!
//! Values the mirror never interprets (op params, head state, row values,
//! the actor) stay [`Value`], so a newer owner's fields pass through.

use crate::Origin;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// One row of a row-backed owner: a message, an inbox order key.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StoredRow {
    pub key: String,
    /// Order within the table (for example the message seq); null when unordered.
    pub n: Option<i64>,
    #[serde(default)]
    pub row: Value,
}

/// One committed row change of an op (`RowWrite`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "lowercase")]
pub enum RowWrite {
    Upsert {
        table: String,
        key: String,
        #[serde(default)]
        n: Option<i64>,
        row: Value,
    },
    Delete {
        table: String,
        key: String,
    },
    /// A write kind this build does not know: the mirror resyncs from a snapshot.
    #[serde(other)]
    Unknown,
}

/// What a row-mode event changed: the new head state and the row writes.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Effects {
    #[serde(default)]
    pub state: Value,
    pub writes: Vec<RowWrite>,
}

/// Owner to subscribers: one committed event.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EventFrame {
    pub stream: String,
    pub seq: u64,
    pub tx: String,
    pub op: String,
    #[serde(default)]
    pub params: Value,
    #[serde(default)]
    pub actor: Value,
    /// Kept verbatim: a newer owner's origin value must not fail the frame.
    #[serde(default)]
    pub origin: Value,
    #[serde(default)]
    pub at: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effects: Option<Effects>,
}

/// The last frame of every request: the write barrier.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SettledFrame {
    pub tx: String,
    pub idempotency_key: String,
    pub stream: String,
    /// Seq of the request's last event, 0 when it caused none.
    pub sequence: u64,
    pub ok: bool,
}

/// A key the owner already decided, carried by a snapshot.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DecidedKey {
    pub idempotency_key: String,
    pub ok: bool,
    pub sequence: u64,
}

/// Rows a snapshot carries: the newest rows of the owner's snapshot table.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SnapshotRows {
    pub table: String,
    pub rows: Vec<StoredRow>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SnapshotFrame {
    pub stream: String,
    pub seq: u64,
    pub state: Value,
    #[serde(default)]
    pub decided: Vec<DecidedKey>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rows: Option<SnapshotRows>,
}

/// Owner to client. `result` and `reject` carry the value for the caller;
/// the mirror's log is decided by `request-settled`. Any other `t` (welcome,
/// typing, live run frames, frames of a newer owner) is [`OwnerFrame::Other`].
#[derive(Debug, Clone, PartialEq)]
pub enum OwnerFrame {
    Event(Box<EventFrame>),
    Settled(SettledFrame),
    Snapshot(SnapshotFrame),
    Result(Value),
    Reject(Value),
    Other(Value),
}

impl OwnerFrame {
    /// Decodes one JSON text frame. A frame whose `t` is known but whose
    /// fields do not decode is an error; an unknown `t` is `Other`.
    pub fn from_value(v: Value) -> Result<Self, serde_json::Error> {
        let t = v.get("t").and_then(Value::as_str).unwrap_or_default().to_owned();
        Ok(match t.as_str() {
            "event" => Self::Event(Box::new(serde_json::from_value(v)?)),
            "request-settled" => Self::Settled(serde_json::from_value(v)?),
            "snapshot" => Self::Snapshot(serde_json::from_value(v)?),
            "result" => Self::Result(v),
            "reject" => Self::Reject(v),
            _ => Self::Other(v),
        })
    }
}

/// Client to owner: one typed op with a client-chosen idempotency key.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OpFrame {
    pub op: String,
    pub params: Value,
    pub idempotency_key: String,
    pub origin: Origin,
}

/// What the mirror asks its transport to send.
#[derive(Debug, Clone, PartialEq)]
pub enum ClientOut {
    Op(OpFrame),
    /// Ask for a snapshot that also reports which of `pending` are decided.
    SnapshotRequest {
        pending: Vec<String>,
    },
}

impl ClientOut {
    /// The JSON text frame for the socket.
    pub fn to_value(&self) -> Value {
        match self {
            Self::Op(f) => serde_json::json!({
                "t": "op",
                "op": f.op,
                "params": f.params,
                "idempotency_key": f.idempotency_key,
                "origin": f.origin,
            }),
            Self::SnapshotRequest { pending } => {
                serde_json::json!({ "t": "snapshot.request", "pending": pending })
            }
        }
    }
}
