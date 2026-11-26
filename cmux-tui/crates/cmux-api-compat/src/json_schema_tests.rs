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
    assert!(got.iter().any(|b| b.contains("request:x/get /must: new required member")), "{got:?}");
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
