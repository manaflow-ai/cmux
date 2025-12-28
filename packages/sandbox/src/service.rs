use crate::errors::SandboxResult;
use crate::models::{
    AwaitReadyRequest, AwaitReadyResponse, CreateSandboxRequest, ExecRequest, ExecResponse,
    GhResponse, HostEvent, PruneRequest, PruneResponse, PtyCaptureResponse, PtyCreateRequest,
    PtyResizeRequest, PtySessionInfo, SandboxSummary,
};
use crate::notifications::NotificationStore;
use async_trait::async_trait;
use axum::body::Body;
use axum::extract::ws::WebSocket;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{broadcast, oneshot, Mutex};

/// Broadcast channel for host-directed events (open-url, notifications, etc.).
/// Sent to connected mux clients to handle actions on the host machine.
pub type HostEventSender = broadcast::Sender<HostEvent>;
pub type HostEventReceiver = broadcast::Receiver<HostEvent>;

/// Registry for pending gh requests awaiting responses.
pub type GhResponseRegistry = Arc<Mutex<HashMap<String, oneshot::Sender<GhResponse>>>>;

/// Cached gh auth status result from the host.
/// Used to quickly respond to `gh auth status` requests from sandboxes.
#[derive(Clone, Debug, Default)]
pub struct CachedGhAuth {
    pub exit_code: i32,
    pub stdout: String,
    pub stderr: String,
}

/// Cache for gh auth status, shared across connections.
pub type GhAuthCache = Arc<Mutex<Option<CachedGhAuth>>>;

#[async_trait]
pub trait SandboxService: Send + Sync + 'static {
    async fn create(&self, request: CreateSandboxRequest) -> SandboxResult<SandboxSummary>;
    async fn list(&self) -> SandboxResult<Vec<SandboxSummary>>;
    async fn get(&self, id: String) -> SandboxResult<Option<SandboxSummary>>;
    async fn exec(&self, id: String, exec: ExecRequest) -> SandboxResult<ExecResponse>;
    async fn attach(
        &self,
        id: String,
        socket: WebSocket,
        initial_size: Option<(u16, u16)>,
        command: Option<Vec<String>>,
        tty: bool,
    ) -> SandboxResult<()>;
    /// Multiplexed attach - handles multiple PTY sessions over a single WebSocket.
    async fn mux_attach(
        &self,
        socket: WebSocket,
        host_event_rx: HostEventReceiver,
        gh_responses: GhResponseRegistry,
        gh_auth_cache: GhAuthCache,
    ) -> SandboxResult<()>;
    async fn proxy(&self, id: String, port: u16, socket: WebSocket) -> SandboxResult<()>;
    async fn upload_archive(&self, id: String, archive: Body) -> SandboxResult<()>;
    async fn delete(&self, id: String) -> SandboxResult<Option<SandboxSummary>>;
    /// Prune orphaned sandbox filesystem directories that don't correspond to running sandboxes.
    async fn prune_orphaned(&self, request: PruneRequest) -> SandboxResult<PruneResponse>;
    /// Wait for sandbox services (VNC, VS Code, etc.) to become ready.
    async fn await_services_ready(
        &self,
        id: String,
        request: AwaitReadyRequest,
    ) -> SandboxResult<AwaitReadyResponse>;

    // =========================================================================
    // PTY Session Methods (HTTP API)
    // =========================================================================

    /// Create a new PTY session in a sandbox.
    async fn pty_create_session(
        &self,
        sandbox_id: String,
        request: PtyCreateRequest,
    ) -> SandboxResult<PtySessionInfo>;

    /// List all PTY sessions in a sandbox.
    async fn pty_list_sessions(&self, sandbox_id: String) -> SandboxResult<Vec<PtySessionInfo>>;

    /// Get a specific PTY session.
    async fn pty_get_session(
        &self,
        sandbox_id: String,
        session_id: String,
    ) -> SandboxResult<Option<PtySessionInfo>>;

    /// Capture the current terminal content of a PTY session.
    async fn pty_capture_session(
        &self,
        sandbox_id: String,
        session_id: String,
    ) -> SandboxResult<PtyCaptureResponse>;

    /// Resize a PTY session.
    async fn pty_resize_session(
        &self,
        sandbox_id: String,
        session_id: String,
        request: PtyResizeRequest,
    ) -> SandboxResult<()>;

    /// Send input data to a PTY session.
    async fn pty_send_input(
        &self,
        sandbox_id: String,
        session_id: String,
        data: Vec<u8>,
    ) -> SandboxResult<()>;

    /// Delete (close) a PTY session.
    async fn pty_delete_session(&self, sandbox_id: String, session_id: String)
        -> SandboxResult<()>;
}

#[derive(Clone)]
pub struct AppState {
    pub service: Arc<dyn SandboxService>,
    pub host_events: HostEventSender,
    pub gh_responses: GhResponseRegistry,
    pub gh_auth_cache: GhAuthCache,
    pub notifications: NotificationStore,
}

impl AppState {
    pub fn new(
        service: Arc<dyn SandboxService>,
        host_events: HostEventSender,
        gh_responses: GhResponseRegistry,
        gh_auth_cache: GhAuthCache,
        notifications: NotificationStore,
    ) -> Self {
        Self {
            service,
            host_events,
            gh_responses,
            gh_auth_cache,
            notifications,
        }
    }
}

#[allow(dead_code)]
fn assert_app_state_bounds() {
    fn assert_state<T: Clone + Send + Sync + 'static>() {}
    assert_state::<AppState>();
}
