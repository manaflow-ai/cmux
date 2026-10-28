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
//! - a connection that echoed [`CAPABILITY`] (`placement-shift-v1`: it does
//!   not order by `workspace_placement.index`, for example because it reads
//!   the order from the sidebar document) gets the changes as stored, with
//!   no restatement;
//! - any other connection gets the placements in the shifted range appended
//!   to the batch, read from the current state.
//!
//! Current state, not the state at the batch's revision: a later write
//! that changes a row again sends that row again in its own batch, so a
//! reader that applies the batches in order ends at the current order.
//! Exception (as before this module): `forget-session` deletes a machine's
//! rows outside any resource batch and sends no placement change, so the
//! rows after them keep their old index until a later shift restates them.

use crate::panic_free::JsonFields;
use rusqlite::{Connection, Transaction};
use serde_json::{Value, json};

/// Advertised in `identify`; a connection that echoes it in
/// `set-client-info` or `client.metadata.update` gets no placement
/// restatement. `sidebar-doc-v1` alone does not change placement delivery.
pub const CAPABILITY: &str = "placement-shift-v1";

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

/// What the current placements depend on: the resource revision, the
/// personal revision and the connection's write count (so a write that
/// advances neither revision still reads fresh placements). Equal keys
/// read equal placements.
#[track_caller]
pub(crate) fn state_key(connection: &Connection) -> anyhow::Result<(u64, u64, u64)> {
    let resource = connection.query_row(
        "SELECT value FROM meta WHERE key = 'resource_revision'",
        [],
        |row| row.get::<_, String>(0),
    )?;
    let personal = crate::workspace_registry::personal_store::personal_revision(connection)?;
    Ok((resource.parse()?, personal, connection.total_changes()))
}

/// Every current placement as its `workspace_placement` upsert, in order.
pub(crate) fn all_changes(connection: &Connection) -> anyhow::Result<Vec<Value>> {
    Ok(super::personal_state_store::placement_snapshots(connection)?
        .into_iter()
        .map(super::personal::placement_change)
        .collect())
}

/// The upserts of `all` (from [`all_changes`]) that `shift` restates.
pub(crate) fn restatement(all: &[Value], shift: PlacementShift) -> Vec<Value> {
    let to = shift.to.unwrap_or(usize::MAX);
    all.iter()
        .filter(|change| {
            change
                .field("value")
                .field("index")
                .as_u64()
                .and_then(|index| usize::try_from(index).ok())
                .is_some_and(|index| shift.from <= index && index <= to)
        })
        .cloned()
        .collect()
}
