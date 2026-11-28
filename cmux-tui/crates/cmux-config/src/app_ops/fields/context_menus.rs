//! Swift `ContextMenusSetting`: the person's right-click menu arrangements (`contextMenus.*`).

use serde_json::{Map, Value, json};

use super::super::OpError;
use super::reader::{invalid, value_at};

/// The deepest submenu nesting and the most entries a layout may hold.
const MAX_DEPTH: usize = 8;
const MAX_ENTRIES: usize = 2_000;
const SEPARATOR: &str = "-";
const MORE_KEY: &str = "folder:more";

struct Count(usize);

fn keys(list: Option<&Value>, count: &mut Count) -> Option<Vec<String>> {
    let items = list?.as_array()?;
    let keys: Vec<String> = items.iter().filter_map(|v| v.as_str().map(String::from)).collect();
    count.0 += keys.len();
    (keys.len() == items.len() && count.0 <= MAX_ENTRIES).then_some(keys)
}

fn nodes(list: Option<&Value>, depth: usize, count: &mut Count) -> Option<Vec<Value>> {
    if depth > MAX_DEPTH {
        return None;
    }
    let mut result = Vec::new();
    for item in list?.as_array()? {
        count.0 += 1;
        if count.0 > MAX_ENTRIES {
            return None;
        }
        if let Some(key) = item.as_str() {
            result.push(json!(key));
        } else if let Some(key) = item.get("key").and_then(Value::as_str) {
            let empty = json!([]);
            let children = nodes(Some(item.get("items").unwrap_or(&empty)), depth + 1, count)?;
            let title = item.get("title").and_then(Value::as_str);
            if key.starts_with("group:") && title.is_none() {
                return None;
            }
            let mut folder = Map::new();
            folder.insert("key".into(), json!(key));
            folder.insert("items".into(), Value::Array(children));
            if let Some(title) = title {
                folder.insert("title".into(), json!(title));
            }
            result.push(Value::Object(folder));
        } else {
            return None;
        }
    }
    Some(result)
}

fn node_key(node: &Value) -> Option<&str> {
    node.as_str().filter(|key| *key != SEPARATOR).or_else(|| node.get("key")?.as_str())
}

/// A layout object: `items` (a tree) and `hidden` keys, or the first shape (`top` and `more`).
/// `None` for anything else.
#[allow(
    clippy::indexing_slicing,
    reason = "positions come from the value's own length or search, so they are in range"
)]
pub(crate) fn layout(value: &Value) -> Option<Value> {
    value.as_object()?;
    let mut count = Count(0);
    let hidden =
        if value.get("hidden").is_none() { vec![] } else { keys(value.get("hidden"), &mut count)? };
    if value.get("items").is_some() {
        let items = nodes(value.get("items"), 0, &mut count)?;
        return Some(json!({"items": items, "hidden": hidden}));
    }
    let top = keys(value.get("top"), &mut count)?;
    let more =
        if value.get("more").is_none() { vec![] } else { keys(value.get("more"), &mut count)? };
    let mut items: Vec<Value> =
        top.iter()
            .map(|key| {
                if key.starts_with("folder:") {
                    json!({"key": key, "items": []})
                } else {
                    json!(key)
                }
            })
            .collect();
    if !more.is_empty() {
        let mut moved: Vec<Value> = more.iter().map(|k| json!(k)).collect();
        moved.push(json!(SEPARATOR));
        let folder = json!({"key": MORE_KEY, "items": moved});
        match items.iter().position(|n| node_key(n) == Some(MORE_KEY)) {
            Some(at) => items[at] = folder,
            None => {
                items.push(json!(SEPARATOR));
                items.push(folder);
            }
        }
    }
    Some(json!({"items": items, "hidden": hidden}))
}

pub(super) fn op(request: &Value) -> Result<Value, OpError> {
    let root = request.get("root").ok_or_else(|| OpError::Invalid("expected `root`".into()))?;
    let contexts: Vec<&str> = request
        .get("contexts")
        .and_then(Value::as_array)
        .ok_or_else(|| OpError::Invalid("expected `contexts`".into()))?
        .iter()
        .filter_map(Value::as_str)
        .collect();
    let mut diags = Vec::new();
    let mut show = json!(false);
    if let Some(value) = value_at(root, &["contextMenus", "showCustomizeItem"]) {
        if value.is_boolean() {
            show = value.clone();
        } else {
            diags.push(invalid("contextMenus.showCustomizeItem", "expected true or false"));
        }
    }
    let mut layouts = Map::new();
    if let Some(value) = value_at(root, &["contextMenus", "layouts"]) {
        let id = "contextMenus.layouts";
        match value.as_object() {
            None => diags.push(invalid(id, "expected an object of menu layouts")),
            Some(members) => {
                for (name, value) in members {
                    if !contexts.contains(&name.as_str()) {
                        diags.push(invalid(
                            format!("{id}.{name}"),
                            "no right-click menu with this name",
                        ));
                        continue;
                    }
                    match layout(value) {
                        Some(layout) => {
                            layouts.insert(name.clone(), layout);
                        }
                        None => diags.push(invalid(
                            format!("{id}.{name}"),
                            "expected {\"items\": [...], \"hidden\": [...]}: row keys, \"-\" and {\"key\", \"title\", \"items\"} submenus",
                        )),
                    }
                }
            }
        }
    }
    Ok(json!({"showCustomizeItem": show, "layouts": layouts, "diagnostics": diags}))
}
