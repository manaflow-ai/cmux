//! Reads the framed-IPC method attributes out of `spec/sdk-schema.json` and
//! `spec/resource-operations-v2.json` and writes them as Rust tables
//! (`methods.rs` includes the output). Shared by `build.rs`, which writes the
//! tables into `OUT_DIR`, and by the crate's tests, which feed it schemas that
//! must be refused.
//!
//! The attributes are those of spec/transports.md, "Framed IPC method
//! attributes" (p05-ipc design, section 3.3): `method_id` / `event_id` =
//! family u8 << 8 | ordinal u8, families declared in each file's `families`
//! table (sdk-schema commands 0x01-0x5F, resource-operations-v2 0x60-0xBF,
//! events 0xC0-0xFE). A method without an id is not framed and stays out of
//! the tables. The codegen validator (bindings/codegen/ipc_meta.py) owns the
//! full rule set; this reader refuses only what it cannot encode, so a table
//! never disagrees with its schema.

use std::collections::BTreeMap;
use std::fmt::{self, Write as _};

use serde_json::{Map, Value};

pub const V12_FAMILY_FIRST: u8 = 0x01;
pub const V12_FAMILY_LAST: u8 = 0x5F;
pub const V2_FAMILY_FIRST: u8 = 0x60;
pub const V2_FAMILY_LAST: u8 = 0xBF;
pub const EVENT_FAMILY_FIRST: u8 = 0xC0;
pub const EVENT_FAMILY_LAST: u8 = 0xFE;
/// The frame header's length cap (design 3.2); `max_bytes` cannot exceed it.
pub const MAX_FRAME_BYTES: u64 = 32 * 1024 * 1024;

/// Why a schema cannot become a table. `path` is a JSON path into the file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TableError {
    pub file: &'static str,
    pub path: String,
    pub message: String,
}

impl fmt::Display for TableError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}: {}", self.file, self.path, self.message)
    }
}

/// Which id space a family lives in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Space {
    V12,
    V2,
    Events,
}

impl Space {
    fn range(self) -> (u8, u8) {
        match self {
            Space::V12 => (V12_FAMILY_FIRST, V12_FAMILY_LAST),
            Space::V2 => (V2_FAMILY_FIRST, V2_FAMILY_LAST),
            Space::Events => (EVENT_FAMILY_FIRST, EVENT_FAMILY_LAST),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Coalesce {
    pub key: Vec<String>,
    pub additive: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Method {
    pub id: u16,
    pub name: String,
    /// `PriorityHint` variant name.
    pub priority: &'static str,
    pub ordering: &'static str,
    pub durability: &'static str,
    /// `None` is JSON; `Some(v)` is a binary layout of version `v`.
    pub binary_layout: Option<u8>,
    pub stream_scoped: bool,
    pub crosses_stream_ok: Option<String>,
    pub max_bytes: Option<u32>,
    pub coalesce: Option<Coalesce>,
    pub urgent: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Event {
    pub id: u16,
    pub name: String,
    pub priority: &'static str,
    pub coalesce: Option<Coalesce>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Family<T> {
    pub id: u8,
    pub name: String,
    /// Indexed by ordinal; `None` is an ordinal no method holds.
    pub slots: Vec<Option<T>>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Tables {
    pub v12: Vec<Family<Method>>,
    pub v2: Vec<Family<Method>>,
    pub events: Vec<Family<Event>>,
}

pub const SDK: &str = "sdk-schema.json";
pub const V2: &str = "resource-operations-v2.json";

/// Builds the tables from the two schema documents.
pub fn read(sdk: &Value, v2: &Value) -> Result<Tables, TableError> {
    let sdk_families = families(SDK, sdk, &[Space::V12, Space::Events])?;
    let v2_families = families(V2, v2, &[Space::V2])?;
    Ok(Tables {
        v12: methods(SDK, sdk, "commands", Space::V12, &sdk_families)?,
        v2: methods(V2, v2, "operations", Space::V2, &v2_families)?,
        events: events(sdk, &sdk_families)?,
    })
}

fn error(file: &'static str, path: impl Into<String>, message: impl Into<String>) -> TableError {
    TableError { file, path: path.into(), message: message.into() }
}

/// `families: { "<kebab-name>": { "id": <u8>, "description": "..." } }`;
/// absent means no family yet.
fn families(
    file: &'static str,
    doc: &Value,
    spaces: &[Space],
) -> Result<BTreeMap<u8, String>, TableError> {
    let mut out = BTreeMap::new();
    let Some(table) = doc.get("families") else {
        return Ok(out);
    };
    let table = table.as_object().ok_or_else(|| error(file, "$.families", "must be an object"))?;
    for (name, entry) in table {
        let path = format!("$.families.{name}");
        let id = entry
            .get("id")
            .and_then(Value::as_u64)
            .and_then(|id| u8::try_from(id).ok())
            .ok_or_else(|| error(file, format!("{path}.id"), "must be a u8"))?;
        if !spaces.iter().any(|space| in_space(*space, id)) {
            return Err(error(
                file,
                format!("{path}.id"),
                format!("0x{id:02X} is outside this file's family ranges"),
            ));
        }
        if let Some(other) = out.insert(id, name.clone()) {
            return Err(error(
                file,
                format!("{path}.id"),
                format!("0x{id:02X} is also family {other:?}"),
            ));
        }
    }
    Ok(out)
}

fn in_space(space: Space, family: u8) -> bool {
    let (first, last) = space.range();
    (first..=last).contains(&family)
}

fn entries<'a>(
    file: &'static str,
    doc: &'a Value,
    key: &str,
) -> Result<&'a Map<String, Value>, TableError> {
    doc.get(key)
        .and_then(Value::as_object)
        .ok_or_else(|| error(file, format!("$.{key}"), "must be an object"))
}

/// An entry that knows its wire name, for the duplicate-id message.
trait Named {
    fn name(&self) -> &str;
}

impl Named for Method {
    fn name(&self) -> &str {
        &self.name
    }
}

impl Named for Event {
    fn name(&self) -> &str {
        &self.name
    }
}

/// Collects one id space's entries into dense families.
struct Grouper<'a, T> {
    file: &'static str,
    space: Space,
    declared: &'a BTreeMap<u8, String>,
    grouped: BTreeMap<u8, Vec<Option<T>>>,
}

impl<'a, T: Named> Grouper<'a, T> {
    fn new(file: &'static str, space: Space, declared: &'a BTreeMap<u8, String>) -> Self {
        Grouper { file, space, declared, grouped: BTreeMap::new() }
    }

    /// Places `item` at its family and ordinal; refuses an undeclared family,
    /// a family of another space and a second holder of an id.
    fn place(&mut self, path: &str, id: u16, item: T) -> Result<(), TableError> {
        let file = self.file;
        let [family, ordinal] = id.to_be_bytes();
        if !self.declared.contains_key(&family) {
            return Err(error(
                file,
                path,
                format!("family 0x{family:02X} is not declared in $.families"),
            ));
        }
        if !in_space(self.space, family) {
            let (first, last) = self.space.range();
            return Err(error(
                file,
                path,
                format!("0x{id:04X} is outside families 0x{first:02X}-0x{last:02X}"),
            ));
        }
        let slots = self.grouped.entry(family).or_default();
        let index = usize::from(ordinal);
        if slots.len() <= index {
            slots.resize_with(index + 1, || None);
        }
        if let Some(Some(existing)) = slots.get(index) {
            return Err(error(
                file,
                path,
                format!("0x{id:04X} is also held by {:?}", existing.name()),
            ));
        }
        if let Some(slot) = slots.get_mut(index) {
            *slot = Some(item);
        }
        Ok(())
    }

    fn finish(self) -> Vec<Family<T>> {
        let declared = self.declared;
        self.grouped
            .into_iter()
            .map(|(id, slots)| Family {
                id,
                name: declared.get(&id).cloned().unwrap_or_default(),
                slots,
            })
            .collect()
    }
}

fn methods(
    file: &'static str,
    doc: &Value,
    key: &str,
    space: Space,
    declared: &BTreeMap<u8, String>,
) -> Result<Vec<Family<Method>>, TableError> {
    let mut grouper = Grouper::new(file, space, declared);
    for (name, node) in entries(file, doc, key)? {
        let path = format!("$.{key}.{name}");
        let Some(id) = wire_id(file, &path, node, "method_id")? else {
            continue;
        };
        let method = method(file, &path, name, id, node)?;
        grouper.place(&format!("{path}.method_id"), id, method)?;
    }
    Ok(grouper.finish())
}

fn events(doc: &Value, declared: &BTreeMap<u8, String>) -> Result<Vec<Family<Event>>, TableError> {
    let mut grouper = Grouper::new(SDK, Space::Events, declared);
    for (name, node) in entries(SDK, doc, "events")? {
        let path = format!("$.events.{name}");
        let Some(id) = wire_id(SDK, &path, node, "event_id")? else {
            continue;
        };
        let event = Event {
            id,
            name: name.clone(),
            priority: priority(SDK, &path, node)?,
            coalesce: coalesce(SDK, &path, node)?,
        };
        grouper.place(&format!("{path}.event_id"), id, event)?;
    }
    Ok(grouper.finish())
}

fn wire_id(
    file: &'static str,
    path: &str,
    node: &Value,
    key: &str,
) -> Result<Option<u16>, TableError> {
    match node.get(key) {
        None => Ok(None),
        Some(value) => {
            value.as_u64().and_then(|id| u16::try_from(id).ok()).map(Some).ok_or_else(|| {
                error(file, format!("{path}.{key}"), "must be a u16 (family << 8 | ordinal)")
            })
        }
    }
}

/// Maps a schema string to a Rust variant name; absent gives `default`.
fn variant(
    file: &'static str,
    path: &str,
    node: &Value,
    key: &str,
    choices: &[(&str, &'static str)],
    default: Option<&'static str>,
) -> Result<&'static str, TableError> {
    let Some(value) = node.get(key) else {
        return default
            .ok_or_else(|| error(file, path, format!("a method with an id needs {key}")));
    };
    let text = value.as_str().unwrap_or_default();
    choices.iter().find(|(wire, _)| *wire == text).map(|(_, rust)| *rust).ok_or_else(|| {
        let wires: Vec<&str> = choices.iter().map(|(wire, _)| *wire).collect();
        error(file, format!("{path}.{key}"), format!("must be one of {}", wires.join(", ")))
    })
}

fn priority(file: &'static str, path: &str, node: &Value) -> Result<&'static str, TableError> {
    variant(
        file,
        path,
        node,
        "priority",
        &[
            ("input", "Input"),
            ("control", "Control"),
            ("bulk", "Bulk"),
            ("background", "Background"),
        ],
        None,
    )
}

fn flag(file: &'static str, path: &str, node: &Value, key: &str) -> Result<bool, TableError> {
    match node.get(key) {
        None => Ok(false),
        Some(value) => {
            value.as_bool().ok_or_else(|| error(file, format!("{path}.{key}"), "must be a boolean"))
        }
    }
}

fn method(
    file: &'static str,
    path: &str,
    name: &str,
    id: u16,
    node: &Value,
) -> Result<Method, TableError> {
    let binary = variant(
        file,
        path,
        node,
        "payload",
        &[("json", "Json"), ("binary", "Binary")],
        Some("Json"),
    )? == "Binary";
    let binary_layout = match (binary, node.get("layout_version")) {
        (false, None) => None,
        (false, Some(_)) => {
            return Err(error(file, format!("{path}.layout_version"), "needs payload \"binary\""));
        }
        (true, layout) => Some(
            layout
                .and_then(Value::as_u64)
                .and_then(|v| u8::try_from(v).ok())
                .filter(|v| *v >= 1)
                .ok_or_else(|| {
                error(
                    file,
                    format!("{path}.layout_version"),
                    "a binary payload needs a layout version 1-255",
                )
            })?,
        ),
    };
    let crosses_stream_ok = match node.get("crosses_stream_ok") {
        None => None,
        Some(reason) => Some(
            reason
                .as_str()
                .filter(|r| !r.trim().is_empty())
                .ok_or_else(|| {
                    error(file, format!("{path}.crosses_stream_ok"), "must be a non-empty reason")
                })?
                .to_owned(),
        ),
    };
    let max_bytes = match node.get("max_bytes") {
        None => None,
        Some(value) => Some(
            value
                .as_u64()
                .filter(|v| (1..=MAX_FRAME_BYTES).contains(v))
                .and_then(|v| u32::try_from(v).ok())
                .ok_or_else(|| {
                    error(file, format!("{path}.max_bytes"), format!("must be 1-{MAX_FRAME_BYTES}"))
                })?,
        ),
    };
    // The Rust tables hold every framed method; only the Swift table keeps
    // just its client's. A malformed list is refused here too, so both
    // readers refuse the same schemas.
    check_clients(file, path, node)?;
    Ok(Method {
        id,
        name: name.to_owned(),
        priority: priority(file, path, node)?,
        // Absent ordering is the connection sequence (Mojo: in-order delivery).
        ordering: variant(
            file,
            path,
            node,
            "ordering",
            &[("sequence", "Sequence"), ("independent", "Independent")],
            Some("Sequence"),
        )?,
        // Durability has no default (spec/transports.md): a framed command
        // states it, as it states its priority.
        durability: variant(
            file,
            path,
            node,
            "durability",
            &[
                ("read_only", "ReadOnly"),
                ("memory", "Memory"),
                ("reply_before_journal", "ReplyBeforeJournal"),
                ("reply_after_journal", "ReplyAfterJournal"),
            ],
            None,
        )?,
        binary_layout,
        stream_scoped: flag(file, path, node, "stream_scoped")?,
        crosses_stream_ok,
        max_bytes,
        coalesce: coalesce(file, path, node)?,
        urgent: flag(file, path, node, "urgent")?,
    })
}

fn names(file: &'static str, path: &str, value: Option<&Value>) -> Result<Vec<String>, TableError> {
    let Some(value) = value else {
        return Ok(Vec::new());
    };
    value
        .as_array()
        .and_then(|items| {
            items.iter().map(|item| item.as_str().map(str::to_owned)).collect::<Option<Vec<_>>>()
        })
        .ok_or_else(|| error(file, path, "must be an array of field names"))
}

/// `clients`, when present, is a non-empty array of client names.
fn check_clients(file: &'static str, path: &str, node: &Value) -> Result<(), TableError> {
    let Some(value) = node.get("clients") else {
        return Ok(());
    };
    let named = value
        .as_array()
        .is_some_and(|items| !items.is_empty() && items.iter().all(Value::is_string));
    if named {
        Ok(())
    } else {
        Err(error(file, format!("{path}.clients"), "must be a non-empty array of client names"))
    }
}

fn coalesce(file: &'static str, path: &str, node: &Value) -> Result<Option<Coalesce>, TableError> {
    let Some(value) = node.get("coalesce") else {
        return Ok(None);
    };
    let path = format!("{path}.coalesce");
    if !value.is_object() {
        return Err(error(file, path, "must be an object"));
    }
    Ok(Some(Coalesce {
        key: names(file, &format!("{path}.key"), value.get("key"))?,
        additive: names(file, &format!("{path}.additive"), value.get("additive"))?,
    }))
}

// Emitting ------------------------------------------------------------------

fn emit_str_slice(out: &mut String, items: &[String]) {
    out.push_str("&[");
    for item in items {
        let _ = write!(out, "{item:?}, ");
    }
    out.push(']');
}

fn emit_coalesce(out: &mut String, coalesce: Option<&Coalesce>) {
    match coalesce {
        None => out.push_str("None"),
        Some(c) => {
            out.push_str("Some(Coalesce { key: ");
            emit_str_slice(out, &c.key);
            out.push_str(", additive: ");
            emit_str_slice(out, &c.additive);
            out.push_str(" })");
        }
    }
}

fn emit_method(out: &mut String, m: &Method) {
    let _ = write!(
        out,
        "Some(MethodAttrs {{ id: MethodId::new(0x{:04X}), name: {:?}, priority: PriorityHint::{}, ordering: Ordering::{}, durability: Durability::{}, payload: ",
        m.id, m.name, m.priority, m.ordering, m.durability
    );
    match m.binary_layout {
        None => out.push_str("Payload::Json"),
        Some(version) => {
            let _ = write!(out, "Payload::Binary {{ layout_version: {version} }}");
        }
    }
    let _ = write!(
        out,
        ", stream_scoped: {}, crosses_stream_ok: {:?}, max_bytes: {:?}, coalesce: ",
        m.stream_scoped, m.crosses_stream_ok, m.max_bytes
    );
    emit_coalesce(out, m.coalesce.as_ref());
    let _ = writeln!(out, ", urgent: {} }}),", m.urgent);
}

fn emit_event(out: &mut String, e: &Event) {
    let _ = write!(
        out,
        "Some(EventAttrs {{ id: EventId::new(0x{:04X}), name: {:?}, priority: PriorityHint::{}, coalesce: ",
        e.id, e.name, e.priority
    );
    emit_coalesce(out, e.coalesce.as_ref());
    out.push_str(" }),\n");
}

/// One `[Option<&FamilyTable<T>>; N]` literal, indexed by family id - first.
fn emit_space<T>(
    out: &mut String,
    space: Space,
    families: &[Family<T>],
    attrs: &str,
    entry: impl Fn(&mut String, &T),
) {
    let (first, last) = space.range();
    out.push_str("[\n");
    for family_id in first..=last {
        match families.iter().find(|f| f.id == family_id) {
            None => out.push_str("None,\n"),
            Some(family) => {
                let _ = writeln!(
                    out,
                    "Some(&FamilyTable::<{attrs}> {{ id: 0x{:02X}, name: {:?}, entries: &[",
                    family.id, family.name
                );
                for slot in &family.slots {
                    match slot {
                        None => out.push_str("None,\n"),
                        Some(item) => entry(out, item),
                    }
                }
                out.push_str("] }),\n");
            }
        }
    }
    out.push(']');
}

fn emit_names<'a>(out: &mut String, ids: impl Iterator<Item = (&'a str, u16)>, value: &str) {
    let mut map = phf_codegen::Map::<&str>::new();
    map.phf_path("::phf");
    let entries: Vec<(&str, String)> =
        ids.map(|(name, id)| (name, format!("{value}::new(0x{id:04X})"))).collect();
    for (name, id) in &entries {
        map.entry(name, id);
    }
    let _ = write!(out, "{}", map.build());
}

fn method_names(families: &[Family<Method>]) -> impl Iterator<Item = (&str, u16)> {
    families.iter().flat_map(|f| f.slots.iter().flatten()).map(|m| (m.name.as_str(), m.id))
}

/// Rust source of `static <name>: MethodTables`, for `methods.rs` to include.
pub fn emit(tables: &Tables, name: &str) -> String {
    let mut out = String::new();
    let _ = write!(out, "pub(crate) static {name}: MethodTables = MethodTables {{\nv12: ");
    emit_space(&mut out, Space::V12, &tables.v12, "MethodAttrs", emit_method);
    out.push_str(",\nv2: ");
    emit_space(&mut out, Space::V2, &tables.v2, "MethodAttrs", emit_method);
    out.push_str(",\nevents: ");
    emit_space(&mut out, Space::Events, &tables.events, "EventAttrs", emit_event);
    out.push_str(",\nv12_names: ");
    emit_names(&mut out, method_names(&tables.v12), "MethodId");
    out.push_str(",\nv2_names: ");
    emit_names(&mut out, method_names(&tables.v2), "MethodId");
    out.push_str(",\nevent_names: ");
    emit_names(
        &mut out,
        tables
            .events
            .iter()
            .flat_map(|f| f.slots.iter().flatten())
            .map(|e| (e.name.as_str(), e.id)),
        "EventId",
    );
    out.push_str(",\n};\n");
    out
}
