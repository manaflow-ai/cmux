//! Build-time generation for cmux-ipc (plans/cmux-next/chrome-parity/p05-ipc.md
//! section 3.3, task 027). Reads the two schema files, spec/sdk-schema.json
//! (the v12 commands and events) and spec/resource-operations-v2.json (the v2
//! operations), and writes Rust into OUT_DIR. Nothing it writes is in git
//! (scripts/ci/generated-files.json, `ipc-wire-rust`, status "build").
//!
//! Cargo reruns this only when a schema file, the digest or this file changes,
//! so an edit anywhere else in the crate does not regenerate. Later tasks add
//! their emitters (method tables, client and server family types) as more
//! files in OUT_DIR from the same parsed `Schemas`.

#[path = "src/schema_digest.rs"]
mod schema_digest;

use std::fmt::{self, Write as _};
use std::path::{Path, PathBuf};

const SDK_SCHEMA: &str = "../../spec/sdk-schema.json";
const RESOURCE_OPERATIONS: &str = "../../spec/resource-operations-v2.json";

/// Why generation failed; cargo prints it as the build script's error.
struct BuildError(String);

impl fmt::Debug for BuildError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "cmux-ipc build.rs: {}", self.0)
    }
}

/// One schema file: where it is, its bytes and its parsed JSON.
struct SchemaFile {
    path: PathBuf,
    bytes: Vec<u8>,
    doc: serde_json::Value,
}

impl SchemaFile {
    fn read(path: PathBuf) -> Result<Self, BuildError> {
        println!("cargo:rerun-if-changed={}", path.display());
        let bytes =
            std::fs::read(&path).map_err(|e| BuildError(format!("{}: {e}", path.display())))?;
        let doc = serde_json::from_slice(&bytes)
            .map_err(|e| BuildError(format!("{}: {e}", path.display())))?;
        Ok(Self { path, bytes, doc })
    }

    fn error(&self, pointer: &str, what: &str) -> BuildError {
        BuildError(format!("{}: {pointer} {what}", self.path.display()))
    }

    fn at(&self, pointer: &str) -> Result<&serde_json::Value, BuildError> {
        self.doc.pointer(pointer).ok_or_else(|| self.error(pointer, "is missing"))
    }

    fn string(&self, pointer: &str) -> Result<&str, BuildError> {
        self.at(pointer)?.as_str().ok_or_else(|| self.error(pointer, "is not a string"))
    }

    fn unsigned(&self, pointer: &str) -> Result<u64, BuildError> {
        self.at(pointer)?.as_u64().ok_or_else(|| self.error(pointer, "is not an unsigned integer"))
    }

    fn key_count(&self, pointer: &str) -> Result<usize, BuildError> {
        self.at(pointer)?
            .as_object()
            .map(serde_json::Map::len)
            .ok_or_else(|| self.error(pointer, "is not an object"))
    }

    fn digest(&self) -> u64 {
        schema_digest::fnv1a64(&self.bytes)
    }
}

/// Both schema files, read once for every emitter.
struct Schemas {
    sdk: SchemaFile,
    resource: SchemaFile,
}

fn main() -> Result<(), BuildError> {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=src/schema_digest.rs");
    let manifest = PathBuf::from(env("CARGO_MANIFEST_DIR")?);
    let out_dir = PathBuf::from(env("OUT_DIR")?);
    let schemas = Schemas {
        sdk: SchemaFile::read(manifest.join(SDK_SCHEMA))?,
        resource: SchemaFile::read(manifest.join(RESOURCE_OPERATIONS))?,
    };
    write(&out_dir, "schema_identity.generated.rs", &schema_identity(&schemas)?)
}

fn env(key: &str) -> Result<String, BuildError> {
    std::env::var(key).map_err(|e| BuildError(format!("{key}: {e}")))
}

fn write(dir: &Path, name: &str, code: &str) -> Result<(), BuildError> {
    let path = dir.join(name);
    std::fs::write(&path, code).map_err(|e| BuildError(format!("{}: {e}", path.display())))
}

/// `SCHEMA_IDENTITY`, the values `src/schema.rs` declares.
fn schema_identity(schemas: &Schemas) -> Result<String, BuildError> {
    let sdk = &schemas.sdk;
    let resource = &schemas.resource;
    let mut code = String::new();
    // Writing to a String cannot fail. Debug formatting of a &str is a valid
    // Rust string literal, escapes included.
    let _ = writeln!(code, "/// The schema this build compiled (cmux-ipc build.rs).");
    let _ = writeln!(code, "pub const SCHEMA_IDENTITY: SchemaIdentity = SchemaIdentity {{");
    let _ = writeln!(code, "    mux_protocol: {:?},", sdk.string("/protocol/name")?);
    let _ = writeln!(code, "    mux_protocol_version: {},", sdk.unsigned("/protocol/version")?);
    let _ = writeln!(code, "    resource_protocol: {:?},", resource.string("/protocol")?);
    let _ = writeln!(code, "    command_count: {},", sdk.key_count("/commands")?);
    let _ = writeln!(code, "    event_count: {},", sdk.key_count("/events")?);
    let _ = writeln!(code, "    resource_operation_count: {},", resource.key_count("/operations")?);
    let _ =
        writeln!(code, "    local_operation_count: {},", resource.key_count("/local_operations")?);
    let _ = writeln!(code, "    sdk_schema_digest: {:#018x},", sdk.digest());
    let _ = writeln!(code, "    resource_operations_digest: {:#018x},", resource.digest());
    let _ = writeln!(code, "}};");
    Ok(code)
}
