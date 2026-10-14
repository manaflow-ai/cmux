//! Moving one personal workspace row without renumbering the others.
//!
//! The personal order is `ORDER BY position, session_id, workspace_key`
//! and every reader uses only that order (`index` is the row's ordinal), so
//! positions may have gaps. A move gives the row a position between its new
//! neighbors; only when no integer fits between them (repeated inserts at
//! one place, or the dense positions an older binary wrote) does the whole
//! list get evenly spaced positions again, in one statement.
//!
//! Every lookup here is a range scan of the order index
//! `personal_workspaces_order (position, session_id, workspace_key)`, made
//! at open with the sidebar document's triggers.
//!
//! Group slots (`personal_groups.top_position`, `personal-mixed-order-v1`)
//! are positions too: a group shows right before the first row at or after
//! its slot. A move keeps the old rule: groups that were right before the
//! moved row now sit right before the row that followed it, and the moved
//! row lands before the groups at its new place.

use rusqlite::{OptionalExtension, Transaction, params};

use super::mixed_order;

/// The space between two rows after a renumbering, and after the last row
/// for a new one.
pub(crate) const GAP: i64 = 1 << 16;
/// The position of the first row after a renumbering (and of the first row
/// of an empty list): room for 2^24 moves to the top before the next one.
pub(crate) const FIRST: i64 = 1 << 40;

/// `(position, session_id, workspace_key)`: one row's place in the order.
type Place = (i64, String, String);

fn place_of(tx: &Transaction<'_>, session: &str, key: &str) -> anyhow::Result<Option<i64>> {
    Ok(tx
        .query_row(
            "SELECT position FROM personal_workspaces WHERE session_id = ?1 AND workspace_key = ?2",
            params![session, key],
            |row| row.get(0),
        )
        .optional()?)
}

fn read_place(row: &rusqlite::Row<'_>) -> rusqlite::Result<Place> {
    Ok((row.get(0)?, row.get(1)?, row.get(2)?))
}

/// The rows at ordinal `index - 1` and `index` among the rows other than
/// `(session, key)`.
fn neighbors_at(
    tx: &Transaction<'_>,
    session: &str,
    key: &str,
    index: usize,
) -> anyhow::Result<(Option<Place>, Option<Place>)> {
    let mut statement = tx.prepare(
        "SELECT position, session_id, workspace_key FROM personal_workspaces
         WHERE NOT (session_id = ?1 AND workspace_key = ?2)
         ORDER BY position, session_id, workspace_key LIMIT ?3 OFFSET ?4",
    )?;
    let (limit, offset) = match index.checked_sub(1) {
        Some(before) => (2_i64, i64::try_from(before)?),
        None => (1, 0),
    };
    let rows: Vec<Place> = statement
        .query_map(params![session, key, limit, offset], read_place)?
        .collect::<Result<_, _>>()?;
    Ok(match index {
        0 => (None, rows.into_iter().next()),
        _ => {
            let mut rows = rows.into_iter();
            let low = rows.next();
            let high = rows.next();
            if low.is_none() {
                // Past the end: after the last row.
                (last_other(tx, session, key)?, None)
            } else {
                (low, high)
            }
        }
    })
}

fn last_other(tx: &Transaction<'_>, session: &str, key: &str) -> anyhow::Result<Option<Place>> {
    Ok(tx
        .prepare(
            "SELECT position, session_id, workspace_key FROM personal_workspaces
             WHERE NOT (session_id = ?1 AND workspace_key = ?2)
             ORDER BY position DESC, session_id DESC, workspace_key DESC LIMIT 1",
        )?
        .query_row(params![session, key], read_place)
        .optional()?)
}

/// The first row after `place` (from the start: None) other than
/// `(session, key)`. Each form is a range scan of the order index
/// (`personal_workspaces_order`).
fn next_other(
    tx: &Transaction<'_>,
    session: &str,
    key: &str,
    place: Option<&Place>,
) -> anyhow::Result<Option<Place>> {
    Ok(match place {
        Some((position, after_session, after_key)) => tx
            .prepare(
                "SELECT position, session_id, workspace_key FROM personal_workspaces
                 WHERE (position, session_id, workspace_key) > (?3, ?4, ?5)
                   AND NOT (session_id = ?1 AND workspace_key = ?2)
                 ORDER BY position, session_id, workspace_key LIMIT 1",
            )?
            .query_row(params![session, key, position, after_session, after_key], read_place)
            .optional()?,
        None => tx
            .prepare(
                "SELECT position, session_id, workspace_key FROM personal_workspaces
                 WHERE NOT (session_id = ?1 AND workspace_key = ?2)
                 ORDER BY position, session_id, workspace_key LIMIT 1",
            )?
            .query_row(params![session, key], read_place)
            .optional()?,
    })
}

/// Move the row `(session, key)` to ordinal `index` among the other rows
/// (past the end: last).
pub(crate) fn move_to_index(
    tx: &Transaction<'_>,
    session: &str,
    key: &str,
    index: usize,
) -> anyhow::Result<()> {
    let (low, high) = neighbors_at(tx, session, key, index)?;
    move_between(tx, session, key, low, high)
}

/// Move the row `(session, key)` right after the row `after` (None: first).
pub(crate) fn move_after(
    tx: &Transaction<'_>,
    session: &str,
    key: &str,
    after: Option<(&str, &str)>,
) -> anyhow::Result<()> {
    let low = match after {
        Some((s, k)) => {
            let position = place_of(tx, s, k)?
                .ok_or_else(|| anyhow::anyhow!("no personal row for {s}/{k}"))?;
            Some((position, s.to_string(), k.to_string()))
        }
        None => None,
    };
    let high = next_other(tx, session, key, low.as_ref())?;
    move_between(tx, session, key, low, high)
}

fn move_between(
    tx: &Transaction<'_>,
    session: &str,
    key: &str,
    low: Option<Place>,
    high: Option<Place>,
) -> anyhow::Result<()> {
    let old = place_of(tx, session, key)?
        .ok_or_else(|| anyhow::anyhow!("no personal row for {session}/{key}"))?;
    let new = match (&low, &high) {
        (None, None) => Some(FIRST),
        (Some((low, ..)), None) => low.checked_add(GAP),
        // Positions are never negative (a CHECK in the schema).
        (None, Some((high, ..))) if *high >= GAP => Some(high - GAP),
        (None, Some((high, ..))) => (*high >= 1).then_some(high / 2),
        (Some((low, ..)), Some((high, ..))) => {
            (high.saturating_sub(*low) >= 2).then(|| low + (high - low) / 2)
        }
    };
    let Some(new) = new else {
        // No integer fits: space every row out, then place again.
        respace(tx)?;
        let low = match &low {
            Some((_, s, k)) => place_of(tx, s, k)?.map(|p| (p, s.clone(), k.clone())),
            None => None,
        };
        let high = next_other(tx, session, key, low.as_ref())?;
        let new = match (&low, &high) {
            (Some((low, ..)), Some((high, ..))) => low + (high - low) / 2,
            (Some((low, ..)), None) => low + GAP,
            (None, Some((high, ..))) => (high - GAP).max(0),
            (None, None) => FIRST,
        };
        let old = place_of(tx, session, key)?.unwrap_or(old);
        return finish_move(tx, session, key, old, new, low, high);
    };
    finish_move(tx, session, key, old, new, low, high)
}

fn finish_move(
    tx: &Transaction<'_>,
    session: &str,
    key: &str,
    old: i64,
    new: i64,
    low: Option<Place>,
    high: Option<Place>,
) -> anyhow::Result<()> {
    // Groups right before the moved row stay right before the row that
    // followed it (or at the end).
    let follower = next_other(tx, session, key, Some(&(old, session.into(), key.into())))?;
    let end = end_slot(tx, session, key, new)?;
    tx.prepare("UPDATE personal_groups SET top_position = ?2 WHERE top_position = ?1")?
        .execute(params![old, follower.as_ref().map_or(end, |(p, ..)| *p)])?;
    tx.prepare(
        "UPDATE personal_workspaces SET position = ?3 WHERE session_id = ?1 AND workspace_key = ?2",
    )?
    .execute(params![session, key, new])?;
    // The moved row lands before the groups at its new place.
    let floor = low.as_ref().map_or(i64::MIN, |(p, ..)| *p);
    let slot = high.as_ref().map_or(new + 1, |(p, ..)| *p);
    tx.prepare(
        "UPDATE personal_groups SET top_position = ?3
         WHERE top_position > ?1 AND top_position <= ?2",
    )?
    .execute(params![floor, new, slot])?;
    crate::state::sidebar_doc_sync::mark_moved(tx, session, key)?;
    Ok(())
}

/// The slot after every row once the moved row sits at `new`.
fn end_slot(tx: &Transaction<'_>, session: &str, key: &str, new: i64) -> anyhow::Result<i64> {
    let last = last_other(tx, session, key)?.map_or(i64::MIN, |(p, ..)| p);
    Ok(last.max(new).saturating_add(1))
}

/// Evenly spaced positions for every row from [`FIRST`], in the current
/// order (one statement), with each group kept at its slot among the rows.
fn respace(tx: &Transaction<'_>) -> anyhow::Result<()> {
    let slots = mixed_order::group_slots(tx, None)?;
    tx.execute(
        "UPDATE personal_workspaces SET position = ?2 + (spaced.rank - 1) * ?1
         FROM (SELECT session_id, workspace_key,
                      ROW_NUMBER() OVER (ORDER BY position, session_id, workspace_key) AS rank
               FROM personal_workspaces) AS spaced
         WHERE spaced.session_id = personal_workspaces.session_id
           AND spaced.workspace_key = personal_workspaces.workspace_key",
        params![GAP, FIRST],
    )?;
    mixed_order::restore_group_slots(tx, &slots, None)
}
