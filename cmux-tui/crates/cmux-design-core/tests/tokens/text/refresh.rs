//! `ChromeTextRefresh.swift`.

use cmux_design_core::ops::call;
use cmux_design_core::tokens::text::refresh::*;
use serde_json::json;

fn node(
    id: &str,
    kind: LayerKind,
    sublayers: Vec<LayerNode>,
    mask: Option<LayerNode>,
) -> LayerNode {
    LayerNode { id: id.into(), kind, sublayers, mask: mask.map(Box::new) }
}

/// A label redraws and is walked into; a text layer redraws and stops; masks come after sublayers.
#[test]
fn walk_order() {
    let tree = node(
        "root",
        LayerKind::Other,
        vec![
            node(
                "label",
                LayerKind::Label,
                vec![node("inner", LayerKind::TextLayer, vec![], None)],
                None,
            ),
            node(
                "text",
                LayerKind::TextLayer,
                vec![node("hidden", LayerKind::Label, vec![], None)],
                None,
            ),
        ],
        Some(node(
            "mask",
            LayerKind::Other,
            vec![node("maskText", LayerKind::TextLayer, vec![], None)],
            None,
        )),
    );
    assert_eq!(
        refresh(&tree),
        vec![
            Refresh::Label("label".into()),
            Refresh::TextLayer("inner".into()),
            Refresh::TextLayer("text".into()),
            Refresh::TextLayer("maskText".into()),
        ]
    );
    assert!(refresh(&LayerNode::default()).is_empty());
}

#[test]
fn op() {
    let request = json!({"id": "root", "sublayers": [{"id": "l", "kind": "label"}, {"id": "t", "kind": "textLayer"}]});
    assert_eq!(
        call("tokens.text_refresh", &request).unwrap(),
        json!({"refresh": [{"kind": "label", "id": "l"}, {"kind": "textLayer", "id": "t"}]})
    );
}
