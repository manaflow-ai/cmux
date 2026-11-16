//! The text outline of a view's first scene: what `ext dev --once` and
//! `ext shot` show an author (or an agent) of what their script rendered,
//! without a window.
//!
//! A mount's scene arrives as op batches (`cmux-app-host/js/src/materialize.ts`:
//! `create`, `update`, `children`, `remove`, `root`). The outline applies them
//! and prints the tree from the root, one node per line, indented by depth:
//! the node type, then the props a person reads (`title`, `text`, `label`,
//! ...) and the `tint` and `icon` that say how it looks.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Map, Value};

use super::Field as _;

/// Lines the outline prints at most; past it one line says how many more.
pub(super) const MAX_LINES: usize = 200;

/// Depth past which the outline stops descending (the runtime's own cap).
const MAX_DEPTH: usize = 64;

/// Props shown in quotes, in this order: the words on screen.
const WORDS: [&str; 7] = ["title", "text", "label", "subtitle", "message", "value", "placeholder"];

/// Props shown as `name=value`: how the node looks or acts.
const LOOKS: [&str; 6] = ["icon", "tint", "tone", "font", "style", "count"];

/// A quoted prop is cut to this many characters.
const MAX_WORDS: usize = 80;

struct Node {
    kind: String,
    props: Map<String, Value>,
    children: Vec<String>,
}

/// The scene the op batches `batches` build: its root and its nodes.
fn apply(batches: &[&Value]) -> (Option<String>, BTreeMap<String, Node>) {
    let mut nodes: BTreeMap<String, Node> = BTreeMap::new();
    let mut root = None;
    for op in batches.iter().flat_map(|batch| batch.as_array().into_iter().flatten()) {
        let Some(id) = op.field("id").as_str().map(str::to_string) else { continue };
        match op.field("op").as_str().unwrap_or("") {
            "create" => {
                let node = Node {
                    kind: op.field("type").as_str().unwrap_or("?").to_string(),
                    props: op.field("props").as_object().cloned().unwrap_or_default(),
                    children: Vec::new(),
                };
                nodes.insert(id, node);
            }
            "update" => {
                if let Some(node) = nodes.get_mut(&id) {
                    for (key, value) in op.field("props").as_object().into_iter().flatten() {
                        if value.is_null() {
                            node.props.remove(key);
                        } else {
                            node.props.insert(key.clone(), value.clone());
                        }
                    }
                }
            }
            "children" => {
                if let Some(node) = nodes.get_mut(&id) {
                    node.children = op
                        .field("children")
                        .as_array()
                        .into_iter()
                        .flatten()
                        .filter_map(|child| child.as_str().map(str::to_string))
                        .collect();
                }
            }
            "remove" => {
                nodes.remove(&id);
            }
            "root" => root = Some(id),
            _ => {}
        }
    }
    (root, nodes)
}

/// One node's line, without its indent.
fn line(node: &Node) -> String {
    let mut text = node.kind.clone();
    for key in WORDS {
        if let Some(words) = node.props.get(key).and_then(Value::as_str) {
            let words: String = words.split_whitespace().collect::<Vec<_>>().join(" ");
            let cut: String = words.chars().take(MAX_WORDS).collect();
            let ellipsis = if cut.len() < words.len() { "…" } else { "" };
            text.push_str(&format!(" {key}={:?}", format!("{cut}{ellipsis}")));
        }
    }
    for key in LOOKS {
        match node.props.get(key) {
            Some(Value::String(value)) => text.push_str(&format!(" {key}={value}")),
            Some(value @ (Value::Number(_) | Value::Bool(_))) => {
                text.push_str(&format!(" {key}={value}"));
            }
            _ => {}
        }
    }
    text
}

/// The outline of the scene `batches` build, one line per node from the
/// root, two spaces per level. Empty when the batches name no root.
pub(super) fn outline(batches: &[&Value]) -> Vec<String> {
    let (root, nodes) = apply(batches);
    let Some(root) = root else { return Vec::new() };
    let mut lines = Vec::new();
    let mut more = 0usize;
    // Each node once, however many parents name it: the walk is at most the scene's size.
    let mut seen = BTreeSet::new();
    // Depth first, children in order: a stack of (id, depth), last child pushed first.
    let mut stack = vec![(root, 0usize)];
    while let Some((id, depth)) = stack.pop() {
        let Some(node) = nodes.get(&id) else { continue };
        if !seen.insert(id) {
            continue;
        }
        if lines.len() >= MAX_LINES {
            more += 1;
        } else {
            lines.push(format!("{}{}", "  ".repeat(depth), line(node)));
        }
        if depth < MAX_DEPTH {
            stack.extend(node.children.iter().rev().map(|child| (child.clone(), depth + 1)));
        }
    }
    if more > 0 {
        lines.push(format!("… {more} more"));
    }
    lines
}
