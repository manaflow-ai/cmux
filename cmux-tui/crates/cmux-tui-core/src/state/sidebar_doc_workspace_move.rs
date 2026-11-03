//! `workspace.move {index}` in the sidebar document (`sidebar-doc-v1`): the
//! order the person sees (#29875). The session order alone moved before, so
//! `cmux workspace <ws> move --index 0` (the Chief's "move to top") changed
//! nothing in the sidebar, which draws the document.
//!
//! `index` counts this machine's workspaces in `workspace.list` order (the
//! document's display order). The workspace keeps its place kind: it stays in
//! its section and in its group, so a move never pins, unpins or regroups it
//! (`workspace group add|remove` and `sidebar pin` do that). Among its
//! siblings on its own side (archived items stay last, a group's pinned
//! members first) it goes before the first one that lists at `index` or
//! later (a group lists at its first member), else last. The home workspace
//! stays first: it is never an anchor and is never moved. An app section's
//! items are its provider's and do not move.
//!
//! The document move commits after the session move, under a key derived
//! from the request's, so a retried request replays both.

use std::collections::HashMap;

use cmux_layout_reducer::sidebar_doc::{Doc, Item, Op, SectionKind, Target, WorkspaceRef};
use serde_json::json;
use sha2::{Digest, Sha256};

use super::sidebar_doc_order::order_in;
use super::sidebar_doc_store as store;
use super::values::local_registry_id;
use crate::WorkspaceMutation;
use crate::mux::*;
use crate::state::store::StateCommit;

/// The reducer ops that move `local`'s workspace `workspace` to `index` of
/// the display order, or none when it already lists there, has no item, or is
/// the home workspace.
pub(crate) fn move_ops(
    doc: &Doc,
    local: &str,
    home: Option<&str>,
    workspace: &str,
    index: usize,
) -> Vec<Op> {
    if home == Some(workspace) {
        return Vec::new();
    }
    let Some(item) = doc.workspace_item(&WorkspaceRef::new(local, workspace)) else {
        return Vec::new();
    };
    // An app section's items are its provider's: the reducer refuses a move there.
    if doc
        .section(&item.section)
        .is_none_or(|section| matches!(section.kind, SectionKind::App { .. }))
    {
        return Vec::new();
    }
    let order = order_in(doc, local);
    // Ranks without the moved workspace: `index` is where it ends up.
    let rank: HashMap<&str, usize> = order
        .ids()
        .iter()
        .filter(|id| id.as_str() != workspace)
        .enumerate()
        .map(|(rank, id)| (id.as_str(), rank))
        .collect();
    let local_rank = |entry: &Item| {
        entry
            .body
            .workspace()
            .filter(|reference| reference.session_id == local)
            .and_then(|reference| rank.get(reference.workspace_id.as_str()).copied())
    };
    // Where a sibling lists: a workspace at its rank, a group at its first member.
    let starts = |sibling: &Item| {
        if sibling.body.is_group() {
            doc.descendants(sibling).into_iter().filter_map(local_rank).min()
        } else {
            local_rank(sibling)
        }
    };
    let is_home = |sibling: &Item| {
        sibling.body.workspace().is_some_and(|reference| {
            reference.session_id == local && Some(reference.workspace_id.as_str()) == home
        })
    };
    // The reducer keeps archived items last and a group's pinned members
    // first: the move is among the siblings on the item's own side.
    let same_side = |sibling: &&Item| {
        sibling.archived() == item.archived()
            && (item.parent.is_none() || sibling.pinned_in_group() == item.pinned_in_group())
    };
    let siblings: Vec<&Item> =
        doc.list(&item.section, item.parent.as_deref()).filter(same_side).collect();
    let anchor = siblings
        .iter()
        .filter(|sibling| sibling.id != item.id && !is_home(sibling))
        .find(|sibling| starts(sibling).is_some_and(|start| start >= index))
        .map(|sibling| sibling.id.clone());
    // Already there: the next listed sibling after it is that anchor.
    let next = siblings
        .iter()
        .skip_while(|sibling| sibling.id != item.id)
        .skip(1)
        .filter(|sibling| !is_home(sibling))
        .find(|sibling| starts(sibling).is_some())
        .map(|sibling| sibling.id.clone());
    if next == anchor {
        return Vec::new();
    }
    vec![Op::Move {
        items: vec![item.id.clone()],
        to: Target {
            section: item.section.clone(),
            parent: item.parent.clone(),
            before: anchor,
            ..Target::default()
        },
    }]
}

/// The idempotency key of the document move of the `workspace.move` request
/// keyed `key`.
fn derived_key(key: &str) -> String {
    let digest = Sha256::digest(key.as_bytes());
    let hex: String = digest.iter().map(|byte| format!("{byte:02x}")).collect();
    format!("workspace.move.sidebar:{hex}")
}

impl Mux {
    /// Move workspace `workspace` (public id) to `index` of the sidebar
    /// document's order, after `workspace.move` moved it in the session
    /// (see the module). `None` when the store has no document.
    pub(crate) fn state_workspace_sidebar_move(
        &self,
        mutation: &WorkspaceMutation,
        workspace: &str,
        index: usize,
    ) -> anyhow::Result<Option<StateCommit>> {
        if !self.read_registry_state(store::is_migrated)? {
            return Ok(None);
        }
        let derived = WorkspaceMutation {
            id: derived_key(&mutation.id),
            origin: mutation.origin.clone(),
            actor: mutation.actor.clone(),
        };
        let operation = "workspace.move.sidebar";
        let fingerprint = json!({"operation": operation, "workspace": workspace, "index": index});
        let workspace = workspace.to_string();
        self.commit_sidebar_ops(&derived, operation, &fingerprint, move |transaction, doc| {
            let local = local_registry_id(transaction)?;
            let home = crate::state::home_store::live_home(transaction)?.map(|(id, _)| id);
            Ok(move_ops(doc, &local, home.as_deref(), &workspace, index))
        })
        .map(Some)
    }
}
