use super::*;
use crate::{
    ProcessEvent, REMOTE_PROTOCOL_VERSION, RemoteCapability, RpcEvent, RpcRequest, RpcResponse,
    WorkspaceRequest, WorkspaceResponse,
};
use schemars::generate::SchemaSettings;
use serde_json::{Map, Value, json};

const GOLDEN_PATH: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/contract/remote-v1.json");

/// Drops doc-comment `description`s so the golden file tracks the wire, not prose.
/// A property that is itself named `description` stays.
fn strip_descriptions(value: &mut Value, in_properties: bool) {
    match value {
        Value::Object(map) => {
            if !in_properties {
                map.remove("description");
            }
            for (key, child) in map.iter_mut() {
                strip_descriptions(child, !in_properties && key == "properties");
            }
        }
        Value::Array(items) => items.iter_mut().for_each(|item| strip_descriptions(item, false)),
        _ => {}
    }
}

/// The `type` tag of one internally tagged variant schema.
fn variant_tag(schema: &Value) -> String {
    let tag = &schema["properties"]["type"];
    tag.get("const")
        .or_else(|| tag["enum"].get(0))
        .and_then(Value::as_str)
        .unwrap_or_else(|| panic!("variant without a type tag: {schema}"))
        .to_owned()
}

/// `(tag, schema)` for each variant of an internally tagged enum, in declaration order.
fn variants(defs: &Map<String, Value>, name: &str) -> Vec<(String, Value)> {
    let schema = &defs[name];
    let one_of = schema["oneOf"].as_array().unwrap_or_else(|| panic!("{name}: {schema}"));
    one_of.iter().map(|variant| (variant_tag(variant), variant.clone())).collect()
}

fn wire_strings(value: &Value, out: &mut Vec<String>) {
    match value {
        Value::Object(map) => {
            if let Some(Value::String(name)) = map.get("const") {
                out.push(name.clone());
            }
            if let Some(Value::Array(names)) = map.get("enum") {
                out.extend(names.iter().filter_map(Value::as_str).map(str::to_owned));
            }
            map.values().for_each(|child| wire_strings(child, out));
        }
        Value::Array(items) => items.iter().for_each(|item| wire_strings(item, out)),
        _ => {}
    }
}

fn generated_contract() -> Value {
    let mut generator = SchemaSettings::draft2020_12().for_deserialize().into_generator();
    let envelopes = json!({
        "request": generator.subschema_for::<RpcRequest>(),
        "response": generator.subschema_for::<RpcResponse>(),
        "event": generator.subschema_for::<RpcEvent>(),
    });
    let _ = generator.subschema_for::<RemoteCapability>();
    let _ = generator.subschema_for::<WorkspaceRequest>();
    let _ = generator.subschema_for::<WorkspaceResponse>();
    let _ = generator.subschema_for::<ProcessEvent>();
    let mut defs = Value::Object(generator.take_definitions(true));
    strip_descriptions(&mut defs, false);
    let defs = match defs {
        Value::Object(defs) => defs,
        _ => unreachable!(),
    };

    let mut capabilities = Vec::new();
    wire_strings(&defs["RemoteCapability"], &mut capabilities);

    let requests = variants(&defs, "WorkspaceRequest");
    let methods: Vec<Value> = CONTRACT_METHODS
        .iter()
        .zip(&requests)
        .map(|(method, (_, schema))| {
            json!({
                "name": method.name,
                "capability": method.capability,
                "request_schema": schema,
                "responses": method.responses,
            })
        })
        .collect();
    let responses: Vec<Value> = variants(&defs, "WorkspaceResponse")
        .into_iter()
        .map(|(name, schema)| json!({ "name": name, "schema": schema }))
        .collect();
    let events: Vec<Value> = variants(&defs, "ProcessEvent")
        .into_iter()
        .map(|(name, schema)| json!({ "name": name, "schema": schema }))
        .collect();

    json!({
        "format": REMOTE_CONTRACT_FORMAT,
        "protocol": { "min": REMOTE_PROTOCOL_VERSION, "max": REMOTE_PROTOCOL_VERSION },
        "capabilities": capabilities,
        "methods": methods,
        "responses": responses,
        "events": events,
        "envelopes": envelopes,
        "$defs": defs,
    })
}

fn rendered(contract: &Value) -> String {
    let mut text = serde_json::to_string_pretty(contract).unwrap();
    text.push('\n');
    text
}

/// The wire changed and `contract/remote-v1.json` did not: regenerate it with
/// `UPDATE_CONTRACT=1 cargo test -p cmux-remote-protocol contract` and review the diff.
/// Removing or renaming a method, response or field breaks old peers; add a new
/// one behind a capability instead.
#[test]
fn golden_contract_matches_the_wire_types() {
    let expected = rendered(&generated_contract());
    if std::env::var_os("UPDATE_CONTRACT").is_some() {
        std::fs::write(GOLDEN_PATH, &expected).unwrap();
    }
    let golden = std::fs::read_to_string(GOLDEN_PATH).unwrap();
    assert!(
        golden == expected,
        "contract/remote-v1.json is stale: run UPDATE_CONTRACT=1 cargo test -p cmux-remote-protocol contract"
    );
    assert_eq!(remote_contract(), generated_contract());
}

#[test]
fn method_table_names_every_request_in_order() {
    let mut generator = SchemaSettings::draft2020_12().into_generator();
    let _ = generator.subschema_for::<WorkspaceRequest>();
    let _ = generator.subschema_for::<WorkspaceResponse>();
    let defs = generator.take_definitions(true);
    let request_tags: Vec<String> =
        variants(&defs, "WorkspaceRequest").into_iter().map(|(tag, _)| tag).collect();
    let table: Vec<&str> = CONTRACT_METHODS.iter().map(|method| method.name).collect();
    assert_eq!(request_tags, table, "CONTRACT_METHODS must list every WorkspaceRequest in order");

    let response_tags: Vec<String> =
        variants(&defs, "WorkspaceResponse").into_iter().map(|(tag, _)| tag).collect();
    for method in CONTRACT_METHODS {
        for response in method.responses {
            assert!(response_tags.iter().any(|tag| tag == response), "{}: {response}", method.name);
        }
        if let Some(capability) = method.capability {
            let decoded: RemoteCapability = serde_json::from_value(json!(capability)).unwrap();
            assert!(
                !matches!(decoded, RemoteCapability::Unknown(_)),
                "{}: unknown capability {capability}",
                method.name
            );
        }
    }
    for tag in &response_tags {
        assert!(
            CONTRACT_METHODS.iter().any(|method| method.responses.contains(&tag.as_str())),
            "response {tag} is answered by no method"
        );
    }
}

#[test]
fn contract_lists_describe_and_its_capability() {
    let contract = remote_contract();
    assert_eq!(contract["format"], REMOTE_CONTRACT_FORMAT);
    assert!(contract["capabilities"].as_array().unwrap().contains(&json!("describe-v1")));
    let describe = contract["methods"]
        .as_array()
        .unwrap()
        .iter()
        .find(|method| method["name"] == "describe")
        .unwrap();
    assert_eq!(describe["capability"], "describe-v1");
    assert_eq!(describe["responses"], json!(["contract"]));
    assert_eq!(
        serde_json::to_value(WorkspaceRequest::Describe).unwrap(),
        json!({ "type": "describe" })
    );
}
