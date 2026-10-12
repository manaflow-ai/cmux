//! The closed-history record of a deleted room (SPACE-DELETE-CLOSES-ITS-
//! WORKSPACES, RECOVERABLE-BY-DEFAULT) and its restore.
//!
//! The record keeps the room's own rows (the room, its follows, its groups,
//! its pins and the group of every workspace in those groups) as plain
//! column maps, so a restore writes them back with the columns this build
//! has, whatever build recorded them. A restore gives the room its old id
//! and its old place in the room order, and moves the pins and group of
//! each reopened workspace from its closed key to its new key.

use rusqlite::types::{Value as SqlValue, ValueRef};
use rusqlite::{Connection, ToSql, Transaction, params};
use serde_json::{Value, json};

use super::super::personal_store::{
    DEFAULT_PROFILE_ID, bump_personal_revision, commit_personal, read_groups, read_profile,
    read_profiles, subject, write_order,
};

/// The rooms that show workspace `key` of `session` (data-model.md 3.2, the
/// rule of the app's `RoomMembership`): its pin, else every room that
/// follows its session, else `default`.
fn rooms_of(connection: &Connection, session: &str, key: &str) -> anyhow::Result<Vec<String>> {
    let pinned = connection
        .prepare(
            "SELECT profile_id FROM profile_pins WHERE session_id = ?1 AND workspace_key = ?2",
        )?
        .query_map(params![session, key], |row| row.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    if !pinned.is_empty() {
        return Ok(pinned);
    }
    let followers = connection
        .prepare("SELECT profile_id FROM profile_follows WHERE session_id = ?1")?
        .query_map([session], |row| row.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(if followers.is_empty() { vec![DEFAULT_PROFILE_ID.to_string()] } else { followers })
}

/// The workspaces of `keys` (of `session`) that only `room` shows: the ones
/// a delete of `room` closes. A workspace another room also shows stays.
pub(crate) fn closing_keys(
    connection: &Connection,
    room: &str,
    session: &str,
    keys: &[String],
) -> anyhow::Result<Vec<String>> {
    let mut closing = Vec::new();
    for key in keys {
        if rooms_of(connection, session, key)? == [room] {
            closing.push(key.clone());
        }
    }
    Ok(closing)
}

/// The rows of `table` that `filter` selects, as column maps.
pub(super) fn rows(
    connection: &Connection,
    table: &str,
    filter: &str,
    args: &[&dyn ToSql],
) -> anyhow::Result<Vec<Value>> {
    let mut statement = connection.prepare(&format!("SELECT * FROM {table} WHERE {filter}"))?;
    let columns = statement.column_names().into_iter().map(str::to_string).collect::<Vec<_>>();
    let rows = statement.query_map(args, |row| {
        let mut map = serde_json::Map::new();
        for (index, column) in columns.iter().enumerate() {
            let value = match row.get_ref(index)? {
                ValueRef::Null | ValueRef::Blob(_) => Value::Null,
                ValueRef::Integer(value) => json!(value),
                ValueRef::Real(value) => json!(value),
                ValueRef::Text(value) => json!(String::from_utf8_lossy(value)),
            };
            map.insert(column.clone(), value);
        }
        Ok(Value::Object(map))
    })?;
    Ok(rows.collect::<Result<Vec<_>, _>>()?)
}

/// Write `rows` (column maps) into `table`, keeping only the columns the
/// table has now. A row whose key exists is left as it is.
pub(super) fn insert_rows(
    transaction: &Transaction<'_>,
    table: &str,
    rows: &[Value],
) -> anyhow::Result<()> {
    let present = transaction
        .prepare(&format!("PRAGMA table_info({table})"))?
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<Vec<_>, _>>()?;
    for row in rows {
        let Some(map) = row.as_object() else { continue };
        let (columns, values): (Vec<&String>, Vec<SqlValue>) = map
            .iter()
            .filter(|(column, _)| present.contains(column))
            .map(|(column, value)| {
                let value = match value {
                    Value::Null => SqlValue::Null,
                    Value::Bool(value) => SqlValue::Integer(i64::from(*value)),
                    Value::Number(number) => match number.as_i64() {
                        Some(value) => SqlValue::Integer(value),
                        None => SqlValue::Real(number.as_f64().unwrap_or_default()),
                    },
                    Value::String(text) => SqlValue::Text(text.clone()),
                    other => SqlValue::Text(other.to_string()),
                };
                (column, value)
            })
            .unzip();
        if columns.is_empty() {
            continue;
        }
        let names = columns.iter().map(|column| column.as_str()).collect::<Vec<_>>().join(", ");
        let slots = (1..=columns.len()).map(|index| format!("?{index}")).collect::<Vec<_>>();
        transaction.execute(
            &format!("INSERT OR IGNORE INTO {table}({names}) VALUES({})", slots.join(", ")),
            rusqlite::params_from_iter(values),
        )?;
    }
    Ok(())
}

/// The record of `room` before its delete: its rows, its place in the room
/// order and the place of each of its groups in the group order.
pub(crate) fn snapshot_room(connection: &Connection, room: &str) -> anyhow::Result<Value> {
    let index = read_profiles(connection)?.iter().position(|profile| profile.id == room);
    let order = read_groups(connection)?.into_iter().map(|group| group.id).collect::<Vec<_>>();
    let groups =
        rows(connection, "personal_groups", "profile_id = ?1 ORDER BY position", &[&room])?;
    let group_indexes = groups
        .iter()
        .map(|group| order.iter().position(|id| group["group_id"] == id.as_str()))
        .collect::<Vec<_>>();
    Ok(json!({
        "id": room,
        "index": index,
        "profile": rows(connection, "profiles", "profile_id = ?1", &[&room])?,
        "follows": rows(connection, "profile_follows", "profile_id = ?1", &[&room])?,
        "groups": groups,
        "group_indexes": group_indexes,
        "pins": rows(connection, "profile_pins", "profile_id = ?1", &[&room])?,
        "grouped": rows(
            connection,
            "personal_workspaces",
            "group_id IN (SELECT group_id FROM personal_groups WHERE profile_id = ?1)",
            &[&room],
        )?
        .into_iter()
        .map(|row| json!({
            "session_id": row["session_id"],
            "workspace_key": row["workspace_key"],
            "group_id": row["group_id"],
        }))
        .collect::<Vec<_>>(),
    }))
}

/// Put `ids` into `order` at their recorded indexes (ascending, clamped).
pub(super) fn reinsert(mut order: Vec<String>, ids: &[(String, Option<u64>)]) -> Vec<String> {
    let mut placed = ids.to_vec();
    placed.sort_by_key(|(_, index)| index.unwrap_or(u64::MAX));
    for (id, index) in placed {
        order.retain(|candidate| candidate != &id);
        let at = index.and_then(|index| usize::try_from(index).ok()).unwrap_or(order.len());
        order.insert(at.min(order.len()), id);
    }
    order
}

/// Restore the room of `archive` when it is gone, then move the pins and
/// group of each reopened workspace (`placements`: closed key, new key, of
/// session `local`) to its new key. Returns whether personal rows changed.
pub(crate) fn restore_room(
    transaction: &Transaction<'_>,
    archive: &Value,
    local: &str,
    placements: &[(String, String)],
) -> anyhow::Result<bool> {
    let room = archive["id"].as_str().unwrap_or_default();
    anyhow::ensure!(!room.is_empty(), "the closed space has no id");
    let restored = read_profile(transaction, room)?.is_none();
    let empty = Vec::new();
    let list = |field: &str| archive[field].as_array().unwrap_or(&empty).clone();
    if restored {
        insert_rows(transaction, "profiles", &list("profile"))?;
        let order = read_profiles(transaction)?.into_iter().map(|profile| profile.id).collect();
        let order = reinsert(order, &[(room.to_string(), archive["index"].as_u64())]);
        write_order(transaction, "profiles", "profile_id", &order)?;
        insert_rows(transaction, "profile_follows", &list("follows"))?;
        insert_rows(transaction, "personal_groups", &list("groups"))?;
        let groups = list("groups")
            .iter()
            .zip(list("group_indexes"))
            .filter_map(|(group, index)| {
                Some((group["group_id"].as_str()?.to_string(), index.as_u64()))
            })
            .collect::<Vec<_>>();
        let order = read_groups(transaction)?.into_iter().map(|group| group.id).collect();
        write_order(transaction, "personal_groups", "group_id", &reinsert(order, &groups))?;
        insert_rows(transaction, "profile_pins", &list("pins"))?;
        for row in list("grouped") {
            transaction.execute(
                "UPDATE personal_workspaces SET group_id = ?3
                 WHERE session_id = ?1 AND workspace_key = ?2 AND group_id IS NULL",
                params![
                    row["session_id"].as_str(),
                    row["workspace_key"].as_str(),
                    row["group_id"].as_str()
                ],
            )?;
        }
        commit_personal(
            transaction,
            "personal.profile.restored",
            vec![subject("profile", room)],
            &json!({"profile_id": room}),
        )?;
    }
    let mut rekeyed = 0;
    for (closed, reopened) in placements {
        rekeyed += transaction.execute(
            "UPDATE OR IGNORE profile_pins SET workspace_key = ?3
             WHERE session_id = ?1 AND workspace_key = ?2 AND profile_id = ?4",
            params![local, closed, reopened, room],
        )?;
    }
    if rekeyed > 0 && !restored {
        bump_personal_revision(transaction)?;
    }
    Ok(restored || rekeyed > 0)
}
