//! Which schema this build compiled. `build.rs` reads both schema files,
//! spec/sdk-schema.json and spec/resource-operations-v2.json, and writes
//! [`SCHEMA_IDENTITY`] into OUT_DIR; CmuxNextWireGen writes the same values
//! for Swift (`WireSchemaIdentity.built` in CmuxNextIPC). Equal identities
//! mean both sides were generated from the same schema bytes.

pub use crate::schema_digest::fnv1a64;

/// The protocol names, versions, method counts and content digests of the
/// two schema files a build read.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SchemaIdentity {
    /// `protocol.name` of spec/sdk-schema.json (the v12 mux protocol).
    pub mux_protocol: &'static str,
    /// `protocol.version` of spec/sdk-schema.json.
    pub mux_protocol_version: u64,
    /// `protocol` of spec/resource-operations-v2.json.
    pub resource_protocol: &'static str,
    /// Keys of `commands` in spec/sdk-schema.json.
    pub command_count: usize,
    /// Keys of `events` in spec/sdk-schema.json.
    pub event_count: usize,
    /// Keys of `operations` in spec/resource-operations-v2.json.
    pub resource_operation_count: usize,
    /// Keys of `local_operations` in spec/resource-operations-v2.json.
    pub local_operation_count: usize,
    /// [`fnv1a64`] of spec/sdk-schema.json's bytes.
    pub sdk_schema_digest: u64,
    /// [`fnv1a64`] of spec/resource-operations-v2.json's bytes.
    pub resource_operations_digest: u64,
}

include!(concat!(env!("OUT_DIR"), "/schema_identity.generated.rs"));
