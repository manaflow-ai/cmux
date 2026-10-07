//! The closed-history record of a deleted personal workspace group
//! (RECOVERABLE-BY-DEFAULT) and its restore.
//!
//! Ungroup and Delete Group keep every workspace, so the record has no
//! member: it keeps the group's own row (a plain column map, written back
//! with the columns this build has), its place in the group order and its
//! members `{session_id, workspace_key}`. A restore gives the group its old
//! id and place, and puts back every member whose personal row still exists
//! and that no later change put in another group.

use rusqlite::{Connection, Transaction, params};
use serde_json::{Value, json};

use super::super::personal_store::{
    DEFAULT_PROFILE_ID, commit_personal, read_group, read_groups, read_profile, subject,
    write_order,
};
use super::room_archive::{insert_rows, reinsert, rows};

/// The record of `group` before its delete: its row, its place in the
/// group order and its members in personal order.
pub(crate) fn snapshot_group(connection: &Connection, group: &str) -> anyhow::Result<Value> {
    let index = read_groups(connection)?.iter().position(|candidate| candidate.id == group);
    let members = rows(
        connection,
        "personal_workspaces",
        "group_id = ?1 ORDER BY position ASC, session_id ASC, workspace_key ASC",
        &[&group],
    )?
    .into_iter()
    .map(|row| json!({"session_id": row["session_id"], "workspace_key": row["workspace_key"]}))
    .collect::<Vec<_>>();
    Ok(json!({
        "id": group,
        "index": index,
        "row": rows(connection, "personal_groups", "group_id = ?1", &[&group])?,
        "members": members,
    }))
}

/// The public summary of a group record (`ClosedItemSnapshot.group`).
pub(crate) fn public_group(archive: &Value) -> Value {
    let row = &archive["row"][0];
    json!({"id": archive["id"], "name": row["name"], "color": row["color"]})
}

/// Restore the group of `archive` when it is gone. Members of `session`
/// closed and reopened in the same reopen are found by their new key
/// (`placements`: closed key, reopened key). Returns whether personal rows
/// changed.
pub(crate) fn restore_group(
    transaction: &Transaction<'_>,
    archive: &Value,
    session: &str,
    placements: &[(String, String)],
) -> anyhow::Result<bool> {
    let group = archive["id"].as_str().unwrap_or_default();
    anyhow::ensure!(!group.is_empty(), "the closed group has no id");
    if read_group(transaction, group)?.is_some() {
        return Ok(false);
    }
    let empty = Vec::new();
    let row = archive["row"].as_array().unwrap_or(&empty);
    anyhow::ensure!(!row.is_empty(), "the closed group {group} has no row");
    insert_rows(transaction, "personal_groups", row)?;
    // A group of a room deleted since then shows in the default room.
    let room = row[0]["profile_id"].as_str().unwrap_or(DEFAULT_PROFILE_ID);
    if read_profile(transaction, room)?.is_none() {
        transaction.execute(
            "UPDATE personal_groups SET profile_id = ?2 WHERE group_id = ?1",
            params![group, DEFAULT_PROFILE_ID],
        )?;
    }
    let order = read_groups(transaction)?.into_iter().map(|group| group.id).collect();
    let order = reinsert(order, &[(group.to_string(), archive["index"].as_u64())]);
    write_order(transaction, "personal_groups", "group_id", &order)?;
    for member in archive["members"].as_array().unwrap_or(&empty) {
        let (Some(member_session), Some(key)) =
            (member["session_id"].as_str(), member["workspace_key"].as_str())
        else {
            continue;
        };
        let key = placements
            .iter()
            .find(|(closed, _)| member_session == session && closed == key)
            .map_or(key, |(_, reopened)| reopened.as_str());
        transaction.execute(
            "UPDATE personal_workspaces SET group_id = ?3
             WHERE session_id = ?1 AND workspace_key = ?2 AND group_id IS NULL",
            params![member_session, key, group],
        )?;
    }
    commit_personal(
        transaction,
        "personal.group.restored",
        vec![subject("personal_group", group)],
        &json!({"group_id": group}),
    )?;
    Ok(true)
}
