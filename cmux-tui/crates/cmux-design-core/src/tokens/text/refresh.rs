//! `ChromeTextRefresh.swift`: which layers of a tree draw again after a smoothing change, in
//! the order `refresh(_:)` visits them. The window walk and the redraw calls stay in Swift.

use serde::{Deserialize, Serialize};

/// What a layer is to the refresh.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LayerKind {
    /// A `ChromeLabel`'s layer (the label is its delegate).
    Label,
    /// A `ChromeTextLayer`.
    TextLayer,
    /// Any other layer.
    #[default]
    Other,
}

/// A layer tree: a layer, its sublayers and its mask.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct LayerNode {
    /// A name the caller gives the layer (echoed in the result).
    pub id: String,
    /// What the layer is.
    pub kind: LayerKind,
    /// `sublayers`.
    pub sublayers: Vec<LayerNode>,
    /// `mask`.
    pub mask: Option<Box<LayerNode>>,
}

/// One redraw `refresh` asks for.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind", content = "id")]
pub enum Refresh {
    /// `label.needsDisplay = true`.
    Label(String),
    /// `text.smoothingDidChange()`.
    TextLayer(String),
}

/// `refresh(_:)`: a label redraws and its sublayers and mask are still walked; a text layer
/// redraws and stops; any other layer is walked through (sublayers first, then the mask).
pub fn refresh(node: &LayerNode) -> Vec<Refresh> {
    let mut out = Vec::new();
    walk(node, &mut out);
    out
}

fn walk(node: &LayerNode, out: &mut Vec<Refresh>) {
    match node.kind {
        LayerKind::Label => out.push(Refresh::Label(node.id.clone())),
        LayerKind::TextLayer => {
            out.push(Refresh::TextLayer(node.id.clone()));
            return;
        }
        LayerKind::Other => {}
    }
    for sub in &node.sublayers {
        walk(sub, out);
    }
    if let Some(mask) = &node.mask {
        walk(mask, out);
    }
}
