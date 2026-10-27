//! The v2 views of the home session's personal state (`profiles-v1`):
//! workspace groups, the personal workspace order (placements), and rooms.
//! Writes reuse the raw command bodies (`personal_mutations.rs`) inside the
//! state commit transaction, so each v2 mutation advances both the resource
//! revision and `personal_revision` atomically.
//!
//! Personal workspaces are session-qualified. A reference names the owning
//! session's registry id and an opaque workspace reference; the public
//! `workspace_id` is filled in for this session's live workspaces.

use rusqlite::{Connection, Transaction};
use serde_json::{Value, json};

use super::values::{local_registry_id, workspace_ref};
use crate::workspace_registry::WorkspaceRegistry;
use crate::workspace_registry::personal_mutations::{
    PersonalWorkspaceUpdate, ProfileDeletion, ProfileInput, ProfileUpdate,
};
use crate::workspace_registry::personal_store::{
    PersonalGroup, PersonalPin, PersonalProfile, PersonalWorkspace, read_group, read_groups,
    read_pins, read_profile, read_profiles, read_workspace, read_workspaces,
};

fn group_value(group: &PersonalGroup) -> Value {
    json!({
        "id": group.id,
        "room_id": group.profile,
        "name": group.name,
        "color": group.color,
        "collapsed": group.collapsed,
        "index": group.index,
        "top_index": group.top_index,
        "icon": group.icon,
        "pinned": group.pinned,
    })
}

pub(crate) fn workspace_group_snapshots(
    connection: &Connection,
    room: Option<&str>,
) -> anyhow::Result<Vec<Value>> {
    Ok(read_groups(connection)?
        .iter()
        .filter(|group| room.is_none_or(|room| group.profile == room))
        .map(group_value)
        .collect())
}

pub(crate) fn workspace_group_snapshot(
    connection: &Connection,
    id: &str,
) -> anyhow::Result<Option<Value>> {
    Ok(read_group(connection, id)?.as_ref().map(group_value))
}

fn room_value(
    connection: &Connection,
    local: &str,
    profile: &PersonalProfile,
) -> anyhow::Result<Value> {
    let pins = read_pins(connection)?
        .into_iter()
        .filter(|pin| pin.profile == profile.id)
        .map(|pin| workspace_ref(connection, local, &pin.session_id, &pin.workspace_key))
        .collect::<anyhow::Result<Vec<_>>>()?;
    Ok(json!({
        "id": profile.id,
        "name": profile.name,
        "color": profile.color,
        "icon": profile.icon,
        "theme": profile.theme,
        "index": profile.index,
        "browser_profile_id": profile.browser_profile_id,
        "default_session_id": profile.default_session_id,
        "follows": profile.follows,
        "pins": pins,
    }))
}

pub(crate) fn room_snapshots(connection: &Connection) -> anyhow::Result<Vec<Value>> {
    let local = local_registry_id(connection)?;
    read_profiles(connection)?
        .iter()
        .map(|profile| room_value(connection, &local, profile))
        .collect()
}

pub(crate) fn room_snapshot(connection: &Connection, id: &str) -> anyhow::Result<Option<Value>> {
    let local = local_registry_id(connection)?;
    read_profile(connection, id)?
        .map(|profile| room_value(connection, &local, &profile))
        .transpose()
}

fn placement_value(
    connection: &Connection,
    local: &str,
    row: &PersonalWorkspace,
    pins: &[PersonalPin],
) -> anyhow::Result<Value> {
    let room = pins
        .iter()
        .find(|pin| pin.session_id == row.session_id && pin.workspace_key == row.workspace_key)
        .map(|pin| pin.profile.clone());
    Ok(json!({
        "workspace": workspace_ref(connection, local, &row.session_id, &row.workspace_key)?,
        "index": row.index,
        "group_id": row.group,
        "room_id": room,
    }))
}

/// The id a placement change carries on `session.events`.
pub(crate) fn placement_id(session_id: &str, workspace_key: &str) -> String {
    format!("{session_id}/{workspace_key}")
}

/// Every placement in personal order. This session's live workspaces that
/// have no personal row yet follow, in registry order, ungrouped.
pub(crate) fn placement_snapshots(connection: &Connection) -> anyhow::Result<Vec<Value>> {
    placements_in(connection, 0..=usize::MAX)
}

/// The placements whose `index` is in `range` (the rows a move or an
/// insert shifted), built from one read of the rows, the pins and the live
/// public ids.
pub(crate) fn placements_in(
    connection: &Connection,
    range: std::ops::RangeInclusive<usize>,
) -> anyhow::Result<Vec<Value>> {
    let local = local_registry_id(connection)?;
    let rows = read_workspaces(connection)?;
    let rooms: std::collections::HashMap<(String, String), String> = read_pins(connection)?
        .into_iter()
        .map(|pin| ((pin.session_id, pin.workspace_key), pin.profile))
        .collect();
    let live: Vec<(String, String)> = {
        let mut statement = connection.prepare(
            "SELECT w.workspace_key, rw.public_id FROM workspaces AS w
             JOIN resource_workspaces AS rw ON rw.workspace_key = w.workspace_key
             WHERE w.tombstoned = 0 AND rw.deleted_revision IS NULL
             ORDER BY w.position ASC",
        )?;
        statement
            .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?
            .collect::<Result<Vec<_>, _>>()?
    };
    // Public ids as `workspace_ref` reads them (deleted_revision only).
    let public: Vec<(String, String)> = {
        let mut statement = connection.prepare(
            "SELECT workspace_key, public_id FROM resource_workspaces
             WHERE deleted_revision IS NULL",
        )?;
        statement
            .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?
            .collect::<Result<Vec<_>, _>>()?
    };
    let ids: std::collections::HashMap<&str, &str> =
        public.iter().map(|(key, id)| (key.as_str(), id.as_str())).collect();
    let reference = |session: &str, key: &str| {
        let id = (session == local).then(|| ids.get(key).copied()).flatten();
        json!({"session_id": session, "workspace_ref": key, "workspace_id": id})
    };
    let mut placements = Vec::new();
    let mut placed = std::collections::HashSet::new();
    for row in &rows {
        if row.session_id == local {
            placed.insert(row.workspace_key.as_str());
        }
        if !range.contains(&row.index) {
            continue;
        }
        let room = rooms.get(&(row.session_id.clone(), row.workspace_key.clone()));
        placements.push(json!({
            "workspace": reference(&row.session_id, &row.workspace_key),
            "index": row.index,
            "group_id": row.group,
            "room_id": room,
        }));
    }
    let mut index = rows.len();
    for (key, _) in &live {
        if placed.contains(key.as_str()) {
            continue;
        }
        if range.contains(&index) {
            let room = rooms.get(&(local.clone(), key.clone()));
            placements.push(json!({
                "workspace": reference(&local, key),
                "index": index,
                "group_id": null,
                "room_id": room,
            }));
        }
        index += 1;
    }
    Ok(placements)
}

/// The placement of one qualified workspace. A workspace without a personal
/// row reports index 0 and no group.
pub(crate) fn placement_snapshot(
    connection: &Connection,
    session_id: &str,
    workspace_key: &str,
) -> anyhow::Result<Value> {
    let local = local_registry_id(connection)?;
    // One row by its key and its ordinal by the order index, not a read of
    // every row: a create and a move publish this for one row at a time.
    match read_workspace(connection, session_id, workspace_key)? {
        Some(row) => placement_value(connection, &local, &row, &read_pins(connection)?),
        None => {
            let room = read_pins(connection)?
                .into_iter()
                .find(|pin| pin.session_id == session_id && pin.workspace_key == workspace_key)
                .map(|pin| pin.profile);
            Ok(json!({
                "workspace": workspace_ref(connection, &local, session_id, workspace_key)?,
                "index": 0,
                "group_id": null,
                "room_id": room,
            }))
        }
    }
}

// MARK: Transaction-level writes (the raw command bodies)

#[track_caller]
pub(crate) fn create_group(
    tx: &Transaction<'_>,
    room: Option<&str>,
    name: &str,
    color: Option<&str>,
    collapsed: bool,
    index: Option<usize>,
) -> anyhow::Result<PersonalGroup> {
    WorkspaceRegistry::create_personal_group_in(tx, None, room, name, color, collapsed, index)
        .map(|(group, _)| group)
}

#[track_caller]
pub(crate) fn update_group(
    tx: &Transaction<'_>,
    id: &str,
    name: Option<&str>,
    color: Option<Option<&str>>,
    collapsed: Option<bool>,
    room: Option<&str>,
) -> anyhow::Result<PersonalGroup> {
    WorkspaceRegistry::update_personal_group_in(tx, id, name, color, collapsed, room)
        .map(|(group, _)| group)
}

#[track_caller]
pub(crate) fn delete_group(
    tx: &Transaction<'_>,
    id: &str,
) -> anyhow::Result<Vec<(String, String)>> {
    WorkspaceRegistry::delete_personal_group_in(tx, id)
}

#[track_caller]
pub(crate) fn move_group(
    tx: &Transaction<'_>,
    id: &str,
    index: usize,
) -> anyhow::Result<PersonalGroup> {
    WorkspaceRegistry::move_personal_group_in(tx, id, index).map(|(group, _)| group)
}

#[track_caller]
pub(crate) fn set_group_top(
    tx: &Transaction<'_>,
    id: &str,
    top_index: Option<usize>,
) -> anyhow::Result<PersonalGroup> {
    WorkspaceRegistry::set_personal_group_top_in(tx, id, top_index).map(|(group, _)| group)
}

#[track_caller]
pub(crate) fn set_group_icon(
    tx: &Transaction<'_>,
    id: &str,
    icon: Option<&str>,
) -> anyhow::Result<PersonalGroup> {
    WorkspaceRegistry::set_personal_group_icon_in(tx, id, icon).map(|(group, _)| group)
}

#[track_caller]
pub(crate) fn set_group_pinned(
    tx: &Transaction<'_>,
    id: &str,
    pinned: bool,
) -> anyhow::Result<PersonalGroup> {
    WorkspaceRegistry::set_personal_group_pinned_in(tx, id, pinned).map(|(group, _)| group)
}

#[track_caller]
pub(crate) fn place_workspace(
    tx: &Transaction<'_>,
    session: &str,
    key: &str,
    update: PersonalWorkspaceUpdate,
) -> anyhow::Result<PersonalWorkspace> {
    WorkspaceRegistry::set_personal_workspace_in(tx, session, key, update).map(|(row, _)| row)
}

#[track_caller]
pub(crate) fn create_room(
    tx: &Transaction<'_>,
    input: ProfileInput,
) -> anyhow::Result<PersonalProfile> {
    WorkspaceRegistry::create_profile_in(tx, input).map(|(room, _)| room)
}

#[track_caller]
pub(crate) fn update_room(
    tx: &Transaction<'_>,
    id: &str,
    update: ProfileUpdate,
) -> anyhow::Result<PersonalProfile> {
    WorkspaceRegistry::update_profile_in(tx, id, update).map(|(room, _)| room)
}

#[track_caller]
pub(crate) fn move_room(
    tx: &Transaction<'_>,
    id: &str,
    index: usize,
) -> anyhow::Result<PersonalProfile> {
    WorkspaceRegistry::move_profile_in(tx, id, index).map(|(room, _)| room)
}

#[track_caller]
pub(crate) fn delete_room(
    tx: &Transaction<'_>,
    id: &str,
    move_to: Option<&str>,
) -> anyhow::Result<ProfileDeletion> {
    WorkspaceRegistry::delete_profile_in(tx, id, move_to)
}

#[track_caller]
pub(crate) fn follow_sessions(
    tx: &Transaction<'_>,
    id: &str,
    sessions: &[String],
) -> anyhow::Result<PersonalProfile> {
    WorkspaceRegistry::set_profile_follows_in(tx, id, sessions).map(|(room, _)| room)
}

#[track_caller]
pub(crate) fn pin_workspace(
    tx: &Transaction<'_>,
    session: &str,
    key: &str,
    room: &str,
) -> anyhow::Result<()> {
    WorkspaceRegistry::pin_workspace_in(tx, session, key, room).map(|_| ())
}

#[track_caller]
pub(crate) fn unpin_workspace(
    tx: &Transaction<'_>,
    session: &str,
    key: &str,
) -> anyhow::Result<()> {
    WorkspaceRegistry::unpin_workspace_in(tx, session, key).map(|_| ())
}
