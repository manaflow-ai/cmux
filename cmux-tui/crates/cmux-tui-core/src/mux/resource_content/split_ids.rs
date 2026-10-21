//! Public ids for every live split (layout splits, viewport columns and
//! their rows), minted once and kept in the resource indexes.

use std::collections::HashSet;

use crate::model::{Node, State};
use crate::resource::SplitPublicId;

pub(super) fn ensure_split_public_ids(state: &mut State) -> anyhow::Result<()> {
    let mut splits = HashSet::new();
    for workspace in &state.workspaces {
        for screen in &workspace.screens {
            collect_screen_split_ids(screen, &mut splits);
        }
    }
    mint_split_public_ids(state, splits)
}

/// Names every split of the screen at `location` (workspace and screen
/// index) that has no public id yet, so a layout the daemon sends names each
/// of its splits from the first time it holds them (`split_id`,
/// `split-client-split-id-v1`). O(the screen's splits).
pub(crate) fn ensure_screen_split_public_ids(
    state: &mut State,
    location: (usize, usize),
) -> anyhow::Result<()> {
    let mut splits = HashSet::new();
    if let Some(screen) =
        state.workspaces.get(location.0).and_then(|workspace| workspace.screens.get(location.1))
    {
        collect_screen_split_ids(screen, &mut splits);
    }
    splits.retain(|split| !state.resource_indexes.split_ids.contains_key(split));
    mint_split_public_ids(state, splits)
}

/// Every split of one screen: its layout splits, viewport columns and rows.
pub(super) fn collect_screen_split_ids(
    screen: &crate::model::Screen,
    splits: &mut HashSet<crate::SplitId>,
) {
    collect_node_split_ids(&screen.root, splits);
    for column in &screen.layout_columns {
        splits.extend(std::iter::once(column.id).chain(column.row_ids()));
        collect_node_split_ids(&column.root, splits);
    }
}

/// Mint a public id for each split in `splits` that has none.
pub(super) fn mint_split_public_ids(
    state: &mut State,
    splits: HashSet<crate::SplitId>,
) -> anyhow::Result<()> {
    for split in splits {
        if state.resource_indexes.split_ids.contains_key(&split) {
            continue;
        }
        let public_id = SplitPublicId::random()?;
        state.resource_indexes.splits.insert(public_id.clone(), split);
        state.resource_indexes.split_ids.insert(split, public_id);
    }
    Ok(())
}

fn collect_node_split_ids(node: &Node, splits: &mut HashSet<crate::SplitId>) {
    match node {
        Node::Leaf(_) | Node::Stack { .. } => {}
        Node::Split { id, a, b, .. } => {
            splits.insert(*id);
            collect_node_split_ids(a, splits);
            collect_node_split_ids(b, splits);
        }
    }
}
