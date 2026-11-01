//! The one workspace order. With the sidebar document (`sidebar-doc-v1`),
//! `workspace.list` (no `order`, or `order: personal`) lists this machine's workspaces in the document's display
//! order: section by section (Pinned before the machine sections), each
//! group's members (nested groups' too) in place right after the group. A live workspace the
//! document does not place yet goes where `workspaces.newPlacement` puts a
//! new one. The reply shape stays the same; only the array order changes.
//! `workspace.list {order: session}` keeps the session order, and so does
//! the private `list-workspaces` tree: its `workspace-added` /
//! `workspace-moved` deltas carry session indexes that delta readers (the
//! app's store) apply to the listed array. Without the document the order
//! is unchanged.

use std::collections::{HashMap, HashSet};

use cmux_layout_reducer::sidebar_doc::{Doc, Item};
use rusqlite::Connection;
use serde_json::Value;

use super::sidebar_doc_store as store;
use super::values::local_registry_id;
use crate::user_settings::NewWorkspacePlacement;

/// This machine's workspace ids in document order, and how many of them
/// come before this machine's section (the slot of a `Top` placement) and
/// before the archived tail of that section's top level, where the reducer
/// puts a new workspace (plans/cmux-next/archiving-DESIGN.md).
pub(crate) struct DocumentOrder {
    ids: Vec<String>,
    machine_start: usize,
    archived_start: Option<usize>,
}

/// The document order, or `None` when the store has no document.
pub(crate) fn document_order(connection: &Connection) -> anyhow::Result<Option<DocumentOrder>> {
    if !store::is_migrated(connection)? {
        return Ok(None);
    }
    let local = local_registry_id(connection)?;
    store::with_doc(connection, |doc| Ok(Some(order_in(doc, &local))))
}

/// The order of `local`'s workspaces in `doc` ([`document_order`]).
pub(crate) fn order_in(doc: &Doc, local: &str) -> DocumentOrder {
    let mut ids = Vec::new();
    let mut seen = HashSet::new();
    let mut machine_start = None;
    let mut archived_start = None;
    let mut push = |ids: &mut Vec<String>, item: &Item| {
        if let Some(reference) = item.body.workspace()
            && reference.session_id == local
            && seen.insert(reference.workspace_id.clone())
        {
            ids.push(reference.workspace_id.clone());
        }
    };
    for section in doc.sections() {
        let own = section.kind.machine() == Some(local);
        if machine_start.is_none() && own {
            machine_start = Some(ids.len());
        }
        for item in doc.list(&section.id, None) {
            if own {
                // The archived run is the list's tail: it starts at its first item.
                archived_start = match (item.archived(), archived_start) {
                    (true, None) => Some(ids.len()),
                    (true, start) => start,
                    (false, _) => None,
                };
            }
            push(&mut ids, item);
            // Every member, nested groups' too, at its group's place.
            if item.body.is_group() {
                let mut groups = vec![doc.list(&section.id, Some(item.id.as_str()))];
                while let Some(members) = groups.last_mut() {
                    let Some(member) = members.next() else {
                        groups.pop();
                        continue;
                    };
                    push(&mut ids, member);
                    if member.body.is_group() {
                        groups.push(doc.list(&section.id, Some(member.id.as_str())));
                    }
                }
            }
        }
    }
    let machine_start = machine_start.unwrap_or(ids.len());
    DocumentOrder { ids, machine_start, archived_start }
}

impl DocumentOrder {
    /// This machine's workspace ids in display order.
    pub(crate) fn ids(&self) -> &[String] {
        &self.ids
    }
}

/// Sort `workspaces` (reply objects whose `id_field` is the workspace's
/// public id) into `order`. Unplaced ones keep their relative order and go
/// to the `placement` slot: `Top` at the start of this machine's section,
/// `Bottom` last, `AfterCurrent` right after the active (`active` or
/// `focused`) workspace, else as `Top`.
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
    let is_active = |workspace: &Value| {
        workspace["active"].as_bool() == Some(true) || workspace["focused"].as_bool() == Some(true)
    };
    // Above this machine's archived tail, where adopting the new workspace puts it.
    let bottom = order.archived_start.map_or(placed.len(), |start| {
        placed
            .iter()
            .position(|workspace| rank_of(workspace).is_some_and(|rank| rank >= start))
            .unwrap_or(placed.len())
    });
    let slot = match placement {
        NewWorkspacePlacement::Bottom => bottom,
        NewWorkspacePlacement::Top => top,
        NewWorkspacePlacement::AfterCurrent => {
            // An archived active workspace: above the tail too.
            placed.iter().position(is_active).map_or(top, |index| (index + 1).min(bottom))
        }
    };
    placed.splice(slot..slot, unplaced);
    *workspaces = placed;
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn ids(workspaces: &[Value]) -> Vec<&str> {
        workspaces.iter().map(|workspace| workspace["id"].as_str().unwrap()).collect()
    }

    /// This machine's section: `a`, then the archived tail `z`; `new` is not placed yet.
    fn listed(active: &str) -> (Vec<Value>, DocumentOrder) {
        let order = DocumentOrder {
            ids: vec!["a".into(), "z".into()],
            machine_start: 0,
            archived_start: Some(1),
        };
        let workspaces =
            ["z", "new", "a"].map(|id| json!({ "id": id, "active": id == active })).to_vec();
        (workspaces, order)
    }

    #[test]
    fn a_new_workspace_lists_above_the_archived_tail() {
        let (mut workspaces, order) = listed("a");
        sort_workspaces(&mut workspaces, "id", &order, NewWorkspacePlacement::Bottom);
        assert_eq!(ids(&workspaces), ["a", "new", "z"]);
        // After an archived active workspace: above the tail too.
        let (mut workspaces, order) = listed("z");
        sort_workspaces(&mut workspaces, "id", &order, NewWorkspacePlacement::AfterCurrent);
        assert_eq!(ids(&workspaces), ["a", "new", "z"]);
        let (mut workspaces, order) = listed("a");
        sort_workspaces(&mut workspaces, "id", &order, NewWorkspacePlacement::AfterCurrent);
        assert_eq!(ids(&workspaces), ["a", "new", "z"]);
    }
}
