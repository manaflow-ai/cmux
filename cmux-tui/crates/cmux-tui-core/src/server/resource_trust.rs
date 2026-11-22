//! The trusted-local rule of the connection-owned resource operations.

use serde_json::json;

use super::{Mux, ResourceError, ResourceOperation};

/// `Ok` for a local Unix connection; every other transport is refused with
/// `operation.failed` naming the authority it lacks.
pub(super) fn trusted_local_resource_client(
    mux: &Mux,
    client: u64,
    operation: ResourceOperation,
) -> Result<(), ResourceError> {
    if mux.control_clients.is_unix(client) {
        Ok(())
    } else {
        let operation = operation.wire_name().to_owned();
        Err(ResourceError::operation_failed(
            operation,
            "operation requires a trusted local connection",
            json!({"required_authority":"trusted_local"}),
        ))
    }
}

/// The operations `handle_resource_connection_message` answers itself (they
/// need the connection: its streams, its principal, its client record).
pub(super) const fn handles_resource_connection_operation(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        ResourceOperation::SessionEvents
            | ResourceOperation::SessionJournalSubscribe
            | ResourceOperation::SessionJournalProducerList
            | ResourceOperation::SessionJournalProducerPut
            | ResourceOperation::SessionJournalAppend
            | ResourceOperation::SessionJournalHookList
            | ResourceOperation::SessionJournalHookPut
            | ResourceOperation::SessionJournalCheckpointCreate
            | ResourceOperation::SessionJournalCheckpointList
            | ResourceOperation::SessionJournalRestorePreview
            | ResourceOperation::SessionJournalSegmentList
            | ResourceOperation::SessionJournalSegmentSeal
            | ResourceOperation::SessionShutdown
            | ResourceOperation::PairingRequestList
            | ResourceOperation::PairingRequestResolve
            | ResourceOperation::RequestCancel
            | ResourceOperation::ClientList
            | ResourceOperation::ClientGet
            | ResourceOperation::ClientMetadataUpdate
            | ResourceOperation::ClientSizingSet
            | ResourceOperation::ClientSizingRelease
            | ResourceOperation::ClientCellPixelsSet
            | ResourceOperation::ClientDetach
            | ResourceOperation::TerminalRendererGrantCreate
            | ResourceOperation::TerminalViewerResize
            | ResourceOperation::TerminalViewerRelease
            | ResourceOperation::TerminalAttach
            | ResourceOperation::BrowserViewerResize
            | ResourceOperation::BrowserViewerRelease
            | ResourceOperation::BrowserAttach
            | ResourceOperation::SidebarViewAttach
            | ResourceOperation::StreamCancel
            | ResourceOperation::OriginConfirmationIssue
    ) || super::conversation_resource::handles(operation)
        || super::chief_control::handles(operation)
}
