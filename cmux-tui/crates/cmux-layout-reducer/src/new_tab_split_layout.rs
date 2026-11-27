//! Predict the divider-insert tree before creating a New Tab renderer at its final size.
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
            Node::split(NEW_SPLIT, *axis, 0.5, *a.clone(), Node::leaf(NEW_PANE)),
            *b.clone(),
        ));
    }
    if let changed = insert(a, target, ratio) {
        return Some(Node::split(split, *axis, *old, changed, *b.clone()));
    }
    insert(b, target, ratio).map(|changed| Node::split(split, *axis, *old, *a.clone(), changed))
}

#[cfg(test)]
mod new_tab_split_layout_tests {
    use super::*;
    use crate::layout_state::{DIVIDER_RATIO, divider_insert_plan};
    use crate::screen_layout::Axis;

    fn predicted(tree: Node, split: &str) -> Node {
        predict(Request { tree, split: split.into(), ratio: DIVIDER_RATIO }).unwrap()
    }

    #[test]
    fn new_tab_divider_wraps_the_whole_first_subtree_on_the_existing_axis() {
        let first = Node::split("nested", Axis::Vertical, 0.35, Node::leaf("a"), Node::leaf("b"));
        let tree = Node::split("divider", Axis::Horizontal, 0.7, first.clone(), Node::leaf("c"));
        let plan = divider_insert_plan(&tree, "divider").unwrap();
        assert_eq!(plan.target, "b");
        assert_eq!(plan.around.as_deref(), Some("nested"));
        assert_eq!(
            predicted(tree, "divider"),
            Node::split(
                "divider",
                plan.axis,
                plan.sizing[0].ratio,
                Node::split(NEW_SPLIT, plan.axis, 0.5, first, Node::leaf(NEW_PANE)),
                Node::leaf("c"),
            )
        );
    }

    #[test]
    fn new_tab_nested_divider_preserves_ancestor_and_sibling_geometry() {
        let nested = Node::split("divider", Axis::Vertical, 0.4, Node::leaf("a"), Node::leaf("b"));
        let tree =
            Node::split("outer", Axis::Horizontal, 0.27, Node::leaf("sibling"), nested.clone());
        assert_eq!(
            predicted(tree, "divider"),
            Node::split(
                "outer",
                Axis::Horizontal,
                0.27,
                Node::leaf("sibling"),
                predicted(nested, "divider"),
            )
        );
    }

    #[test]
    fn new_tab_missing_divider_and_invalid_ratios_have_no_preview() {
        let tree = Node::split("divider", Axis::Horizontal, 0.5, Node::leaf("a"), Node::leaf("b"));
        for ratio in [0.0, 1.0, f64::NAN] {
            assert!(
                predict(Request { tree: tree.clone(), split: "divider".into(), ratio }).is_none()
            );
        }
        assert!(predict(Request { tree, split: "missing".into(), ratio: DIVIDER_RATIO }).is_none());
    }
}
