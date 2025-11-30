use std::sync::Arc;

use agent_client_protocol::{ModelId, SessionId, SessionModelState, SessionNotification};

use crate::acp_client::provider::AcpProvider;
use crate::acp_client::workspace_sync::WorkspaceSyncStatus;

pub(crate) enum AppEvent {
    SessionUpdate(Box<SessionNotification>),
    DebugMessage {
        direction: String,
        message: String,
    },
    /// Provider switch completed successfully
    ProviderSwitchComplete {
        provider: AcpProvider,
        connection: Arc<agent_client_protocol::ClientSideConnection>,
        session_id: SessionId,
        model_state: Option<SessionModelState>,
    },
    /// Provider switch failed
    ProviderSwitchFailed {
        provider: AcpProvider,
        error: String,
    },
    /// Model switch completed successfully
    ModelSwitchComplete {
        model_id: ModelId,
    },
    /// Model switch failed
    ModelSwitchFailed {
        error: String,
    },
    /// ACP request error (prompt, tool calls, etc.)
    RequestError {
        error: String,
    },
    /// Models loaded for a provider (for the model picker)
    ProviderModelsLoaded {
        provider: AcpProvider,
        /// List of (model_id, display_name) pairs
        models: Vec<(String, String)>,
    },
    /// Failed to load models for a provider
    ProviderModelsLoadFailed {
        provider: AcpProvider,
    },
    WorkspaceSyncStatus(WorkspaceSyncStatus),
}
