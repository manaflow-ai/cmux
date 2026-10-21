//! Optional machine descriptor metadata, negotiated for strict provider-v1 peers.

use super::{MachineStatus, OpaqueId, WorkspaceCreatePolicy};
use serde::{Deserialize, Serialize};

/// Enables machine platform and capability fields for one control generation.
/// Providers emit them only after accepting this client capability.
pub const MACHINE_METADATA_CLIENT_CAPABILITY: &str = "machine-metadata-v1";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MachineDescriptor {
    pub id: OpaqueId,
    pub display_name: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub subtitle: String,
    pub status: MachineStatus,
    pub connectable: bool,
    pub workspace_create: WorkspaceCreatePolicy,
    /// Optional non-secret host metadata for agent and machine surfaces.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub platform: Option<MachinePlatform>,
    /// Stable capability names; credentials and account data stay outside the catalog.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub capabilities: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MachinePlatform {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub os: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub arch: Option<String>,
}
