//! Which advertised [`RemoteCapability`]s a [`WorkspaceRequest`] needs.
//!
//! A peer that does not advertise a capability may not know the method, or
//! may silently drop a field it introduced. A client checks this list
//! against the peer's `capabilities` answer before it sends the request.

use crate::{RemoteCapability, WorkspaceRequest};

/// The `*** Begin Patch` header of Codex's patch grammar (`workspace-patch-v3`).
const CODEX_PATCH_HEADER: &str = "*** Begin Patch";

impl WorkspaceRequest {
    /// Every capability the peer must advertise to understand this request
    /// exactly as encoded: the method's own capability, plus the one that
    /// introduced each optional field the request sets.
    pub fn required_capabilities(&self) -> Vec<RemoteCapability> {
        use RemoteCapability as C;
        match self {
            Self::Capabilities => Vec::new(),
            Self::OpenWorkspace { .. }
            | Self::ListWorkspaces
            | Self::Stat { .. }
            | Self::ReadFile { .. }
            | Self::WriteFile { .. } => vec![C::WorkspaceFilesV1],
            Self::ListDirectory { cursor, .. } => {
                with_if(vec![C::WorkspaceFilesV1], cursor.is_some(), C::WorkspacePaginationV1)
            }
            Self::Search { cursor, .. } => {
                with_if(vec![C::WorkspaceSearchV1], cursor.is_some(), C::WorkspacePaginationV1)
            }
            Self::ApplyPatch { patch, preconditions, .. } => {
                let required = with_if(
                    vec![C::WorkspacePatchV1],
                    !preconditions.is_empty(),
                    C::WorkspacePatchV2,
                );
                with_if(
                    required,
                    patch.trim_start().starts_with(CODEX_PATCH_HEADER),
                    C::WorkspacePatchV3,
                )
            }
            Self::GitStatus { .. } => vec![C::WorkspaceDiffV1],
            Self::Diff { cursor, max_bytes, .. } => with_if(
                vec![C::WorkspaceDiffV1],
                cursor.is_some() || max_bytes.is_some(),
                C::WorkspacePaginationV1,
            ),
            Self::SpawnProcess { operation, timeout_ms, retained_output_bytes, .. } => with_if(
                vec![C::ProcessPipesV1],
                operation.is_some() || timeout_ms.is_some() || retained_output_bytes.is_some(),
                C::ProcessLifecycleV2,
            ),
            Self::SpawnProcessWithHandle {
                operation, timeout_ms, retained_output_bytes, ..
            } => with_if(
                vec![C::ProcessPipesV1, C::ProcessHandlesV2],
                operation.is_some() || timeout_ms.is_some() || retained_output_bytes.is_some(),
                C::ProcessLifecycleV2,
            ),
            Self::WriteProcess { .. } | Self::SignalProcess { .. } | Self::WaitProcess { .. } => {
                vec![C::ProcessPipesV1]
            }
            Self::ResizeProcess { .. } => vec![C::ProcessPtyV1],
            Self::ReadProcessEvents { .. } => vec![C::ProcessReplayV1],
            Self::ListProcesses => vec![C::ProcessCatalogV1],
            Self::SnapshotProcessTerminal { .. } => vec![C::ProcessTerminalSnapshotV1],
            Self::FinishOperation { .. } | Self::CloseWorkspace { .. } => {
                vec![C::ProcessLifecycleV2]
            }
            Self::CancelRequest { .. } => vec![C::RequestControlV1],
            Self::CreateRoute { .. } | Self::CloseRoute { .. } => vec![C::TcpRoutesV1],
            Self::ComputerUseCapabilities => vec![C::ComputerUseNegotiationV1],
            Self::ComputerUseCapabilitiesV1
            | Self::InvokeComputerUse { .. }
            | Self::CancelComputerUse { .. } => vec![C::ComputerUseV1],
            Self::ReplaceMachineSecrets { .. } => vec![C::SecretsV1],
        }
    }
}

fn with_if(
    mut required: Vec<RemoteCapability>,
    condition: bool,
    capability: RemoteCapability,
) -> Vec<RemoteCapability> {
    if condition {
        required.push(capability);
    }
    required
}

impl RemoteCapability {
    /// The capability's wire string, as a peer advertises it.
    pub fn wire_name(&self) -> String {
        match serde_json::to_value(self) {
            Ok(serde_json::Value::String(name)) => name,
            _ => format!("{self:?}"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::WorkspaceId;

    #[test]
    fn plain_methods_need_only_their_own_capability() {
        assert!(WorkspaceRequest::Capabilities.required_capabilities().is_empty());
        assert_eq!(
            WorkspaceRequest::ListProcesses.required_capabilities(),
            vec![RemoteCapability::ProcessCatalogV1]
        );
        assert_eq!(
            WorkspaceRequest::ListWorkspaces.required_capabilities(),
            vec![RemoteCapability::WorkspaceFilesV1]
        );
    }

    #[test]
    fn optional_fields_add_the_capability_that_introduced_them() {
        let workspace = WorkspaceId("w".into());
        let codex = WorkspaceRequest::ApplyPatch {
            workspace: workspace.clone(),
            patch: "*** Begin Patch\n*** End Patch\n".into(),
            dry_run: true,
            preconditions: Default::default(),
        };
        assert_eq!(
            codex.required_capabilities(),
            vec![RemoteCapability::WorkspacePatchV1, RemoteCapability::WorkspacePatchV3]
        );
        let unified = WorkspaceRequest::ApplyPatch {
            workspace: workspace.clone(),
            patch: "--- a/x\n+++ b/x\n".into(),
            dry_run: true,
            preconditions: Default::default(),
        };
        assert_eq!(unified.required_capabilities(), vec![RemoteCapability::WorkspacePatchV1]);
        let paged = WorkspaceRequest::Diff {
            workspace,
            paths: Vec::new(),
            staged: false,
            context: 3,
            format: crate::DiffFormat::Unified,
            cursor: None,
            max_bytes: Some(1),
        };
        assert_eq!(
            paged.required_capabilities(),
            vec![RemoteCapability::WorkspaceDiffV1, RemoteCapability::WorkspacePaginationV1]
        );
    }

    #[test]
    fn wire_name_is_the_advertised_string() {
        assert_eq!(RemoteCapability::ProcessCatalogV1.wire_name(), "process-catalog-v1");
        assert_eq!(RemoteCapability::Unknown("future-v9".into()).wire_name(), "future-v9");
    }
}
