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

#[derive(Clone, Debug, Deserialize, Serialize, ToSchema)]
pub struct SandboxSummary {
    pub id: Uuid,
    pub index: usize,
    pub name: String,
    pub created_at: DateTime<Utc>,
    pub workspace: String,
    pub status: SandboxStatus,
    pub network: SandboxNetwork,
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
