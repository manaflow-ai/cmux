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
    let spec: openapiv3::OpenAPI = serde_json::from_value(doc)
        .map_err(|e| format!("openapi.json is not OpenAPI 3.0 after normalization: {e}"))?;
    let mut generator = progenitor::Generator::new(&progenitor::GenerationSettings::default());
    let tokens = generator.generate_tokens(&spec).map_err(|e| format!("progenitor: {e}"))?;
    let file: syn::File = syn::parse2(tokens).map_err(|e| format!("generated code: {e}"))?;
    let out = PathBuf::from(std::env::var("OUT_DIR").map_err(|e| format!("OUT_DIR: {e}"))?);
    std::fs::write(out.join("generated.rs"), prettyplease::unparse(&file))
        .map_err(|e| format!("write generated.rs: {e}"))
}
