//! A tab's frame tree as `frames.list` reports it (`FrameTree`, `FrameRecord`).
//!
//! The app reads WebKit's tree (`-[WKWebView _frames:]`) into [`FrameNode`]s; the flattening
//! here gives parents before children, in document order. A node without a frame id (no
//! `_handle` SPI) is dropped with its subtree, as the Swift walk stops there.

use serde::{Deserialize, Serialize};

/// One node of WebKit's frame tree.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FrameNode {
    /// WebKit's frame handle id, or None when it could not be read.
    #[serde(default)]
    pub frame_id: Option<String>,
    /// The frame's request URL, empty when none.
    #[serde(default)]
    pub url: String,
    /// The child frames, in document order.
    #[serde(default)]
    pub children: Vec<FrameNode>,
}

/// One frame of a tab.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FrameRecord {
    pub frame_id: String,
    pub parent_frame_id: Option<String>,
    pub url: String,
    /// True for the main frame, the one without a parent.
    pub is_main: bool,
}

/// The frames under `root`, parents before children, in document order.
pub fn flatten(root: &FrameNode) -> Vec<FrameRecord> {
    let mut out = Vec::new();
    walk(root, None, &mut out);
    out
}

fn walk(node: &FrameNode, parent: Option<&str>, out: &mut Vec<FrameRecord>) {
    let Some(id) = node.frame_id.as_deref() else { return };
    out.push(FrameRecord {
        frame_id: id.to_owned(),
        parent_frame_id: parent.map(str::to_owned),
        url: node.url.clone(),
        is_main: parent.is_none(),
    });
    for child in &node.children {
        walk(child, Some(id), out);
    }
}
