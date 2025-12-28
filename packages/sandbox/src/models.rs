use chrono::{DateTime, Utc};
use clap::ValueEnum;
use serde::{Deserialize, Serialize};
use utoipa::ToSchema;
use uuid::Uuid;

#[derive(Clone, Debug, Deserialize, Serialize, ToSchema)]
pub struct EnvVar {
    pub key: String,
    pub value: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, ToSchema)]
pub struct CreateSandboxRequest {
    pub name: Option<String>,
    /// Host path mounted into /workspace inside the sandbox
    #[schema(example = "/var/lib/cmux/sandboxes/workspaces/<id>")]
    pub workspace: Option<String>,
    #[serde(default)]
    pub tab_id: Option<String>,
    #[serde(default)]
    pub read_only_paths: Vec<String>,
    #[serde(default)]
    pub tmpfs: Vec<String>,
    #[serde(default)]
    pub env: Vec<EnvVar>,
}

#[derive(Clone, Debug, Deserialize, Serialize, ToSchema, PartialEq, Eq)]
pub enum SandboxStatus {
    /// Placeholder - creation in progress (client-only, never sent by server)
    Creating,
    Running,
    Exited,
    Failed,
    Unknown,
}

#[derive(Clone, Debug, Deserialize, Serialize, ToSchema)]
pub struct SandboxNetwork {
    pub host_interface: String,
    pub sandbox_interface: String,
    pub host_ip: String,
    pub sandbox_ip: String,
    pub cidr: u8,
}

/// Display configuration for a sandbox's isolated X11/VNC stack and VS Code server.
#[derive(Clone, Debug, Deserialize, Serialize, ToSchema)]
pub struct SandboxDisplay {
    /// X11 display number (e.g., 10 for :10)
    pub display_number: u16,
    /// VNC port (5900 + display_number, e.g., 5910)
    pub vnc_port: u16,
    /// noVNC WebSocket port (always 39380 inside sandbox, accessed via subdomain routing)
    pub novnc_port: u16,
    /// Chrome DevTools Protocol port
    pub cdp_port: u16,
    /// cmux-code (VS Code) port (always 39378 inside sandbox, accessed via subdomain routing)
    pub vscode_port: u16,
    /// cmux-pty port (always 39383 inside sandbox, accessed via subdomain routing)
    pub pty_port: u16,
}

/// Readiness status for sandbox services.
/// Used by the await-ready endpoint to wait for services to become available.
#[derive(Clone, Debug, Default, Deserialize, Serialize, ToSchema)]
pub struct ServiceReadiness {
    /// VNC/X11 display is ready
    #[serde(default)]
    pub vnc: bool,
    /// VS Code server is ready
    #[serde(default)]
    pub vscode: bool,
    /// PTY server is ready
    #[serde(default)]
    pub pty: bool,
}

/// Request to await service readiness
#[derive(Clone, Debug, Deserialize, ToSchema)]
pub struct AwaitReadyRequest {
    /// Services to wait for (default: all configured services)
    #[serde(default)]
    pub services: Vec<String>,
    /// Timeout in milliseconds (default: 10000)
    #[serde(default = "default_await_timeout")]
    pub timeout_ms: u64,
}

fn default_await_timeout() -> u64 {
    10000
}

/// Response from await-ready endpoint
#[derive(Clone, Debug, Serialize, ToSchema)]
pub struct AwaitReadyResponse {
    /// Whether all requested services are ready
    pub ready: bool,
    /// Current readiness status of each service
    pub services: ServiceReadiness,
    /// Services that timed out (if any)
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub timed_out: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, ToSchema)]
pub struct SandboxSummary {
    pub id: Uuid,
    pub index: usize,
    pub name: String,
    pub created_at: DateTime<Utc>,
    pub workspace: String,
    pub status: SandboxStatus,
    pub network: SandboxNetwork,
    /// Display configuration for isolated X11/VNC desktop.
    /// Each sandbox has its own virtual display, VNC server, and Chrome instance.
    #[serde(default)]
    pub display: Option<SandboxDisplay>,
    /// Correlation ID (tab_id) for matching placeholders to created sandboxes.
    /// Set by client when creating a placeholder; used to update in-place when
    /// the server responds with the real sandbox.
    #[serde(default)]
    pub correlation_id: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, ToSchema)]
pub struct ExecRequest {
    /// Command arguments executed via nsenter inside the sandbox
    #[schema(example = "[\"/bin/sh\",\"-c\",\"pnpm dev\"]")]
    pub command: Vec<String>,
    #[schema(example = "/workspace")]
    pub workdir: Option<String>,
    #[serde(default)]
    pub env: Vec<EnvVar>,
}

#[derive(Clone, Debug, Deserialize, Serialize, ToSchema)]
pub struct ExecResponse {
    pub exit_code: i32,
    pub stdout: String,
    pub stderr: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, ToSchema)]
pub struct HealthResponse {
    pub status: String,
}

#[derive(
    Clone, Debug, Deserialize, Serialize, ToSchema, PartialEq, Eq, Copy, ValueEnum, Default,
)]
#[serde(rename_all = "lowercase")]
pub enum NotificationLevel {
    #[default]
    Info,
    Warning,
    Error,
}

#[derive(Clone, Debug, Deserialize, Serialize, ToSchema)]
pub struct NotificationRequest {
    pub message: String,
    #[serde(default)]
    pub level: NotificationLevel,
    #[serde(default)]
    pub sandbox_id: Option<String>,
    #[serde(default)]
    pub tab_id: Option<String>,
    #[serde(default)]
    pub pane_id: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, ToSchema)]
pub struct OpenUrlRequest {
    pub url: String,
    #[serde(default)]
    pub sandbox_id: Option<String>,
    #[serde(default)]
    pub tab_id: Option<String>,
}

#[derive(Clone, Debug)]
pub enum HostEvent {
    OpenUrl(OpenUrlRequest),
    Notification(NotificationRequest),
    GhRequest(GhRequest),
}

#[derive(Clone, Debug, Deserialize, Serialize, ToSchema)]
pub struct NotificationLogEntry {
    pub id: Uuid,
    pub message: String,
    #[serde(default)]
    pub level: NotificationLevel,
    #[serde(default)]
    pub sandbox_id: Option<String>,
    #[serde(default)]
    pub tab_id: Option<String>,
    #[serde(default)]
    pub pane_id: Option<String>,
    pub received_at: DateTime<Utc>,
}

/// Request to run a `gh` CLI command on the host machine.
/// Used for git credential helpers and other gh commands that need host auth.
#[derive(Clone, Debug, Deserialize, Serialize, ToSchema)]
pub struct GhRequest {
    /// Unique request ID for correlating responses
    pub request_id: String,
    /// Arguments to pass to the `gh` command (e.g., ["auth", "git-credential", "get"])
    pub args: Vec<String>,
    /// Optional stdin to pass to the command
    #[serde(default)]
    pub stdin: Option<String>,
    #[serde(default)]
    pub sandbox_id: Option<String>,
    #[serde(default)]
    pub tab_id: Option<String>,
}

/// Response from running a `gh` CLI command on the host.
#[derive(Clone, Debug, Deserialize, Serialize, ToSchema)]
pub struct GhResponse {
    /// Request ID this response corresponds to
    pub request_id: String,
    pub exit_code: i32,
    /// Stdout from the command
    pub stdout: String,
    /// Stderr from the command
    pub stderr: String,
}

/// Request to prune orphaned sandbox filesystem directories.
#[derive(Clone, Debug, Deserialize, Serialize, ToSchema)]
pub struct PruneRequest {
    /// Only prune directories older than this many seconds.
    /// If not specified, defaults to 86400 (24 hours).
    #[serde(default)]
    pub max_age_secs: Option<u64>,
    /// If true, prune all orphaned directories regardless of age.
    #[serde(default)]
    pub all: bool,
    /// If true, only report what would be deleted without actually deleting.
    #[serde(default)]
    pub dry_run: bool,
}

/// Information about a pruned orphaned directory.
#[derive(Clone, Debug, Deserialize, Serialize, ToSchema)]
pub struct PrunedItem {
    /// The UUID of the orphaned sandbox directory.
    pub id: String,
    /// Path to the directory that was (or would be) deleted.
    pub path: String,
    /// Age of the directory in seconds.
    pub age_secs: u64,
    /// Size of the directory in bytes.
    #[serde(default)]
    pub size_bytes: u64,
}

/// Response from pruning orphaned sandbox directories.
#[derive(Clone, Debug, Deserialize, Serialize, ToSchema)]
pub struct PruneResponse {
    /// Number of orphaned directories that were deleted (or would be in dry_run mode).
    pub deleted_count: usize,
    /// Number of directories that failed to delete.
    pub failed_count: usize,
    /// Details about each pruned item.
    pub items: Vec<PrunedItem>,
    /// Whether this was a dry run.
    pub dry_run: bool,
    /// Total bytes freed (or would be freed in dry_run mode).
    #[serde(default)]
    pub bytes_freed: u64,
}

// ============================================================================
// Unified Bridge Socket Protocol
// ============================================================================

/// Request sent from sandbox to host via the bridge socket.
/// Uses tagged enum for type discrimination.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum BridgeRequest {
    /// Open a URL on the host machine
    OpenUrl {
        url: String,
        #[serde(default)]
        sandbox_id: Option<String>,
        #[serde(default)]
        tab_id: Option<String>,
    },
    /// Run a gh CLI command on the host machine
    Gh {
        #[serde(default)]
        request_id: String,
        args: Vec<String>,
        #[serde(default)]
        stdin: Option<String>,
        #[serde(default)]
        sandbox_id: Option<String>,
        #[serde(default)]
        tab_id: Option<String>,
    },
    /// Send a notification to the host UI
    Notify {
        message: String,
        #[serde(default)]
        level: NotificationLevel,
        #[serde(default)]
        sandbox_id: Option<String>,
        #[serde(default)]
        tab_id: Option<String>,
        #[serde(default)]
        pane_id: Option<String>,
    },
    /// List PTY sessions in the sandbox
    PtyList { sandbox_id: String },
    /// Get a specific PTY session
    PtyGet {
        sandbox_id: String,
        session_id: String,
    },
    /// Create a new PTY session
    PtyCreate {
        sandbox_id: String,
        #[serde(default)]
        name: Option<String>,
        #[serde(default = "default_bridge_command")]
        command: String,
        #[serde(default)]
        args: Vec<String>,
        #[serde(default = "default_bridge_cols")]
        cols: u16,
        #[serde(default = "default_bridge_rows")]
        rows: u16,
        #[serde(default = "default_bridge_cwd")]
        cwd: String,
        #[serde(default)]
        env: std::collections::HashMap<String, String>,
    },
    /// Send input to a PTY session
    PtyInput {
        sandbox_id: String,
        session_id: String,
        /// Base64-encoded input data
        data: String,
    },
    /// Resize a PTY session
    PtyResize {
        sandbox_id: String,
        session_id: String,
        cols: u16,
        rows: u16,
    },
    /// Capture PTY session content
    PtyCapture {
        sandbox_id: String,
        session_id: String,
    },
    /// Delete a PTY session
    PtyDelete {
        sandbox_id: String,
        session_id: String,
    },
}

fn default_bridge_command() -> String {
    "/bin/bash".to_string()
}

fn default_bridge_cols() -> u16 {
    80
}

fn default_bridge_rows() -> u16 {
    24
}

fn default_bridge_cwd() -> String {
    "/workspace".to_string()
}

/// Response from the bridge socket.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum BridgeResponse {
    /// Response to open-url request
    Ok,
    /// Error response
    Error { message: String },
    /// Response to gh command
    Gh {
        request_id: String,
        exit_code: i32,
        stdout: String,
        stderr: String,
    },
    /// Response to PTY list request
    PtyList { sessions: Vec<PtySessionInfo> },
    /// Response to PTY get request
    PtySession { session: Option<PtySessionInfo> },
    /// Response to PTY create request
    PtyCreated { session: PtySessionInfo },
    /// Response to PTY capture request
    PtyCapture {
        content: String,
        cursor_x: u16,
        cursor_y: u16,
    },
}

// ============================================================================
// Multiplexed WebSocket Protocol Messages
// ============================================================================

/// Unique identifier for a PTY session within a multiplexed connection.
/// This is a string to allow for flexible ID generation on the client side.
pub type PtySessionId = String;

/// Client-to-server messages for the multiplexed WebSocket protocol.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum MuxClientMessage {
    /// Create a new sandbox.
    CreateSandbox {
        /// Optional name for the sandbox.
        #[serde(default)]
        name: Option<String>,
        /// Environment variables to inject into the sandbox.
        #[serde(default)]
        env: Vec<EnvVar>,
    },
    /// List all sandboxes.
    ListSandboxes,
    /// Attach to a sandbox's terminal, creating a new PTY session.
    Attach {
        session_id: PtySessionId,
        sandbox_id: String,
        cols: u16,
        rows: u16,
        #[serde(default)]
        command: Option<Vec<String>>,
        #[serde(default = "default_tty")]
        tty: bool,
        /// Tab identifier for this session (used for routing notifications).
        #[serde(default)]
        tab_id: Option<String>,
        /// Pane identifier for this session (used for diagnostics/UI focus).
        #[serde(default)]
        pane_id: Option<String>,
    },
    /// Send input data to a PTY session.
    Input {
        session_id: PtySessionId,
        #[serde(with = "base64_bytes")]
        data: Vec<u8>,
    },
    /// Resize a PTY session.
    Resize {
        session_id: PtySessionId,
        cols: u16,
        rows: u16,
    },
    /// Detach from a PTY session (close it).
    Detach { session_id: PtySessionId },
    /// Ping to keep connection alive.
    Ping { timestamp: u64 },
    /// Response to a gh command request from the server.
    GhResponse {
        request_id: String,
        exit_code: i32,
        stdout: String,
        stderr: String,
    },
    /// Cache gh auth status for faster responses to sandboxes.
    /// Sent by client on connect after running `gh auth status` locally.
    GhAuthCache {
        exit_code: i32,
        stdout: String,
        stderr: String,
    },
    /// Forward a signal to all PTY child processes.
    /// Common uses: SIGUSR1 (theme change), SIGUSR2, SIGHUP (config reload).
    Signal {
        /// Signal number to send (e.g., 10 for SIGUSR1 on most Unix systems)
        signum: i32,
    },
}

/// Server-to-client messages for the multiplexed WebSocket protocol.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum MuxServerMessage {
    /// Sandbox was successfully created.
    SandboxCreated(SandboxSummary),
    /// List of all sandboxes.
    SandboxList { sandboxes: Vec<SandboxSummary> },
    /// PTY session was successfully attached.
    Attached { session_id: PtySessionId },
    /// Output data from a PTY session.
    Output {
        session_id: PtySessionId,
        #[serde(with = "base64_bytes")]
        data: Vec<u8>,
    },
    /// PTY session exited.
    Exited {
        session_id: PtySessionId,
        #[serde(default)]
        exit_code: Option<i32>,
    },
    /// Error occurred for a session.
    Error {
        session_id: Option<PtySessionId>,
        message: String,
    },
    /// Pong response to ping.
    Pong { timestamp: u64 },
    /// Request to open a URL on the client (host) machine.
    /// This is sent when a sandbox process calls xdg-open/open-url.
    OpenUrl {
        url: String,
        #[serde(default)]
        sandbox_id: Option<String>,
        #[serde(default)]
        tab_id: Option<String>,
    },
    /// Request to show a notification to the user.
    Notification {
        message: String,
        #[serde(default)]
        level: NotificationLevel,
        #[serde(default)]
        sandbox_id: Option<String>,
        #[serde(default)]
        tab_id: Option<String>,
        #[serde(default)]
        pane_id: Option<String>,
    },
    /// Request to run a gh CLI command on the client (host) machine.
    /// Client should respond with MuxClientMessage::GhResponse.
    GhRequest {
        request_id: String,
        args: Vec<String>,
        #[serde(default)]
        stdin: Option<String>,
        #[serde(default)]
        sandbox_id: Option<String>,
        #[serde(default)]
        tab_id: Option<String>,
    },
}

fn default_tty() -> bool {
    true
}

// ============================================================================
// HTTP PTY Session Types
// ============================================================================

/// Request to create a new PTY session in a sandbox.
#[derive(Clone, Debug, Deserialize, ToSchema)]
pub struct PtyCreateRequest {
    /// Optional session name
    #[serde(default)]
    pub name: Option<String>,
    /// Command to run (default: /bin/bash)
    #[serde(default = "default_command")]
    pub command: String,
    /// Command arguments
    #[serde(default)]
    pub args: Vec<String>,
    /// Terminal columns (default: 80)
    #[serde(default = "default_cols")]
    pub cols: u16,
    /// Terminal rows (default: 24)
    #[serde(default = "default_rows")]
    pub rows: u16,
    /// Working directory (default: /workspace)
    #[serde(default = "default_cwd")]
    pub cwd: String,
    /// Environment variables as key-value pairs
    #[serde(default)]
    pub env: std::collections::HashMap<String, String>,
}

fn default_command() -> String {
    "/bin/bash".to_string()
}

fn default_cwd() -> String {
    "/workspace".to_string()
}

fn default_cols() -> u16 {
    80
}

fn default_rows() -> u16 {
    24
}

/// Information about a PTY session.
#[derive(Clone, Debug, Deserialize, Serialize, ToSchema)]
pub struct PtySessionInfo {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub command: String,
    pub args: Vec<String>,
    pub cols: u16,
    pub rows: u16,
    pub cwd: String,
    pub created_at: DateTime<Utc>,
    pub exited: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i32>,
}

/// List of PTY sessions.
#[derive(Clone, Debug, Serialize, ToSchema)]
pub struct PtySessionList {
    pub sessions: Vec<PtySessionInfo>,
}

/// Response from capturing PTY terminal content.
#[derive(Clone, Debug, Serialize, ToSchema)]
pub struct PtyCaptureResponse {
    /// Terminal content as text
    pub content: String,
    /// Cursor X position (column)
    pub cursor_x: u16,
    /// Cursor Y position (row)
    pub cursor_y: u16,
}

/// Request to resize a PTY session.
#[derive(Clone, Debug, Deserialize, ToSchema)]
pub struct PtyResizeRequest {
    pub cols: u16,
    pub rows: u16,
}

/// Request to send input to a PTY session.
#[derive(Clone, Debug, Deserialize, ToSchema)]
pub struct PtyInputRequest {
    /// Base64-encoded input data
    #[serde(with = "base64_bytes")]
    pub data: Vec<u8>,
}

/// Helper module for base64 encoding/decoding of byte vectors in JSON.
mod base64_bytes {
    use base64::{engine::general_purpose::STANDARD, Engine};
    use serde::{Deserialize, Deserializer, Serialize, Serializer};

    pub fn serialize<S>(bytes: &Vec<u8>, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let encoded = STANDARD.encode(bytes);
        encoded.serialize(serializer)
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Vec<u8>, D::Error>
    where
        D: Deserializer<'de>,
    {
        let encoded = String::deserialize(deserializer)?;
        STANDARD.decode(&encoded).map_err(serde::de::Error::custom)
    }
}
