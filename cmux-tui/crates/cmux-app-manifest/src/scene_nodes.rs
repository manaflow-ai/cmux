//! The scene's node vocabulary (`js/ABI.md` "Node types") and the typed props of the Instrument kit
//! nodes, `Tooltip`, `Pill` and `Card`: the one validator the app host runs on every scene batch and
//! the manifest checks run on every interface's `nodes` list.
//!
//! The kit nodes are drawn by the Instrument kit (`webviews/src/kit`: `Tooltip`, `Pill`, `Card`); the
//! logic of what each accepts lives here. [`TypedNodes::sanitize`] leaves a valid prop in its
//! canonical form (a scene tone alias mapped onto the kit's tone, a number as its text) and an
//! invalid one as `null`, with a log line naming the node and the prop, so every renderer reads the
//! same values. It depends on `serde_json` only: `cmux-app-host` compiles this same file
//! (`#[path]`) to run it in the VM's scene callback.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Map, Value};

/// Every node type a scene may create, in the ABI's order. An interface's `nodes` list names only
/// these (`interfaces::tests`).
pub const SCENE_NODES: &[&str] = &[
    "VStack",
    "HStack",
    "ZStack",
    "LazyVStack",
    "Group",
    "ForEach",
    "Reorderable",
    "Text",
    "Icon",
    "Image",
    "Button",
    "Menu",
    "Spacer",
    "Divider",
    "Circle",
    "Capsule",
    "Rectangle",
    "RoundedRectangle",
    "Line",
    "ProgressView",
    "TextField",
    "Row",
    "Badge",
    "EmptyState",
    "Toggle",
    "Slider",
    "Panel",
    "Particles",
    "Tooltip",
    "Pill",
    "Card",
];

/// The kit nodes whose props [`TypedNodes`] checks.
pub const KIT_NODES: &[&str] = &["Tooltip", "Pill", "Card"];

/// `Pill` tones, the kit's (`kit/Pill.tsx` `PillTone`); the first is the default.
pub const PILL_TONES: &[&str] = &["neutral", "accent", "success", "attention", "danger"];
/// Scene tone names a `Pill` also takes, as the kit tone each one draws.
pub const PILL_TONE_ALIASES: &[(&str, &str)] = &[
    ("secondary", "neutral"),
    ("primary", "neutral"),
    ("tertiary", "neutral"),
    ("warning", "attention"),
];
/// `Pill` sizes (`kit/Pill.tsx` `PillSize`: sm 20, md 24); the first is the default.
pub const PILL_SIZES: &[&str] = &["md", "sm"];
/// `Tooltip` sides (`ui/Tooltip.tsx`); the first is the default.
pub const TOOLTIP_SIDES: &[&str] = &["bottom", "top"];
/// `Card` sides (`ui/Tooltip.tsx` `AnchoredCard`); the first is the default.
pub const CARD_SIDES: &[&str] = &["bottom", "top", "inline-end", "inline-start"];

/// Longest `Pill` text, in characters (a count, a tag, a short state).
pub const MAX_PILL_CHARS: usize = 64;
/// Longest `Tooltip` text or detail, in characters.
pub const MAX_TOOLTIP_CHARS: usize = 512;
/// Longest `Tooltip` shortcut, in characters (`⌘⇧T`).
pub const MAX_SHORTCUT_CHARS: usize = 16;

/// Whether `name` is a scene node type.
pub fn is_scene_node(name: &str) -> bool {
    SCENE_NODES.contains(&name)
}

/// The canonical value of a kit node's prop: `None` when `node` has no such typed prop (it passes
/// as it is), `Some(Ok(v))` for a valid one and `Some(Err(why))` for an invalid one.
pub fn normalize_prop(node: &str, key: &str, value: &Value) -> Option<Result<Value, String>> {
    match (node, key) {
        ("Pill", "text") => Some(text(value, MAX_PILL_CHARS)),
        ("Pill", "tone") => Some(pill_tone(value)),
        ("Pill", "size") => Some(one_of(value, PILL_SIZES)),
        ("Tooltip", "text") => Some(text(value, MAX_TOOLTIP_CHARS).and_then(non_empty)),
        ("Tooltip", "detail") => Some(text(value, MAX_TOOLTIP_CHARS)),
        ("Tooltip", "shortcut") => Some(text(value, MAX_SHORTCUT_CHARS)),
        ("Tooltip", "side") => Some(one_of(value, TOOLTIP_SIDES)),
        ("Card", "side") => Some(one_of(value, CARD_SIDES)),
        _ => None,
    }
}

fn text(value: &Value, max: usize) -> Result<Value, String> {
    let text = match value {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        _ => return Err("is a string".to_string()),
    };
    if text.chars().count() > max {
        return Err(format!("is at most {max} characters"));
    }
    Ok(Value::String(text))
}

fn non_empty(value: Value) -> Result<Value, String> {
    if value.as_str().is_some_and(|s| s.trim().is_empty()) {
        Err("is not empty".to_string())
    } else {
        Ok(value)
    }
}

fn one_of(value: &Value, table: &[&str]) -> Result<Value, String> {
    match value.as_str() {
        Some(s) if table.contains(&s) => Ok(Value::String(s.to_string())),
        _ => Err(format!("is one of {}", table.join(", "))),
    }
}

fn pill_tone(value: &Value) -> Result<Value, String> {
    let alias = value.as_str().and_then(|s| PILL_TONE_ALIASES.iter().find(|(from, _)| *from == s));
    match alias {
        Some((_, to)) => Ok(Value::String((*to).to_string())),
        None => one_of(value, PILL_TONES),
    }
}

/// The kit nodes of one VM's mounted scenes, by mount and node id: an `update` op names no type, so
/// the batch that created a node tells the later ones which props to check.
#[derive(Debug, Default)]
pub struct TypedNodes {
    mounts: BTreeMap<String, BTreeMap<String, TrackedNode>>,
}

/// Untyped ancestors matter too: the scene ABI removes an entire subtree with one op.
#[derive(Debug, Default)]
struct TrackedNode {
    kind: Option<&'static str>,
    parent: Option<String>,
    children: BTreeSet<String>,
}

// Match webviews/src/apps/scene/store.ts. Tracking a rejected op would make a later removal
// erase validation for nodes the renderer still owns under their previous parent.
const MAX_SCENE_NODES: usize = 4096;
const MAX_SCENE_DEPTH: usize = 64;

fn remove_subtree(nodes: &mut BTreeMap<String, TrackedNode>, id: &str) {
    let parent = nodes.get(id).and_then(|node| node.parent.clone());
    if let Some(parent) = parent.and_then(|parent| nodes.get_mut(&parent)) {
        parent.children.remove(id);
    }
    let mut pending = vec![id.to_string()];
    while let Some(id) = pending.pop() {
        if let Some(node) = nodes.remove(&id) {
            pending.extend(node.children);
        }
    }
}

fn replace_children(nodes: &mut BTreeMap<String, TrackedNode>, id: &str, children: &[Value]) {
    if !nodes.contains_key(id) {
        return;
    }
    // Match the scene store: ignore missing nodes, duplicates, self-links and ancestors.
    let mut ancestors = BTreeSet::from([id.to_string()]);
    let mut current = nodes.get(id).and_then(|node| node.parent.as_deref());
    while let Some(parent) = current {
        if !ancestors.insert(parent.to_string()) {
            break;
        }
        current = nodes.get(parent).and_then(|node| node.parent.as_deref());
    }
    let children: BTreeSet<String> = children
        .iter()
        .filter_map(Value::as_str)
        .filter(|child| nodes.contains_key(*child) && !ancestors.contains(*child))
        .map(str::to_string)
        .collect();
    // Check depth(parent) + height(child) before detaching anything. Walk only the candidate
    // subtrees, bounded by the scene's node/depth limits; shared candidates need no revisit at
    // an equal or shallower depth. The scene root counts as depth one, not zero.
    let mut pending: Vec<_> =
        children.iter().map(|child| (child.as_str(), ancestors.len() + 1)).collect();
    let mut visited = BTreeMap::new();
    while let Some((child, depth)) = pending.pop() {
        if depth > MAX_SCENE_DEPTH {
            return;
        }
        if visited.get(child).is_some_and(|previous| *previous >= depth) {
            continue;
        }
        visited.insert(child, depth);
        if let Some(node) = nodes.get(child) {
            pending.extend(node.children.iter().map(|child| (child.as_str(), depth + 1)));
        }
    }
    let previous = std::mem::take(&mut nodes.get_mut(id).unwrap().children);
    for child in previous {
        if let Some(node) = nodes.get_mut(&child) {
            node.parent = None;
        }
    }
    for child in &children {
        let previous = nodes.get_mut(child).unwrap().parent.replace(id.to_string());
        if let Some(parent) = previous.and_then(|parent| nodes.get_mut(&parent)) {
            parent.children.remove(child);
        }
    }
    nodes.get_mut(id).unwrap().children = children;
}

impl TypedNodes {
    /// Checks the kit nodes' props in one scene batch of `mount` in place; returns a log line per
    /// refused prop. Other nodes and props pass untouched.
    pub fn sanitize(&mut self, mount: &str, ops: &mut Value) -> Vec<String> {
        let mut refused = Vec::new();
        let Some(list) = ops.as_array_mut() else { return refused };
        let nodes = self.mounts.entry(mount.to_string()).or_default();
        for op in list {
            let Some(object) = op.as_object_mut() else { continue };
            let Some(id) = object.get("id").and_then(Value::as_str).filter(|id| !id.is_empty())
            else {
                continue;
            };
            let id = id.to_string();
            match object.get("op").and_then(Value::as_str) {
                Some("create") => {
                    if nodes.contains_key(&id) || nodes.len() >= MAX_SCENE_NODES {
                        continue;
                    }
                    let kind = object.get("type").and_then(Value::as_str);
                    nodes.entry(id.clone()).or_insert_with(|| TrackedNode {
                        kind: kind.and_then(|k| KIT_NODES.iter().copied().find(|n| *n == k)),
                        ..TrackedNode::default()
                    });
                }
                Some("children") => {
                    if let Some(children) = object.get("children").and_then(Value::as_array) {
                        replace_children(nodes, &id, children);
                    }
                    continue;
                }
                Some("remove") => {
                    remove_subtree(nodes, &id);
                    continue;
                }
                _ => {}
            }
            let Some(node) = nodes.get(&id).and_then(|node| node.kind) else { continue };
            if let Some(props) = object.get_mut("props").and_then(Value::as_object_mut) {
                sanitize_props(node, &id, props, &mut refused);
            }
        }
        if nodes.is_empty() {
            self.mounts.remove(mount);
        }
        refused
    }

    /// Forgets a mount's nodes (its unmount).
    pub fn forget(&mut self, mount: &str) {
        self.mounts.remove(mount);
    }
}

fn sanitize_props(node: &str, id: &str, props: &mut Map<String, Value>, refused: &mut Vec<String>) {
    for (key, value) in props.iter_mut() {
        if value.is_null() {
            continue;
        }
        match normalize_prop(node, key, value) {
            None => {}
            Some(Ok(canonical)) => *value = canonical,
            Some(Err(why)) => {
                refused.push(format!("{node} {id}: {key} refused: {why}"));
                *value = Value::Null;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_pill_takes_kit_tones_and_scene_aliases() {
        let mut nodes = TypedNodes::default();
        let mut ops = json!([
            {"op": "create", "id": "a", "type": "Pill", "props": {"text": 3, "tone": "warning", "size": "sm"}},
            {"op": "create", "id": "b", "type": "Pill", "props": {"text": "x", "tone": "blue", "size": "lg"}},
        ]);
        let refused = nodes.sanitize("m", &mut ops);
        assert_eq!(ops[0]["props"], json!({"text": "3", "tone": "attention", "size": "sm"}));
        assert_eq!(ops[1]["props"], json!({"text": "x", "tone": null, "size": null}));
        assert_eq!(refused.len(), 2);
        assert!(refused.iter().any(|line| line.starts_with("Pill b: tone refused")), "{refused:?}");
        assert!(refused.iter().any(|line| line.starts_with("Pill b: size refused")), "{refused:?}");
    }

    #[test]
    fn an_update_is_checked_by_the_type_its_create_named() {
        let mut nodes = TypedNodes::default();
        nodes.sanitize(
            "m",
            &mut json!([{"op": "create", "id": "t", "type": "Tooltip", "props": {"text": "Open"}}]),
        );
        let mut update =
            json!([{"op": "update", "id": "t", "props": {"side": "left", "text": ""}}]);
        assert_eq!(nodes.sanitize("m", &mut update).len(), 2);
        assert_eq!(update[0]["props"], json!({"side": null, "text": null}));
        // Another mount's node of the same id, and a Badge's tone, pass as they are.
        let mut other = json!([
            {"op": "update", "id": "t", "props": {"side": "left"}},
            {"op": "create", "id": "b", "type": "Badge", "props": {"tone": "blue"}},
        ]);
        assert!(nodes.sanitize("n", &mut other).is_empty());
        assert_eq!(other[0]["props"]["side"], "left");
        nodes.sanitize("m", &mut json!([{"op": "remove", "id": "t"}]));
        let mut after = json!([{"op": "update", "id": "t", "props": {"side": "left"}}]);
        assert!(nodes.sanitize("m", &mut after).is_empty());
    }

    #[test]
    fn a_card_side_and_long_text_are_bounded() {
        let mut nodes = TypedNodes::default();
        let long = "x".repeat(MAX_TOOLTIP_CHARS + 1);
        let mut ops = json!([
            {"op": "create", "id": "c", "type": "Card", "props": {"side": "inline-end"}},
            {"op": "create", "id": "t", "type": "Tooltip", "props": {"text": long, "shortcut": "⌘T"}},
        ]);
        let refused = nodes.sanitize("m", &mut ops);
        assert_eq!(ops[0]["props"]["side"], "inline-end");
        assert_eq!(ops[1]["props"], json!({"text": null, "shortcut": "⌘T"}));
        assert_eq!(refused.len(), 1);
        nodes.forget("m");
        assert!(nodes.mounts.is_empty());
    }

    #[test]
    fn repeated_dynamic_subtree_removals_release_nodes_and_edges() {
        let mut nodes = TypedNodes::default();
        nodes.sanitize("m", &mut json!([{"op": "create", "id": "root", "type": "Group"}]));
        for generation in 0..256 {
            let row = format!("row-{generation}");
            let tooltip = format!("tooltip-{generation}");
            let pill = format!("pill-{generation}");
            nodes.sanitize(
                "m",
                &mut json!([
                    {"op": "create", "id": row, "type": "Row"},
                    {"op": "create", "id": tooltip, "type": "Tooltip"},
                    {"op": "create", "id": pill, "type": "Pill"},
                    {"op": "children", "id": tooltip, "children": [pill]},
                    {"op": "children", "id": row, "children": [tooltip]},
                    {"op": "children", "id": "root", "children": [row]},
                    {"op": "remove", "id": row}
                ]),
            );
            let scene = &nodes.mounts["m"];
            assert_eq!(scene.len(), 1, "generation {generation}");
            assert!(scene["root"].children.is_empty());
            let mut update = json!([
                {"op": "update", "id": pill, "props": {"tone": "invalid"}},
                {"op": "update", "id": tooltip, "props": {"side": "invalid"}}
            ]);
            assert!(nodes.sanitize("m", &mut update).is_empty());
        }
        nodes.sanitize("m", &mut json!([{"op": "remove", "id": "root"}]));
        assert!(nodes.mounts.is_empty());
    }

    #[test]
    fn replacing_children_detaches_without_deleting_the_old_children() {
        let mut nodes = TypedNodes::default();
        nodes.sanitize(
            "m",
            &mut json!([
                {"op": "create", "id": "row", "type": "Row"},
                {"op": "create", "id": "old", "type": "Pill"},
                {"op": "create", "id": "new", "type": "Pill"},
                {"op": "children", "id": "row", "children": ["old"]},
                {"op": "children", "id": "row", "children": ["new"]},
                {"op": "remove", "id": "row"}
            ]),
        );
        assert_eq!(nodes.mounts["m"].len(), 1);
        assert!(nodes.mounts["m"]["old"].parent.is_none());
        let mut update = json!([
            {"op": "update", "id": "old", "props": {"tone": "warning"}},
            {"op": "update", "id": "new", "props": {"tone": "warning"}}
        ]);
        assert!(nodes.sanitize("m", &mut update).is_empty());
        assert_eq!(update[0]["props"]["tone"], "attention");
        assert_eq!(update[1]["props"]["tone"], "warning");
        nodes.sanitize("m", &mut json!([{"op": "remove", "id": "old"}]));
        assert!(nodes.mounts.is_empty());
    }

    #[test]
    fn moving_a_typed_subtree_detaches_it_from_its_previous_parent() {
        let mut nodes = TypedNodes::default();
        nodes.sanitize(
            "m",
            &mut json!([
                {"op": "create", "id": "a", "type": "Row"},
                {"op": "create", "id": "b", "type": "Row"},
                {"op": "create", "id": "card", "type": "Card"},
                {"op": "create", "id": "pill", "type": "Pill"},
                {"op": "children", "id": "card", "children": ["pill"]},
                {"op": "children", "id": "a", "children": ["card"]},
                {"op": "children", "id": "b", "children": ["card"]}
            ]),
        );
        assert!(nodes.mounts["m"]["a"].children.is_empty());
        nodes.sanitize("m", &mut json!([{"op": "remove", "id": "a"}]));
        let mut update = json!([
            {"op": "update", "id": "card", "props": {"side": "invalid"}},
            {"op": "update", "id": "pill", "props": {"tone": "invalid"}}
        ]);
        assert_eq!(nodes.sanitize("m", &mut update).len(), 2);
        nodes.sanitize("m", &mut json!([{"op": "remove", "id": "b"}]));
        assert!(nodes.mounts.is_empty());
    }

    #[test]
    fn subtree_removal_and_forget_are_isolated_to_their_mount() {
        let mut nodes = TypedNodes::default();
        for mount in ["a", "b"] {
            nodes.sanitize(
                mount,
                &mut json!([
                    {"op": "create", "id": "row", "type": "Row"},
                    {"op": "create", "id": "pill", "type": "Pill"},
                    {"op": "children", "id": "row", "children": ["pill"]}
                ]),
            );
        }
        nodes.sanitize("a", &mut json!([{"op": "remove", "id": "row"}]));
        assert!(!nodes.mounts.contains_key("a"));
        let mut update = json!([{"op": "update", "id": "pill", "props": {"tone": "invalid"}}]);
        assert_eq!(nodes.sanitize("b", &mut update).len(), 1);
        assert_eq!(nodes.mounts["b"].len(), 2);
        nodes.forget("b");
        assert!(nodes.mounts.is_empty());
        nodes.sanitize(
            "b",
            &mut json!([
                {"op": "create", "id": "row", "type": "Row"},
                {"op": "create", "id": "pill", "type": "Pill"},
                {"op": "remove", "id": "row"}
            ]),
        );
        assert_eq!(nodes.mounts["b"].len(), 1, "forget must not retain the old edge");
    }

    #[test]
    fn refused_depth_move_preserves_the_previous_parent_and_the_limit_is_inclusive() {
        let mut nodes = TypedNodes::default();
        nodes.sanitize(
            "m",
            &mut json!([
                {"op": "create", "id": "old", "type": "Row"},
                {"op": "create", "id": "pill", "type": "Pill"},
                {"op": "children", "id": "old", "children": ["pill"]}
            ]),
        );
        // A chain with root depth one: moving the pill to its last node would make depth 65.
        for index in 0..MAX_SCENE_DEPTH {
            nodes.sanitize(
                "m",
                &mut json!([
                    {"op": "create", "id": format!("n{index}"), "type": "Row"}
                ]),
            );
            if index > 0 {
                nodes.sanitize("m", &mut json!([
                    {"op": "children", "id": format!("n{}", index - 1), "children": [format!("n{index}")]}
                ]));
            }
        }
        // The subtree root would fit at 64, but its pill would be at 65: reject the whole op.
        nodes.sanitize(
            "m",
            &mut json!([
                {"op": "children", "id": "n62", "children": ["old"]}
            ]),
        );
        assert!(nodes.mounts["m"]["old"].parent.is_none());
        assert!(nodes.mounts["m"]["n62"].children.contains("n63"));
        nodes.sanitize(
            "m",
            &mut json!([
                {"op": "children", "id": "n63", "children": ["pill"]},
                {"op": "remove", "id": "n63"}
            ]),
        );
        assert_eq!(nodes.mounts["m"]["pill"].parent.as_deref(), Some("old"));
        let mut update = json!([{"op": "update", "id": "pill", "props": {"tone": "invalid"}}]);
        assert_eq!(nodes.sanitize("m", &mut update).len(), 1);
        // Depth 64 is accepted, and removing the former owner must now preserve the pill.
        nodes.sanitize(
            "m",
            &mut json!([
                {"op": "children", "id": "n62", "children": ["pill"]},
                {"op": "remove", "id": "old"}
            ]),
        );
        assert_eq!(nodes.mounts["m"]["pill"].parent.as_deref(), Some("n62"));
        let mut update = json!([{"op": "update", "id": "pill", "props": {"tone": "invalid"}}]);
        assert_eq!(nodes.sanitize("m", &mut update).len(), 1);
        nodes.sanitize("m", &mut json!([{"op": "remove", "id": "n0"}]));
        assert!(nodes.mounts.is_empty());
    }

    #[test]
    fn node_limit_accepts_the_boundary_and_never_tracks_a_refused_create() {
        let mut nodes = TypedNodes::default();
        let mut creates = Value::Array(
            (0..=MAX_SCENE_NODES)
                .map(|index| {
                    json!({
                        "op": "create", "id": format!("n{index}"), "type": "Pill"
                    })
                })
                .collect(),
        );
        nodes.sanitize("m", &mut creates);
        assert_eq!(nodes.mounts["m"].len(), MAX_SCENE_NODES);
        let mut update = json!([
            {"op": "update", "id": "n4095", "props": {"tone": "warning"}},
            {"op": "update", "id": "n4096", "props": {"tone": "warning"}}
        ]);
        assert!(nodes.sanitize("m", &mut update).is_empty());
        assert_eq!(update[0]["props"]["tone"], "attention");
        assert_eq!(update[1]["props"]["tone"], "warning");
        let mut reuse = json!([
            {"op": "remove", "id": "n0"},
            {"op": "create", "id": "n4096", "type": "Pill", "props": {"tone": "warning"}}
        ]);
        assert!(nodes.sanitize("m", &mut reuse).is_empty());
        assert_eq!(reuse[1]["props"]["tone"], "attention");
        assert_eq!(nodes.mounts["m"].len(), MAX_SCENE_NODES);
    }

    #[test]
    fn the_kit_nodes_are_scene_nodes() {
        for node in KIT_NODES {
            assert!(is_scene_node(node));
        }
    }
}
