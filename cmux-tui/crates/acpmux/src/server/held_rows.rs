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

use super::{Conn, Hub, Message, json, method, outbound};
use crate::no_panic::LockExt as _;
use std::sync::Mutex as StdMutex;
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
pub(super) fn flush(hub: &Hub, conn: &Conn) {
    let held = conn.held_rows.take();
    let mut built: Option<(&str, serde_json::Value)> = None;
    for row in &held {
        if built.as_ref().is_none_or(|(id, _)| *id != row.session_id) {
            let Ok(s) = hub.resolve(&row.session_id) else { continue };
            // A client that draws no breakdown gets the row without it (`server/mod.rs`'s
            // `lean`), and its build leaves the chart the chat's rows owe to the next client.
            let lean = conn.omit_time_breakdown.load(std::sync::atomic::Ordering::SeqCst)
                || super::omits_time_breakdown(conn, &row.session_id);
            let mut summary = hub.session_change_summary(&s, row.seq, lean);
            if lean {
                super::requests::without_time_breakdown(&mut summary);
            }
            built = Some((&row.session_id, summary));
        }
        let Some((_, summary)) = &built else { continue };
        conn.send_row(
            &Message::notification(
                method::MUX_SESSION_CHANGED,
                json!({"sessionId": row.session_id, "session": summary, "kind": row.kind, "recordKind": row.kind, "seq": row.seq, "listSeq": row.list_seq}),
            ),
            outbound::Row::None,
        );
    }
}
