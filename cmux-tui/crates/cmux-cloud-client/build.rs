//! Generates the client from `openapi.json`, this crate's selection of
//! cmux-platform's spec (`tags.txt`, `scripts/update-spec.sh`), into
//! `OUT_DIR`: generated code is build output (scripts/ci/generated-files.json).
//! The spelling rewrite is cmux-vm-codegen's own (`normalize.rs`), so both
//! clients read the platform's Effect spec the same way.

#[allow(dead_code, reason = "raw_success_bodies is only for cmux-vm-client")]
// The file follows its own workspace's formatting (workers/cmux-vm/cli).
#[rustfmt::skip]
#[path = "../../../workers/cmux-vm/cli/crates/cmux-vm-codegen/src/normalize.rs"]
mod normalize;

use std::path::PathBuf;

const NORMALIZE: &str = "../../../workers/cmux-vm/cli/crates/cmux-vm-codegen/src/normalize.rs";

fn main() -> Result<(), String> {
    println!("cargo::rerun-if-changed=openapi.json");
    println!("cargo::rerun-if-changed={NORMALIZE}");
    let text = std::fs::read_to_string("openapi.json").map_err(|e| format!("openapi.json: {e}"))?;
    let mut doc: serde_json::Value =
        serde_json::from_str(&text).map_err(|e| format!("openapi.json: {e}"))?;
    normalize::normalize(&mut doc);
    always_send_capabilities(&mut doc);
    let spec: openapiv3::OpenAPI = serde_json::from_value(doc)
        .map_err(|e| format!("openapi.json is not OpenAPI 3.0 after normalization: {e}"))?;
    let mut generator = progenitor::Generator::new(&progenitor::GenerationSettings::default());
    let tokens = generator.generate_tokens(&spec).map_err(|e| format!("progenitor: {e}"))?;
    let file: syn::File = syn::parse2(tokens).map_err(|e| format!("generated code: {e}"))?;
    let out = PathBuf::from(std::env::var("OUT_DIR").map_err(|e| format!("OUT_DIR: {e}"))?);
    std::fs::write(out.join("generated.rs"), prettyplease::unparse(&file))
        .map_err(|e| format!("write generated.rs: {e}"))
}

/// The request bodies whose `capabilities` list is always sent, an empty one too: the platform
/// reads a missing list as a machine joined before it took one (cmux-platform#1015), and an
/// optional list would be left out when empty. Required here only, so the generated field is a
/// plain list; every body the platform takes still has one.
const SEND_CAPABILITIES: &[&str] = &["JoinRedeem", "MachineCredentialRotate"];

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
