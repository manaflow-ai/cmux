//! Build-time generation for cmux-ipc (p05-ipc design 3.3): the method
//! tables are read from the two schema files on every build and written to
//! `OUT_DIR`; nothing generated is committed (scripts/ci/generated-files.json).
//!
//! - `method_tables.rs`: the real tables, from `spec/sdk-schema.json` and
//!   `spec/resource-operations-v2.json`.
//! - `method_tables_fixture.rs`: the same emitter over
//!   `spec/fixtures/ipc-method-tables/`, which the tests check entry by entry
//!   (the Swift table emitter reads the same fixture).
//!
//! A schema the tables cannot encode fails the build with its JSON path.

#[path = "build-support/method_tables.rs"]
mod method_tables;

use std::path::{Path, PathBuf};

fn read_json(path: &Path) -> serde_json::Value {
    println!("cargo:rerun-if-changed={}", path.display());
    let text = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

fn write_tables(spec: &Path, out: &Path, static_name: &str, file: &str) {
    let sdk = read_json(&spec.join("sdk-schema.json"));
    let v2 = read_json(&spec.join("resource-operations-v2.json"));
    let tables =
        method_tables::read(&sdk, &v2).unwrap_or_else(|e| panic!("{}: {e}", spec.display()));
    let source = method_tables::emit(&tables, static_name);
    let path = out.join(file);
    std::fs::write(&path, source).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
}

fn main() {
    let manifest = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    let out = PathBuf::from(std::env::var("OUT_DIR").expect("OUT_DIR"));
    let spec = manifest.join("../../spec");
    println!("cargo:rerun-if-changed=build-support/method_tables.rs");
    write_tables(&spec, &out, "TABLES", "method_tables.rs");
    write_tables(
        &spec.join("fixtures/ipc-method-tables"),
        &out,
        "FIXTURE_TABLES",
        "method_tables_fixture.rs",
    );
}
