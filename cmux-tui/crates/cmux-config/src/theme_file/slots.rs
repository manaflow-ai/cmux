//! A theme file's `slots` map (`{"slots": {"<slot id>": "<variant id>"}}`):
//! which variant each theme slot draws (schemas/theme/slots.json,
//! webviews/src/slots/registry.ts). Each entry is checked against the slots
//! cmux ships; an unknown slot or variant is dropped with a diagnostic and the
//! others still apply. The host passes the kept map to the web views as is.

use std::collections::BTreeMap;
use std::sync::OnceLock;

use serde_json::{Map, Value, json};

use super::Reader;

/// The key a theme file names its slot variants under.
pub const KEY: &str = "slots";

const SCHEMA: &str = include_str!("../../../../../schemas/theme/slots.json");

/// Each shipped slot id with its variant ids, in schemas/theme/slots.json order.
pub fn known() -> &'static [(String, Vec<String>)] {
    static KNOWN: OnceLock<Vec<(String, Vec<String>)>> = OnceLock::new();
    KNOWN.get_or_init(|| {
        let schema: Value = serde_json::from_str(SCHEMA).unwrap_or(Value::Null);
        let ids = |list: Option<&Value>| -> Vec<String> {
            list.and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|entry| entry.get("id").and_then(Value::as_str).map(str::to_string))
                .collect()
        };
        schema
            .get("slots")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|slot| {
                let id = slot.get("id").and_then(Value::as_str)?;
                Some((id.to_string(), ids(slot.get("variants"))))
            })
            .collect()
    })
}

/// The `slots` property of the theme file JSON Schema: each slot id with its variants.
pub fn json_schema() -> Value {
    let properties: Map<String, Value> = known()
        .iter()
        .map(|(slot, variants)| (slot.clone(), json!({ "type": "string", "enum": variants })))
        .collect();
    json!({
        "type": "object",
        "description": "Which variant each theme slot draws (schemas/theme/slots.json): {\"<slot id>\": \"<variant id>\"}.",
        "properties": Value::Object(properties),
        "additionalProperties": false,
    })
}

/// Reads `members`' `slots` into the reader, refusing what no shipped slot has.
pub(super) fn read(reader: &mut Reader, members: &Map<String, Value>) -> BTreeMap<String, String> {
    let mut slots = BTreeMap::new();
    let Some(written) = members.get(KEY) else { return slots };
    let Value::Object(entries) = written else {
        reader.refuse(KEY, Some(written), "expected an object of slot id to variant id");
        return slots;
    };
    let mut entries: Vec<(&String, &Value)> = entries.iter().collect();
    entries.sort_by_key(|(slot, _)| *slot);
    for (slot, value) in entries {
        let path = format!("{KEY}.{slot}");
        let Some((_, variants)) = known().iter().find(|(id, _)| id == slot) else {
            let ids: Vec<&str> = known().iter().map(|(id, _)| id.as_str()).collect();
            reader.refuse(
                &path,
                Some(value),
                &format!("no such slot; expected one of {}", ids.join(", ")),
            );
            continue;
        };
        let Some(variant) = value.as_str().filter(|variant| variants.iter().any(|v| v == variant))
        else {
            reader.refuse(&path, Some(value), &format!("expected one of {}", variants.join(", ")));
            continue;
        };
        slots.insert(slot.clone(), variant.to_string());
    }
    slots
}
