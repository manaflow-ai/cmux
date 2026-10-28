//! Reads the request shape of every framed v12 command (a command with a
//! `method_id`) out of `spec/sdk-schema.json` and writes it as a Rust table
//! that `src/request_shapes.rs` includes (feature `fuzzing`). The cmux-tui/fuzz
//! `dispatch_structured` target walks that table to build request bodies the
//! schema allows, as MojoLPM builds structured messages from the mojom
//! definitions (chromium mojo/public/tools/fuzzers/mojolpm.h and
//! mojo/public/tools/bindings/generators/mojolpm_generator.py), so the fuzzer
//! starts past every member-name and type check of the handler's decode.
//!
//! Shared by `build.rs` and the crate's tests. The reader never refuses a
//! schema: a type kind it does not know is `Any` (any JSON value), so no
//! schema edit can break a build through this table. Named types become one
//! node each, so recursive types (a layout tree) stay finite.

use std::collections::BTreeMap;
use std::fmt::Write as _;

use serde_json::{Map, Value};

/// One node of the shape arena; children are arena indexes.
#[derive(Debug, Clone, PartialEq)]
pub enum Node {
    /// Any JSON value (`opaque_json`, or a kind this reader does not know).
    Any,
    Bool,
    Unsigned {
        min: u64,
        max: u64,
    },
    Signed {
        min: i64,
        max: i64,
    },
    Float,
    Text {
        max_bytes: Option<u64>,
    },
    LiteralBool(bool),
    LiteralInt(i64),
    LiteralText(String),
    Enum(Vec<String>),
    Array {
        items: usize,
        min: u64,
        max: Option<u64>,
    },
    Map {
        values: usize,
    },
    Object {
        fields: Vec<FieldNode>,
        open: bool,
    },
    /// Exactly one of these shapes (a tagged or untagged union).
    OneOf(Vec<usize>),
}

#[derive(Debug, Clone, PartialEq)]
pub struct FieldNode {
    pub name: String,
    pub shape: usize,
    pub required: bool,
    pub nullable: bool,
}

/// A framed command and the arena index of its request object.
#[derive(Debug, Clone, PartialEq)]
pub struct Request {
    pub method_id: u16,
    pub name: String,
    pub params: usize,
}

/// Every request shape of one schema, sorted by method id.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Shapes {
    pub nodes: Vec<Node>,
    pub requests: Vec<Request>,
}

/// Reads the shapes of `sdk` (spec/sdk-schema.json).
pub fn read(sdk: &Value) -> Shapes {
    let empty = Map::new();
    let types = sdk.get("types").and_then(Value::as_object).unwrap_or(&empty);
    let mut reader = Reader { types, nodes: Vec::new(), named: BTreeMap::new() };
    let mut requests = Vec::new();
    let commands = sdk.get("commands").and_then(Value::as_object).unwrap_or(&empty);
    for (name, command) in commands {
        let Some(method_id) =
            command.get("method_id").and_then(Value::as_u64).and_then(|id| u16::try_from(id).ok())
        else {
            continue;
        };
        let params = match command.get("request") {
            Some(request) => reader.shape(request, None),
            None => reader.push(Node::Object { fields: Vec::new(), open: false }),
        };
        requests.push(Request { method_id, name: name.clone(), params });
    }
    requests.sort_by_key(|request| request.method_id);
    Shapes { nodes: reader.nodes, requests }
}

struct Reader<'a> {
    types: &'a Map<String, Value>,
    nodes: Vec<Node>,
    /// Arena index of each named type read so far.
    named: BTreeMap<String, usize>,
}

impl Reader<'_> {
    fn push(&mut self, node: Node) -> usize {
        self.nodes.push(node);
        self.nodes.len() - 1
    }

    /// The arena index of `ty`; a ref is its named type's one node.
    fn shape(&mut self, ty: &Value, constraints: Option<&Value>) -> usize {
        match (kind(ty), ty.get("name").and_then(Value::as_str)) {
            ("ref", Some(name)) => self.named(name),
            _ => {
                let node = self.node(ty, constraints);
                self.push(node)
            }
        }
    }

    fn named(&mut self, name: &str) -> usize {
        if let Some(&index) = self.named.get(name) {
            return index;
        }
        // Reserved before the body is read, so a type that refers to
        // itself finds its own index.
        let index = self.push(Node::Any);
        self.named.insert(name.to_owned(), index);
        let types = self.types;
        let node = types.get(name).map_or(Node::Any, |ty| self.node(ty, None));
        if let Some(slot) = self.nodes.get_mut(index) {
            *slot = node;
        }
        index
    }

    fn node(&mut self, ty: &Value, constraints: Option<&Value>) -> Node {
        match kind(ty) {
            "ref" => match ty.get("name").and_then(Value::as_str) {
                Some(name) => Node::OneOf(vec![self.named(name)]),
                None => Node::Any,
            },
            "alias" => match ty.get("target") {
                Some(target) => self.node(target, constraints),
                None => Node::Any,
            },
            "scalar" => scalar(ty.get("name").and_then(Value::as_str).unwrap_or(""), constraints),
            "literal" => match ty.get("value") {
                Some(Value::Bool(value)) => Node::LiteralBool(*value),
                Some(Value::String(value)) => Node::LiteralText(value.clone()),
                Some(Value::Number(value)) => value.as_i64().map_or(Node::Any, Node::LiteralInt),
                _ => Node::Any,
            },
            "enum" => Node::Enum(
                ty.get("values")
                    .and_then(Value::as_array)
                    .map(|values| {
                        values.iter().filter_map(Value::as_str).map(str::to_owned).collect()
                    })
                    .unwrap_or_default(),
            ),
            "array" => {
                let items = match ty.get("items") {
                    Some(items) => self.shape(items, None),
                    None => self.push(Node::Any),
                };
                Node::Array {
                    items,
                    min: ty.get("min_items").and_then(Value::as_u64).unwrap_or(0),
                    max: ty.get("max_items").and_then(Value::as_u64),
                }
            }
            "map" => {
                let values = match ty.get("values") {
                    Some(values) => self.shape(values, None),
                    None => self.push(Node::Any),
                };
                Node::Map { values }
            }
            "object" => self.object(ty),
            "tagged_union" => {
                let variants: Vec<&Value> = ty
                    .get("variants")
                    .and_then(Value::as_object)
                    .map(|variants| variants.values().collect())
                    .unwrap_or_default();
                Node::OneOf(variants.into_iter().map(|variant| self.shape(variant, None)).collect())
            }
            "untagged_union" => {
                let variants: Vec<&Value> = ty
                    .get("variants")
                    .and_then(Value::as_array)
                    .map(|variants| variants.iter().collect())
                    .unwrap_or_default();
                Node::OneOf(variants.into_iter().map(|variant| self.shape(variant, None)).collect())
            }
            _ => Node::Any,
        }
    }

    fn object(&mut self, ty: &Value) -> Node {
        let open = ty.get("additional_properties").and_then(Value::as_bool).unwrap_or(false);
        let mut fields = Vec::new();
        if let Some(members) = ty.get("fields").and_then(Value::as_object) {
            for (name, field) in members {
                let shape = match field.get("type") {
                    Some(member) => self.shape(member, field.get("constraints")),
                    None => self.push(Node::Any),
                };
                fields.push(FieldNode {
                    name: name.clone(),
                    shape,
                    required: field.get("presence").and_then(Value::as_str) == Some("required"),
                    nullable: field.get("nullable").and_then(Value::as_bool).unwrap_or(false),
                });
            }
        }
        Node::Object { fields, open }
    }
}

fn kind(ty: &Value) -> &str {
    ty.get("kind").and_then(Value::as_str).unwrap_or("")
}

/// The first constraint object's `key`, as a number.
fn bound<'a>(constraints: Option<&'a Value>, key: &str) -> Option<&'a serde_json::Number> {
    constraints?.as_array()?.iter().find_map(|constraint| constraint.get(key)?.as_number())
}

fn scalar(name: &str, constraints: Option<&Value>) -> Node {
    let unsigned = |max: u64| {
        let min = bound(constraints, "minimum").and_then(serde_json::Number::as_u64).unwrap_or(0);
        let max = bound(constraints, "maximum")
            .and_then(serde_json::Number::as_u64)
            .map_or(max, |bound| bound.min(max));
        Node::Unsigned { min: min.min(max), max }
    };
    let signed = |min: i64, max: i64| {
        let low = bound(constraints, "minimum")
            .and_then(serde_json::Number::as_i64)
            .map_or(min, |bound| bound.max(min));
        let high = bound(constraints, "maximum")
            .and_then(serde_json::Number::as_i64)
            .map_or(max, |bound| bound.min(max));
        Node::Signed { min: low.min(high), max: high }
    };
    match name {
        "boolean" => Node::Bool,
        "uint16" => unsigned(u64::from(u16::MAX)),
        "uint32" => unsigned(u64::from(u32::MAX)),
        "uint64" => unsigned(u64::MAX),
        "int32" => signed(i64::from(i32::MIN), i64::from(i32::MAX)),
        "int64" => signed(i64::MIN, i64::MAX),
        "float32" | "float64" => Node::Float,
        "string" => Node::Text {
            max_bytes: bound(constraints, "max_utf8_bytes")
                .or_else(|| bound(constraints, "max_length"))
                .and_then(serde_json::Number::as_u64),
        },
        _ => Node::Any,
    }
}

fn emit_node(out: &mut String, node: &Node) {
    let _ = match node {
        Node::Any => write!(out, "Shape::Any"),
        Node::Bool => write!(out, "Shape::Bool"),
        Node::Unsigned { min, max } => write!(out, "Shape::Unsigned {{ min: {min}, max: {max} }}"),
        Node::Signed { min, max } => write!(out, "Shape::Signed {{ min: {min}, max: {max} }}"),
        Node::Float => write!(out, "Shape::Float"),
        Node::Text { max_bytes } => write!(out, "Shape::Text {{ max_bytes: {max_bytes:?} }}"),
        Node::LiteralBool(value) => write!(out, "Shape::Literal(Literal::Bool({value}))"),
        Node::LiteralInt(value) => write!(out, "Shape::Literal(Literal::Int({value}))"),
        Node::LiteralText(value) => write!(out, "Shape::Literal(Literal::Text({value:?}))"),
        Node::Enum(values) => write!(out, "Shape::Enum(&{values:?})"),
        Node::Array { items, min, max } => {
            write!(out, "Shape::Array {{ items: {items}, min: {min}, max: {max:?} }}")
        }
        Node::Map { values } => write!(out, "Shape::Map {{ values: {values} }}"),
        Node::Object { fields, open } => {
            out.push_str("Shape::Object { fields: &[");
            for field in fields {
                let _ = write!(
                    out,
                    "Field {{ name: {:?}, shape: {}, required: {}, nullable: {} }}, ",
                    field.name, field.shape, field.required, field.nullable
                );
            }
            write!(out, "], open: {open} }}")
        }
        Node::OneOf(variants) => write!(out, "Shape::OneOf(&{variants:?})"),
    };
}

/// Rust source of `static SHAPES: RequestShapes`, for `request_shapes.rs`.
pub fn emit(shapes: &Shapes) -> String {
    let mut out = String::new();
    out.push_str("static SHAPES: RequestShapes = RequestShapes {\nshapes: &[\n");
    for node in &shapes.nodes {
        emit_node(&mut out, node);
        out.push_str(",\n");
    }
    out.push_str("],\nrequests: &[\n");
    for request in &shapes.requests {
        let _ = writeln!(
            out,
            "RequestShape {{ method_id: MethodId::new(0x{:04X}), name: {:?}, params: {} }},",
            request.method_id, request.name, request.params
        );
    }
    out.push_str("],\n};\n");
    out
}
