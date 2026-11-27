//! Part of the server; see `server/mod.rs`. The rows of an attached chat's turn-opening records
//! wait behind the turn's first output.
//!
//! A prompt logs `user_message`, `turn_started` and `status` before the agent's first word, and
//! each sent the chat's whole row (`_acpmux/session_changed`, 3 KB and a millisecond to build)
//! down the connection's one ordered queue ahead of that word. On a peer daemon's link the three
//! rows also raised the durable gate past the events themselves (`durable_gate.rs`), so the first
//! reply chunk of a moved chat waited on journal syncs it showed nothing of, then on the origin
//! reading three rows before it: 8 ms of the 13 ms a moved chat's first token took, 5 ms local
//! (tests/transfer_cli/view_latency.rs).
//!
//! Each row is still sent, with its own kind, seq and `listSeq`, in row order: a held row goes
//! before any later row of this connection, before a turn's answer (`fanout::Flush`), and at
//! most [`HOLD`] after its record. Only its place among the agent's output moves, and the events
//! of the same records (`_acpmux/event`) go at once as before.

use super::{Conn, Hub, Message, json, method, outbound, requests, session_patch};
use crate::no_panic::LockExt as _;
use serde_json::Value;
use std::sync::Arc;
use std::sync::Mutex as StdMutex;
use std::sync::atomic::Ordering;
use tokio::time::{Duration, Instant};

/// How long a turn-opening row waits for the turn's first output to pass it.
const HOLD: Duration = Duration::from_millis(25);

/// A record whose row is held: the ones every prompt logs before the agent answers.
pub(super) fn opens_a_turn(record_kind: &str) -> bool {
    matches!(record_kind, "user_message" | "turn_started" | "status")
}

struct Held {
    session_id: String,
    kind: String,
    seq: u64,
    list_seq: u64,
}

#[derive(Default)]
pub(super) struct HeldRows(StdMutex<(Vec<Held>, Option<Instant>)>);

impl HeldRows {
    pub(super) fn hold(&self, session_id: &str, kind: &str, seq: u64, list_seq: u64) {
        let mut held = self.0.lock_or_recover();
        held.0.push(Held {
            session_id: session_id.to_owned(),
            kind: kind.to_owned(),
            seq,
            list_seq,
        });
        held.1.get_or_insert_with(|| Instant::now() + HOLD);
    }

    /// When the oldest held row is due, None with none held.
    pub(super) fn due(&self) -> Option<Instant> {
        self.0.lock_or_recover().1
    }

    fn take(&self) -> Vec<Held> {
        let mut held = self.0.lock_or_recover();
        held.1 = None;
        std::mem::take(&mut held.0)
    }
}

pub(super) async fn wait(due: Option<Instant>) {
    match due {
        Some(due) => tokio::time::sleep_until(due).await,
        None => std::future::pending().await,
    }
}

/// Sends the rows held for `conn`, oldest first. A chat's row is built once for all of its held
/// rows: it is the chat as it is now, which each of them would show anyway once applied.
///
/// They go the way every other attached row goes (`server/mod.rs`): without the time breakdown
/// to a client that draws none, and as a `session_patch` to a connection that asked for patches
/// (`session_patch.rs`). Sent whole, they were most of a peer link's bytes under a streaming
/// chat: five rows a turn, each the 3 to 100 KB row again, ahead of the turn's output in the
/// link's one ordered queue (cmux#58056's duress runs: 380 of the 640 KB a kept relay link
/// carried more than a fresh one).
pub(super) fn flush(hub: &Hub, conn: &Conn) {
    flush_sharing(hub, conn, None);
}

/// [`flush`] ahead of `ev`'s own row: a held row of `ev`'s chat is the event's shared full row
/// (`HubEvent::row`), built once for this connection's held rows, its own row and every other
/// watcher's, where each had built it again (6% of a host's CPU in a 2,000-chat prompt burst).
/// The row returned keeps that cell alive until the event's row is read from it.
pub(super) fn flush_sharing(
    hub: &Hub,
    conn: &Conn,
    ev: Option<&crate::hub::HubEvent>,
) -> Option<Arc<Value>> {
    let held = conn.held_rows.take();
    let mut shared = None;
    let mut built: Option<(&str, Arc<Value>)> = None;
    for row in &held {
        if built.as_ref().is_none_or(|(id, _)| *id != row.session_id) {
            let lean = conn.omit_time_breakdown.load(Ordering::SeqCst)
                || super::omits_time_breakdown(conn, &row.session_id);
            let build = || {
                let s = hub.resolve(&row.session_id).ok()?;
                let mut summary = hub.session_change_summary(&s);
                if lean {
                    requests::without_time_breakdown(&mut summary);
                }
                Some(summary)
            };
            let summary = match ev {
                Some(ev) if ev.remote.is_none() && ev.session_id == row.session_id => {
                    let summary = ev.row.cells[if lean { 2 } else { 1 }].get_or_build(build);
                    shared.clone_from(&summary);
                    summary
                }
                _ => build().map(Arc::new),
            };
            let Some(summary) = summary else { continue };
            built = Some((&row.session_id, summary));
        }
        let Some((_, summary)) = &built else { continue };
        let notice = json!({"sessionId": row.session_id, "kind": row.kind, "recordKind": row.kind, "seq": row.seq, "listSeq": row.list_seq});
        if session_patch::send_row(conn, &row.session_id, true, summary, notice) {
            continue;
        }
        conn.send_row(
            &Message::notification(
                method::MUX_SESSION_CHANGED,
                row_notice(&row.session_id, summary, &row.kind, &row.kind, row.seq, row.list_seq),
            ),
            outbound::Row::None,
        );
    }
    shared
}

/// A `_acpmux/session_changed` notice's params, with the row cloned in: `json!` copies a `Value`
/// through the serializer (`to_value`), 1.4% of a host's CPU in a 2,000-chat prompt burst.
pub(super) fn row_notice(
    session_id: &str,
    summary: &Value,
    kind: &str,
    record_kind: &str,
    seq: u64,
    list_seq: u64,
) -> Value {
    let mut params = serde_json::Map::new();
    params.insert("sessionId".into(), Value::String(session_id.to_owned()));
    params.insert("session".into(), summary.clone());
    params.insert("kind".into(), Value::String(kind.to_owned()));
    params.insert("recordKind".into(), Value::String(record_kind.to_owned()));
    params.insert("seq".into(), seq.into());
    params.insert("listSeq".into(), list_seq.into());
    Value::Object(params)
}
