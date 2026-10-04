//! Public ids for every live split (layout splits, viewport columns and
//! their rows), minted once and kept in the resource indexes.

use std::collections::HashSet;

use crate::model::{Node, State};
use crate::resource::SplitPublicId;

pub(super) fn ensure_split_public_ids(state: &mut State) -> anyhow::Result<()> {
    let mut splits = HashSet::new();
    for workspace in &state.workspaces {
        for screen in &workspace.screens {
            collect_node_split_ids(&screen.root, &mut splits);
            for column in &screen.layout_columns {
                splits.extend(std::iter::once(column.id).chain(column.row_ids()));
                collect_node_split_ids(&column.root, &mut splits);
            }
        }
    }
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
