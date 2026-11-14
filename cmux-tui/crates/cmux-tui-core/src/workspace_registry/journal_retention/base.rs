//! The base of a reducer on a registry with a retention floor.
//!
//! After retention deleted records, the saved state of a reducer
//! (`journal_reducer.<id>` in `meta`) was the only copy of what it folded
//! below the floor. That key is the one every build writes. A build from
//! before 2026-11-09 does not decode the sealed segments, folds an empty
//! agent roster and saves it there; a state that does not load is folded
//! again from the first RETAINED record and saved there. Each time the
//! agents and sessions with no later record were gone for good.
//!
//! So the transaction that moves the floor (the delete of a segment in
//! place, the swap of a rebuilt registry) first copies the saved state of
//! each reducer that holds the floor to a second key,
//! `journal_reducer_base.<id>`. No build before this one writes that key.
//! The rule of the copy:
//!
//! - From a state of this build's reducer version, with no rebuild owed
//!   (`journal_reducer_rebuild.<id>`), and a cursor at or above the new
//!   floor: the reducer's own fold of every record through its cursor.
//! - Only when the base is absent, is not of this version, or has a cursor
//!   below the new floor. The floor stays the minimum window behind the
//!   head (one hour of segments), and the copied cursor is near the head:
//!   about one copy for each hour of work.
//! - A floor that would move without such a base for each reducer does not
//!   move: the delete or the swap is refused.
//!
//! So a base, where the floor is above 0, always holds the fold through a
//! cursor at or above the floor, and every record after that cursor is in
//! the journal. A reader that cannot use its saved state as its own fold
//! (another version, a rebuild owed, a value that does not load) starts
//! from the base and folds the records after the base's cursor: the agent
//! roster in `mux/agent_roster_restore.rs` and `mux/agent_roster_rebuild.rs`,
//! the agent history in `history_ops/merged.rs`.
//!
//! Cost: the two saved states are in `meta` two times.

use rusqlite::{Connection, OptionalExtension, params};
use serde_json::Value;

use super::super::WorkspaceRegistry;
use crate::history_ops::{AGENT_FOLD_STATE_ID, AGENT_FOLD_STATE_VERSION};
use crate::journal_reducers::{AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION};

/// The `meta` key prefix of a reducer's base.
const REDUCER_BASE_PREFIX: &str = "journal_reducer_base.";

/// The reducers whose saved state holds what the journal no longer has
/// below the floor, each with this build's version (the same two that
/// `retention_limit` reads).
pub(super) const FLOOR_REDUCERS: [(&str, u32); 2] = [
    (AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION),
    (AGENT_FOLD_STATE_ID, AGENT_FOLD_STATE_VERSION),
];

/// SQL, true when the `meta` value in `column` is a saved state with a
/// cursor at or above the parameter `floor`. `CASE` gives the order:
/// `json_extract` fails on a value that is not JSON.
fn at_or_above(column: &str, floor: &str) -> String {
    format!(
        "CASE WHEN json_valid({column})
           THEN CAST(json_extract({column}, '$.cursor') AS INTEGER) >= {floor} ELSE 0 END"
    )
}

/// SQL, true when the `meta` value in `column` is a saved state of the
/// reducer version `?3` with a cursor at or above `?4`.
fn own_at_or_above(column: &str) -> String {
    format!(
        "CASE WHEN json_valid({column})
           THEN json_extract({column}, '$.version') = ?3
            AND CAST(json_extract({column}, '$.cursor') AS INTEGER) >= ?4 ELSE 0 END"
    )
}

fn keys(reducer: &str) -> (String, String, String) {
    (
        format!("{REDUCER_BASE_PREFIX}{reducer}"),
        format!("journal_reducer.{reducer}"),
        format!("journal_reducer_rebuild.{reducer}"),
    )
}

/// Before the floor of the registry in `schema` moves to `floor`: copies
/// each reducer's saved state to its base where the rule of this module
/// asks for it. True when each reducer then has a base with a cursor at or
/// above `floor`; on false the caller must not delete a record. Call in the
/// transaction that moves the floor.
pub(crate) fn save_reducer_bases(
    connection: &Connection,
    schema: &str,
    floor: u64,
) -> anyhow::Result<bool> {
    let floor = i64::try_from(floor)?;
    let mut every = true;
    for (reducer, version) in FLOOR_REDUCERS {
        let (base_key, state_key, rebuild_key) = keys(reducer);
        // The base in place (`meta.value` in the conflict clause) stays
        // when it is of this version and at or above the floor.
        let (own, in_place) = (own_at_or_above("value"), own_at_or_above("meta.value"));
        connection.execute(
            &format!(
                "INSERT INTO {schema}.meta(key, value)
                 SELECT ?1, value FROM {schema}.meta
                 WHERE key = ?2
                   AND {own}
                   AND NOT EXISTS (SELECT 1 FROM {schema}.meta WHERE key = ?5)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value
                 WHERE NOT ({in_place})"
            ),
            params![base_key, state_key, i64::from(version), floor, rebuild_key],
        )?;
        let at_floor = at_or_above("value", "?2");
        let held: bool = connection.query_row(
            &format!("SELECT EXISTS(SELECT 1 FROM {schema}.meta WHERE key = ?1 AND {at_floor})"),
            params![base_key, floor],
            |row| row.get(0),
        )?;
        every &= held;
    }
    Ok(every)
}

/// True when [`save_reducer_bases`] at `floor` would leave each reducer of
/// the registry behind `connection` with a base at or above `floor`. It
/// writes nothing: the swap at open asks before it builds.
pub(crate) fn reducer_bases_possible(connection: &Connection, floor: u64) -> anyhow::Result<bool> {
    let floor = i64::try_from(floor)?;
    for (reducer, version) in FLOOR_REDUCERS {
        let (base_key, state_key, rebuild_key) = keys(reducer);
        let (at_floor, own) = (at_or_above("value", "?4"), own_at_or_above("value"));
        let possible: bool = connection.query_row(
            &format!(
                "SELECT EXISTS(SELECT 1 FROM meta WHERE key = ?1 AND {at_floor})
                     OR (EXISTS(SELECT 1 FROM meta WHERE key = ?2 AND {own})
                         AND NOT EXISTS (SELECT 1 FROM meta WHERE key = ?5))"
            ),
            params![base_key, state_key, i64::from(version), floor, rebuild_key],
            |row| row.get(0),
        )?;
        if !possible {
            return Ok(false);
        }
    }
    Ok(true)
}

/// The base of `reducer_id` as (version, cursor, snapshot); `None` when
/// there is none or its value is not a saved state.
fn reducer_base(
    connection: &Connection,
    reducer_id: &str,
) -> anyhow::Result<Option<(u32, u64, String)>> {
    let raw = connection
        .query_row(
            "SELECT value FROM meta WHERE key = ?1",
            [format!("{REDUCER_BASE_PREFIX}{reducer_id}")],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    let Some(value) = raw.and_then(|raw| serde_json::from_str::<Value>(&raw).ok()) else {
        return Ok(None);
    };
    let version = value
        .get("version")
        .and_then(Value::as_u64)
        .and_then(|version| u32::try_from(version).ok());
    let cursor =
        value.get("cursor").and_then(Value::as_str).and_then(|cursor| cursor.parse::<u64>().ok());
    let snapshot = value.get("snapshot").and_then(Value::as_str);
    Ok(match (version, cursor, snapshot) {
        (Some(version), Some(cursor), Some(snapshot)) => {
            Some((version, cursor, snapshot.to_owned()))
        }
        _ => None,
    })
}

/// The base of `reducer_id` when the registry behind `connection` has a
/// retention floor and the base can stand for the records below it: its
/// cursor is at or above what retention deleted through and not past the
/// journal head. `(version, cursor, snapshot)`; `None` on a registry with
/// no floor.
pub(crate) fn usable_reducer_base(
    connection: &Connection,
    reducer_id: &str,
) -> anyhow::Result<Option<(u32, u64, String)>> {
    let pruned_through = super::journal_pruned_through(connection)?;
    if pruned_through == 0 {
        return Ok(None);
    }
    let head = super::super::session_journal::query_journal_head(connection)?;
    Ok(reducer_base(connection, reducer_id)?
        .filter(|(_, cursor, _)| *cursor >= pruned_through && *cursor <= head))
}

impl WorkspaceRegistry {
    /// [`usable_reducer_base`] of this registry.
    pub(crate) fn journal_reducer_base(
        &self,
        reducer_id: &str,
    ) -> anyhow::Result<Option<(u32, u64, String)>> {
        usable_reducer_base(&self.connection.get(), reducer_id)
    }
}
