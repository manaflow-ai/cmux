//! Nested personal workspace groups (`workspace-group-nest-v1`): a group's
//! parent group, the rules a parent must meet, and the sibling order.
//!
//! A parent is another group of the same room. A group is never inside
//! itself, and a chain is at most [`MAX_GROUP_DEPTH`] groups long, its
//! nested groups included. A refused parent is a `bad request` with the
//! reason (`nesting`, `too_deep`, `cross_room`), and nothing changes.
//!
//! The personal store has no place for a nested group among its parent's
//! workspaces: inside a parent, its nested groups come first (in group
//! order), then its workspaces. The sidebar document follows that order
//! when it syncs a nest from this store.
//!
//! Only a top-level group has a place among the loose workspaces
//! (`top_index`) and a pin: a nested group shows and pins with its
//! top-level group. Nesting a group clears its own slot and pin;
//! `top_index` or `pinned: true` on a nested group is refused
//! (`nested_group`).

use std::collections::HashMap;

use cmux_layout_reducer::sidebar_doc::MAX_GROUP_DEPTH;
use rusqlite::{Connection, Transaction, params};
use serde_json::json;

use super::super::WorkspaceRegistry;
use super::super::personal_store::{
    PersonalGroup, commit_personal, read_group, read_groups, subject,
};
use super::super::presentation_store::validate_workspace_group_id;

pub(crate) const WORKSPACE_GROUP_NEST_CAPABILITY: &str = "workspace-group-nest-v1";

/// Every group's parent, by group id.
fn parents(connection: &Connection) -> anyhow::Result<HashMap<String, Option<String>>> {
    Ok(read_groups(connection)?.into_iter().map(|group| (group.id, group.parent)).collect())
}

/// The groups above `id`, nearest first (bounded, so a stored cycle ends).
pub(crate) fn ancestors_in(parents: &HashMap<String, Option<String>>, id: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cursor = parents.get(id).cloned().flatten();
    while let Some(parent) = cursor {
        if parent == id || out.contains(&parent) || out.len() > MAX_GROUP_DEPTH {
            break;
        }
        cursor = parents.get(&parent).cloned().flatten();
        out.push(parent);
    }
    out
}

/// `id` and every group under it, parents before children.
pub(crate) fn subtree_in(parents: &HashMap<String, Option<String>>, id: &str) -> Vec<String> {
    let mut out = vec![id.to_string()];
    let mut at = 0;
    while at < out.len() && out.len() <= parents.len() {
        let parent = out[at].clone();
        let mut children: Vec<&String> = parents
            .iter()
            .filter(|(child, above)| {
                above.as_deref() == Some(parent.as_str()) && !out.contains(child)
            })
            .map(|(child, _)| child)
            .collect();
        children.sort();
        out.extend(children.into_iter().cloned());
        at += 1;
    }
    out
}

/// How many group levels `id` and its nested groups take (1: no nested group).
fn height_in(parents: &HashMap<String, Option<String>>, id: &str) -> usize {
    subtree_in(parents, id)
        .iter()
        .map(|group| {
            let below_id = ancestors_in(parents, group).iter().position(|above| above == id);
            match below_id {
                Some(at) => at + 2,
                None => 1,
            }
        })
        .max()
        .unwrap_or(1)
}

/// Refuse `parent` for group `id` unless it is a group of the same room,
/// not `id` or a group under it, and the result is at most
/// [`MAX_GROUP_DEPTH`] levels deep.
pub(crate) fn require_parent(
    connection: &Connection,
    id: Option<&str>,
    room: &str,
    parent: &str,
) -> anyhow::Result<()> {
    let target = read_group(connection, parent)?
        .ok_or_else(|| anyhow::anyhow!("unknown personal group {parent}"))?;
    anyhow::ensure!(
        target.profile == room,
        "bad request: cross_room: group {parent} is in room {}, not {room}",
        target.profile
    );
    let parents = parents(connection)?;
    let above = ancestors_in(&parents, parent);
    if let Some(id) = id {
        anyhow::ensure!(
            parent != id && !above.iter().any(|group| group == id),
            "bad request: nesting: group {id} cannot go inside itself or one of its own groups"
        );
    }
    let height = id.map_or(1, |id| height_in(&parents, id));
    anyhow::ensure!(
        above.len() + 1 + height <= MAX_GROUP_DEPTH,
        "bad request: too_deep: groups nest at most {MAX_GROUP_DEPTH} levels"
    );
    Ok(())
}

impl WorkspaceRegistry {
    /// Put group `id` inside `parent` (`None`: the top level), at the end
    /// of its new siblings, inside the caller's transaction (the v2
    /// `workspace_group.update {parent_group}` commit).
    pub(crate) fn set_personal_group_parent_in(
        tx: &Transaction<'_>,
        id: &str,
        parent: Option<&str>,
    ) -> anyhow::Result<(PersonalGroup, bool)> {
        validate_workspace_group_id(id)?;
        let before =
            read_group(tx, id)?.ok_or_else(|| anyhow::anyhow!("unknown personal group {id}"))?;
        if before.parent.as_deref() == parent {
            return Ok((before, false));
        }
        if let Some(parent) = parent {
            require_parent(tx, Some(id), &before.profile, parent)?;
        }
        // A nested group has no slot and no pin of its own.
        if parent.is_some() {
            tx.execute(
                "UPDATE personal_groups SET parent_id = ?2, top_position = NULL, pinned = 0
                 WHERE group_id = ?1",
                params![id, parent],
            )?;
        } else {
            tx.execute(
                "UPDATE personal_groups SET parent_id = NULL WHERE group_id = ?1",
                params![id],
            )?;
        }
        // At the end of its new siblings.
        let mut order: Vec<String> = read_groups(tx)?.into_iter().map(|group| group.id).collect();
        order.retain(|group| group != id);
        order.push(id.to_string());
        super::super::personal_store::write_order(tx, "personal_groups", "group_id", &order)?;
        let after =
            read_group(tx, id)?.ok_or_else(|| anyhow::anyhow!("unknown personal group {id}"))?;
        commit_personal(
            tx,
            "personal.group.updated",
            vec![subject("personal_group", id)],
            &json!({"group": after}),
        )?;
        Ok((after, true))
    }
}

/// Refuse a slot or a pin of its own for a nested group.
pub(crate) fn require_top_level(
    connection: &Connection,
    id: &str,
    what: &str,
) -> anyhow::Result<()> {
    let group = read_group(connection, id)?
        .ok_or_else(|| anyhow::anyhow!("unknown personal group {id}"))?;
    anyhow::ensure!(
        group.parent.is_none(),
        "bad request: nested_group: {what} is for a top-level group; group {id} shows with its top-level group"
    );
    Ok(())
}

/// The group order with `id` moved to `index` among its siblings (the
/// groups with the same parent); the other groups keep their places.
pub(crate) fn sibling_move(
    groups: &[PersonalGroup],
    id: &str,
    index: usize,
) -> Option<Vec<String>> {
    let moving = groups.iter().find(|group| group.id == id)?;
    let siblings: Vec<&str> = groups
        .iter()
        .filter(|group| group.parent == moving.parent && group.id != id)
        .map(|group| group.id.as_str())
        .collect();
    let mut order: Vec<String> =
        groups.iter().filter(|group| group.id != id).map(|group| group.id.clone()).collect();
    let at = match siblings.get(index) {
        Some(anchor) => order.iter().position(|group| group == anchor)?,
        None => match siblings.last() {
            Some(last) => order.iter().position(|group| group == last)? + 1,
            None => order.len(),
        },
    };
    order.insert(at, id.to_string());
    Some(order)
}
