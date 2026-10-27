//! Reads the wire attributes out of the schema files, in exactly the shape
//! their validators accept: `bindings/codegen/ipc_meta.py` for
//! `sdk-schema.json` and `spec/resource-operations-v2.schema.json` for the
//! v2 operations. Any other shape is a [`ReadError`], never zero ids.

use std::collections::BTreeMap;

use serde_json::Value;

use super::layout::TypeTables;
use super::{LayoutRecord, WireEntry, WireIds};

/// A schema file the wire rules cannot read.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReadError {
    /// Where (`commands.send.method_id`, `families.tabs`, ...).
    pub at: String,
    /// What is wrong.
    pub why: String,
}

impl std::fmt::Display for ReadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.at, self.why)
    }
}

impl std::error::Error for ReadError {}

/// Reads the wire ids of `spec/sdk-schema.json`. A command's binary layout
/// covers its request and result; an event has no binary layout (its
/// `payload` is its type).
pub fn ids_from_sdk_schema(schema: &Value) -> Result<WireIds, ReadError> {
    let types = TypeTables::new(schema, &["types"]);
    let mut ids = WireIds { families: families(schema)?, ..WireIds::default() };
    let commands =
        Section { name: "commands", id_key: "method_id", bodies: &["request", "result"] };
    read_entries(schema, &commands, &types, &mut ids.methods)?;
    let events = Section { name: "events", id_key: "event_id", bodies: &[] };
    read_entries(schema, &events, &types, &mut ids.events)?;
    Ok(ids)
}

/// Reads the wire ids of `spec/resource-operations-v2.json`. Only transported
/// operations travel in frames; a local operation runs in the app, and its
/// JSON Schema (`localOperation`) has no wire attributes.
pub fn ids_from_resource_operations(schema: &Value) -> Result<WireIds, ReadError> {
    let types = TypeTables::new(schema, &["types", "generics"]);
    let mut ids = WireIds { families: families(schema)?, ..WireIds::default() };
    let operations =
        Section { name: "operations", id_key: "method_id", bodies: &["params", "result"] };
    read_entries(schema, &operations, &types, &mut ids.methods)?;
    let local = schema.get("local_operations").and_then(Value::as_object);
    for (name, entry) in local.into_iter().flatten() {
        if let Some(key) = WIRE_KEYS.iter().find(|key| entry.get(**key).is_some()) {
            let why = "a local operation never travels in a frame";
            return Err(ReadError {
                at: format!("local_operations.{name}.{key}"),
                why: why.into(),
            });
        }
    }
    Ok(ids)
}

/// The wire attributes of a transported operation.
const WIRE_KEYS: [&str; 5] =
    ["method_id", "priority", "priority_changed_reason", "payload", "layout_version"];

/// One name -> entry table of a schema file.
struct Section<'a> {
    name: &'a str,
    id_key: &'a str,
    /// The members a binary layout covers; empty when the section has no
    /// binary payloads.
    bodies: &'a [&'a str],
}

impl Section<'_> {
    fn error(&self, entry: &str, key: &str, why: impl Into<String>) -> ReadError {
        ReadError { at: format!("{}.{entry}.{key}", self.name), why: why.into() }
    }
}

fn families(schema: &Value) -> Result<BTreeMap<String, u8>, ReadError> {
    let Some(table) = schema.get("families") else { return Ok(BTreeMap::new()) };
    let Some(table) = table.as_object() else {
        return Err(ReadError { at: "families".into(), why: "is not an object".into() });
    };
    table
        .iter()
        .map(|(name, family)| {
            let at = format!("families.{name}.id");
            let id = family.get("id").and_then(Value::as_u64).ok_or_else(|| ReadError {
                at: at.clone(),
                why: "a family needs an integer id".into(),
            })?;
            let id = u8::try_from(id)
                .map_err(|_| ReadError { at, why: format!("{id} does not fit a byte") })?;
            Ok((name.clone(), id))
        })
        .collect()
}

fn read_entries(
    schema: &Value,
    section: &Section<'_>,
    types: &TypeTables<'_>,
    out: &mut BTreeMap<String, WireEntry>,
) -> Result<(), ReadError> {
    let Some(entries) = schema.get(section.name).and_then(Value::as_object) else {
        return Ok(());
    };
    for (name, entry) in entries {
        let Some(raw) = entry.get(section.id_key) else { continue };
        let id = raw
            .as_u64()
            .and_then(|id| u16::try_from(id).ok())
            .ok_or_else(|| section.error(name, section.id_key, format!("{raw} is not a u16")))?;
        let text = |key: &str| match entry.get(key) {
            None => Ok(None),
            Some(Value::String(text)) => Ok(Some(text.clone())),
            Some(other) => Err(section.error(name, key, format!("{other} is not a string"))),
        };
        let layout = if section.bodies.is_empty() {
            None
        } else {
            binary_layout(section, name, entry, types)?
        };
        let priority_changed_reason =
            text("priority_changed_reason")?.filter(|reason| !reason.trim().is_empty());
        let wire = WireEntry { id, priority: text("priority")?, priority_changed_reason, layout };
        out.insert(name.clone(), wire);
    }
    Ok(())
}

/// `payload` is `"json"` (the default) or `"binary"`; a binary payload needs
/// `layout_version` 1-255 beside it, and only a binary one may have it.
fn binary_layout(
    section: &Section<'_>,
    name: &str,
    entry: &Value,
    types: &TypeTables<'_>,
) -> Result<Option<LayoutRecord>, ReadError> {
    let binary = match entry.get("payload") {
        None => false,
        Some(Value::String(kind)) if kind == "json" => false,
        Some(Value::String(kind)) if kind == "binary" => true,
        Some(other) => {
            let why = format!("{other} is neither \"json\" nor \"binary\"");
            return Err(section.error(name, "payload", why));
        }
    };
    let version = entry.get("layout_version");
    if !binary {
        return match version {
            None => Ok(None),
            Some(_) => Err(section.error(name, "layout_version", "needs payload \"binary\"")),
        };
    }
    let Some(version) = version else {
        return Err(section.error(name, "payload", "a binary payload needs a layout_version"));
    };
    let version =
        version.as_u64().and_then(|v| u8::try_from(v).ok()).filter(|v| *v >= 1).ok_or_else(
            || section.error(name, "layout_version", format!("{version} is not 1-255")),
        )?;
    let fingerprint = types.fingerprint(entry, section.bodies);
    Ok(Some(LayoutRecord { version, fingerprint }))
}
