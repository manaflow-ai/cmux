//! What pending sidebar-document changes write on item records (#26382), moved from Swift's
//! `SidebarDocPendingRecords.swift`.
//!
//! A `sidebar.apply` op array writes a group's name, color or icon (`group.update`), a new group
//! (`group.create`, with its space) or an item's own fields (`item.update`: its space, label, span,
//! icon). The mirror's rows place every pending change at once, but the rows draw names, colors and
//! icons from the records, which change only with the daemon's batch: so the store holds each
//! change's writes from its intent until its key settles and lays them over the confirmed records,
//! in order, at read time. These rules read the writes out of the ops ([`writes`]) and lay them over
//! records ([`apply`]); which keys are pending stays the store's bookkeeping.

use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;

/// A group's own fields on its record.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct GroupBody {
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    #[serde(default)]
    pub collapsed: bool,
}

/// The fields of an item record the writes read or write. `group` is the body of a group item,
/// absent for every other kind (the caller keeps the rest of its record).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Item {
    pub id: String,
    pub section: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group: Option<GroupBody>,
    #[serde(default = "yes")]
    pub shows_label: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub span: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub room: Option<String>,
}

fn yes() -> bool {
    true
}

/// A patch field: absent (`None`) leaves the field, `Some(None)` (JSON null) clears it.
pub type Field<T> = Option<Option<T>>;

fn present<'de, D: Deserializer<'de>, T: Deserialize<'de>>(d: D) -> Result<Field<T>, D::Error> {
    Option::<T>::deserialize(d).map(Some)
}

/// The fields of an `item.update` patch the records hold.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ItemPatch {
    pub id: String,
    #[serde(default, deserialize_with = "present", skip_serializing_if = "Option::is_none")]
    pub room: Field<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shows_label: Option<bool>,
    #[serde(default, deserialize_with = "present", skip_serializing_if = "Option::is_none")]
    pub span: Field<i64>,
    #[serde(default, deserialize_with = "present", skip_serializing_if = "Option::is_none")]
    pub label: Field<String>,
    #[serde(default, deserialize_with = "present", skip_serializing_if = "Option::is_none")]
    pub icon_url: Field<String>,
}

impl ItemPatch {
    fn is_empty(&self) -> bool {
        self.room.is_none()
            && self.shows_label.is_none()
            && self.span.is_none()
            && self.label.is_none()
            && self.icon_url.is_none()
    }

    fn applied(&self, mut item: Item) -> Item {
        if let Some(room) = &self.room {
            item.room = room.clone();
        }
        if let Some(shows_label) = self.shows_label {
            item.shows_label = shows_label;
        }
        if let Some(span) = self.span {
            item.span = span;
        }
        if let Some(label) = &self.label {
            item.label = label.clone();
        }
        if let Some(icon_url) = &self.icon_url {
            item.icon_url = icon_url.clone();
        }
        item
    }
}

/// A `group.update`'s fields: each `None` when the patch leaves it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct GroupPatch {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, deserialize_with = "present", skip_serializing_if = "Option::is_none")]
    pub color: Field<String>,
    #[serde(default, deserialize_with = "present", skip_serializing_if = "Option::is_none")]
    pub icon: Field<String>,
}

/// One op's write on the records.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Write {
    Update(GroupPatch),
    Create(Item),
    Item(ItemPatch),
}

/// A patch field as Swift's `field` read it: absent, a string, or cleared by any other value.
fn field(patch: &Map<String, Value>, key: &str) -> Field<String> {
    patch.get(key).map(|value| value.as_str().map(str::to_owned))
}

/// An integer as Swift's `as? Int` read a JSON number: whole numbers only.
fn int(value: &Value) -> Option<i64> {
    if let Some(int) = value.as_i64() {
        return Some(int);
    }
    let float = value.as_f64()?;
    (float.fract() == 0.0 && float >= i64::MIN as f64 && float < i64::MAX as f64)
        .then_some(float as i64)
}

/// The record write of one op, or `None`. A fold (`collapsed` alone) writes nothing: the window
/// shows it already.
pub fn write(op: &Value, items: &BTreeMap<String, Item>) -> Option<Write> {
    let id = op.get("id")?.as_str()?.to_owned();
    match op.get("op").and_then(Value::as_str) {
        Some("group.update") => {
            let patch = op.get("patch")?.as_object()?;
            let name = patch.get("name").and_then(Value::as_str).map(str::to_owned);
            let (color, icon) = (field(patch, "color"), field(patch, "icon"));
            if name.is_none() && color.is_none() && icon.is_none() {
                return None;
            }
            Some(Write::Update(GroupPatch { id, name, color, icon }))
        }
        Some("group.create") => {
            let to = op.get("to").and_then(Value::as_object);
            let names: Option<Vec<&str>> = op
                .get("items")
                .and_then(Value::as_array)
                .and_then(|list| list.iter().map(Value::as_str).collect());
            let first = names.and_then(|names| names.first().and_then(|name| items.get(*name)));
            let to_field = |key: &str| to.and_then(|to| to.get(key));
            let section = to_field("section")
                .and_then(Value::as_str)
                .map(str::to_owned)
                .or_else(|| first.map(|item| item.section.clone()))
                .unwrap_or_default();
            let parent = match to_field("parent").and_then(Value::as_str) {
                Some(parent) => Some(parent.to_owned()),
                None if to_field("section").is_none() => first.and_then(|item| item.parent.clone()),
                None => None,
            };
            let text = |key: &str| op.get(key).and_then(Value::as_str).map(str::to_owned);
            Some(Write::Create(Item {
                id,
                section,
                parent,
                group: Some(GroupBody {
                    name: text("name").unwrap_or_default(),
                    color: text("color"),
                    icon: None,
                    collapsed: false,
                }),
                shows_label: true,
                span: None,
                label: None,
                icon_url: None,
                room: text("profile"),
            }))
        }
        Some("item.update") => {
            let wire = op.get("patch")?.as_object()?;
            let patch = ItemPatch {
                id,
                room: field(wire, "room"),
                shows_label: wire.get("shows_label").and_then(Value::as_bool),
                span: wire.get("span").map(int),
                label: field(wire, "label"),
                icon_url: field(wire, "icon_url"),
            };
            (!patch.is_empty()).then_some(Write::Item(patch))
        }
        _ => None,
    }
}

/// The writes `ops` (a `sidebar.apply` op array) make on records, in order; `None` when `ops` is no
/// array of objects. Empty when they write none (a move, a pin, a fold).
pub fn writes(ops: &Value, items: &BTreeMap<String, Item>) -> Option<Vec<Write>> {
    let ops = ops.as_array()?;
    if !ops.iter().all(Value::is_object) {
        return None;
    }
    Some(ops.iter().filter_map(|op| write(op, items)).collect())
}

/// `items` with every write applied, in order.
pub fn apply(mut items: BTreeMap<String, Item>, writes: &[Write]) -> BTreeMap<String, Item> {
    for write in writes {
        match write {
            Write::Update(patch) => {
                let Some(group) = items.get_mut(&patch.id).and_then(|item| item.group.as_mut())
                else {
                    continue;
                };
                if let Some(name) = &patch.name {
                    group.name = name.clone();
                }
                if let Some(color) = &patch.color {
                    group.color = color.clone();
                }
                if let Some(icon) = &patch.icon {
                    group.icon = icon.clone();
                }
            }
            Write::Create(item) => {
                items.entry(item.id.clone()).or_insert_with(|| item.clone());
            }
            Write::Item(patch) => {
                if let Some(item) = items.remove(&patch.id) {
                    items.insert(patch.id.clone(), patch.applied(item));
                }
            }
        }
    }
    items
}

/// A request to the `sidebar_pending_records` FFI op.
#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Request {
    /// The writes of an op array: `{writes}`, or `{writes: null}` when the ops are no op array.
    Writes {
        ops: Value,
        #[serde(default)]
        items: BTreeMap<String, Item>,
    },
    /// The records with the writes laid over them: `{items}`.
    Apply {
        writes: Vec<Write>,
        #[serde(default)]
        items: BTreeMap<String, Item>,
    },
}

/// The answer to one request.
pub fn respond(request: Request) -> Value {
    match request {
        Request::Writes { ops, items } => json!({"writes": writes(&ops, &items)}),
        Request::Apply { writes, items } => json!({"items": apply(items, &writes)}),
    }
}

#[cfg(test)]
#[path = "sidebar_pending_records_tests.rs"]
mod tests;
