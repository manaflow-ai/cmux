//! Generates the client from `openapi.json`, this crate's selection of
//! cmux-platform's spec (`tags.txt`, `scripts/update-spec.sh`), into
//! `OUT_DIR`: generated code is build output (scripts/ci/generated-files.json).
//! The spelling rewrite is cmux-vm-codegen's own (`normalize.rs`), so both
//! clients read the platform's Effect spec the same way.

#[allow(dead_code, reason = "raw_success_bodies is only for cmux-vm-client")]
// The file follows its own workspace's formatting (workers/cmux-vm/cli).
#[rustfmt::skip]
#[path = "../../../workers/cmux-vm/cli/crates/cmux-vm-codegen/src/normalize.rs"]
#[cfg(feature = "http")]
mod normalize;

#[cfg(feature = "http")]
use std::path::PathBuf;

#[cfg(feature = "http")]
const NORMALIZE: &str = "../../../workers/cmux-vm/cli/crates/cmux-vm-codegen/src/normalize.rs";

#[cfg(feature = "http")]
fn main() -> Result<(), String> {
    println!("cargo::rerun-if-changed=openapi.json");
    println!("cargo::rerun-if-changed={NORMALIZE}");
    let text = std::fs::read_to_string("openapi.json").map_err(|e| format!("openapi.json: {e}"))?;
    let mut doc: serde_json::Value =
        serde_json::from_str(&text).map_err(|e| format!("openapi.json: {e}"))?;
    normalize::normalize(&mut doc);
    let mut raw = doc.clone();
    always_send_capabilities(&mut doc);
    let out = PathBuf::from(std::env::var("OUT_DIR").map_err(|e| format!("OUT_DIR: {e}"))?);
    emit(doc, &out.join("generated.rs"))?;
    keep_raw_tags(&mut raw);
    raw_answers(&mut raw);
    keep_used_schemas(&mut raw);
    emit(raw, &out.join("generated_raw.rs"))
}

#[cfg(feature = "http")]
fn emit(doc: serde_json::Value, path: &std::path::Path) -> Result<(), String> {
    let spec: openapiv3::OpenAPI = serde_json::from_value(doc)
        .map_err(|e| format!("openapi.json is not OpenAPI 3.0 after normalization: {e}"))?;
    let mut generator = progenitor::Generator::new(&progenitor::GenerationSettings::default());
    let tokens = generator.generate_tokens(&spec).map_err(|e| format!("progenitor: {e}"))?;
    let file: syn::File = syn::parse2(tokens).map_err(|e| format!("generated code: {e}"))?;
    std::fs::write(path, prettyplease::unparse(&file))
        .map_err(|e| format!("write {}: {e}", path.display()))
}

/// The groups the `raw` client offers: callers that read fields the spec does not name yet
/// (a row's `online`, a revoke's `accessEndsWithinSeconds`) and send a body exactly as the
/// spec spells it (a rotation without `capabilities` keeps the recorded list), so their
/// answers stay JSON rather than the generated types, which would drop such fields.
#[cfg(feature = "http")]
const RAW_TAGS: &[&str] = &["Machine join credentials"];

#[cfg(feature = "http")]
fn keep_raw_tags(doc: &mut serde_json::Value) {
    let Some(paths) = doc.get_mut("paths").and_then(serde_json::Value::as_object_mut) else {
        return;
    };
    for item in paths.values_mut().filter_map(serde_json::Value::as_object_mut) {
        // Path-level keys (`parameters`) stay; operations stay only in a raw group.
        item.retain(|_, operation| {
            operation.get("responses").is_none()
                || operation
                    .pointer("/tags/0")
                    .and_then(serde_json::Value::as_str)
                    .is_some_and(|tag| RAW_TAGS.contains(&tag))
        });
    }
    paths.retain(|_, item| {
        item.as_object().is_some_and(|item| item.values().any(|op| op.get("responses").is_some()))
    });
}

/// Every success answer as raw bytes, an answer the spec says has no body too (the
/// `raw_success_bodies` of cmux-vm-codegen keeps those empty).
#[cfg(feature = "http")]
fn raw_answers(doc: &mut serde_json::Value) {
    let Some(paths) = doc.get_mut("paths").and_then(serde_json::Value::as_object_mut) else {
        return;
    };
    for item in paths.values_mut().filter_map(serde_json::Value::as_object_mut) {
        for operation in item.values_mut() {
            let Some(responses) =
                operation.get_mut("responses").and_then(serde_json::Value::as_object_mut)
            else {
                continue;
            };
            for (status, response) in responses.iter_mut() {
                if status.starts_with('2')
                    && let Some(response) = response.as_object_mut()
                {
                    response.insert("content".to_owned(), serde_json::json!({ "*/*": {} }));
                }
            }
        }
    }
}

/// Only the component schemas the kept routes reach, so the `raw` client stays small.
#[cfg(feature = "http")]
fn keep_used_schemas(doc: &mut serde_json::Value) {
    fn refs(value: &serde_json::Value, found: &mut Vec<String>) {
        match value {
            serde_json::Value::Object(map) => {
                if let Some(name) = map
                    .get("$ref")
                    .and_then(serde_json::Value::as_str)
                    .and_then(|r| r.strip_prefix("#/components/schemas/"))
                {
                    found.push(name.to_owned());
                }
                map.values().for_each(|v| refs(v, found));
            }
            serde_json::Value::Array(list) => list.iter().for_each(|v| refs(v, found)),
            _ => {}
        }
    }
    let mut pending = Vec::new();
    refs(&doc["paths"], &mut pending);
    let mut used = std::collections::BTreeSet::new();
    while let Some(name) = pending.pop() {
        if used.insert(name.clone())
            && let Some(schema) = doc.pointer(&format!("/components/schemas/{name}"))
        {
            refs(schema, &mut pending);
        }
    }
    if let Some(schemas) =
        doc.pointer_mut("/components/schemas").and_then(serde_json::Value::as_object_mut)
    {
        schemas.retain(|name, _| used.contains(name));
    }
}

/// The request bodies whose `capabilities` list is always sent, an empty one too: the platform
/// reads a missing list as a machine joined before it took one (cmux-platform#1015), and an
/// optional list would be left out when empty. Required here only, so the generated field is a
/// plain list; every body the platform takes still has one.
#[cfg(feature = "http")]
const SEND_CAPABILITIES: &[&str] = &["JoinRedeem", "MachineCredentialRotate"];

#[cfg(feature = "http")]
fn always_send_capabilities(doc: &mut serde_json::Value) {
    for name in SEND_CAPABILITIES {
        let Some(schema) = doc.pointer_mut(&format!("/components/schemas/{name}")) else {
            continue;
        };
        if schema.pointer("/properties/capabilities").is_none() {
            continue;
        }
        let Some(object) = schema.as_object_mut() else { continue };
        let required =
            object.entry("required").or_insert_with(|| serde_json::Value::Array(Vec::new()));
        if let Some(list) = required.as_array_mut()
            && !list.iter().any(|v| v == "capabilities")
        {
            list.push(serde_json::Value::from("capabilities"));
        }
    }
}

#[cfg(not(feature = "http"))]
fn main() {}
