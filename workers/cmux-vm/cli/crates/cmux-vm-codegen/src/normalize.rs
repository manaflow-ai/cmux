//! Rewrites the OpenAPI 3.1 document that Effect's `OpenApi.fromApi` emits
//! into the OpenAPI 3.0 dialect that progenitor (via the `openapiv3` crate)
//! reads. The rewrite only changes how a schema is spelled, never what it
//! accepts, with the deliberate exceptions documented on [`normalize`].

use serde_json::{Map, Value};

/// Normalizes `doc` in place.
///
/// Spelling changes (same meaning in 3.0):
/// - `openapi: 3.1.x` becomes `3.0.3`.
/// - `anyOf`/`oneOf` with a `{"type": "null"}` branch and `type: [.., "null"]`
///   become `nullable: true`.
/// - `const: v` becomes `enum: [v]`; numeric `exclusiveMinimum`/`exclusiveMaximum`
///   become `minimum`/`maximum` plus the 3.0 boolean flag.
/// - An `anyOf`/`oneOf` whose branches are all plain strings (a `vm_` or a
///   `snap_` id, say) becomes one string whose pattern is the alternation of
///   the branch patterns. Progenitor would otherwise generate a struct of
///   flattened newtypes, which cannot read or write a JSON string.
/// - `examples` arrays are dropped (3.0 has only `example`).
///
/// Deliberate changes:
/// - Schema `title`s are dropped. Effect fills them with refinement names such
///   as `maxLength(100)`, and the type generator would turn them into Rust type
///   names that change whenever a constraint changes.
/// - `additionalProperties: false` is dropped. Effect puts it on every struct,
///   and the generated types would then reject any field the server adds, so
///   an older CLI would break on every additive API change.
/// - String enums with more than one value in component and response schemas
///   become plain strings, so an older CLI still reads a VM whose state the
///   server added later. Request parameters keep their enums, and one-value
///   enums (tags) stay, because they never grow.
/// - Every 4xx/5xx response body becomes an untyped byte stream. Progenitor
///   needs one error type per operation, but Effect gives every error its own
///   schema. A byte stream keeps the status code and the body for every error,
///   including ones a proxy answers with HTML, and the CLI decodes the common
///   `{ "_tag", "message" }` shape itself.
/// - Operations that answer `101 Switching Protocols` (the terminal
///   WebSocket endpoints) are left out. Progenitor's upgrade support does not
///   compile with byte-stream error bodies, and a WebSocket needs its own
///   client; the `cmux-vm` CLI has no terminal verbs yet.
pub fn normalize(doc: &mut Value) {
    if let Some(version) = doc.get_mut("openapi")
        && version.as_str().is_some_and(|v| v.starts_with("3.1"))
    {
        *version = Value::String("3.0.3".to_owned());
    }

    if let Some(schemas) = doc
        .pointer_mut("/components/schemas")
        .and_then(Value::as_object_mut)
    {
        for schema in schemas.values_mut() {
            normalize_schema(schema, true);
        }
    }

    if let Some(paths) = doc.get_mut("paths").and_then(Value::as_object_mut) {
        for item in paths.values_mut() {
            let Some(item) = item.as_object_mut() else {
                continue;
            };
            if let Some(params) = item.get_mut("parameters") {
                normalize_parameters(params);
            }
            item.retain(|method, operation| !(is_http_method(method) && is_upgrade(operation)));
            for (method, operation) in item.iter_mut() {
                if is_http_method(method) {
                    normalize_operation(operation);
                }
            }
        }
        paths.retain(|_, item| {
            item.as_object()
                .is_none_or(|item| item.keys().any(|k| is_http_method(k)))
        });
    }
}

/// Whether `operation` answers with a protocol switch (a WebSocket).
fn is_upgrade(operation: &Value) -> bool {
    operation
        .get("responses")
        .and_then(Value::as_object)
        .is_some_and(|responses| responses.contains_key("101"))
}

/// Makes every 2xx response body raw bytes (`*/*`). Applied after
/// [`normalize`] for the raw client variant.
pub fn raw_success_bodies(doc: &mut Value) {
    let Some(paths) = doc.get_mut("paths").and_then(Value::as_object_mut) else {
        return;
    };
    for item in paths.values_mut().filter_map(Value::as_object_mut) {
        for (method, operation) in item.iter_mut() {
            if !is_http_method(method) {
                continue;
            }
            let Some(responses) = operation
                .get_mut("responses")
                .and_then(Value::as_object_mut)
            else {
                continue;
            };
            for (status, response) in responses.iter_mut() {
                if status.starts_with('2')
                    && let Some(response) = response.as_object_mut()
                    && response.contains_key("content")
                {
                    let mut raw = Map::new();
                    raw.insert("*/*".to_owned(), Value::Object(Map::new()));
                    response.insert("content".to_owned(), Value::Object(raw));
                }
            }
        }
    }
}

fn is_http_method(key: &str) -> bool {
    matches!(
        key,
        "get" | "put" | "post" | "delete" | "options" | "head" | "patch" | "trace"
    )
}

fn normalize_operation(operation: &mut Value) {
    let Some(operation) = operation.as_object_mut() else {
        return;
    };
    if let Some(params) = operation.get_mut("parameters") {
        normalize_parameters(params);
    }
    if let Some(content) = operation
        .get_mut("requestBody")
        .and_then(|body| body.get_mut("content"))
    {
        normalize_content(content, false);
    }
    if let Some(responses) = operation
        .get_mut("responses")
        .and_then(Value::as_object_mut)
    {
        for (status, response) in responses.iter_mut() {
            let Some(response) = response.as_object_mut() else {
                continue;
            };
            if is_error_status(status) {
                if response.contains_key("content") {
                    let mut raw = Map::new();
                    raw.insert("*/*".to_owned(), Value::Object(Map::new()));
                    response.insert("content".to_owned(), Value::Object(raw));
                }
            } else if let Some(content) = response.get_mut("content") {
                normalize_content(content, true);
            }
        }
    }
}

fn is_error_status(status: &str) -> bool {
    matches!(status.as_bytes().first(), Some(b'4' | b'5'))
}

fn normalize_parameters(params: &mut Value) {
    for param in params.as_array_mut().into_iter().flatten() {
        if let Some(schema) = param.get_mut("schema") {
            normalize_schema(schema, false);
        }
    }
}

fn normalize_content(content: &mut Value, open_enums: bool) {
    for media in content
        .as_object_mut()
        .into_iter()
        .flat_map(|m| m.values_mut())
    {
        if let Some(schema) = media.get_mut("schema") {
            normalize_schema(schema, open_enums);
        }
    }
}

/// Keys whose value is a map from a name to a schema.
const SCHEMA_MAPS: &[&str] = &["properties", "patternProperties", "$defs", "definitions"];
/// Keys whose value is one schema.
const SCHEMA_VALUES: &[&str] = &["items", "additionalProperties", "not"];
/// Keys whose value is a list of schemas.
const SCHEMA_LISTS: &[&str] = &["anyOf", "oneOf", "allOf", "prefixItems"];

fn normalize_schema(schema: &mut Value, open_enums: bool) {
    let Some(obj) = schema.as_object_mut() else {
        return;
    };

    for key in SCHEMA_MAPS {
        if let Some(map) = obj.get_mut(*key).and_then(Value::as_object_mut) {
            map.values_mut()
                .for_each(|v| normalize_schema(v, open_enums));
        }
    }
    for key in SCHEMA_VALUES {
        if let Some(value) = obj.get_mut(*key) {
            normalize_schema(value, open_enums);
        }
    }
    for key in SCHEMA_LISTS {
        if let Some(list) = obj.get_mut(*key).and_then(Value::as_array_mut) {
            list.iter_mut()
                .for_each(|v| normalize_schema(v, open_enums));
        }
    }

    obj.remove("title");
    obj.remove("examples");
    if obj.get("additionalProperties") == Some(&Value::Bool(false)) {
        obj.remove("additionalProperties");
    }
    obj.remove("$schema");

    if let Some(value) = obj.remove("const") {
        obj.insert("enum".to_owned(), Value::Array(vec![value]));
    }
    if open_enums
        && obj.get("type").is_some_and(|t| t == "string")
        && obj
            .get("enum")
            .and_then(Value::as_array)
            .is_some_and(|values| values.len() > 1)
    {
        obj.remove("enum");
    }
    // A 3.0 `$ref` ignores its siblings; wrap it so constraints such as
    // `minimum` next to it still apply.
    if obj.keys().any(|k| k != "$ref" && k != "description")
        && let Some(reference) = obj.remove("$ref")
    {
        let mut target = Map::new();
        target.insert("$ref".to_owned(), reference);
        obj.insert(
            "allOf".to_owned(),
            Value::Array(vec![Value::Object(target)]),
        );
    }
    for (exclusive, bound) in [
        ("exclusiveMinimum", "minimum"),
        ("exclusiveMaximum", "maximum"),
    ] {
        if obj.get(exclusive).is_some_and(Value::is_number) {
            let value = obj.remove(exclusive).unwrap_or(Value::Null);
            obj.insert(bound.to_owned(), value);
            obj.insert(exclusive.to_owned(), Value::Bool(true));
        }
    }

    if let Some(Value::Array(types)) = obj.get("type").cloned() {
        let nullable = types.iter().any(|t| t == "null");
        let rest: Vec<Value> = types.into_iter().filter(|t| t != "null").collect();
        match rest.len() {
            0 => {
                obj.remove("type");
            }
            1 => {
                obj.insert(
                    "type".to_owned(),
                    rest.into_iter().next().unwrap_or_default(),
                );
            }
            _ => {
                obj.remove("type");
                let branches = rest
                    .into_iter()
                    .map(|t| {
                        let mut branch = Map::new();
                        branch.insert("type".to_owned(), t);
                        Value::Object(branch)
                    })
                    .collect();
                obj.insert("anyOf".to_owned(), Value::Array(branches));
            }
        }
        if nullable {
            obj.insert("nullable".to_owned(), Value::Bool(true));
        }
    }

    for key in ["anyOf", "oneOf"] {
        let Some(Value::Array(branches)) = obj.get(key) else {
            continue;
        };
        if !branches.iter().any(is_null_schema) {
            continue;
        }
        let rest: Vec<Value> = branches
            .iter()
            .filter(|b| !is_null_schema(b))
            .cloned()
            .collect();
        obj.remove(key);
        obj.insert("nullable".to_owned(), Value::Bool(true));
        match rest.len() {
            0 => {}
            1 => {
                let only = rest.into_iter().next().unwrap_or_default();
                if only.get("$ref").is_some() {
                    // A 3.0 `$ref` ignores its siblings, so wrap it to keep
                    // `nullable`.
                    obj.insert("allOf".to_owned(), Value::Array(vec![only]));
                } else if let Value::Object(only) = only {
                    for (k, v) in only {
                        obj.entry(k).or_insert(v);
                    }
                }
            }
            _ => {
                obj.insert(key.to_owned(), Value::Array(rest));
            }
        }
    }
    merge_string_unions(obj);
}

/// Merges an `anyOf`/`oneOf` of plain string schemas into one string schema.
/// A branch is plain when it has `type: string` and at most a `pattern` and a
/// `description` besides; any other keyword (a length, an enum, a format)
/// leaves the union alone.
fn merge_string_unions(obj: &mut Map<String, Value>) {
    for key in ["anyOf", "oneOf"] {
        let Some(Value::Array(branches)) = obj.get(key) else {
            continue;
        };
        let plain = branches.len() > 1
            && branches.iter().all(|b| {
                b.as_object().is_some_and(|b| {
                    b.get("type").is_some_and(|t| t == "string")
                        && b.keys()
                            .all(|k| matches!(k.as_str(), "type" | "pattern" | "description"))
                })
            });
        if !plain {
            continue;
        }
        let patterns: Option<Vec<&str>> = branches
            .iter()
            .map(|b| b.get("pattern").and_then(Value::as_str))
            .collect();
        let pattern = patterns.map(|p| {
            p.iter()
                .map(|p| format!("(?:{p})"))
                .collect::<Vec<_>>()
                .join("|")
        });
        obj.remove(key);
        obj.insert("type".to_owned(), Value::String("string".to_owned()));
        if let Some(pattern) = pattern {
            obj.insert("pattern".to_owned(), Value::String(pattern));
        }
    }
}

fn is_null_schema(schema: &Value) -> bool {
    schema.get("type").is_some_and(|t| t == "null")
}

#[cfg(test)]
mod tests {
    use super::normalize;
    use serde_json::json;

    fn schema(doc: &serde_json::Value, name: &str) -> serde_json::Value {
        doc["components"]["schemas"][name].clone()
    }

    #[test]
    fn downgrades_version_and_nullable_spellings() {
        let mut doc = json!({
            "openapi": "3.1.0",
            "info": { "title": "kept", "version": "1" },
            "paths": {},
            "components": { "schemas": {
                "A": { "anyOf": [{ "type": "number" }, { "type": "null" }] },
                "B": { "anyOf": [{ "$ref": "#/components/schemas/A" }, { "type": "null" }] },
                "C": { "type": ["string", "null"], "title": "maxLength(3)" },
                "D": { "const": "x", "exclusiveMinimum": 0 },
                "F": { "type": "string", "enum": ["running", "paused"] },
                "G": { "$ref": "#/components/schemas/Int", "minimum": -1, "description": "d" },
                "H": { "$ref": "#/components/schemas/Int", "description": "only" },
                "E": { "type": "object", "additionalProperties": false, "properties": {
                    "title": { "type": "string", "title": "dropped" },
                    "type": { "oneOf": [{ "type": "string" }, { "type": "integer" }, { "type": "null" }] }
                } }
            } }
        });
        normalize(&mut doc);
        assert_eq!(doc["openapi"], "3.0.3");
        assert_eq!(doc["info"]["title"], "kept");
        assert_eq!(
            schema(&doc, "A"),
            json!({ "type": "number", "nullable": true })
        );
        assert_eq!(
            schema(&doc, "B"),
            json!({ "allOf": [{ "$ref": "#/components/schemas/A" }], "nullable": true })
        );
        assert_eq!(
            schema(&doc, "C"),
            json!({ "type": "string", "nullable": true })
        );
        assert_eq!(
            schema(&doc, "D"),
            json!({ "enum": ["x"], "minimum": 0, "exclusiveMinimum": true })
        );
        assert_eq!(schema(&doc, "F"), json!({ "type": "string" }));
        assert_eq!(
            schema(&doc, "G"),
            json!({ "allOf": [{ "$ref": "#/components/schemas/Int" }], "minimum": -1, "description": "d" })
        );
        assert_eq!(
            schema(&doc, "H"),
            json!({ "$ref": "#/components/schemas/Int", "description": "only" })
        );
        let e = schema(&doc, "E");
        assert!(e.get("additionalProperties").is_none());
        assert_eq!(e["properties"]["title"], json!({ "type": "string" }));
        assert_eq!(
            e["properties"]["type"],
            json!({ "oneOf": [{ "type": "string" }, { "type": "integer" }], "nullable": true })
        );
    }

    #[test]
    fn error_bodies_become_raw_and_success_bodies_stay_typed() {
        let mut doc = json!({
            "openapi": "3.1.0",
            "paths": { "/v1/things/{id}": { "get": {
                "operationId": "things.get",
                "responses": {
                    "200": { "description": "ok", "content": { "application/json": {
                        "schema": { "type": ["string", "null"] } } } },
                    "404": { "description": "nf", "content": { "application/json": {
                        "schema": { "$ref": "#/components/schemas/NotFound" } } } },
                    "500": { "description": "no body" }
                }
            } } }
        });
        normalize(&mut doc);
        let responses = &doc["paths"]["/v1/things/{id}"]["get"]["responses"];
        assert_eq!(
            responses["200"]["content"]["application/json"]["schema"],
            json!({ "type": "string", "nullable": true })
        );
        assert_eq!(responses["404"]["content"], json!({ "*/*": {} }));
        assert!(responses["500"].get("content").is_none());
    }

    #[test]
    fn websocket_operations_are_left_out() {
        let mut doc = json!({
            "openapi": "3.1.0",
            "paths": {
                "/t": { "get": { "responses": { "101": { "description": "upgrade" } } } },
                "/u": {
                    "get": { "responses": { "101": { "description": "upgrade" } } },
                    "delete": { "responses": { "200": { "description": "ok" } } }
                }
            }
        });
        super::normalize(&mut doc);
        assert!(doc["paths"].get("/t").is_none());
        assert!(doc["paths"]["/u"].get("get").is_none());
        assert!(doc["paths"]["/u"].get("delete").is_some());
    }

    #[test]
    fn unions_of_plain_strings_become_one_string() {
        let mut doc = json!({
            "openapi": "3.1.0",
            "components": { "schemas": {
                "Ids": { "type": "array", "items": { "anyOf": [
                    { "type": "string", "pattern": "^vm_[a-z]{3}$", "description": "a vm" },
                    { "type": "string", "pattern": "^snap_[a-z]{3}$" }
                ] } },
                "Mixed": { "anyOf": [
                    { "type": "string", "maxLength": 3 },
                    { "type": "string" }
                ] }
            } },
            "paths": {}
        });
        super::normalize(&mut doc);
        assert_eq!(
            schema(&doc, "Ids")["items"],
            json!({ "type": "string", "pattern": "(?:^vm_[a-z]{3}$)|(?:^snap_[a-z]{3}$)" })
        );
        assert!(schema(&doc, "Mixed").get("anyOf").is_some());
    }

    #[test]
    fn parameter_enums_stay_closed() {
        let mut doc = json!({
            "openapi": "3.1.0",
            "paths": { "/v1/things": { "get": {
                "operationId": "things.list",
                "parameters": [{ "name": "state", "in": "query",
                    "schema": { "type": "string", "enum": ["a", "b"] } }],
                "responses": {}
            } } }
        });
        normalize(&mut doc);
        assert_eq!(
            doc["paths"]["/v1/things"]["get"]["parameters"][0]["schema"],
            json!({ "type": "string", "enum": ["a", "b"] })
        );
    }

    #[test]
    fn raw_success_bodies_only_touch_2xx_content() {
        let mut doc = json!({
            "paths": { "/v1/things": { "get": {
                "responses": {
                    "200": { "description": "ok", "content": { "application/json": {
                        "schema": { "type": "object" } } } },
                    "204": { "description": "empty" },
                    "404": { "description": "nf", "content": { "*/*": {} } }
                }
            } } }
        });
        super::raw_success_bodies(&mut doc);
        let responses = &doc["paths"]["/v1/things"]["get"]["responses"];
        assert_eq!(responses["200"]["content"], json!({ "*/*": {} }));
        assert!(responses["204"].get("content").is_none());
        assert_eq!(responses["404"]["content"], json!({ "*/*": {} }));
    }
}
