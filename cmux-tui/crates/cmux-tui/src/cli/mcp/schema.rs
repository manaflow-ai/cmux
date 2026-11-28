//! JSON Schema for MCP tool inputs, generated from the type expressions of
//! the `cmux.protocol/2` operation catalog
//! (`spec/resource-operations-v2.schema.json` defines the expressions). The
//! daemon validates every request against the same catalog, so the schema
//! only guides the client; constraints JSON Schema cannot say (one-of
//! groups) stay in the tool description.

use serde_json::{Map, Value, json};

/// Public id prefix of a catalog resource scope (`ws` for `workspace`).
pub(super) fn id_prefix(resource: &str) -> Option<&'static str> {
    Some(match resource {
        "machine" => "machine",
        "session" => "session",
        "workspace" => "ws",
        "screen" => "screen",
        "pane" => "pane",
        "tab" => "tab",
        "terminal" => "term",
        "browser" => "browser",
        "client" => "client",
        "split" => "split",
        "stream" => "stream",
        "notification" => "notification",
        "agent" => "agent",
        "frontend_projection" => "projection",
        "pairing_request" => "pairing",
        "sidebar_view" => "sidebar_view",
        _ => return None,
    })
}

/// Resource scopes whose ids take a unique prefix: the list operation that
/// reports every id of that kind in a session.
pub(super) fn prefix_list(resource: &str) -> Option<cmux_tui_core::resource::ResourceOperation> {
    use cmux_tui_core::resource::ResourceOperation as Op;
    Some(match resource {
        "workspace" => Op::WorkspaceList,
        "screen" => Op::ScreenList,
        "pane" => Op::PaneList,
        "tab" => Op::TabList,
        "terminal" => Op::TerminalList,
        "browser" => Op::BrowserList,
        _ => return None,
    })
}

pub(super) struct Generator<'a> {
    types: &'a Map<String, Value>,
}

impl<'a> Generator<'a> {
    pub(super) fn new(catalog: &'a Value) -> Self {
        static EMPTY: std::sync::OnceLock<Map<String, Value>> = std::sync::OnceLock::new();
        let types = catalog["types"].as_object().unwrap_or_else(|| EMPTY.get_or_init(Map::new));
        Self { types }
    }

    /// The schema of one catalog field: its type plus its description.
    pub(super) fn field(&self, field: &Value) -> Value {
        let mut schema = self.expression(&field["type"], &mut Vec::new());
        if let Some(description) = field.get("description").and_then(Value::as_str) {
            describe(&mut schema, description);
        }
        schema
    }

    fn expression(&self, expression: &Value, stack: &mut Vec<String>) -> Value {
        match expression["kind"].as_str().unwrap_or_default() {
            "primitive" => primitive(expression),
            "resource_id" | "selector" => id(expression["resource"].as_str().unwrap_or_default()),
            "enum" => json!({ "enum": expression["values"] }),
            "ref" => {
                let name = expression["name"].as_str().unwrap_or_default();
                if stack.iter().any(|entry| entry == name) {
                    return json!({ "description": format!("A nested {name}.") });
                }
                let Some(definition) = self.types.get(name) else { return json!({}) };
                stack.push(name.to_owned());
                let schema = self.expression(definition, stack);
                stack.pop();
                schema
            }
            "array" => {
                let mut schema = json!({ "type": "array", "items": self.expression(&expression["items"], stack) });
                copy(expression, "min_items", &mut schema, "minItems");
                copy(expression, "max_items", &mut schema, "maxItems");
                schema
            }
            "map" => json!({
                "type": "object",
                "additionalProperties": self.expression(&expression["values"], stack),
            }),
            "nullable" => {
                json!({ "anyOf": [self.expression(&expression["value"], stack), {"type": "null"}] })
            }
            "union" => {
                let variants = expression["variants"]
                    .as_array()
                    .map(|variants| {
                        variants
                            .iter()
                            .map(|variant| self.expression(variant, stack))
                            .collect::<Vec<Value>>()
                    })
                    .unwrap_or_default();
                let mut schema = json!({ "anyOf": variants });
                if let Some(constraints) = joined(&expression["constraints"]) {
                    describe(&mut schema, &constraints);
                }
                schema
            }
            "object" => {
                let (properties, required) =
                    self.properties(expression["fields"].as_object(), stack);
                let mut schema = json!({
                    "type": "object",
                    "properties": properties,
                    "required": required,
                    "additionalProperties": false,
                });
                if let Some(constraints) = joined(&expression["constraints"]) {
                    describe(&mut schema, &constraints);
                }
                schema
            }
            // `parameter` and `apply` appear only in results.
            _ => json!({}),
        }
    }

    fn properties(
        &self,
        fields: Option<&Map<String, Value>>,
        stack: &mut Vec<String>,
    ) -> (Map<String, Value>, Vec<Value>) {
        let mut properties = Map::new();
        let mut required = Vec::new();
        for (name, field) in fields.into_iter().flatten() {
            let mut schema = self.expression(&field["type"], stack);
            if let Some(description) = field.get("description").and_then(Value::as_str) {
                describe(&mut schema, description);
            }
            properties.insert(name.clone(), schema);
            if field["required"] == Value::Bool(true) {
                required.push(Value::String(name.clone()));
            }
        }
        (properties, required)
    }
}

fn primitive(expression: &Value) -> Value {
    let mut schema = match expression["name"].as_str().unwrap_or_default() {
        "string" => json!({ "type": "string" }),
        "boolean" => json!({ "type": "boolean" }),
        "uint16" => json!({ "type": "integer", "minimum": 0, "maximum": u16::MAX }),
        "uint32" => json!({ "type": "integer", "minimum": 0, "maximum": u32::MAX }),
        "uint64" => json!({ "type": "integer", "minimum": 0 }),
        "int32" => json!({ "type": "integer", "minimum": i32::MIN, "maximum": i32::MAX }),
        "float64" => json!({ "type": "number" }),
        "decimal" => json!({
            "type": "string",
            "pattern": "^(0|[1-9][0-9]{0,19})$",
            "description": "An unsigned integer written as a decimal string.",
        }),
        "base64" => json!({ "type": "string", "contentEncoding": "base64" }),
        _ => json!({}),
    };
    copy(expression, "min_length", &mut schema, "minLength");
    copy(expression, "max_length", &mut schema, "maxLength");
    copy(expression, "minimum", &mut schema, "minimum");
    copy(expression, "maximum", &mut schema, "maximum");
    schema
}

/// A public id, unique id prefix, session-qualified id, `current`, or name.
pub(super) fn id(resource: &str) -> Value {
    let description = match id_prefix(resource) {
        Some(prefix) => format!(
            "The {resource}: its public id (`{prefix}_…`), a unique prefix of it, \
             `<session>:{prefix}_…` for another session, `current`, or its exact name."
        ),
        None => format!("The {resource} id."),
    };
    json!({ "type": "string", "minLength": 1, "description": description })
}

fn copy(from: &Value, key: &str, to: &mut Value, as_key: &str) {
    if let Some(value) = from.get(key) {
        to[as_key] = value.clone();
    }
}

/// Appends `text` to the schema's description.
pub(super) fn describe(schema: &mut Value, text: &str) {
    let Some(object) = schema.as_object_mut() else { return };
    let description = match object.get("description").and_then(Value::as_str) {
        Some(existing) if !existing.is_empty() => format!("{existing} {text}"),
        _ => text.to_owned(),
    };
    object.insert("description".into(), Value::String(description));
}

/// Constraint sentences joined with spaces, or `None` when there are none.
pub(super) fn joined(constraints: &Value) -> Option<String> {
    let sentences = constraints.as_array()?.iter().filter_map(Value::as_str).collect::<Vec<_>>();
    (!sentences.is_empty()).then(|| sentences.join(" "))
}
