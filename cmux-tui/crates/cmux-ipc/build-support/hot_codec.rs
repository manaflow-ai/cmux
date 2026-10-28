//! The binary layouts of the schema's hot messages (p05-ipc-183;
//! spec/transports.md, "Binary payload layouts"), read from
//! spec/sdk-schema.json and written as Rust for `src/hot.rs`.
//!
//! A command with `payload: "binary"` has a layout for its request and one
//! for its result; an event with `encoding: "binary"` has one for its
//! payload. A layout is the version byte, then the body: an object's fields
//! in ascending byte order of their wire names, without its literal fields
//! (the frame header names the message); a tag byte (0 absent or null, 1
//! present) before each optional or nullable field; integers and floats
//! little-endian at their width; a boolean as 0 or 1; an enum as the u8 index
//! of its value in schema order; a string as a u16 byte length (at most the
//! field's `max_bytes`) and its UTF-8; an array as a u16 count (at most its
//! field's `max_items`, else its type's) and its items. A field's bounds are
//! the layout's only: JSON decoders do not read them, and a value over one
//! goes as JSON. Sorting by name makes the bytes independent of
//! the order of the schema file, which is the order `api-compat-check`'s
//! layout fingerprint ignores too.
//!
//! The Swift twin is Packages/macOS/CmuxNext/Sources/CmuxNextWireGen/
//! HotEmitter.swift; spec/fixtures/ipc-hot-codec/golden.json holds bytes both
//! must produce. This file is included by build.rs and by the tests.

use std::collections::BTreeMap;
use std::fmt::Write as _;

use serde_json::{Map, Value};

/// The largest bound a u16 length prefix can carry.
const MAX_PREFIXED: u64 = u16::MAX as u64;

/// What a value is on the wire.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Ty {
    Bool,
    U16,
    U32,
    U64,
    I32,
    I64,
    F32,
    F64,
    /// A string of at most `max_bytes` UTF-8 bytes.
    Str {
        max_bytes: u16,
    },
    /// A generated enum, by type name.
    Enum(String),
    /// A generated struct, by type name.
    Object(String),
    /// At most `max_items` items.
    Array {
        items: Box<Ty>,
        max_items: u16,
    },
}

/// One wire field of a struct.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Field {
    /// The JSON member name.
    pub wire: String,
    pub ty: Ty,
    /// Optional or nullable: a tag byte comes first.
    pub tagged: bool,
}

/// A generated struct: its wire fields in layout order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Struct {
    pub name: String,
    pub fields: Vec<Field>,
}

/// A generated enum: its wire values in index order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Enum {
    pub name: String,
    pub values: Vec<String>,
}

/// Which body of a message a layout carries.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Part {
    Request,
    Result,
    Event,
}

impl Part {
    fn rust(self) -> &'static str {
        match self {
            Part::Request => "Request",
            Part::Result => "Result",
            Part::Event => "Event",
        }
    }
}

/// One binary layout: a command's request or result, or an event.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Message {
    /// The command or event name.
    pub name: String,
    pub part: Part,
    /// `method_id` or `event_id`.
    pub wire_id: u16,
    pub layout_version: u8,
    /// The struct that holds its body.
    pub ty: String,
}

/// Every binary layout of one schema, and the types they reach.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct HotModel {
    pub messages: Vec<Message>,
    pub structs: BTreeMap<String, Struct>,
    pub enums: BTreeMap<String, Enum>,
}

/// Reads the binary layouts of `sdk` (spec/sdk-schema.json). A layout this
/// codec cannot carry is an error with its JSON path; the codegen validator
/// (bindings/codegen/ipc_meta.py) refuses the same schemas.
pub fn read(sdk: &Value) -> Result<HotModel, String> {
    let types = sdk.get("types").and_then(Value::as_object).cloned().unwrap_or_default();
    let mut reader = Reader { types: &types, model: HotModel::default() };
    for (name, node) in members(sdk, "commands")? {
        let path = format!("$.commands.{name}");
        let Some(version) = layout_version(node, "payload", &path)? else { continue };
        let wire_id = wire_id(node, "method_id", &path)?;
        let pascal = pascal(name);
        for (part, key) in [(Part::Request, "request"), (Part::Result, "result")] {
            let expr = node.get(key).ok_or_else(|| format!("{path}.{key}: missing"))?;
            let fallback = format!("{pascal}{}", part.rust());
            let ty = reader.body(expr, &fallback, &format!("{path}.{key}"))?;
            reader.model.messages.push(Message {
                name: name.clone(),
                part,
                wire_id,
                layout_version: version,
                ty,
            });
        }
    }
    for (name, node) in members(sdk, "events")? {
        let path = format!("$.events.{name}");
        let Some(version) = layout_version(node, "encoding", &path)? else { continue };
        let wire_id = wire_id(node, "event_id", &path)?;
        let expr = node.get("payload").ok_or_else(|| format!("{path}.payload: missing"))?;
        let ty =
            reader.body(expr, &format!("{}Event", pascal(name)), &format!("{path}.payload"))?;
        reader.model.messages.push(Message {
            name: name.clone(),
            part: Part::Event,
            wire_id,
            layout_version: version,
            ty,
        });
    }
    Ok(reader.model)
}

/// The entries under `key`, sorted by name, so the output does not depend
/// on the order the map keeps.
fn members<'a>(doc: &'a Value, key: &str) -> Result<Vec<(&'a String, &'a Value)>, String> {
    let map = doc
        .get(key)
        .and_then(Value::as_object)
        .ok_or_else(|| format!("$.{key}: must be an object"))?;
    let mut entries: Vec<_> = map.iter().collect();
    entries.sort_by(|a, b| a.0.as_bytes().cmp(b.0.as_bytes()));
    Ok(entries)
}

fn layout_version(node: &Value, kind_key: &str, path: &str) -> Result<Option<u8>, String> {
    match node.get(kind_key).and_then(Value::as_str) {
        Some("binary") => node
            .get("layout_version")
            .and_then(Value::as_u64)
            .and_then(|v| u8::try_from(v).ok())
            .filter(|v| *v >= 1)
            .map(Some)
            .ok_or_else(|| format!("{path}.layout_version: a binary {kind_key} needs 1-255")),
        _ => Ok(None),
    }
}

fn wire_id(node: &Value, key: &str, path: &str) -> Result<u16, String> {
    node.get(key)
        .and_then(Value::as_u64)
        .and_then(|v| u16::try_from(v).ok())
        .ok_or_else(|| format!("{path}.{key}: a binary layout needs a u16 {key}"))
}

/// A field's layout bounds: `max_bytes` bounds each string it reaches,
/// `max_items` the field's own array.
#[derive(Clone, Copy, Debug, Default)]
struct Bounds {
    max_bytes: Option<u64>,
    max_items: Option<u64>,
}

struct Reader<'a> {
    types: &'a Map<String, Value>,
    model: HotModel,
}

impl Reader<'_> {
    /// The struct a message body is: a named object type keeps its name, an
    /// inline object gets `fallback`.
    fn body(&mut self, expr: &Value, fallback: &str, path: &str) -> Result<String, String> {
        match self.ty(expr, fallback, Bounds::default(), path, &mut Vec::new())? {
            Ty::Object(name) => Ok(name),
            _ => Err(format!("{path}: a binary body must be an object")),
        }
    }

    /// The wire type of `expr`. `context` names an inline enum or object;
    /// `bounds` are the field's; `reached` stops a recursive type.
    fn ty(
        &mut self,
        expr: &Value,
        context: &str,
        bounds: Bounds,
        path: &str,
        reached: &mut Vec<String>,
    ) -> Result<Ty, String> {
        let kind = expr.get("kind").and_then(Value::as_str).unwrap_or_default();
        match kind {
            "ref" => {
                let name = expr
                    .get("name")
                    .and_then(Value::as_str)
                    .ok_or_else(|| format!("{path}: a ref needs a name"))?;
                let target =
                    self.types.get(name).ok_or_else(|| format!("{path}: unknown type {name:?}"))?;
                if reached.iter().any(|seen| seen == name) {
                    return Err(format!("{path}: recursive type {name:?} has no binary layout"));
                }
                reached.push(name.to_owned());
                let ty = self.ty(target, name, bounds, &format!("$.types.{name}"), reached);
                reached.pop();
                ty
            }
            "alias" => {
                let target =
                    expr.get("target").ok_or_else(|| format!("{path}: an alias needs a target"))?;
                self.ty(target, context, bounds, path, reached)
            }
            "scalar" => scalar(expr, bounds.max_bytes, path),
            "enum" => self.enumeration(expr, context, path),
            "object" => self.object(expr, context, path, reached),
            "array" => {
                // The field's bound is this array's; its items keep only the
                // field's `max_bytes`.
                let max_items = bounds
                    .max_items
                    .or_else(|| expr.get("max_items").and_then(Value::as_u64))
                    .filter(|n| *n <= MAX_PREFIXED)
                    .and_then(|n| u16::try_from(n).ok())
                    .ok_or_else(|| format!("{path}: a binary array needs max_items 0-65535"))?;
                let items = expr.get("items").ok_or_else(|| format!("{path}: no items"))?;
                let item_bounds = Bounds { max_items: None, ..bounds };
                let items =
                    self.ty(items, context, item_bounds, &format!("{path}.items"), reached)?;
                Ok(Ty::Array { items: Box::new(items), max_items })
            }
            other => Err(format!("{path}: {other:?} has no binary layout")),
        }
    }

    fn enumeration(&mut self, expr: &Value, name: &str, path: &str) -> Result<Ty, String> {
        let values: Vec<String> = expr
            .get("values")
            .and_then(Value::as_array)
            .map(|values| values.iter().filter_map(Value::as_str).map(str::to_owned).collect())
            .unwrap_or_default();
        if values.is_empty() || values.len() > 256 {
            return Err(format!("{path}: a binary enum needs 1-256 string values"));
        }
        let entry = Enum { name: name.to_owned(), values };
        self.register_enum(entry, path)?;
        Ok(Ty::Enum(name.to_owned()))
    }

    fn register_enum(&mut self, entry: Enum, path: &str) -> Result<(), String> {
        if self.model.structs.contains_key(&entry.name) {
            return Err(format!("{path}: {} names a struct and an enum", entry.name));
        }
        match self.model.enums.get(&entry.name) {
            Some(known) if *known != entry => {
                Err(format!("{path}: two enums are named {}", entry.name))
            }
            Some(_) => Ok(()),
            None => {
                self.model.enums.insert(entry.name.clone(), entry);
                Ok(())
            }
        }
    }

    fn object(
        &mut self,
        expr: &Value,
        name: &str,
        path: &str,
        reached: &mut Vec<String>,
    ) -> Result<Ty, String> {
        if expr.get("additional_properties").and_then(Value::as_bool) == Some(true) {
            return Err(format!("{path}: a binary object cannot allow additional properties"));
        }
        let empty = Map::new();
        let declared = expr.get("fields").and_then(Value::as_object).unwrap_or(&empty);
        // The layout order is the byte order of the names, whatever order
        // the map keeps (serde_json's `preserve_order` keeps the file's).
        let mut sorted: Vec<(&String, &Value)> = declared.iter().collect();
        sorted.sort_by(|a, b| a.0.as_bytes().cmp(b.0.as_bytes()));
        let mut fields = Vec::new();
        for (wire, field) in sorted {
            let field_path = format!("{path}.fields.{wire}");
            let ty_expr =
                field.get("type").ok_or_else(|| format!("{field_path}: a field needs a type"))?;
            if ty_expr.get("kind").and_then(Value::as_str) == Some("literal") {
                continue;
            }
            let bounds = Bounds {
                max_bytes: field.get("max_bytes").and_then(Value::as_u64),
                max_items: field.get("max_items").and_then(Value::as_u64),
            };
            let context = format!("{name}{}", pascal(wire));
            let ty = self.ty(ty_expr, &context, bounds, &field_path, reached)?;
            let tagged = field.get("presence").and_then(Value::as_str) != Some("required")
                || field.get("nullable").and_then(Value::as_bool) == Some(true);
            fields.push(Field { wire: wire.clone(), ty, tagged });
        }
        let entry = Struct { name: name.to_owned(), fields };
        if self.model.enums.contains_key(name) {
            return Err(format!("{path}: {name} names a struct and an enum"));
        }
        match self.model.structs.get(name) {
            Some(known) if *known != entry => {
                return Err(format!("{path}: two structs are named {name}"));
            }
            Some(_) => {}
            None => {
                self.model.structs.insert(name.to_owned(), entry);
            }
        }
        Ok(Ty::Object(name.to_owned()))
    }
}

fn scalar(expr: &Value, bound: Option<u64>, path: &str) -> Result<Ty, String> {
    let name = expr.get("name").and_then(Value::as_str).unwrap_or_default();
    Ok(match name {
        "boolean" => Ty::Bool,
        "uint16" => Ty::U16,
        "uint32" => Ty::U32,
        "uint64" => Ty::U64,
        "int32" => Ty::I32,
        "int64" => Ty::I64,
        "float32" => Ty::F32,
        "float64" => Ty::F64,
        "string" => {
            let max_bytes = bound
                .filter(|n| (1..=MAX_PREFIXED).contains(n))
                .and_then(|n| u16::try_from(n).ok())
                .ok_or_else(|| format!("{path}: a binary string needs max_bytes 1-65535"))?;
            Ty::Str { max_bytes }
        }
        other => return Err(format!("{path}: scalar {other:?} has no binary layout")),
    })
}

/// `resize-attached-view` -> `ResizeAttachedView`, `at_bottom` -> `AtBottom`.
pub fn pascal(name: &str) -> String {
    name.split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|part| !part.is_empty())
        .map(|part| {
            let mut chars = part.chars();
            chars.next().map(|first| first.to_ascii_uppercase().to_string() + chars.as_str())
        })
        .collect::<Option<String>>()
        .unwrap_or_default()
}

// Emitting --------------------------------------------------------------------

const KEYWORDS: &[&str] = &[
    "as", "async", "await", "box", "break", "const", "continue", "crate", "dyn", "else", "enum",
    "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move",
    "mut", "pub", "ref", "return", "self", "static", "struct", "super", "trait", "true", "type",
    "unsafe", "use", "where", "while", "yield",
];

fn field_ident(wire: &str) -> String {
    let ident: String =
        wire.chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '_' }).collect();
    if KEYWORDS.contains(&ident.as_str()) { format!("r#{ident}") } else { ident }
}

fn rust_type(ty: &Ty) -> String {
    match ty {
        Ty::Bool => "bool".into(),
        Ty::U16 => "u16".into(),
        Ty::U32 => "u32".into(),
        Ty::U64 => "u64".into(),
        Ty::I32 => "i32".into(),
        Ty::I64 => "i64".into(),
        Ty::F32 => "f32".into(),
        Ty::F64 => "f64".into(),
        Ty::Str { .. } => "String".into(),
        Ty::Enum(name) | Ty::Object(name) => name.clone(),
        Ty::Array { items, .. } => format!("Vec<{}>", rust_type(items)),
    }
}

/// Writes `v` (a `&T` of `ty`) with the `HotWriter` `w`.
fn write_expr(ty: &Ty) -> String {
    match ty {
        Ty::Bool => "w.bool(*v)".into(),
        Ty::U16 => "w.u16(*v)".into(),
        Ty::U32 => "w.u32(*v)".into(),
        Ty::U64 => "w.u64(*v)".into(),
        Ty::I32 => "w.i32(*v)".into(),
        Ty::I64 => "w.i64(*v)".into(),
        Ty::F32 => "w.f32(*v)".into(),
        Ty::F64 => "w.f64(*v)".into(),
        Ty::Str { max_bytes } => format!("w.str(v, {max_bytes})"),
        Ty::Enum(_) => "w.enumeration(v.index())".into(),
        Ty::Object(_) => "v.write(w)".into(),
        Ty::Array { items, max_items } => {
            format!("w.array(v, {max_items}, |w, v| {})", write_expr(items))
        }
    }
}

/// Reads a `ty` with the `HotReader` `r`, as a `Result`.
fn read_expr(ty: &Ty) -> String {
    match ty {
        Ty::Bool => "r.bool()".into(),
        Ty::U16 => "r.u16()".into(),
        Ty::U32 => "r.u32()".into(),
        Ty::U64 => "r.u64()".into(),
        Ty::I32 => "r.i32()".into(),
        Ty::I64 => "r.i64()".into(),
        Ty::F32 => "r.f32()".into(),
        Ty::F64 => "r.f64()".into(),
        Ty::Str { max_bytes } => format!("r.str({max_bytes})"),
        Ty::Enum(name) => format!("r.enumeration().and_then({name}::from_index)"),
        Ty::Object(name) => format!("{name}::read(r)"),
        Ty::Array { items, max_items } => format!("r.array({max_items}, |r| {})", read_expr(items)),
    }
}

/// `RESIZE_ATTACHED_VIEW_REQUEST`, `SIZE_STATE_EVENT`.
pub fn const_name(message: &Message) -> String {
    let base: String = message
        .name
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c.to_ascii_uppercase() } else { '_' })
        .collect();
    format!("{base}_{}", message.part.rust().to_ascii_uppercase())
}

fn layout_literal(m: &Message) -> String {
    format!(
        "HotLayout {{ name: {:?}, part: HotPart::{}, wire_id: 0x{:04X}, layout_version: {}, type_name: {:?} }}",
        m.name,
        m.part.rust(),
        m.wire_id,
        m.layout_version,
        m.ty
    )
}

/// The Rust source `src/hot.rs` includes: one type per struct and enum the
/// layouts reach, `HotValue` for each, a typed `Layout` constant per message
/// body, and `MESSAGES`, every layout (commands, then events, by name). A struct may be the
/// body of several messages (`EmptyResult`), each with its own version, so
/// the version lives in the constant, not in the type.
pub fn emit(model: &HotModel) -> String {
    let mut out = String::from(
        "// Generated by cmux-ipc build.rs (build-support/hot_codec.rs) from\n\
         // spec/sdk-schema.json. Do not edit; never committed.\n",
    );
    for entry in model.enums.values() {
        emit_enum(&mut out, entry);
    }
    for entry in model.structs.values() {
        emit_struct(&mut out, entry);
    }
    for m in &model.messages {
        let _ =
            writeln!(out, "\n/// The `{}` {} layout.", m.name, m.part.rust().to_ascii_lowercase());
        let _ = writeln!(
            out,
            "pub const {}: Layout<{}> = Layout::new({});",
            const_name(m),
            m.ty,
            layout_literal(m)
        );
    }
    out.push_str("\n/// Every binary layout of the schema: commands, then events, by name.\n");
    out.push_str("pub const MESSAGES: &[HotLayout] = &[\n");
    for m in &model.messages {
        let _ = writeln!(out, "    {},", layout_literal(m));
    }
    out.push_str("];\n");
    out
}

fn emit_enum(out: &mut String, entry: &Enum) {
    let _ = writeln!(out, "\n/// `{}`: a u8 index on the wire.", entry.name);
    let _ = writeln!(out, "#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]");
    let _ = writeln!(out, "pub enum {} {{", entry.name);
    for value in &entry.values {
        let _ = writeln!(out, "    /// `{value}`.");
        let _ = writeln!(out, "    {},", pascal(value));
    }
    let _ = writeln!(out, "}}\n\nimpl {} {{", entry.name);
    let _ = writeln!(out, "    /// Every value, in wire index order.");
    let _ = write!(out, "    pub const ALL: [Self; {}] = [", entry.values.len());
    for value in &entry.values {
        let _ = write!(out, "Self::{}, ", pascal(value));
    }
    let _ = writeln!(out, "];\n");
    let _ = writeln!(out, "    /// The schema spelling.");
    let _ =
        writeln!(out, "    pub const fn as_str(self) -> &'static str {{\n        match self {{");
    for value in &entry.values {
        let _ = writeln!(out, "            Self::{} => {value:?},", pascal(value));
    }
    let _ = writeln!(out, "        }}\n    }}\n");
    let _ = writeln!(out, "    /// The wire index.");
    let _ = writeln!(out, "    pub const fn index(self) -> u8 {{\n        match self {{");
    for (index, value) in entry.values.iter().enumerate() {
        let _ = writeln!(out, "            Self::{} => {index},", pascal(value));
    }
    let _ = writeln!(out, "        }}\n    }}\n");
    let _ = writeln!(
        out,
        "    fn from_index(index: u8) -> Result<Self, HotDecodeError> {{\n        \
         Self::ALL.get(usize::from(index)).copied().ok_or(HotDecodeError::BadEnum {{ type_name: {:?}, index }})\n    }}\n}}",
        entry.name
    );
}

fn emit_struct(out: &mut String, entry: &Struct) {
    let _ = writeln!(out, "\n/// `{}`, fields in layout order.", entry.name);
    let _ = writeln!(out, "#[derive(Clone, Debug, PartialEq)]");
    let _ = writeln!(out, "pub struct {} {{", entry.name);
    for field in &entry.fields {
        let ty = rust_type(&field.ty);
        let ty = if field.tagged { format!("Option<{ty}>") } else { ty };
        let _ = writeln!(out, "    /// `{}`.", field.wire);
        let _ = writeln!(out, "    pub {}: {ty},", field_ident(&field.wire));
    }
    let _ = writeln!(out, "}}\n\nimpl HotValue for {} {{", entry.name);
    let writer = if entry.fields.is_empty() { "_w" } else { "w" };
    let _ = writeln!(
        out,
        "    fn write(&self, {writer}: &mut HotWriter<'_>) -> Result<(), HotEncodeError> {{"
    );
    for field in &entry.fields {
        let ident = field_ident(&field.wire);
        let expr = write_expr(&field.ty);
        if field.tagged {
            let _ = writeln!(out, "        w.option(self.{ident}.as_ref(), |w, v| {expr})?;");
        } else {
            let _ = writeln!(
                out,
                "        {{\n            let v = &self.{ident};\n            {expr}?;\n        }}"
            );
        }
    }
    let _ = writeln!(out, "        Ok(())\n    }}\n");
    let reader = if entry.fields.is_empty() { "_r" } else { "r" };
    let _ = writeln!(
        out,
        "    fn read({reader}: &mut HotReader<'_>) -> Result<Self, HotDecodeError> {{\n        Ok(Self {{"
    );
    for field in &entry.fields {
        let ident = field_ident(&field.wire);
        let expr = read_expr(&field.ty);
        if field.tagged {
            let _ = writeln!(out, "            {ident}: r.option(|r| {expr})?,");
        } else {
            let _ = writeln!(out, "            {ident}: {expr}?,");
        }
    }
    let _ = writeln!(out, "        }})\n    }}\n}}");
}
