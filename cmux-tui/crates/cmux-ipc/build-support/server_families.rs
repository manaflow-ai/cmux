//! Writes the daemon's request params for the schema families listed in
//! `server-families.json` (p05-ipc design 3.3, tasks 026 and 029: queue Q15).
//! Shared by `build.rs`, which writes the macros into `OUT_DIR`, and by the
//! crate's tests, which feed it schemas that must be refused.
//!
//! Mojo generates each interface's request structs from its mojom
//! (mojo/public/tools/bindings/generators/cpp_templates/struct_declaration.tmpl);
//! here each listed family's commands become structs, one per command, with the
//! serde rules the hand-written `Command` variants had:
//!
//! - required: the type, no default;
//! - required and nullable: `Option<T>` that must be present (`null` is `None`);
//! - optional and nullable with a schema `default`: `Option<T>`, absent and
//!   `null` both `None` (the handler applies a non-null default);
//! - optional and nullable without a `default`: absent and `null` differ, so
//!   `Option<Option<T>>` (absent `None`, `null` `Some(None)`: "null clears");
//! - optional, not nullable: the type, with its schema default.
//!
//! `server-families.json` `refused_fields` adds, per command, a pre-rename
//! field the handler refuses: `Option<serde_json::Value>`. The structs ignore
//! unknown fields, as the hand-written enum did. Its `boxed` names, per
//! command, a params struct the enum holds in a `Box`, with its reason: one
//! large, rarely sent command must not grow every `Command` (clippy's
//! `large_enum_variant`, which cannot see a macro's variants).
//!
//! The output is two kinds of `#[macro_export]` macro, so the structs are local
//! types of the daemon crate (which owns the field types the schema names by
//! ref, and the handlers' inherent impls):
//!
//! - `<family>_params! { Ref = Type, ... }` defines every struct of that family.
//!   Each object type the family names by ref is a parameter, in name order.
//! - `server_command_enum! { <family> = <module>; <enum> }` appends one variant
//!   per command of every listed family to the enum it is given: a newtype
//!   over the struct in `<module>` (or over its `Box`), or a unit variant for
//!   a command with no fields.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt::{self, Write as _};

use serde_json::{Map, Value};

/// Why the schema cannot become params. `path` is a JSON path into the file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EmitError {
    pub path: String,
    pub message: String,
}

impl fmt::Display for EmitError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.path, self.message)
    }
}

fn error(path: impl Into<String>, message: impl Into<String>) -> EmitError {
    EmitError { path: path.into(), message: message.into() }
}

/// The families `server-families.json` lists, in its order.
pub fn listed_families(doc: &Value) -> Result<Vec<String>, EmitError> {
    let list = doc
        .get("families")
        .and_then(Value::as_array)
        .ok_or_else(|| error("$.families", "must be an array of family names"))?;
    let mut names = Vec::with_capacity(list.len());
    for (index, name) in list.iter().enumerate() {
        let name = name
            .as_str()
            .ok_or_else(|| error(format!("$.families[{index}]"), "must be a string"))?;
        if names.iter().any(|known| known == name) {
            return Err(error(format!("$.families[{index}]"), format!("{name:?} is listed twice")));
        }
        names.push(name.to_owned());
    }
    Ok(names)
}

/// One request field: its Rust name and type, and its serde attribute.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Field {
    pub wire: String,
    pub ident: String,
    pub rust_type: String,
    /// `default`, `default = "<fn>"`, `alias = ...`: the inside of `#[serde(...)]`.
    pub serde: Vec<String>,
    /// A default other than the type's `Default`: `(fn name, Rust type, expression)`.
    pub default_fn: Option<(String, String, String)>,
    /// The `deserialize_with` reader of a nullable field that tells `null`
    /// from absent; the params macro defines each reader its family uses.
    pub reader: Option<Reader>,
}

/// A serde reader the params macro defines once in its family's module.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Reader {
    /// Required and nullable: must be present; `null` is `None`.
    RequiredNullable,
    /// Optional and nullable without a default: absent is `None` (by
    /// `default`), `null` is `Some(None)`.
    PresentNullable,
}

impl Reader {
    pub fn name(self) -> &'static str {
        match self {
            Self::RequiredNullable => "required_nullable",
            Self::PresentNullable => "present_nullable",
        }
    }

    /// The reader's function, generic over the type inside the options.
    fn definition(self) -> String {
        let (output, wrap) = match self {
            Self::RequiredNullable => ("::core::option::Option<T>", ""),
            Self::PresentNullable => (
                "::core::option::Option<::core::option::Option<T>>",
                ".map(::core::option::Option::Some)",
            ),
        };
        let name = self.name();
        let mut code = String::new();
        let _ = writeln!(code, "        fn {name}<'de, D, T>(");
        let _ = writeln!(code, "            deserializer: D,");
        let _ = writeln!(code, "        ) -> ::core::result::Result<{output}, D::Error>");
        let _ = writeln!(code, "        where");
        let _ = writeln!(code, "            D: ::serde::Deserializer<'de>,");
        let _ = writeln!(code, "            T: ::serde::Deserialize<'de>,");
        let _ = writeln!(code, "        {{");
        let _ = writeln!(
            code,
            "            <::core::option::Option<T> as ::serde::Deserialize>::deserialize(deserializer){wrap}"
        );
        let _ = writeln!(code, "        }}");
        code
    }
}

/// The type of a refused field (`server-families.json` `refused_fields`): the
/// handler refuses any value but `null`.
pub const REFUSED_TYPE: &str = "::core::option::Option<::serde_json::Value>";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Command {
    pub wire: String,
    pub method_id: u16,
    pub variant: String,
    pub fields: Vec<Field>,
    /// The enum holds the params in a `Box` (`server-families.json` `boxed`).
    pub boxed: bool,
}

impl Command {
    /// The params struct's name; a command without fields has none.
    pub fn params(&self) -> Option<String> {
        (!self.fields.is_empty()).then(|| format!("{}Params", self.variant))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Family {
    pub name: String,
    pub id: u8,
    /// The family's name in snake case: the macro prefix and module parameter.
    pub snake: String,
    pub commands: Vec<Command>,
    /// Object types the family's fields name by ref: the macro's parameters.
    pub refs: BTreeSet<String>,
}

/// The listed families of `sdk`, their commands in method id order.
pub fn read(sdk: &Value, listed: &[String]) -> Result<Vec<Family>, EmitError> {
    let declared = sdk
        .get("families")
        .and_then(Value::as_object)
        .ok_or_else(|| error("$.families", "must be an object"))?;
    let commands = sdk
        .get("commands")
        .and_then(Value::as_object)
        .ok_or_else(|| error("$.commands", "must be an object"))?;
    let types = sdk.get("types").and_then(Value::as_object).cloned().unwrap_or_default();
    let mut families = Vec::with_capacity(listed.len());
    for name in listed {
        let id = declared
            .get(name)
            .and_then(|family| family.get("id"))
            .and_then(Value::as_u64)
            .and_then(|id| u8::try_from(id).ok())
            .ok_or_else(|| {
                error(format!("$.families.{name}"), "is not a family of sdk-schema.json")
            })?;
        families.push(family(name, id, commands, &types)?);
    }
    Ok(families)
}

/// Adds `server-families.json` `refused_fields` (`{command: {field: reason}}`)
/// to the generated commands: each one a [`REFUSED_TYPE`] field after the
/// schema's. A refused field must name a generated command, must not be a
/// schema field and needs a reason.
pub fn add_refused_fields(families: &mut [Family], doc: &Value) -> Result<(), EmitError> {
    let Some(refused) = doc.get("refused_fields") else {
        return Ok(());
    };
    let refused = refused
        .as_object()
        .ok_or_else(|| error("$.refused_fields", "must be an object of commands"))?;
    for (wire, fields) in refused {
        let path = format!("$.refused_fields.{wire}");
        let command = families
            .iter_mut()
            .flat_map(|family| family.commands.iter_mut())
            .find(|command| command.wire == *wire)
            .ok_or_else(|| error(&path, "is not a command of a listed family"))?;
        let fields =
            fields.as_object().ok_or_else(|| error(&path, "must be an object of fields"))?;
        for (name, reason) in fields {
            let field_path = format!("{path}.{name}");
            if reason.as_str().is_none_or(|reason| reason.trim().is_empty()) {
                return Err(error(&field_path, "needs a reason"));
            }
            if command.fields.iter().any(|field| field.wire == *name) {
                return Err(error(&field_path, "is a schema field"));
            }
            let ident =
                field_ident(name).ok_or_else(|| error(&field_path, "is not a snake_case name"))?;
            command.fields.push(Field {
                wire: name.clone(),
                ident,
                rust_type: REFUSED_TYPE.to_owned(),
                serde: vec!["default".to_owned()],
                default_fn: None,
                reader: None,
            });
        }
    }
    Ok(())
}

/// Marks the commands `server-families.json` `boxed` (`{command: reason}`):
/// the enum holds their params in a `Box`. A boxed command must be a generated
/// command with params and needs a reason.
pub fn box_variants(families: &mut [Family], doc: &Value) -> Result<(), EmitError> {
    let Some(boxed) = doc.get("boxed") else {
        return Ok(());
    };
    let boxed =
        boxed.as_object().ok_or_else(|| error("$.boxed", "must be an object of commands"))?;
    for (wire, reason) in boxed {
        let path = format!("$.boxed.{wire}");
        let command = families
            .iter_mut()
            .flat_map(|family| family.commands.iter_mut())
            .find(|command| command.wire == *wire)
            .ok_or_else(|| error(&path, "is not a command of a listed family"))?;
        if reason.as_str().is_none_or(|reason| reason.trim().is_empty()) {
            return Err(error(&path, "needs a reason"));
        }
        if command.fields.is_empty() {
            return Err(error(&path, "has no params to box"));
        }
        command.boxed = true;
    }
    Ok(())
}

fn family(
    name: &str,
    id: u8,
    commands: &Map<String, Value>,
    types: &Map<String, Value>,
) -> Result<Family, EmitError> {
    let mut refs = BTreeSet::new();
    let mut found = BTreeMap::new();
    for (wire, command) in commands {
        let Some(method_id) = command.get("method_id").and_then(Value::as_u64) else {
            continue;
        };
        let path = format!("$.commands.{wire}");
        let method_id = u16::try_from(method_id)
            .map_err(|_| error(format!("{path}.method_id"), "must be a u16"))?;
        if method_id >> 8 != u16::from(id) {
            continue;
        }
        let variant = pascal(wire).ok_or_else(|| error(&path, "is not a kebab-case name"))?;
        let fields = request_fields(&path, wire, command, types, &mut refs)?;
        found.insert(
            method_id,
            Command { wire: wire.clone(), method_id, variant, fields, boxed: false },
        );
    }
    if found.is_empty() {
        return Err(error(format!("$.families.{name}"), "has no command with a method_id"));
    }
    Ok(Family {
        name: name.to_owned(),
        id,
        snake: name.replace('-', "_"),
        commands: found.into_values().collect(),
        refs,
    })
}

fn request_fields(
    path: &str,
    wire: &str,
    command: &Value,
    types: &Map<String, Value>,
    refs: &mut BTreeSet<String>,
) -> Result<Vec<Field>, EmitError> {
    let request = command
        .get("request")
        .and_then(Value::as_object)
        .ok_or_else(|| error(format!("{path}.request"), "must be an object"))?;
    if request.get("kind").and_then(Value::as_str) != Some("object") {
        return Err(error(format!("{path}.request.kind"), "must be \"object\""));
    }
    let Some(fields) = request.get("fields") else {
        return Ok(Vec::new());
    };
    let fields = fields
        .as_object()
        .ok_or_else(|| error(format!("{path}.request.fields"), "must be an object"))?;
    let mut out = Vec::with_capacity(fields.len());
    for (name, field) in fields {
        let field_path = format!("{path}.request.fields.{name}");
        out.push(request_field(&field_path, wire, name, field, types, refs)?);
    }
    Ok(out)
}

fn request_field(
    path: &str,
    wire: &str,
    name: &str,
    field: &Value,
    types: &Map<String, Value>,
    refs: &mut BTreeSet<String>,
) -> Result<Field, EmitError> {
    let ident = field_ident(name).ok_or_else(|| error(path, "is not a snake_case name"))?;
    let expression =
        field.get("type").ok_or_else(|| error(format!("{path}.type"), "is missing"))?;
    let base = rust_type(&format!("{path}.type"), expression, types, refs)?;
    let required = match field.get("presence").and_then(Value::as_str) {
        Some("required") => true,
        Some("optional") => false,
        _ => return Err(error(format!("{path}.presence"), "must be required or optional")),
    };
    let nullable = field.get("nullable").and_then(Value::as_bool).unwrap_or(false);
    let mut serde = Vec::new();
    let mut default_fn = None;
    let mut reader = None;
    let rust_type = match (required, nullable) {
        (true, false) => base,
        (true, true) => {
            // serde reads an absent `Option` field as `None`; a reader keeps
            // the field required.
            reader = Some(Reader::RequiredNullable);
            serde.push(format!("deserialize_with = {:?}", Reader::RequiredNullable.name()));
            format!("::core::option::Option<{base}>")
        }
        (false, true) if field.get("default").is_some() => {
            serde.push("default".to_owned());
            format!("::core::option::Option<{base}>")
        }
        (false, true) => {
            reader = Some(Reader::PresentNullable);
            serde.push("default".to_owned());
            serde.push(format!("deserialize_with = {:?}", Reader::PresentNullable.name()));
            // The tests' Serialize derive writes absent as absent, `null` as `null`.
            serde.push("skip_serializing_if = \"::core::option::Option::is_none\"".to_owned());
            format!("::core::option::Option<::core::option::Option<{base}>>")
        }
        (false, false) => {
            let default = field.get("default").ok_or_else(|| {
                error(path, "an optional field that is not nullable needs a default")
            })?;
            match default_expression(&format!("{path}.default"), &base, default)? {
                None => serde.push("default".to_owned()),
                Some(expression) => {
                    let function = format!("{}_{name}_default", wire.replace('-', "_"));
                    serde.push(format!("default = {function:?}"));
                    default_fn = Some((function, base.clone(), expression));
                }
            }
            base
        }
    };
    if let Some(aliases) = field.get("aliases") {
        let aliases = aliases
            .as_array()
            .ok_or_else(|| error(format!("{path}.aliases"), "must be an array"))?;
        for alias in aliases {
            let alias = alias
                .as_str()
                .ok_or_else(|| error(format!("{path}.aliases"), "must hold strings"))?;
            serde.push(format!("alias = {alias:?}"));
        }
    }
    Ok(Field { wire: name.to_owned(), ident, rust_type, serde, default_fn, reader })
}

/// The Rust type of a schema type expression. An object type named by ref
/// becomes the macro parameter `$Name`.
fn rust_type(
    path: &str,
    expression: &Value,
    types: &Map<String, Value>,
    refs: &mut BTreeSet<String>,
) -> Result<String, EmitError> {
    let kind = expression.get("kind").and_then(Value::as_str).unwrap_or_default();
    match kind {
        "scalar" => {
            let name = expression.get("name").and_then(Value::as_str).unwrap_or_default();
            scalar(name)
                .map(str::to_owned)
                .ok_or_else(|| error(path, format!("unknown scalar {name:?}")))
        }
        "alias" => {
            let target =
                expression.get("target").ok_or_else(|| error(path, "alias has no target"))?;
            rust_type(&format!("{path}.target"), target, types, refs)
        }
        // The hand-written enum took these as strings and checked the value in
        // the handler, which answers with its own error; so do these structs.
        "enum" => {
            let values = expression.get("values").and_then(Value::as_array);
            if values.is_some_and(|values| values.iter().all(Value::is_string)) {
                Ok("::std::string::String".to_owned())
            } else {
                Err(error(path, "only string enums are generated"))
            }
        }
        "array" => {
            let items = expression.get("items").ok_or_else(|| error(path, "array has no items"))?;
            let item = rust_type(&format!("{path}.items"), items, types, refs)?;
            Ok(format!("::std::vec::Vec<{item}>"))
        }
        "map" => {
            let values =
                expression.get("values").ok_or_else(|| error(path, "map has no values"))?;
            let value = rust_type(&format!("{path}.values"), values, types, refs)?;
            Ok(format!("::std::collections::BTreeMap<::std::string::String, {value}>"))
        }
        "ref" => {
            let name = expression.get("name").and_then(Value::as_str).unwrap_or_default();
            let target = types
                .get(name)
                .ok_or_else(|| error(path, format!("names unknown type {name:?}")))?;
            if target.get("kind").and_then(Value::as_str) == Some("alias") {
                return rust_type(&format!("$.types.{name}"), target, types, refs);
            }
            if !name.chars().all(|c| c.is_ascii_alphanumeric())
                || !name.starts_with(|c: char| c.is_ascii_uppercase())
            {
                return Err(error(path, format!("type name {name:?} is not PascalCase")));
            }
            refs.insert(name.to_owned());
            Ok(format!("${name}"))
        }
        other => Err(error(path, format!("type kind {other:?} is not generated yet"))),
    }
}

fn scalar(name: &str) -> Option<&'static str> {
    Some(match name {
        "string" => "::std::string::String",
        "boolean" => "bool",
        "uint16" => "u16",
        "uint32" => "u32",
        "uint64" => "u64",
        "int32" => "i32",
        "int64" => "i64",
        "float32" => "f32",
        "float64" => "f64",
        _ => return None,
    })
}

/// `None` when the type's `Default` is the schema default (`false`, `0`,
/// `""`), else the expression of a default function.
fn default_expression(
    path: &str,
    rust: &str,
    default: &Value,
) -> Result<Option<String>, EmitError> {
    let mismatch = || error(path, format!("does not fit the field type {rust}"));
    match (rust, default) {
        ("bool", Value::Bool(value)) => Ok(value.then(|| "true".to_owned())),
        // `[]` and `{}` are an empty Vec's and BTreeMap's `Default`.
        (_, Value::Array(items)) if items.is_empty() && rust.starts_with("::std::vec::Vec<") => {
            Ok(None)
        }
        (_, Value::Object(members))
            if members.is_empty() && rust.starts_with("::std::collections::BTreeMap<") =>
        {
            Ok(None)
        }
        ("::std::string::String", Value::String(value)) => {
            Ok((!value.is_empty()).then(|| format!("::std::string::String::from({value:?})")))
        }
        (_, Value::Number(number)) if rust.starts_with(['u', 'i']) => {
            let fits = match rust {
                "u16" => number.as_u64().is_some_and(|v| u16::try_from(v).is_ok()),
                "u32" => number.as_u64().is_some_and(|v| u32::try_from(v).is_ok()),
                "u64" => number.as_u64().is_some(),
                "i32" => number.as_i64().is_some_and(|v| i32::try_from(v).is_ok()),
                "i64" => number.as_i64().is_some(),
                _ => false,
            };
            if !fits {
                return Err(mismatch());
            }
            let zero = number.as_u64() == Some(0) || number.as_i64() == Some(0);
            Ok((!zero).then(|| number.to_string()))
        }
        _ => Err(mismatch()),
    }
}

/// `read-screen` -> `ReadScreen`.
fn pascal(wire: &str) -> Option<String> {
    let valid = wire.starts_with(|c: char| c.is_ascii_lowercase())
        && wire.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
        && !wire.contains("--")
        && !wire.ends_with('-');
    valid.then(|| {
        wire.split('-')
            .map(|part| {
                let mut chars = part.chars();
                chars.next().map_or_else(String::new, |first| {
                    first.to_ascii_uppercase().to_string() + chars.as_str()
                })
            })
            .collect()
    })
}

const KEYWORDS: &[&str] = &[
    "as", "async", "await", "break", "const", "continue", "dyn", "else", "enum", "extern", "false",
    "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref",
    "return", "static", "struct", "trait", "true", "type", "unsafe", "use", "where", "while",
    "abstract", "become", "box", "do", "final", "gen", "macro", "override", "priv", "try",
    "typeof", "unsized", "virtual", "yield",
];

/// A wire field name as a Rust field; a keyword becomes a raw identifier,
/// which serde reads under its plain name.
fn field_ident(name: &str) -> Option<String> {
    let valid = name.starts_with(|c: char| c.is_ascii_lowercase() || c == '_')
        && name.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_');
    if !valid || matches!(name, "self" | "super" | "crate" | "Self" | "_") {
        return None;
    }
    Some(if KEYWORDS.contains(&name) { format!("r#{name}") } else { name.to_owned() })
}

/// Both macros for `families`.
pub fn emit(families: &[Family]) -> String {
    let mut code = String::new();
    // Writing to a String cannot fail.
    let _ =
        writeln!(code, "// Generated by cmux-ipc build.rs from spec/sdk-schema.json; not in git.");
    for family in families {
        emit_params(&mut code, family);
    }
    emit_enum(&mut code, families);
    code
}

fn emit_params(code: &mut String, family: &Family) {
    let name = &family.name;
    let _ = writeln!(
        code,
        "/// The request params of every `{name}` command (family 0x{:02X}), one struct per",
        family.id
    );
    let _ =
        writeln!(code, "/// command with fields. Arguments: the Rust type of each object type the");
    let _ = writeln!(code, "/// family names by ref, in name order.");
    let _ = writeln!(code, "#[macro_export]");
    let _ = writeln!(code, "macro_rules! {}_params {{", family.snake);
    let parameters: Vec<String> =
        family.refs.iter().map(|name| format!("{name} = ${name}:ty")).collect();
    let _ = writeln!(code, "    ({} $(,)?) => {{", parameters.join(", "));
    let readers: BTreeSet<Reader> = family
        .commands
        .iter()
        .flat_map(|command| command.fields.iter().filter_map(|field| field.reader))
        .collect();
    for reader in readers {
        code.push_str(&reader.definition());
    }
    for command in &family.commands {
        let Some(params) = command.params() else { continue };
        for field in &command.fields {
            if let Some((function, rust, expression)) = &field.default_fn {
                let _ = writeln!(code, "        fn {function}() -> {rust} {{");
                let _ = writeln!(code, "            {expression}");
                let _ = writeln!(code, "        }}");
            }
        }
        let doc = format!(
            "`{}`: {name} method 0x{:04X}, from spec/sdk-schema.json (cmux-ipc build.rs).",
            command.wire, command.method_id
        );
        let _ = writeln!(code, "        #[doc = {doc:?}]");
        let _ = writeln!(code, "        #[derive(Debug, ::serde::Deserialize)]");
        let _ = writeln!(code, "        #[cfg_attr(test, derive(::serde::Serialize))]");
        let _ = writeln!(code, "        pub(crate) struct {params} {{");
        for field in &command.fields {
            if !field.serde.is_empty() {
                let _ = writeln!(code, "            #[serde({})]", field.serde.join(", "));
            }
            let _ = writeln!(code, "            pub(crate) {}: {},", field.ident, field.rust_type);
        }
        let _ = writeln!(code, "        }}");
    }
    let _ = writeln!(code, "    }};");
    let _ = writeln!(code, "}}");
}

fn emit_enum(code: &mut String, families: &[Family]) {
    let _ =
        writeln!(code, "/// Appends a variant per command of every generated family to the given");
    let _ =
        writeln!(code, "/// `cmd`-tagged enum. Arguments: `<family> = <module>;` for each family,");
    let _ =
        writeln!(code, "/// the module where its `<family>_params!` structs are; then the enum.");
    let _ = writeln!(code, "#[macro_export]");
    let _ = writeln!(code, "macro_rules! server_command_enum {{");
    let _ = writeln!(code, "    (");
    for family in families {
        let _ = writeln!(code, "        {0} = ${0}:ident;", family.snake);
    }
    let _ = writeln!(code, "        $(#[$meta:meta])*");
    let _ = writeln!(code, "        $vis:vis enum $name:ident {{ $($variants:tt)* }}");
    let _ = writeln!(code, "    ) => {{");
    let _ = writeln!(code, "        $(#[$meta])*");
    let _ = writeln!(code, "        $vis enum $name {{");
    let _ = writeln!(code, "            $($variants)*");
    for family in families {
        for command in &family.commands {
            let doc = format!("`{}` ({} 0x{:04X}).", command.wire, family.name, command.method_id);
            let _ = writeln!(code, "            #[doc = {doc:?}]");
            let _ = writeln!(code, "            #[serde(rename = {:?})]", command.wire);
            match command.params() {
                Some(params) if command.boxed => {
                    let _ = writeln!(
                        code,
                        "            {}(::std::boxed::Box<${}::{params}>),",
                        command.variant, family.snake
                    );
                }
                Some(params) => {
                    let _ = writeln!(
                        code,
                        "            {}(${}::{params}),",
                        command.variant, family.snake
                    );
                }
                None => {
                    let _ = writeln!(code, "            {},", command.variant);
                }
            }
        }
    }
    let _ = writeln!(code, "        }}");
    let _ = writeln!(code, "    }};");
    let _ = writeln!(code, "}}");
}
