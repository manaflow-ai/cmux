//! Receives a pump may still ask about after this daemon restarts
//! (cx-rppd.7). A pump that lost a finish answer settles the move with a
//! receive-abort of the receive: acpmux forgets the move (its
//! `forgot-<transferId>` mark, kept on disk, refuses a late finish) and
//! answers whether the chat landed. That needs the move and chat ids of the
//! receive's own manifest, which the live and settled receives keep in
//! memory only; without this record a restarted daemon answered
//! `unknown_receive` and the move stayed unresolved, the chat frozen on the
//! source.
//!
//! Each receive acpmux answered here is recorded with those ids (never a
//! client's: they come from the manifest this daemon forwarded and acpmux
//! took): the 40 most recent receives acpmux answered here (aborted ones
//! included), each for 24 h, in [`ASKABLE_FILE`] next to the session's registry, trusted only as
//! this daemon writes it (`state_file.rs`). Only a receive-abort reads it,
//! and only for a receive this daemon no longer holds in memory; a write or
//! finish of such a receive stays refused. An in-memory session keeps them
//! in memory only.

use cmux_threads::sync::Mutex;
use std::path::Path;

use serde::{Deserialize, Serialize};

use super::state_file::{self, now_ms, read_trusted, save};
use super::{MAX_CALLS, MAX_RECEIVES, MAX_SETTLED, Moved, is_plain_id, lock};
use crate::mux::Mux;

/// The askable receives file in the session state directory.
pub(super) const ASKABLE_FILE: &str = "agent-transfer-receives.json";
/// Receives remembered (the oldest goes first): every live and settled one,
/// and the calls that may be making more.
const MAX_ASKABLE: usize = MAX_RECEIVES + MAX_SETTLED + MAX_CALLS;

#[derive(Clone, Serialize, Deserialize)]
struct AskableReceive {
    receive: String,
    transfer: String,
    session: String,
    at_ms: u64,
}

impl AskableReceive {
    fn well_formed(&self) -> bool {
        is_plain_id(&self.receive) && is_plain_id(&self.transfer) && is_plain_id(&self.session)
    }

    fn fresh(&self, now: u64) -> bool {
        state_file::fresh(self.at_ms, now)
    }
}

/// The askable receives, read from the file on first use (`None` until then).
#[derive(Default)]
pub(super) struct Askable {
    receives: Mutex<Option<Vec<AskableReceive>>>,
}

/// The file's fresh, well formed records, oldest first; none when it is
/// missing, too large, damaged or not this daemon's own file.
fn load(directory: Option<&Path>) -> Vec<AskableReceive> {
    let Some(path) = directory.map(|directory| directory.join(ASKABLE_FILE)) else {
        return Vec::new();
    };
    let receives: Vec<AskableReceive> = read_trusted(&path)
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default();
    let now = now_ms();
    let mut receives: Vec<_> =
        receives.into_iter().filter(|r| r.well_formed() && r.fresh(now)).collect();
    let extra = receives.len().saturating_sub(MAX_ASKABLE);
    receives.drain(..extra);
    receives
}

impl Mux {
    /// Records receive `receive_id` of `moved` (acpmux answered it here).
    pub(super) fn remember_askable_receive(&self, receive_id: &str, moved: &Moved) {
        let record = AskableReceive {
            receive: receive_id.to_owned(),
            transfer: moved.transfer_id.clone(),
            session: moved.session_id.clone(),
            at_ms: now_ms(),
        };
        if !record.well_formed() {
            return;
        }
        let directory = self.session_state_directory();
        let mut receives = lock(&self.agent_transfers.askable.receives);
        let receives = receives.get_or_insert_with(|| load(directory.as_deref()));
        let now = record.at_ms;
        receives.retain(|r| r.receive != record.receive && r.fresh(now));
        let extra = (receives.len() + 1).saturating_sub(MAX_ASKABLE);
        receives.drain(..extra);
        receives.push(record);
        if let Some(directory) = directory
            && let Err(error) = save(&directory, ASKABLE_FILE, receives)
        {
            // Still askable for this daemon's life; only a restart forgets it.
            eprintln!("cmux-tui: chat move receive record not written: {error}");
        }
    }

    /// The move and chat of receive `receive_id`, when this daemon recorded
    /// it (within the last 24 h, the 40 most recent).
    pub(super) fn askable_receive(&self, receive_id: &str) -> Option<Moved> {
        let directory = self.session_state_directory();
        let mut receives = lock(&self.agent_transfers.askable.receives);
        let receives = receives.get_or_insert_with(|| load(directory.as_deref()));
        let now = now_ms();
        let record = receives.iter().rev().find(|r| r.receive == receive_id && r.fresh(now))?;
        Some(Moved { transfer_id: record.transfer.clone(), session_id: record.session.clone() })
    }
}
