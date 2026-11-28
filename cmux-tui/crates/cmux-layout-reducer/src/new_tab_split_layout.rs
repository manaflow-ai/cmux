//! Predict the divider-insert tree before creating a New Tab renderer at its final size.
use crate::divider_insert::NEW_SPLIT_RATIO;
use crate::screen_layout::Node;
use serde::Deserialize;

pub const NEW_PANE: &str = "__new-tab-divider-pane";
const NEW_SPLIT: &str = "__new-tab-divider-split";

#[derive(Deserialize)]
pub struct Request {
    pub tree: Node,
    pub split: String,
    pub ratio: f64,
}

/// The same wrapping as `divider_insert_plan`: preserve all of the first subtree, append
/// the new pane on its axis, and apply the caller's divider ratio. An absent split has no preview.
pub fn predict(request: Request) -> Option<Node> {
    if !request.ratio.is_finite() || request.ratio <= 0.0 || request.ratio >= 1.0 {
        return None;
    }
    insert(&request.tree, &request.split, request.ratio)
}

fn insert(tree: &Node, target: &str, ratio: f64) -> Option<Node> {
    let Node::Split { split, axis, ratio: old, a, b } = tree else { return None };
    if split == target {
        return Some(Node::split(
            split,
            *axis,
            ratio,
            Node::split(NEW_SPLIT, *axis, NEW_SPLIT_RATIO, *a.clone(), Node::leaf(NEW_PANE)),
            *b.clone(),
        ));
    }
    if let Some(changed) = insert(a, target, ratio) {
        return Some(Node::split(split, *axis, *old, changed, *b.clone()));
    }
    insert(b, target, ratio).map(|changed| Node::split(split, *axis, *old, *a.clone(), changed))
}

#[cfg(test)]
#[path = "new_tab_split_layout_new_tab_split_layout_tests.rs"]
mod new_tab_split_layout_tests;
