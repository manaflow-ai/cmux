//! Writes the client request types of one client (`clients` in
//! spec/sdk-schema.json) as Rust: one `<Command>Request` struct per command
//! the client sends, with its wire name and method id, and the named types its
//! fields reach (p05-ipc design 3.3, task 028). `src/client.rs` includes the
//! output; build.rs writes it into OUT_DIR for the `cli` client.
//!
//! Mojo generates one request struct per interface method with its ordinal
//! (mojo/public/tools/bindings/generators/cpp_templates/
//! struct_declaration.tmpl and interface_declaration.tmpl); a caller fills
//! the struct and never spells a method name. These types do the same for the
//! JSON-line wire: `ClientRequest::line` writes `{"id", "cmd", fields...}`.
//!
//! A field's Rust type follows its presence and nullability with the same
//! four shapes as the Rust SDK (bindings/codegen/emit_rust.py), spelled with
//! `Option` because cmux-ipc stays std-only and does not depend on the SDK:
//! - required, not nullable: `T` (SDK `T`);
//! - required, nullable: `Option<T>`, `None` is `null` (SDK `Nullable<T>`);
//! - optional, not nullable: `Option<T>`, `None` leaves the field out (SDK
//!   `Option<T>`);
//! - optional, nullable: `Option<Option<T>>`, `None` leaves the field out and
//!   `Some(None)` sends `null` (SDK `presence::Optional<T>`).
//!
//! A `default` does not change the shape: the daemon applies it to an absent
//! field, and a nullable field can still be sent as `null`. The test
//! `cli_wire_request_shapes_agree_with_the_sdk` checks every `cli` request
//! against the SDK's generated struct, field by field.
//!
//! A `literal` field is a constant the encoder writes; it has no Rust field.
//! A field with a `capability` gets `<FIELD>_CAPABILITY` on its struct.
//! `opaque_json` and `untagged_union` types are `Value`. Anything else the
//! emitter cannot type fails the build with its JSON path, and so does a
//! tagged-union variant that does not carry its tag as a required literal
//! equal to the variant name.

use std::collections::{BTreeMap, VecDeque};
use std::fmt::{self, Write as _};

use serde_json::{Map, Value};

/// The client whose request types the build writes for the Rust CLI.
pub const CLI: &str = "cli";

/// Why the schema cannot become client types. `path` is a JSON path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClientError {
    pub path: String,
    pub message: String,
}

impl fmt::Display for ClientError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.path, self.message)
    }
}

fn error(path: impl Into<String>, message: impl Into<String>) -> ClientError {
    ClientError { path: path.into(), message: message.into() }
}

/// The Rust for every command of `doc` whose `clients` lists `client`.
pub fn emit(doc: &Value, client: &str) -> Result<String, ClientError> {
    let commands = object(doc.get("commands"), "$.commands")?;
    let empty = Map::new();
    let types = match doc.get("types") {
        None => &empty,
        Some(types) => object(Some(types), "$.types")?,
    };
    let mut emitter =
        Emitter { types, out: String::new(), claimed: BTreeMap::new(), queue: VecDeque::new() };
    let mut listed = Vec::new();
    for (name, command) in commands {
        if !sends(command, client) {
            continue;
        }
        let path = format!("$.commands.{name}");
        let rust = format!("{}Request", pascal(name, &path)?);
        let id = command
            .get("method_id")
            .and_then(Value::as_u64)
            .and_then(|id| u16::try_from(id).ok())
            .ok_or_else(|| {
                error(format!("{path}.method_id"), "a client command needs a u16 method_id")
            })?;
        let capability = command.get("capability").and_then(Value::as_str);
        let request = command.get("request").ok_or_else(|| error(&path, "has no request"))?;
        if request.get("kind").and_then(Value::as_str) != Some("object") {
            return Err(error(format!("{path}.request"), "a request must be an object"));
        }
        for envelope in ["id", "cmd"] {
            if request.get("fields").and_then(|fields| fields.get(envelope)).is_some() {
                return Err(error(
                    format!("{path}.request.fields.{envelope}"),
                    "collides with the line envelope",
                ));
            }
        }
        emitter.claim(&rust, &format!("{path}.request"))?;
        let doc_line = format!("The `{name}` request (method 0x{id:04X}).");
        emitter.object(&rust, &doc_line, request, &format!("{path}.request"))?;
        let _ = writeln!(emitter.out, "impl ClientRequest for {rust} {{");
        let _ = writeln!(emitter.out, "    const CMD: &'static str = {name:?};");
        let _ = writeln!(emitter.out, "    const METHOD_ID: MethodId = MethodId::new(0x{id:04X});");
        let _ =
            writeln!(emitter.out, "    const CAPABILITY: Option<&'static str> = {capability:?};");
        let _ = writeln!(emitter.out, "}}\n");
        listed.push((name.clone(), id));
        emitter.drain()?;
    }
    let _ = writeln!(emitter.out, "/// Every command this client sends: wire name and method id.");
    let _ = writeln!(emitter.out, "pub const COMMANDS: &[(&str, MethodId)] = &[");
    for (name, id) in listed {
        let _ = writeln!(emitter.out, "    ({name:?}, MethodId::new(0x{id:04X})),");
    }
    let _ = writeln!(emitter.out, "];");
    Ok(emitter.out)
}

fn sends(command: &Value, client: &str) -> bool {
    command
        .get("clients")
        .and_then(Value::as_array)
        .is_some_and(|clients| clients.iter().any(|entry| entry.as_str() == Some(client)))
}

fn object<'a>(value: Option<&'a Value>, path: &str) -> Result<&'a Map<String, Value>, ClientError> {
    value.and_then(Value::as_object).ok_or_else(|| error(path, "must be an object"))
}

fn text<'a>(node: &'a Value, key: &str, path: &str) -> Result<&'a str, ClientError> {
    node.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| error(format!("{path}.{key}"), "must be a string"))
}

/// `kebab-case`, `snake_case` or `dotted.name` as `PascalCase`.
fn pascal(name: &str, path: &str) -> Result<String, ClientError> {
    let mut out = String::new();
    for part in name.split(['-', '_', '.']) {
        let mut chars = part.chars();
        if let Some(first) = chars.next() {
            out.extend(first.to_uppercase());
            out.push_str(chars.as_str());
        }
    }
    let valid = out.chars().next().is_some_and(|first| first.is_ascii_uppercase())
        && out.chars().all(|c| c.is_ascii_alphanumeric());
    if valid { Ok(out) } else { Err(error(path, format!("{name:?} is not a Rust type name"))) }
}

const KEYWORDS: &[&str] = &[
    "abstract", "as", "async", "await", "become", "box", "break", "const", "continue", "crate",
    "do", "dyn", "else", "enum", "extern", "false", "final", "fn", "for", "gen", "if", "impl",
    "in", "let", "loop", "macro", "match", "mod", "move", "mut", "override", "priv", "pub", "ref",
    "return", "self", "static", "struct", "super", "trait", "true", "try", "type", "typeof",
    "unsafe", "unsized", "use", "virtual", "where", "while", "yield",
];

/// A wire field name as a Rust field: keywords get a trailing `_`.
fn field_ident(name: &str, path: &str) -> Result<String, ClientError> {
    let valid = name.chars().next().is_some_and(|first| first.is_ascii_lowercase() || first == '_')
        && name.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_');
    if !valid {
        return Err(error(path, format!("{name:?} is not a Rust field name")));
    }
    Ok(if KEYWORDS.contains(&name) { format!("{name}_") } else { name.to_owned() })
}

/// How a field is written and typed.
enum Shape {
    /// A constant the encoder always writes.
    Literal(String),
    /// `T` or `Option<T>` written every time (`None` is `null`).
    Always(String),
    /// `Option<..>` left out when `None`.
    Omittable(String),
}

struct Emitter<'a> {
    types: &'a Map<String, Value>,
    out: String,
    /// Rust type name -> the schema path that declared it.
    claimed: BTreeMap<String, String>,
    /// Types claimed but not written yet: Rust name, schema node, path.
    queue: VecDeque<(String, &'a Value, String)>,
}

impl<'a> Emitter<'a> {
    fn claim(&mut self, rust: &str, path: &str) -> Result<(), ClientError> {
        if let Some(other) = self.claimed.insert(rust.to_owned(), path.to_owned()) {
            return Err(error(path, format!("Rust type {rust} is also {other}")));
        }
        Ok(())
    }

    /// Writes every queued type.
    fn drain(&mut self) -> Result<(), ClientError> {
        while let Some((rust, node, path)) = self.queue.pop_front() {
            let kind = text(node, "kind", &path)?;
            match kind {
                "object" => self.object(&rust, &format!("`{path}`."), node, &path)?,
                "enum" => self.enumeration(&rust, node, &path)?,
                "tagged_union" => self.tagged_union(&rust, node, &path)?,
                other => return Err(error(&path, format!("cannot declare a {other:?} type"))),
            }
        }
        Ok(())
    }

    /// The Rust type of `node`; inline objects, enums and unions are named
    /// `<owner><Field>` and queued.
    fn rust_type(
        &mut self,
        node: &'a Value,
        owner: &str,
        path: &str,
    ) -> Result<String, ClientError> {
        match text(node, "kind", path)? {
            "scalar" => scalar(text(node, "name", path)?, path),
            "array" => {
                let items = node.get("items").ok_or_else(|| error(path, "array has no items"))?;
                Ok(format!("Vec<{}>", self.rust_type(items, owner, &format!("{path}.items"))?))
            }
            "map" => {
                let values = node.get("values").ok_or_else(|| error(path, "map has no values"))?;
                Ok(format!(
                    "BTreeMap<String, {}>",
                    self.rust_type(values, owner, &format!("{path}.values"))?
                ))
            }
            "ref" => self.named(text(node, "name", path)?, path),
            "opaque_json" | "untagged_union" => Ok("Value".to_owned()),
            "object" | "enum" | "tagged_union" => {
                // An alias target is resolved on every reference; declare it once.
                if self.claimed.get(owner).is_some_and(|claimed| claimed == path) {
                    return Ok(owner.to_owned());
                }
                self.claim(owner, path)?;
                self.queue.push_back((owner.to_owned(), node, path.to_owned()));
                Ok(owner.to_owned())
            }
            other => Err(error(path, format!("cannot type a {other:?}"))),
        }
    }

    /// A `ref`: aliases resolve to their target, other types are declared once.
    fn named(&mut self, name: &str, path: &str) -> Result<String, ClientError> {
        let type_path = format!("$.types.{name}");
        let node = self.types.get(name).ok_or_else(|| error(path, format!("no type {name:?}")))?;
        match text(node, "kind", &type_path)? {
            "alias" => {
                let target =
                    node.get("target").ok_or_else(|| error(&type_path, "alias has no target"))?;
                let owner = pascal(name, &type_path)?;
                self.rust_type(target, &owner, &format!("{type_path}.target"))
            }
            "opaque_json" | "untagged_union" => Ok("Value".to_owned()),
            _ => {
                let rust = pascal(name, &type_path)?;
                match self.claimed.get(&rust) {
                    Some(owner) if *owner == type_path => {}
                    _ => {
                        self.claim(&rust, &type_path)?;
                        self.queue.push_back((rust.clone(), node, type_path));
                    }
                }
                Ok(rust)
            }
        }
    }

    fn shape(
        &mut self,
        field: &'a Value,
        owner: &str,
        name: &str,
        path: &str,
    ) -> Result<Shape, ClientError> {
        let ty = field.get("type").ok_or_else(|| error(path, "field has no type"))?;
        let required = match text(field, "presence", path)? {
            "required" => true,
            "optional" => false,
            other => {
                return Err(error(
                    format!("{path}.presence"),
                    format!("unknown presence {other:?}"),
                ));
            }
        };
        let nullable = field.get("nullable").and_then(Value::as_bool).unwrap_or(false);
        if text(ty, "kind", path)? == "literal" {
            if !required {
                return Err(error(path, "an optional literal has no client encoding"));
            }
            return literal(ty.get("value"), path).map(Shape::Literal);
        }
        let inner = self.rust_type(
            ty,
            &format!("{owner}{}", pascal(name, path)?),
            &format!("{path}.type"),
        )?;
        Ok(match (required, nullable) {
            (true, false) => Shape::Always(inner),
            (true, true) => Shape::Always(format!("Option<{inner}>")),
            (false, true) => Shape::Omittable(format!("Option<Option<{inner}>>")),
            (false, false) => Shape::Omittable(format!("Option<{inner}>")),
        })
    }

    /// A struct with `WireObject` and `WireValue`.
    fn object(
        &mut self,
        rust: &str,
        doc_line: &str,
        node: &'a Value,
        path: &str,
    ) -> Result<(), ClientError> {
        let fields = match node.get("fields") {
            None => None,
            Some(fields) => Some(object(Some(fields), &format!("{path}.fields"))?),
        };
        let mut members = Vec::new();
        for (name, field) in fields.into_iter().flatten() {
            let field_path = format!("{path}.fields.{name}");
            let shape = self.shape(field, rust, name, &field_path)?;
            let capability = field.get("capability").and_then(Value::as_str);
            members.push((name, field_ident(name, &field_path)?, shape, capability));
        }
        let all_optional = members.iter().all(|(_, _, shape, _)| match shape {
            Shape::Literal(_) | Shape::Omittable(_) => true,
            Shape::Always(ty) => ty.starts_with("Option<"),
        });
        let mut code = String::new();
        let _ = writeln!(code, "#[doc = {doc_line:?}]");
        let derives = if all_optional {
            "Debug, Clone, PartialEq, Default"
        } else {
            "Debug, Clone, PartialEq"
        };
        let _ = writeln!(code, "#[derive({derives})]");
        let _ = writeln!(code, "pub struct {rust} {{");
        for (name, ident, shape, capability) in &members {
            let ty = match shape {
                Shape::Literal(_) => continue,
                Shape::Always(ty) | Shape::Omittable(ty) => ty,
            };
            let doc = match capability {
                Some(capability) => format!("`{name}` (capability `{capability}`)."),
                None => format!("`{name}`."),
            };
            let _ = writeln!(code, "    #[doc = {doc:?}]");
            let _ = writeln!(code, "    pub {ident}: {ty},");
        }
        let _ = writeln!(code, "}}\n");
        let gated: Vec<_> = members
            .iter()
            .filter_map(|(name, _, _, capability)| capability.map(|capability| (name, capability)))
            .collect();
        if !gated.is_empty() {
            let _ = writeln!(code, "impl {rust} {{");
            for (name, capability) in gated {
                let constant = format!("{}_CAPABILITY", name.to_ascii_uppercase());
                let doc = format!("The capability the daemon advertises for `{name}`.");
                let _ = writeln!(code, "    #[doc = {doc:?}]");
                let _ = writeln!(code, "    pub const {constant}: &'static str = {capability:?};");
            }
            let _ = writeln!(code, "}}\n");
        }
        let fields_arg = if members.is_empty() { "_fields" } else { "fields" };
        let _ = writeln!(code, "impl WireObject for {rust} {{");
        let _ =
            writeln!(code, "    fn insert_fields(&self, {fields_arg}: &mut Map<String, Value>) {{");
        for (name, ident, shape, _) in &members {
            match shape {
                Shape::Literal(value) => {
                    let _ = writeln!(code, "        fields.insert({name:?}.to_owned(), {value});");
                }
                Shape::Always(_) => {
                    let _ = writeln!(
                        code,
                        "        fields.insert({name:?}.to_owned(), self.{ident}.wire_value());"
                    );
                }
                Shape::Omittable(_) => {
                    let _ = writeln!(code, "        if let Some(value) = &self.{ident} {{");
                    let _ = writeln!(
                        code,
                        "            fields.insert({name:?}.to_owned(), value.wire_value());"
                    );
                    let _ = writeln!(code, "        }}");
                }
            }
        }
        let _ = writeln!(code, "    }}");
        let _ = writeln!(code, "}}\n");
        let _ = writeln!(code, "impl WireValue for {rust} {{");
        let _ = writeln!(code, "    fn wire_value(&self) -> Value {{");
        let _ = writeln!(code, "        let mut fields = Map::new();");
        let _ = writeln!(code, "        self.insert_fields(&mut fields);");
        let _ = writeln!(code, "        Value::Object(fields)");
        let _ = writeln!(code, "    }}");
        let _ = writeln!(code, "}}\n");
        self.out.push_str(&code);
        Ok(())
    }

    fn enumeration(&mut self, rust: &str, node: &Value, path: &str) -> Result<(), ClientError> {
        let values = node
            .get("values")
            .and_then(Value::as_array)
            .ok_or_else(|| error(format!("{path}.values"), "must be an array"))?;
        let mut variants: BTreeMap<String, String> = BTreeMap::new();
        let mut ordered = Vec::new();
        for (index, value) in values.iter().enumerate() {
            let value_path = format!("{path}.values[{index}]");
            let wire = value.as_str().ok_or_else(|| error(&value_path, "must be a string"))?;
            let variant = pascal(wire, &value_path)?;
            if let Some(other) = variants.insert(variant.clone(), wire.to_owned()) {
                return Err(error(
                    &value_path,
                    format!("{wire:?} and {other:?} are both {rust}::{variant}"),
                ));
            }
            ordered.push((variant, wire));
        }
        let mut code = String::new();
        let _ = writeln!(code, "#[doc = {:?}]", format!("`{path}`."));
        let _ = writeln!(code, "#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]");
        let _ = writeln!(code, "pub enum {rust} {{");
        for (variant, wire) in &ordered {
            let _ = writeln!(code, "    #[doc = {:?}]", format!("`{wire}`."));
            let _ = writeln!(code, "    {variant},");
        }
        let _ = writeln!(code, "}}\n");
        let _ = writeln!(code, "impl {rust} {{");
        let _ = writeln!(code, "    /// The wire spelling.");
        let _ = writeln!(code, "    pub const fn as_str(self) -> &'static str {{");
        let _ = writeln!(code, "        match self {{");
        for (variant, wire) in &ordered {
            let _ = writeln!(code, "            {rust}::{variant} => {wire:?},");
        }
        let _ = writeln!(code, "        }}");
        let _ = writeln!(code, "    }}");
        let _ = writeln!(code, "}}\n");
        let _ = writeln!(code, "impl WireValue for {rust} {{");
        let _ = writeln!(code, "    fn wire_value(&self) -> Value {{");
        let _ = writeln!(code, "        Value::from(self.as_str())");
        let _ = writeln!(code, "    }}");
        let _ = writeln!(code, "}}\n");
        self.out.push_str(&code);
        Ok(())
    }

    /// An enum of one struct per variant; each variant struct writes its tag
    /// as a required literal field whose value is the variant name.
    fn tagged_union(&mut self, rust: &str, node: &'a Value, path: &str) -> Result<(), ClientError> {
        let tag = text(node, "tag", path)?;
        let variants = object(node.get("variants"), &format!("{path}.variants"))?;
        let mut arms = Vec::new();
        for (wire, variant) in variants {
            let variant_path = format!("{path}.variants.{wire}");
            let name = pascal(wire, &variant_path)?;
            let payload = format!("{rust}{name}");
            if text(variant, "kind", &variant_path)? != "object" {
                return Err(error(&variant_path, "a tagged-union variant must be an object"));
            }
            let carries_tag =
                variant.get("fields").and_then(|fields| fields.get(tag)).is_some_and(|field| {
                    field.get("presence").and_then(Value::as_str) == Some("required")
                        && field.pointer("/type/kind").and_then(Value::as_str) == Some("literal")
                        && field.pointer("/type/value").and_then(Value::as_str)
                            == Some(wire.as_str())
                });
            if !carries_tag {
                return Err(error(
                    format!("{variant_path}.fields.{tag}"),
                    format!("a variant must carry its tag as a required literal {wire:?}"),
                ));
            }
            self.claim(&payload, &variant_path)?;
            self.queue.push_back((payload.clone(), variant, variant_path));
            arms.push((name, payload));
        }
        let mut code = String::new();
        let _ = writeln!(code, "#[doc = {:?}]", format!("`{path}`."));
        let _ = writeln!(code, "#[derive(Debug, Clone, PartialEq)]");
        let _ = writeln!(code, "pub enum {rust} {{");
        for (name, payload) in &arms {
            let _ = writeln!(code, "    {name}({payload}),");
        }
        let _ = writeln!(code, "}}\n");
        let _ = writeln!(code, "impl WireValue for {rust} {{");
        let _ = writeln!(code, "    fn wire_value(&self) -> Value {{");
        let _ = writeln!(code, "        match self {{");
        for (name, _) in &arms {
            let _ = writeln!(code, "            {rust}::{name}(variant) => variant.wire_value(),");
        }
        let _ = writeln!(code, "        }}");
        let _ = writeln!(code, "    }}");
        let _ = writeln!(code, "}}\n");
        self.out.push_str(&code);
        Ok(())
    }
}

fn scalar(name: &str, path: &str) -> Result<String, ClientError> {
    let rust = match name {
        "string" => "String",
        "boolean" => "bool",
        "uint8" => "u8",
        "uint16" => "u16",
        "uint32" => "u32",
        "uint64" => "u64",
        "int8" => "i8",
        "int16" => "i16",
        "int32" => "i32",
        "int64" => "i64",
        "float32" => "f32",
        "float64" => "f64",
        other => return Err(error(path, format!("unknown scalar {other:?}"))),
    };
    Ok(rust.to_owned())
}

/// A literal's constant as a `Value` expression.
fn literal(value: Option<&Value>, path: &str) -> Result<String, ClientError> {
    match value {
        Some(Value::String(text)) => Ok(format!("Value::from({text:?})")),
        Some(Value::Bool(flag)) => Ok(format!("Value::Bool({flag})")),
        Some(Value::Number(number)) if number.is_u64() => Ok(format!("Value::from({number}_u64)")),
        Some(Value::Number(number)) if number.is_i64() => Ok(format!("Value::from({number}_i64)")),
        _ => Err(error(path, "a literal must be a string, a boolean or an integer")),
    }
}
