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

use std::collections::BTreeMap;

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
    types: BTreeMap<(String, String), &'static str>,
}

impl TypedNodes {
    /// Checks the kit nodes' props in one scene batch of `mount` in place; returns a log line per
    /// refused prop. Other nodes and props pass untouched.
    pub fn sanitize(&mut self, mount: &str, ops: &mut Value) -> Vec<String> {
        let mut refused = Vec::new();
        let Some(list) = ops.as_array_mut() else { return refused };
        for op in list {
            let Some(object) = op.as_object_mut() else { continue };
            let id = object.get("id").and_then(Value::as_str).unwrap_or("?").to_string();
            let key = (mount.to_string(), id.clone());
            match object.get("op").and_then(Value::as_str) {
                Some("create") => {
                    let kind = object.get("type").and_then(Value::as_str);
                    match kind.and_then(|k| KIT_NODES.iter().copied().find(|n| *n == k)) {
                        Some(node) => {
                            self.types.insert(key.clone(), node);
                        }
                        None => {
                            self.types.remove(&key);
                        }
                    }
                }
                Some("remove") => {
                    self.types.remove(&key);
                    continue;
                }
                _ => {}
            }
            let Some(node) = self.types.get(&key).copied() else { continue };
            if let Some(props) = object.get_mut("props").and_then(Value::as_object_mut) {
                sanitize_props(node, &id, props, &mut refused);
            }
        }
        refused
    }

    /// Forgets a mount's nodes (its unmount).
    pub fn forget(&mut self, mount: &str) {
        self.types.retain(|(m, _), _| m != mount);
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
        assert!(nodes.types.is_empty());
    }

    #[test]
    fn the_kit_nodes_are_scene_nodes() {
        for node in KIT_NODES {
            assert!(is_scene_node(node));
        }
    }
}
