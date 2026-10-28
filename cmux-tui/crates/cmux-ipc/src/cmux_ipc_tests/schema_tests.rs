//! `SCHEMA_IDENTITY` is what build.rs read from the two schema files in the
//! tree; CmuxNextIPCTests checks the Swift side the same way.

use std::path::PathBuf;

use serde_json::Value;

use crate::SCHEMA_IDENTITY;
use crate::schema::fnv1a64;

fn spec(name: &str) -> Vec<u8> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../spec").join(name);
    std::fs::read(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

fn keys(doc: &Value, key: &str) -> usize {
    doc[key].as_object().map_or(0, serde_json::Map::len)
}

#[test]
fn schema_identity_matches_the_schema_files_in_the_tree() {
    let sdk_bytes = spec("sdk-schema.json");
    let ops_bytes = spec("resource-operations-v2.json");
    let sdk: Value = serde_json::from_slice(&sdk_bytes).unwrap();
    let ops: Value = serde_json::from_slice(&ops_bytes).unwrap();

    assert_eq!(SCHEMA_IDENTITY.sdk_schema_digest, fnv1a64(&sdk_bytes));
    assert_eq!(SCHEMA_IDENTITY.resource_operations_digest, fnv1a64(&ops_bytes));
    assert_eq!(SCHEMA_IDENTITY.mux_protocol, sdk["protocol"]["name"].as_str().unwrap());
    assert_eq!(SCHEMA_IDENTITY.mux_protocol_version, sdk["protocol"]["version"].as_u64().unwrap());
    assert_eq!(SCHEMA_IDENTITY.resource_protocol, ops["protocol"].as_str().unwrap());
    assert_eq!(SCHEMA_IDENTITY.command_count, keys(&sdk, "commands"));
    assert_eq!(SCHEMA_IDENTITY.event_count, keys(&sdk, "events"));
    assert_eq!(SCHEMA_IDENTITY.resource_operation_count, keys(&ops, "operations"));
    assert_eq!(SCHEMA_IDENTITY.local_operation_count, keys(&ops, "local_operations"));
    assert!(keys(&sdk, "commands") > 0 && keys(&ops, "operations") > 0);
}

#[test]
fn fnv1a64_matches_the_published_vectors() {
    // CmuxNextIPCTests checks the same three against the Swift digest.
    assert_eq!(fnv1a64(b""), 0xcbf2_9ce4_8422_2325);
    assert_eq!(fnv1a64(b"a"), 0xaf63_dc4c_8601_ec8c);
    assert_eq!(fnv1a64(b"foobar"), 0x8594_4171_f739_67e8);
}
