//! Split public ids referenced by a screen layout and its viewport.

use super::*;

pub(crate) fn collect_split_public_ids(layout: &RegistryLayoutNode, output: &mut Vec<String>) {
    match layout {
        RegistryLayoutNode::Leaf { .. } | RegistryLayoutNode::Stack { .. } => {}
        RegistryLayoutNode::Split { split, first, second, .. } => {
            output.push(split.to_string());
            collect_split_public_ids(first, output);
            collect_split_public_ids(second, output);
        }
    }
}

pub(crate) fn collect_screen_split_public_ids(
    layout: &RegistryLayoutNode,
    viewport: &RegistryViewport,
    output: &mut Vec<String>,
) {
    collect_split_public_ids(layout, output);
    for column in &viewport.columns {
        if !output.iter().any(|id| id == column.id.as_str()) {
            output.push(column.id.to_string());
        }
    }
}
