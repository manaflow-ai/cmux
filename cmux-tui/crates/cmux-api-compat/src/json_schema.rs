//! The compat surface of a JSON-RPC protocol described as JSON Schema
//! (acpmux's `spec/acpmux-protocol.json`: `{version, methods[], types{}}`,
//! schemars draft 2020-12 with definitions under `#/types/`).
//!
//! Each schema is lowered into the SDK schema IR's type kinds (`ref`,
//! `object`, `array`, `map`, `enum`, `literal`, `scalar`, `untagged_union`,
//! `opaque_json`) and flattened by the same walker as the cmux-tui daemon's
//! surface, so [`crate::coverage::check`] judges both protocols by one rule
//! set.
//!
//! Message kinds, by who writes them:
//! - `request:<method>`: a request's or client notification's params (the client);
//! - `response:<method>`: a request's result, under `/data` (the server);
//! - `event:<method>`: a notification's or server request's params (the server);
//! - `request:reply/<method>`: a server request's result (the client).
//!
//! Methods whose params or result are `true` (not declared yet) still
//! appear, as one `json` member at the root, so removing a method is a break
//! even before it is typed.

use serde_json::{Map, Value, json};

use crate::Schema;
use crate::coverage::{Snapshot, Surface, Verdict, check, surface_from_sdk_schema};

/// What [`check_files`] found, as one line (or a list) to print.
#[derive(Debug)]
pub struct Outcome {
    /// The protocol matches its snapshot, or the snapshot was refreshed.
    pub ok: bool,
    /// What happened and, on failure, how to fix it.
    pub message: String,
}

/// Checks `ir` against the committed snapshot and compat rules. With `write`,
/// a stale (or missing) snapshot is rewritten once every break is covered.
pub fn check_files(
    ir: &Value,
    snapshot_path: &std::path::Path,
    compat_path: &std::path::Path,
    write: bool,
) -> Result<Outcome, Box<dyn std::error::Error>> {
    let compat = Schema::from_json(&std::fs::read(compat_path)?)?;
    let surface = surface_from_json_schema_ir(ir);
    let snapshot: Option<Snapshot> = match std::fs::read(snapshot_path) {
        Ok(bytes) => Some(serde_json::from_slice(&bytes)?),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => return Err(e.into()),
    };
    let verdict = match &snapshot {
        Some(snapshot) => check(snapshot, &surface, &compat),
        None => Verdict::StaleSnapshot { breaks: Vec::new() },
    };
    let fix = format!(
        "add a revision to {} with one rule per break (rename, move, add, remove, retype, \
         rename_value, fill; paths are JSON pointers, results sit under /data), then \
         ACPMUX_PROTOCOL_BLESS=1 cargo test -p acpmux --lib -- protocol::",
        compat_path.display()
    );
    Ok(match verdict {
        Verdict::Clean => Outcome {
            ok: true,
            message: format!(
                "protocol surface ({} message kinds) matches revision {}",
                surface.len(),
                compat.current()
            ),
        },
        Verdict::Uncovered(missing) => {
            let list: Vec<String> = missing.iter().map(|m| format!("  - {m}")).collect();
            Outcome {
                ok: false,
                message: format!(
                    "{} breaking protocol change(s) without a compat rule:\n{}\nHow to fix: {fix}",
                    missing.len(),
                    list.join("\n")
                ),
            }
        }
        Verdict::StaleSnapshot { breaks } if write => {
            let fresh = Snapshot { revision: compat.current(), surface };
            let mut bytes = serde_json::to_vec_pretty(&fresh)?;
            bytes.push(b'\n');
            std::fs::write(snapshot_path, bytes)?;
            Outcome {
                ok: true,
                message: format!(
                    "snapshot refreshed at revision {} ({} covered break(s))",
                    compat.current(),
                    breaks.len()
                ),
            }
        }
        Verdict::StaleSnapshot { .. } => Outcome {
            ok: false,
            message: format!(
                "the protocol changed and every break is covered, but {} is stale; \
                 ACPMUX_PROTOCOL_BLESS=1 cargo test -p acpmux --lib -- protocol::",
                snapshot_path.display()
            ),
        },
    })
}

/// Flattens a JSON-Schema protocol IR into a compat surface.
pub fn surface_from_json_schema_ir(ir: &Value) -> Surface {
    let mut types = Map::new();
    if let Some(defs) = ir.get("types").and_then(Value::as_object) {
        for (name, schema) in defs {
            types.insert(name.clone(), lower(schema).0);
        }
    }
    let mut commands = Map::new();
    let mut events = Map::new();
    for method in ir.get("methods").and_then(Value::as_array).into_iter().flatten() {
        let Some(name) = method.get("name").and_then(Value::as_str) else { continue };
        let kind = method.get("kind").and_then(Value::as_str).unwrap_or("request");
        let params = method.get("params").map_or_else(opaque, root);
        let result = method.get("result").map(root);
        match kind {
            "request" => {
                let mut command = Map::new();
                command.insert("request".to_owned(), params);
                if let Some(result) = result {
                    command.insert("result".to_owned(), result);
                }
                commands.insert(name.to_owned(), Value::Object(command));
            }
            "client_notification" => {
                commands.insert(name.to_owned(), json!({ "request": params }));
            }
            "notification" => {
                events.insert(name.to_owned(), json!({ "payload": params }));
            }
            "server_request" => {
                events.insert(name.to_owned(), json!({ "payload": params }));
                if let Some(result) = result {
                    commands.insert(format!("reply/{name}"), json!({ "request": result }));
                }
            }
            // Never on the wire (`client_local`), or a kind this build does not know.
            _ => {}
        }
    }
    surface_from_sdk_schema(&json!({ "types": types, "commands": commands, "events": events }))
}

fn opaque() -> Value {
    json!({ "kind": "opaque_json" })
}

/// A message's root: an untyped root still gets one member, so the message
/// kind exists in the surface (the walker skips an object root's own leaf).
fn root(schema: &Value) -> Value {
    let (lowered, _) = lower(schema);
    if lowered.get("kind").and_then(Value::as_str) == Some("opaque_json") {
        json!({ "kind": "object", "fields": {
            "*untyped*": { "type": opaque(), "presence": "optional", "nullable": true }
        }})
    } else {
        lowered
    }
}

/// One JSON Schema lowered to an SDK IR type, and whether it admits `null`.
fn lower(schema: &Value) -> (Value, bool) {
    let Some(object) = schema.as_object() else { return (opaque(), false) };
    if let Some(target) = object.get("$ref").and_then(Value::as_str) {
        let name = target.rsplit('/').next().unwrap_or(target);
        return (json!({ "kind": "ref", "name": name }), false);
    }
    if let Some(value) = object.get("const") {
        return (json!({ "kind": "literal", "value": value }), false);
    }
    if let Some(values) = object.get("enum").and_then(Value::as_array) {
        let nullable = values.iter().any(Value::is_null);
        let values: Vec<_> = values.iter().filter(|v| !v.is_null()).cloned().collect();
        return (json!({ "kind": "enum", "values": values }), nullable);
    }
    if let Some(variants) =
        object.get("anyOf").or_else(|| object.get("oneOf")).and_then(Value::as_array)
    {
        let nullable = variants.iter().any(is_null_schema);
        let rest: Vec<_> = variants.iter().filter(|v| !is_null_schema(v)).collect();
        if let [only] = rest.as_slice() {
            let (lowered, inner) = lower(only);
            return (lowered, nullable || inner);
        }
        let lowered: Vec<_> = rest.iter().map(|v| lower(v).0).collect();
        return (json!({ "kind": "untagged_union", "variants": lowered }), nullable);
    }
    let (ty, nullable) = match object.get("type") {
        Some(Value::String(ty)) => (Some(ty.as_str()), false),
        Some(Value::Array(types)) => {
            let nullable = types.iter().any(|t| t == "null");
            let rest: Vec<_> =
                types.iter().filter_map(Value::as_str).filter(|t| *t != "null").collect();
            match rest.as_slice() {
                [one] => (Some(*one), nullable),
                [] => (Some("null"), false),
                many => {
                    let variants: Vec<_> = many
                        .iter()
                        .map(|t| {
                            let mut single = object.clone();
                            single.insert("type".into(), json!(t));
                            lower(&Value::Object(single)).0
                        })
                        .collect();
                    return (json!({ "kind": "untagged_union", "variants": variants }), nullable);
                }
            }
        }
        _ => (None, false),
    };
    let lowered = match ty {
        Some("object") => lower_object(object),
        Some("array") => {
            let items = object.get("items").map_or_else(opaque, |i| lower(i).0);
            json!({ "kind": "array", "items": items })
        }
        Some(scalar @ ("string" | "integer" | "number" | "boolean" | "null")) => {
            let name = object.get("format").and_then(Value::as_str).unwrap_or(scalar);
            json!({ "kind": "scalar", "name": name })
        }
        _ => opaque(),
    };
    (lowered, nullable)
}

fn lower_object(object: &Map<String, Value>) -> Value {
    let properties = object.get("properties").and_then(Value::as_object);
    if properties.is_none()
        && let Some(values) = object.get("additionalProperties").filter(|v| v.is_object())
    {
        return json!({ "kind": "map", "values": lower(values).0 });
    }
    let required: Vec<&str> = object
        .get("required")
        .and_then(Value::as_array)
        .map(|r| r.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    let mut fields = Map::new();
    for (name, schema) in properties.into_iter().flatten() {
        let (ty, nullable) = lower(schema);
        let presence = if required.contains(&name.as_str()) { "required" } else { "optional" };
        fields.insert(
            name.clone(),
            json!({ "type": ty, "presence": presence, "nullable": nullable }),
        );
    }
    json!({ "kind": "object", "fields": fields })
}

fn is_null_schema(schema: &Value) -> bool {
    schema.get("type").and_then(Value::as_str) == Some("null")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::coverage::breaking_changes;

    fn ir(params: Value, result: Value) -> Value {
        json!({
            "version": "1",
            "methods": [
                { "name": "x/get", "kind": "request", "params": { "$ref": "#/types/P" },
                  "result": { "$ref": "#/types/R" } },
                { "name": "x/untyped", "kind": "request", "params": true, "result": true },
                { "name": "x/changed", "kind": "notification", "params": true }
            ],
            "types": { "P": params, "R": result }
        })
    }

    fn p(extra: Value) -> Value {
        let mut props = json!({ "id": { "type": "string" } });
        for (k, v) in extra.as_object().into_iter().flatten() {
            props[k] = v.clone();
        }
        json!({ "type": "object", "properties": props, "required": ["id"],
                "additionalProperties": false }) // skew: strict test fixture: exercises lowering of a closed schema, never a wire decoder
    }

    fn r() -> Value {
        json!({ "type": "object", "required": ["n"], "properties": {
            "n": { "type": "integer", "format": "uint64", "minimum": 0 },
            "label": { "type": ["string", "null"] },
            "state": { "enum": ["on", "off"], "type": "string" }
        }})
    }

    fn breaks(old: &Value, new: &Value) -> Vec<String> {
        breaking_changes(&surface_from_json_schema_ir(old), &surface_from_json_schema_ir(new))
            .iter()
            .map(ToString::to_string)
            .collect()
    }

    #[test]
    fn additive_changes_are_not_breaks() {
        let old = ir(p(json!({})), r());
        let new = ir(p(json!({ "limit": { "type": "integer" } })), r());
        assert_eq!(breaks(&old, &new), Vec::<String>::new());
    }

    #[test]
    fn removed_methods_members_and_values_are_breaks() {
        let old = ir(p(json!({})), r());
        let mut new = old.clone();
        new["methods"].as_array_mut().unwrap().retain(|m| m["name"] != "x/untyped");
        new["types"]["R"]["properties"]["state"]["enum"] = json!(["on"]);
        new["types"]["R"]["properties"].as_object_mut().unwrap().remove("label");
        let got = breaks(&old, &new);
        assert!(got.iter().any(|b| b.starts_with("request:x/untyped (whole message)")), "{got:?}");
        assert!(got.iter().any(|b| b.starts_with("response:x/untyped (whole message)")), "{got:?}");
        assert!(got.iter().any(|b| b.contains("/data/label: member removed")), "{got:?}");
        assert!(got.iter().any(|b| b.contains("/data/state: values removed: off")), "{got:?}");
    }

    #[test]
    fn a_new_required_param_and_a_retype_are_breaks() {
        let old = ir(p(json!({})), r());
        let mut new = ir(p(json!({ "must": { "type": "string" } })), r());
        new["types"]["P"]["required"] = json!(["id", "must"]);
        new["types"]["R"]["properties"]["n"] = json!({ "type": "string" });
        let got = breaks(&old, &new);
        assert!(
            got.iter().any(|b| b.contains("request:x/get /must: new required member")),
            "{got:?}"
        );
        assert!(got.iter().any(|b| b.contains("/data/n: type uint64 -> string")), "{got:?}");
    }

    #[test]
    fn nullable_results_are_marked_and_nulling_one_breaks_readers() {
        let old = ir(p(json!({})), r());
        let mut new = old.clone();
        new["types"]["R"]["properties"]["n"] =
            json!({ "anyOf": [{ "type": "integer", "format": "uint64" }, { "type": "null" }] });
        let got = breaks(&old, &new);
        assert!(got.iter().any(|b| b.contains("/data/n: became nullable")), "{got:?}");
        let surface = surface_from_json_schema_ir(&old);
        assert!(surface["response:x/get"]["/data/label"].nullable);
        assert!(surface.contains_key("event:x/changed"));
    }
}
