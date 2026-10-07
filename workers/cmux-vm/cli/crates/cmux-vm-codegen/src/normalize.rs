//! Rewrites the OpenAPI 3.1 document that Effect's `OpenApi.fromApi` emits
//! into the OpenAPI 3.0 dialect that progenitor (via the `openapiv3` crate)
//! reads. The rewrite only changes how a schema is spelled, never what it
//! accepts, with two deliberate exceptions documented on [`normalize`].

use serde_json::{Map, Value};

/// Normalizes `doc` in place.
///
/// Spelling changes (same meaning in 3.0):
/// - `openapi: 3.1.x` becomes `3.0.3`.
/// - `anyOf`/`oneOf` with a `{"type": "null"}` branch and `type: [.., "null"]`
///   become `nullable: true`.
/// - `const: v` becomes `enum: [v]`; numeric `exclusiveMinimum`/`exclusiveMaximum`
///   become `minimum`/`maximum` plus the 3.0 boolean flag.
/// - `examples` arrays are dropped (3.0 has only `example`).
///
/// Deliberate changes:
/// - Schema `title`s are dropped. Effect fills them with refinement names such
///   as `maxLength(100)`, and the type generator would turn them into Rust type
///   names that change whenever a constraint changes.
/// - Every 4xx/5xx response body becomes an untyped byte stream. Progenitor
///   needs one error type per operation, but Effect gives every error its own
///   schema. A byte stream keeps the status code and the body for every error,
///   including ones a proxy answers with HTML, and the CLI decodes the common
///   `{ "_tag", "message" }` shape itself.
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
            normalize_schema(schema);
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
            for (method, operation) in item.iter_mut() {
                if is_http_method(method) {
                    normalize_operation(operation);
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
        normalize_content(content);
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
                normalize_content(content);
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
            normalize_schema(schema);
        }
    }
}

fn normalize_content(content: &mut Value) {
    for media in content.as_object_mut().into_iter().flat_map(|m| m.values_mut()) {
        if let Some(schema) = media.get_mut("schema") {
            normalize_schema(schema);
        }
    }
}

/// Keys whose value is a map from a name to a schema.
const SCHEMA_MAPS: &[&str] = &["properties", "patternProperties", "$defs", "definitions"];
/// Keys whose value is one schema.
const SCHEMA_VALUES: &[&str] = &["items", "additionalProperties", "not"];
/// Keys whose value is a list of schemas.
const SCHEMA_LISTS: &[&str] = &["anyOf", "oneOf", "allOf", "prefixItems"];

fn normalize_schema(schema: &mut Value) {
    let Some(obj) = schema.as_object_mut() else {
        return;
    };

    for key in SCHEMA_MAPS {
        if let Some(map) = obj.get_mut(*key).and_then(Value::as_object_mut) {
            map.values_mut().for_each(normalize_schema);
        }
    }
    for key in SCHEMA_VALUES {
        if let Some(value) = obj.get_mut(*key) {
            normalize_schema(value);
        }
    }
    for key in SCHEMA_LISTS {
        if let Some(list) = obj.get_mut(*key).and_then(Value::as_array_mut) {
            list.iter_mut().for_each(normalize_schema);
        }
    }

    obj.remove("title");
    obj.remove("examples");
    obj.remove("$schema");

    if let Some(value) = obj.remove("const") {
        obj.insert("enum".to_owned(), Value::Array(vec![value]));
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
                obj.insert("type".to_owned(), rest.into_iter().next().unwrap_or_default());
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
                "E": { "type": "object", "properties": {
                    "title": { "type": "string", "title": "dropped" },
                    "type": { "oneOf": [{ "type": "string" }, { "type": "integer" }, { "type": "null" }] }
                } }
            } }
        });
        normalize(&mut doc);
        assert_eq!(doc["openapi"], "3.0.3");
        assert_eq!(doc["info"]["title"], "kept");
        assert_eq!(schema(&doc, "A"), json!({ "type": "number", "nullable": true }));
        assert_eq!(
            schema(&doc, "B"),
            json!({ "allOf": [{ "$ref": "#/components/schemas/A" }], "nullable": true })
        );
        assert_eq!(schema(&doc, "C"), json!({ "type": "string", "nullable": true }));
        assert_eq!(
            schema(&doc, "D"),
            json!({ "enum": ["x"], "minimum": 0, "exclusiveMinimum": true })
        );
        let e = schema(&doc, "E");
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
}
