//! The one workspace order. With the sidebar document (`sidebar-doc-v1`),
//! `workspace.list` (no `order`, or `order: personal`) lists this machine's workspaces in the document's display
//! order: section by section (Pinned before the machine sections), each
//! group's members in place right after the group. A live workspace the
//! document does not place yet goes where `workspaces.newPlacement` puts a
//! new one. The reply shape stays the same; only the array order changes.
//! `workspace.list {order: session}` keeps the session order, and so does
//! the private `list-workspaces` tree: its `workspace-added` /
//! `workspace-moved` deltas carry session indexes that delta readers (the
//! app's store) apply to the listed array. Without the document the order
//! is unchanged.

use std::collections::{HashMap, HashSet};

use cmux_layout_reducer::sidebar_doc::Item;
use rusqlite::Connection;
use serde_json::Value;

use super::sidebar_doc_store as store;
use super::values::local_registry_id;
use crate::user_settings::NewWorkspacePlacement;

/// This machine's workspace ids in document order, and how many of them
/// come before this machine's section (the slot of a `Top` placement).
pub(crate) struct DocumentOrder {
    ids: Vec<String>,
    machine_start: usize,
}

/// The document order, or `None` when the store has no document.
pub(crate) fn document_order(connection: &Connection) -> anyhow::Result<Option<DocumentOrder>> {
    if !store::is_migrated(connection)? {
        return Ok(None);
    }
    let local = local_registry_id(connection)?;
    store::with_doc(connection, |doc| {
        let mut ids = Vec::new();
        let mut seen = HashSet::new();
        let mut machine_start = None;
        let mut push = |ids: &mut Vec<String>, item: &Item| {
            if let Some(reference) = item.body.workspace()
                && reference.session_id == local
                && seen.insert(reference.workspace_id.clone())
            {
                ids.push(reference.workspace_id.clone());
            }
        };
        for section in doc.sections() {
            if machine_start.is_none() && section.kind.machine() == Some(local.as_str()) {
                machine_start = Some(ids.len());
            }
            for item in doc.list(&section.id, None) {
                push(&mut ids, item);
                if item.body.is_group() {
                    for member in doc.list(&section.id, Some(item.id.as_str())) {
                        push(&mut ids, member);
                    }
                }
            }
        }
        let machine_start = machine_start.unwrap_or(ids.len());
        Ok(Some(DocumentOrder { ids, machine_start }))
    })
}

/// Sort `workspaces` (reply objects whose `id_field` is the workspace's
/// public id) into `order`. Unplaced ones keep their relative order and go
/// to the `placement` slot: `Top` at the start of this machine's section,
/// `Bottom` last, `BeforeCurrent` / `AfterCurrent` right before / after the
/// active (`active` or `focused`) workspace of this machine's section other
/// than Home, else first in the section below a leading Home row.
pub(crate) fn sort_workspaces(
    workspaces: &mut Vec<Value>,
    id_field: &str,
    order: &DocumentOrder,
    placement: NewWorkspacePlacement,
) {
    let rank: HashMap<&str, usize> =
        order.ids.iter().enumerate().map(|(rank, id)| (id.as_str(), rank)).collect();
    let rank_of =
        |workspace: &Value| workspace[id_field].as_str().and_then(|id| rank.get(id).copied());
    let (mut placed, unplaced): (Vec<Value>, Vec<Value>) =
        std::mem::take(workspaces).into_iter().partition(|workspace| rank_of(workspace).is_some());
    placed.sort_by_key(|workspace| rank_of(workspace).unwrap_or(usize::MAX));
    let top = placed
        .iter()
        .take_while(|workspace| rank_of(workspace).is_some_and(|rank| rank < order.machine_start))
        .count();
    let is_home = |workspace: &Value| {
        workspace["extra"]["kind"].as_str() == Some(super::home_store::HOME_KIND)
    };
    // The current workspace anchors only from this machine's section (not a
    // pinned row before it) and never as Home; without one, a new row goes
    // first in the section, below a leading Home row.
    let current = (top..placed.len()).find(|&index| {
        let workspace = &placed[index];
        !is_home(workspace)
            && (workspace["active"].as_bool() == Some(true)
                || workspace["focused"].as_bool() == Some(true))
    });
    let below_home = top + usize::from(placed.get(top).is_some_and(is_home));
    let slot = match placement {
        NewWorkspacePlacement::Bottom => placed.len(),
        NewWorkspacePlacement::Top => top,
        NewWorkspacePlacement::BeforeCurrent => current.unwrap_or(below_home),
        NewWorkspacePlacement::AfterCurrent => current.map_or(below_home, |index| index + 1),
    };
    placed.splice(slot..slot, unplaced);
    *workspaces = placed;
}
