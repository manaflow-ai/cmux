//! Placement shifts: a personal order write that moves other rows only by
//! their ordinal (a new workspace at the top, a row moved across others)
//! does not restate those rows in its commit.
//!
//! `workspace_placement.index` is an ordinal, so one insert at the top
//! changes the index of every row after it: at 2000 workspaces the old
//! commit restated 2000 placements in the journal and on every
//! `session.events` stream. The commit now names only the changed rows and
//! records the ordinal range that shifted (`placement_shift` in the journal
//! record's payload, next to `changes`). When a delta batch goes out:
//! - a connection that echoed `sidebar-doc-v1` (it reads the order from the
//!   sidebar document) gets the changes as stored, with no restatement;
//! - any other connection gets the placements in the shifted range appended
//!   to the batch, read from the current state.
//!
//! Current state, not the state at the batch's revision: a later write
//! that changes a row again sends that row again in its own batch, so a
//! reader that applies the batches in order ends at the current order.

use rusqlite::{Connection, Transaction};
use serde_json::{Value, json};

/// The journal payload key, and the key of a queued marker in
/// `state_pending_changes`.
pub(crate) const PAYLOAD_KEY: &str = "placement_shift";

/// The placements whose ordinal moved: `from_index` through `to_index`
/// (absent: through the last placement).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct PlacementShift {
    pub(crate) from: usize,
    pub(crate) to: Option<usize>,
}

impl PlacementShift {
    fn union(self, other: Self) -> Self {
        let to = match (self.to, other.to) {
            (Some(a), Some(b)) => Some(a.max(b)),
            _ => None,
        };
        Self { from: self.from.min(other.from), to }
    }

    pub(crate) fn to_value(self) -> Value {
        json!({"from_index": self.from, "to_index": self.to})
    }

    pub(crate) fn from_value(value: &Value) -> Option<Self> {
        let from = usize::try_from(value.get("from_index")?.as_u64()?).ok()?;
        let to = match value.get("to_index") {
            None | Some(Value::Null) => None,
            Some(to) => Some(usize::try_from(to.as_u64()?).ok()?),
        };
        Some(Self { from, to })
    }
}

/// Record, in the current journaled commit, that the placements from
/// `from` through `to` (None: the end) moved by ordinal only. The changed
/// rows themselves are queued as changes by the caller.
pub(crate) fn queue(
    transaction: &Transaction<'_>,
    from: usize,
    to: Option<usize>,
) -> anyhow::Result<()> {
    super::closed_history_store::queue_change(
        transaction,
        &json!({ PAYLOAD_KEY: PlacementShift { from, to }.to_value() }),
    )
}

/// The shift a queued `state_pending_changes` value carries, if it is a
/// marker (a change always has a `kind`).
pub(crate) fn marker(value: &Value) -> Option<PlacementShift> {
    if value.get("kind").is_some() {
        return None;
    }
    PlacementShift::from_value(value.get(PAYLOAD_KEY)?)
}

/// Fold one more marker into the commit's shift.
pub(crate) fn merge(shift: &mut Option<PlacementShift>, more: PlacementShift) {
    *shift = Some(shift.map_or(more, |shift| shift.union(more)));
}

/// The `workspace_placement` upserts a connection without `sidebar-doc-v1`
/// gets for `shift`, from the current state.
pub(crate) fn restatement(
    connection: &Connection,
    shift: PlacementShift,
) -> anyhow::Result<Vec<Value>> {
    let range = shift.from..=shift.to.unwrap_or(usize::MAX);
    Ok(super::personal_state_store::placements_in(connection, range)?
        .into_iter()
        .map(super::personal::placement_change)
        .collect())
}
