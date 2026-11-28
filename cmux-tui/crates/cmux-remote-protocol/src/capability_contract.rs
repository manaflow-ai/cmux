//! The intended wire contract for each workspace capability. Fields inherit their
//! enclosing message's capability unless a later protocol revision introduced them.

use crate::RemoteCapability;

impl RemoteCapability {
    pub(crate) fn wire_names(&self) -> &'static [&'static str] {
        match self {
            Self::MuxControlV9 => &["service:mux-control"],
            Self::WorkspaceFilesV1 => &[
                "method:open-workspace",
                "method:list-workspaces",
                "method:stat",
                "method:read-file",
                "method:write-file",
                "method:list-directory",
                "method:response/workspace",
                "method:response/workspaces",
                "method:response/stat",
                "method:response/file",
                "method:response/written",
                "method:response/directory",
            ],
            Self::WorkspaceSearchV1 => &["method:search", "method:response/search"],
            Self::WorkspacePatchV1 => &["method:apply-patch", "method:response/patch"],
            Self::WorkspacePatchV2 => {
                &["param:apply-patch#preconditions", "field:response.patch#files"]
            }
            // V3 adds the Codex patch format to the existing apply-patch method.
            Self::WorkspacePatchV3 => &["header:*** Begin Patch"],
            Self::WorkspaceDiffV1 => &[
                "method:git-status",
                "method:diff",
                "method:response/git-status",
                "method:response/diff",
            ],
            Self::StructuredDiffV1 => &["method:response/structured-diff"],
            Self::WorkspacePaginationV1 => &[
                "param:list-directory#cursor",
                "param:search#cursor",
                "param:diff#cursor",
                "param:diff#max_bytes",
                "field:response.directory#next_cursor",
                "field:response.search#next_cursor",
                "field:response.diff#next_cursor",
            ],
            Self::ProcessPipesV1 => &[
                "method:spawn-process",
                "method:write-process",
                "method:signal-process",
                "method:wait-process",
                "method:response/process-started",
                "method:response/process-write-accepted",
                "method:response/process-signaled",
                "method:response/process-exit",
                "service:process-stream",
                "param:process-stream#process",
                "event:stdout",
                "event:stderr",
                "event:exit",
            ],
            Self::ProcessPtyV1 => &["method:resize-process", "method:response/process-resized"],
            Self::ProcessLifecycleV2 => &[
                "method:finish-operation",
                "method:response/operation-finished",
                "method:close-workspace",
                "method:response/workspace-closed",
                "param:spawn-process#operation",
                "param:spawn-process#timeout_ms",
                "param:spawn-process#retained_output_bytes",
                "field:response.process-started#operation",
            ],
            Self::ProcessReplayV1 => &[
                "method:read-process-events",
                "method:response/process-events",
                "method:response/process-replay-gap",
                "param:process-stream#after",
                "event:replay-gap",
                "event:output-truncated",
            ],
            Self::ProcessHandlesV2 => {
                &["method:spawn-process-with-handle", "param:process-stream#reserve"]
            }
            Self::ProcessCatalogV1 => &["method:list-processes", "method:response/processes"],
            Self::ProcessTerminalSnapshotV1 => {
                &["method:snapshot-process-terminal", "method:response/process-terminal-snapshot"]
            }
            Self::TcpRoutesV1 => &[
                "service:tcp-tunnel",
                "param:tcp-tunnel#route",
                "method:create-route",
                "method:close-route",
                "method:response/route-created",
                "method:response/closed",
            ],
            Self::RequestControlV1 => &[
                "method:cancel-request",
                "method:response/request-canceled",
                "param:workspace-rpc#purpose",
            ],
            Self::ComputerUseNegotiationV1 => {
                &["method:computer-use-capabilities", "method:response/computer-use-capabilities"]
            }
            Self::ComputerUseV1 => &[
                "service:computer-use",
                "method:computer-use-capabilities-v1",
                "method:response/computer-use-capabilities-v1",
                "method:invoke-computer-use",
                "method:cancel-computer-use",
                "method:response/computer-use-accepted",
                "method:response/computer-use-result",
                "method:response/computer-use-canceled",
            ],
            Self::TerminalViewerSizePriorityV1 => &["param:terminal-bytes-v1#viewer_size_priority"],
            Self::SecretsV1 => {
                &["method:replace-machine-secrets", "method:response/machine-secrets-replaced"]
            }
            Self::GitHostTokensV1 => {
                &["method:replace-git-host-token", "method:response/git-host-token-replaced"]
            }
            // Behavior only: the daemon answers the existing reads from its replica.
            Self::PausedReadsV1 | Self::Unknown(_) => &[],
        }
    }

    /// A capability that changes what a peer does with existing messages and
    /// adds no wire name of its own.
    pub(crate) fn changes_no_wire(&self) -> bool {
        matches!(self, Self::PausedReadsV1)
    }
}
