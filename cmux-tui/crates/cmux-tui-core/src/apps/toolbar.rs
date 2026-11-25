//! `contributes.toolbarItems` (titlebar-area.md 3, app-platform.md 17): the
//! buttons and menu buttons installed apps add to the window's top-left
//! toolbar band, after the built-in sidebar toggle, Back and Forward. The
//! daemon resolves which apps contribute and serves them as one list
//! (`apps.toolbar.list`); the Mac only draws that list and runs a click's op
//! through `apps-run` as the person.
//!
//! Each call reads the live catalog, so a save of an installed local app's
//! manifest changes the next answer: the local reload (`local_reload.rs`)
//! swaps the catalog and broadcasts `apps-changed`, on which the Mac lists
//! again. Only installed, enabled and visible apps contribute, none in safe
//! mode. Nothing shows unless an app contributes.
//!
//! Not listed: `view` items (a slot the app's page renders, not drawn yet),
//! items with `overrides` (an alternative for a built-in item the person
//! picks in Settings, never applied silently), and actions that are not one
//! of the app's own catalog ops (`apps-run` runs only those).

use serde::Serialize;
use serde_json::{Value, json};

use super::supervisor::{Inner, Supervisor};

/// The most items `apps.toolbar.list` answers, over every app (each app has
/// at most 4, `cmux-app.schema.json`).
const MAX_ITEMS: usize = 16;
/// Where an item with no `order` sorts among app items (the schema's range is 0 to 1000).
const DEFAULT_ORDER: u64 = 500;

#[derive(Debug, Serialize)]
struct Entry {
    /// The manifest's text (a string or a locale map); the Mac resolves its locale.
    title: Value,
    op: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    args: Option<Value>,
}

#[derive(Debug, Serialize)]
struct Item {
    app: String,
    /// The app's name, which the button's tooltip names as its source.
    extension: String,
    id: String,
    /// `button` (runs `op`) or `menu` (opens `entries`).
    kind: &'static str,
    title: Value,
    /// An SF Symbol name (`icon.symbol`).
    #[serde(skip_serializing_if = "Option::is_none")]
    symbol: Option<String>,
    /// A package-relative image path (`icon` as a path).
    #[serde(skip_serializing_if = "Option::is_none")]
    icon: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    op: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    args: Option<Value>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    entries: Vec<Entry>,
    order: u64,
}

/// `action` as `(op, args)` when it names one of the app's own catalog ops.
fn own_op(action: &Value, family: &str) -> Option<(String, Option<Value>)> {
    let op = action.get("op")?.as_str()?;
    let rest = op.strip_prefix(family)?.strip_prefix('.')?;
    if family.is_empty() || rest.is_empty() {
        return None;
    }
    Some((op.to_string(), action.get("args").filter(|a| a.is_object()).cloned()))
}

fn items(inner: &Inner) -> Vec<Item> {
    if inner.safe_mode.is_some() {
        return Vec::new();
    }
    let mut found: Vec<(u64, String, usize, Item)> = Vec::new();
    for (app, record) in &inner.mirror.apps {
        if !(record.installed && record.enabled && !record.hidden) {
            continue;
        }
        let Some(package) = inner.catalog.packages.get(app) else { continue };
        let manifest = &package.manifest;
        let Some(list) = manifest.pointer("/contributes/toolbarItems").and_then(Value::as_array)
        else {
            continue;
        };
        let family = package
            .fragment
            .as_deref()
            .and_then(|f| f.get("family"))
            .and_then(Value::as_str)
            .unwrap_or_default();
        let extension = manifest
            .get("name")
            .map(super::store::text)
            .filter(|n| !n.is_empty())
            .unwrap_or_else(|| app.clone());
        for (index, entry) in list.iter().enumerate() {
            if entry.get("overrides").is_some() {
                continue;
            }
            let (Some(id), Some(title)) =
                (entry.get("id").and_then(Value::as_str), entry.get("title"))
            else {
                continue;
            };
            let (symbol, icon) = match entry.get("icon") {
                Some(Value::String(path)) => (None, Some(path.clone())),
                Some(icon) => {
                    (icon.get("symbol").and_then(Value::as_str).map(str::to_string), None)
                }
                None => (None, None),
            };
            let mut item = Item {
                app: app.clone(),
                extension: extension.clone(),
                id: id.to_string(),
                kind: "button",
                title: title.clone(),
                symbol,
                icon,
                op: None,
                args: None,
                entries: Vec::new(),
                order: entry.get("order").and_then(Value::as_u64).unwrap_or(DEFAULT_ORDER),
            };
            match entry.get("kind").and_then(Value::as_str) {
                Some("button") => {
                    let Some((op, args)) = entry.get("action").and_then(|a| own_op(a, family))
                    else {
                        continue;
                    };
                    item.op = Some(op);
                    item.args = args;
                }
                Some("menu") => {
                    item.kind = "menu";
                    item.entries = entry
                        .get("items")
                        .and_then(Value::as_array)
                        .into_iter()
                        .flatten()
                        .filter_map(|row| {
                            let (op, args) = own_op(row.get("action")?, family)?;
                            Some(Entry { title: row.get("title")?.clone(), op, args })
                        })
                        .collect();
                    if item.entries.is_empty() {
                        continue;
                    }
                }
                _ => continue,
            }
            found.push((item.order, app.clone(), index, item));
        }
    }
    found.sort_by(|a, b| (a.0, &a.1, a.2).cmp(&(b.0, &b.1, b.2)));
    found.into_iter().take(MAX_ITEMS).map(|(.., item)| item).collect()
}

impl Supervisor {
    /// `apps.toolbar.list`: the toolbar band's app items, by `order`, then
    /// app id, then manifest order.
    pub(super) fn toolbar_list(&self) -> Value {
        let inner = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        json!({ "items": items(&inner) })
    }
}
