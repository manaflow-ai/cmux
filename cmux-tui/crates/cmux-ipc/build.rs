//! Build-time generation for cmux-ipc (plans/cmux-next/chrome-parity/p05-ipc.md
//! section 3.3, task 027). Reads the two schema files, spec/sdk-schema.json
//! (the v12 commands and events) and spec/resource-operations-v2.json (the v2
//! operations), and writes Rust into OUT_DIR. Nothing it writes is in git
//! (scripts/ci/generated-files.json, `ipc-wire-rust`, status "build").
//!
//! Cargo reruns this only when a schema file, the digest, the method-table
//! reader or this file changes, so an edit anywhere else in the crate does not
//! regenerate. Each emitter writes one file in OUT_DIR from the same parsed
//! `Schemas`; later tasks (client and server family types) add theirs here.
//!
//! - `schema_identity.generated.rs` (task 027): `SCHEMA_IDENTITY`.
//! - `method_tables.rs` (task 023): the method tables `src/methods.rs`
//!   includes. `method_tables_fixture.rs` is the same emitter over
//!   spec/fixtures/ipc-method-tables, which the tests check entry by entry.
//! - `client_requests.rs` (task 028): the `cli` client's request types,
//!   which `src/client.rs` includes (feature `client`).
//! - `server_families.rs` (tasks 026, 029): the `<family>_params!` and
//!   `server_command_enum!` macros `src/server_families.rs` includes; the
//!   daemon expands them into its request params and `Command` variants for
//!   the families `server-families.json` lists, with its `refused_fields`
//!   and `boxed` variants.

#[path = "build-support/client_requests.rs"]
mod client_requests;
#[path = "build-support/method_tables.rs"]
mod method_tables;
#[path = "src/schema_digest.rs"]
mod schema_digest;
#[path = "build-support/server_families.rs"]
mod server_families;

use std::fmt::{self, Write as _};
use std::path::{Path, PathBuf};

const SDK_SCHEMA: &str = "../../spec/sdk-schema.json";
const RESOURCE_OPERATIONS: &str = "../../spec/resource-operations-v2.json";
const TABLE_FIXTURE_SDK: &str = "../../spec/fixtures/ipc-method-tables/sdk-schema.json";
const TABLE_FIXTURE_RESOURCE: &str =
    "../../spec/fixtures/ipc-method-tables/resource-operations-v2.json";
const SERVER_FAMILIES: &str = "server-families.json";

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

impl Schemas {
    fn read(manifest: &Path, sdk: &str, resource: &str) -> Result<Self, BuildError> {
        Ok(Self {
            sdk: SchemaFile::read(manifest.join(sdk))?,
            resource: SchemaFile::read(manifest.join(resource))?,
        })
    }
}

fn main() -> Result<(), BuildError> {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=src/schema_digest.rs");
    println!("cargo:rerun-if-changed=build-support/method_tables.rs");
    println!("cargo:rerun-if-changed=build-support/client_requests.rs");
    println!("cargo:rerun-if-changed=build-support/server_families.rs");
    let manifest = PathBuf::from(env("CARGO_MANIFEST_DIR")?);
    let out_dir = PathBuf::from(env("OUT_DIR")?);
    let schemas = Schemas::read(&manifest, SDK_SCHEMA, RESOURCE_OPERATIONS)?;
    write(&out_dir, "schema_identity.generated.rs", &schema_identity(&schemas)?)?;
    write(&out_dir, "method_tables.rs", &method_tables(&schemas, "TABLES")?)?;
    write(&out_dir, "client_requests.rs", &client_requests(&schemas.sdk)?)?;
    write(&out_dir, "server_families.rs", &server_families(&manifest, &schemas)?)?;
    let fixture = Schemas::read(&manifest, TABLE_FIXTURE_SDK, TABLE_FIXTURE_RESOURCE)?;
    write(&out_dir, "method_tables_fixture.rs", &method_tables(&fixture, "FIXTURE_TABLES")?)
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

/// `static <name>: MethodTables`, the tables `src/methods.rs` includes. A
/// schema the tables cannot encode fails the build with its file and JSON path.
fn method_tables(schemas: &Schemas, name: &str) -> Result<String, BuildError> {
    let tables = method_tables::read(&schemas.sdk.doc, &schemas.resource.doc).map_err(|e| {
        let file = if e.file == method_tables::V2 { &schemas.resource } else { &schemas.sdk };
        BuildError(format!("{}: {}: {}", file.path.display(), e.path, e.message))
    })?;
    Ok(method_tables::emit(&tables, name))
}

/// The `cli` client's request types, the ones `src/client.rs` includes. A
/// command the emitter cannot type fails the build with its JSON path.
fn client_requests(sdk: &SchemaFile) -> Result<String, BuildError> {
    client_requests::emit(&sdk.doc, client_requests::CLI)
        .map_err(|e| BuildError(format!("{}: {e}", sdk.path.display())))
}

/// The `<family>_params!` and `server_command_enum!` macros for the families
/// `server-families.json` lists. A family or field the emitter cannot
/// generate fails the build with its file and JSON path.
fn server_families(manifest: &Path, schemas: &Schemas) -> Result<String, BuildError> {
    let list = SchemaFile::read(manifest.join(SERVER_FAMILIES))?;
    let listed = server_families::listed_families(&list.doc)
        .map_err(|e| BuildError(format!("{}: {e}", list.path.display())))?;
    let mut families = server_families::read(&schemas.sdk.doc, &listed)
        .map_err(|e| BuildError(format!("{}: {e}", schemas.sdk.path.display())))?;
    server_families::add_refused_fields(&mut families, &list.doc)
        .map_err(|e| BuildError(format!("{}: {e}", list.path.display())))?;
    server_families::box_variants(&mut families, &list.doc)
        .map_err(|e| BuildError(format!("{}: {e}", list.path.display())))?;
    Ok(server_families::emit(&families))
}
