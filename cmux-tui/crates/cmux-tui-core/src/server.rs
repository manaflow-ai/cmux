//! Control protocol server over Unix JSON-lines and WebSocket text frames.
//!
//! This is the attach surface for external frontends (the cmux app, the
//! bundled `cmux-tui attach` client, scripts). Unix uses one JSON message
//! per line and WebSocket uses one JSON message per text frame. Three commands
//! additionally turn the connection full-duplex:
//!
//! - `subscribe` — the server pushes `{"event":...}` lines (tree-changed,
//!   surface-output, surface-exited, title-changed, bell) interleaved
//!   with responses.
//! - `subscribe-topology` — the server pushes revisioned canonical topology
//!   replacements from a validated snapshot cursor.
//! - `attach-surface` — PTYs receive `{"event":"vt-state"}` with a
//!   base64 VT replay followed by live `{"event":"output"}` pty bytes.
//!   Browsers receive `{"event":"browser-state"}` with optional latest
//!   frame followed by live `{"event":"frame"}` PNG payloads.
//!
//! ```text
//! {"id":1,"cmd":"identify"}
//! {"id":1,"ok":true,"data":{"app":"cmux-tui","session":"main",...}}
//! ```

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{Shutdown, SocketAddr, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, RwLock};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use base64::Engine;
use ghostty_vt::{
    Dirty, KeyAction, KeyEncoder, KeyInput, Mods, MouseAction, MouseButton, MouseInput,
    SelectionAdjustment, StyledRun, UnderlineStyle, key_input_from_chord, rows_to_runs,
};
use regex::Regex;
use serde::de::{self, DeserializeSeed, MapAccess, SeqAccess, Visitor};
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tungstenite::protocol::CloseFrame;
use tungstenite::protocol::frame::coding::CloseCode;
use tungstenite::protocol::{Role, WebSocketConfig};
use tungstenite::{Message, WebSocket, accept_with_config};

use crate::connection_security::{
    ConnectionAuthorization, ConnectionPermission, ConnectionRole, RegisteredClientKind,
    TopologyMutationLease, TopologyMutationLeaseClaim,
};
use crate::model::{Screen, State};
use crate::mux::{
    CanonicalMutationExpectation, CanonicalMutationReceipt, CanonicalSurfacePlacement,
    EnsureTerminalRequest, RendererPreedit, RendererPresentationConfiguration,
    TerminalLaunchRequest, clamp_terminal_size,
};
use crate::platform::{self, transport};
use crate::presentation::normalize_presentation;
use crate::projection_state::{
    ProjectionClaimant, ProjectionStateUpdate, ProjectionWorkspaceState,
};
use crate::renderer_control::{RendererColorSpace, RendererFrameRelease, RendererPixelFormat};
use crate::surface::{
    AttachLifecycle, ExternalTerminalClaimReceipt, ExternalTerminalOutputReceipt,
    ExternalTerminalOwner, MouseSelectionAutoscrollDirection, TerminalInteractionSnapshot,
};
use crate::terminal_authority::{
    AutomationInputScope, BeginTerminalOperation, DEFAULT_TERMINAL_LEASE_TTL_MS,
    PresentationAuthority, RequestFingerprint, TerminalConnectionClaim,
    TerminalDelegationReference, TerminalInputGroup, TerminalLeaseClaim, TerminalLeaseKind,
    TerminalLeaseReference, TerminalOperationKind, TerminalOperationOutcome,
    TerminalOperationReceipt,
};
use crate::{
    AgentRecord, AgentSource, AgentState, AttachFrame, DaemonInstanceId, DefaultColors, Direction,
    LEGACY_TERMINAL_ACTIVITY_READER_UUID, LayoutLeafSpec, LayoutSpec, Mux, MuxEvent,
    MuxEventReceiver, Node, NotificationLevel, PairingDecision, PaneId, PresentationId,
    PresentationScroll, PresentationView, PresentationZoom, RenderAttachFrame, Rgb, ScreenId,
    SidebarPluginStatus, SplitDir, SurfaceId, SurfaceKind, SurfaceNotification, SurfaceRenderFrame,
    SurfaceUuid, TerminalColors, TopologyResume, TreeDelta, TreeDeltaKind, WorkspaceId,
    WorkspaceUuid, ZoomMode, assign_short_ids,
};

pub const PROTOCOL_VERSION: u32 = 8;
pub const PROTOCOL_MIN_VERSION: u32 = 6;
pub const PROTOCOL_MAX_VERSION: u32 = 9;
pub const PROTOCOL_CAPABILITIES: &[&str] = &[
    "durable-session-identity-v1",
    "ensure-terminal-v1",
    "ensure-terminals-v1",
    "reparent-terminal-v1",
    "canonical-topology-mutations-v1",
    "canonical-topology-snapshot-v1",
    "presentation-registry-v1",
    "projection-state-reconnect-v1",
    "renderer-semantic-scene-v1",
    "renderer-worker-supervision-v1",
    "render-attach-v1",
    "stable-entity-uuid-v1",
    "terminal-interaction-v1",
    "terminal-accessibility-v1",
    "terminal-activity-v1",
    "terminal-control-lease-v1",
    "terminal-split-leases-v1",
    "terminal-lease-transfer-v1",
    "terminal-input-delegation-v1",
    "terminal-input-groups-v1",
    "terminal-global-input-order-v1",
    "terminal-input-idempotency-v1",
    "terminal-input-receipt-ack-v1",
    "terminal-nonrenderer-presentation-v1",
    "terminal-link-hit-v1",
    "terminal-ordered-input-v1",
    "topology-resume-v1",
    "topology-revision-v1",
    "tree-delta-v1",
];

/// Default socket path for a session.
pub fn default_socket_path(session: &str) -> PathBuf {
    default_socket_path_in(
        &platform::runtime_dir(),
        &platform::short_runtime_dir(),
        session,
        if cfg!(target_os = "macos") { Some(103) } else { None },
    )
}

fn default_socket_path_in(
    runtime_dir: &Path,
    short_runtime_dir: &Path,
    session: &str,
    max_bytes: Option<usize>,
) -> PathBuf {
    let candidate = runtime_dir.join(format!("{session}.sock"));
    if max_bytes.is_none_or(|limit| socket_path_bytes(&candidate) <= limit) {
        candidate
    } else {
        short_runtime_dir.join(format!("{session}.sock"))
    }
}

fn socket_path_bytes(path: &Path) -> usize {
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        path.as_os_str().as_bytes().len()
    }
    #[cfg(not(unix))]
    {
        path.as_os_str().to_string_lossy().len()
    }
}

#[derive(Deserialize)]
struct Request {
    id: Option<Value>,
    #[serde(flatten)]
    cmd: Command,
}

/// First-pass envelope used before allocating a typed command tree. Unknown
/// fields are skipped by serde_json's non-materializing `IgnoredAny` path. A
/// borrowed command rejects escaped command names instead of allocating a
/// scratch String controlled by the peer.
#[derive(Deserialize)]
struct CommandEnvelope<'a> {
    #[serde(borrow)]
    cmd: &'a str,
}

#[derive(Deserialize)]
struct EnsureTerminalEnvironment {
    name: String,
    value: String,
}

#[derive(Deserialize)]
struct CanonicalMutationWire {
    request_id: uuid::Uuid,
    daemon_instance_id: DaemonInstanceId,
    session_id: crate::SessionId,
    expected_revision: u64,
    topology_lease_id: uuid::Uuid,
    topology_lease_generation: u64,
}

impl CanonicalMutationWire {
    fn lease_claim(&self) -> TopologyMutationLeaseClaim {
        TopologyMutationLeaseClaim {
            id: self.topology_lease_id,
            generation: self.topology_lease_generation,
        }
    }
}

impl From<CanonicalMutationWire> for CanonicalMutationExpectation {
    fn from(value: CanonicalMutationWire) -> Self {
        Self {
            request_id: value.request_id,
            daemon_instance_id: value.daemon_instance_id,
            session_id: value.session_id,
            expected_revision: value.expected_revision,
        }
    }
}

#[derive(Deserialize)]
struct EnsureTerminalSpec {
    workspace_uuid: WorkspaceUuid,
    surface_uuid: SurfaceUuid,
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default)]
    argv: Option<Vec<String>>,
    #[serde(default)]
    command: Option<String>,
    #[serde(default)]
    env: Vec<EnsureTerminalEnvironment>,
    #[serde(default)]
    initial_input: Option<String>,
    #[serde(default)]
    wait_after_command: bool,
    cols: u16,
    rows: u16,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
enum TerminalInputPayload {
    Text {
        text: String,
        #[serde(default)]
        paste: bool,
    },
    Bytes {
        data: String,
        #[serde(default)]
        paste: bool,
    },
    /// A Ghostty chord name such as `enter` or `ctrl+shift+p`. This is the
    /// protocol-v9 equivalent of one entry in the legacy `send-key` command.
    NamedKey { key: String },
    Key {
        key: u32,
        #[serde(default)]
        modifiers: u16,
        #[serde(default)]
        consumed_modifiers: u16,
        #[serde(default)]
        text: String,
        #[serde(default)]
        unshifted_codepoint: u32,
        #[serde(default)]
        action: Option<String>,
    },
    /// Renderer-resolved cell coordinates. Protocol v9 never accepts
    /// frontend-provided cell pixel dimensions as mouse authority.
    Mouse {
        action: String,
        #[serde(default)]
        button: Option<String>,
        #[serde(default)]
        modifiers: u16,
        column: u16,
        row: u16,
        #[serde(default)]
        any_button_pressed: bool,
        #[serde(default = "default_terminal_mouse_click_count")]
        click_count: u8,
        #[serde(default)]
        autoscroll: Option<String>,
    },
}

#[derive(Deserialize)]
#[serde(tag = "cmd", rename_all = "kebab-case")]
enum Command {
    Identify,
    Ping,
    RegisterClient {
        protocol_min: u32,
        protocol_max: u32,
        client_uuid: uuid::Uuid,
        process_instance_uuid: uuid::Uuid,
        #[serde(default)]
        client_kind: Option<String>,
    },
    OpenPresentation {
        #[serde(default)]
        view: PresentationView,
        #[serde(default)]
        zoom: PresentationZoom,
        #[serde(default)]
        scroll: PresentationScroll,
    },
    ClosePresentation {
        presentation_id: PresentationId,
    },
    ActivateTerminalPresentation {
        presentation_id: PresentationId,
        expected_generation: u64,
    },
    UpdatePresentation {
        presentation_id: PresentationId,
        expected_generation: u64,
        #[serde(default)]
        view: Option<PresentationView>,
        #[serde(default)]
        zoom: Option<PresentationZoom>,
        #[serde(default)]
        scroll: Option<PresentationScroll>,
    },
    ListPresentations,
    ClaimProjectionState {
        logical_presentation_id: uuid::Uuid,
    },
    UpdateProjectionState {
        logical_presentation_id: uuid::Uuid,
        claim_id: uuid::Uuid,
        expected_generation: u64,
        workspaces: Vec<ProjectionWorkspaceState>,
    },
    UpdateProjectionStates {
        projections: Vec<ProjectionStateUpdate>,
    },
    ReleaseProjectionState {
        logical_presentation_id: uuid::Uuid,
        claim_id: uuid::Uuid,
        expected_generation: u64,
    },
    ListProjectionStates,
    EnsureTerminal {
        workspace_uuid: WorkspaceUuid,
        surface_uuid: SurfaceUuid,
        #[serde(default)]
        cwd: Option<String>,
        #[serde(default)]
        argv: Option<Vec<String>>,
        #[serde(default)]
        command: Option<String>,
        #[serde(default)]
        env: Vec<EnsureTerminalEnvironment>,
        #[serde(default)]
        initial_input: Option<String>,
        #[serde(default)]
        wait_after_command: bool,
        cols: u16,
        rows: u16,
    },
    EnsureTerminals {
        terminals: Vec<EnsureTerminalSpec>,
    },
    ReparentTerminal {
        surface_uuid: SurfaceUuid,
        workspace_uuid: WorkspaceUuid,
    },
    RendererWorkers,
    ConfigureRendererPresentation {
        presentation_id: PresentationId,
        expected_generation: u64,
        width: u32,
        height: u32,
        backing_scale_factor: f64,
        columns: u16,
        rows: u16,
        pixel_format: String,
        color_space: String,
        frame_endpoint_service: String,
        frame_endpoint_capability: String,
        #[serde(default)]
        resolved_config_revision: u64,
        #[serde(default)]
        resolved_config: String,
        #[serde(default = "default_true")]
        focused: bool,
        #[serde(default = "default_true")]
        cursor_blink_visible: bool,
        #[serde(default)]
        preedit: Option<String>,
        #[serde(default)]
        preedit_selection_start_utf16: u32,
        #[serde(default)]
        preedit_selection_length_utf16: u32,
        #[serde(default)]
        preedit_caret_utf16: u32,
    },
    DetachRendererPresentation {
        presentation_id: PresentationId,
        expected_generation: u64,
    },
    TerminalPreedit {
        presentation_id: PresentationId,
        renderer_generation: u64,
        #[serde(default)]
        text: Option<String>,
        #[serde(default)]
        selection_start_utf16: u32,
        #[serde(default)]
        selection_length_utf16: u32,
        #[serde(default)]
        caret_utf16: u32,
    },
    TerminalAccessibilitySnapshot {
        presentation_id: PresentationId,
        expected_generation: u64,
        expected_content_sequence: u64,
    },
    TerminalAccessibilityActivateLink {
        presentation_id: PresentationId,
        expected_generation: u64,
        terminal_revision: u64,
        content_revision: u64,
        viewport_revision: u64,
        link_id: String,
    },
    TerminalLinkAtCell {
        presentation_id: PresentationId,
        expected_generation: u64,
        expected_content_sequence: u64,
        column: u16,
        row: u16,
    },
    AcquireTerminalControl {
        surface_uuid: SurfaceUuid,
        presentation_id: PresentationId,
        presentation_generation: u64,
        #[serde(default = "default_terminal_lease_ttl_ms")]
        ttl_ms: u64,
    },
    AcquireTerminalLease {
        kind: String,
        surface_uuid: SurfaceUuid,
        presentation_id: PresentationId,
        presentation_generation: u64,
        #[serde(default = "default_terminal_lease_ttl_ms")]
        ttl_ms: u64,
    },
    RenewTerminalLease {
        kind: String,
        surface_uuid: SurfaceUuid,
        presentation_id: PresentationId,
        presentation_generation: u64,
        lease_id: uuid::Uuid,
        lease_generation: u64,
        #[serde(default = "default_terminal_lease_ttl_ms")]
        ttl_ms: u64,
    },
    ReleaseTerminalControl {
        surface_uuid: SurfaceUuid,
        presentation_id: PresentationId,
        presentation_generation: u64,
        lease_id: uuid::Uuid,
        lease_generation: u64,
    },
    ReleaseTerminalLease {
        kind: String,
        surface_uuid: SurfaceUuid,
        presentation_id: PresentationId,
        presentation_generation: u64,
        lease_id: uuid::Uuid,
        lease_generation: u64,
    },
    TransferTerminalLease {
        kind: String,
        surface_uuid: SurfaceUuid,
        presentation_id: PresentationId,
        presentation_generation: u64,
        lease_id: uuid::Uuid,
        lease_generation: u64,
        target_client_uuid: uuid::Uuid,
        target_presentation_id: PresentationId,
        target_presentation_generation: u64,
        #[serde(default = "default_terminal_lease_ttl_ms")]
        ttl_ms: u64,
    },
    GrantTerminalInputDelegation {
        surface_uuid: SurfaceUuid,
        presentation_id: PresentationId,
        presentation_generation: u64,
        lease_id: uuid::Uuid,
        lease_generation: u64,
        delegate_client_uuid: uuid::Uuid,
        ttl_ms: u64,
        scopes: Vec<String>,
    },
    RevokeTerminalInputDelegation {
        surface_uuid: SurfaceUuid,
        presentation_id: PresentationId,
        presentation_generation: u64,
        lease_id: uuid::Uuid,
        lease_generation: u64,
        delegation_id: uuid::Uuid,
        delegation_generation: u64,
    },
    TerminalInput {
        surface_uuid: SurfaceUuid,
        presentation_id: PresentationId,
        presentation_generation: u64,
        lease_id: uuid::Uuid,
        lease_generation: u64,
        sequence: u64,
        request_id: uuid::Uuid,
        input: TerminalInputPayload,
        #[serde(default)]
        input_group_id: Option<uuid::Uuid>,
        #[serde(default)]
        input_group_index: Option<u32>,
        #[serde(default)]
        input_group_end: Option<bool>,
    },
    TerminalDelegatedInput {
        surface_uuid: SurfaceUuid,
        delegation_id: uuid::Uuid,
        delegation_generation: u64,
        sequence: u64,
        request_id: uuid::Uuid,
        input: TerminalInputPayload,
        #[serde(default)]
        input_group_id: Option<uuid::Uuid>,
        #[serde(default)]
        input_group_index: Option<u32>,
        #[serde(default)]
        input_group_end: Option<bool>,
    },
    TerminalGeometry {
        surface_uuid: SurfaceUuid,
        presentation_id: PresentationId,
        presentation_generation: u64,
        lease_id: uuid::Uuid,
        lease_generation: u64,
        sequence: u64,
        request_id: uuid::Uuid,
        cols: u16,
        rows: u16,
    },
    TerminalRequestStatus {
        surface_uuid: SurfaceUuid,
        request_id: uuid::Uuid,
    },
    AcknowledgeTerminalRequest {
        surface_uuid: SurfaceUuid,
        request_id: uuid::Uuid,
    },
    ReleaseRendererFrame {
        daemon_instance_id: uuid::Uuid,
        renderer_epoch: u64,
        terminal_id: uuid::Uuid,
        terminal_epoch: u64,
        terminal_sequence: u64,
        presentation_id: uuid::Uuid,
        presentation_generation: u64,
        frame_sequence: u64,
        surface_id: u32,
    },
    SetClientInfo {
        #[serde(default)]
        name: Option<String>,
        #[serde(default)]
        kind: Option<String>,
    },
    ListClients,
    SetClientSizing {
        #[serde(default)]
        client: Option<u64>,
        enabled: bool,
        #[serde(default)]
        exclusive: bool,
    },
    PairingResponse {
        request: u64,
        approve: bool,
    },
    DetachClient {
        client: u64,
    },
    ReloadConfig,
    SetWindowTitle {
        title: String,
    },
    ClearWindowTitle,
    TopologySnapshot,
    TerminalActivitySnapshot,
    MarkTerminalSeen {
        surface_uuid: SurfaceUuid,
        activity_sequence: u64,
    },
    ListWorkspaces,
    ExportLayout {
        #[serde(default)]
        screen: Option<ScreenId>,
    },
    ApplyLayout {
        #[serde(default)]
        workspace: Option<WorkspaceId>,
        #[serde(default)]
        name: Option<String>,
        layout: LayoutRequest,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    Send {
        surface: SurfaceId,
        #[serde(default)]
        text: Option<String>,
        /// Base64-encoded raw bytes, written verbatim to the pty.
        #[serde(default)]
        bytes: Option<String>,
        #[serde(default)]
        paste: bool,
    },
    ReadScreen {
        surface: SurfaceId,
    },
    ReadScrollback {
        surface: SurfaceId,
        start: u32,
        count: u32,
    },
    SidebarPlugin {
        cols: u16,
        rows: u16,
        #[serde(default)]
        relaunch: bool,
    },
    WaitFor {
        surface: SurfaceId,
        pattern: String,
        #[serde(alias = "timeout_ms")]
        timeout_ms: u64,
    },
    Run {
        #[serde(default)]
        argv: Option<Vec<String>>,
        #[serde(default)]
        command: Option<String>,
        #[serde(default)]
        cwd: Option<String>,
        #[serde(default)]
        pane: Option<PaneId>,
        #[serde(default)]
        new_workspace: bool,
        #[serde(default)]
        name: Option<String>,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    SendKey {
        surface: SurfaceId,
        keys: Vec<String>,
    },
    /// One layout-resolved physical key event. cmuxd encodes it against the
    /// canonical terminal modes, so frontends never keep a second VT parser.
    TerminalKey {
        surface: SurfaceId,
        key: u32,
        #[serde(default)]
        modifiers: u16,
        #[serde(default)]
        consumed_modifiers: u16,
        #[serde(default)]
        text: String,
        #[serde(default)]
        unshifted_codepoint: u32,
        #[serde(default)]
        action: Option<String>,
    },
    TerminalMouse {
        surface: SurfaceId,
        action: String,
        #[serde(default)]
        button: Option<String>,
        #[serde(default)]
        modifiers: u16,
        x: f32,
        y: f32,
        viewport_width: u32,
        viewport_height: u32,
        cell_width: u32,
        cell_height: u32,
        #[serde(default)]
        padding_left: u32,
        #[serde(default)]
        padding_top: u32,
        #[serde(default)]
        padding_right: u32,
        #[serde(default)]
        padding_bottom: u32,
        #[serde(default)]
        any_button_pressed: bool,
        #[serde(default = "default_terminal_mouse_click_count")]
        click_count: u8,
    },
    TerminalState {
        surface_uuid: SurfaceUuid,
    },
    TerminalBindingAction {
        surface_uuid: SurfaceUuid,
        action: String,
        #[serde(default = "default_repeat_count")]
        repeat_count: usize,
    },
    TerminalSelection {
        surface_uuid: SurfaceUuid,
        operation: String,
    },
    TerminalCopyMode {
        surface_uuid: SurfaceUuid,
        operation: String,
        #[serde(default)]
        adjustment: Option<String>,
        #[serde(default = "default_repeat_count")]
        count: usize,
    },
    TerminalSearch {
        surface_uuid: SurfaceUuid,
        operation: String,
        #[serde(default)]
        query: Option<String>,
    },
    TerminalScroll {
        surface_uuid: SurfaceUuid,
        operation: String,
        #[serde(default)]
        amount: Option<isize>,
    },
    Copy {
        surface: SurfaceId,
        mode: String,
    },
    Ids {
        #[serde(default)]
        kind: Option<String>,
    },
    Notify {
        title: String,
        body: String,
        #[serde(default)]
        level: Option<String>,
        #[serde(default)]
        surface: Option<SurfaceId>,
    },
    ListAgents {
        #[serde(default)]
        surface: Option<SurfaceId>,
        #[serde(default)]
        state: Option<String>,
    },
    ReportAgent {
        surface: SurfaceId,
        state: String,
        source: String,
        #[serde(default)]
        session: Option<String>,
    },
    /// One-shot VT replay of the surface's current state (base64).
    VtState {
        surface: SurfaceId,
    },
    /// New tab in a pane (default: the active pane).
    NewTab {
        #[serde(default)]
        pane: Option<PaneId>,
        #[serde(default)]
        cwd: Option<String>,
        #[serde(default)]
        argv: Option<Vec<String>>,
        #[serde(default)]
        command: Option<String>,
        #[serde(default)]
        env: Vec<EnsureTerminalEnvironment>,
        #[serde(default)]
        initial_input: Option<String>,
        #[serde(default)]
        wait_after_command: bool,
        /// Expected content size in cells (spawn-at-size avoids shell
        /// redraw artifacts).
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    NewBrowserTab {
        url: String,
        #[serde(default)]
        pane: Option<PaneId>,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    SetCellPixels {
        #[serde(alias = "width_px")]
        width_px: u16,
        #[serde(alias = "height_px")]
        height_px: u16,
    },
    BrowserMouse {
        surface: SurfaceId,
        kind: String,
        #[serde(alias = "x_px")]
        x_px: f64,
        #[serde(alias = "y_px")]
        y_px: f64,
        #[serde(default)]
        button: Option<String>,
        #[serde(default, alias = "click_count")]
        click_count: Option<u32>,
    },
    BrowserWheel {
        surface: SurfaceId,
        #[serde(alias = "x_px")]
        x_px: f64,
        #[serde(alias = "y_px")]
        y_px: f64,
        #[serde(alias = "delta_y_px")]
        delta_y_px: f64,
    },
    BrowserKey {
        surface: SurfaceId,
        kind: String,
        key: String,
        code: String,
        #[serde(alias = "windows_virtual_key_code")]
        windows_virtual_key_code: u32,
        modifiers: u32,
        #[serde(default)]
        text: Option<String>,
    },
    BrowserInsertText {
        surface: SurfaceId,
        text: String,
    },
    BrowserNavigate {
        surface: SurfaceId,
        url: String,
    },
    BrowserBack {
        surface: SurfaceId,
    },
    BrowserForward {
        surface: SurfaceId,
    },
    BrowserReload {
        surface: SurfaceId,
    },
    BrowserActivate {
        surface: SurfaceId,
    },
    NewWorkspace {
        #[serde(default)]
        name: Option<String>,
        #[serde(default)]
        cwd: Option<String>,
        #[serde(default)]
        argv: Option<Vec<String>>,
        #[serde(default)]
        command: Option<String>,
        #[serde(default)]
        env: Vec<EnsureTerminalEnvironment>,
        #[serde(default)]
        initial_input: Option<String>,
        #[serde(default)]
        wait_after_command: bool,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    CanonicalNewWorkspace {
        #[serde(flatten)]
        mutation: CanonicalMutationWire,
        workspace_uuid: WorkspaceUuid,
        surface_uuid: SurfaceUuid,
        #[serde(default)]
        name: Option<String>,
        #[serde(default)]
        cwd: Option<String>,
        #[serde(default)]
        argv: Option<Vec<String>>,
        #[serde(default)]
        command: Option<String>,
        #[serde(default)]
        env: Vec<EnsureTerminalEnvironment>,
        #[serde(default)]
        initial_input: Option<String>,
        #[serde(default)]
        wait_after_command: bool,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    CanonicalNewTab {
        #[serde(flatten)]
        mutation: CanonicalMutationWire,
        pane_uuid: crate::PaneUuid,
        surface_uuid: SurfaceUuid,
        #[serde(default)]
        cwd: Option<String>,
        #[serde(default)]
        argv: Option<Vec<String>>,
        #[serde(default)]
        command: Option<String>,
        #[serde(default)]
        env: Vec<EnsureTerminalEnvironment>,
        #[serde(default)]
        initial_input: Option<String>,
        #[serde(default)]
        wait_after_command: bool,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    CanonicalMaterializeTerminal {
        #[serde(flatten)]
        mutation: CanonicalMutationWire,
        workspace_uuid: WorkspaceUuid,
        surface_uuid: SurfaceUuid,
        #[serde(default)]
        cwd: Option<String>,
        #[serde(default)]
        argv: Option<Vec<String>>,
        #[serde(default)]
        command: Option<String>,
        #[serde(default)]
        env: Vec<EnsureTerminalEnvironment>,
        #[serde(default)]
        initial_input: Option<String>,
        #[serde(default)]
        wait_after_command: bool,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    CanonicalRespawnTerminal {
        #[serde(flatten)]
        mutation: CanonicalMutationWire,
        surface_uuid: SurfaceUuid,
        #[serde(default)]
        cwd: Option<String>,
        #[serde(default)]
        argv: Option<Vec<String>>,
        #[serde(default)]
        command: Option<String>,
        #[serde(default)]
        env: Vec<EnsureTerminalEnvironment>,
        #[serde(default)]
        initial_input: Option<String>,
        #[serde(default)]
        wait_after_command: bool,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    CanonicalMaterializeExternalTerminal {
        #[serde(flatten)]
        mutation: CanonicalMutationWire,
        workspace_uuid: WorkspaceUuid,
        surface_uuid: SurfaceUuid,
        cols: u16,
        rows: u16,
        #[serde(default)]
        no_reflow: bool,
    },
    CanonicalNewBrowserWorkspace {
        #[serde(flatten)]
        mutation: CanonicalMutationWire,
        workspace_uuid: WorkspaceUuid,
        surface_uuid: SurfaceUuid,
        #[serde(default)]
        name: Option<String>,
        url: String,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    CanonicalNewBrowserTab {
        #[serde(flatten)]
        mutation: CanonicalMutationWire,
        pane_uuid: crate::PaneUuid,
        surface_uuid: SurfaceUuid,
        url: String,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    CanonicalSplitBrowserPane {
        #[serde(flatten)]
        mutation: CanonicalMutationWire,
        pane_uuid: crate::PaneUuid,
        surface_uuid: SurfaceUuid,
        dir: String,
        ratio: f32,
        url: String,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    ClaimExternalTerminal {
        surface_uuid: SurfaceUuid,
        request_id: uuid::Uuid,
    },
    ResetExternalTerminal {
        surface_uuid: SurfaceUuid,
        owner_generation: u64,
        request_id: uuid::Uuid,
        output_generation: u64,
        cols: u16,
        rows: u16,
        seed: String,
    },
    ExternalTerminalOutput {
        surface_uuid: SurfaceUuid,
        owner_generation: u64,
        request_id: uuid::Uuid,
        output_generation: u64,
        sequence: u64,
        data: String,
    },
    DrainExternalTerminalEgress {
        surface_uuid: SurfaceUuid,
        owner_generation: u64,
    },
    CanonicalSplitPane {
        #[serde(flatten)]
        mutation: CanonicalMutationWire,
        pane_uuid: crate::PaneUuid,
        surface_uuid: SurfaceUuid,
        dir: String,
        ratio: f32,
        #[serde(default)]
        cwd: Option<String>,
        #[serde(default)]
        argv: Option<Vec<String>>,
        #[serde(default)]
        command: Option<String>,
        #[serde(default)]
        env: Vec<EnsureTerminalEnvironment>,
        #[serde(default)]
        initial_input: Option<String>,
        #[serde(default)]
        wait_after_command: bool,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    CanonicalSplitTab {
        #[serde(flatten)]
        mutation: CanonicalMutationWire,
        surface_uuid: SurfaceUuid,
        pane_uuid: crate::PaneUuid,
        dir: String,
        ratio: f32,
    },
    CanonicalClosePane {
        #[serde(flatten)]
        mutation: CanonicalMutationWire,
        pane_uuid: crate::PaneUuid,
    },
    CanonicalCloseWorkspace {
        #[serde(flatten)]
        mutation: CanonicalMutationWire,
        workspace_uuid: WorkspaceUuid,
    },
    CanonicalRenameWorkspace {
        #[serde(flatten)]
        mutation: CanonicalMutationWire,
        workspace_uuid: WorkspaceUuid,
        name: String,
    },
    CanonicalRenameSurface {
        #[serde(flatten)]
        mutation: CanonicalMutationWire,
        surface_uuid: SurfaceUuid,
        name: String,
    },
    CanonicalMoveTab {
        #[serde(flatten)]
        mutation: CanonicalMutationWire,
        surface_uuid: SurfaceUuid,
        pane_uuid: crate::PaneUuid,
        index: usize,
    },
    CanonicalReorderTabs {
        #[serde(flatten)]
        mutation: CanonicalMutationWire,
        pane_uuid: crate::PaneUuid,
        surface_uuids: Vec<SurfaceUuid>,
    },
    CanonicalReorderWorkspaces {
        #[serde(flatten)]
        mutation: CanonicalMutationWire,
        workspace_uuids: Vec<WorkspaceUuid>,
    },
    CanonicalMoveTabToNewWorkspace {
        #[serde(flatten)]
        mutation: CanonicalMutationWire,
        surface_uuid: SurfaceUuid,
        workspace_uuid: WorkspaceUuid,
        #[serde(default)]
        name: Option<String>,
        #[serde(default)]
        index: Option<usize>,
    },
    CanonicalSetSplitRatio {
        #[serde(flatten)]
        mutation: CanonicalMutationWire,
        pane_uuid: crate::PaneUuid,
        dir: String,
        ratio: f32,
    },
    /// New screen in a workspace (default: the active one).
    NewScreen {
        #[serde(default)]
        workspace: Option<WorkspaceId>,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    Split {
        pane: PaneId,
        /// "left", "right", "up", or "down"
        dir: String,
        #[serde(default)]
        ratio: Option<f32>,
        #[serde(default)]
        cwd: Option<String>,
        #[serde(default)]
        argv: Option<Vec<String>>,
        #[serde(default)]
        command: Option<String>,
        #[serde(default)]
        env: Vec<EnsureTerminalEnvironment>,
        #[serde(default)]
        initial_input: Option<String>,
        #[serde(default)]
        wait_after_command: bool,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    SetRatio {
        pane: PaneId,
        /// "right" or "down"
        dir: String,
        ratio: f32,
    },
    PaneNeighbor {
        pane: PaneId,
        dir: String,
    },
    FocusDirection {
        #[serde(default)]
        pane: Option<PaneId>,
        dir: String,
    },
    SwapPane {
        pane: PaneId,
        #[serde(default)]
        dir: Option<String>,
        #[serde(default)]
        target: Option<PaneId>,
    },
    ZoomPane {
        #[serde(default)]
        pane: Option<PaneId>,
        #[serde(default)]
        mode: Option<String>,
    },
    ProcessInfo {
        surface: SurfaceId,
    },
    MoveTab {
        surface: SurfaceId,
        pane: PaneId,
        index: usize,
    },
    MoveWorkspace {
        workspace: WorkspaceId,
        index: usize,
    },
    SetDefaultColors {
        #[serde(default)]
        fg: Option<String>,
        #[serde(default)]
        bg: Option<String>,
    },
    /// Close one tab.
    CloseSurface {
        surface: SurfaceId,
    },
    /// Close a pane and all its tabs.
    ClosePane {
        pane: PaneId,
    },
    CloseScreen {
        screen: ScreenId,
    },
    CloseWorkspace {
        workspace: WorkspaceId,
    },
    RenamePane {
        pane: PaneId,
        /// Empty clears the name (falls back to the tab title).
        name: String,
    },
    RenameSurface {
        surface: SurfaceId,
        /// Empty clears the name (falls back to the generated tab label).
        name: String,
    },
    RenameScreen {
        screen: ScreenId,
        /// Empty clears the name (falls back to the screen number).
        name: String,
    },
    RenameWorkspace {
        workspace: WorkspaceId,
        name: String,
    },
    ResizeSurface {
        surface: SurfaceId,
        cols: u16,
        rows: u16,
    },
    /// Stop this client from contributing a size for a surface while
    /// retaining its attach stream for cached rendering.
    ReleaseSurfaceSize {
        surface: SurfaceId,
    },
    FocusPane {
        pane: PaneId,
    },
    /// Select a tab within a pane (default: the active pane).
    SelectTab {
        #[serde(default)]
        pane: Option<PaneId>,
        #[serde(default)]
        index: Option<usize>,
        #[serde(default)]
        delta: Option<isize>,
    },
    /// Select a screen within the active workspace.
    SelectScreen {
        #[serde(default)]
        index: Option<usize>,
        #[serde(default)]
        delta: Option<isize>,
    },
    SelectWorkspace {
        #[serde(default)]
        index: Option<usize>,
        #[serde(default)]
        delta: Option<isize>,
    },
    /// Stream mux events on this connection.
    Subscribe {
        #[serde(default)]
        tree_events: Option<String>,
    },
    /// Protocol-v8 canonical topology stream with retained-delta resume.
    SubscribeTopology {
        daemon_instance_id: DaemonInstanceId,
        session_id: crate::SessionId,
        revision: u64,
    },
    /// Stream a surface: vt-state event followed by live output events.
    AttachSurface {
        surface: SurfaceId,
        #[serde(default)]
        mode: Option<String>,
    },
    /// Scroll a surface's viewport by a row delta (negative is up).
    ScrollSurface {
        surface: SurfaceId,
        delta: isize,
    },
}

impl Command {
    fn canonical_mutation_claim(&self) -> Option<TopologyMutationLeaseClaim> {
        match self {
            Self::CanonicalNewWorkspace { mutation, .. }
            | Self::CanonicalNewTab { mutation, .. }
            | Self::CanonicalMaterializeTerminal { mutation, .. }
            | Self::CanonicalRespawnTerminal { mutation, .. }
            | Self::CanonicalMaterializeExternalTerminal { mutation, .. }
            | Self::CanonicalNewBrowserWorkspace { mutation, .. }
            | Self::CanonicalNewBrowserTab { mutation, .. }
            | Self::CanonicalSplitBrowserPane { mutation, .. }
            | Self::CanonicalSplitPane { mutation, .. }
            | Self::CanonicalSplitTab { mutation, .. }
            | Self::CanonicalClosePane { mutation, .. }
            | Self::CanonicalCloseWorkspace { mutation, .. }
            | Self::CanonicalRenameWorkspace { mutation, .. }
            | Self::CanonicalRenameSurface { mutation, .. }
            | Self::CanonicalMoveTab { mutation, .. }
            | Self::CanonicalReorderTabs { mutation, .. }
            | Self::CanonicalReorderWorkspaces { mutation, .. }
            | Self::CanonicalMoveTabToNewWorkspace { mutation, .. }
            | Self::CanonicalSetSplitRatio { mutation, .. } => Some(mutation.lease_claim()),
            _ => None,
        }
    }
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
enum LayoutRequest {
    Leaf {
        #[serde(default)]
        cwd: Option<String>,
        #[serde(default)]
        command: Option<Vec<String>>,
    },
    Split {
        dir: String,
        ratio: f32,
        a: Box<LayoutRequest>,
        b: Box<LayoutRequest>,
    },
}

#[derive(Serialize)]
struct Response {
    #[serde(skip_serializing_if = "Option::is_none")]
    id: Option<Value>,
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    data: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

const STREAM_DISCONNECT_POLL: Duration = Duration::from_millis(100);
const STREAM_WRITE_TIMEOUT: Duration = Duration::from_secs(2);
#[cfg(not(test))]
const WEBSOCKET_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(5);
#[cfg(test)]
const WEBSOCKET_HANDSHAKE_TIMEOUT: Duration = Duration::from_millis(100);
const MAX_SERVER_CONNECTIONS: usize = 64;
const MAX_TOPOLOGY_STREAMS: u64 = 256;
const WEBSOCKET_AUTH_MAX_BYTES: usize = 4 * 1024;
const CONTROL_MESSAGE_MAX_BYTES: usize = 4 * 1024 * 1024;
const EXTERNAL_TERMINAL_PAYLOAD_MAX_BYTES: usize = 2 * 1024 * 1024;
const WEBSOCKET_MESSAGE_MAX_BYTES: usize = CONTROL_MESSAGE_MAX_BYTES;
/// One mux-wide ceiling covering Unix line buffers, WebSocket frame reads, and
/// conservatively estimated allocations made while decoding admitted JSON.
/// This replaces the old per-connection-only bound, which permitted 64 peers
/// to materialize independent 4 MiB request trees at once.
const INBOUND_INFLIGHT_MAX_BYTES: usize = 32 * 1024 * 1024;
const PRE_REGISTRATION_MESSAGE_MAX_BYTES: usize = 16 * 1024;
const STANDARD_COMMAND_MAX_BYTES: usize = 256 * 1024;
const STANDARD_COMMAND_DECODE_MAX_BYTES: usize = 4 * 1024 * 1024;
const BULK_COMMAND_DECODE_MAX_BYTES: usize = 12 * 1024 * 1024;
const AUTH_DECODE_MAX_BYTES: usize = 32 * 1024;
const COMMAND_NAME_MAX_BYTES: usize = 64;
const WEBSOCKET_BUDGETED_READ_TIMEOUT: Duration = Duration::from_millis(50);
const TERMINAL_KEY_TEXT_MAX_BYTES: usize = 4 * 1024;
const TERMINAL_KEY_MODIFIERS_MASK: u16 = 0x03ff;
const TERMINAL_SEARCH_QUERY_MAX_BYTES: usize = 64 * 1024;
const TERMINAL_ACTION_MAX_REPEAT_COUNT: usize = 10_000;

const fn default_true() -> bool {
    true
}

const fn default_repeat_count() -> usize {
    1
}

const fn default_terminal_mouse_click_count() -> u8 {
    1
}

const fn default_terminal_lease_ttl_ms() -> u64 {
    DEFAULT_TERMINAL_LEASE_TTL_MS
}

fn parse_renderer_pixel_format(value: &str) -> anyhow::Result<RendererPixelFormat> {
    match value {
        "bgra8-unorm" => Ok(RendererPixelFormat::Bgra8Unorm),
        "rgba16-float" => Ok(RendererPixelFormat::Rgba16Float),
        other => anyhow::bail!("bad request: unknown renderer pixel format {other:?}"),
    }
}

const fn renderer_pixel_format_name(value: RendererPixelFormat) -> &'static str {
    match value {
        RendererPixelFormat::Bgra8Unorm => "bgra8-unorm",
        RendererPixelFormat::Rgba16Float => "rgba16-float",
    }
}

fn parse_renderer_color_space(value: &str) -> anyhow::Result<RendererColorSpace> {
    match value {
        "srgb" => Ok(RendererColorSpace::Srgb),
        "display-p3" => Ok(RendererColorSpace::DisplayP3),
        "extended-linear-srgb" => Ok(RendererColorSpace::ExtendedLinearSrgb),
        other => anyhow::bail!("bad request: unknown renderer color space {other:?}"),
    }
}

fn parse_renderer_preedit(
    text: Option<String>,
    selection_start_utf16: u32,
    selection_length_utf16: u32,
    caret_utf16: u32,
) -> anyhow::Result<Option<RendererPreedit>> {
    let Some(text) = text else {
        if selection_start_utf16 != 0 || selection_length_utf16 != 0 || caret_utf16 != 0 {
            anyhow::bail!("bad request: cleared terminal preedit has nonzero UTF-16 state");
        }
        return Ok(None);
    };
    if text.len() > TERMINAL_KEY_TEXT_MAX_BYTES {
        anyhow::bail!("bad request: terminal preedit exceeds {TERMINAL_KEY_TEXT_MAX_BYTES} bytes");
    }
    let utf16_len = u32::try_from(text.encode_utf16().count())
        .map_err(|_| anyhow::anyhow!("bad request: terminal preedit UTF-16 length overflow"))?;
    let selection_end = selection_start_utf16
        .checked_add(selection_length_utf16)
        .ok_or_else(|| anyhow::anyhow!("bad request: terminal preedit selection overflow"))?;
    if selection_end > utf16_len || caret_utf16 > utf16_len {
        anyhow::bail!("bad request: terminal preedit UTF-16 state is outside marked text");
    }
    if text.is_empty() {
        return Ok(None);
    }
    Ok(Some(RendererPreedit { text, selection_start_utf16, selection_length_utf16, caret_utf16 }))
}

const fn renderer_color_space_name(value: RendererColorSpace) -> &'static str {
    match value {
        RendererColorSpace::Srgb => "srgb",
        RendererColorSpace::DisplayP3 => "display-p3",
        RendererColorSpace::ExtendedLinearSrgb => "extended-linear-srgb",
    }
}
const OUTBOUND_CAPACITY: usize = 256;
const OUTBOUND_CONTROL_RESERVE: usize = 256;
const OUTBOUND_BYTE_CAPACITY: usize = 16 * 1024 * 1024;
const OUTBOUND_CONTROL_BYTE_RESERVE: usize = 16 * 1024 * 1024;
const CLIENT_DETACH_WRITE_TIMEOUT: Duration = Duration::from_millis(100);

#[derive(Debug)]
struct InboundBudget {
    limit: usize,
    state: Mutex<InboundBudgetState>,
    changed: Condvar,
}

#[derive(Debug, Default)]
struct InboundBudgetState {
    used: usize,
    peak: usize,
}

impl InboundBudget {
    fn new(limit: usize) -> Arc<Self> {
        Arc::new(Self {
            limit,
            state: Mutex::new(InboundBudgetState::default()),
            changed: Condvar::new(),
        })
    }

    fn try_reserve(self: &Arc<Self>, bytes: usize) -> Option<InboundPermit> {
        let mut state = self.state.lock().unwrap();
        if bytes > self.limit.saturating_sub(state.used) {
            return None;
        }
        state.used += bytes;
        state.peak = state.peak.max(state.used);
        Some(InboundPermit { budget: self.clone(), bytes })
    }

    fn reserve_timeout(self: &Arc<Self>, bytes: usize, timeout: Duration) -> Option<InboundPermit> {
        let deadline = Instant::now() + timeout;
        let mut state = self.state.lock().unwrap();
        loop {
            if bytes <= self.limit.saturating_sub(state.used) {
                state.used += bytes;
                state.peak = state.peak.max(state.used);
                return Some(InboundPermit { budget: self.clone(), bytes });
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return None;
            }
            let (next, wait) = self.changed.wait_timeout(state, remaining).unwrap();
            state = next;
            if wait.timed_out() && bytes > self.limit.saturating_sub(state.used) {
                return None;
            }
        }
    }

    #[cfg(test)]
    fn usage(&self) -> (usize, usize) {
        let state = self.state.lock().unwrap();
        (state.used, state.peak)
    }
}

struct InboundPermit {
    budget: Arc<InboundBudget>,
    bytes: usize,
}

impl InboundPermit {
    fn try_grow(&mut self, bytes: usize) -> bool {
        if bytes == 0 {
            return true;
        }
        let mut state = self.budget.state.lock().unwrap();
        if bytes > self.budget.limit.saturating_sub(state.used) {
            return false;
        }
        state.used += bytes;
        state.peak = state.peak.max(state.used);
        self.bytes += bytes;
        true
    }

    fn shrink_to(&mut self, bytes: usize) {
        assert!(bytes <= self.bytes, "inbound permit cannot grow through shrink_to");
        let released = self.bytes - bytes;
        if released == 0 {
            return;
        }
        let mut state = self.budget.state.lock().unwrap();
        state.used = state.used.checked_sub(released).expect("inbound budget underflow");
        self.bytes = bytes;
        drop(state);
        self.budget.changed.notify_all();
    }

    #[cfg(test)]
    fn bytes(&self) -> usize {
        self.bytes
    }
}

impl Drop for InboundPermit {
    fn drop(&mut self) {
        let mut state = self.budget.state.lock().unwrap();
        state.used = state.used.checked_sub(self.bytes).expect("inbound budget underflow");
        drop(state);
        self.budget.changed.notify_all();
    }
}

#[derive(Debug, Clone, Copy)]
struct CommandAdmissionPolicy {
    wire_max: usize,
    decoded_max: usize,
    permission: Option<ConnectionPermission>,
    protocol_v9: bool,
}

fn command_admission_policy(command: &str) -> CommandAdmissionPolicy {
    let mut policy = CommandAdmissionPolicy {
        wire_max: STANDARD_COMMAND_MAX_BYTES,
        decoded_max: STANDARD_COMMAND_DECODE_MAX_BYTES,
        // Unknown and newly added commands fail closed as control mutations.
        // Read-only commands must be explicitly granted below.
        permission: Some(ConnectionPermission::Control),
        protocol_v9: false,
    };
    match command {
        "identify" | "ping" | "register-client" => {
            policy.wire_max = PRE_REGISTRATION_MESSAGE_MAX_BYTES;
            policy.decoded_max = AUTH_DECODE_MAX_BYTES;
        }
        "ensure-terminal"
        | "ensure-terminals"
        | "canonical-new-workspace"
        | "canonical-new-tab"
        | "canonical-materialize-terminal"
        | "canonical-respawn-terminal"
        | "canonical-materialize-external-terminal"
        | "canonical-new-browser-workspace"
        | "canonical-new-browser-tab"
        | "canonical-split-browser-pane"
        | "reset-external-terminal"
        | "external-terminal-output"
        | "canonical-split-pane"
        | "update-projection-state"
        | "update-projection-states"
        | "configure-renderer-presentation"
        | "terminal-input"
        | "terminal-delegated-input"
        | "send"
        | "apply-layout"
        | "browser-insert-text" => {
            policy.wire_max = CONTROL_MESSAGE_MAX_BYTES;
            policy.decoded_max = BULK_COMMAND_DECODE_MAX_BYTES;
        }
        _ => {}
    }
    if matches!(
        command,
        "identify"
            | "ping"
            | "register-client"
            | "topology-snapshot"
            | "terminal-activity-snapshot"
            | "list-workspaces"
            | "export-layout"
            | "read-screen"
            | "read-scrollback"
            | "wait-for"
            | "terminal-state"
            | "ids"
            | "list-agents"
            | "vt-state"
            | "pane-neighbor"
            | "process-info"
            | "subscribe"
            | "subscribe-topology"
            | "attach-surface"
    ) {
        policy.permission = None;
    }
    if matches!(
        command,
        "ensure-terminal"
            | "ensure-terminals"
            | "reparent-terminal"
            | "canonical-new-workspace"
            | "canonical-new-tab"
            | "canonical-materialize-terminal"
            | "canonical-respawn-terminal"
            | "canonical-materialize-external-terminal"
            | "canonical-new-browser-workspace"
            | "canonical-new-browser-tab"
            | "canonical-split-browser-pane"
            | "canonical-split-pane"
            | "canonical-split-tab"
            | "canonical-close-pane"
            | "canonical-close-workspace"
            | "canonical-rename-workspace"
            | "canonical-rename-surface"
            | "canonical-move-tab"
            | "canonical-reorder-tabs"
            | "canonical-reorder-workspaces"
            | "canonical-move-tab-to-new-workspace"
            | "canonical-set-split-ratio"
            | "close-surface"
            | "close-pane"
            | "close-screen"
            | "close-workspace"
            | "acquire-terminal-control"
            | "acquire-terminal-lease"
            | "renew-terminal-lease"
            | "release-terminal-control"
            | "release-terminal-lease"
            | "transfer-terminal-lease"
            | "grant-terminal-input-delegation"
            | "revoke-terminal-input-delegation"
            | "terminal-input"
            | "terminal-delegated-input"
            | "terminal-geometry"
            | "terminal-request-status"
            | "acknowledge-terminal-request"
            | "mark-terminal-seen"
            | "apply-layout"
            | "run"
            | "send"
            | "send-key"
            | "terminal-key"
            | "terminal-mouse"
            | "terminal-binding-action"
            | "terminal-selection"
            | "terminal-copy-mode"
            | "terminal-search"
            | "terminal-scroll"
            | "new-tab"
            | "new-browser-tab"
            | "new-workspace"
            | "new-screen"
            | "split"
            | "set-ratio"
            | "swap-pane"
            | "zoom-pane"
            | "move-tab"
            | "move-workspace"
            | "rename-pane"
            | "rename-surface"
            | "rename-screen"
            | "rename-workspace"
            | "resize-surface"
            | "release-surface-size"
            | "scroll-surface"
            | "set-cell-pixels"
            | "browser-mouse"
            | "browser-wheel"
            | "browser-key"
            | "browser-insert-text"
            | "browser-navigate"
            | "browser-back"
            | "browser-forward"
            | "browser-reload"
            | "browser-activate"
            | "set-client-sizing"
            | "detach-client"
            | "reload-config"
            | "set-window-title"
            | "clear-window-title"
            | "focus-pane"
            | "select-tab"
            | "select-screen"
            | "select-workspace"
            | "set-default-colors"
            | "notify"
            | "report-agent"
            | "sidebar-plugin"
    ) {
        policy.permission = Some(ConnectionPermission::Control);
    }
    if matches!(
        command,
        "open-presentation"
            | "close-presentation"
            | "activate-terminal-presentation"
            | "update-presentation"
            | "list-presentations"
            | "claim-projection-state"
            | "update-projection-state"
            | "update-projection-states"
            | "release-projection-state"
            | "list-projection-states"
            | "renderer-workers"
            | "configure-renderer-presentation"
            | "detach-renderer-presentation"
            | "terminal-preedit"
            | "terminal-accessibility-snapshot"
            | "terminal-accessibility-activate-link"
            | "terminal-link-at-cell"
            | "release-renderer-frame"
            | "list-clients"
            | "pairing-response"
            | "copy"
            | "claim-external-terminal"
            | "reset-external-terminal"
            | "external-terminal-output"
            | "drain-external-terminal-egress"
    ) {
        policy.permission = Some(ConnectionPermission::Frontend);
    }
    policy.protocol_v9 = matches!(
        command,
        "activate-terminal-presentation"
            | "canonical-new-workspace"
            | "canonical-new-tab"
            | "canonical-materialize-terminal"
            | "canonical-respawn-terminal"
            | "canonical-materialize-external-terminal"
            | "canonical-new-browser-workspace"
            | "canonical-new-browser-tab"
            | "canonical-split-browser-pane"
            | "canonical-split-pane"
            | "canonical-split-tab"
            | "canonical-close-pane"
            | "canonical-close-workspace"
            | "canonical-rename-workspace"
            | "canonical-rename-surface"
            | "canonical-move-tab"
            | "canonical-reorder-tabs"
            | "canonical-reorder-workspaces"
            | "canonical-move-tab-to-new-workspace"
            | "canonical-set-split-ratio"
            | "close-surface"
            | "close-pane"
            | "close-screen"
            | "close-workspace"
            | "claim-projection-state"
            | "update-projection-state"
            | "update-projection-states"
            | "release-projection-state"
            | "list-projection-states"
            | "terminal-accessibility-snapshot"
            | "terminal-accessibility-activate-link"
            | "terminal-link-at-cell"
            | "acquire-terminal-control"
            | "acquire-terminal-lease"
            | "renew-terminal-lease"
            | "release-terminal-control"
            | "release-terminal-lease"
            | "transfer-terminal-lease"
            | "grant-terminal-input-delegation"
            | "revoke-terminal-input-delegation"
            | "terminal-input"
            | "terminal-delegated-input"
            | "terminal-geometry"
            | "terminal-request-status"
            | "claim-external-terminal"
            | "reset-external-terminal"
            | "external-terminal-output"
            | "drain-external-terminal-egress"
            | "acknowledge-terminal-request"
            | "terminal-activity-snapshot"
            | "mark-terminal-seen"
    );
    policy
}

/// Conservative accounting for allocations created by typed serde decoding.
/// Strings are charged twice (owned String plus downstream decode/copy), while
/// each sequence slot is charged 256 bytes so arrays of tiny JSON values cannot
/// amplify a small wire payload into a large Vec tree.
struct JsonDecodeAccount {
    used: std::cell::Cell<usize>,
    limit: usize,
}

impl JsonDecodeAccount {
    fn charge<E: de::Error>(&self, bytes: usize) -> Result<(), E> {
        let next = self
            .used
            .get()
            .checked_add(bytes)
            .ok_or_else(|| E::custom("decoded request allocation accounting overflow"))?;
        if next > self.limit {
            return Err(E::custom(format!(
                "decoded request exceeds {}-byte allocation limit",
                self.limit
            )));
        }
        self.used.set(next);
        Ok(())
    }
}

#[derive(Clone, Copy)]
struct JsonDecodeSeed<'a>(&'a JsonDecodeAccount);

impl<'de> DeserializeSeed<'de> for JsonDecodeSeed<'_> {
    type Value = ();

    fn deserialize<D>(self, deserializer: D) -> Result<(), D::Error>
    where
        D: Deserializer<'de>,
    {
        deserializer.deserialize_any(self)
    }
}

impl<'de> Visitor<'de> for JsonDecodeSeed<'_> {
    type Value = ();

    fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("bounded JSON")
    }

    fn visit_bool<E: de::Error>(self, _value: bool) -> Result<(), E> {
        self.0.charge(16)
    }

    fn visit_i64<E: de::Error>(self, _value: i64) -> Result<(), E> {
        self.0.charge(16)
    }

    fn visit_u64<E: de::Error>(self, _value: u64) -> Result<(), E> {
        self.0.charge(16)
    }

    fn visit_f64<E: de::Error>(self, _value: f64) -> Result<(), E> {
        self.0.charge(16)
    }

    fn visit_unit<E: de::Error>(self) -> Result<(), E> {
        self.0.charge(8)
    }

    fn visit_none<E: de::Error>(self) -> Result<(), E> {
        self.visit_unit()
    }

    fn visit_some<D>(self, deserializer: D) -> Result<(), D::Error>
    where
        D: Deserializer<'de>,
    {
        JsonDecodeSeed(self.0).deserialize(deserializer)
    }

    fn visit_borrowed_str<E: de::Error>(self, value: &'de str) -> Result<(), E> {
        self.0.charge(value.len().saturating_mul(2).saturating_add(32))
    }

    fn visit_str<E: de::Error>(self, value: &str) -> Result<(), E> {
        self.0.charge(value.len().saturating_mul(2).saturating_add(32))
    }

    fn visit_string<E: de::Error>(self, value: String) -> Result<(), E> {
        self.visit_str(&value)
    }

    fn visit_borrowed_bytes<E: de::Error>(self, value: &'de [u8]) -> Result<(), E> {
        self.0.charge(value.len().saturating_mul(2).saturating_add(32))
    }

    fn visit_bytes<E: de::Error>(self, value: &[u8]) -> Result<(), E> {
        self.0.charge(value.len().saturating_mul(2).saturating_add(32))
    }

    fn visit_byte_buf<E: de::Error>(self, value: Vec<u8>) -> Result<(), E> {
        self.visit_bytes(&value)
    }

    fn visit_seq<A>(self, mut sequence: A) -> Result<(), A::Error>
    where
        A: SeqAccess<'de>,
    {
        self.0.charge::<A::Error>(32)?;
        loop {
            self.0.charge::<A::Error>(256)?;
            if sequence.next_element_seed(JsonDecodeSeed(self.0))?.is_none() {
                // Undoing the final speculative slot would complicate the
                // monotonic failure path; charging one sentinel is deliberate.
                return Ok(());
            }
        }
    }

    fn visit_map<A>(self, mut map: A) -> Result<(), A::Error>
    where
        A: MapAccess<'de>,
    {
        self.0.charge::<A::Error>(32)?;
        while map.next_key_seed(JsonDecodeSeed(self.0))?.is_some() {
            self.0.charge::<A::Error>(64)?;
            map.next_value_seed(JsonDecodeSeed(self.0))?;
        }
        Ok(())
    }
}

fn account_json_decode(message: &str, limit: usize) -> anyhow::Result<usize> {
    let account = JsonDecodeAccount { used: std::cell::Cell::new(0), limit };
    let mut deserializer = serde_json::Deserializer::from_str(message);
    JsonDecodeSeed(&account)
        .deserialize(&mut deserializer)
        .map_err(|error| anyhow::anyhow!("bad request: {error}"))?;
    deserializer.end().map_err(|error| anyhow::anyhow!("bad request: {error}"))?;
    Ok(account.used.get())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BoundedLineRead {
    Eof,
    Line,
    TooLong,
    BudgetExceeded,
}

/// Read one JSON-lines frame without ever growing `line` beyond `max_bytes`.
/// An exact-limit frame is accepted; one additional byte before the delimiter
/// closes the connection.
fn read_bounded_line<R: BufRead>(
    reader: &mut R,
    line: &mut Vec<u8>,
    max_bytes: usize,
) -> std::io::Result<BoundedLineRead> {
    line.clear();
    loop {
        let available = reader.fill_buf()?;
        if available.is_empty() {
            return Ok(if line.is_empty() { BoundedLineRead::Eof } else { BoundedLineRead::Line });
        }
        if let Some(newline) = available.iter().position(|byte| *byte == b'\n') {
            let chunk = &available[..newline];
            if chunk.len() > max_bytes.saturating_sub(line.len()) {
                return Ok(BoundedLineRead::TooLong);
            }
            line.extend_from_slice(chunk);
            reader.consume(newline + 1);
            if line.last() == Some(&b'\r') {
                line.pop();
            }
            return Ok(BoundedLineRead::Line);
        }
        if available.len() > max_bytes.saturating_sub(line.len()) {
            return Ok(BoundedLineRead::TooLong);
        }
        line.extend_from_slice(available);
        let consumed = available.len();
        reader.consume(consumed);
    }
}

/// Production Unix reader. Every byte is reserved from the mux-wide inbound
/// budget before the line Vec grows, and the returned permit remains live
/// through typed decode and command execution.
fn read_budgeted_line<R: BufRead>(
    reader: &mut R,
    line: &mut Vec<u8>,
    max_bytes: usize,
    budget: &Arc<InboundBudget>,
) -> std::io::Result<(BoundedLineRead, Option<InboundPermit>)> {
    line.clear();
    let mut permit = budget.try_reserve(0).expect("zero-byte inbound reservation must succeed");
    loop {
        let available = reader.fill_buf()?;
        if available.is_empty() {
            let status = if line.is_empty() { BoundedLineRead::Eof } else { BoundedLineRead::Line };
            return Ok((status, Some(permit)));
        }
        let (chunk, consumed, complete) =
            if let Some(newline) = available.iter().position(|byte| *byte == b'\n') {
                (&available[..newline], newline + 1, true)
            } else {
                (available, available.len(), false)
            };
        if chunk.len() > max_bytes.saturating_sub(line.len()) {
            return Ok((BoundedLineRead::TooLong, Some(permit)));
        }
        if !permit.try_grow(chunk.len()) {
            return Ok((BoundedLineRead::BudgetExceeded, Some(permit)));
        }
        line.try_reserve_exact(chunk.len()).map_err(|error| {
            std::io::Error::other(format!("request buffer allocation failed: {error}"))
        })?;
        line.extend_from_slice(chunk);
        reader.consume(consumed);
        if complete {
            if line.last() == Some(&b'\r') {
                line.pop();
            }
            return Ok((BoundedLineRead::Line, Some(permit)));
        }
    }
}

#[derive(Clone)]
struct OutboundStream {
    id: u64,
    open: Arc<AtomicBool>,
    terminal_enqueued: Arc<AtomicBool>,
    overflow_text: Arc<str>,
}

impl OutboundStream {
    fn new(id: u64, overflow_text: String) -> Self {
        Self {
            id,
            open: Arc::new(AtomicBool::new(true)),
            terminal_enqueued: Arc::new(AtomicBool::new(false)),
            overflow_text: overflow_text.into(),
        }
    }

    fn is_open(&self) -> bool {
        self.open.load(Ordering::Acquire)
    }

    fn close(&self) {
        self.open.store(false, Ordering::Release);
    }
}

trait MessageSink: Send + Sync {
    fn send_initial(&self, value: &Value, stream: &OutboundStream) -> std::io::Result<()>;
    fn send_stream(&self, value: &Value, stream: &OutboundStream) -> std::io::Result<()>;
    fn send_control(&self, value: &Value) -> std::io::Result<()>;
    fn send_terminal(&self, value: &Value, stream: &OutboundStream) -> std::io::Result<()>;
    fn set_write_timeout(&self, _timeout: Option<Duration>) -> std::io::Result<()> {
        Ok(())
    }
    fn is_open(&self) -> bool;
    fn close(&self);
}

/// Transport-independent writer shared by command responses and event streams.
#[derive(Clone)]
struct MessageWriter {
    sink: Arc<dyn MessageSink>,
    open: Arc<AtomicBool>,
    next_stream_id: Arc<AtomicU64>,
}

impl MessageWriter {
    fn new(sink: impl MessageSink + 'static) -> Self {
        Self {
            sink: Arc::new(sink),
            open: Arc::new(AtomicBool::new(true)),
            next_stream_id: Arc::new(AtomicU64::new(1)),
        }
    }

    fn start_stream(&self, overflow: &Value) -> std::io::Result<OutboundStream> {
        Ok(OutboundStream::new(
            self.next_stream_id.fetch_add(1, Ordering::Relaxed),
            serde_json::to_string(overflow)?,
        ))
    }

    fn send_stream(&self, value: &Value, stream: &OutboundStream) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let result = self.sink.send_stream(value, stream);
        if result.as_ref().is_err_and(|error| error.kind() != std::io::ErrorKind::WouldBlock) {
            stream.close();
        }
        result
    }

    fn send_initial(&self, value: &Value, stream: &OutboundStream) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let result = self.sink.send_initial(value, stream);
        if result.as_ref().is_err_and(|error| error.kind() != std::io::ErrorKind::WouldBlock) {
            stream.close();
        }
        result
    }

    fn send_terminal(&self, value: &Value, stream: &OutboundStream) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let result = self.sink.send_terminal(value, stream);
        if result.is_err() {
            self.close();
        }
        result
    }

    fn send_control(&self, value: &Value) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let result = self.sink.send_control(value);
        if result.is_err() {
            self.close();
        }
        result
    }

    fn is_open(&self) -> bool {
        self.open.load(Ordering::Acquire) && self.sink.is_open()
    }

    fn set_write_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        self.sink.set_write_timeout(timeout)
    }

    fn close(&self) {
        if self.open.swap(false, Ordering::AcqRel) {
            self.sink.close();
        }
    }
}

#[derive(Default)]
struct BoundedOutbound {
    state: Mutex<BoundedOutboundState>,
    changed: Condvar,
}

#[derive(Default)]
struct BoundedOutboundState {
    initial: VecDeque<RegularOutbound>,
    control: VecDeque<String>,
    regular: VecDeque<RegularOutbound>,
    control_bytes: usize,
    regular_bytes: usize,
    closed: bool,
}

struct RegularOutbound {
    text: String,
    stream: OutboundStream,
}

struct ConnectionPermit(Arc<AtomicU64>);

impl Drop for ConnectionPermit {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}

fn claim_connection(active: &Arc<AtomicU64>) -> Option<ConnectionPermit> {
    active
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
            (count < MAX_SERVER_CONNECTIONS as u64).then_some(count + 1)
        })
        .ok()
        .map(|_| ConnectionPermit(active.clone()))
}

impl BoundedOutbound {
    fn push_regular(&self, text: String, stream: &OutboundStream) -> std::io::Result<()> {
        self.push_regular_with_priority(text, stream, false)
    }

    fn push_initial(&self, text: String, stream: &OutboundStream) -> std::io::Result<()> {
        self.push_regular_with_priority(text, stream, true)
    }

    fn push_regular_with_priority(
        &self,
        text: String,
        stream: &OutboundStream,
        initial: bool,
    ) -> std::io::Result<()> {
        let mut state = self.state.lock().unwrap();
        if state.closed {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        if !stream.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "stream closed"));
        }
        let bytes = text.len();
        if bytes > OUTBOUND_BYTE_CAPACITY {
            Self::terminate_stream_locked(&mut state, stream)?;
            self.changed.notify_one();
            return Err(std::io::Error::new(
                std::io::ErrorKind::WouldBlock,
                "outbound queue overflowed",
            ));
        }
        loop {
            let byte_full = bytes > OUTBOUND_BYTE_CAPACITY.saturating_sub(state.regular_bytes);
            let count_full = state.initial.len() + state.regular.len() >= OUTBOUND_CAPACITY;
            if !byte_full && !count_full {
                break;
            }
            let Some(victim) = Self::largest_stream(&state, byte_full) else {
                Self::terminate_stream_locked(&mut state, stream)?;
                self.changed.notify_one();
                return Err(std::io::Error::new(
                    std::io::ErrorKind::WouldBlock,
                    "outbound queue overflowed",
                ));
            };
            let incoming_terminated = victim.id == stream.id;
            Self::terminate_stream_locked(&mut state, &victim)?;
            if incoming_terminated {
                self.changed.notify_one();
                return Err(std::io::Error::new(
                    std::io::ErrorKind::WouldBlock,
                    "outbound queue overflowed",
                ));
            }
        }
        state.regular_bytes += bytes;
        let message = RegularOutbound { text, stream: stream.clone() };
        if initial {
            state.initial.push_back(message);
        } else {
            state.regular.push_back(message);
        }
        self.changed.notify_one();
        Ok(())
    }

    fn push_control(&self, text: String) -> std::io::Result<()> {
        let mut state = self.state.lock().unwrap();
        Self::push_control_locked(&mut state, text)?;
        self.changed.notify_one();
        Ok(())
    }

    fn push_terminal(&self, text: String, stream: &OutboundStream) -> std::io::Result<()> {
        let mut state = self.state.lock().unwrap();
        stream.close();
        Self::purge_stream_locked(&mut state, stream.id);
        if stream.terminal_enqueued.swap(true, Ordering::AcqRel) {
            return Ok(());
        }
        Self::push_control_locked(&mut state, text)?;
        self.changed.notify_one();
        Ok(())
    }

    fn terminate_stream_locked(
        state: &mut BoundedOutboundState,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        stream.close();
        Self::purge_stream_locked(state, stream.id);
        if stream.terminal_enqueued.swap(true, Ordering::AcqRel) {
            return Ok(());
        }
        if let Err(error) = Self::push_control_locked(state, stream.overflow_text.to_string()) {
            state.closed = true;
            return Err(std::io::Error::new(
                std::io::ErrorKind::BrokenPipe,
                format!("could not report stream overflow: {error}"),
            ));
        }
        Ok(())
    }

    fn purge_stream_locked(state: &mut BoundedOutboundState, stream_id: u64) {
        let mut removed_bytes = 0;
        state.initial.retain(|message| {
            if message.stream.id == stream_id {
                removed_bytes += message.text.len();
                false
            } else {
                true
            }
        });
        state.regular.retain(|message| {
            if message.stream.id == stream_id {
                removed_bytes += message.text.len();
                false
            } else {
                true
            }
        });
        state.regular_bytes -= removed_bytes;
    }

    fn largest_stream(state: &BoundedOutboundState, by_bytes: bool) -> Option<OutboundStream> {
        let mut usage = HashMap::<u64, (usize, usize, OutboundStream)>::new();
        for message in state.initial.iter().chain(&state.regular) {
            let entry =
                usage.entry(message.stream.id).or_insert_with(|| (0, 0, message.stream.clone()));
            entry.0 += 1;
            entry.1 += message.text.len();
        }
        usage
            .into_values()
            .max_by_key(|(messages, bytes, _)| if by_bytes { *bytes } else { *messages })
            .map(|(_, _, stream)| stream)
    }

    fn push_control_locked(state: &mut BoundedOutboundState, text: String) -> std::io::Result<()> {
        if state.closed {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let bytes = text.len();
        if state.control.len() >= OUTBOUND_CONTROL_RESERVE
            || bytes > OUTBOUND_CONTROL_BYTE_RESERVE.saturating_sub(state.control_bytes)
        {
            return Err(std::io::Error::new(
                std::io::ErrorKind::WouldBlock,
                "outbound control reserve overflowed",
            ));
        }
        state.control_bytes += bytes;
        state.control.push_back(text);
        Ok(())
    }

    #[cfg(test)]
    fn try_pop(&self) -> Option<String> {
        let mut state = self.state.lock().unwrap();
        Self::pop_locked(&mut state)
    }

    fn recv(&self) -> Option<String> {
        let mut state = self.state.lock().unwrap();
        loop {
            if let Some(text) = Self::pop_locked(&mut state) {
                return Some(text);
            }
            if state.closed {
                return None;
            }
            state = self.changed.wait(state).unwrap();
        }
    }

    fn pop_locked(state: &mut BoundedOutboundState) -> Option<String> {
        if let Some(message) = state.initial.pop_front() {
            state.regular_bytes -= message.text.len();
            return Some(message.text);
        }
        if let Some(text) = state.control.pop_front() {
            state.control_bytes -= text.len();
            return Some(text);
        }
        let message = state.regular.pop_front()?;
        state.regular_bytes -= message.text.len();
        Some(message.text)
    }

    fn is_open(&self) -> bool {
        !self.state.lock().unwrap().closed
    }

    fn close(&self) {
        self.state.lock().unwrap().closed = true;
        self.changed.notify_all();
    }
}

struct QueuedSink {
    outbound: Arc<BoundedOutbound>,
    control: Option<SinkControl>,
}

enum SinkControl {
    Unix(Box<dyn transport::Stream>),
    WebSocket(TcpStream),
}

/// Cloned TCP streams share one write boundary so independent Tungstenite
/// reader and writer contexts cannot interleave frame bytes. Reads remain
/// fully blocking and are interrupted by shutting down a clone.
struct SynchronizedTcpStream {
    stream: TcpStream,
    write_lock: Arc<Mutex<()>>,
}

impl SynchronizedTcpStream {
    fn new(stream: TcpStream) -> Self {
        Self { stream, write_lock: Arc::new(Mutex::new(())) }
    }

    fn try_clone(&self) -> std::io::Result<Self> {
        Ok(Self { stream: self.stream.try_clone()?, write_lock: self.write_lock.clone() })
    }

    fn try_clone_raw(&self) -> std::io::Result<TcpStream> {
        self.stream.try_clone()
    }

    fn set_read_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        self.stream.set_read_timeout(timeout)
    }

    fn set_write_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        self.stream.set_write_timeout(timeout)
    }

    fn wait_readable(&self) -> std::io::Result<()> {
        let mut byte = [0_u8; 1];
        self.stream.peek(&mut byte).map(|_| ())
    }
}

impl Read for SynchronizedTcpStream {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.stream.read(buf)
    }
}

impl Write for SynchronizedTcpStream {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let _guard = self.write_lock.lock().unwrap();
        self.stream.write_all(buf)?;
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        let _guard = self.write_lock.lock().unwrap();
        self.stream.flush()
    }
}

impl SinkControl {
    fn set_write_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        match self {
            Self::Unix(stream) => stream.set_write_timeout(timeout),
            Self::WebSocket(stream) => stream.set_write_timeout(timeout),
        }
    }
}

impl MessageSink for QueuedSink {
    fn send_initial(&self, value: &Value, stream: &OutboundStream) -> std::io::Result<()> {
        let text = serde_json::to_string(value)?;
        self.outbound.push_initial(text, stream)
    }

    fn send_stream(&self, value: &Value, stream: &OutboundStream) -> std::io::Result<()> {
        let text = serde_json::to_string(value)?;
        self.outbound.push_regular(text, stream)
    }

    fn send_control(&self, value: &Value) -> std::io::Result<()> {
        let text = serde_json::to_string(value)?;
        self.outbound.push_control(text)
    }

    fn send_terminal(&self, value: &Value, stream: &OutboundStream) -> std::io::Result<()> {
        let text = serde_json::to_string(value)?;
        self.outbound.push_terminal(text, stream)
    }

    fn is_open(&self) -> bool {
        self.outbound.is_open()
    }

    fn set_write_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        self.control.as_ref().map_or(Ok(()), |control| control.set_write_timeout(timeout))
    }

    fn close(&self) {
        self.outbound.close();
    }
}

/// First-attach announcement payload: (transport, name, kind).
type ClientAnnouncement = (String, Option<String>, Option<String>);
/// Size-report update payload: (changed, name, kind, previous size).
pub(crate) type ClientSizeUpdate = (bool, Option<String>, Option<String>, Option<(u16, u16)>);

#[derive(Clone, Copy)]
enum ClientTransport {
    Unix,
    WebSocket,
}

impl ClientTransport {
    fn as_str(self) -> &'static str {
        match self {
            Self::Unix => "unix",
            Self::WebSocket => "ws",
        }
    }
}

#[derive(Default)]
struct AttachedSurface {
    streams: BTreeMap<u64, OutboundStream>,
    size: Option<(u16, u16)>,
}

struct ClientRecord {
    transport: ClientTransport,
    authorization: ConnectionAuthorization,
    connection_id: uuid::Uuid,
    connected_at: Instant,
    protocol: u32,
    client_uuid: Option<uuid::Uuid>,
    process_instance_uuid: Option<uuid::Uuid>,
    name: Option<String>,
    kind: Option<String>,
    attached: BTreeMap<SurfaceId, AttachedSurface>,
    announced_attached: bool,
    topology_subscribed: bool,
    writer: MessageWriter,
}

struct ClientRegistration {
    protocol: u32,
    connection_id: uuid::Uuid,
    role: ConnectionRole,
    kind: Option<RegisteredClientKind>,
    topology_lease: Option<TopologyMutationLease>,
}

pub(crate) struct ClientRegistry {
    next_id: AtomicU64,
    lifecycle: RwLock<()>,
    clients: Mutex<BTreeMap<u64, ClientRecord>>,
    active_topology_streams: Arc<AtomicU64>,
    inbound_budget: Arc<InboundBudget>,
}

impl ClientRegistry {
    pub(crate) fn new() -> Self {
        Self {
            next_id: AtomicU64::new(1),
            lifecycle: RwLock::new(()),
            clients: Mutex::new(BTreeMap::new()),
            active_topology_streams: Arc::new(AtomicU64::new(0)),
            inbound_budget: InboundBudget::new(INBOUND_INFLIGHT_MAX_BYTES),
        }
    }

    fn inbound_budget(&self) -> Arc<InboundBudget> {
        self.inbound_budget.clone()
    }

    fn admission_state(
        &self,
        client: u64,
    ) -> anyhow::Result<(ClientTransport, u32, bool, ConnectionRole)> {
        self.clients
            .lock()
            .unwrap()
            .get(&client)
            .map(|record| {
                (
                    record.transport,
                    record.protocol,
                    record.client_uuid.is_some(),
                    record.authorization.role(),
                )
            })
            .ok_or_else(|| anyhow::anyhow!("unknown client {client}"))
    }

    fn register_with_authorization(
        &self,
        transport: ClientTransport,
        authorization: ConnectionAuthorization,
        writer: MessageWriter,
    ) -> u64 {
        let client = self.next_id.fetch_add(1, Ordering::Relaxed);
        self.clients.lock().unwrap().insert(
            client,
            ClientRecord {
                transport,
                authorization,
                connection_id: uuid::Uuid::new_v4(),
                connected_at: Instant::now(),
                protocol: PROTOCOL_VERSION,
                client_uuid: None,
                process_instance_uuid: None,
                name: None,
                kind: None,
                attached: BTreeMap::new(),
                announced_attached: false,
                topology_subscribed: false,
                writer,
            },
        );
        client
    }

    fn register_unix(
        &self,
        peer_credentials: Option<transport::PeerCredentials>,
        writer: MessageWriter,
    ) -> u64 {
        self.register_with_authorization(
            ClientTransport::Unix,
            ConnectionAuthorization::unix(peer_credentials),
            writer,
        )
    }

    fn register_websocket(&self, writer: MessageWriter) -> u64 {
        self.register_with_authorization(
            ClientTransport::WebSocket,
            ConnectionAuthorization::websocket(),
            writer,
        )
    }

    #[cfg(test)]
    fn register(&self, transport: ClientTransport, writer: MessageWriter) -> u64 {
        let authorization = match transport {
            ClientTransport::Unix => {
                ConnectionAuthorization::unix(platform::effective_user_id().map(|user_id| {
                    transport::PeerCredentials {
                        process_id: Some(std::process::id()),
                        user_id,
                        group_id: 1,
                    }
                }))
            }
            ClientTransport::WebSocket => ConnectionAuthorization::websocket(),
        };
        self.register_with_authorization(transport, authorization, writer)
    }

    fn lock_lifecycle(&self) -> std::sync::RwLockWriteGuard<'_, ()> {
        self.lifecycle.write().unwrap()
    }

    fn read_lifecycle(&self) -> std::sync::RwLockReadGuard<'_, ()> {
        self.lifecycle.read().unwrap()
    }

    fn register_protocol(
        &self,
        client: u64,
        protocol_min: u32,
        protocol_max: u32,
        client_uuid: uuid::Uuid,
        process_instance_uuid: uuid::Uuid,
        client_kind: Option<&str>,
    ) -> anyhow::Result<ClientRegistration> {
        if protocol_min > protocol_max {
            anyhow::bail!("bad request: protocol_min exceeds protocol_max");
        }
        if client_uuid.is_nil() || process_instance_uuid.is_nil() {
            anyhow::bail!("bad request: client identities must be non-nil UUIDs");
        }
        let common_min = protocol_min.max(PROTOCOL_MIN_VERSION);
        let common_max = protocol_max.min(PROTOCOL_MAX_VERSION);
        if common_min > common_max {
            anyhow::bail!(
                "no compatible protocol version (client {protocol_min}..={protocol_max}, server {PROTOCOL_MIN_VERSION}..={PROTOCOL_MAX_VERSION})"
            );
        }
        let mut clients = self.clients.lock().unwrap();
        let record =
            clients.get_mut(&client).ok_or_else(|| anyhow::anyhow!("unknown client {client}"))?;
        if record.client_uuid.is_some() {
            anyhow::bail!("connection already registered");
        }
        record.authorization.register(common_max, client_kind)?;
        record.protocol = common_max;
        record.client_uuid = Some(client_uuid);
        record.process_instance_uuid = Some(process_instance_uuid);
        Ok(ClientRegistration {
            protocol: record.protocol,
            connection_id: record.connection_id,
            role: record.authorization.role(),
            kind: record.authorization.registered_kind(),
            topology_lease: record.authorization.topology_lease(),
        })
    }

    fn protocol_identity(
        &self,
        client: u64,
        minimum: u32,
    ) -> anyhow::Result<(uuid::Uuid, uuid::Uuid, uuid::Uuid)> {
        let clients = self.clients.lock().unwrap();
        let record =
            clients.get(&client).ok_or_else(|| anyhow::anyhow!("unknown client {client}"))?;
        if record.protocol < minimum {
            anyhow::bail!("command requires negotiated protocol v{minimum}");
        }
        let client_uuid = record
            .client_uuid
            .ok_or_else(|| anyhow::anyhow!("command requires register-client"))?;
        let process_instance_uuid = record
            .process_instance_uuid
            .ok_or_else(|| anyhow::anyhow!("command requires register-client"))?;
        Ok((client_uuid, process_instance_uuid, record.connection_id))
    }

    fn stable_reader_uuid(&self, client: u64) -> Option<uuid::Uuid> {
        self.clients
            .lock()
            .unwrap()
            .get(&client)
            .and_then(|record| (record.protocol >= 9).then_some(record.client_uuid).flatten())
    }

    /// Resolves a stable v9 client UUID to one exact live connection claim.
    /// Duplicate logical clients fail closed so a stale process cannot receive
    /// a transferred lease or automation delegation.
    fn unique_connection_claim(
        &self,
        client_uuid: uuid::Uuid,
    ) -> anyhow::Result<TerminalConnectionClaim> {
        let clients = self.clients.lock().unwrap();
        let mut matches = clients.iter().filter_map(|(connection, record)| {
            (record.protocol >= 9 && record.client_uuid == Some(client_uuid)).then(|| {
                TerminalConnectionClaim {
                    connection: *connection,
                    client_uuid,
                    process_instance_uuid: record
                        .process_instance_uuid
                        .expect("registered v9 client has process identity"),
                }
            })
        });
        let claim = matches
            .next()
            .ok_or_else(|| anyhow::anyhow!("delegate client {client_uuid} has no live v9 claim"))?;
        if matches.next().is_some() {
            anyhow::bail!("delegate client {client_uuid} has multiple live v9 claims");
        }
        Ok(claim)
    }

    pub(crate) fn negotiated_protocol(&self, client: u64) -> anyhow::Result<u32> {
        self.clients
            .lock()
            .unwrap()
            .get(&client)
            .map(|record| record.protocol)
            .ok_or_else(|| anyhow::anyhow!("unknown client {client}"))
    }

    fn connection_id(&self, client: u64) -> Option<uuid::Uuid> {
        self.clients.lock().unwrap().get(&client).map(|record| record.connection_id)
    }

    fn has_permission(&self, client: u64, permission: ConnectionPermission) -> bool {
        self.clients
            .lock()
            .unwrap()
            .get(&client)
            .is_some_and(|record| record.authorization.role().permits(permission))
    }

    fn require_topology_mutation(
        &self,
        client: u64,
        claim: TopologyMutationLeaseClaim,
    ) -> anyhow::Result<()> {
        let clients = self.clients.lock().unwrap();
        let record =
            clients.get(&client).ok_or_else(|| anyhow::anyhow!("unknown client {client}"))?;
        record.authorization.require_topology_mutation(claim)
    }

    fn set_info(
        &self,
        client: u64,
        name: Option<String>,
        kind: Option<String>,
    ) -> anyhow::Result<(Option<String>, Option<String>)> {
        let mut clients = self.clients.lock().unwrap();
        let record =
            clients.get_mut(&client).ok_or_else(|| anyhow::anyhow!("unknown client {client}"))?;
        if let Some(name) = name {
            record.name = Some(clamp_client_label(name));
        }
        if let Some(kind) = kind {
            record.kind = Some(clamp_client_label(kind));
        }
        Ok((record.name.clone(), record.kind.clone()))
    }

    pub(crate) fn list_json(&self, requesting_client: u64) -> Value {
        let clients = self.clients.lock().unwrap();
        json!(
            clients
                .iter()
                .map(|(client, record)| {
                    json!({
                        "client": client,
                        "connection_id": record.connection_id,
                        "transport": record.transport.as_str(),
                        "protocol": record.protocol,
                        "client_uuid": record.client_uuid,
                        "process_instance_uuid": record.process_instance_uuid,
                        "registered_kind": record.authorization.registered_kind().map(|kind| kind.as_str()),
                        "role": record.authorization.role().as_str(),
                        "peer_pid": record.authorization.peer_credentials().and_then(|peer| peer.process_id),
                        "peer_uid": record.authorization.peer_credentials().map(|peer| peer.user_id),
                        "name": record.name,
                        "kind": record.kind,
                        "connected_seconds": record.connected_at.elapsed().as_secs(),
                        "attached": record.attached.keys().copied().collect::<Vec<_>>(),
                        "sizes": record.attached.iter().map(|(surface, attached)| {
                            match attached.size {
                                Some((cols, rows)) => json!({
                                    "surface": surface,
                                    "cols": cols,
                                    "rows": rows,
                                }),
                                None => json!({
                                    "surface": surface,
                                    "cols": null,
                                    "rows": null,
                                }),
                            }
                        }).collect::<Vec<_>>(),
                        "self": *client == requesting_client,
                    })
                })
                .collect::<Vec<_>>()
        )
    }

    fn attach_surface(
        &self,
        client: u64,
        surface: SurfaceId,
        stream: OutboundStream,
    ) -> anyhow::Result<Option<ClientAnnouncement>> {
        let mut clients = self.clients.lock().unwrap();
        let record =
            clients.get_mut(&client).ok_or_else(|| anyhow::anyhow!("unknown client {client}"))?;
        record.attached.entry(surface).or_default().streams.insert(stream.id, stream);
        if record.announced_attached {
            return Ok(None);
        }
        record.announced_attached = true;
        Ok(Some((record.transport.as_str().to_string(), record.name.clone(), record.kind.clone())))
    }

    fn detach_surface(&self, client: u64, surface: SurfaceId, stream: u64) -> bool {
        let mut clients = self.clients.lock().unwrap();
        let Some(record) = clients.get_mut(&client) else { return false };
        let Some(attached) = record.attached.get_mut(&surface) else { return false };
        attached.streams.remove(&stream);
        if attached.streams.is_empty() {
            record.attached.remove(&surface);
            return true;
        }
        false
    }

    pub(crate) fn record_size(
        &self,
        client: u64,
        surface: SurfaceId,
        cols: u16,
        rows: u16,
    ) -> anyhow::Result<Option<ClientSizeUpdate>> {
        let mut clients = self.clients.lock().unwrap();
        let record =
            clients.get_mut(&client).ok_or_else(|| anyhow::anyhow!("unknown client {client}"))?;
        let Some(attached) = record.attached.get_mut(&surface) else { return Ok(None) };
        let previous = attached.size;
        let changed = previous != Some((cols, rows));
        attached.size = Some((cols, rows));
        Ok(Some((changed, record.name.clone(), record.kind.clone(), previous)))
    }

    pub(crate) fn restore_size(&self, client: u64, surface: SurfaceId, size: Option<(u16, u16)>) {
        if let Some(attached) = self
            .clients
            .lock()
            .unwrap()
            .get_mut(&client)
            .and_then(|record| record.attached.get_mut(&surface))
        {
            attached.size = size;
        }
    }

    fn clear_size(
        &self,
        client: u64,
        surface: SurfaceId,
    ) -> Option<(bool, Option<String>, Option<String>)> {
        let mut clients = self.clients.lock().unwrap();
        let record = clients.get_mut(&client)?;
        let attached = record.attached.get_mut(&surface)?;
        let changed = attached.size.take().is_some();
        Some((changed, record.name.clone(), record.kind.clone()))
    }

    pub(crate) fn clear_surface_sizes(&self, surface: SurfaceId) -> Vec<u64> {
        let mut clients = self.clients.lock().unwrap();
        let mut changed = Vec::new();
        for (client, record) in clients.iter_mut() {
            if record
                .attached
                .get_mut(&surface)
                .is_some_and(|attached| attached.size.take().is_some())
            {
                changed.push(*client);
            }
        }
        changed
    }

    fn remove(&self, client: u64) -> Option<ClientRecord> {
        self.clients.lock().unwrap().remove(&client)
    }

    pub(crate) fn contains(&self, client: u64) -> bool {
        self.clients.lock().unwrap().contains_key(&client)
    }

    fn claim_topology_stream(&self, client: u64) -> anyhow::Result<TopologyStreamPermit> {
        let mut clients = self.clients.lock().unwrap();
        let record =
            clients.get_mut(&client).ok_or_else(|| anyhow::anyhow!("unknown client {client}"))?;
        if record.topology_subscribed {
            anyhow::bail!("connection already has a topology subscription");
        }
        self.active_topology_streams
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
                (count < MAX_TOPOLOGY_STREAMS).then_some(count + 1)
            })
            .map_err(|_| anyhow::anyhow!("topology subscription limit reached"))?;
        record.topology_subscribed = true;
        Ok(TopologyStreamPermit(self.active_topology_streams.clone()))
    }

    fn cancel_topology_claim(&self, client: u64) {
        if let Some(record) = self.clients.lock().unwrap().get_mut(&client) {
            record.topology_subscribed = false;
        }
    }

    #[cfg(test)]
    fn active_topology_streams(&self) -> u64 {
        self.active_topology_streams.load(Ordering::Acquire)
    }

    pub(crate) fn client_ids(&self) -> HashSet<u64> {
        self.clients.lock().unwrap().keys().copied().collect()
    }

    pub(crate) fn client_info(&self, client: u64) -> Option<(Option<String>, Option<String>)> {
        self.clients
            .lock()
            .unwrap()
            .get(&client)
            .map(|record| (record.name.clone(), record.kind.clone()))
    }

    pub(crate) fn attached_client_ids(&self) -> HashSet<u64> {
        self.clients
            .lock()
            .unwrap()
            .iter()
            .filter_map(|(client, record)| (!record.attached.is_empty()).then_some(*client))
            .collect()
    }
}

struct TopologyStreamPermit(Arc<AtomicU64>);

impl Drop for TopologyStreamPermit {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}

fn clamp_client_label(value: String) -> String {
    sanitize_window_title(&value).chars().take(64).collect()
}

/// Bind the socket and serve connections on background threads.
pub fn serve(mux: Arc<Mux>, path: Option<PathBuf>) -> anyhow::Result<PathBuf> {
    let path = path.unwrap_or_else(|| default_socket_path(&mux.session));
    prepare_socket_path(&path)?;
    let listener = transport::listen(&path)?;
    platform::restrict_file(&path)?;
    let active_connections = Arc::new(AtomicU64::new(0));

    std::thread::Builder::new().name("mux-server".into()).spawn(move || {
        loop {
            let Ok(stream) = listener.accept() else { continue };
            let Some(permit) = claim_connection(&active_connections) else { continue };
            let mux = mux.clone();
            let _ = std::thread::Builder::new().name("mux-conn".into()).spawn(move || {
                let _permit = permit;
                handle_connection(mux, stream);
            });
        }
    })?;
    Ok(path)
}

fn prepare_socket_path(path: &Path) -> anyhow::Result<()> {
    let directory = path
        .parent()
        .filter(|directory| !directory.as_os_str().is_empty())
        .ok_or_else(|| anyhow::anyhow!("socket path must have a dedicated parent directory"))?;
    platform::ensure_private_directory(directory)?;

    // Refuse symlinks and ordinary files. Only an unreachable Unix socket in
    // the already validated private directory is eligible for stale cleanup.
    match std::fs::symlink_metadata(path) {
        Ok(metadata) => {
            if metadata.file_type().is_symlink() {
                anyhow::bail!("refusing socket symbolic link: {}", path.display());
            }
            #[cfg(unix)]
            {
                use std::os::unix::fs::FileTypeExt;

                if !metadata.file_type().is_socket() {
                    anyhow::bail!("refusing non-socket path: {}", path.display());
                }
            }
            #[cfg(not(unix))]
            if !metadata.is_file() {
                anyhow::bail!("refusing non-file socket path: {}", path.display());
            }

            // Refuse to clobber a live endpoint; remove only a stale endpoint
            // whose type was checked without following links above.
            match transport::connect(path) {
                Ok(_) => anyhow::bail!(
                    "session socket {} is already in use (another instance running?)",
                    path.display()
                ),
                Err(_) => std::fs::remove_file(path)?,
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    Ok(())
}

/// A running opt-in WebSocket listener. Dropping it stops accepts and closes clients.
pub struct WebSocketServer {
    local_addr: SocketAddr,
    shutdown: Arc<AtomicBool>,
    connections: Arc<Mutex<HashMap<u64, TcpStream>>>,
    thread: Option<JoinHandle<()>>,
}

impl WebSocketServer {
    pub fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }
}

impl Drop for WebSocketServer {
    fn drop(&mut self) {
        self.shutdown.store(true, Ordering::Release);
        for stream in self.connections.lock().unwrap().values() {
            let _ = stream.shutdown(Shutdown::Both);
        }
        if let Ok(stream) = TcpStream::connect(self.local_addr) {
            let _ = stream.set_nodelay(true);
        }
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// Bind an opt-in WebSocket listener using one JSON message per text frame.
pub fn serve_websocket(
    mux: Arc<Mux>,
    addr: SocketAddr,
    token: Option<String>,
    allow_insecure_bind: bool,
) -> anyhow::Result<WebSocketServer> {
    // WebSocket has no TLS here. Remote deployments must explicitly opt in and
    // should put cmux-tui behind a TLS-terminating reverse proxy.
    if !addr.ip().is_loopback() && !allow_insecure_bind {
        anyhow::bail!("refusing non-loopback WebSocket bind {addr} without --ws-insecure-bind");
    }
    let token = token.filter(|value| !value.trim().is_empty());
    if let Some(token_value) = token.as_ref() {
        let auth_message_bytes =
            serde_json::to_vec(&json!({"auth": {"token": token_value}}))?.len();
        if auth_message_bytes > WEBSOCKET_AUTH_MAX_BYTES {
            anyhow::bail!(
                "WebSocket token produces a {auth_message_bytes}-byte auth message; maximum is {WEBSOCKET_AUTH_MAX_BYTES} bytes"
            );
        }
    }
    let listener = TcpListener::bind(addr)?;
    let local_addr = listener.local_addr()?;
    let shutdown = Arc::new(AtomicBool::new(false));
    let connections = Arc::new(Mutex::new(HashMap::new()));
    let next_connection = Arc::new(AtomicU64::new(1));
    let active_connections = Arc::new(AtomicU64::new(0));
    let thread_shutdown = shutdown.clone();
    let thread_connections = connections.clone();
    let thread = std::thread::Builder::new().name("mux-ws-server".into()).spawn(move || {
        while !thread_shutdown.load(Ordering::Acquire) {
            let (stream, peer) = match listener.accept() {
                Ok(connection) => connection,
                Err(_) => {
                    if thread_shutdown.load(Ordering::Acquire) {
                        break;
                    }
                    // Accept errors can persist (for example, after resource exhaustion).
                    // A short backoff prevents a hot retry loop while still recovering promptly.
                    std::thread::sleep(STREAM_DISCONNECT_POLL);
                    continue;
                }
            };
            if stream.set_nodelay(true).is_err() {
                continue;
            }
            if thread_shutdown.load(Ordering::Acquire) {
                break;
            }
            let Some(permit) = claim_connection(&active_connections) else { continue };
            let id = next_connection.fetch_add(1, Ordering::Relaxed);
            if let Ok(tracked) = stream.try_clone() {
                thread_connections.lock().unwrap().insert(id, tracked);
            }
            let mux = mux.clone();
            let token = token.clone();
            let connections = thread_connections.clone();
            let cleanup_connections = thread_connections.clone();
            if std::thread::Builder::new()
                .name("mux-ws-conn".into())
                .spawn(move || {
                    let _permit = permit;
                    handle_websocket_connection(mux, stream, peer, token.as_deref());
                    connections.lock().unwrap().remove(&id);
                })
                .is_err()
            {
                cleanup_connections.lock().unwrap().remove(&id);
            }
        }
    })?;
    Ok(WebSocketServer { local_addr, shutdown, connections, thread: Some(thread) })
}

pub fn window_title_osc(title: &str) -> Vec<u8> {
    let title = sanitize_window_title(title);
    format!("\x1b]0;{title}\x07\x1b]2;{title}\x07").into_bytes()
}

fn sanitize_window_title(title: &str) -> String {
    title
        .chars()
        .map(|ch| match ch {
            '\u{00}'..='\u{1f}' | '\u{7f}' => ' ',
            _ => ch,
        })
        .collect()
}

fn handle_connection(mux: Arc<Mux>, stream: Box<dyn transport::Stream>) {
    let peer_credentials = stream.peer_credentials().ok().flatten();
    let Ok(mut write_half) = stream.try_clone_box() else { return };
    let Ok(control) = write_half.try_clone_box() else { return };
    if write_half.set_write_timeout(Some(STREAM_WRITE_TIMEOUT)).is_err() {
        return;
    }
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink {
        outbound: outbound.clone(),
        control: Some(SinkControl::Unix(control)),
    });
    let writer_outbound = outbound;
    let Ok(writer_thread) =
        std::thread::Builder::new().name("mux-line-out".into()).spawn(move || {
            while let Some(text) = writer_outbound.recv() {
                if write_half.write_all(text.as_bytes()).is_err()
                    || write_half.write_all(b"\n").is_err()
                {
                    writer_outbound.close();
                    let _ = write_half.shutdown(Shutdown::Both);
                    break;
                }
            }
            let _ = write_half.shutdown(Shutdown::Both);
        })
    else {
        writer.close();
        return;
    };
    let client = mux.control_clients.register_unix(peer_credentials, writer.clone());
    let mut reader = BufReader::new(stream);
    let inbound_budget = mux.control_clients.inbound_budget();
    loop {
        // A fresh allocation per request prevents every connection from
        // retaining its previous 4 MiB high-water capacity after the permit
        // is released.
        let mut line = Vec::new();
        let wire_permit = match read_budgeted_line(
            &mut reader,
            &mut line,
            CONTROL_MESSAGE_MAX_BYTES,
            &inbound_budget,
        ) {
            Ok((BoundedLineRead::Eof, _)) | Err(_) => break,
            Ok((BoundedLineRead::TooLong, _)) => {
                let response = Response {
                    id: None,
                    ok: false,
                    data: None,
                    error: Some(format!("request exceeds {CONTROL_MESSAGE_MAX_BYTES}-byte limit")),
                };
                if let Ok(value) = serde_json::to_value(response) {
                    let _ = writer.send_control(&value);
                }
                break;
            }
            Ok((BoundedLineRead::BudgetExceeded, _)) => {
                let response = Response {
                    id: None,
                    ok: false,
                    data: None,
                    error: Some(format!(
                        "server inbound request budget exceeds {INBOUND_INFLIGHT_MAX_BYTES} bytes"
                    )),
                };
                if let Ok(value) = serde_json::to_value(response) {
                    let _ = writer.send_control(&value);
                }
                break;
            }
            Ok((BoundedLineRead::Line, permit)) => permit,
        };
        let Ok(line) = std::str::from_utf8(&line) else { break };
        if line.trim().is_empty() {
            continue;
        }
        if !handle_message_with_permit(&mux, client, line, &writer, wire_permit) {
            break;
        }
    }
    disconnect_client(&mux, client, false);
    let _ = writer_thread.join();
}

fn handle_websocket_connection(
    mux: Arc<Mux>,
    stream: TcpStream,
    peer: SocketAddr,
    token: Option<&str>,
) {
    let stream = SynchronizedTcpStream::new(stream);
    if stream.set_read_timeout(Some(WEBSOCKET_HANDSHAKE_TIMEOUT)).is_err()
        || stream.set_write_timeout(Some(WEBSOCKET_HANDSHAKE_TIMEOUT)).is_err()
    {
        return;
    }
    let auth_config = WebSocketConfig::default()
        .read_buffer_size(4 * 1024)
        .write_buffer_size(4 * 1024)
        .max_write_buffer_size(WEBSOCKET_MESSAGE_MAX_BYTES)
        .max_message_size(Some(WEBSOCKET_AUTH_MAX_BYTES))
        .max_frame_size(Some(WEBSOCKET_AUTH_MAX_BYTES));
    let Ok(mut websocket) = accept_with_config(stream, Some(auth_config)) else { return };

    if !authenticate_websocket(&mux, &mut websocket, peer, token) {
        let frame = CloseFrame { code: CloseCode::Policy, reason: "authentication failed".into() };
        let _ = websocket.close(Some(frame));
        let _ = websocket.flush();
        return;
    }
    websocket.set_config(|config| {
        config.max_message_size = Some(WEBSOCKET_MESSAGE_MAX_BYTES);
        config.max_frame_size = Some(WEBSOCKET_MESSAGE_MAX_BYTES);
    });
    let _ = websocket.get_mut().set_read_timeout(None);
    let _ = websocket.get_mut().set_write_timeout(Some(STREAM_WRITE_TIMEOUT));
    let Ok(writer_stream) = websocket.get_ref().try_clone() else { return };
    let Ok(writer_shutdown) = writer_stream.try_clone_raw() else { return };
    let Ok(control) = writer_stream.try_clone_raw() else { return };
    let _ = writer_stream.set_write_timeout(Some(STREAM_WRITE_TIMEOUT));
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink {
        outbound: outbound.clone(),
        control: Some(SinkControl::WebSocket(control)),
    });
    let writer_outbound = outbound;
    let Ok(writer_thread) =
        std::thread::Builder::new().name("mux-ws-out".into()).spawn(move || {
            let mut websocket = WebSocket::from_raw_socket(writer_stream, Role::Server, None);
            while let Some(text) = writer_outbound.recv() {
                if websocket.send(Message::Text(text.into())).is_err() {
                    writer_outbound.close();
                    break;
                }
            }
            let _ = websocket.close(None);
            let _ = websocket.flush();
            let _ = writer_shutdown.shutdown(Shutdown::Both);
        })
    else {
        writer.close();
        return;
    };
    let client = mux.control_clients.register_websocket(writer.clone());
    let inbound_budget = mux.control_clients.inbound_budget();
    // The authentication read can leave bytes for the first control frame in
    // Tungstenite's private buffer, so the first read must be budgeted without
    // probing the raw socket. After a timed-out read proves that buffer empty,
    // a blocking peek avoids holding 4 MiB of budget for an idle connection.
    let mut probe_socket = false;

    loop {
        if !writer.is_open() {
            break;
        }

        if probe_socket {
            if websocket.get_ref().set_read_timeout(None).is_err()
                || websocket.get_ref().wait_readable().is_err()
            {
                break;
            }
            probe_socket = false;
        }
        let Some(wire_permit) = inbound_budget
            .reserve_timeout(WEBSOCKET_MESSAGE_MAX_BYTES, WEBSOCKET_BUDGETED_READ_TIMEOUT)
        else {
            continue;
        };
        if websocket.get_ref().set_read_timeout(Some(WEBSOCKET_BUDGETED_READ_TIMEOUT)).is_err() {
            break;
        }

        let incoming = websocket.read();
        match incoming {
            Ok(Message::Text(text)) => {
                let mut wire_permit = wire_permit;
                wire_permit.shrink_to(text.len());
                if !handle_message_with_permit(&mux, client, &text, &writer, Some(wire_permit)) {
                    break;
                }
            }
            Ok(Message::Ping(_)) | Ok(Message::Pong(_)) => {
                let _ = websocket.flush();
            }
            Ok(Message::Close(_)) => break,
            Ok(_) => break,
            Err(tungstenite::Error::Io(error))
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                probe_socket = true;
            }
            Err(_) => break,
        }
    }
    disconnect_client(&mux, client, false);
    let _ = writer_thread.join();
    let _ = websocket.close(None);
}

fn authenticate_websocket(
    mux: &Arc<Mux>,
    websocket: &mut WebSocket<SynchronizedTcpStream>,
    peer: SocketAddr,
    configured_token: Option<&str>,
) -> bool {
    let Some(wire_permit) = mux
        .control_clients
        .inbound_budget()
        .reserve_timeout(WEBSOCKET_AUTH_MAX_BYTES, WEBSOCKET_HANDSHAKE_TIMEOUT)
    else {
        return false;
    };
    let Ok(Message::Text(text)) = websocket.read() else { return false };
    let mut wire_permit = wire_permit;
    wire_permit.shrink_to(text.len());
    let Ok(_inbound_permit) = preflight_authentication_message(&text, wire_permit) else {
        return false;
    };
    if let Some(provided) = auth_token(&text) {
        return configured_token
            .is_some_and(|expected| constant_time_eq(provided.as_bytes(), expected.as_bytes()))
            || mux.authenticate_pairing_credential(&provided);
    }
    if !pairing_request(&text) {
        return false;
    }

    let (challenge, decision) = match mux.begin_pairing(peer.ip()) {
        Ok(pairing) => pairing,
        Err(error) => {
            let _ = websocket.send(Message::Text(
                json!({"pairing_error": {"code": error.code(), "message": error.to_string()}})
                    .to_string()
                    .into(),
            ));
            return false;
        }
    };
    if websocket
        .send(Message::Text(
            json!({"pairing": {
                "id": challenge.id,
                "code": challenge.code,
                "peer": challenge.peer,
                "expires_in": challenge.expires_in,
            }})
            .to_string()
            .into(),
        ))
        .is_err()
    {
        mux.cancel_pairing(challenge.id);
        return false;
    }

    match decision.recv_timeout(Duration::from_secs(challenge.expires_in)) {
        Ok(PairingDecision::Approved { credential }) => websocket
            .send(Message::Text(json!({"paired": {"credential": credential}}).to_string().into()))
            .is_ok(),
        Ok(PairingDecision::Denied) | Err(_) => {
            mux.cancel_pairing(challenge.id);
            false
        }
    }
}

fn disconnect_client(mux: &Mux, client: u64, send_detached: bool) -> bool {
    let _client_lifecycle = mux.control_clients.lock_lifecycle();
    let record = {
        let _lifecycle = mux.lock_client_sizing_lifecycle();
        let Some(record) = mux.control_clients.remove(client) else { return false };
        mux.remove_size_client(client);
        record
    };
    mux.terminal_authority.revoke_connection(client);
    mux.projection_states.release_connection(record.connection_id);
    for presentation_id in mux.presentations.remove_client(client) {
        let _ = mux.remove_renderer_presentation(presentation_id);
    }
    if send_detached {
        let _ = record.writer.set_write_timeout(Some(CLIENT_DETACH_WRITE_TIMEOUT));
        for (surface, attached) in &record.attached {
            for stream in attached.streams.values() {
                let _ = record
                    .writer
                    .send_terminal(&json!({"event": "detached", "surface": surface}), stream);
            }
        }
    }
    record.writer.close();
    mux.emit(MuxEvent::ClientDetached(client));
    true
}

pub fn detach_control_client(mux: &Mux, client: u64) -> bool {
    disconnect_client(mux, client, true)
}

fn handle_message(mux: &Arc<Mux>, client: u64, message: &str, writer: &MessageWriter) -> bool {
    handle_message_with_permit(mux, client, message, writer, None)
}

fn preflight_authentication_message(
    message: &str,
    mut wire_permit: InboundPermit,
) -> anyhow::Result<InboundPermit> {
    if message.len() > WEBSOCKET_AUTH_MAX_BYTES {
        anyhow::bail!("authentication request exceeds {WEBSOCKET_AUTH_MAX_BYTES}-byte limit");
    }
    if !wire_permit.try_grow(message.len()) {
        anyhow::bail!("server inbound request budget exceeds {INBOUND_INFLIGHT_MAX_BYTES} bytes");
    }
    let decoded = account_json_decode(message, AUTH_DECODE_MAX_BYTES)?;
    if wire_permit.bytes < message.len() && !wire_permit.try_grow(message.len() - wire_permit.bytes)
    {
        anyhow::bail!("server inbound request budget exceeds {INBOUND_INFLIGHT_MAX_BYTES} bytes");
    }
    if !wire_permit.try_grow(decoded) {
        anyhow::bail!("server inbound request budget exceeds {INBOUND_INFLIGHT_MAX_BYTES} bytes");
    }
    Ok(wire_permit)
}

fn preflight_request(
    mux: &Mux,
    client: u64,
    message: &str,
    wire_permit: Option<InboundPermit>,
) -> anyhow::Result<InboundPermit> {
    let envelope: CommandEnvelope<'_> =
        serde_json::from_str(message).map_err(|error| anyhow::anyhow!("bad request: {error}"))?;
    if envelope.cmd.is_empty() || envelope.cmd.len() > COMMAND_NAME_MAX_BYTES {
        anyhow::bail!("bad request: invalid command name");
    }
    let policy = command_admission_policy(envelope.cmd);
    if message.len() > policy.wire_max {
        anyhow::bail!(
            "request for command {:?} exceeds {}-byte wire limit",
            envelope.cmd,
            policy.wire_max
        );
    }

    let (_transport, protocol, registered, role) = mux.control_clients.admission_state(client)?;
    if envelope.cmd == "register-client" && registered {
        anyhow::bail!("connection already registered");
    }
    if let Some(permission) = policy.permission {
        role.require_permission(permission, envelope.cmd)?;
    }
    if policy.protocol_v9 && (!registered || protocol < 9) {
        anyhow::bail!("command {:?} requires a registered protocol v9 capability", envelope.cmd);
    }

    let budget = mux.control_clients.inbound_budget();
    let mut permit = match wire_permit {
        Some(permit) => permit,
        None => budget.try_reserve(message.len()).ok_or_else(|| {
            anyhow::anyhow!(
                "server inbound request budget exceeds {INBOUND_INFLIGHT_MAX_BYTES} bytes"
            )
        })?,
    };
    if permit.bytes > message.len() {
        permit.shrink_to(message.len());
    }
    if permit.bytes < message.len() && !permit.try_grow(message.len() - permit.bytes) {
        anyhow::bail!("server inbound request budget exceeds {INBOUND_INFLIGHT_MAX_BYTES} bytes");
    }
    // serde_json's structural pass does not materialize a Value tree, but an
    // escaped JSON string can use a scratch buffer as large as the wire text.
    // Reserve that exact worst case before traversing untrusted structure.
    if !permit.try_grow(message.len()) {
        anyhow::bail!("server inbound request budget exceeds {INBOUND_INFLIGHT_MAX_BYTES} bytes");
    }
    let decoded = account_json_decode(message, policy.decoded_max)?;
    if !permit.try_grow(decoded) {
        anyhow::bail!("server inbound request budget exceeds {INBOUND_INFLIGHT_MAX_BYTES} bytes");
    }
    Ok(permit)
}

fn handle_message_with_permit(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
    wire_permit: Option<InboundPermit>,
) -> bool {
    let mut detach_self = false;
    let response = match preflight_request(mux, client, message, wire_permit) {
        Ok(_inbound_permit) => match serde_json::from_str::<Request>(message) {
            Ok(req) => {
                let id = req.id.clone();
                detach_self = matches!(
                    &req.cmd,
                    Command::DetachClient { client: target } if *target == client
                );
                match handle_command(mux, client, req.cmd, writer) {
                    Ok(data) => Response { id, ok: true, data: Some(data), error: None },
                    Err(e) => Response { id, ok: false, data: None, error: Some(e.to_string()) },
                }
            }
            Err(e) => Response {
                id: None,
                ok: false,
                data: None,
                error: Some(format!("bad request: {e}")),
            },
        },
        Err(error) => Response { id: None, ok: false, data: None, error: Some(error.to_string()) },
    };
    let response_ok = response.ok;
    let sent =
        serde_json::to_value(&response).is_ok_and(|value| writer.send_control(&value).is_ok());
    if detach_self && response_ok && sent {
        disconnect_client(mux, client, true);
        return false;
    }
    sent
}

fn auth_token(message: &str) -> Option<String> {
    let value: Value = serde_json::from_str(message).ok()?;
    let object = value.as_object()?;
    if object.len() != 1 {
        return None;
    }
    let auth = object.get("auth")?.as_object()?;
    if auth.len() != 1 {
        return None;
    }
    auth.get("token")?.as_str().map(str::to_string)
}

fn pairing_request(message: &str) -> bool {
    let Ok(value) = serde_json::from_str::<Value>(message) else { return false };
    let Some(object) = value.as_object() else { return false };
    if object.len() != 1 {
        return false;
    }
    let Some(pair) = object.get("pair").and_then(Value::as_object) else { return false };
    pair.len() == 1 && pair.get("request").and_then(Value::as_bool) == Some(true)
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    let mut difference = a.len() ^ b.len();
    let length = a.len().max(b.len());
    for index in 0..length {
        difference |=
            usize::from(a.get(index).copied().unwrap_or(0) ^ b.get(index).copied().unwrap_or(0));
    }
    difference == 0
}

fn node_json(node: &Node) -> Value {
    match node {
        Node::Leaf(id) => json!({ "type": "leaf", "pane": id }),
        Node::Split { dir, ratio, a, b } => json!({
            "type": "split",
            "dir": match dir { SplitDir::Right => "right", SplitDir::Down => "down" },
            "ratio": ratio,
            "a": node_json(a),
            "b": node_json(b),
        }),
    }
}

fn layout_request_to_spec(layout: LayoutRequest) -> anyhow::Result<LayoutSpec> {
    match layout {
        LayoutRequest::Leaf { cwd, command } => {
            Ok(LayoutSpec::Leaf(LayoutLeafSpec { cwd, command }))
        }
        LayoutRequest::Split { dir, ratio, a, b } => Ok(LayoutSpec::Split {
            dir: parse_split_dir(&dir)?,
            ratio,
            a: Box::new(layout_request_to_spec(*a)?),
            b: Box::new(layout_request_to_spec(*b)?),
        }),
    }
}

fn parse_split_dir(dir: &str) -> anyhow::Result<SplitDir> {
    match dir {
        "right" => Ok(SplitDir::Right),
        "down" => Ok(SplitDir::Down),
        other => anyhow::bail!("bad dir {other:?} (want \"right\" or \"down\")"),
    }
}

fn optional_surface_size(cols: Option<u16>, rows: Option<u16>) -> Option<(u16, u16)> {
    cols.zip(rows).map(|(cols, rows)| (cols.max(1), rows.max(1)))
}

fn terminal_launch_request(
    cwd: Option<String>,
    argv: Option<Vec<String>>,
    command: Option<String>,
    env: Vec<EnsureTerminalEnvironment>,
    initial_input: Option<String>,
    wait_after_command: bool,
) -> TerminalLaunchRequest {
    TerminalLaunchRequest {
        cwd,
        argv,
        command,
        env: env.into_iter().map(|entry| (entry.name, entry.value)).collect(),
        initial_input,
        wait_after_command,
    }
}

fn parse_canonical_split_edge(dir: &str) -> anyhow::Result<(SplitDir, bool)> {
    match dir {
        "left" => Ok((SplitDir::Right, true)),
        "right" => Ok((SplitDir::Right, false)),
        "up" => Ok((SplitDir::Down, true)),
        "down" => Ok((SplitDir::Down, false)),
        other => anyhow::bail!("bad dir {other:?} (want \"left\", \"right\", \"up\", or \"down\")"),
    }
}

fn canonical_mutation_receipt_json(receipt: CanonicalMutationReceipt) -> Value {
    json!({
        "request_id": receipt.request_id,
        "daemon_instance_id": receipt.daemon_instance_id,
        "session_id": receipt.session_id,
        "base_revision": receipt.base_revision,
        "revision": receipt.revision,
        "replayed": receipt.replayed,
    })
}

fn canonical_surface_placement_json(placement: CanonicalSurfacePlacement) -> Value {
    let mut value = canonical_mutation_receipt_json(placement.receipt);
    let object = value.as_object_mut().expect("receipt JSON is an object");
    object.insert("workspace".into(), json!(placement.workspace));
    object.insert("workspace_uuid".into(), json!(placement.workspace_uuid));
    object.insert("screen".into(), json!(placement.screen));
    object.insert("screen_uuid".into(), json!(placement.screen_uuid));
    object.insert("pane".into(), json!(placement.pane));
    object.insert("pane_uuid".into(), json!(placement.pane_uuid));
    object.insert("surface".into(), json!(placement.surface));
    object.insert("surface_uuid".into(), json!(placement.surface_uuid));
    value
}

fn external_terminal_owner(mux: &Mux, client: u64) -> anyhow::Result<ExternalTerminalOwner> {
    let (client_uuid, process_instance_uuid, _) =
        mux.control_clients.protocol_identity(client, 9)?;
    Ok(ExternalTerminalOwner { client_uuid, process_instance_uuid, connection_id: client })
}

fn decode_external_terminal_payload(field: &str, encoded: &str) -> anyhow::Result<Vec<u8>> {
    if encoded.len() > EXTERNAL_TERMINAL_PAYLOAD_MAX_BYTES.saturating_mul(4).div_ceil(3) + 4 {
        anyhow::bail!(
            "external terminal {field} exceeds {EXTERNAL_TERMINAL_PAYLOAD_MAX_BYTES} decoded bytes"
        );
    }
    let bytes = base64::engine::general_purpose::STANDARD.decode(encoded)?;
    if bytes.len() > EXTERNAL_TERMINAL_PAYLOAD_MAX_BYTES {
        anyhow::bail!(
            "external terminal {field} exceeds {EXTERNAL_TERMINAL_PAYLOAD_MAX_BYTES} decoded bytes"
        );
    }
    Ok(bytes)
}

fn external_terminal_claim_json(receipt: ExternalTerminalClaimReceipt) -> Value {
    json!({
        "request_id": receipt.request_id,
        "owner_generation": receipt.owner_generation,
        "required_output_generation": receipt.required_output_generation,
        "replayed": receipt.replayed,
    })
}

fn external_terminal_output_json(receipt: ExternalTerminalOutputReceipt) -> Value {
    json!({
        "request_id": receipt.request_id,
        "owner_generation": receipt.owner_generation,
        "output_generation": receipt.output_generation,
        "accepted_sequence": receipt.accepted_sequence,
        "next_sequence": receipt.next_sequence,
        "egress": base64::engine::general_purpose::STANDARD.encode(receipt.egress),
        "replayed": receipt.replayed,
    })
}

fn parse_direction(dir: &str) -> anyhow::Result<Direction> {
    match dir {
        "left" => Ok(Direction::Left),
        "right" => Ok(Direction::Right),
        "up" => Ok(Direction::Up),
        "down" => Ok(Direction::Down),
        other => anyhow::bail!("bad dir {other:?} (want \"left\", \"right\", \"up\", or \"down\")"),
    }
}

fn parse_zoom_mode(mode: Option<String>) -> anyhow::Result<ZoomMode> {
    match mode.as_deref().unwrap_or("toggle") {
        "toggle" => Ok(ZoomMode::Toggle),
        "on" => Ok(ZoomMode::On),
        "off" => Ok(ZoomMode::Off),
        other => anyhow::bail!("bad mode {other:?} (want \"toggle\", \"on\", or \"off\")"),
    }
}

fn export_layout_json(state: &State, screen_id: Option<ScreenId>) -> anyhow::Result<Value> {
    let screen = match screen_id {
        Some(id) => state
            .workspaces
            .iter()
            .flat_map(|ws| ws.screens.iter())
            .find(|screen| screen.id == id)
            .ok_or_else(|| anyhow::anyhow!("unknown screen {id}"))?,
        None => state
            .workspaces
            .get(state.active_workspace)
            .and_then(|ws| ws.active_screen_ref())
            .ok_or_else(|| anyhow::anyhow!("no active screen"))?,
    };
    let mut pane_ids = Vec::new();
    screen.root.pane_ids(&mut pane_ids);
    Ok(json!({
        "layout": node_json(&screen.root),
        "panes": pane_ids.iter().map(|pane_id| {
            let surfaces = state
                .panes
                .get(pane_id)
                .map(|pane| pane.tabs.clone())
                .unwrap_or_default();
            json!({ "pane": pane_id, "surfaces": surfaces })
        }).collect::<Vec<_>>(),
    }))
}

fn pane_json(
    state: &State,
    id: PaneId,
    short_ids: &HashMap<u64, String>,
    notifications: &HashMap<SurfaceId, SurfaceNotification>,
) -> Value {
    let Some(pane) = state.panes.get(&id) else {
        return json!({ "id": id, "dead": true });
    };
    json!({
        "id": id,
        "uuid": pane.uuid,
        "short_id": short_ids.get(&id).cloned().unwrap_or_default(),
        "name": pane.name,
        "active_tab": pane.active_tab,
        "tabs": pane.tabs.iter().map(|sid| {
            let surface = state.surfaces.get(sid);
            json!({
                "surface": sid,
                "uuid": surface.map(|surface| surface.uuid),
                "short_id": short_ids.get(sid).cloned().unwrap_or_default(),
                "kind": surface.map(|s| s.kind().as_str()).unwrap_or("pty"),
                "browser_source": surface.and_then(|s| s.browser_source().map(|source| source.as_str())),
                "browser_status": surface.and_then(|s| s.browser_status().map(|status| status.as_str())),
                "browser_error": surface.and_then(|s| s.browser_status().and_then(|status| status.error())),
                "browser_frames_stalled": surface.and_then(|s| s.browser_frames_stalled()),
                "notification": notifications.get(sid).copied().map(|n| {
                    json!({
                        "notification": n.notification,
                        "unread": n.unread,
                        "level": n.level.as_str(),
                    })
                }),
                "name": surface.and_then(|s| s.name()),
                "title": surface.map(|s| s.title()).unwrap_or_default(),
                "size": surface.map(|s| {
                    let (c, r) = s.size();
                    json!({"cols": c, "rows": r})
                }),
                "dead": surface.map(|s| s.is_dead()).unwrap_or(true),
            })
        }).collect::<Vec<_>>(),
    })
}

fn screen_json(
    state: &State,
    screen: &Screen,
    active: bool,
    short_ids: &HashMap<u64, String>,
    notifications: &HashMap<SurfaceId, SurfaceNotification>,
) -> Value {
    let mut pane_ids = Vec::new();
    screen.root.pane_ids(&mut pane_ids);
    json!({
        "id": screen.id,
        "uuid": screen.uuid,
        "short_id": short_ids.get(&screen.id).cloned().unwrap_or_default(),
        "name": screen.name,
        "active": active,
        "active_pane": screen.active_pane,
        "zoomed_pane": screen.zoomed_pane,
        "layout": node_json(&screen.root),
        "panes": pane_ids.iter().map(|id| pane_json(state, *id, short_ids, notifications)).collect::<Vec<_>>(),
    })
}

fn workspaces_json(
    state: &State,
    notifications: &HashMap<SurfaceId, SurfaceNotification>,
) -> Value {
    let ids = state
        .workspaces
        .iter()
        .flat_map(|ws| {
            let mut ids = vec![ws.id];
            for screen in &ws.screens {
                ids.push(screen.id);
                screen.root.pane_ids(&mut ids);
            }
            ids
        })
        .chain(state.surfaces.keys().copied());
    let short_ids = assign_short_ids(ids);
    json!({
        "workspaces": state.workspaces.iter().enumerate().map(|(i, ws)| {
            json!({
                "id": ws.id,
                "uuid": ws.uuid,
                "short_id": short_ids.get(&ws.id).cloned().unwrap_or_default(),
                "name": ws.name,
                "active": i == state.active_workspace,
                "screens": ws.screens.iter().enumerate().map(|(s, screen)| {
                    screen_json(state, screen, s == ws.active_screen, &short_ids, notifications)
                }).collect::<Vec<_>>(),
            })
        }).collect::<Vec<_>>(),
    })
}

pub(crate) fn tree_entity_json(
    state: &State,
    notifications: &HashMap<SurfaceId, SurfaceNotification>,
    kind: TreeDeltaKind,
    id: u64,
) -> Option<Value> {
    let tree = workspaces_json(state, notifications);
    let workspaces = tree.get("workspaces")?.as_array()?;
    match kind {
        TreeDeltaKind::WorkspaceAdded
        | TreeDeltaKind::WorkspaceClosed
        | TreeDeltaKind::WorkspaceRenamed => workspaces
            .iter()
            .find(|workspace| workspace.get("id").and_then(Value::as_u64) == Some(id))
            .cloned(),
        TreeDeltaKind::ScreenAdded | TreeDeltaKind::ScreenClosed | TreeDeltaKind::ScreenRenamed => {
            workspaces
                .iter()
                .flat_map(|workspace| {
                    workspace.get("screens").and_then(Value::as_array).into_iter().flatten()
                })
                .find(|screen| screen.get("id").and_then(Value::as_u64) == Some(id))
                .cloned()
        }
        TreeDeltaKind::PaneAdded | TreeDeltaKind::PaneClosed => workspaces
            .iter()
            .flat_map(|workspace| {
                workspace.get("screens").and_then(Value::as_array).into_iter().flatten()
            })
            .flat_map(|screen| screen.get("panes").and_then(Value::as_array).into_iter().flatten())
            .find(|pane| pane.get("id").and_then(Value::as_u64) == Some(id))
            .cloned(),
        TreeDeltaKind::TabAdded | TreeDeltaKind::TabClosed | TreeDeltaKind::TabRenamed => {
            workspaces
                .iter()
                .flat_map(|workspace| {
                    workspace.get("screens").and_then(Value::as_array).into_iter().flatten()
                })
                .flat_map(|screen| {
                    screen.get("panes").and_then(Value::as_array).into_iter().flatten()
                })
                .flat_map(|pane| pane.get("tabs").and_then(Value::as_array).into_iter().flatten())
                .find(|tab| tab.get("surface").and_then(Value::as_u64) == Some(id))
                .cloned()
        }
    }
}

fn tree_delta_json(delta: &TreeDelta) -> Value {
    let mut value = json!({
        "event": delta.kind.as_str(),
        "workspace": delta.workspace,
        "entity": delta.entity,
    });
    if let Some(screen) = delta.screen {
        value["screen"] = json!(screen);
    }
    if let Some(pane) = delta.pane {
        value["pane"] = json!(pane);
    }
    if let Some(surface) = delta.surface {
        value["surface"] = json!(surface);
    }
    if let Some(index) = delta.index {
        value["index"] = json!(index);
    }
    value
}

fn ids_json(state: &State, kind: Option<&str>) -> anyhow::Result<Value> {
    let allowed = ["workspace", "screen", "pane", "surface"];
    if let Some(kind) = kind
        && !allowed.contains(&kind)
    {
        anyhow::bail!("bad kind {kind}");
    }
    let mut raw = Vec::new();
    for ws in &state.workspaces {
        raw.push(("workspace", ws.id));
        for screen in &ws.screens {
            raw.push(("screen", screen.id));
            let mut panes = Vec::new();
            screen.root.pane_ids(&mut panes);
            for pane in panes {
                raw.push(("pane", pane));
            }
        }
    }
    raw.extend(state.surfaces.keys().copied().map(|id| ("surface", id)));
    let short_ids = assign_short_ids(raw.iter().map(|(_, id)| *id));
    Ok(json!({
        "ids": raw
            .into_iter()
            .filter(|(item_kind, _)| kind.is_none_or(|kind| kind == *item_kind))
            .map(|(kind, id)| json!({
                "kind": kind,
                "id": id,
                "short_id": short_ids.get(&id).cloned().unwrap_or_default(),
            }))
            .collect::<Vec<_>>()
    }))
}

fn get_surface(mux: &Mux, id: SurfaceId) -> anyhow::Result<Arc<crate::Surface>> {
    mux.surface(id).ok_or_else(|| anyhow::anyhow!("unknown surface {id}"))
}

fn get_surface_by_uuid(
    mux: &Mux,
    surface_uuid: SurfaceUuid,
) -> anyhow::Result<Arc<crate::Surface>> {
    let surface_id = mux
        .with_state(|state| state.surface_id_by_uuid(surface_uuid))
        .ok_or_else(|| anyhow::anyhow!("unknown terminal surface {surface_uuid}"))?;
    get_surface(mux, surface_id)
}

fn selection_adjustment(value: &str) -> anyhow::Result<SelectionAdjustment> {
    match value {
        "left" => Ok(SelectionAdjustment::Left),
        "right" => Ok(SelectionAdjustment::Right),
        "up" => Ok(SelectionAdjustment::Up),
        "down" => Ok(SelectionAdjustment::Down),
        "home" => Ok(SelectionAdjustment::Home),
        "end" => Ok(SelectionAdjustment::End),
        "page-up" => Ok(SelectionAdjustment::PageUp),
        "page-down" => Ok(SelectionAdjustment::PageDown),
        "beginning-of-line" => Ok(SelectionAdjustment::BeginningOfLine),
        "end-of-line" => Ok(SelectionAdjustment::EndOfLine),
        other => anyhow::bail!("bad request: unknown terminal selection adjustment {other:?}"),
    }
}

fn terminal_interaction_json(
    surface_uuid: SurfaceUuid,
    snapshot: &TerminalInteractionSnapshot,
) -> Value {
    let point_json = |point: ghostty_vt::SelectionPoint| {
        json!({
            "column": point.column,
            "row": point.row,
        })
    };
    let selection = snapshot.selection.as_ref().map(|selection| {
        json!({
            "has_selection": true,
            "text": selection.text,
            "range": {
                "start": point_json(selection.start),
                "end": point_json(selection.end),
                "top_left": point_json(selection.top_left),
                "bottom_right": point_json(selection.bottom_right),
                "rectangle": selection.rectangle,
            },
        })
    });
    let selection = selection.unwrap_or_else(|| {
        json!({
            "has_selection": false,
            "text": null,
            "range": null,
        })
    });
    let copy_cursor = snapshot.copy_cursor.map(point_json);
    let cursor = snapshot.cursor.map(|cursor| {
        json!({
            "column": cursor.column,
            "row": cursor.row,
            "visible": snapshot.cursor_visible,
        })
    });
    let viewport = snapshot.viewport.map(|viewport| {
        json!({
            "total_rows": viewport.total,
            "offset": viewport.offset,
            "visible_rows": viewport.len,
        })
    });
    json!({
        "surface_uuid": surface_uuid,
        "copy_mode": snapshot.copy_mode,
        "copy_cursor": copy_cursor,
        "cursor": cursor,
        "selection": selection,
        "search": {
            "active": snapshot.search.active,
            "query": snapshot.search.query,
            "selected_match": snapshot.search.selected_match,
            "total_matches": snapshot.search.total_matches,
        },
        "viewport": viewport,
        "mouse_tracking": snapshot.mouse_tracking,
    })
}

fn terminal_action_response(
    surface_uuid: SurfaceUuid,
    handled: bool,
    clipboard_text: Option<String>,
    snapshot: &TerminalInteractionSnapshot,
) -> Value {
    json!({
        "handled": handled,
        "clipboard_text": clipboard_text,
        "state": terminal_interaction_json(surface_uuid, snapshot),
    })
}

fn surface_placement_json(mux: &Mux, surface: SurfaceId) -> anyhow::Result<Value> {
    mux.with_state(|state| {
        let pane = state.pane_of(surface)?;
        let (workspace_index, screen_index) = state.screen_of(pane)?;
        let workspace = state.workspaces.get(workspace_index)?;
        let screen = workspace.screens.get(screen_index)?;
        let pane_uuid = state.panes.get(&pane)?.uuid;
        let surface_uuid = state.surface_uuid(surface)?;
        Some(json!({
            "surface": surface,
            "surface_uuid": surface_uuid,
            "pane": pane,
            "pane_uuid": pane_uuid,
            "screen": screen.id,
            "screen_uuid": screen.uuid,
            "workspace": workspace.id,
            "workspace_uuid": workspace.uuid,
        }))
    })
    .ok_or_else(|| anyhow::anyhow!("surface {surface} has no canonical topology placement"))
}

fn sidebar_plugin_status_json(status: SidebarPluginStatus) -> Value {
    let retry_after_ms = status.retry_after.map(|duration| duration.as_millis() as u64);
    json!({
        "surface": status.surface,
        "error": status.error,
        "retry_after_ms": retry_after_ms,
    })
}

fn require_pty(surface: &crate::Surface) -> anyhow::Result<()> {
    if surface.kind() == SurfaceKind::Pty {
        Ok(())
    } else {
        anyhow::bail!("browser surface does not support PTY/VT socket commands")
    }
}

fn require_browser(surface: &crate::Surface) -> anyhow::Result<()> {
    if surface.kind() == SurfaceKind::Browser {
        Ok(())
    } else {
        anyhow::bail!("PTY surface is not a browser surface")
    }
}

fn parse_notification_level(level: &str) -> anyhow::Result<NotificationLevel> {
    match level {
        "info" => Ok(NotificationLevel::Info),
        "warning" => Ok(NotificationLevel::Warning),
        "error" => Ok(NotificationLevel::Error),
        other => anyhow::bail!("bad level {other}"),
    }
}

fn parse_agent_state(state: &str) -> anyhow::Result<AgentState> {
    match state {
        "working" => Ok(AgentState::Working),
        "blocked" => Ok(AgentState::Blocked),
        "idle" => Ok(AgentState::Idle),
        "done" => Ok(AgentState::Done),
        "unknown" => Ok(AgentState::Unknown),
        other => anyhow::bail!("bad state {other}"),
    }
}

fn parse_agent_source(source: &str) -> anyhow::Result<AgentSource> {
    match source {
        "socket" => Ok(AgentSource::Socket),
        "hook" => Ok(AgentSource::Hook),
        other => anyhow::bail!("bad source {other}"),
    }
}

fn agent_json(record: &AgentRecord) -> Value {
    json!({
        "surface": record.surface,
        "state": record.state.as_str(),
        "source": record.source.as_str(),
        "session": record.session,
        "updated_at_ms": record.updated_at_ms,
    })
}

fn parse_hex_color(value: &str) -> anyhow::Result<Rgb> {
    let bytes = value.as_bytes();
    if bytes.len() != 7 || bytes[0] != b'#' {
        anyhow::bail!("bad color {value:?} (want \"#rrggbb\")");
    }
    let nibble = |b: u8| -> anyhow::Result<u8> {
        match b {
            b'0'..=b'9' => Ok(b - b'0'),
            b'a'..=b'f' => Ok(b - b'a' + 10),
            b'A'..=b'F' => Ok(b - b'A' + 10),
            _ => anyhow::bail!("bad color {value:?} (want \"#rrggbb\")"),
        }
    };
    let hex = |idx: usize| -> anyhow::Result<u8> {
        Ok((nibble(bytes[idx])? << 4) | nibble(bytes[idx + 1])?)
    };
    Ok(Rgb { r: hex(1)?, g: hex(3)?, b: hex(5)? })
}

fn color_hex(color: Option<Rgb>) -> Option<String> {
    color.map(|color| format!("#{:02x}{:02x}{:02x}", color.r, color.g, color.b))
}

fn terminal_colors_json(colors: TerminalColors) -> Value {
    let cursor_style = colors.cursor_style.map(|style| match style {
        ghostty_vt::CursorShape::Bar => "bar",
        ghostty_vt::CursorShape::Underline => "underline",
        ghostty_vt::CursorShape::Block | ghostty_vt::CursorShape::BlockHollow => "block",
    });
    let palette = colors
        .palette
        .into_iter()
        .enumerate()
        .filter_map(|(index, color)| {
            color_hex(color).map(|color| (index.to_string(), Value::String(color)))
        })
        .collect::<serde_json::Map<String, Value>>();
    json!({
        "fg": color_hex(colors.fg),
        "bg": color_hex(colors.bg),
        "cursor": color_hex(colors.cursor),
        "selection_bg": color_hex(colors.selection_bg),
        "selection_fg": color_hex(colors.selection_fg),
        "palette": palette,
        "cursor_style": cursor_style,
        "cursor_blink": colors.cursor_blink,
    })
}

fn default_colors_json(colors: DefaultColors) -> Value {
    terminal_colors_json(TerminalColors {
        fg: colors.fg,
        bg: colors.bg,
        cursor: colors.cursor,
        selection_bg: colors.selection_bg,
        selection_fg: colors.selection_fg,
        palette: colors.palette,
        cursor_style: colors.cursor_style,
        cursor_blink: colors.cursor_blink,
    })
}

fn rgb_hex(color: Rgb) -> String {
    format!("#{:02x}{:02x}{:02x}", color.r, color.g, color.b)
}

fn styled_run_json(run: &StyledRun) -> Value {
    let underline = run.underline.map(|style| match style {
        UnderlineStyle::Single => "single",
        UnderlineStyle::Double => "double",
        UnderlineStyle::Curly => "curly",
        UnderlineStyle::Dotted => "dotted",
        UnderlineStyle::Dashed => "dashed",
    });
    let mut value = json!({
        "text": run.text,
        "fg": run.fg.map(rgb_hex),
        "bg": run.bg.map(rgb_hex),
        "attrs": run.attrs,
    });
    if let Some(underline) = underline {
        value["underline"] = json!(underline);
    }
    if let Some(width_hint) = run.width_hint {
        value["width_hint"] = json!(width_hint);
    }
    value
}

fn render_rows_json(frame: &SurfaceRenderFrame, rows: impl IntoIterator<Item = u16>) -> Vec<Value> {
    rows.into_iter()
        .filter_map(|row| {
            frame.frame.row_runs(row).map(|runs| {
                json!({
                    "row": row,
                    "runs": runs.iter().map(styled_run_json).collect::<Vec<_>>(),
                })
            })
        })
        .collect()
}

fn render_cursor_json(frame: &SurfaceRenderFrame) -> Value {
    let (style, blink) = frame.frame.cursor_visual;
    let style = match style {
        ghostty_vt::CursorShape::Bar => "bar",
        ghostty_vt::CursorShape::Underline => "underline",
        ghostty_vt::CursorShape::Block | ghostty_vt::CursorShape::BlockHollow => "block",
    };
    let (x, y, visible) =
        frame.frame.cursor.map(|cursor| (cursor.x, cursor.y, true)).unwrap_or((0, 0, false));
    json!({
        "x": x,
        "y": y,
        "style": style,
        "blink": blink,
        "visible": visible,
        "color": frame.frame.cursor_color.map(rgb_hex),
    })
}

fn render_state_json(surface: SurfaceId, frame: &SurfaceRenderFrame) -> Value {
    let (cols, rows) = frame.frame.size;
    json!({
        "event": "render-state",
        "surface": surface,
        "size": { "cols": cols, "rows": rows },
        "cursor": render_cursor_json(frame),
        "default_fg": rgb_hex(frame.frame.default_colors.1),
        "default_bg": rgb_hex(frame.frame.default_colors.0),
        "scrollback_rows": frame.scrollback_rows,
        "rows": render_rows_json(frame, 0..rows),
    })
}

struct RenderClientState {
    size: (u16, u16),
    default_colors: (Rgb, Rgb),
    scrollback_rows: u32,
}

impl RenderClientState {
    fn new(frame: &SurfaceRenderFrame) -> Self {
        Self {
            size: frame.frame.size,
            default_colors: frame.frame.default_colors,
            scrollback_rows: frame.scrollback_rows,
        }
    }

    fn delta_json(&mut self, surface: SurfaceId, frame: &SurfaceRenderFrame) -> Value {
        let size_changed = self.size != frame.frame.size;
        let foreground_changed = self.default_colors.1 != frame.frame.default_colors.1;
        let background_changed = self.default_colors.0 != frame.frame.default_colors.0;
        let scrollback_changed = self.scrollback_rows != frame.scrollback_rows;
        let full = size_changed
            || foreground_changed
            || background_changed
            || frame.frame.dirty == Dirty::Full;
        let rows = if full {
            render_rows_json(frame, 0..frame.frame.size.1)
        } else {
            render_rows_json(frame, frame.frame.dirty_rows.iter().copied())
        };
        let mut value = json!({
            "event": "render-delta",
            "surface": surface,
            "cursor": render_cursor_json(frame),
            "full": full,
            "rows": rows,
        });
        if size_changed {
            value["size"] = json!({ "cols": frame.frame.size.0, "rows": frame.frame.size.1 });
        }
        if foreground_changed {
            value["default_fg"] = json!(rgb_hex(frame.frame.default_colors.1));
        }
        if background_changed {
            value["default_bg"] = json!(rgb_hex(frame.frame.default_colors.0));
        }
        if scrollback_changed {
            value["scrollback_rows"] = json!(frame.scrollback_rows);
        }
        self.size = frame.frame.size;
        self.default_colors = frame.frame.default_colors;
        self.scrollback_rows = frame.scrollback_rows;
        value
    }
}

fn browser_state_json(
    surface: SurfaceId,
    state: &crate::BrowserAttachState,
    include_frame: bool,
) -> Value {
    let mut value = json!({
        "event": "browser-state",
        "surface": surface,
        "cols": state.cols,
        "rows": state.rows,
        "url": state.url,
        "title": state.title,
        "status": state.status.as_str(),
        "error": state.status.error(),
        "frames_stalled": state.frames_stalled,
    });
    if include_frame {
        value["frame"] = match state.frame.as_ref() {
            Some(frame) => json!({
                "seq": frame.seq,
                "width": frame.css_width,
                "height": frame.css_height,
                "data": frame.data_b64,
            }),
            None => Value::Null,
        };
    }
    value
}

fn spawn_attach_notification_stream(
    mux: Arc<Mux>,
    surface_id: SurfaceId,
    writer: MessageWriter,
    lifecycle: AttachLifecycle,
    outbound_stream: OutboundStream,
) -> std::io::Result<()> {
    let events = mux.subscribe_attached_surface(surface_id);
    std::thread::Builder::new()
        .name("mux-attach-notifications".into())
        .spawn(move || {
            while writer.is_open() && outbound_stream.is_open() && !lifecycle.is_canceled() {
                let event = match events.recv_timeout(STREAM_DISCONNECT_POLL) {
                    Ok(event) => event,
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                    Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                };
                let value = match event {
                    MuxEvent::Notification(notification)
                        if notification.surface == Some(surface_id) =>
                    {
                        json!({
                            "event": "notification",
                            "notification": notification.notification,
                            "title": notification.title,
                            "body": notification.body,
                            "level": notification.level.as_str(),
                            "surface": notification.surface,
                        })
                    }
                    MuxEvent::ScrollChanged { surface, offset, at_bottom }
                        if surface == surface_id =>
                    {
                        json!({
                            "event": "scroll-changed",
                            "surface": surface,
                            "offset": offset,
                            "at_bottom": at_bottom,
                        })
                    }
                    _ => continue,
                };
                if let Err(error) = writer.send_stream(&value, &outbound_stream) {
                    handle_attach_send_error(&lifecycle, &error);
                    break;
                }
            }
            if events.overflowed() {
                lifecycle.mark_overflow();
            }
            report_attach_overflow(&writer, surface_id, &lifecycle, &outbound_stream);
        })
        .map(|_| ())
}

fn spawn_terminal_activity_stream(
    events: MuxEventReceiver,
    reader_uuid: uuid::Uuid,
    writer: MessageWriter,
    outbound_stream: OutboundStream,
) -> std::io::Result<()> {
    std::thread::Builder::new().name("mux-terminal-activity-out".into()).spawn(move || {
        while writer.is_open() && outbound_stream.is_open() {
            let event = match events.recv_timeout(STREAM_DISCONNECT_POLL) {
                Ok(event) => event,
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
            };
            let value = match event {
                MuxEvent::TerminalActivity(fact) => {
                    subscribed_event_json(&MuxEvent::TerminalActivity(fact))
                }
                MuxEvent::TerminalActivityReceipt(receipt)
                    if receipt.reader_uuid == reader_uuid =>
                {
                    subscribed_event_json(&MuxEvent::TerminalActivityReceipt(receipt))
                }
                _ => continue,
            };
            if writer.send_stream(&value, &outbound_stream).is_err() {
                break;
            }
        }
        if events.overflowed() {
            // The client recovers from a closed connection by taking a fresh
            // persisted activity snapshot. Never hide a receipt or fact gap.
            writer.close();
        }
    })?;
    Ok(())
}

fn report_attach_overflow(
    writer: &MessageWriter,
    surface_id: SurfaceId,
    lifecycle: &AttachLifecycle,
    outbound_stream: &OutboundStream,
) {
    if lifecycle.claim_overflow_report() {
        let _ = writer.send_terminal(&attach_overflow_json(surface_id), outbound_stream);
    }
}

fn handle_attach_send_error(lifecycle: &AttachLifecycle, error: &std::io::Error) {
    if error.kind() == std::io::ErrorKind::WouldBlock {
        lifecycle.mark_overflow();
    } else {
        lifecycle.cancel();
    }
}

fn mark_client_attached(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    stream: OutboundStream,
) -> anyhow::Result<()> {
    if let Some((transport, name, kind)) =
        mux.control_clients.attach_surface(client, surface, stream)?
    {
        mux.emit(MuxEvent::ClientAttached { client, transport, name, kind });
    }
    Ok(())
}

fn terminal_request_fingerprint(value: &Value) -> anyhow::Result<RequestFingerprint> {
    let encoded = serde_json::to_vec(value)?;
    let digest: [u8; 32] = Sha256::digest(encoded).into();
    Ok(RequestFingerprint(digest))
}

fn terminal_lease_reference(
    mux: &Mux,
    client: u64,
    presentation_id: PresentationId,
    presentation_generation: u64,
    lease_id: uuid::Uuid,
    lease_generation: u64,
) -> anyhow::Result<TerminalLeaseReference> {
    let (client_uuid, process_instance_uuid, _) =
        mux.control_clients.protocol_identity(client, 9)?;
    Ok(TerminalLeaseReference {
        connection: client,
        client_uuid,
        process_instance_uuid,
        presentation_id,
        presentation_generation,
        lease_id,
        lease_generation,
    })
}

fn terminal_lease_kind(value: &str) -> anyhow::Result<TerminalLeaseKind> {
    match value {
        "input" => Ok(TerminalLeaseKind::Input),
        "geometry" => Ok(TerminalLeaseKind::Geometry),
        other => anyhow::bail!("bad request: unknown terminal lease kind {other:?}"),
    }
}

fn terminal_input_scope(input: &TerminalInputPayload) -> AutomationInputScope {
    match input {
        TerminalInputPayload::Text { .. } | TerminalInputPayload::Bytes { .. } => {
            AutomationInputScope::Text
        }
        TerminalInputPayload::NamedKey { .. } | TerminalInputPayload::Key { .. } => {
            AutomationInputScope::Key
        }
        TerminalInputPayload::Mouse { .. } => AutomationInputScope::Mouse,
    }
}

fn terminal_automation_scopes(
    values: Vec<String>,
) -> anyhow::Result<BTreeSet<AutomationInputScope>> {
    let mut scopes = BTreeSet::new();
    for value in values {
        let scope = match value.as_str() {
            "text" => AutomationInputScope::Text,
            "key" => AutomationInputScope::Key,
            "mouse" => AutomationInputScope::Mouse,
            other => anyhow::bail!("bad request: unknown terminal input scope {other:?}"),
        };
        if !scopes.insert(scope) {
            anyhow::bail!("bad request: duplicate terminal input scope {value:?}");
        }
    }
    if scopes.is_empty() {
        anyhow::bail!("bad request: terminal input delegation requires at least one scope");
    }
    Ok(scopes)
}

fn terminal_input_group(
    id: Option<uuid::Uuid>,
    index: Option<u32>,
    end: Option<bool>,
) -> anyhow::Result<Option<TerminalInputGroup>> {
    match (id, index, end) {
        (None, None, None) => Ok(None),
        (Some(id), Some(index), Some(end)) if !id.is_nil() => {
            Ok(Some(TerminalInputGroup { id, index, end }))
        }
        (Some(id), Some(_), Some(_)) if id.is_nil() => {
            anyhow::bail!("bad request: terminal input_group_id must be a non-nil UUID")
        }
        _ => anyhow::bail!(
            "bad request: input_group_id, input_group_index, and input_group_end must appear together"
        ),
    }
}

fn terminal_lease_json(
    lease: crate::terminal_authority::TerminalLease,
    presentation_id: PresentationId,
    presentation_generation: u64,
) -> Value {
    let kind = match lease.kind {
        TerminalLeaseKind::Input => "input",
        TerminalLeaseKind::Geometry => "geometry",
    };
    json!({
        "kind": kind,
        "surface_uuid": lease.surface_uuid,
        "presentation_id": presentation_id,
        "presentation_generation": presentation_generation,
        "lease_id": lease.lease_id,
        "lease_generation": lease.lease_generation,
        "revocation_sequence": lease.revocation_sequence,
        "expires_at_ms": lease.expires_at_ms,
        "next_sequence": lease.next_client_sequence,
        "next_global_input_sequence": lease.next_global_input_sequence,
        "migrated_from_legacy": lease.migrated_from_legacy,
    })
}

fn terminal_receipt_json(receipt: TerminalOperationReceipt) -> Value {
    let kind = match receipt.kind {
        TerminalOperationKind::Input => "input",
        TerminalOperationKind::Geometry => "geometry",
    };
    let mut value = json!({
        "request_id": receipt.request_id,
        "kind": kind,
        "sequence": receipt.sequence,
        "ordered_input_sequence": receipt.ordered_input_sequence,
        "lease_generation": receipt.lease_generation,
        "replayed": receipt.replayed,
    });
    match receipt.outcome {
        TerminalOperationOutcome::InputApplied { encoded_bytes } => {
            value["status"] = json!("applied");
            value["encoded_bytes"] = json!(encoded_bytes);
            value["lease_revoked"] = json!(false);
        }
        TerminalOperationOutcome::GeometryApplied { cols, rows, changed } => {
            value["status"] = json!("applied");
            value["cols"] = json!(cols);
            value["rows"] = json!(rows);
            value["changed"] = json!(changed);
            value["lease_revoked"] = json!(false);
        }
        TerminalOperationOutcome::InputIndeterminate { diagnostic } => {
            value["status"] = json!("indeterminate");
            value["diagnostic"] = json!(diagnostic);
            value["lease_revoked"] = json!(true);
        }
    }
    value
}

enum PreparedTerminalInput {
    Bytes {
        bytes: Vec<u8>,
        paste: bool,
    },
    Key(KeyInput),
    Mouse {
        action: MouseAction,
        button: Option<MouseButton>,
        modifiers: u16,
        column: u16,
        row: u16,
        any_button_pressed: bool,
        click_count: u8,
        autoscroll: Option<MouseSelectionAutoscrollDirection>,
    },
}

enum TerminalInputExecutionError {
    Rejected(anyhow::Error),
    Indeterminate(std::io::Error),
}

fn prepare_terminal_input(input: TerminalInputPayload) -> anyhow::Result<PreparedTerminalInput> {
    match input {
        TerminalInputPayload::Text { text, paste } => {
            Ok(PreparedTerminalInput::Bytes { bytes: text.into_bytes(), paste })
        }
        TerminalInputPayload::Bytes { data, paste } => Ok(PreparedTerminalInput::Bytes {
            bytes: base64::engine::general_purpose::STANDARD.decode(data)?,
            paste,
        }),
        TerminalInputPayload::NamedKey { key } => {
            if key.is_empty() {
                anyhow::bail!("bad request: named terminal key must be non-empty");
            }
            if key.len() > TERMINAL_KEY_TEXT_MAX_BYTES {
                anyhow::bail!(
                    "bad request: named terminal key exceeds {TERMINAL_KEY_TEXT_MAX_BYTES} bytes"
                );
            }
            let input =
                key_input_from_chord(&key).ok_or_else(|| anyhow::anyhow!("unknown key {key}"))?;
            Ok(PreparedTerminalInput::Key(input))
        }
        TerminalInputPayload::Key {
            key,
            modifiers,
            consumed_modifiers,
            text,
            unshifted_codepoint,
            action,
        } => {
            if key > ghostty_vt::sys::GHOSTTY_KEY_PASTE {
                anyhow::bail!("bad request: unknown terminal key {key}");
            }
            if modifiers & !TERMINAL_KEY_MODIFIERS_MASK != 0
                || consumed_modifiers & !TERMINAL_KEY_MODIFIERS_MASK != 0
                || consumed_modifiers & !modifiers != 0
            {
                anyhow::bail!("bad request: invalid terminal key modifiers");
            }
            if text.len() > TERMINAL_KEY_TEXT_MAX_BYTES {
                anyhow::bail!(
                    "bad request: terminal key text exceeds {TERMINAL_KEY_TEXT_MAX_BYTES} bytes"
                );
            }
            if text.chars().any(|character| character <= '\u{1f}' || character == '\u{7f}') {
                anyhow::bail!("bad request: terminal key text contains a control character");
            }
            if unshifted_codepoint != 0 && char::from_u32(unshifted_codepoint).is_none() {
                anyhow::bail!("bad request: invalid unshifted codepoint");
            }
            let action = match action.as_deref().unwrap_or("press") {
                "press" => KeyAction::Press,
                "release" => KeyAction::Release,
                "repeat" => KeyAction::Repeat,
                other => anyhow::bail!("bad request: unknown terminal key action {other:?}"),
            };
            Ok(PreparedTerminalInput::Key(KeyInput {
                key,
                mods: Mods(modifiers),
                consumed_mods: Mods(consumed_modifiers),
                utf8: text,
                unshifted_codepoint,
                action: Some(action),
            }))
        }
        TerminalInputPayload::Mouse {
            action,
            button,
            modifiers,
            column,
            row,
            any_button_pressed,
            click_count,
            autoscroll,
        } => {
            if modifiers & !TERMINAL_KEY_MODIFIERS_MASK != 0 {
                anyhow::bail!("bad request: invalid terminal mouse modifiers");
            }
            if !(1..=3).contains(&click_count) {
                anyhow::bail!("bad request: terminal mouse click_count must be 1, 2, or 3");
            }
            let action = match action.as_str() {
                "press" => MouseAction::Press,
                "release" => MouseAction::Release,
                "motion" => MouseAction::Motion,
                other => anyhow::bail!("bad request: unknown terminal mouse action {other:?}"),
            };
            let button = match button.as_deref() {
                None => None,
                Some("left") => Some(MouseButton::Left),
                Some("right") => Some(MouseButton::Right),
                Some("middle") => Some(MouseButton::Middle),
                Some("wheel-up") => Some(MouseButton::WheelUp),
                Some("wheel-down") => Some(MouseButton::WheelDown),
                Some("wheel-left") => Some(MouseButton::WheelLeft),
                Some("wheel-right") => Some(MouseButton::WheelRight),
                Some(other) => {
                    anyhow::bail!("bad request: unknown terminal mouse button {other:?}")
                }
            };
            if action != MouseAction::Motion && button.is_none() {
                anyhow::bail!("bad request: terminal mouse press/release requires a button");
            }
            let autoscroll = match autoscroll.as_deref() {
                None => None,
                Some("up") if action == MouseAction::Motion && any_button_pressed => {
                    Some(MouseSelectionAutoscrollDirection::Up)
                }
                Some("down") if action == MouseAction::Motion && any_button_pressed => {
                    Some(MouseSelectionAutoscrollDirection::Down)
                }
                Some("up" | "down") => anyhow::bail!(
                    "bad request: terminal mouse autoscroll requires an active motion"
                ),
                Some(other) => {
                    anyhow::bail!("bad request: unknown terminal mouse autoscroll {other:?}")
                }
            };
            Ok(PreparedTerminalInput::Mouse {
                action,
                button,
                modifiers,
                column,
                row,
                any_button_pressed,
                click_count,
                autoscroll,
            })
        }
    }
}

fn execute_terminal_input(
    surface: &Arc<crate::Surface>,
    input: PreparedTerminalInput,
) -> Result<usize, TerminalInputExecutionError> {
    match input {
        PreparedTerminalInput::Bytes { bytes, paste } => {
            let result =
                if paste { surface.write_paste(&bytes) } else { surface.write_bytes(&bytes) };
            result.map(|()| bytes.len()).map_err(TerminalInputExecutionError::Indeterminate)
        }
        PreparedTerminalInput::Key(input) => {
            let mut encoder = KeyEncoder::new()
                .map_err(anyhow::Error::from)
                .map_err(TerminalInputExecutionError::Rejected)?;
            let mut encoded = Vec::new();
            surface.scroll_to_bottom().map_err(TerminalInputExecutionError::Rejected)?;
            surface
                .try_with_terminal(|terminal| {
                    encoder.sync_from_terminal(terminal);
                    encoder.encode(&input, &mut encoded)
                })
                .map_err(TerminalInputExecutionError::Rejected)?
                .map_err(anyhow::Error::from)
                .map_err(TerminalInputExecutionError::Rejected)?;
            if encoded.is_empty() {
                return Ok(0);
            }
            surface
                .write_bytes(&encoded)
                .map(|()| encoded.len())
                .map_err(TerminalInputExecutionError::Indeterminate)
        }
        PreparedTerminalInput::Mouse {
            action,
            button,
            modifiers,
            column,
            row,
            any_button_pressed,
            click_count,
            autoscroll,
        } => {
            let (cols, rows) = surface.size();
            if column >= cols || row >= rows {
                return Err(TerminalInputExecutionError::Rejected(anyhow::anyhow!(
                    "bad request: terminal mouse cell is outside the leased geometry"
                )));
            }
            let mouse_tracking = surface
                .try_with_terminal(|terminal| terminal.mouse_tracking())
                .map_err(TerminalInputExecutionError::Rejected)?;
            if !mouse_tracking {
                if matches!(button, Some(MouseButton::WheelUp | MouseButton::WheelDown)) {
                    let delta = if button == Some(MouseButton::WheelUp) { -3 } else { 3 };
                    surface.scroll_delta(delta).map_err(TerminalInputExecutionError::Rejected)?;
                    return Ok(0);
                }
                let selects = button == Some(MouseButton::Left)
                    || (action == MouseAction::Motion && any_button_pressed);
                if selects {
                    let current = surface
                        .terminal_interaction_snapshot()
                        .map_err(TerminalInputExecutionError::Rejected)?;
                    let offset = current.viewport.map_or(0, |viewport| viewport.offset);
                    let canonical_row =
                        u32::try_from(offset.saturating_add(u64::from(row))).unwrap_or(u32::MAX);
                    surface
                        .terminal_mouse_selection(
                            action,
                            ghostty_vt::SelectionPoint { column, row: canonical_row },
                            click_count,
                            autoscroll,
                        )
                        .map_err(TerminalInputExecutionError::Rejected)?;
                }
                return Ok(0);
            }
            let input = MouseInput {
                action,
                button,
                mods: Mods(modifiers),
                position: (f32::from(column) + 0.5, f32::from(row) + 0.5),
                screen_size: (u32::from(cols), u32::from(rows)),
                cell_size: (1, 1),
                any_button_pressed,
            };
            let mut encoded = Vec::new();
            let result = if action == MouseAction::Release {
                surface.encode_mouse_release(input, &mut encoded)
            } else {
                surface.encode_mouse(input, &mut encoded)
            }
            .ok_or_else(|| anyhow::anyhow!("terminal mouse encoder is busy"))
            .map_err(TerminalInputExecutionError::Rejected)?;
            result.map_err(anyhow::Error::from).map_err(TerminalInputExecutionError::Rejected)?;
            if encoded.is_empty() {
                return Ok(0);
            }
            surface
                .write_bytes(&encoded)
                .map(|()| encoded.len())
                .map_err(TerminalInputExecutionError::Indeterminate)
        }
    }
}

fn projection_claimant(mux: &Mux, client: u64) -> anyhow::Result<ProjectionClaimant> {
    let (client_uuid, process_instance_uuid, connection_id) =
        mux.control_clients.protocol_identity(client, 9)?;
    Ok(ProjectionClaimant { client_uuid, process_instance_uuid, connection_id })
}

fn projection_live_bindings(mux: &Mux) -> BTreeMap<WorkspaceUuid, BTreeSet<crate::ScreenUuid>> {
    mux.with_state(|state| {
        state
            .workspaces
            .iter()
            .map(|workspace| {
                (workspace.uuid, workspace.screens.iter().map(|screen| screen.uuid).collect())
            })
            .collect()
    })
}

const MAX_ENSURE_COMMAND_BYTES: usize = 64 * 1024;

fn ensure_terminal_request(spec: EnsureTerminalSpec) -> anyhow::Result<EnsureTerminalRequest> {
    if spec.argv.is_some() && spec.command.is_some() {
        anyhow::bail!("ensure-terminal argv and command are mutually exclusive");
    }
    let argv = match (spec.argv, spec.command) {
        (Some(argv), None) => Some(argv),
        (None, Some(command)) => {
            if command.is_empty() {
                anyhow::bail!("ensure-terminal command must be non-empty when supplied");
            }
            if command.len() > MAX_ENSURE_COMMAND_BYTES {
                anyhow::bail!("ensure-terminal command exceeds {MAX_ENSURE_COMMAND_BYTES} bytes");
            }
            Some(vec![platform::default_shell(), "-lc".to_owned(), command])
        }
        (None, None) => None,
        (Some(_), Some(_)) => unreachable!("mutual exclusion checked above"),
    };
    Ok(EnsureTerminalRequest {
        workspace_uuid: spec.workspace_uuid,
        surface_uuid: spec.surface_uuid,
        cwd: spec.cwd,
        argv,
        env: spec.env.into_iter().map(|entry| (entry.name, entry.value)).collect(),
        initial_input: spec.initial_input,
        wait_after_command: spec.wait_after_command,
        cols: spec.cols,
        rows: spec.rows,
    })
}

fn ensured_terminal_placement_json(placement: crate::mux::EnsureTerminalPlacement) -> Value {
    json!({
        "created": placement.created,
        "workspace": placement.workspace,
        "workspace_uuid": placement.workspace_uuid,
        "screen": placement.screen,
        "screen_uuid": placement.screen_uuid,
        "pane": placement.pane,
        "pane_uuid": placement.pane_uuid,
        "surface": placement.surface,
        "surface_uuid": placement.surface_uuid,
    })
}

fn handle_command(
    mux: &Arc<Mux>,
    client: u64,
    cmd: Command,
    writer: &MessageWriter,
) -> anyhow::Result<Value> {
    // Keep registration and its connection-bound lease live through the
    // entire canonical state transaction. Disconnect takes the write side.
    let topology_mutation_claim = cmd.canonical_mutation_claim();
    let _topology_client_lifecycle = if let Some(claim) = topology_mutation_claim {
        let lifecycle = mux.control_clients.read_lifecycle();
        mux.control_clients.require_topology_mutation(client, claim)?;
        Some(lifecycle)
    } else {
        None
    };

    match cmd {
        Command::Identify => {
            let (topology_revision, canonical_topology_revision) = mux.topology_revisions();
            let renderer_workers = mux.renderer_worker_statuses();
            Ok(json!({
                "app": "cmux-tui",
                "version": env!("CARGO_PKG_VERSION"),
                "build_id": crate::build_identity::BUILD_ID,
                "protocol": PROTOCOL_VERSION,
                "protocol_min": PROTOCOL_MIN_VERSION,
                "protocol_max": PROTOCOL_MAX_VERSION,
                "capabilities": PROTOCOL_CAPABILITIES,
                "session": mux.session,
                "session_id": mux.session_id,
                "daemon_instance_id": mux.daemon_instance_id,
                "topology_revision": topology_revision,
                "canonical_topology_revision": canonical_topology_revision,
                "pid": std::process::id(),
                "connection_id": mux.control_clients.connection_id(client),
                "renderer_workers": renderer_workers,
            }))
        }
        Command::Ping => {
            let (topology_revision, canonical_topology_revision) = mux.topology_revisions();
            let renderer_workers = mux.renderer_worker_statuses();
            Ok(json!({
                "ok": true,
                "version": env!("CARGO_PKG_VERSION"),
                "build_id": crate::build_identity::BUILD_ID,
                "protocol": PROTOCOL_VERSION,
                "protocol_min": PROTOCOL_MIN_VERSION,
                "protocol_max": PROTOCOL_MAX_VERSION,
                "capabilities": PROTOCOL_CAPABILITIES,
                "session": mux.session,
                "session_id": mux.session_id,
                "daemon_instance_id": mux.daemon_instance_id,
                "topology_revision": topology_revision,
                "canonical_topology_revision": canonical_topology_revision,
                "pid": std::process::id(),
                "connection_id": mux.control_clients.connection_id(client),
                "renderer_workers": renderer_workers,
            }))
        }
        Command::RegisterClient {
            protocol_min,
            protocol_max,
            client_uuid,
            process_instance_uuid,
            client_kind,
        } => {
            let registration = mux.control_clients.register_protocol(
                client,
                protocol_min,
                protocol_max,
                client_uuid,
                process_instance_uuid,
                client_kind.as_deref(),
            )?;
            Ok(json!({
                "protocol": registration.protocol,
                "connection_id": registration.connection_id,
                "client_uuid": client_uuid,
                "process_instance_uuid": process_instance_uuid,
                "client_kind": registration.kind.map(RegisteredClientKind::as_str),
                "role": registration.role.as_str(),
                "topology_lease_id": registration.topology_lease.map(|lease| lease.id),
                "topology_lease_generation": registration.topology_lease.map(|lease| lease.generation),
            }))
        }
        Command::OpenPresentation { view, zoom, scroll } => {
            let _client_lifecycle = mux.control_clients.lock_lifecycle();
            if !mux.control_clients.contains(client) {
                anyhow::bail!("unknown client {client}");
            }
            let presentation = mux.with_state(|state| -> anyhow::Result<_> {
                let (view, zoom, scroll) = normalize_presentation(state, view, zoom, scroll)?;
                mux.presentations.open(client, view, zoom, scroll)
            })?;
            // Another trusted connection can detach this client. Recheck after
            // insertion so an open racing disconnect cannot leave an orphan.
            if !mux.control_clients.contains(client) {
                mux.presentations.remove_client(client);
                anyhow::bail!("unknown client {client}");
            }
            if let Err(error) = mux.set_renderer_presentation_workspace(
                presentation.presentation_id,
                presentation.view.workspace_uuid,
            ) {
                let _ = mux.presentations.close(client, presentation.presentation_id);
                return Err(error.into());
            }
            Ok(serde_json::to_value(presentation)?)
        }
        Command::ClosePresentation { presentation_id } => {
            let _client_lifecycle = mux.control_clients.lock_lifecycle();
            if !mux.control_clients.contains(client) {
                anyhow::bail!("unknown client {client}");
            }
            mux.presentations.close(client, presentation_id)?;
            mux.terminal_authority.revoke_presentation(presentation_id);
            mux.remove_renderer_presentation(presentation_id)?;
            Ok(json!({}))
        }
        Command::ActivateTerminalPresentation { presentation_id, expected_generation } => {
            let _client_lifecycle = mux.control_clients.read_lifecycle();
            let _terminal_lifecycle = mux.read_terminal_control_lifecycle();
            let _ = mux.control_clients.protocol_identity(client, 9)?;
            let presentation = mux.presentations.get_for_client(client, presentation_id)?;
            if presentation.generation != expected_generation {
                anyhow::bail!(
                    "stale presentation generation {expected_generation}; current generation is {}",
                    presentation.generation
                );
            }
            let surface_uuid = presentation
                .view
                .surface_uuid
                .ok_or_else(|| anyhow::anyhow!("terminal presentation has no selected surface"))?;
            let surface = get_surface_by_uuid(mux, surface_uuid)?;
            require_pty(&surface)?;
            mux.terminal_authority.mark_presentation_visible(PresentationAuthority {
                connection: client,
                presentation_id,
                presentation_generation: presentation.generation,
                surface_uuid,
            })?;
            Ok(json!({
                "presentation_id": presentation_id,
                "presentation_generation": presentation.generation,
                "surface_uuid": surface_uuid,
            }))
        }
        Command::UpdatePresentation {
            presentation_id,
            expected_generation,
            view,
            zoom,
            scroll,
        } => {
            let _client_lifecycle = mux.control_clients.lock_lifecycle();
            if !mux.control_clients.contains(client) {
                anyhow::bail!("unknown client {client}");
            }
            let presentation = mux.with_state(|state| -> anyhow::Result<_> {
                let current = mux.presentations.get_for_client(client, presentation_id)?;
                if current.generation != expected_generation {
                    anyhow::bail!(
                        "stale presentation generation {expected_generation}; current generation is {}",
                        current.generation
                    );
                }
                let next_view = view.clone().unwrap_or_else(|| current.view.clone());
                let next_zoom = zoom.clone().unwrap_or_else(|| current.zoom.clone());
                let next_scroll = scroll.clone().unwrap_or_else(|| current.scroll.clone());
                let (next_view, next_zoom, next_scroll) =
                    normalize_presentation(state, next_view, next_zoom, next_scroll)?;
                mux.presentations.update(
                    client,
                    presentation_id,
                    expected_generation,
                    Some(next_view),
                    Some(next_zoom),
                    Some(next_scroll),
                )
            })?;
            if presentation.generation != expected_generation {
                mux.terminal_authority.revoke_presentation(presentation.presentation_id);
                mux.invalidate_renderer_presentation(presentation.presentation_id);
            }
            mux.set_renderer_presentation_workspace(
                presentation.presentation_id,
                presentation.view.workspace_uuid,
            )?;
            Ok(serde_json::to_value(presentation)?)
        }
        Command::ListPresentations => {
            if !mux.control_clients.contains(client) {
                anyhow::bail!("unknown client {client}");
            }
            Ok(serde_json::to_value(mux.presentations.list_for_client(client))?)
        }
        Command::ClaimProjectionState { logical_presentation_id } => {
            let claimant = projection_claimant(mux, client)?;
            let live_bindings = projection_live_bindings(mux);
            Ok(serde_json::to_value(mux.projection_states.claim(
                claimant,
                logical_presentation_id,
                &live_bindings,
            )?)?)
        }
        Command::UpdateProjectionState {
            logical_presentation_id,
            claim_id,
            expected_generation,
            workspaces,
        } => {
            let claimant = projection_claimant(mux, client)?;
            let live_bindings = projection_live_bindings(mux);
            Ok(serde_json::to_value(mux.projection_states.update(
                claimant,
                logical_presentation_id,
                claim_id,
                expected_generation,
                workspaces,
                &live_bindings,
            )?)?)
        }
        Command::UpdateProjectionStates { projections } => {
            let claimant = projection_claimant(mux, client)?;
            let live_bindings = projection_live_bindings(mux);
            Ok(serde_json::to_value(mux.projection_states.update_many(
                claimant,
                projections,
                &live_bindings,
            )?)?)
        }
        Command::ReleaseProjectionState {
            logical_presentation_id,
            claim_id,
            expected_generation,
        } => {
            let claimant = projection_claimant(mux, client)?;
            mux.projection_states.release(
                claimant,
                logical_presentation_id,
                claim_id,
                expected_generation,
            )?;
            Ok(json!({}))
        }
        Command::ListProjectionStates => {
            let claimant = projection_claimant(mux, client)?;
            let live_bindings = projection_live_bindings(mux);
            Ok(serde_json::to_value(mux.projection_states.list(claimant, &live_bindings)?)?)
        }
        Command::EnsureTerminal {
            workspace_uuid,
            surface_uuid,
            cwd,
            argv,
            command,
            env,
            initial_input,
            wait_after_command,
            cols,
            rows,
        } => {
            if !mux.control_clients.has_permission(client, ConnectionPermission::Control) {
                anyhow::bail!("ensure-terminal requires a trusted local connection");
            }
            let placement = mux.ensure_terminal(ensure_terminal_request(EnsureTerminalSpec {
                workspace_uuid,
                surface_uuid,
                cwd,
                argv,
                command,
                env,
                initial_input,
                wait_after_command,
                cols,
                rows,
            })?)?;
            Ok(ensured_terminal_placement_json(placement))
        }
        Command::EnsureTerminals { terminals } => {
            if !mux.control_clients.has_permission(client, ConnectionPermission::Control) {
                anyhow::bail!("ensure-terminals requires a trusted local connection");
            }
            let requests = terminals
                .into_iter()
                .map(ensure_terminal_request)
                .collect::<anyhow::Result<Vec<_>>>()?;
            Ok(Value::Array(
                mux.ensure_terminals(requests)?
                    .into_iter()
                    .map(ensured_terminal_placement_json)
                    .collect(),
            ))
        }
        Command::ReparentTerminal { surface_uuid, workspace_uuid } => {
            if !mux.control_clients.has_permission(client, ConnectionPermission::Control) {
                anyhow::bail!("reparent-terminal requires a trusted local connection");
            }
            let placement = mux.reparent_terminal(surface_uuid, workspace_uuid)?;
            Ok(json!({
                "moved": placement.moved,
                "workspace": placement.workspace,
                "workspace_uuid": placement.workspace_uuid,
                "screen": placement.screen,
                "screen_uuid": placement.screen_uuid,
                "pane": placement.pane,
                "pane_uuid": placement.pane_uuid,
                "surface": placement.surface,
                "surface_uuid": placement.surface_uuid,
            }))
        }
        Command::RendererWorkers => {
            if !mux.control_clients.has_permission(client, ConnectionPermission::Frontend) {
                anyhow::bail!("renderer worker status requires a trusted local connection");
            }
            let (default_colors_revision, default_colors) = mux.default_colors_snapshot();
            Ok(json!({
                "daemon_instance_id": mux.daemon_instance_id,
                "workers": mux.renderer_worker_statuses(),
                "default_colors_revision": default_colors_revision,
                "default_colors": default_colors_json(default_colors),
            }))
        }
        Command::ConfigureRendererPresentation {
            presentation_id,
            expected_generation,
            width,
            height,
            backing_scale_factor,
            columns,
            rows,
            pixel_format,
            color_space,
            frame_endpoint_service,
            frame_endpoint_capability,
            resolved_config_revision,
            resolved_config,
            focused,
            cursor_blink_visible,
            preedit,
            preedit_selection_start_utf16,
            preedit_selection_length_utf16,
            preedit_caret_utf16,
        } => {
            let _client_lifecycle = mux.control_clients.lock_lifecycle();
            if !mux.control_clients.has_permission(client, ConnectionPermission::Frontend) {
                anyhow::bail!(
                    "renderer presentation configuration requires a trusted local connection"
                );
            }
            let configuration = RendererPresentationConfiguration {
                width,
                height,
                backing_scale_factor,
                columns,
                rows,
                pixel_format: parse_renderer_pixel_format(&pixel_format)?,
                color_space: parse_renderer_color_space(&color_space)?,
                frame_endpoint_service,
                frame_endpoint_capability: base64::engine::general_purpose::STANDARD
                    .decode(frame_endpoint_capability)?,
                resolved_config_revision,
                resolved_config: base64::engine::general_purpose::STANDARD
                    .decode(resolved_config)?,
                focused,
                cursor_blink_visible,
                preedit: parse_renderer_preedit(
                    preedit,
                    preedit_selection_start_utf16,
                    preedit_selection_length_utf16,
                    preedit_caret_utf16,
                )?,
            };
            let receipt = mux.configure_renderer_presentation(
                client,
                presentation_id,
                expected_generation,
                configuration,
            )?;
            // A child-exit close can originate outside the control connection.
            // Fence the final presentation lookup and visibility publication
            // so canonical retirement cannot finish and then be followed by a
            // stale visible-authority insertion.
            let _terminal_lifecycle = mux.read_terminal_control_lifecycle();
            let presentation = mux.presentations.get_for_client(client, presentation_id)?;
            let surface_uuid = presentation
                .view
                .surface_uuid
                .ok_or_else(|| anyhow::anyhow!("renderer presentation has no selected terminal"))?;
            get_surface_by_uuid(mux, surface_uuid)?;
            mux.terminal_authority.mark_presentation_visible(PresentationAuthority {
                connection: client,
                presentation_id,
                presentation_generation: presentation.generation,
                surface_uuid,
            })?;
            let worker_ready = receipt.worker.state == crate::RendererWorkerState::Ready;
            let worker_pid = worker_ready.then_some(receipt.worker.pid).flatten();
            let worker_effective_user_id =
                worker_ready.then_some(receipt.worker.effective_user_id).flatten();
            Ok(json!({
                "daemon_instance_id": receipt.daemon_instance_id,
                "workspace_uuid": receipt.worker.workspace_uuid,
                "renderer_epoch": receipt.worker.renderer_epoch,
                "worker_state": receipt.worker.state,
                "worker_pid": worker_pid,
                "worker_effective_user_id": worker_effective_user_id,
                "scene_capabilities": receipt.worker.scene_capabilities,
                "terminal_id": receipt.terminal_id,
                "terminal_epoch": receipt.terminal_epoch,
                "presentation_id": receipt.presentation_id,
                "generation": receipt.canonical_presentation_generation,
                "renderer_generation": receipt.renderer_presentation_generation,
                "minimum_content_sequence": receipt.minimum_content_sequence,
                "width": receipt.width,
                "height": receipt.height,
                "backing_scale_factor": receipt.backing_scale_factor,
                "columns": receipt.columns,
                "rows": receipt.rows,
                "metrics": Value::Null,
                "pixel_format": renderer_pixel_format_name(receipt.pixel_format),
                "color_space": renderer_color_space_name(receipt.color_space),
            }))
        }
        Command::DetachRendererPresentation { presentation_id, expected_generation } => {
            let _client_lifecycle = mux.control_clients.lock_lifecycle();
            if !mux.control_clients.has_permission(client, ConnectionPermission::Frontend) {
                anyhow::bail!("renderer presentation detach requires a trusted local connection");
            }
            mux.detach_renderer_presentation(client, presentation_id, expected_generation)?;
            mux.terminal_authority.hide_presentation(client, presentation_id);
            Ok(json!({}))
        }
        Command::TerminalPreedit {
            presentation_id,
            renderer_generation,
            text,
            selection_start_utf16,
            selection_length_utf16,
            caret_utf16,
        } => {
            if !mux.control_clients.has_permission(client, ConnectionPermission::Frontend) {
                anyhow::bail!("terminal preedit requires a trusted local connection");
            }
            if text.as_ref().is_some_and(|text| text.len() > TERMINAL_KEY_TEXT_MAX_BYTES) {
                anyhow::bail!(
                    "bad request: terminal preedit exceeds {TERMINAL_KEY_TEXT_MAX_BYTES} bytes"
                );
            }
            let preedit = parse_renderer_preedit(
                text,
                selection_start_utf16,
                selection_length_utf16,
                caret_utf16,
            )?;
            mux.set_renderer_preedit(client, presentation_id, renderer_generation, preedit)?;
            Ok(json!({}))
        }
        Command::TerminalAccessibilitySnapshot {
            presentation_id,
            expected_generation,
            expected_content_sequence,
        } => {
            if !mux.control_clients.has_permission(client, ConnectionPermission::Frontend) {
                anyhow::bail!("terminal accessibility requires a trusted local connection");
            }
            // Accessibility reads expose terminal contents. Require the
            // protocol-v9 logical/process registration and an owned,
            // generation-fenced presentation instead of accepting a numeric
            // surface handle from any local socket client.
            let _ = mux.control_clients.protocol_identity(client, 9)?;
            let value = serde_json::to_value(mux.terminal_accessibility_snapshot(
                client,
                presentation_id,
                expected_generation,
                expected_content_sequence,
            )?)?;
            if serde_json::to_vec(&value)?.len() > crate::TERMINAL_ACCESSIBILITY_MAX_WIRE_BYTES {
                anyhow::bail!("terminal accessibility response exceeds wire bound");
            }
            Ok(value)
        }
        Command::TerminalAccessibilityActivateLink {
            presentation_id,
            expected_generation,
            terminal_revision,
            content_revision,
            viewport_revision,
            link_id,
        } => {
            if !mux.control_clients.has_permission(client, ConnectionPermission::Frontend) {
                anyhow::bail!(
                    "terminal accessibility link activation requires a trusted local connection"
                );
            }
            let _ = mux.control_clients.protocol_identity(client, 9)?;
            if link_id.is_empty() || link_id.len() > 128 {
                anyhow::bail!("bad request: invalid terminal accessibility link id");
            }
            let target = mux.activate_terminal_accessibility_link(
                client,
                presentation_id,
                expected_generation,
                terminal_revision,
                content_revision,
                viewport_revision,
                &link_id,
            )?;
            Ok(json!({ "target": target }))
        }
        Command::TerminalLinkAtCell {
            presentation_id,
            expected_generation,
            expected_content_sequence,
            column,
            row,
        } => {
            if !mux.control_clients.has_permission(client, ConnectionPermission::Frontend) {
                anyhow::bail!("terminal hyperlink activation requires a trusted local connection");
            }
            let _ = mux.control_clients.protocol_identity(client, 9)?;
            let hit = mux.terminal_hyperlink_at_viewport_cell(
                client,
                presentation_id,
                expected_generation,
                expected_content_sequence,
                column,
                row,
            )?;
            Ok(json!({
                "surface_uuid": hit.surface_uuid,
                "presentation_id": hit.presentation_id,
                "presentation_generation": hit.presentation_generation,
                "content_sequence": hit.content_sequence,
                "terminal_revision": hit.terminal_revision,
                "content_revision": hit.content_revision,
                "viewport_revision": hit.viewport_revision,
                "column": hit.column,
                "row": hit.row,
                "target": hit.target,
            }))
        }
        Command::AcquireTerminalControl {
            surface_uuid,
            presentation_id,
            presentation_generation,
            ttl_ms,
        } => {
            let _client_lifecycle = mux.control_clients.lock_lifecycle();
            let (client_uuid, process_instance_uuid, _) =
                mux.control_clients.protocol_identity(client, 9)?;
            let surface = get_surface_by_uuid(mux, surface_uuid)?;
            require_pty(&surface)?;
            let presentation = mux.presentations.get_for_client(client, presentation_id)?;
            if presentation.generation != presentation_generation {
                anyhow::bail!(
                    "stale presentation generation {presentation_generation}; current generation is {}",
                    presentation.generation
                );
            }
            if presentation.view.surface_uuid != Some(surface_uuid) {
                anyhow::bail!("presentation does not display terminal {surface_uuid}");
            }
            // Compatibility alias for early v9 clients. New clients negotiate
            // terminal-split-leases-v1 and use acquire-terminal-lease twice.
            let lease = mux.acquire_terminal_lease(
                surface.id,
                TerminalLeaseKind::Input,
                TerminalLeaseClaim {
                    connection: client,
                    client_uuid,
                    process_instance_uuid,
                    presentation_id,
                    presentation_generation,
                },
                ttl_ms,
            )?;
            Ok(json!({
                "surface_uuid": lease.surface_uuid,
                "presentation_id": presentation_id,
                "presentation_generation": presentation_generation,
                "lease_id": lease.lease_id,
                "lease_generation": lease.lease_generation,
                "expires_at_ms": lease.expires_at_ms,
                "next_input_sequence": lease.next_client_sequence,
                "next_geometry_sequence": 1,
                "migrated_from_legacy": lease.migrated_from_legacy,
            }))
        }
        Command::AcquireTerminalLease {
            kind,
            surface_uuid,
            presentation_id,
            presentation_generation,
            ttl_ms,
        } => {
            let _client_lifecycle = mux.control_clients.lock_lifecycle();
            let kind = terminal_lease_kind(&kind)?;
            let (client_uuid, process_instance_uuid, _) =
                mux.control_clients.protocol_identity(client, 9)?;
            let surface = get_surface_by_uuid(mux, surface_uuid)?;
            require_pty(&surface)?;
            let presentation = mux.presentations.get_for_client(client, presentation_id)?;
            if presentation.generation != presentation_generation {
                anyhow::bail!(
                    "stale presentation generation {presentation_generation}; current generation is {}",
                    presentation.generation
                );
            }
            if presentation.view.surface_uuid != Some(surface_uuid) {
                anyhow::bail!("presentation does not display terminal {surface_uuid}");
            }
            let lease = mux.acquire_terminal_lease(
                surface.id,
                kind,
                TerminalLeaseClaim {
                    connection: client,
                    client_uuid,
                    process_instance_uuid,
                    presentation_id,
                    presentation_generation,
                },
                ttl_ms,
            )?;
            Ok(terminal_lease_json(lease, presentation_id, presentation_generation))
        }
        Command::RenewTerminalLease {
            kind,
            surface_uuid,
            presentation_id,
            presentation_generation,
            lease_id,
            lease_generation,
            ttl_ms,
        } => {
            let _client_lifecycle = mux.control_clients.read_lifecycle();
            let _terminal_lifecycle = mux.read_terminal_control_lifecycle();
            let kind = terminal_lease_kind(&kind)?;
            let reference = terminal_lease_reference(
                mux,
                client,
                presentation_id,
                presentation_generation,
                lease_id,
                lease_generation,
            )?;
            let lease = mux.terminal_authority.renew(surface_uuid, kind, reference, ttl_ms)?;
            Ok(terminal_lease_json(lease, presentation_id, presentation_generation))
        }
        Command::ReleaseTerminalControl {
            surface_uuid,
            presentation_id,
            presentation_generation,
            lease_id,
            lease_generation,
        } => {
            let _client_lifecycle = mux.control_clients.read_lifecycle();
            let _terminal_lifecycle = mux.read_terminal_control_lifecycle();
            let reference = terminal_lease_reference(
                mux,
                client,
                presentation_id,
                presentation_generation,
                lease_id,
                lease_generation,
            )?;
            mux.terminal_authority.release(surface_uuid, TerminalLeaseKind::Input, reference)?;
            Ok(json!({}))
        }
        Command::ReleaseTerminalLease {
            kind,
            surface_uuid,
            presentation_id,
            presentation_generation,
            lease_id,
            lease_generation,
        } => {
            let _client_lifecycle = mux.control_clients.read_lifecycle();
            let _terminal_lifecycle = mux.read_terminal_control_lifecycle();
            let kind = terminal_lease_kind(&kind)?;
            let reference = terminal_lease_reference(
                mux,
                client,
                presentation_id,
                presentation_generation,
                lease_id,
                lease_generation,
            )?;
            mux.terminal_authority.release(surface_uuid, kind, reference)?;
            Ok(json!({}))
        }
        Command::TransferTerminalLease {
            kind,
            surface_uuid,
            presentation_id,
            presentation_generation,
            lease_id,
            lease_generation,
            target_client_uuid,
            target_presentation_id,
            target_presentation_generation,
            ttl_ms,
        } => {
            let _client_lifecycle = mux.control_clients.lock_lifecycle();
            let _terminal_lifecycle = mux.read_terminal_control_lifecycle();
            let kind = terminal_lease_kind(&kind)?;
            let reference = terminal_lease_reference(
                mux,
                client,
                presentation_id,
                presentation_generation,
                lease_id,
                lease_generation,
            )?;
            let target_claim = mux.control_clients.unique_connection_claim(target_client_uuid)?;
            let target_presentation = mux
                .presentations
                .get_for_client(target_claim.connection, target_presentation_id)?;
            if target_presentation.generation != target_presentation_generation {
                anyhow::bail!(
                    "stale target presentation generation {target_presentation_generation}; current generation is {}",
                    target_presentation.generation
                );
            }
            if target_presentation.view.surface_uuid != Some(surface_uuid) {
                anyhow::bail!("target presentation does not display terminal {surface_uuid}");
            }
            let lease = mux.terminal_authority.transfer(
                surface_uuid,
                kind,
                reference,
                TerminalLeaseClaim {
                    connection: target_claim.connection,
                    client_uuid: target_claim.client_uuid,
                    process_instance_uuid: target_claim.process_instance_uuid,
                    presentation_id: target_presentation_id,
                    presentation_generation: target_presentation_generation,
                },
                ttl_ms,
            )?;
            Ok(terminal_lease_json(lease, target_presentation_id, target_presentation_generation))
        }
        Command::GrantTerminalInputDelegation {
            surface_uuid,
            presentation_id,
            presentation_generation,
            lease_id,
            lease_generation,
            delegate_client_uuid,
            ttl_ms,
            scopes,
        } => {
            let _client_lifecycle = mux.control_clients.read_lifecycle();
            let _terminal_lifecycle = mux.read_terminal_control_lifecycle();
            let owner = terminal_lease_reference(
                mux,
                client,
                presentation_id,
                presentation_generation,
                lease_id,
                lease_generation,
            )?;
            let delegate = mux.control_clients.unique_connection_claim(delegate_client_uuid)?;
            let delegation = mux.terminal_authority.grant_input_delegation(
                surface_uuid,
                owner,
                delegate,
                ttl_ms,
                terminal_automation_scopes(scopes)?,
            )?;
            Ok(json!({
                "surface_uuid": delegation.surface_uuid,
                "delegation_id": delegation.delegation_id,
                "delegation_generation": delegation.delegation_generation,
                "owner_lease_generation": delegation.owner_lease_generation,
                "delegate_client_uuid": delegation.delegate.client_uuid,
                "delegate_process_instance_uuid": delegation.delegate.process_instance_uuid,
                "expires_at_ms": delegation.expires_at_ms,
                "scopes": delegation.scopes.into_iter().map(|scope| match scope {
                    AutomationInputScope::Text => "text",
                    AutomationInputScope::Key => "key",
                    AutomationInputScope::Mouse => "mouse",
                }).collect::<Vec<_>>(),
                "next_sequence": delegation.next_client_sequence,
            }))
        }
        Command::RevokeTerminalInputDelegation {
            surface_uuid,
            presentation_id,
            presentation_generation,
            lease_id,
            lease_generation,
            delegation_id,
            delegation_generation,
        } => {
            let _client_lifecycle = mux.control_clients.read_lifecycle();
            let _terminal_lifecycle = mux.read_terminal_control_lifecycle();
            let owner = terminal_lease_reference(
                mux,
                client,
                presentation_id,
                presentation_generation,
                lease_id,
                lease_generation,
            )?;
            mux.terminal_authority.revoke_input_delegation(
                surface_uuid,
                owner,
                delegation_id,
                delegation_generation,
            )?;
            Ok(json!({}))
        }
        Command::TerminalInput {
            surface_uuid,
            presentation_id,
            presentation_generation,
            lease_id,
            lease_generation,
            sequence,
            request_id,
            input,
            input_group_id,
            input_group_index,
            input_group_end,
        } => {
            let _client_lifecycle = mux.control_clients.read_lifecycle();
            let _terminal_lifecycle = mux.read_terminal_control_lifecycle();
            if request_id.is_nil() {
                anyhow::bail!("bad request: terminal request_id must be a non-nil UUID");
            }
            let reference = terminal_lease_reference(
                mux,
                client,
                presentation_id,
                presentation_generation,
                lease_id,
                lease_generation,
            )?;
            let group = terminal_input_group(input_group_id, input_group_index, input_group_end)?;
            let scope = terminal_input_scope(&input);
            let fingerprint = terminal_request_fingerprint(&json!({
                "kind": "input",
                "sequence": sequence,
                "input": &input,
                "input_group": group.map(|group| json!({
                    "id": group.id,
                    "index": group.index,
                    "end": group.end,
                })),
            }))?;
            let prepared = prepare_terminal_input(input)?;
            let surface = get_surface_by_uuid(mux, surface_uuid)?;
            require_pty(&surface)?;
            match mux.terminal_authority.begin_input_with_scope(
                surface_uuid,
                reference,
                scope,
                sequence,
                request_id,
                fingerprint,
                group,
            )? {
                BeginTerminalOperation::Replay(receipt) => Ok(terminal_receipt_json(receipt)),
                BeginTerminalOperation::Execute(permit) => {
                    match execute_terminal_input(&surface, prepared) {
                        Ok(encoded_bytes) => {
                            let receipt = mux.terminal_authority.complete_operation(
                                permit,
                                TerminalOperationOutcome::InputApplied { encoded_bytes },
                            )?;
                            Ok(terminal_receipt_json(receipt))
                        }
                        Err(TerminalInputExecutionError::Rejected(error)) => {
                            mux.terminal_authority.abort_operation(permit)?;
                            Err(error)
                        }
                        Err(TerminalInputExecutionError::Indeterminate(error)) => {
                            let receipt = mux.terminal_authority.complete_operation(
                                permit,
                                TerminalOperationOutcome::InputIndeterminate {
                                    diagnostic: format!(
                                        "PTY write failed after an unknown consumed prefix: {error}"
                                    ),
                                },
                            )?;
                            Ok(terminal_receipt_json(receipt))
                        }
                    }
                }
            }
        }
        Command::TerminalDelegatedInput {
            surface_uuid,
            delegation_id,
            delegation_generation,
            sequence,
            request_id,
            input,
            input_group_id,
            input_group_index,
            input_group_end,
        } => {
            let _client_lifecycle = mux.control_clients.read_lifecycle();
            let _terminal_lifecycle = mux.read_terminal_control_lifecycle();
            if request_id.is_nil() {
                anyhow::bail!("bad request: terminal request_id must be a non-nil UUID");
            }
            let (client_uuid, process_instance_uuid, _) =
                mux.control_clients.protocol_identity(client, 9)?;
            let reference = TerminalDelegationReference {
                connection: client,
                client_uuid,
                process_instance_uuid,
                delegation_id,
                delegation_generation,
            };
            let group = terminal_input_group(input_group_id, input_group_index, input_group_end)?;
            let scope = terminal_input_scope(&input);
            let fingerprint = terminal_request_fingerprint(&json!({
                "kind": "delegated-input",
                "sequence": sequence,
                "input": &input,
                "input_group": group.map(|group| json!({
                    "id": group.id,
                    "index": group.index,
                    "end": group.end,
                })),
            }))?;
            let prepared = prepare_terminal_input(input)?;
            let surface = get_surface_by_uuid(mux, surface_uuid)?;
            require_pty(&surface)?;
            match mux.terminal_authority.begin_delegated_input(
                surface_uuid,
                reference,
                scope,
                sequence,
                request_id,
                fingerprint,
                group,
            )? {
                BeginTerminalOperation::Replay(receipt) => Ok(terminal_receipt_json(receipt)),
                BeginTerminalOperation::Execute(permit) => {
                    match execute_terminal_input(&surface, prepared) {
                        Ok(encoded_bytes) => {
                            let receipt = mux.terminal_authority.complete_operation(
                                permit,
                                TerminalOperationOutcome::InputApplied { encoded_bytes },
                            )?;
                            Ok(terminal_receipt_json(receipt))
                        }
                        Err(TerminalInputExecutionError::Rejected(error)) => {
                            mux.terminal_authority.abort_operation(permit)?;
                            Err(error)
                        }
                        Err(TerminalInputExecutionError::Indeterminate(error)) => {
                            let receipt = mux.terminal_authority.complete_operation(
                                permit,
                                TerminalOperationOutcome::InputIndeterminate {
                                    diagnostic: format!(
                                        "PTY write failed after an unknown consumed prefix: {error}"
                                    ),
                                },
                            )?;
                            Ok(terminal_receipt_json(receipt))
                        }
                    }
                }
            }
        }
        Command::TerminalGeometry {
            surface_uuid,
            presentation_id,
            presentation_generation,
            lease_id,
            lease_generation,
            sequence,
            request_id,
            cols,
            rows,
        } => {
            let _client_lifecycle = mux.control_clients.read_lifecycle();
            let _terminal_lifecycle = mux.read_terminal_control_lifecycle();
            if request_id.is_nil() {
                anyhow::bail!("bad request: terminal request_id must be a non-nil UUID");
            }
            let reference = terminal_lease_reference(
                mux,
                client,
                presentation_id,
                presentation_generation,
                lease_id,
                lease_generation,
            )?;
            let (cols, rows) = clamp_terminal_size(cols, rows);
            let fingerprint = terminal_request_fingerprint(&json!({
                "kind": "geometry",
                "sequence": sequence,
                "cols": cols,
                "rows": rows,
            }))?;
            let surface = get_surface_by_uuid(mux, surface_uuid)?;
            require_pty(&surface)?;
            match mux.terminal_authority.begin_geometry(
                surface_uuid,
                reference,
                sequence,
                request_id,
                fingerprint,
            )? {
                BeginTerminalOperation::Replay(receipt) => Ok(terminal_receipt_json(receipt)),
                BeginTerminalOperation::Execute(permit) => {
                    let changed = match mux.resize_surface(surface.id, cols, rows) {
                        Ok(changed) => changed,
                        Err(error) => {
                            mux.terminal_authority.abort_operation(permit)?;
                            return Err(error);
                        }
                    };
                    let (cols, rows) = surface.size();
                    let receipt = mux.terminal_authority.complete_operation(
                        permit,
                        TerminalOperationOutcome::GeometryApplied { cols, rows, changed },
                    )?;
                    Ok(terminal_receipt_json(receipt))
                }
            }
        }
        Command::TerminalRequestStatus { surface_uuid, request_id } => {
            let (client_uuid, _, _) = mux.control_clients.protocol_identity(client, 9)?;
            Ok(match mux.terminal_authority.receipt(surface_uuid, client_uuid, request_id) {
                Some(receipt) => terminal_receipt_json(receipt),
                None => json!({
                    "request_id": request_id,
                    "status": "unknown",
                }),
            })
        }
        Command::AcknowledgeTerminalRequest { surface_uuid, request_id } => {
            let (client_uuid, _, _) = mux.control_clients.protocol_identity(client, 9)?;
            let surface = get_surface_by_uuid(mux, surface_uuid)?;
            require_pty(&surface)?;
            let acknowledged = mux.terminal_authority.acknowledge_receipt(
                surface_uuid,
                client_uuid,
                request_id,
            )?;
            Ok(json!({
                "request_id": request_id,
                "acknowledged": acknowledged,
            }))
        }
        Command::ReleaseRendererFrame {
            daemon_instance_id,
            renderer_epoch,
            terminal_id,
            terminal_epoch,
            terminal_sequence,
            presentation_id,
            presentation_generation,
            frame_sequence,
            surface_id,
        } => {
            if !mux.control_clients.has_permission(client, ConnectionPermission::Frontend) {
                anyhow::bail!("renderer frame release requires a trusted local connection");
            }
            let forwarded = mux.release_renderer_frame(
                client,
                RendererFrameRelease {
                    daemon_instance_id,
                    renderer_epoch,
                    terminal_id,
                    terminal_epoch,
                    terminal_sequence,
                    presentation_id,
                    presentation_generation,
                    frame_sequence,
                    surface_id,
                },
            )?;
            Ok(json!({ "forwarded": forwarded }))
        }
        Command::SetClientInfo { name, kind } => {
            let (name, kind) = mux.control_clients.set_info(client, name, kind)?;
            mux.emit(MuxEvent::ClientChanged { client, name, kind });
            Ok(json!({}))
        }
        Command::ListClients => Ok(mux.control_clients_json(client)),
        Command::SetClientSizing { client: target, enabled, exclusive } => {
            if exclusive && !enabled {
                anyhow::bail!("exclusive client sizing must be enabled");
            }
            if let Some(target) = target {
                if exclusive {
                    mux.use_only_client_size(target)
                        .ok_or_else(|| anyhow::anyhow!("unknown client {target}"))?;
                } else {
                    mux.set_client_size_participation(target, enabled)
                        .ok_or_else(|| anyhow::anyhow!("unknown client {target}"))?;
                }
            } else if enabled {
                mux.use_all_client_sizes();
            } else {
                anyhow::bail!("client is required when disabling sizing");
            }
            Ok(json!({}))
        }
        Command::PairingResponse { request, approve } => {
            if !mux.control_clients.has_permission(client, ConnectionPermission::Frontend) {
                anyhow::bail!("pairing decisions require a trusted local connection");
            }
            if !mux.respond_pairing(request, approve) {
                anyhow::bail!("unknown or expired pairing request {request}");
            }
            Ok(json!({}))
        }
        Command::DetachClient { client: target } => {
            if target == client {
                if !mux.control_clients.contains(target) {
                    anyhow::bail!("unknown client {target}");
                }
            } else if !disconnect_client(mux, target, true) {
                anyhow::bail!("unknown client {target}");
            }
            Ok(json!({}))
        }
        Command::ReloadConfig => {
            mux.emit(MuxEvent::ConfigReloadRequested);
            Ok(json!({
                "reloaded": true,
                "path": platform::config_path().map(|path| path.display().to_string()),
            }))
        }
        Command::SetWindowTitle { title } => {
            mux.emit(MuxEvent::WindowTitleRequested(title));
            Ok(json!({}))
        }
        Command::ClearWindowTitle => {
            mux.emit(MuxEvent::WindowTitleRequested(String::new()));
            Ok(json!({}))
        }
        Command::TopologySnapshot => Ok(serde_json::to_value(mux.topology_snapshot())?),
        Command::TerminalActivitySnapshot => {
            let (reader_uuid, _, _) = mux.control_clients.protocol_identity(client, 9)?;
            Ok(serde_json::to_value(mux.terminal_activity_snapshot(reader_uuid)?)?)
        }
        Command::MarkTerminalSeen { surface_uuid, activity_sequence } => {
            let (reader_uuid, _, _) = mux.control_clients.protocol_identity(client, 9)?;
            Ok(serde_json::to_value(mux.mark_terminal_seen(
                reader_uuid,
                surface_uuid,
                activity_sequence,
            )?)?)
        }
        Command::ListWorkspaces => {
            let reader_uuid = mux
                .control_clients
                .stable_reader_uuid(client)
                .unwrap_or(LEGACY_TERMINAL_ACTIVITY_READER_UUID);
            let notifications = mux.surface_notifications_for_reader(reader_uuid);
            let snapshot = mux.with_state_snapshot(|state| workspaces_json(state, &notifications));
            let mut data = snapshot.state;
            data["topology_revision"] = json!(snapshot.topology_revision);
            Ok(data)
        }
        Command::ExportLayout { screen } => {
            mux.with_state(|state| export_layout_json(state, screen))
        }
        Command::ApplyLayout { workspace, name, layout, cols, rows } => {
            let layout = layout_request_to_spec(layout)?;
            let applied =
                mux.apply_layout(workspace, name, &layout, optional_surface_size(cols, rows))?;
            Ok(json!({
                "screen": applied.screen,
                "panes": applied.panes.iter().map(|pane| {
                    json!({ "pane": pane.pane, "surface": pane.surface })
                }).collect::<Vec<_>>(),
            }))
        }
        Command::Send { surface, text, bytes, paste } => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)?;
            mux.with_legacy_terminal_control(&surface, || {
                if paste {
                    let mut payload = text.unwrap_or_default().into_bytes();
                    if let Some(b64) = bytes {
                        payload.extend(base64::engine::general_purpose::STANDARD.decode(b64)?);
                    }
                    surface.write_paste(&payload)?;
                } else {
                    if let Some(text) = text {
                        surface.write_bytes(text.as_bytes())?;
                    }
                    if let Some(b64) = bytes {
                        let raw = base64::engine::general_purpose::STANDARD.decode(b64)?;
                        surface.write_bytes(&raw)?;
                    }
                }
                Ok(json!({}))
            })
        }
        Command::ReadScreen { surface } => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)?;
            let text = surface.try_with_terminal(|t| t.viewport_text())??;
            Ok(json!({ "text": text }))
        }
        Command::ReadScrollback { surface, start, count } => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)?;
            let count = u16::try_from(count).map_err(|_| anyhow::anyhow!("count out of range"))?;
            let (start, total, rows) = surface.try_with_terminal(|term| {
                let total = term.history_rows();
                let start = start.min(total);
                term.styled_history_rows(start, count).map(|rows| (start, total, rows))
            })??;
            let runs = rows_to_runs(&rows);
            let rows = runs
                .iter()
                .enumerate()
                .map(|(row, runs)| {
                    json!({
                        "row": row as u16,
                        "runs": runs.iter().map(styled_run_json).collect::<Vec<_>>(),
                    })
                })
                .collect::<Vec<_>>();
            Ok(json!({ "rows": rows, "start": start, "total": total }))
        }
        Command::SidebarPlugin { cols, rows, relaunch } => {
            Ok(sidebar_plugin_status_json(mux.ensure_sidebar_plugin(cols, rows, relaunch)))
        }
        Command::WaitFor { surface, pattern, timeout_ms } => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)?;
            let regex = Regex::new(&pattern).map_err(|err| anyhow::anyhow!("bad regex: {err}"))?;
            let start = Instant::now();
            let check = || -> anyhow::Result<Option<String>> {
                let text = surface.try_with_terminal(|t| t.viewport_text())??;
                Ok(regex.is_match(&text).then_some(text))
            };
            if timeout_ms == 0 {
                if let Some(text) = check()? {
                    return Ok(json!({
                        "matched": true,
                        "text": text,
                        "elapsed_ms": start.elapsed().as_millis() as u64,
                    }));
                }
                anyhow::bail!("timeout waiting for pattern");
            }
            let deadline = start + Duration::from_millis(timeout_ms);
            let attach = surface.attach_stream()?;
            if let Some(text) = check()? {
                return Ok(json!({
                    "matched": true,
                    "text": text,
                    "elapsed_ms": start.elapsed().as_millis() as u64,
                }));
            }
            loop {
                let now = Instant::now();
                if now >= deadline {
                    anyhow::bail!("timeout waiting for pattern");
                }
                let remaining = deadline.saturating_duration_since(now);
                match attach.stream.recv_timeout(remaining) {
                    Ok(_) => {
                        if let Some(text) = check()? {
                            return Ok(json!({
                                "matched": true,
                                "text": text,
                                "elapsed_ms": start.elapsed().as_millis() as u64,
                            }));
                        }
                    }
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                        anyhow::bail!("timeout waiting for pattern");
                    }
                    Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                        anyhow::bail!("timeout waiting for pattern");
                    }
                }
            }
        }
        Command::Run { argv, command, cwd, pane, new_workspace, name, cols, rows } => {
            if argv.is_some() && command.is_some() {
                anyhow::bail!("argv and command are mutually exclusive");
            }
            let argv = match (argv, command) {
                (Some(argv), None) if !argv.is_empty() => argv,
                (None, Some(command)) if !command.is_empty() => {
                    vec![platform::default_shell(), "-lc".to_string(), command]
                }
                _ => anyhow::bail!("argv or command is required"),
            };
            if new_workspace && pane.is_some() {
                anyhow::bail!("pane and new_workspace are mutually exclusive");
            }
            let placement = mux.run_command_surface(
                argv,
                pane,
                new_workspace,
                cwd,
                name,
                optional_surface_size(cols, rows),
            )?;
            Ok(json!({
                "surface": placement.surface,
                "pane": placement.pane,
                "screen": placement.screen,
                "workspace": placement.workspace,
            }))
        }
        Command::SendKey { surface, keys } => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)
                .map_err(|_| anyhow::anyhow!("surface does not support key input"))?;
            if keys.is_empty() {
                anyhow::bail!("bad request: keys must be non-empty");
            }
            mux.with_legacy_terminal_control(&surface, || {
                let mut encoder = KeyEncoder::new()?;
                let mut encoded = Vec::new();
                surface.scroll_to_bottom()?;
                surface.try_with_terminal(|term| {
                    encoder.sync_from_terminal(term);
                    for key in &keys {
                        let Some(input) = key_input_from_chord(key) else {
                            return Err(anyhow::anyhow!("unknown key {key}"));
                        };
                        encoder.encode(&input, &mut encoded).map_err(anyhow::Error::from)?;
                    }
                    Ok::<(), anyhow::Error>(())
                })??;
                surface.write_bytes(&encoded)?;
                Ok(json!({}))
            })
        }
        Command::TerminalKey {
            surface,
            key,
            modifiers,
            consumed_modifiers,
            text,
            unshifted_codepoint,
            action,
        } => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)
                .map_err(|_| anyhow::anyhow!("surface does not support key input"))?;
            if key > ghostty_vt::sys::GHOSTTY_KEY_PASTE {
                anyhow::bail!("bad request: unknown terminal key {key}");
            }
            if modifiers & !TERMINAL_KEY_MODIFIERS_MASK != 0
                || consumed_modifiers & !TERMINAL_KEY_MODIFIERS_MASK != 0
                || consumed_modifiers & !modifiers != 0
            {
                anyhow::bail!("bad request: invalid terminal key modifiers");
            }
            if text.len() > TERMINAL_KEY_TEXT_MAX_BYTES {
                anyhow::bail!(
                    "bad request: terminal key text exceeds {TERMINAL_KEY_TEXT_MAX_BYTES} bytes"
                );
            }
            if text.chars().any(|character| character <= '\u{1f}' || character == '\u{7f}') {
                anyhow::bail!("bad request: terminal key text contains a control character");
            }
            if unshifted_codepoint != 0 && char::from_u32(unshifted_codepoint).is_none() {
                anyhow::bail!("bad request: invalid unshifted codepoint");
            }
            let action = match action.as_deref().unwrap_or("press") {
                "press" => KeyAction::Press,
                "release" => KeyAction::Release,
                "repeat" => KeyAction::Repeat,
                other => anyhow::bail!("bad request: unknown terminal key action {other:?}"),
            };
            let input = KeyInput {
                key,
                mods: Mods(modifiers),
                consumed_mods: Mods(consumed_modifiers),
                utf8: text,
                unshifted_codepoint,
                action: Some(action),
            };
            mux.with_legacy_terminal_control(&surface, || {
                let mut encoder = KeyEncoder::new()?;
                let mut encoded = Vec::new();
                surface.scroll_to_bottom()?;
                surface.try_with_terminal(|terminal| {
                    encoder.sync_from_terminal(terminal);
                    encoder.encode(&input, &mut encoded)
                })??;
                if !encoded.is_empty() {
                    surface.write_bytes(&encoded)?;
                }
                Ok(json!({ "encoded_bytes": encoded.len() }))
            })
        }
        Command::TerminalMouse {
            surface,
            action,
            button,
            modifiers,
            x,
            y,
            viewport_width,
            viewport_height,
            cell_width,
            cell_height,
            padding_left,
            padding_top,
            padding_right,
            padding_bottom,
            any_button_pressed,
            click_count,
        } => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)
                .map_err(|_| anyhow::anyhow!("surface does not support mouse input"))?;
            if modifiers & !TERMINAL_KEY_MODIFIERS_MASK != 0 {
                anyhow::bail!("bad request: invalid terminal mouse modifiers");
            }
            if !x.is_finite() || !y.is_finite() {
                anyhow::bail!("bad request: terminal mouse coordinates must be finite");
            }
            if !(1..=3).contains(&click_count) {
                anyhow::bail!("bad request: terminal mouse click_count must be 1, 2, or 3");
            }
            if viewport_width == 0
                || viewport_height == 0
                || cell_width == 0
                || cell_height == 0
                || padding_left.saturating_add(padding_right) >= viewport_width
                || padding_top.saturating_add(padding_bottom) >= viewport_height
            {
                anyhow::bail!("bad request: invalid terminal mouse geometry");
            }
            let action = match action.as_str() {
                "press" => MouseAction::Press,
                "release" => MouseAction::Release,
                "motion" => MouseAction::Motion,
                other => anyhow::bail!("bad request: unknown terminal mouse action {other:?}"),
            };
            let button = match button.as_deref() {
                None => None,
                Some("left") => Some(MouseButton::Left),
                Some("right") => Some(MouseButton::Right),
                Some("middle") => Some(MouseButton::Middle),
                Some("wheel-up") => Some(MouseButton::WheelUp),
                Some("wheel-down") => Some(MouseButton::WheelDown),
                Some("wheel-left") => Some(MouseButton::WheelLeft),
                Some("wheel-right") => Some(MouseButton::WheelRight),
                Some(other) => {
                    anyhow::bail!("bad request: unknown terminal mouse button {other:?}")
                }
            };
            if action != MouseAction::Motion && button.is_none() {
                anyhow::bail!("bad request: terminal mouse press/release requires a button");
            }
            mux.with_legacy_terminal_control(&surface, || {
                let mouse_tracking =
                    surface.try_with_terminal(|terminal| terminal.mouse_tracking())?;
                if !mouse_tracking {
                    if matches!(button, Some(MouseButton::WheelUp | MouseButton::WheelDown)) {
                        let delta = if button == Some(MouseButton::WheelUp) { -3 } else { 3 };
                        surface.scroll_delta(delta)?;
                        let snapshot = surface.terminal_interaction_snapshot()?;
                        return Ok(json!({
                            "encoded_bytes": 0,
                            "route": "scrollback",
                            "handled": true,
                            "state": terminal_interaction_json(surface.uuid, &snapshot),
                        }));
                    }
                    let selects = button == Some(MouseButton::Left)
                        || (action == MouseAction::Motion && any_button_pressed);
                    let snapshot = if selects {
                        let columns = surface.size().0.max(1);
                        let rows = surface.size().1.max(1);
                        let local_x = (x - padding_left as f32).max(0.0);
                        let local_y = (y - padding_top as f32).max(0.0);
                        let column = ((local_x / cell_width as f32).floor() as u16)
                            .min(columns.saturating_sub(1));
                        let viewport_row = ((local_y / cell_height as f32).floor() as u16)
                            .min(rows.saturating_sub(1));
                        let current = surface.terminal_interaction_snapshot()?;
                        let offset = current.viewport.map_or(0, |viewport| viewport.offset);
                        let row = u32::try_from(offset.saturating_add(u64::from(viewport_row)))
                            .unwrap_or(u32::MAX);
                        let autoscroll = if action == MouseAction::Motion && any_button_pressed {
                            if y < padding_top as f32 {
                                Some(MouseSelectionAutoscrollDirection::Up)
                            } else if y >= viewport_height.saturating_sub(padding_bottom) as f32 {
                                Some(MouseSelectionAutoscrollDirection::Down)
                            } else {
                                None
                            }
                        } else {
                            None
                        };
                        let (handled, snapshot) = surface.terminal_mouse_selection(
                            action,
                            ghostty_vt::SelectionPoint { column, row },
                            click_count,
                            autoscroll,
                        )?;
                        return Ok(json!({
                            "encoded_bytes": 0,
                            "route": "selection",
                            "handled": handled,
                            "state": terminal_interaction_json(surface.uuid, &snapshot),
                        }));
                    } else {
                        surface.terminal_interaction_snapshot()?
                    };
                    return Ok(json!({
                        "encoded_bytes": 0,
                        "route": "selection",
                        "handled": false,
                        "state": terminal_interaction_json(surface.uuid, &snapshot),
                    }));
                }
                let input = MouseInput {
                    action,
                    button,
                    mods: Mods(modifiers),
                    position: (x - padding_left as f32, y - padding_top as f32),
                    screen_size: (
                        viewport_width - padding_left - padding_right,
                        viewport_height - padding_top - padding_bottom,
                    ),
                    cell_size: (cell_width, cell_height),
                    any_button_pressed,
                };
                let mut encoded = Vec::new();
                let result = if action == MouseAction::Release {
                    surface.encode_mouse_release(input, &mut encoded)
                } else {
                    surface.encode_mouse(input, &mut encoded)
                }
                .ok_or_else(|| anyhow::anyhow!("terminal mouse encoder is busy"))?;
                result?;
                if !encoded.is_empty() {
                    surface.write_bytes(&encoded)?;
                }
                Ok(json!({ "encoded_bytes": encoded.len(), "route": "application" }))
            })
        }
        Command::TerminalState { surface_uuid } => {
            let surface = get_surface_by_uuid(mux, surface_uuid)?;
            require_pty(&surface)?;
            let snapshot = surface.terminal_interaction_snapshot()?;
            Ok(terminal_interaction_json(surface_uuid, &snapshot))
        }
        Command::TerminalSelection { surface_uuid, operation } => {
            let surface = get_surface_by_uuid(mux, surface_uuid)?;
            require_pty(&surface)?;
            let snapshot = match operation.as_str() {
                "read" => surface.terminal_interaction_snapshot()?,
                "clear" => surface.terminal_selection_clear()?,
                "select-all" => surface.terminal_selection_select_all()?,
                other => {
                    anyhow::bail!("bad request: unknown terminal selection operation {other:?}")
                }
            };
            let state = terminal_interaction_json(surface_uuid, &snapshot);
            Ok(json!({
                "selection": state["selection"].clone(),
                "state": state,
            }))
        }
        Command::TerminalCopyMode { surface_uuid, operation, adjustment, count } => {
            if count == 0 || count > TERMINAL_ACTION_MAX_REPEAT_COUNT {
                anyhow::bail!(
                    "bad request: terminal copy-mode count must be between 1 and {TERMINAL_ACTION_MAX_REPEAT_COUNT}"
                );
            }
            let surface = get_surface_by_uuid(mux, surface_uuid)?;
            require_pty(&surface)?;
            let mut clipboard_text = None;
            let snapshot = match operation.as_str() {
                "enter" => surface.terminal_copy_mode_enter()?,
                "exit" => surface.terminal_copy_mode_exit()?,
                "start-selection" => surface.terminal_copy_mode_start_selection(false, 1)?,
                "start-line-selection" => {
                    surface.terminal_copy_mode_start_selection(true, count)?
                }
                "clear-selection" => surface.terminal_copy_mode_clear_selection()?,
                "adjust" => surface.terminal_copy_mode_adjust(
                    selection_adjustment(adjustment.as_deref().ok_or_else(|| {
                        anyhow::anyhow!(
                            "bad request: terminal copy-mode adjust requires adjustment"
                        )
                    })?)?,
                    count,
                )?,
                "copy-and-exit" => {
                    let (text, snapshot) = surface.terminal_copy_mode_copy_and_exit()?;
                    clipboard_text = text;
                    snapshot
                }
                other => {
                    anyhow::bail!("bad request: unknown terminal copy-mode operation {other:?}")
                }
            };
            Ok(terminal_action_response(surface_uuid, true, clipboard_text, &snapshot))
        }
        Command::TerminalSearch { surface_uuid, operation, query } => {
            if query.as_ref().is_some_and(|query| query.len() > TERMINAL_SEARCH_QUERY_MAX_BYTES) {
                anyhow::bail!(
                    "bad request: terminal search query exceeds {TERMINAL_SEARCH_QUERY_MAX_BYTES} bytes"
                );
            }
            let surface = get_surface_by_uuid(mux, surface_uuid)?;
            require_pty(&surface)?;
            let snapshot = match operation.as_str() {
                "start" => {
                    let snapshot = surface.terminal_search_start()?;
                    match query {
                        Some(query) => surface.terminal_search_update(query)?,
                        None => snapshot,
                    }
                }
                "update" => surface.terminal_search_update(query.ok_or_else(|| {
                    anyhow::anyhow!("bad request: terminal search update requires query")
                })?)?,
                "next" => surface.terminal_search_navigate(true)?,
                "previous" => surface.terminal_search_navigate(false)?,
                "end" => surface.terminal_search_end()?,
                other => anyhow::bail!("bad request: unknown terminal search operation {other:?}"),
            };
            Ok(terminal_action_response(surface_uuid, true, None, &snapshot))
        }
        Command::TerminalScroll { surface_uuid, operation, amount } => {
            let surface = get_surface_by_uuid(mux, surface_uuid)?;
            require_pty(&surface)?;
            match operation.as_str() {
                "lines" => surface.scroll_delta(amount.unwrap_or(1))?,
                "pages" => surface.scroll_pages(amount.unwrap_or(1))?,
                "top" => surface.scroll_to_top()?,
                "bottom" => surface.scroll_to_bottom()?,
                other => anyhow::bail!("bad request: unknown terminal scroll operation {other:?}"),
            }
            let snapshot = surface.terminal_interaction_snapshot()?;
            Ok(terminal_action_response(surface_uuid, true, None, &snapshot))
        }
        Command::TerminalBindingAction { surface_uuid, action, repeat_count } => {
            if action.is_empty() || action.len() > TERMINAL_SEARCH_QUERY_MAX_BYTES {
                anyhow::bail!("bad request: invalid terminal binding action length");
            }
            if repeat_count == 0 || repeat_count > TERMINAL_ACTION_MAX_REPEAT_COUNT {
                anyhow::bail!(
                    "bad request: terminal binding repeat_count must be between 1 and {TERMINAL_ACTION_MAX_REPEAT_COUNT}"
                );
            }
            let surface = get_surface_by_uuid(mux, surface_uuid)?;
            require_pty(&surface)?;
            let mut handled = true;
            let mut clipboard_text = None;
            for _ in 0..repeat_count {
                match action.as_str() {
                    "copy_to_clipboard" => {
                        clipboard_text = surface
                            .terminal_interaction_snapshot()?
                            .selection
                            .map(|selection| selection.text);
                        handled = clipboard_text.is_some();
                        break;
                    }
                    "scroll_to_top" => surface.scroll_to_top()?,
                    "scroll_to_bottom" => surface.scroll_to_bottom()?,
                    "scroll_page_up" => surface.scroll_pages(-1)?,
                    "scroll_page_down" => surface.scroll_pages(1)?,
                    "start_search" => {
                        surface.terminal_search_start()?;
                    }
                    "end_search" => {
                        surface.terminal_search_end()?;
                    }
                    "search:next" | "navigate_search:next" => {
                        surface.terminal_search_navigate(true)?;
                    }
                    "search:previous" | "navigate_search:previous" => {
                        surface.terminal_search_navigate(false)?;
                    }
                    "search_selection" => {
                        let query = surface
                            .terminal_interaction_snapshot()?
                            .selection
                            .map(|selection| selection.text)
                            .filter(|query| !query.is_empty());
                        if let Some(query) = query {
                            surface.terminal_search_update(query)?;
                        } else {
                            handled = false;
                        }
                    }
                    "select_all" => {
                        surface.terminal_selection_select_all()?;
                    }
                    "clear_selection" => {
                        surface.terminal_selection_clear()?;
                    }
                    _ if action.starts_with("scroll_page_lines:") => {
                        let amount =
                            action["scroll_page_lines:".len()..].parse::<isize>().map_err(
                                |_| anyhow::anyhow!("bad request: invalid scroll line count"),
                            )?;
                        surface.scroll_delta(amount)?;
                    }
                    _ if action.starts_with("scroll_page_fractional:") => {
                        let fraction = action["scroll_page_fractional:".len()..]
                            .parse::<f64>()
                            .map_err(|_| anyhow::anyhow!("bad request: invalid scroll fraction"))?;
                        if !fraction.is_finite() {
                            anyhow::bail!("bad request: invalid scroll fraction");
                        }
                        let rows = f64::from(surface.size().1);
                        let lines = (rows * fraction).trunc();
                        let lines = lines.clamp(isize::MIN as f64, isize::MAX as f64) as isize;
                        surface.scroll_delta(lines)?;
                    }
                    _ if action.starts_with("scroll_to_row:") => {
                        let row = action["scroll_to_row:".len()..]
                            .parse::<u64>()
                            .map_err(|_| anyhow::anyhow!("bad request: invalid scroll row"))?;
                        surface.scroll_to_row(row)?;
                    }
                    _ if action.starts_with("search:") => {
                        let query = action["search:".len()..].to_owned();
                        surface.terminal_search_update(query)?;
                    }
                    _ => {
                        handled = false;
                        break;
                    }
                }
            }
            let snapshot = surface.terminal_interaction_snapshot()?;
            Ok(terminal_action_response(surface_uuid, handled, clipboard_text, &snapshot))
        }
        Command::Copy { surface, mode } => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)?;
            let text = match mode.as_str() {
                "screen" => surface.try_with_terminal(|t| t.viewport_text())??,
                "scrollback" => surface.try_with_terminal(|t| t.plain_text())??,
                "selection" => {
                    surface.selection_text().ok_or_else(|| anyhow::anyhow!("no selection"))?
                }
                other => anyhow::bail!("bad mode {other}"),
            };
            Ok(json!({ "text": text, "mode": mode }))
        }
        Command::Ids { kind } => mux.with_state(|state| ids_json(state, kind.as_deref())),
        Command::Notify { title, body, level, surface } => {
            if title.is_empty() {
                anyhow::bail!("title is required");
            }
            let level = parse_notification_level(level.as_deref().unwrap_or("info"))?;
            if let Some(surface) = surface {
                get_surface(mux, surface)?;
            }
            let notification = mux.post_notification(title, body, level, surface)?;
            Ok(json!({ "notification": notification }))
        }
        Command::ListAgents { surface, state } => {
            if let Some(surface) = surface {
                get_surface(mux, surface)?;
            }
            let state = match state {
                Some(state) => Some(parse_agent_state(&state)?),
                None => None,
            };
            let agents = mux.list_agents(surface, state).iter().map(agent_json).collect::<Vec<_>>();
            Ok(json!({ "agents": agents }))
        }
        Command::ReportAgent { surface, state, source, session } => {
            get_surface(mux, surface)?;
            let state = parse_agent_state(&state)?;
            let source = parse_agent_source(&source)?;
            let record = mux.report_agent(surface, state, source, session);
            Ok(json!({
                "surface": record.surface,
                "state": record.state.as_str(),
                "source": record.source.as_str(),
                "session": record.session,
            }))
        }
        Command::VtState { surface } => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)?;
            let (cols, rows, replay) = surface.try_with_terminal(|t| {
                t.vt_replay_bounded(crate::surface::VT_REPLAY_MAX_BYTES)
                    .map(|replay| (t.cols(), t.rows(), replay))
            })??;
            Ok(json!({
                "cols": cols,
                "rows": rows,
                "data": base64::engine::general_purpose::STANDARD.encode(replay),
            }))
        }
        Command::NewTab {
            pane,
            cwd,
            argv,
            command,
            env,
            initial_input,
            wait_after_command,
            cols,
            rows,
        } => {
            let launch =
                terminal_launch_request(cwd, argv, command, env, initial_input, wait_after_command);
            let surface =
                mux.new_tab_with_launch(pane, optional_surface_size(cols, rows), launch)?;
            surface_placement_json(mux, surface.id)
        }
        Command::NewBrowserTab { url, pane, cols, rows } => {
            let surface = mux.new_browser_tab(url, pane, optional_surface_size(cols, rows))?;
            surface_placement_json(mux, surface.id)
        }
        Command::SetCellPixels { width_px, height_px } => {
            let update = mux.set_cell_pixel_size(width_px, height_px);
            let resizes = update
                .resizes
                .into_iter()
                .map(|(surface, (cols, rows), reservation_id)| {
                    json!({
                        "surface": surface,
                        "cols": cols,
                        "rows": rows,
                        "reservation_id": reservation_id,
                    })
                })
                .collect::<Vec<_>>();
            let failures = update
                .failures
                .into_iter()
                .map(|failure| {
                    json!({
                        "surface": failure.surface,
                        "error": failure.error,
                    })
                })
                .collect::<Vec<_>>();
            Ok(json!({"resizes": resizes, "failures": failures}))
        }
        Command::BrowserMouse { surface, kind, x_px, y_px, button, click_count } => {
            let surface = get_surface(mux, surface)?;
            require_browser(&surface)?;
            let event_type = match kind.as_str() {
                "down" => "mousePressed",
                "up" => "mouseReleased",
                "move" => "mouseMoved",
                other => anyhow::bail!("bad browser mouse kind {other:?}"),
            };
            surface.browser_mouse_event(event_type, x_px, y_px, button.as_deref(), click_count)?;
            Ok(json!({}))
        }
        Command::BrowserWheel { surface, x_px, y_px, delta_y_px } => {
            let surface = get_surface(mux, surface)?;
            require_browser(&surface)?;
            surface.browser_wheel(x_px, y_px, delta_y_px)?;
            Ok(json!({}))
        }
        Command::BrowserKey {
            surface,
            kind,
            key,
            code,
            windows_virtual_key_code,
            modifiers,
            text,
        } => {
            let surface = get_surface(mux, surface)?;
            require_browser(&surface)?;
            let event_type = match kind.as_str() {
                "down" => "keyDown",
                "up" => "keyUp",
                other => anyhow::bail!("bad browser key kind {other:?}"),
            };
            surface.browser_key_event(
                event_type,
                &key,
                &code,
                windows_virtual_key_code,
                modifiers,
                text.as_deref(),
            )?;
            Ok(json!({}))
        }
        Command::BrowserInsertText { surface, text } => {
            let surface = get_surface(mux, surface)?;
            require_browser(&surface)?;
            surface.browser_insert_text(&text)?;
            Ok(json!({}))
        }
        Command::BrowserNavigate { surface, url } => {
            let surface = get_surface(mux, surface)?;
            require_browser(&surface)?;
            surface.browser_navigate(&url)?;
            Ok(json!({}))
        }
        Command::BrowserBack { surface } => {
            let surface = get_surface(mux, surface)?;
            require_browser(&surface)?;
            surface.browser_back()?;
            Ok(json!({}))
        }
        Command::BrowserForward { surface } => {
            let surface = get_surface(mux, surface)?;
            require_browser(&surface)?;
            surface.browser_forward()?;
            Ok(json!({}))
        }
        Command::BrowserReload { surface } => {
            let surface = get_surface(mux, surface)?;
            require_browser(&surface)?;
            surface.browser_reload()?;
            Ok(json!({}))
        }
        Command::BrowserActivate { surface } => {
            let surface = get_surface(mux, surface)?;
            require_browser(&surface)?;
            surface.browser_activate()?;
            Ok(json!({}))
        }
        Command::NewWorkspace {
            name,
            cwd,
            argv,
            command,
            env,
            initial_input,
            wait_after_command,
            cols,
            rows,
        } => {
            let launch =
                terminal_launch_request(cwd, argv, command, env, initial_input, wait_after_command);
            let surface =
                mux.new_workspace_with_launch(name, optional_surface_size(cols, rows), launch)?;
            surface_placement_json(mux, surface.id)
        }
        Command::CanonicalNewWorkspace {
            mutation,
            workspace_uuid,
            surface_uuid,
            name,
            cwd,
            argv,
            command,
            env,
            initial_input,
            wait_after_command,
            cols,
            rows,
        } => Ok(canonical_surface_placement_json(mux.canonical_new_workspace(
            mutation.into(),
            workspace_uuid,
            surface_uuid,
            name,
            optional_surface_size(cols, rows),
            terminal_launch_request(cwd, argv, command, env, initial_input, wait_after_command),
        )?)),
        Command::CanonicalNewTab {
            mutation,
            pane_uuid,
            surface_uuid,
            cwd,
            argv,
            command,
            env,
            initial_input,
            wait_after_command,
            cols,
            rows,
        } => Ok(canonical_surface_placement_json(mux.canonical_new_tab(
            mutation.into(),
            pane_uuid,
            surface_uuid,
            optional_surface_size(cols, rows),
            terminal_launch_request(cwd, argv, command, env, initial_input, wait_after_command),
        )?)),
        Command::CanonicalMaterializeTerminal {
            mutation,
            workspace_uuid,
            surface_uuid,
            cwd,
            argv,
            command,
            env,
            initial_input,
            wait_after_command,
            cols,
            rows,
        } => Ok(canonical_surface_placement_json(mux.canonical_materialize_terminal(
            mutation.into(),
            workspace_uuid,
            surface_uuid,
            optional_surface_size(cols, rows),
            terminal_launch_request(cwd, argv, command, env, initial_input, wait_after_command),
        )?)),
        Command::CanonicalRespawnTerminal {
            mutation,
            surface_uuid,
            cwd,
            argv,
            command,
            env,
            initial_input,
            wait_after_command,
            cols,
            rows,
        } => Ok(canonical_surface_placement_json(mux.canonical_respawn_terminal(
            mutation.into(),
            surface_uuid,
            optional_surface_size(cols, rows),
            terminal_launch_request(cwd, argv, command, env, initial_input, wait_after_command),
        )?)),
        Command::CanonicalMaterializeExternalTerminal {
            mutation,
            workspace_uuid,
            surface_uuid,
            cols,
            rows,
            no_reflow,
        } => Ok(canonical_surface_placement_json(mux.canonical_materialize_external_terminal(
            mutation.into(),
            workspace_uuid,
            surface_uuid,
            (cols, rows),
            no_reflow,
        )?)),
        Command::CanonicalNewBrowserWorkspace {
            mutation,
            workspace_uuid,
            surface_uuid,
            name,
            url,
            cols,
            rows,
        } => Ok(canonical_surface_placement_json(mux.canonical_new_browser_workspace(
            mutation.into(),
            workspace_uuid,
            surface_uuid,
            name,
            url,
            optional_surface_size(cols, rows),
        )?)),
        Command::CanonicalNewBrowserTab { mutation, pane_uuid, surface_uuid, url, cols, rows } => {
            Ok(canonical_surface_placement_json(mux.canonical_new_browser_tab(
                mutation.into(),
                pane_uuid,
                surface_uuid,
                url,
                optional_surface_size(cols, rows),
            )?))
        }
        Command::CanonicalSplitBrowserPane {
            mutation,
            pane_uuid,
            surface_uuid,
            dir,
            ratio,
            url,
            cols,
            rows,
        } => {
            let (split_dir, insert_first) = parse_canonical_split_edge(&dir)?;
            Ok(canonical_surface_placement_json(mux.canonical_split_browser_pane(
                mutation.into(),
                pane_uuid,
                surface_uuid,
                split_dir,
                insert_first,
                ratio,
                url,
                optional_surface_size(cols, rows),
            )?))
        }
        Command::ClaimExternalTerminal { surface_uuid, request_id } => {
            let _client_lifecycle = mux.control_clients.read_lifecycle();
            Ok(external_terminal_claim_json(mux.claim_external_terminal(
                surface_uuid,
                external_terminal_owner(mux, client)?,
                request_id,
            )?))
        }
        Command::ResetExternalTerminal {
            surface_uuid,
            owner_generation,
            request_id,
            output_generation,
            cols,
            rows,
            seed,
        } => {
            let _client_lifecycle = mux.control_clients.read_lifecycle();
            let seed = decode_external_terminal_payload("seed", &seed)?;
            Ok(external_terminal_output_json(mux.reset_external_terminal(
                surface_uuid,
                external_terminal_owner(mux, client)?,
                owner_generation,
                request_id,
                output_generation,
                cols,
                rows,
                &seed,
            )?))
        }
        Command::ExternalTerminalOutput {
            surface_uuid,
            owner_generation,
            request_id,
            output_generation,
            sequence,
            data,
        } => {
            let _client_lifecycle = mux.control_clients.read_lifecycle();
            let data = decode_external_terminal_payload("output", &data)?;
            Ok(external_terminal_output_json(mux.apply_external_terminal_output(
                surface_uuid,
                external_terminal_owner(mux, client)?,
                owner_generation,
                request_id,
                output_generation,
                sequence,
                &data,
            )?))
        }
        Command::DrainExternalTerminalEgress { surface_uuid, owner_generation } => {
            let _client_lifecycle = mux.control_clients.read_lifecycle();
            Ok(json!({
                "egress": base64::engine::general_purpose::STANDARD.encode(
                    mux.drain_external_terminal_egress(
                        surface_uuid,
                        external_terminal_owner(mux, client)?,
                        owner_generation,
                    )?
                ),
            }))
        }
        Command::CanonicalSplitPane {
            mutation,
            pane_uuid,
            surface_uuid,
            dir,
            ratio,
            cwd,
            argv,
            command,
            env,
            initial_input,
            wait_after_command,
            cols,
            rows,
        } => {
            let (split_dir, insert_first) = parse_canonical_split_edge(&dir)?;
            Ok(canonical_surface_placement_json(mux.canonical_split_pane(
                mutation.into(),
                pane_uuid,
                surface_uuid,
                split_dir,
                insert_first,
                ratio,
                optional_surface_size(cols, rows),
                terminal_launch_request(cwd, argv, command, env, initial_input, wait_after_command),
            )?))
        }
        Command::CanonicalSplitTab { mutation, surface_uuid, pane_uuid, dir, ratio } => {
            let (split_dir, insert_first) = parse_canonical_split_edge(&dir)?;
            Ok(canonical_surface_placement_json(mux.canonical_split_tab(
                mutation.into(),
                surface_uuid,
                pane_uuid,
                split_dir,
                insert_first,
                ratio,
            )?))
        }
        Command::CanonicalClosePane { mutation, pane_uuid } => Ok(canonical_mutation_receipt_json(
            mux.canonical_close_pane(mutation.into(), pane_uuid)?,
        )),
        Command::CanonicalCloseWorkspace { mutation, workspace_uuid } => {
            Ok(canonical_mutation_receipt_json(
                mux.canonical_close_workspace(mutation.into(), workspace_uuid)?,
            ))
        }
        Command::CanonicalRenameWorkspace { mutation, workspace_uuid, name } => {
            Ok(canonical_mutation_receipt_json(mux.canonical_rename_workspace(
                mutation.into(),
                workspace_uuid,
                name,
            )?))
        }
        Command::CanonicalRenameSurface { mutation, surface_uuid, name } => {
            Ok(canonical_mutation_receipt_json(mux.canonical_rename_surface(
                mutation.into(),
                surface_uuid,
                name,
            )?))
        }
        Command::CanonicalMoveTab { mutation, surface_uuid, pane_uuid, index } => {
            Ok(canonical_mutation_receipt_json(mux.canonical_move_tab(
                mutation.into(),
                surface_uuid,
                pane_uuid,
                index,
            )?))
        }
        Command::CanonicalReorderTabs { mutation, pane_uuid, surface_uuids } => {
            Ok(canonical_mutation_receipt_json(mux.canonical_reorder_tabs(
                mutation.into(),
                pane_uuid,
                surface_uuids,
            )?))
        }
        Command::CanonicalReorderWorkspaces { mutation, workspace_uuids } => {
            Ok(canonical_mutation_receipt_json(
                mux.canonical_reorder_workspaces(mutation.into(), workspace_uuids)?,
            ))
        }
        Command::CanonicalMoveTabToNewWorkspace {
            mutation,
            surface_uuid,
            workspace_uuid,
            name,
            index,
        } => Ok(canonical_surface_placement_json(mux.canonical_move_tab_to_new_workspace(
            mutation.into(),
            surface_uuid,
            workspace_uuid,
            name,
            index,
        )?)),
        Command::CanonicalSetSplitRatio { mutation, pane_uuid, dir, ratio } => {
            let (split_dir, insert_first) = parse_canonical_split_edge(&dir)?;
            Ok(canonical_mutation_receipt_json(mux.canonical_set_split_ratio(
                mutation.into(),
                pane_uuid,
                split_dir,
                !insert_first,
                ratio,
            )?))
        }
        Command::NewScreen { workspace, cols, rows } => {
            let surface = mux.new_screen(workspace, optional_surface_size(cols, rows))?;
            surface_placement_json(mux, surface.id)
        }
        Command::Split {
            pane,
            dir,
            ratio,
            cwd,
            argv,
            command,
            env,
            initial_input,
            wait_after_command,
            cols,
            rows,
        } => {
            let (dir, insert_first) = parse_canonical_split_edge(&dir)?;
            let surface = mux.split_with_launch(
                pane,
                dir,
                insert_first,
                ratio.unwrap_or(0.5),
                optional_surface_size(cols, rows),
                terminal_launch_request(cwd, argv, command, env, initial_input, wait_after_command),
            )?;
            surface_placement_json(mux, surface.id)
        }
        Command::SetRatio { pane, dir, ratio } => {
            let dir = parse_split_dir(&dir)?;
            if !mux.set_ratio(pane, dir, ratio) {
                anyhow::bail!("unknown pane/split {pane}");
            }
            Ok(json!({}))
        }
        Command::PaneNeighbor { pane, dir } => {
            let dir = parse_direction(&dir)?;
            let pane = mux.pane_neighbor(pane, dir)?;
            Ok(json!({ "pane": pane }))
        }
        Command::FocusDirection { pane, dir } => {
            let dir = parse_direction(&dir)?;
            let pane = mux.focus_direction(pane, dir)?;
            Ok(json!({ "pane": pane }))
        }
        Command::SwapPane { pane, dir, target } => {
            let target = match (dir, target) {
                (Some(_), Some(_)) => anyhow::bail!("use only one of dir or target"),
                (Some(dir), None) => {
                    let dir = parse_direction(&dir)?;
                    mux.pane_neighbor(pane, dir)?.ok_or_else(|| anyhow::anyhow!("no neighbor"))?
                }
                (None, Some(target)) => target,
                (None, None) => anyhow::bail!("one of dir or target is required"),
            };
            if !mux.swap_panes(pane, target) {
                anyhow::bail!("unknown pane/target");
            }
            Ok(json!({}))
        }
        Command::ZoomPane { pane, mode } => {
            let mode = parse_zoom_mode(mode)?;
            let state = mux.zoom_pane(pane, mode)?;
            Ok(json!({
                "pane": state.pane,
                "zoomed": state.zoomed,
                "zoomed_pane": state.zoomed_pane,
            }))
        }
        Command::ProcessInfo { surface } => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)?;
            Ok(json!({
                "pid": surface.process_id(),
                "command": surface.spawn_argv(),
                "cwd": surface.pwd().or_else(|| surface.spawn_cwd()),
                "tty": surface.tty_name(),
            }))
        }
        Command::MoveTab { surface, pane, index } => {
            let valid = mux.with_state(|state| {
                state.surfaces.contains_key(&surface)
                    && state.panes.contains_key(&pane)
                    && state.pane_of(surface).is_some()
            });
            if !valid {
                anyhow::bail!("unknown surface/pane");
            }
            mux.move_tab(surface, pane, index);
            Ok(json!({}))
        }
        Command::MoveWorkspace { workspace, index } => {
            if !mux.with_state(|state| state.workspaces.iter().any(|ws| ws.id == workspace)) {
                anyhow::bail!("unknown workspace");
            }
            mux.move_workspace(workspace, index);
            Ok(json!({}))
        }
        Command::SetDefaultColors { fg, bg } => {
            let current = mux.default_colors();
            let colors = DefaultColors {
                fg: match fg {
                    Some(value) => Some(parse_hex_color(&value)?),
                    None => current.fg,
                },
                bg: match bg {
                    Some(value) => Some(parse_hex_color(&value)?),
                    None => current.bg,
                },
                ..current
            };
            mux.set_default_colors(colors);
            Ok(json!({}))
        }
        Command::CloseSurface { .. }
        | Command::ClosePane { .. }
        | Command::CloseScreen { .. }
        | Command::CloseWorkspace { .. } => anyhow::bail!(
            "legacy numeric close commands are disabled; use a canonical close command with stable UUID targets, expected authority/revision, and the connection topology lease"
        ),
        Command::RenamePane { pane, name } => {
            if !mux.rename_pane(pane, name) {
                anyhow::bail!("unknown pane {pane}");
            }
            Ok(json!({}))
        }
        Command::RenameSurface { surface, name } => {
            if !mux.rename_surface(surface, name) {
                anyhow::bail!("unknown surface {surface}");
            }
            Ok(json!({}))
        }
        Command::RenameScreen { screen, name } => {
            if !mux.rename_screen(screen, name) {
                anyhow::bail!("unknown screen {screen}");
            }
            Ok(json!({}))
        }
        Command::RenameWorkspace { workspace, name } => {
            if !mux.rename_workspace(workspace, name) {
                anyhow::bail!("unknown workspace {workspace}");
            }
            Ok(json!({}))
        }
        Command::ResizeSurface { surface, cols, rows } => {
            let (cols, rows) = clamp_terminal_size(cols, rows);
            // Every live control connection participates through the same
            // client-size reducer. An unattached one-shot resize is removed
            // when its connection closes, so it cannot bypass visible viewers.
            // Recording and reducing happen under the sizing lock so a
            // concurrent detach cannot finish cleanup before this lease exists.
            let (accepted, reservation_id, attached) = mux
                .resize_surface_for_control_client_with_reservation(surface, client, cols, rows)?;
            if let Some((true, name, kind, _)) = attached {
                mux.emit(MuxEvent::ClientChanged { client, name, kind });
            }
            Ok(json!({"accepted": accepted, "reservation_id": reservation_id}))
        }
        Command::ReleaseSurfaceSize { surface } => {
            let surface_runtime = get_surface(mux, surface)?;
            mux.with_legacy_terminal_control(&surface_runtime, || {
                let attached = mux.control_clients.clear_size(client, surface);
                let had_report = mux.client_surface_size(surface, client).is_some();
                if had_report {
                    mux.remove_surface_size_client(surface, client);
                }
                let attached_changed = attached.as_ref().is_some_and(|(changed, _, _)| *changed);
                if attached_changed || (attached.is_none() && had_report) {
                    let (name, kind) = attached
                        .map(|(_, name, kind)| (name, kind))
                        .or_else(|| mux.control_clients.client_info(client))
                        .unwrap_or((None, None));
                    mux.emit(MuxEvent::ClientChanged { client, name, kind });
                }
                Ok(json!({}))
            })
        }
        Command::FocusPane { pane } => {
            if !mux.focus_pane(pane) {
                anyhow::bail!("unknown pane {pane}");
            }
            Ok(json!({}))
        }
        Command::SelectTab { pane, index, delta } => {
            mux.select_tab(pane, index, delta);
            Ok(json!({}))
        }
        Command::SelectScreen { index, delta } => {
            mux.select_screen(index, delta);
            Ok(json!({}))
        }
        Command::SelectWorkspace { index, delta } => {
            mux.select_workspace(index, delta);
            Ok(json!({}))
        }
        Command::ScrollSurface { surface, delta } => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)?;
            surface.scroll_delta(delta)?;
            Ok(json!({}))
        }
        Command::Subscribe { tree_events } => {
            let tree_deltas = match tree_events.as_deref().unwrap_or("coarse") {
                "coarse" => false,
                "deltas" => true,
                other => anyhow::bail!("bad request: unsupported tree_events {other:?}"),
            };
            let events = mux.subscribe();
            let trusted_pairing_client =
                mux.control_clients.has_permission(client, ConnectionPermission::Frontend);
            let pending_pairings =
                if trusted_pairing_client { mux.pending_pairings() } else { Vec::new() };
            let writer = writer.clone();
            let outbound_stream = writer.start_stream(&subscription_overflow_json())?;
            std::thread::Builder::new().name("mux-events-out".into()).spawn(move || {
                let mut transport_overflow = false;
                for challenge in pending_pairings {
                    let value = json!({
                        "event": "pairing-requested",
                        "request": challenge.id,
                        "code": challenge.code,
                        "peer": challenge.peer,
                        "expires_in": challenge.expires_in,
                    });
                    if let Err(error) = writer.send_stream(&value, &outbound_stream) {
                        transport_overflow = error.kind() == std::io::ErrorKind::WouldBlock;
                        break;
                    }
                }
                while writer.is_open() && outbound_stream.is_open() {
                    let event = match events.recv_timeout(STREAM_DISCONNECT_POLL) {
                        Ok(event) => event,
                        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                    };
                    let value = match &event {
                        MuxEvent::PairingRequested(_) | MuxEvent::PairingResolved { .. }
                            if !trusted_pairing_client =>
                        {
                            continue;
                        }
                        MuxEvent::PairingRequested(challenge) => json!({
                            "event": "pairing-requested",
                            "request": challenge.id,
                            "code": challenge.code,
                            "peer": challenge.peer,
                            "expires_in": challenge.expires_in,
                        }),
                        MuxEvent::PairingResolved { request } => json!({
                            "event": "pairing-resolved",
                            "request": request,
                        }),
                        MuxEvent::TreeDelta(delta) if tree_deltas => tree_delta_json(delta),
                        MuxEvent::TreeDelta(_) => json!({"event": "tree-changed"}),
                        _ => subscribed_event_json(&event),
                    };
                    if let Err(error) = writer.send_stream(&value, &outbound_stream) {
                        transport_overflow = error.kind() == std::io::ErrorKind::WouldBlock;
                        break;
                    }
                }
                if events.overflowed() || transport_overflow {
                    let _ = writer.send_terminal(&subscription_overflow_json(), &outbound_stream);
                }
            })?;
            Ok(json!({}))
        }
        Command::SubscribeTopology { daemon_instance_id, session_id, revision } => {
            // Reserve connection/global capacity before the journal allocates
            // and registers a mailbox. Otherwise repeated duplicate requests
            // can leave an unbounded list of dead weak subscribers.
            let permit = mux.control_clients.claim_topology_stream(client)?;
            let activity_stream = mux
                .control_clients
                .stable_reader_uuid(client)
                .map(|reader_uuid| (reader_uuid, mux.subscribe_terminal_activity()));
            match mux.subscribe_topology(daemon_instance_id, session_id, revision) {
                TopologyResume::ResnapshotRequired(required) => {
                    mux.control_clients.cancel_topology_claim(client);
                    drop(permit);
                    Ok(json!({
                        "status": "resnapshot-required",
                        "daemon_instance_id": required.daemon_instance_id,
                        "session_id": required.session_id,
                        "current_revision": required.current_revision,
                        "reason": required.reason.as_str(),
                    }))
                }
                TopologyResume::Subscribed(subscription) => {
                    let overflow = json!({
                        "event": "topology-resnapshot-required",
                        "daemon_instance_id": subscription.daemon_instance_id,
                        "session_id": subscription.session_id,
                        "reason": "slow-consumer",
                    });
                    let outbound_stream = match writer.start_stream(&overflow) {
                        Ok(stream) => stream,
                        Err(error) => {
                            mux.control_clients.cancel_topology_claim(client);
                            drop(permit);
                            return Err(error.into());
                        }
                    };
                    let response = json!({
                        "status": "subscribed",
                        "daemon_instance_id": subscription.daemon_instance_id,
                        "session_id": subscription.session_id,
                        "from_revision": subscription.from_revision,
                        "current_revision": subscription.current_revision,
                        "replayed": subscription.replayed,
                    });
                    if let Some((reader_uuid, activity_events)) = activity_stream {
                        if let Err(error) = spawn_terminal_activity_stream(
                            activity_events,
                            reader_uuid,
                            writer.clone(),
                            outbound_stream.clone(),
                        ) {
                            mux.control_clients.cancel_topology_claim(client);
                            drop(permit);
                            return Err(error.into());
                        }
                    }
                    let writer = writer.clone();
                    let stream_mux = mux.clone();
                    let thread = std::thread::Builder::new().name("mux-topology-out".into()).spawn(
                        move || {
                            let _permit = permit;
                            while writer.is_open() && outbound_stream.is_open() {
                                let delta = match subscription
                                    .receiver
                                    .recv_timeout(STREAM_DISCONNECT_POLL)
                                {
                                    Ok(delta) => delta,
                                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                                    Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                                };
                                let mut value = serde_json::to_value(delta.as_ref())
                                    .expect("canonical topology delta serializes");
                                value["event"] = json!("topology-delta");
                                if writer.send_stream(&value, &outbound_stream).is_err() {
                                    break;
                                }
                            }
                            if subscription.receiver.overflowed() && outbound_stream.is_open() {
                                let _ = writer.send_terminal(
                                    &json!({
                                        "event": "topology-resnapshot-required",
                                        "daemon_instance_id": stream_mux.daemon_instance_id,
                                        "session_id": stream_mux.session_id,
                                        "current_revision": stream_mux.canonical_topology_revision(),
                                        "reason": "slow-consumer",
                                    }),
                                    &outbound_stream,
                                );
                            }
                        },
                    );
                    if let Err(error) = thread {
                        mux.control_clients.cancel_topology_claim(client);
                        return Err(error.into());
                    }
                    Ok(response)
                }
            }
        }
        Command::AttachSurface { surface: surface_id, mode } => {
            let surface = get_surface(mux, surface_id)?;
            let lifecycle = AttachLifecycle::default();
            let outbound_stream = writer.start_stream(&attach_overflow_json(surface_id))?;
            let render_mode = match mode.as_deref().unwrap_or("bytes") {
                "bytes" => false,
                "render" => true,
                other => anyhow::bail!("bad attach mode {other}"),
            };
            if render_mode {
                require_pty(&surface)?;
                let attach = surface.attach_render_stream()?;
                if let Err(error) = writer
                    .send_initial(&render_state_json(surface_id, &attach.initial), &outbound_stream)
                {
                    handle_attach_send_error(&lifecycle, &error);
                    return Err(error.into());
                }
                mark_client_attached(mux, client, surface_id, outbound_stream.clone())?;
                let writer = writer.clone();
                let mux = mux.clone();
                std::thread::Builder::new().name("mux-render-attach-out".into()).spawn(
                    move || {
                        let mut state = RenderClientState::new(&attach.initial);
                        while writer.is_open()
                            && outbound_stream.is_open()
                            && !lifecycle.is_canceled()
                        {
                            let value = match attach.stream.recv_timeout(STREAM_DISCONNECT_POLL) {
                                Ok(RenderAttachFrame::Frame(frame)) => {
                                    state.delta_json(surface_id, &frame)
                                }
                                Ok(RenderAttachFrame::ScrollChanged { offset, at_bottom }) => {
                                    json!({
                                        "event": "scroll-changed",
                                        "surface": surface_id,
                                        "offset": offset,
                                        "at_bottom": at_bottom,
                                    })
                                }
                                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                            };
                            if let Err(error) = writer.send_stream(&value, &outbound_stream) {
                                handle_attach_send_error(&lifecycle, &error);
                                break;
                            }
                        }
                        if writer.is_open() && !lifecycle.overflowed() {
                            let _ = writer.send_stream(
                                &json!({"event": "detached", "surface": surface_id}),
                                &outbound_stream,
                            );
                        }
                        report_attach_overflow(&writer, surface_id, &lifecycle, &outbound_stream);
                        if mux.control_clients.detach_surface(
                            client,
                            surface_id,
                            outbound_stream.id,
                        ) {
                            mux.remove_surface_size_client(surface_id, client);
                        }
                    },
                )?;
                return Ok(json!({}));
            }
            if surface.kind() == SurfaceKind::Browser {
                let (state, frames) = match surface.attach_frames() {
                    Ok(attach) => attach,
                    Err(error) => {
                        lifecycle.cancel();
                        return Err(error);
                    }
                };
                if let Err(error) = writer
                    .send_initial(&browser_state_json(surface_id, &state, true), &outbound_stream)
                {
                    handle_attach_send_error(&lifecycle, &error);
                    return Err(error.into());
                }
                mark_client_attached(mux, client, surface_id, outbound_stream.clone())?;
                spawn_attach_notification_stream(
                    mux.clone(),
                    surface_id,
                    writer.clone(),
                    lifecycle.clone(),
                    outbound_stream.clone(),
                )?;
                let writer = writer.clone();
                let mux = mux.clone();
                std::thread::Builder::new().name("mux-attach-out".into()).spawn(move || {
                    while writer.is_open() && outbound_stream.is_open() && !lifecycle.is_canceled()
                    {
                        match frames.notify.recv_timeout(STREAM_DISCONNECT_POLL) {
                            Ok(()) => {}
                            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                                lifecycle.cancel();
                                if writer.is_open() {
                                    let _ = writer.send_stream(
                                        &json!({"event": "detached", "surface": surface_id}),
                                        &outbound_stream,
                                    );
                                }
                                break;
                            }
                        }
                        let update = std::mem::take(&mut *frames.slot.lock().unwrap());
                        if let Some(state) = update.state {
                            let value = browser_state_json(surface_id, &state, false);
                            if let Err(error) = writer.send_stream(&value, &outbound_stream) {
                                handle_attach_send_error(&lifecycle, &error);
                                break;
                            }
                        }
                        if let Some(frame) = update.frame {
                            let value = json!({
                                "event": "frame",
                                "surface": surface_id,
                                "seq": frame.seq,
                                "width": frame.css_width,
                                "height": frame.css_height,
                                "data": frame.data_b64,
                            });
                            if let Err(error) = writer.send_stream(&value, &outbound_stream) {
                                handle_attach_send_error(&lifecycle, &error);
                                break;
                            }
                        }
                    }
                    report_attach_overflow(&writer, surface_id, &lifecycle, &outbound_stream);
                    if mux.control_clients.detach_surface(client, surface_id, outbound_stream.id) {
                        mux.remove_surface_size_client(surface_id, client);
                    }
                })?;
                return Ok(json!({}));
            }
            let attach = match surface.attach_stream_with_lifecycle(lifecycle.clone()) {
                Ok(attach) => attach,
                Err(error) => {
                    lifecycle.cancel();
                    return Err(error.into());
                }
            };
            if let Err(error) = writer.send_initial(
                &json!({
                    "event": "vt-state",
                    "surface": surface_id,
                    "cols": attach.cols,
                    "rows": attach.rows,
                    "data": base64::engine::general_purpose::STANDARD.encode(attach.replay),
                    "colors": terminal_colors_json(attach.colors),
                }),
                &outbound_stream,
            ) {
                handle_attach_send_error(&lifecycle, &error);
                return Err(error.into());
            }
            mark_client_attached(mux, client, surface_id, outbound_stream.clone())?;
            spawn_attach_notification_stream(
                mux.clone(),
                surface_id,
                writer.clone(),
                lifecycle,
                outbound_stream.clone(),
            )?;
            let writer = writer.clone();
            let mux = mux.clone();
            std::thread::Builder::new().name("mux-attach-out".into()).spawn(move || {
                while writer.is_open()
                    && outbound_stream.is_open()
                    && !attach.lifecycle.is_canceled()
                {
                    let frame = match attach.stream.recv_timeout(STREAM_DISCONNECT_POLL) {
                        Ok(frame) => frame,
                        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                            attach.lifecycle.cancel();
                            if writer.is_open() {
                                let _ = writer.send_stream(
                                    &json!({"event": "detached", "surface": surface_id}),
                                    &outbound_stream,
                                );
                            }
                            break;
                        }
                    };
                    let value = match frame {
                        AttachFrame::Output(chunk) => json!({
                            "event": "output",
                            "surface": surface_id,
                            "data": base64::engine::general_purpose::STANDARD.encode(chunk),
                        }),
                        AttachFrame::Resized { cols, rows, replay } => json!({
                            "event": "resized",
                            "surface": surface_id,
                            "cols": cols,
                            "rows": rows,
                            "replay": base64::engine::general_purpose::STANDARD.encode(replay),
                        }),
                        AttachFrame::ColorsChanged(colors) => {
                            let mut value = terminal_colors_json(colors);
                            value["event"] = json!("colors-changed");
                            value["surface"] = json!(surface_id);
                            value
                        }
                    };
                    if let Err(error) = writer.send_stream(&value, &outbound_stream) {
                        handle_attach_send_error(&attach.lifecycle, &error);
                        break;
                    }
                }
                report_attach_overflow(&writer, surface_id, &attach.lifecycle, &outbound_stream);
                if mux.control_clients.detach_surface(client, surface_id, outbound_stream.id) {
                    mux.remove_surface_size_client(surface_id, client);
                }
            })?;
            Ok(json!({}))
        }
    }
}

fn subscribed_event_json(event: &MuxEvent) -> Value {
    match event {
        MuxEvent::SurfaceOutput(id) => json!({"event": "surface-output", "surface": id}),
        MuxEvent::SurfaceResized { surface, cols, rows, reservation_id } => json!({
            "event": "surface-resized",
            "surface": surface,
            "cols": cols,
            "rows": rows,
            "reservation_id": reservation_id,
        }),
        MuxEvent::SurfaceResizeFailed {
            surface,
            cols,
            rows,
            error,
            retry_after_ms,
            reservation_id,
        } => json!({
            "event": "surface-resize-failed",
            "surface": surface,
            "cols": cols,
            "rows": rows,
            "error": error.as_ref(),
            "retry_after_ms": retry_after_ms,
            "reservation_id": reservation_id,
        }),
        MuxEvent::SurfaceExited(id) => json!({"event": "surface-exited", "surface": id}),
        MuxEvent::TitleChanged { surface, title } => {
            json!({"event": "title-changed", "surface": surface, "title": title.as_ref()})
        }
        MuxEvent::Bell(id) => json!({"event": "bell", "surface": id}),
        MuxEvent::Notification(notification) => json!({
            "event": "notification",
            "notification": notification.notification,
            "title": notification.title,
            "body": notification.body,
            "level": notification.level.as_str(),
            "surface": notification.surface,
        }),
        MuxEvent::TerminalActivity(fact) => json!({
            "event": "terminal-activity",
            "surface_uuid": fact.surface_uuid,
            "sequence": fact.sequence,
            "kind": fact.kind,
            "notification": fact.notification,
            "level": fact.level,
        }),
        MuxEvent::TerminalActivityReceipt(receipt) => json!({
            "event": "terminal-activity-receipt",
            "reader_uuid": receipt.reader_uuid,
            "surface_uuid": receipt.surface_uuid,
            "seen_sequence": receipt.seen_sequence,
        }),
        MuxEvent::Status(message) => json!({"event": "status", "message": message}),
        MuxEvent::RendererWorkerChanged {
            workspace_uuid,
            prior_renderer_epoch,
            prior_process_id,
            status,
            reason,
        } => json!({
            "event": "renderer-worker-changed",
            "workspace_uuid": workspace_uuid,
            "prior_renderer_epoch": prior_renderer_epoch,
            "prior_process_id": prior_process_id,
            "renderer_epoch": status.as_ref().map(|status| status.renderer_epoch),
            "pid": status.as_ref().and_then(|status| status.pid),
            "effective_user_id": status.as_ref().and_then(|status| status.effective_user_id),
            "scene_capabilities": status.as_ref().and_then(|status| status.scene_capabilities),
            "state": status.as_ref().map(|status| status.state),
            "restart_count": status.as_ref().map(|status| status.restart_count),
            "retry_after_milliseconds": status
                .as_ref()
                .and_then(|status| status.retry_after_milliseconds),
            "reason": reason.as_deref(),
        }),
        MuxEvent::RendererPresentationReady {
            workspace_uuid,
            renderer_epoch,
            process_id,
            effective_user_id,
            metrics,
        } => json!({
            "event": "renderer-presentation-ready",
            "workspace_uuid": workspace_uuid,
            "renderer_epoch": renderer_epoch,
            "worker_pid": process_id,
            "worker_effective_user_id": effective_user_id,
            "terminal_id": metrics.terminal_id,
            "terminal_epoch": metrics.terminal_epoch,
            "presentation_id": metrics.presentation_id,
            "presentation_generation": metrics.presentation_generation,
            "canonical_sequence": metrics.canonical_sequence,
            "presentation_sequence": metrics.presentation_sequence,
            "columns": metrics.columns,
            "rows": metrics.rows,
            "cell_width": metrics.cell_width,
            "cell_height": metrics.cell_height,
            "padding": {
                "top": metrics.padding_top,
                "right": metrics.padding_right,
                "bottom": metrics.padding_bottom,
                "left": metrics.padding_left,
            },
        }),
        MuxEvent::RendererConfigInvalidated { revision, reason, default_colors } => json!({
            "event": "renderer-config-invalidated",
            "revision": revision,
            "reason": reason.as_ref(),
            "default_colors": default_colors_json(*default_colors),
        }),
        MuxEvent::ConfigReloadRequested => json!({"event": "config-reload-requested"}),
        MuxEvent::WindowTitleRequested(title) => {
            json!({"event": "window-title-requested", "title": title})
        }
        MuxEvent::ScrollChanged { surface, offset, at_bottom } => json!({
            "event": "scroll-changed",
            "surface": surface,
            "offset": offset,
            "at_bottom": at_bottom,
        }),
        MuxEvent::TreeChanged => json!({"event": "tree-changed"}),
        MuxEvent::TreeDelta(_) => json!({"event": "tree-changed"}),
        MuxEvent::LayoutChanged(screen) => json!({"event": "layout-changed", "screen": screen}),
        MuxEvent::ClientAttached { client, transport, name, kind } => json!({
            "event": "client-attached",
            "client": client,
            "transport": transport,
            "name": name,
            "kind": kind,
        }),
        MuxEvent::ClientChanged { client, name, kind } => json!({
            "event": "client-changed",
            "client": client,
            "name": name,
            "kind": kind,
        }),
        MuxEvent::ClientDetached(client) => {
            json!({"event": "client-detached", "client": client})
        }
        MuxEvent::ClientListInvalidated => json!({"event": "client-list-invalidated"}),
        MuxEvent::PairingRequested(challenge) => json!({
            "event": "pairing-requested",
            "request": challenge.id,
            "code": challenge.code,
            "peer": challenge.peer,
            "expires_in": challenge.expires_in,
        }),
        MuxEvent::PairingResolved { request } => {
            json!({"event": "pairing-resolved", "request": request})
        }
        MuxEvent::Empty => json!({"event": "empty"}),
    }
}

fn subscription_overflow_json() -> Value {
    json!({
        "event": "overflow",
        "error": "subscriber fell behind; resubscribe to continue receiving events",
    })
}

fn attach_overflow_json(surface: SurfaceId) -> Value {
    json!({
        "event": "overflow",
        "scope": "surface",
        "surface": surface,
        "error": "surface stream fell behind; reattach the surface",
    })
}

/// Remove the socket file (call on clean shutdown).
pub fn cleanup(path: &Path) {
    let _ = std::fs::remove_file(path);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::SurfaceOptions;
    use std::io::Cursor;
    use std::sync::mpsc::TryRecvError;
    use std::time::Duration;

    fn test_mux() -> Arc<Mux> {
        Mux::new_for_test("test", SurfaceOptions::default())
    }

    fn test_writer() -> MessageWriter {
        MessageWriter::new(QueuedSink {
            outbound: Arc::new(BoundedOutbound::default()),
            control: None,
        })
    }

    #[test]
    fn renderer_preedit_preserves_japanese_utf16_selection_and_rejects_invalid_ranges() {
        let preedit = parse_renderer_preedit(Some("日本語".into()), 1, 1, 2).unwrap().unwrap();
        assert_eq!(preedit.text.as_str(), "日本語");
        assert_eq!(preedit.selection_start_utf16, 1);
        assert_eq!(preedit.selection_length_utf16, 1);
        assert_eq!(preedit.caret_utf16, 2);

        assert!(parse_renderer_preedit(Some("日本語".into()), 2, 2, 2).is_err());
        assert!(parse_renderer_preedit(None, 0, 0, 1).is_err());
    }

    fn register_v9_client(mux: &Arc<Mux>, writer: &MessageWriter) -> (u64, uuid::Uuid) {
        let (client, client_uuid, _) =
            register_v9_client_kind(mux, writer, ClientTransport::Unix, "swift-shell");
        (client, client_uuid)
    }

    fn register_v9_client_kind(
        mux: &Arc<Mux>,
        writer: &MessageWriter,
        transport: ClientTransport,
        client_kind: &str,
    ) -> (u64, uuid::Uuid, Value) {
        let client = mux.control_clients.register(transport, writer.clone());
        let client_uuid = uuid::Uuid::new_v4();
        let result = handle_command(
            mux,
            client,
            Command::RegisterClient {
                protocol_min: 8,
                protocol_max: 9,
                client_uuid,
                process_instance_uuid: uuid::Uuid::new_v4(),
                client_kind: Some(client_kind.to_owned()),
            },
            writer,
        )
        .unwrap();
        assert_eq!(result["protocol"], 9);
        uuid::Uuid::parse_str(result["connection_id"].as_str().unwrap()).unwrap();
        (client, client_uuid, result)
    }

    #[cfg(unix)]
    #[test]
    fn explicit_socket_path_requires_a_dedicated_private_parent_without_chmod() {
        use std::os::unix::fs::PermissionsExt;

        let root = std::env::temp_dir().join(format!(
            "cmux-socket-boundary-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir(&root).unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o755)).unwrap();

        let unsafe_path = root.join("daemon.sock");
        let error = prepare_socket_path(&unsafe_path).unwrap_err();
        assert!(error.to_string().contains("found 0755"), "unexpected error: {error}");
        assert_eq!(std::fs::symlink_metadata(&root).unwrap().permissions().mode() & 0o777, 0o755);
        assert!(!unsafe_path.exists());

        let private = root.join("private");
        let safe_path = private.join("daemon.sock");
        prepare_socket_path(&safe_path).unwrap();
        assert_eq!(
            std::fs::symlink_metadata(&private).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert!(!safe_path.exists());

        std::fs::remove_dir(&private).unwrap();
        std::fs::remove_dir(&root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn explicit_socket_path_rejects_symlink_without_touching_target() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "cmux-socket-symlink-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        let private = root.join("private");
        platform::ensure_private_directory(&private).unwrap();
        let target = root.join("target");
        std::fs::write(&target, b"caller-owned").unwrap();
        let socket = private.join("daemon.sock");
        symlink(&target, &socket).unwrap();

        let error = prepare_socket_path(&socket).unwrap_err();
        assert!(error.to_string().contains("symbolic link"), "unexpected error: {error}");
        assert_eq!(std::fs::read(&target).unwrap(), b"caller-owned");
        assert!(std::fs::symlink_metadata(&socket).unwrap().file_type().is_symlink());

        std::fs::remove_file(&socket).unwrap();
        std::fs::remove_file(&target).unwrap();
        std::fs::remove_dir(&private).unwrap();
        std::fs::remove_dir(&root).unwrap();
    }

    fn open_visible_terminal_presentation(
        mux: &Arc<Mux>,
        writer: &MessageWriter,
        client: u64,
        surface_uuid: SurfaceUuid,
    ) -> (PresentationId, u64) {
        let opened = handle_command(
            mux,
            client,
            Command::OpenPresentation {
                view: PresentationView { surface_uuid: Some(surface_uuid), ..Default::default() },
                zoom: PresentationZoom::default(),
                scroll: PresentationScroll::default(),
            },
            writer,
        )
        .unwrap();
        let presentation_id = opened["presentation_id"].as_str().unwrap().parse().unwrap();
        let generation = opened["generation"].as_u64().unwrap();
        handle_command(
            mux,
            client,
            Command::ActivateTerminalPresentation {
                presentation_id,
                expected_generation: generation,
            },
            writer,
        )
        .unwrap();
        (presentation_id, generation)
    }

    #[derive(Debug, Deserialize)]
    struct ProcessInfoWireResponse {
        id: u64,
        ok: bool,
        data: ProcessInfoWireData,
    }

    #[derive(Debug, Deserialize)]
    struct ProcessInfoWireData {
        pid: u32,
        command: Vec<String>,
        cwd: Option<String>,
        tty: String,
    }

    #[test]
    fn unix_process_info_wire_returns_exact_argv_and_canonical_tty() {
        static NEXT_SOCKET: AtomicU64 = AtomicU64::new(1);
        let mux = test_mux();
        let cwd = std::env::temp_dir().to_string_lossy().into_owned();
        let applied = mux
            .apply_layout(
                None,
                None,
                &LayoutSpec::Leaf(LayoutLeafSpec {
                    cwd: Some(cwd.clone()),
                    command: Some(vec![
                        "/bin/sh".to_owned(),
                        "-lc".to_owned(),
                        "printf exact".to_owned(),
                    ]),
                }),
                None,
            )
            .unwrap();
        let surface = mux.surface(applied.panes[0].surface).unwrap();
        let path = PathBuf::from(format!(
            "/tmp/cmux-pi-{}-{}.sock",
            std::process::id(),
            NEXT_SOCKET.fetch_add(1, Ordering::Relaxed)
        ));
        let listener = transport::listen(&path).unwrap();
        let server = std::thread::spawn(move || {
            handle_connection(mux, listener.accept().unwrap());
        });
        let mut client = transport::connect(&path).unwrap();
        let read_half = client.try_clone_box().unwrap();
        writeln!(client, "{}", json!({"id": 41, "cmd": "process-info", "surface": surface.id}))
            .unwrap();
        client.flush().unwrap();
        let mut response = String::new();
        BufReader::new(read_half).read_line(&mut response).unwrap();
        let decoded: ProcessInfoWireResponse = serde_json::from_str(&response).unwrap();

        assert_eq!(decoded.id, 41);
        assert!(decoded.ok);
        assert_eq!(decoded.data.pid, surface.id as u32);
        assert_eq!(decoded.data.command, vec!["/bin/sh", "-lc", "printf exact"]);
        assert_eq!(decoded.data.cwd.as_deref(), Some(cwd.as_str()));
        assert_eq!(decoded.data.tty, format!("/dev/ttys{}", surface.id));

        client.shutdown(Shutdown::Both).unwrap();
        server.join().unwrap();
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn bounded_line_reader_accepts_exact_limit_crlf_and_eof_frames() {
        let mut reader = BufReader::with_capacity(3, Cursor::new(b"12345678\nnext\r\nlast"));
        let mut line = Vec::new();

        assert_eq!(read_bounded_line(&mut reader, &mut line, 8).unwrap(), BoundedLineRead::Line);
        assert_eq!(line, b"12345678");
        assert_eq!(read_bounded_line(&mut reader, &mut line, 8).unwrap(), BoundedLineRead::Line);
        assert_eq!(line, b"next");
        assert_eq!(read_bounded_line(&mut reader, &mut line, 8).unwrap(), BoundedLineRead::Line);
        assert_eq!(line, b"last");
        assert_eq!(read_bounded_line(&mut reader, &mut line, 8).unwrap(), BoundedLineRead::Eof);
    }

    #[test]
    fn bounded_line_reader_rejects_an_oversized_unterminated_frame_without_overallocating() {
        let mut reader = BufReader::with_capacity(2, Cursor::new(b"123456789"));
        let mut line = Vec::new();

        assert_eq!(read_bounded_line(&mut reader, &mut line, 8).unwrap(), BoundedLineRead::TooLong);
        assert_eq!(line, b"12345678");
        assert!(line.len() <= 8);
    }

    #[test]
    fn budgeted_line_reader_never_grows_past_the_shared_budget() {
        let budget = InboundBudget::new(8);
        let mut reader = BufReader::with_capacity(2, Cursor::new(b"123456789\n"));
        let mut line = Vec::new();

        let (status, permit) = read_budgeted_line(&mut reader, &mut line, 16, &budget).unwrap();
        assert_eq!(status, BoundedLineRead::BudgetExceeded);
        let permit = permit.unwrap();
        assert_eq!(permit.bytes(), 8);
        assert_eq!(line, b"12345678");
        assert_eq!(budget.usage(), (8, 8));
        drop(permit);
        assert_eq!(budget.usage(), (0, 8));
    }

    #[test]
    fn one_budget_caps_sixty_four_mixed_transport_connections_exactly() {
        let registry = ClientRegistry::new();
        let budget = registry.inbound_budget();
        let bytes_per_connection = INBOUND_INFLIGHT_MAX_BYTES / MAX_SERVER_CONNECTIONS;
        let mut permits = Vec::new();

        for index in 0..MAX_SERVER_CONNECTIONS {
            let transport =
                if index % 2 == 0 { ClientTransport::Unix } else { ClientTransport::WebSocket };
            registry.register(transport, test_writer());
            permits.push(
                budget
                    .try_reserve(bytes_per_connection)
                    .expect("the exact 64-connection budget must fit"),
            );
        }

        assert_eq!(budget.usage(), (INBOUND_INFLIGHT_MAX_BYTES, INBOUND_INFLIGHT_MAX_BYTES));
        assert!(budget.try_reserve(1).is_none());
        permits.truncate(MAX_SERVER_CONNECTIONS / 2);
        assert_eq!(budget.usage().0, INBOUND_INFLIGHT_MAX_BYTES / 2);
        let replacement = budget.try_reserve(INBOUND_INFLIGHT_MAX_BYTES / 2).unwrap();
        assert_eq!(budget.usage(), (INBOUND_INFLIGHT_MAX_BYTES, INBOUND_INFLIGHT_MAX_BYTES));
        drop(replacement);
        drop(permits);
        assert_eq!(budget.usage(), (0, INBOUND_INFLIGHT_MAX_BYTES));
    }

    #[test]
    fn unauthenticated_json_is_bounded_and_releases_every_reservation() {
        let budget = InboundBudget::new(INBOUND_INFLIGHT_MAX_BYTES);
        let malformed = format!("{}0{}", "[".repeat(256), "]".repeat(255));
        let mut wire = budget.try_reserve(WEBSOCKET_AUTH_MAX_BYTES).unwrap();
        wire.shrink_to(malformed.len());

        let error = preflight_authentication_message(&malformed, wire)
            .err()
            .expect("malformed authentication JSON must fail");
        assert!(error.to_string().contains("bad request"));
        assert_eq!(budget.usage(), (0, WEBSOCKET_AUTH_MAX_BYTES));

        let oversized = "x".repeat(WEBSOCKET_AUTH_MAX_BYTES + 1);
        let wire = budget.try_reserve(WEBSOCKET_AUTH_MAX_BYTES).unwrap();
        let error = preflight_authentication_message(&oversized, wire)
            .err()
            .expect("oversized authentication JSON must fail");
        assert!(error.to_string().contains("authentication request exceeds"));
        assert_eq!(budget.usage().0, 0);
        assert_eq!(budget.usage().1, WEBSOCKET_AUTH_MAX_BYTES);
    }

    fn canonical_state_digest(mux: &Mux) -> [u8; 32] {
        Sha256::digest(serde_json::to_vec(&mux.topology_snapshot()).unwrap()).into()
    }

    fn test_writer_and_outbound() -> (MessageWriter, Arc<BoundedOutbound>) {
        let outbound = Arc::new(BoundedOutbound::default());
        (MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None }), outbound)
    }

    fn assert_rejected_response(outbound: &BoundedOutbound, expected: &str) {
        let response: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(response["ok"], false);
        assert!(
            response["error"].as_str().unwrap().contains(expected),
            "unexpected response: {response}"
        );
    }

    fn topology_lease(registration: &Value) -> TopologyMutationLease {
        TopologyMutationLease {
            id: registration["topology_lease_id"].as_str().unwrap().parse().unwrap(),
            generation: registration["topology_lease_generation"].as_u64().unwrap(),
        }
    }

    fn canonical_close_pane_message(
        mux: &Mux,
        lease: TopologyMutationLease,
        request_id: uuid::Uuid,
    ) -> String {
        json!({
            "id": 41,
            "cmd": "canonical-close-pane",
            "request_id": request_id,
            "daemon_instance_id": mux.daemon_instance_id,
            "session_id": mux.session_id,
            "expected_revision": mux.canonical_topology_revision(),
            "topology_lease_id": lease.id,
            "topology_lease_generation": lease.generation,
            "pane_uuid": crate::PaneUuid::new(),
        })
        .to_string()
    }

    #[test]
    fn command_admission_is_fail_closed_with_an_explicit_read_only_allowlist() {
        for command in [
            "identify",
            "ping",
            "register-client",
            "topology-snapshot",
            "terminal-activity-snapshot",
            "list-workspaces",
            "export-layout",
            "read-screen",
            "read-scrollback",
            "wait-for",
            "terminal-state",
            "ids",
            "list-agents",
            "vt-state",
            "pane-neighbor",
            "process-info",
            "subscribe",
            "subscribe-topology",
            "attach-surface",
        ] {
            assert_eq!(command_admission_policy(command).permission, None, "{command}");
        }
        for command in [
            "focus-direction",
            "terminal-input",
            "terminal-geometry",
            "set-client-info",
            "new-workspace",
            "close-workspace",
            "future-unclassified-command",
        ] {
            assert_eq!(
                command_admission_policy(command).permission,
                Some(ConnectionPermission::Control),
                "{command}"
            );
        }
        for command in [
            "open-presentation",
            "renderer-workers",
            "configure-renderer-presentation",
            "list-clients",
            "pairing-response",
            "claim-external-terminal",
            "reset-external-terminal",
            "external-terminal-output",
            "drain-external-terminal-egress",
        ] {
            assert_eq!(
                command_admission_policy(command).permission,
                Some(ConnectionPermission::Frontend),
                "{command}"
            );
        }
    }

    #[test]
    fn hostile_json_is_rejected_before_state_mutation_or_typed_tree_allocation() {
        let mux = test_mux();
        let (writer, outbound) = test_writer_and_outbound();
        let (client, _) = register_v9_client(&mux, &writer);
        let before = canonical_state_digest(&mux);

        let tiny_values = std::iter::repeat_n("\"\"", 20_000).collect::<Vec<_>>().join(",");
        let huge_array =
            format!("{{\"id\":1,\"cmd\":\"send-key\",\"surface\":1,\"keys\":[{tiny_values}]}}");
        assert_eq!(huge_array.len(), 60_046);
        assert!(handle_message(&mux, client, &huge_array, &writer));
        assert_rejected_response(&outbound, "decoded request exceeds");

        let huge_string = format!(
            "{{\"id\":2,\"cmd\":\"set-window-title\",\"title\":\"{}\"}}",
            "x".repeat(STANDARD_COMMAND_MAX_BYTES)
        );
        assert!(handle_message(&mux, client, &huge_string, &writer));
        assert_rejected_response(&outbound, "wire limit");

        let malformed_nesting = format!(
            "{{\"id\":3,\"cmd\":\"apply-layout\",\"layout\":{}0{}}}",
            "[".repeat(256),
            "]".repeat(255)
        );
        assert!(handle_message(&mux, client, &malformed_nesting, &writer));
        assert_rejected_response(&outbound, "bad request");

        assert_eq!(canonical_state_digest(&mux), before);
        assert_eq!(mux.canonical_topology_revision(), 0);
        assert_eq!(
            mux.control_clients.inbound_budget().usage(),
            (0, huge_array.len() * 2),
            "hostile structural traversal may reserve only wire plus scratch, never a typed tree"
        );
    }

    #[test]
    fn stale_protocol_and_remote_local_only_commands_fail_before_decode_admission() {
        let mux = test_mux();
        let (writer, outbound) = test_writer_and_outbound();
        let stale = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        handle_command(
            &mux,
            stale,
            Command::RegisterClient {
                protocol_min: 8,
                protocol_max: 8,
                client_uuid: uuid::Uuid::new_v4(),
                process_instance_uuid: uuid::Uuid::new_v4(),
                client_kind: None,
            },
            &writer,
        )
        .unwrap();
        let before = canonical_state_digest(&mux);
        let before_budget = mux.control_clients.inbound_budget().usage();
        let stale_request = format!(
            "{{\"cmd\":\"terminal-input\",\"input\":{{\"type\":\"text\",\"text\":\"{}\"}}}}",
            "x".repeat(1024 * 1024)
        );
        assert!(handle_message(&mux, stale, &stale_request, &writer));
        assert_rejected_response(&outbound, "registered protocol v9 capability");
        assert_eq!(mux.control_clients.inbound_budget().usage(), before_budget);

        let remote = mux.control_clients.register(ClientTransport::WebSocket, writer.clone());
        let remote_request = json!({"cmd": "ensure-terminals", "terminals": []}).to_string();
        assert!(handle_message(&mux, remote, &remote_request, &writer));
        assert_rejected_response(&outbound, "same-UID trusted frontend or automation");
        assert_eq!(mux.control_clients.inbound_budget().usage(), before_budget);
        assert_eq!(canonical_state_digest(&mux), before);
    }

    #[test]
    fn web_unaffiliated_and_renderer_roles_cannot_mutate_topology_or_terminals() {
        let mux = test_mux();
        let before = canonical_state_digest(&mux);
        let before_revision = mux.canonical_topology_revision();

        let (web_writer, web_outbound) = test_writer_and_outbound();
        let (web, _, web_registration) =
            register_v9_client_kind(&mux, &web_writer, ClientTransport::WebSocket, "swift-shell");
        assert_eq!(web_registration["role"], "remote-read-only");
        assert!(web_registration["topology_lease_id"].is_null());
        assert!(handle_message(
            &mux,
            web,
            &json!({"cmd": "canonical-close-pane"}).to_string(),
            &web_writer,
        ));
        assert_rejected_response(&web_outbound, "trusted frontend or automation");

        let (unaffiliated_writer, unaffiliated_outbound) = test_writer_and_outbound();
        let unaffiliated =
            mux.control_clients.register(ClientTransport::Unix, unaffiliated_writer.clone());
        assert!(handle_message(
            &mux,
            unaffiliated,
            &json!({"cmd": "close-workspace"}).to_string(),
            &unaffiliated_writer,
        ));
        assert_rejected_response(&unaffiliated_outbound, "trusted frontend or automation");
        assert!(handle_message(
            &mux,
            unaffiliated,
            &json!({"cmd": "focus-direction"}).to_string(),
            &unaffiliated_writer,
        ));
        assert_rejected_response(&unaffiliated_outbound, "trusted frontend or automation");

        let (renderer_writer, renderer_outbound) = test_writer_and_outbound();
        let (renderer, _, renderer_registration) = register_v9_client_kind(
            &mux,
            &renderer_writer,
            ClientTransport::Unix,
            "renderer-worker",
        );
        assert_eq!(renderer_registration["role"], "trusted-renderer");
        assert!(renderer_registration["topology_lease_id"].is_null());
        assert!(handle_message(
            &mux,
            renderer,
            &json!({"cmd": "terminal-input"}).to_string(),
            &renderer_writer,
        ));
        assert_rejected_response(&renderer_outbound, "trusted frontend or automation");

        assert_eq!(canonical_state_digest(&mux), before);
        assert_eq!(mux.canonical_topology_revision(), before_revision);
    }

    #[test]
    fn canonical_topology_lease_is_connection_bound_and_generation_fenced() {
        let mux = test_mux();
        let before = canonical_state_digest(&mux);
        let before_revision = mux.canonical_topology_revision();
        let (first_writer, _) = test_writer_and_outbound();
        let (_, _, first_registration) =
            register_v9_client_kind(&mux, &first_writer, ClientTransport::Unix, "swift-shell");
        let first_lease = topology_lease(&first_registration);

        let (second_writer, second_outbound) = test_writer_and_outbound();
        let (second, _, second_registration) =
            register_v9_client_kind(&mux, &second_writer, ClientTransport::Unix, "swift-shell");
        let second_lease = topology_lease(&second_registration);
        assert_ne!(first_lease.id, second_lease.id);

        let cross_connection =
            canonical_close_pane_message(&mux, first_lease, uuid::Uuid::new_v4());
        assert!(handle_message(&mux, second, &cross_connection, &second_writer));
        assert_rejected_response(&second_outbound, "does not belong to this connection");

        let stale_generation = canonical_close_pane_message(
            &mux,
            TopologyMutationLease { id: second_lease.id, generation: second_lease.generation + 1 },
            uuid::Uuid::new_v4(),
        );
        assert!(handle_message(&mux, second, &stale_generation, &second_writer));
        assert_rejected_response(&second_outbound, "stale canonical topology mutation lease");

        assert_eq!(canonical_state_digest(&mux), before);
        assert_eq!(mux.canonical_topology_revision(), before_revision);
    }

    #[test]
    fn external_terminal_wire_has_no_child_and_fences_owner_generation_and_sequence() {
        let mux = test_mux();
        mux.new_workspace(Some("remote".into()), Some((80, 24))).unwrap();
        let workspace_uuid = mux.topology_snapshot().topology["workspaces"][0]["uuid"]
            .as_str()
            .unwrap()
            .parse::<WorkspaceUuid>()
            .unwrap();
        let surface_uuid = SurfaceUuid::new();
        let request_id = uuid::Uuid::new_v4();
        let (writer, outbound) = test_writer_and_outbound();
        let (client, _, registration) =
            register_v9_client_kind(&mux, &writer, ClientTransport::Unix, "swift-shell");
        let lease = topology_lease(&registration);
        let base_revision = mux.canonical_topology_revision();
        let materialize = json!({
            "id": 51,
            "cmd": "canonical-materialize-external-terminal",
            "request_id": request_id,
            "daemon_instance_id": mux.daemon_instance_id,
            "session_id": mux.session_id,
            "expected_revision": base_revision,
            "topology_lease_id": lease.id,
            "topology_lease_generation": lease.generation,
            "workspace_uuid": workspace_uuid,
            "surface_uuid": surface_uuid,
            "cols": 80,
            "rows": 24,
            "no_reflow": true,
        })
        .to_string();
        assert!(handle_message(&mux, client, &materialize, &writer));
        let created: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(created["ok"], true);
        assert_eq!(created["data"]["surface_uuid"], surface_uuid.to_string());
        let surface_id = created["data"]["surface"].as_u64().unwrap();
        let surface = mux.surface(surface_id).unwrap();
        assert!(surface.is_external_terminal());
        assert_eq!(surface.process_id(), None);
        assert_eq!(surface.tty_name(), None);

        assert!(handle_message(&mux, client, &materialize, &writer));
        let replayed: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(replayed["data"]["replayed"], true);

        let claim_request = uuid::Uuid::new_v4();
        assert!(handle_message(
            &mux,
            client,
            &json!({
                "id": 52,
                "cmd": "claim-external-terminal",
                "surface_uuid": surface_uuid,
                "request_id": claim_request,
            })
            .to_string(),
            &writer,
        ));
        let claim: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        let owner_generation = claim["data"]["owner_generation"].as_u64().unwrap();
        let output_generation = claim["data"]["required_output_generation"].as_u64().unwrap();

        assert!(handle_message(
            &mux,
            client,
            &json!({
                "id": 53,
                "cmd": "reset-external-terminal",
                "surface_uuid": surface_uuid,
                "owner_generation": owner_generation,
                "request_id": uuid::Uuid::new_v4(),
                "output_generation": output_generation,
                "cols": 80,
                "rows": 24,
                "seed": base64::engine::general_purpose::STANDARD.encode(b"seed"),
            })
            .to_string(),
            &writer,
        ));
        let reset: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(reset["data"]["accepted_sequence"], 0);
        assert_eq!(reset["data"]["next_sequence"], 1);

        let output_request = uuid::Uuid::new_v4();
        let output = json!({
            "id": 54,
            "cmd": "external-terminal-output",
            "surface_uuid": surface_uuid,
            "owner_generation": owner_generation,
            "request_id": output_request,
            "output_generation": output_generation,
            "sequence": 1,
            "data": base64::engine::general_purpose::STANDARD.encode(b" next"),
        })
        .to_string();
        assert!(handle_message(&mux, client, &output, &writer));
        let accepted: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(accepted["data"]["accepted_sequence"], 1);
        assert_eq!(accepted["data"]["next_sequence"], 2);

        let retired_owner = external_terminal_owner(&mux, client).unwrap();
        assert!(disconnect_client(&mux, client, false));
        let disconnected = handle_command(
            &mux,
            client,
            Command::ExternalTerminalOutput {
                surface_uuid,
                owner_generation,
                request_id: uuid::Uuid::new_v4(),
                output_generation,
                sequence: 2,
                data: base64::engine::general_purpose::STANDARD.encode(b"disconnected"),
            },
            &writer,
        );
        assert!(disconnected.unwrap_err().to_string().contains("unknown client"));

        let (replacement_writer, replacement_outbound) = test_writer_and_outbound();
        let (replacement, _, _) = register_v9_client_kind(
            &mux,
            &replacement_writer,
            ClientTransport::Unix,
            "swift-shell",
        );
        assert!(handle_message(
            &mux,
            replacement,
            &json!({
                "id": 55,
                "cmd": "claim-external-terminal",
                "surface_uuid": surface_uuid,
                "request_id": uuid::Uuid::new_v4(),
            })
            .to_string(),
            &replacement_writer,
        ));
        let replacement_claim: Value =
            serde_json::from_str(&replacement_outbound.try_pop().unwrap()).unwrap();
        assert!(replacement_claim["data"]["owner_generation"].as_u64().unwrap() > owner_generation);

        let stale_queued_output = mux.apply_external_terminal_output(
            surface_uuid,
            retired_owner,
            owner_generation,
            uuid::Uuid::new_v4(),
            output_generation,
            2,
            b"stale queued output",
        );
        assert!(stale_queued_output.unwrap_err().to_string().contains("owner changed"));
    }

    #[test]
    fn canonical_browser_workspace_wire_commits_frontend_optional_projection_once() {
        let mux = test_mux();
        let workspace_uuid = WorkspaceUuid::new();
        let surface_uuid = SurfaceUuid::new();
        let request_id = uuid::Uuid::new_v4();
        let (writer, outbound) = test_writer_and_outbound();
        let (client, _, registration) =
            register_v9_client_kind(&mux, &writer, ClientTransport::Unix, "swift-shell");
        let lease = topology_lease(&registration);
        let message = json!({
            "id": 61,
            "cmd": "canonical-new-browser-workspace",
            "request_id": request_id,
            "daemon_instance_id": mux.daemon_instance_id,
            "session_id": mux.session_id,
            "expected_revision": 0,
            "topology_lease_id": lease.id,
            "topology_lease_generation": lease.generation,
            "workspace_uuid": workspace_uuid,
            "surface_uuid": surface_uuid,
            "name": "browser",
            "url": "about:blank",
            "cols": 100,
            "rows": 35,
        })
        .to_string();

        assert!(handle_message(&mux, client, &message, &writer));
        let created: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(created["ok"], true);
        assert_eq!(created["data"]["workspace_uuid"], workspace_uuid.to_string());
        assert_eq!(created["data"]["surface_uuid"], surface_uuid.to_string());
        assert_eq!(created["data"]["revision"], 1);
        assert_eq!(created["data"]["replayed"], false);

        let snapshot = mux.topology_snapshot();
        let tab = &snapshot.topology["workspaces"][0]["screens"][0]["panes"][0]["tabs"][0];
        assert_eq!(tab["uuid"], surface_uuid.to_string());
        assert_eq!(tab["kind"], "browser");
        assert_eq!(tab["browser_endpoint"]["transport"], "cmuxd-png-frame-stream-v1");
        assert_eq!(tab["browser_endpoint"]["frontend_projection"], "frontend-optional");

        assert!(handle_message(&mux, client, &message, &writer));
        let replayed: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(replayed["data"]["revision"], 1);
        assert_eq!(replayed["data"]["replayed"], true);
        assert_eq!(mux.canonical_topology_revision(), 1);
    }

    struct DurableAcknowledgementSink {
        path: PathBuf,
    }

    impl DurableAcknowledgementSink {
        fn append(&self, value: &Value) -> std::io::Result<()> {
            let mut file =
                std::fs::OpenOptions::new().create(true).append(true).open(&self.path)?;
            serde_json::to_writer(&mut file, value)?;
            file.write_all(b"\n")?;
            file.sync_all()
        }
    }

    impl MessageSink for DurableAcknowledgementSink {
        fn send_initial(&self, value: &Value, _stream: &OutboundStream) -> std::io::Result<()> {
            self.append(value)
        }

        fn send_stream(&self, value: &Value, _stream: &OutboundStream) -> std::io::Result<()> {
            self.append(value)
        }

        fn send_control(&self, value: &Value) -> std::io::Result<()> {
            self.append(value)
        }

        fn send_terminal(&self, value: &Value, _stream: &OutboundStream) -> std::io::Result<()> {
            self.append(value)
        }

        fn is_open(&self) -> bool {
            true
        }

        fn close(&self) {}
    }

    #[test]
    fn durable_append_failure_child_aborts_before_response() {
        let Some(root) = std::env::var_os("CMUX_TEST_DURABILITY_ROOT") else { return };
        let acknowledgement_path = std::env::var_os("CMUX_TEST_DURABILITY_ACK")
            .map(PathBuf::from)
            .expect("durability child acknowledgement path");
        let store = crate::state_store::StateStore::new(PathBuf::from(root));
        let mux = Mux::recover_from_state_store(
            "durability-fail-stop",
            SurfaceOptions::default(),
            &store,
        )
        .unwrap();
        let writer = MessageWriter::new(DurableAcknowledgementSink { path: acknowledgement_path });
        let (client, _, registration) =
            register_v9_client_kind(&mux, &writer, ClientTransport::Unix, "swift-shell");
        let lease = topology_lease(&registration);
        let message = json!({
            "id": 71,
            "cmd": "canonical-new-browser-workspace",
            "request_id": uuid::Uuid::new_v4(),
            "daemon_instance_id": mux.daemon_instance_id,
            "session_id": mux.session_id,
            "expected_revision": 0,
            "topology_lease_id": lease.id,
            "topology_lease_generation": lease.generation,
            "workspace_uuid": WorkspaceUuid::new(),
            "surface_uuid": SurfaceUuid::new(),
            "url": "about:blank",
        })
        .to_string();

        let _ = handle_message(&mux, client, &message, &writer);
        panic!("injected durable append failure returned instead of aborting");
    }

    #[test]
    fn durable_append_failure_is_fail_stop_before_acknowledgement() {
        let root = std::env::temp_dir().join(format!(
            "cmux-durable-fail-stop-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        let acknowledgement_path = root.join("acknowledgements.jsonl");
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .arg("--exact")
            .arg("server::tests::durable_append_failure_child_aborts_before_response")
            .arg("--nocapture")
            .env("CMUX_TEST_DURABILITY_ROOT", &root)
            .env("CMUX_TEST_DURABILITY_ACK", &acknowledgement_path)
            .env("CMUX_TEST_FAIL_DURABLE_APPEND", "1")
            .output()
            .unwrap();

        assert!(!output.status.success(), "durability child unexpectedly returned success");
        let acknowledgements = std::fs::read_to_string(&acknowledgement_path).unwrap_or_default();
        assert!(
            acknowledgements.is_empty(),
            "mutation response escaped before durable append: {acknowledgements}"
        );
        let reopened = crate::state_store::StateStore::new(&root)
            .open_session("durability-fail-stop")
            .unwrap();
        assert_eq!(reopened.snapshot.topology_revision, 0);
        assert!(reopened.snapshot.workspaces.is_empty());
        assert!(reopened.snapshot.surfaces.is_empty());
        assert!(reopened.snapshot.idempotency_results.is_empty());
        drop(reopened.durable);
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn legitimate_max_initial_input_survives_all_admission_bounds() {
        let mux = test_mux();
        let writer = test_writer();
        let (client, _) = register_v9_client(&mux, &writer);
        let message = json!({
            "id": 1,
            "cmd": "ensure-terminal",
            "workspace_uuid": WorkspaceUuid::new(),
            "surface_uuid": SurfaceUuid::new(),
            "initial_input": "x".repeat(1024 * 1024),
            "cols": 80,
            "rows": 24,
        })
        .to_string();

        let decoded_cost = account_json_decode(&message, BULK_COMMAND_DECODE_MAX_BYTES).unwrap();
        assert_eq!(message.len(), 1_048_757);
        assert_eq!(decoded_cost, 2_098_310);
        let permit = preflight_request(&mux, client, &message, None).unwrap();
        assert_eq!(permit.bytes(), 4_195_824);
        assert!(permit.bytes() <= INBOUND_INFLIGHT_MAX_BYTES);
        let request: Request = serde_json::from_str(&message).unwrap();
        let Command::EnsureTerminal {
            workspace_uuid,
            surface_uuid,
            cwd,
            argv,
            command,
            env,
            initial_input,
            wait_after_command,
            cols,
            rows,
        } = request.cmd
        else {
            panic!("wrong command");
        };
        let decoded = ensure_terminal_request(EnsureTerminalSpec {
            workspace_uuid,
            surface_uuid,
            cwd,
            argv,
            command,
            env,
            initial_input,
            wait_after_command,
            cols,
            rows,
        })
        .unwrap();
        assert_eq!(decoded.initial_input.unwrap().len(), 1024 * 1024);
        drop(permit);
        assert_eq!(mux.control_clients.inbound_budget().usage().0, 0);
    }

    #[test]
    fn default_socket_path_falls_back_from_an_oversized_runtime_root() {
        let long_root = PathBuf::from("/tmp").join("r".repeat(100));
        let short_root = PathBuf::from("/tmp/cmux-tui-test");
        let path = default_socket_path_in(&long_root, &short_root, "main", Some(103));
        assert_eq!(path, short_root.join("main.sock"));

        let ordinary = PathBuf::from("/tmp/runtime");
        assert_eq!(
            default_socket_path_in(&ordinary, &short_root, "main", Some(103)),
            ordinary.join("main.sock")
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn darwin_socket_paths_accept_103_bytes_and_reject_104() {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let unique = NEXT.fetch_add(1, Ordering::Relaxed);
        let directory = PathBuf::from(format!("/tmp/cmux-sock-{}-{unique}", std::process::id()));
        std::fs::create_dir_all(&directory).unwrap();
        platform::restrict_directory(&directory).unwrap();

        let exact_path = |bytes: usize| {
            let prefix = socket_path_bytes(&directory) + 1;
            assert!(prefix < bytes);
            directory.join("s".repeat(bytes - prefix))
        };
        let accepted = exact_path(103);
        assert_eq!(socket_path_bytes(&accepted), 103);
        let listener = transport::listen(&accepted).unwrap();
        let client = transport::connect(&accepted).unwrap();
        let server = listener.accept().unwrap();
        drop(client);
        drop(server);
        drop(listener);
        std::fs::remove_file(&accepted).unwrap();

        let rejected = exact_path(104);
        assert_eq!(socket_path_bytes(&rejected), 104);
        let error = transport::listen(&rejected).err().expect("104-byte path must fail");
        assert_eq!(error.kind(), std::io::ErrorKind::InvalidInput);
        assert!(!rejected.exists());
        let error = transport::connect(&rejected).err().expect("104-byte connect must fail");
        assert_eq!(error.kind(), std::io::ErrorKind::InvalidInput);
        std::fs::remove_dir(&directory).unwrap();
    }

    #[test]
    fn bounded_writer_reserves_a_control_lane_for_responses_and_overflow() {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let backlog = writer.start_stream(&json!({"event": "overflow"})).unwrap();

        for sequence in 0..OUTBOUND_CAPACITY - 1 {
            writer
                .send_stream(&json!({"event": "output", "sequence": sequence}), &backlog)
                .unwrap();
        }

        let failed_stream = writer.start_stream(&subscription_overflow_json()).unwrap();
        writer.send_control(&json!({"id": 42, "ok": true, "data": {}})).unwrap();
        writer.send_terminal(&subscription_overflow_json(), &failed_stream).unwrap();
        let response: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(response["id"], 42);
        let terminal: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(terminal["event"], "overflow");
        let drained = (0..OUTBOUND_CAPACITY - 1)
            .map(|_| outbound.try_pop().expect("accepted output"))
            .collect::<Vec<_>>();
        assert!(drained[0].contains("\"sequence\":0"));
        assert!(writer.is_open());
    }

    #[test]
    fn initial_stream_state_precedes_its_response_and_overflows_only_its_stream() {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let stream = writer.start_stream(&attach_overflow_json(7)).unwrap();

        writer.send_initial(&json!({"event": "vt-state", "surface": 7}), &stream).unwrap();
        writer.send_control(&json!({"id": 1, "ok": true})).unwrap();
        let initial: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(initial["event"], "vt-state");
        let response: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(response["id"], 1);

        let oversized = writer.start_stream(&attach_overflow_json(8)).unwrap();
        let error = writer
            .send_initial(
                &json!({"event": "vt-state", "data": "x".repeat(OUTBOUND_BYTE_CAPACITY)}),
                &oversized,
            )
            .unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::WouldBlock);
        let overflow: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(overflow["event"], "overflow");
        assert_eq!(overflow["surface"], 8);
        assert!(writer.is_open());
    }

    #[test]
    fn server_connection_permits_enforce_and_release_the_cap() {
        let active = Arc::new(AtomicU64::new(MAX_SERVER_CONNECTIONS as u64));
        assert!(claim_connection(&active).is_none());
        active.store(MAX_SERVER_CONNECTIONS as u64 - 1, Ordering::Release);
        let permit = claim_connection(&active).expect("last connection slot");
        assert_eq!(active.load(Ordering::Acquire), MAX_SERVER_CONNECTIONS as u64);
        drop(permit);
        assert_eq!(active.load(Ordering::Acquire), MAX_SERVER_CONNECTIONS as u64 - 1);
    }

    #[test]
    fn topology_streams_allow_one_per_connection_and_release_the_global_cap() {
        let registry = ClientRegistry::new();
        let first = registry.register(ClientTransport::Unix, test_writer());
        let first_permit = registry.claim_topology_stream(first).unwrap();
        assert!(
            registry
                .claim_topology_stream(first)
                .err()
                .expect("second stream must fail")
                .to_string()
                .contains("already has")
        );

        let mut permits = vec![first_permit];
        for _ in 1..MAX_TOPOLOGY_STREAMS {
            let client = registry.register(ClientTransport::Unix, test_writer());
            permits.push(registry.claim_topology_stream(client).unwrap());
        }
        assert_eq!(registry.active_topology_streams(), MAX_TOPOLOGY_STREAMS);
        let excess = registry.register(ClientTransport::Unix, test_writer());
        assert!(
            registry
                .claim_topology_stream(excess)
                .err()
                .expect("global overflow must fail")
                .to_string()
                .contains("limit reached")
        );

        drop(permits.pop());
        assert_eq!(registry.active_topology_streams(), MAX_TOPOLOGY_STREAMS - 1);
        let replacement = registry.register(ClientTransport::Unix, test_writer());
        permits.push(registry.claim_topology_stream(replacement).unwrap());
        assert_eq!(registry.active_topology_streams(), MAX_TOPOLOGY_STREAMS);
        drop(permits);
        assert_eq!(registry.active_topology_streams(), 0);
    }

    #[test]
    fn topology_stream_limit_rejects_before_allocating_a_journal_mailbox() {
        let mux = test_mux();
        let mut permits = Vec::new();
        for _ in 0..MAX_TOPOLOGY_STREAMS {
            let client = mux.control_clients.register(ClientTransport::Unix, test_writer());
            permits.push(mux.control_clients.claim_topology_stream(client).unwrap());
        }
        let writer = test_writer();
        let excess = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let snapshot = mux.topology_snapshot();

        let error = handle_command(
            &mux,
            excess,
            Command::SubscribeTopology {
                daemon_instance_id: snapshot.daemon_instance_id,
                session_id: snapshot.session_id,
                revision: snapshot.revision,
            },
            &writer,
        )
        .unwrap_err();

        assert!(error.to_string().contains("topology subscription limit reached"));
        assert_eq!(mux.topology_subscriber_slots(), 0);
        drop(permits);
    }

    #[test]
    fn shutting_down_a_writer_clone_unblocks_the_reader() {
        let path = std::env::temp_dir().join(format!(
            "cmux-tui-shutdown-{}-{}.sock",
            std::process::id(),
            Instant::now().elapsed().as_nanos()
        ));
        let _ = std::fs::remove_file(&path);
        let listener = transport::listen(&path).unwrap();
        let _client = transport::connect(&path).unwrap();
        let mut reader = listener.accept().unwrap();
        let writer = reader.try_clone_box().unwrap();
        let (done, finished) = std::sync::mpsc::channel();
        let read_thread = std::thread::spawn(move || {
            let mut byte = [0_u8; 1];
            done.send(reader.read(&mut byte)).unwrap();
        });

        writer.shutdown(Shutdown::Both).unwrap();
        assert_eq!(finished.recv_timeout(Duration::from_secs(1)).unwrap().unwrap(), 0);
        read_thread.join().unwrap();
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn stalled_websocket_handshake_times_out() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let client = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let (server, peer) = listener.accept().unwrap();
        let (done, finished) = std::sync::mpsc::channel();
        let handler = std::thread::spawn(move || {
            handle_websocket_connection(test_mux(), server, peer, None);
            done.send(()).unwrap();
        });

        finished
            .recv_timeout(Duration::from_secs(1))
            .expect("stalled handshake must not occupy a connection slot indefinitely");
        drop(client);
        handler.join().unwrap();
    }

    #[test]
    fn stalled_websocket_authentication_times_out() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let client_stream = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let (server, peer) = listener.accept().unwrap();
        let (done, finished) = std::sync::mpsc::channel();
        let handler = std::thread::spawn(move || {
            handle_websocket_connection(test_mux(), server, peer, Some("secret"));
            done.send(()).unwrap();
        });
        let (client, _) = tungstenite::client("ws://localhost/", client_stream).unwrap();

        finished
            .recv_timeout(Duration::from_secs(1))
            .expect("stalled authentication must not occupy a connection slot indefinitely");
        drop(client);
        handler.join().unwrap();
    }

    #[test]
    fn authenticated_websocket_pipelining_remains_live_under_the_shared_budget() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let client_stream = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let (server, peer) = listener.accept().unwrap();
        let mux = test_mux();
        let server_mux = mux.clone();
        let handler = std::thread::spawn(move || {
            handle_websocket_connection(server_mux, server, peer, Some("secret"));
        });
        let (mut client, _) = tungstenite::client("ws://localhost/", client_stream).unwrap();

        client
            .send(Message::Text(json!({"auth": {"token": "secret"}}).to_string().into()))
            .unwrap();
        client.send(Message::Text(json!({"id": 7, "cmd": "ping"}).to_string().into())).unwrap();
        let Message::Text(response) = client.read().unwrap() else {
            panic!("expected text response");
        };
        let response: Value = serde_json::from_str(&response).unwrap();
        assert_eq!(response["id"], 7);
        assert_eq!(response["ok"], true);
        assert_eq!(response["data"]["app"], Value::Null);

        client.close(None).unwrap();
        drop(client);
        handler.join().unwrap();
        assert_eq!(mux.control_clients.inbound_budget().usage().0, 0);
    }

    #[test]
    fn global_pressure_terminates_the_stream_occupying_the_backlog() {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let noisy = writer.start_stream(&json!({"event": "overflow", "stream": "noisy"})).unwrap();
        let quiet = writer.start_stream(&json!({"event": "overflow", "stream": "quiet"})).unwrap();

        for sequence in 0..OUTBOUND_CAPACITY {
            writer.send_stream(&json!({"event": "output", "sequence": sequence}), &noisy).unwrap();
        }
        writer.send_stream(&json!({"event": "tree-changed"}), &quiet).unwrap();

        let terminal: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(terminal["stream"], "noisy");
        let quiet_event: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(quiet_event["event"], "tree-changed");
        assert_eq!(outbound.try_pop(), None);
        assert_eq!(
            writer.send_stream(&json!({"event": "late"}), &noisy).unwrap_err().kind(),
            std::io::ErrorKind::BrokenPipe
        );
        assert!(quiet.is_open());
        assert!(writer.is_open());
    }

    #[test]
    fn bounded_writer_rejects_payloads_beyond_each_byte_budget() {
        let outbound = BoundedOutbound::default();
        let stream = OutboundStream::new(1, r#"{"event":"overflow"}"#.to_string());

        let regular =
            outbound.push_regular("x".repeat(OUTBOUND_BYTE_CAPACITY + 1), &stream).unwrap_err();
        assert_eq!(regular.kind(), std::io::ErrorKind::WouldBlock);
        let control =
            outbound.push_control("x".repeat(OUTBOUND_CONTROL_BYTE_RESERVE + 1)).unwrap_err();
        assert_eq!(control.kind(), std::io::ErrorKind::WouldBlock);
        let terminal: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(terminal["event"], "overflow");
        assert_eq!(outbound.try_pop(), None);
    }

    #[test]
    fn terminal_overflow_purges_only_its_stream_and_rejects_late_frames() {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let stale = writer.start_stream(&subscription_overflow_json()).unwrap();
        let unrelated = writer.start_stream(&subscription_overflow_json()).unwrap();

        writer.send_stream(&json!({"event": "output", "stream": "stale"}), &stale).unwrap();
        writer.send_stream(&json!({"event": "output", "stream": "unrelated"}), &unrelated).unwrap();
        writer.send_terminal(&subscription_overflow_json(), &stale).unwrap();

        let late = writer.send_stream(&json!({"event": "output", "stream": "late"}), &stale);
        assert_eq!(late.unwrap_err().kind(), std::io::ErrorKind::BrokenPipe);
        let terminal: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(terminal["event"], "overflow");
        let remaining: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(remaining["stream"], "unrelated");
        assert_eq!(outbound.try_pop(), None);
        assert!(writer.is_open());
    }

    #[test]
    fn client_detach_purges_attach_backlog_before_terminal_event() {
        let mux = Mux::new("detach-order-test", SurfaceOptions::default());
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let stream = writer.start_stream(&attach_overflow_json(41)).unwrap();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        mux.control_clients.attach_surface(client, 41, stream.clone()).unwrap();
        writer.send_initial(&json!({"event": "vt-state", "surface": 41}), &stream).unwrap();
        writer.send_stream(&json!({"event": "output", "surface": 41}), &stream).unwrap();

        assert!(disconnect_client(&mux, client, true));

        let terminal: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(terminal, json!({"event": "detached", "surface": 41}));
        assert_eq!(outbound.try_pop(), None);
    }

    #[test]
    fn self_detach_responds_before_closing_and_releases_the_size_lease() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((120, 40))).unwrap();
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let events = mux.subscribe();
        mux.resize_surface_for_client(surface.id, client, 80, 24).unwrap();

        assert!(!handle_message(
            &mux,
            client,
            &json!({"id": 9, "cmd": "detach-client", "client": client}).to_string(),
            &writer,
        ));

        let response: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(response["id"], 9);
        assert_eq!(response["ok"], true);
        assert_eq!(mux.client_surface_size(surface.id, client), None);
        assert!(mux.control_clients_json(client).as_array().unwrap().is_empty());
        assert!((0..4).any(|_| matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::ClientDetached(id)) if id == client
        )));
        assert!(mux.surface(surface.id).is_some(), "the session must survive its last viewer");
    }

    #[test]
    fn peer_detach_is_id_stable_and_does_not_disconnect_the_initiator() {
        let mux = test_mux();
        let initiator_writer = test_writer();
        let target_writer = test_writer();
        let initiator =
            mux.control_clients.register(ClientTransport::Unix, initiator_writer.clone());
        let target = mux.control_clients.register(ClientTransport::Unix, target_writer);

        handle_command(
            &mux,
            initiator,
            Command::DetachClient { client: target },
            &initiator_writer,
        )
        .unwrap();

        let listed =
            handle_command(&mux, initiator, Command::ListClients, &initiator_writer).unwrap();
        assert_eq!(listed.as_array().unwrap().len(), 1);
        assert_eq!(listed[0]["client"], initiator);
        let error = handle_command(
            &mux,
            initiator,
            Command::DetachClient { client: target },
            &initiator_writer,
        )
        .unwrap_err();
        assert!(error.to_string().contains(&format!("unknown client {target}")));
    }

    #[test]
    fn remote_client_cannot_detach_synthetic_local_client_zero() {
        let mux = test_mux();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());

        let error =
            handle_command(&mux, client, Command::DetachClient { client: 0 }, &writer).unwrap_err();

        assert!(error.to_string().contains("unknown client 0"));
        assert!(
            mux.control_clients_json(client)
                .as_array()
                .unwrap()
                .iter()
                .any(|info| { info["client"] == client })
        );
    }

    #[test]
    fn closing_bounded_writer_wakes_a_waiting_drain() {
        let outbound = Arc::new(BoundedOutbound::default());
        let waiting = outbound.clone();
        let drain = std::thread::spawn(move || waiting.recv());

        outbound.close();

        assert_eq!(drain.join().unwrap(), None);
    }

    #[test]
    fn websocket_overflow_marks_attach_lifecycle() {
        let lifecycle = AttachLifecycle::default();
        let error = std::io::Error::new(std::io::ErrorKind::WouldBlock, "queue full");

        handle_attach_send_error(&lifecycle, &error);

        assert!(lifecycle.is_canceled());
        assert!(lifecycle.overflowed());
    }

    #[test]
    fn ping_is_a_lightweight_authority_and_process_continuity_proof() {
        let session_id = crate::SessionId::new();
        let mux = Mux::new_with_session_id("named-session", SurfaceOptions::default(), session_id);
        let data = handle_command(&mux, 0, Command::Ping, &test_writer()).unwrap();
        assert_eq!(data["ok"].as_bool(), Some(true));
        assert_eq!(data["version"].as_str(), Some(env!("CARGO_PKG_VERSION")));
        assert_eq!(data["protocol"].as_u64(), Some(PROTOCOL_VERSION as u64));
        assert_eq!(data["protocol_min"].as_u64(), Some(PROTOCOL_MIN_VERSION as u64));
        assert_eq!(data["protocol_max"].as_u64(), Some(PROTOCOL_MAX_VERSION as u64));
        assert_eq!(data["capabilities"], serde_json::to_value(PROTOCOL_CAPABILITIES).unwrap());
        assert_eq!(data["session"], "named-session");
        assert_eq!(data["session_id"], session_id.to_string());
        assert_eq!(data["daemon_instance_id"], mux.daemon_instance_id.to_string());
        uuid::Uuid::parse_str(data["session_id"].as_str().unwrap()).unwrap();
        uuid::Uuid::parse_str(data["daemon_instance_id"].as_str().unwrap()).unwrap();
        assert_eq!(data["topology_revision"], 0);
        assert_eq!(data["canonical_topology_revision"], 0);
        assert_eq!(data["pid"], std::process::id());
        assert_eq!(data["renderer_workers"], json!([]));
    }

    #[test]
    fn identify_preserves_v7_fields_and_adds_standard_uuid_identity_and_capabilities() {
        let session_id = crate::SessionId::new();
        let mux = Mux::new_with_session_id("named-session", SurfaceOptions::default(), session_id);
        let data = handle_command(&mux, 0, Command::Identify, &test_writer()).unwrap();

        assert_eq!(data["app"], "cmux-tui");
        assert_eq!(data["version"], env!("CARGO_PKG_VERSION"));
        assert_eq!(data["protocol"], PROTOCOL_VERSION);
        assert_eq!(data["session"], "named-session");
        assert_eq!(data["pid"], std::process::id());
        assert_eq!(data["protocol_min"], PROTOCOL_MIN_VERSION);
        assert_eq!(data["protocol_max"], PROTOCOL_MAX_VERSION);
        assert_eq!(data["capabilities"], serde_json::to_value(PROTOCOL_CAPABILITIES).unwrap());
        let encoded_session = data["session_id"].as_str().unwrap();
        let encoded_daemon = data["daemon_instance_id"].as_str().unwrap();
        assert_eq!(encoded_session.parse::<crate::SessionId>().unwrap(), session_id);
        uuid::Uuid::parse_str(encoded_session).unwrap();
        uuid::Uuid::parse_str(encoded_daemon).unwrap();
        assert_ne!(encoded_session, encoded_daemon);
        assert_eq!(data["topology_revision"], 0);
        assert_eq!(data["canonical_topology_revision"], 0);
        assert_eq!(data["renderer_workers"], json!([]));

        let replacement =
            Mux::new_with_session_id("named-session", SurfaceOptions::default(), session_id);
        assert_eq!(replacement.session_id, mux.session_id);
        assert_ne!(replacement.daemon_instance_id, mux.daemon_instance_id);
    }

    #[test]
    fn authority_responses_distinguish_legacy_and_canonical_topology_revisions() {
        let mux = test_mux();
        mux.new_workspace(Some("one".into()), None).unwrap();
        let workspace = mux.with_state(|state| state.workspaces[0].id);
        assert!(mux.rename_workspace(workspace, "one".into()));

        let ping = handle_command(&mux, 0, Command::Ping, &test_writer()).unwrap();
        let identify = handle_command(&mux, 0, Command::Identify, &test_writer()).unwrap();
        let legacy = handle_command(&mux, 0, Command::ListWorkspaces, &test_writer()).unwrap();
        let canonical = handle_command(&mux, 0, Command::TopologySnapshot, &test_writer()).unwrap();

        for authority in [&ping, &identify] {
            assert_eq!(authority["topology_revision"], 2);
            assert_eq!(authority["canonical_topology_revision"], 1);
        }
        assert_eq!(legacy["topology_revision"], 2);
        assert_eq!(canonical["revision"], 1);
    }

    #[test]
    fn protocol_v8_exposes_canonical_topology_capabilities_without_dropping_v7() {
        assert_eq!(PROTOCOL_VERSION, 8);
        assert_eq!(PROTOCOL_MIN_VERSION, 6);
        assert_eq!(PROTOCOL_MAX_VERSION, 9);
        for capability in [
            "render-attach-v1",
            "presentation-registry-v1",
            "renderer-worker-supervision-v1",
            "tree-delta-v1",
            "canonical-topology-snapshot-v1",
            "stable-entity-uuid-v1",
            "topology-resume-v1",
            "terminal-accessibility-v1",
        ] {
            assert!(PROTOCOL_CAPABILITIES.contains(&capability));
        }

        let request: Request = serde_json::from_str(r#"{"id":7,"cmd":"subscribe"}"#).unwrap();
        assert_eq!(request.id, Some(json!(7)));
        assert!(matches!(request.cmd, Command::Subscribe { tree_events: None }));

        let presentation_id = PresentationId::new();
        let accessibility: Request = serde_json::from_value(json!({
            "id": 8,
            "cmd": "terminal-accessibility-activate-link",
            "presentation_id": presentation_id,
            "expected_generation": 7,
            "terminal_revision": 11,
            "content_revision": 9,
            "viewport_revision": 3,
            "link_id": "9:3:feedface",
        }))
        .unwrap();
        assert!(matches!(
            accessibility.cmd,
            Command::TerminalAccessibilityActivateLink {
                presentation_id: decoded_presentation,
                expected_generation: 7,
                terminal_revision: 11,
                content_revision: 9,
                viewport_revision: 3,
                ref link_id,
            } if decoded_presentation == presentation_id && link_id == "9:3:feedface"
        ));
    }

    #[test]
    fn terminal_accessibility_requires_unix_v9_registration_before_reading_content() {
        let mux = test_mux();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let error = handle_command(
            &mux,
            client,
            Command::TerminalAccessibilitySnapshot {
                presentation_id: PresentationId::new(),
                expected_generation: 1,
                expected_content_sequence: 1,
            },
            &writer,
        )
        .unwrap_err();
        let message = error.to_string();
        assert!(
            message.contains("protocol v9") || message.contains("requires register-client"),
            "unexpected unregistered accessibility error: {message}"
        );

        let (registered, _) = register_v9_client(&mux, &writer);
        let invalid_link = handle_command(
            &mux,
            registered,
            Command::TerminalAccessibilityActivateLink {
                presentation_id: PresentationId::new(),
                expected_generation: 1,
                terminal_revision: 1,
                content_revision: 1,
                viewport_revision: 1,
                link_id: String::new(),
            },
            &writer,
        )
        .unwrap_err();
        assert!(invalid_link.to_string().contains("invalid terminal accessibility link id"));
    }

    #[test]
    fn protocol_v9_registration_is_explicit_single_use_and_rejects_identity_or_range_errors() {
        let mux = test_mux();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let nil_identity = handle_command(
            &mux,
            client,
            Command::RegisterClient {
                protocol_min: 8,
                protocol_max: 9,
                client_uuid: uuid::Uuid::nil(),
                process_instance_uuid: uuid::Uuid::new_v4(),
                client_kind: None,
            },
            &writer,
        )
        .unwrap_err();
        assert!(nil_identity.to_string().contains("non-nil UUIDs"));

        let client_uuid = uuid::Uuid::new_v4();
        let registered = handle_command(
            &mux,
            client,
            Command::RegisterClient {
                protocol_min: 8,
                protocol_max: 9,
                client_uuid,
                process_instance_uuid: uuid::Uuid::new_v4(),
                client_kind: None,
            },
            &writer,
        )
        .unwrap();
        assert_eq!(registered["protocol"], 9);
        assert_eq!(registered["client_uuid"], client_uuid.to_string());

        let duplicate = handle_command(
            &mux,
            client,
            Command::RegisterClient {
                protocol_min: 9,
                protocol_max: 9,
                client_uuid,
                process_instance_uuid: uuid::Uuid::new_v4(),
                client_kind: None,
            },
            &writer,
        )
        .unwrap_err();
        assert!(duplicate.to_string().contains("already registered"));

        let incompatible_client =
            mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let incompatible = handle_command(
            &mux,
            incompatible_client,
            Command::RegisterClient {
                protocol_min: 10,
                protocol_max: 10,
                client_uuid: uuid::Uuid::new_v4(),
                process_instance_uuid: uuid::Uuid::new_v4(),
                client_kind: None,
            },
            &writer,
        )
        .unwrap_err();
        assert!(incompatible.to_string().contains("no compatible protocol version"));
    }

    #[test]
    fn protocol_v9_named_key_wire_payload_decodes_to_the_typed_variant() {
        let request: Request = serde_json::from_value(json!({
            "id": 7,
            "cmd": "terminal-input",
            "surface_uuid": uuid::Uuid::new_v4(),
            "presentation_id": uuid::Uuid::new_v4(),
            "presentation_generation": 3,
            "lease_id": uuid::Uuid::new_v4(),
            "lease_generation": 4,
            "sequence": 5,
            "request_id": uuid::Uuid::new_v4(),
            "input": {"type": "named-key", "key": "ctrl+shift+p"},
        }))
        .unwrap();

        assert!(matches!(
            request.cmd,
            Command::TerminalInput {
                input: TerminalInputPayload::NamedKey { ref key },
                ..
            } if key == "ctrl+shift+p"
        ));
    }

    #[test]
    fn protocol_v9_lease_orders_input_and_geometry_without_legacy_size_reduction() {
        let mux = test_mux();
        mux.new_workspace(Some("leased".into()), Some((80, 24))).unwrap();
        let (surface_id, surface_uuid) = mux.with_state(|state| {
            let surface_id = *state.panes.values().next().unwrap().tabs.first().unwrap();
            (surface_id, state.surfaces[&surface_id].uuid)
        });
        let writer = test_writer();
        let (client, _) = register_v9_client(&mux, &writer);
        let (presentation_id, presentation_generation) =
            open_visible_terminal_presentation(&mux, &writer, client, surface_uuid);

        let lease = handle_command(
            &mux,
            client,
            Command::AcquireTerminalLease {
                kind: "input".into(),
                surface_uuid,
                presentation_id,
                presentation_generation,
                ttl_ms: 5_000,
            },
            &writer,
        )
        .unwrap();
        assert_eq!(lease["migrated_from_legacy"], true);
        let lease_id = lease["lease_id"].as_str().unwrap().parse().unwrap();
        let lease_generation = lease["lease_generation"].as_u64().unwrap();

        let geometry_lease = handle_command(
            &mux,
            client,
            Command::AcquireTerminalLease {
                kind: "geometry".into(),
                surface_uuid,
                presentation_id,
                presentation_generation,
                ttl_ms: 5_000,
            },
            &writer,
        )
        .unwrap();
        let geometry_lease_id = geometry_lease["lease_id"].as_str().unwrap().parse().unwrap();
        let geometry_lease_generation = geometry_lease["lease_generation"].as_u64().unwrap();

        let geometry_request = uuid::Uuid::new_v4();
        let geometry = handle_command(
            &mux,
            client,
            Command::TerminalGeometry {
                surface_uuid,
                presentation_id,
                presentation_generation,
                lease_id: geometry_lease_id,
                lease_generation: geometry_lease_generation,
                sequence: 1,
                request_id: geometry_request,
                cols: 120,
                rows: 40,
            },
            &writer,
        )
        .unwrap();
        assert_eq!(geometry["status"], "applied");
        assert_eq!(mux.surface(surface_id).unwrap().size(), (120, 40));
        mux.apply_renderer_configuration_size(surface_id, client, 60, 20).unwrap();
        assert_eq!(
            mux.surface(surface_id).unwrap().size(),
            (120, 40),
            "v9 renderer reconfiguration must not re-enter the legacy size reducer"
        );

        let nil_request = handle_command(
            &mux,
            client,
            Command::TerminalInput {
                surface_uuid,
                presentation_id,
                presentation_generation,
                lease_id,
                lease_generation,
                sequence: 1,
                request_id: uuid::Uuid::nil(),
                input: TerminalInputPayload::Text { text: "rejected".into(), paste: false },
                input_group_id: None,
                input_group_index: None,
                input_group_end: None,
            },
            &writer,
        )
        .unwrap_err();
        assert!(nil_request.to_string().contains("non-nil UUID"));

        let input_request = uuid::Uuid::new_v4();
        let input = || Command::TerminalInput {
            surface_uuid,
            presentation_id,
            presentation_generation,
            lease_id,
            lease_generation,
            sequence: 1,
            request_id: input_request,
            input: TerminalInputPayload::Text { text: "ordered".into(), paste: false },
            input_group_id: None,
            input_group_index: None,
            input_group_end: None,
        };
        let applied = handle_command(&mux, client, input(), &writer).unwrap();
        assert_eq!(applied["status"], "applied");
        assert_eq!(applied["replayed"], false);
        let replayed = handle_command(&mux, client, input(), &writer).unwrap();
        assert_eq!(replayed["status"], "applied");
        assert_eq!(replayed["replayed"], true);

        let named_key = handle_command(
            &mux,
            client,
            Command::TerminalInput {
                surface_uuid,
                presentation_id,
                presentation_generation,
                lease_id,
                lease_generation,
                sequence: 2,
                request_id: uuid::Uuid::new_v4(),
                input: TerminalInputPayload::NamedKey { key: "enter".into() },
                input_group_id: None,
                input_group_index: None,
                input_group_end: None,
            },
            &writer,
        )
        .unwrap();
        assert_eq!(named_key["status"], "applied");
        assert_eq!(named_key["encoded_bytes"], 1);

        let conflict = handle_command(
            &mux,
            client,
            Command::TerminalInput {
                surface_uuid,
                presentation_id,
                presentation_generation,
                lease_id,
                lease_generation,
                sequence: 1,
                request_id: input_request,
                input: TerminalInputPayload::Text { text: "changed".into(), paste: false },
                input_group_id: None,
                input_group_index: None,
                input_group_end: None,
            },
            &writer,
        )
        .unwrap_err();
        assert!(conflict.to_string().contains("different payload"));

        let recovered = handle_command(
            &mux,
            client,
            Command::TerminalRequestStatus { surface_uuid, request_id: input_request },
            &writer,
        )
        .unwrap();
        assert_eq!(recovered["status"], "applied");
        assert_eq!(recovered["replayed"], true);
        let acknowledged = handle_command(
            &mux,
            client,
            Command::AcknowledgeTerminalRequest { surface_uuid, request_id: input_request },
            &writer,
        )
        .unwrap();
        assert_eq!(acknowledged["acknowledged"], true);
        let duplicate_ack = handle_command(
            &mux,
            client,
            Command::AcknowledgeTerminalRequest { surface_uuid, request_id: input_request },
            &writer,
        )
        .unwrap();
        assert_eq!(duplicate_ack["acknowledged"], false);
        let forgotten = handle_command(
            &mux,
            client,
            Command::TerminalRequestStatus { surface_uuid, request_id: input_request },
            &writer,
        )
        .unwrap();
        assert_eq!(forgotten["status"], "unknown");

        let legacy_resize = handle_command(
            &mux,
            client,
            Command::ResizeSurface { surface: surface_id, cols: 60, rows: 20 },
            &writer,
        )
        .unwrap_err();
        assert!(legacy_resize.to_string().contains("protocol-v9 leased control"));
        assert_eq!(mux.surface(surface_id).unwrap().size(), (120, 40));
    }

    #[test]
    fn protocol_v9_three_clients_have_total_input_order_atomic_groups_and_split_geometry() {
        let mux = test_mux();
        mux.new_workspace(Some("three-client".into()), Some((80, 24))).unwrap();
        let (surface_id, surface_uuid) = mux.with_state(|state| {
            let surface_id = *state.panes.values().next().unwrap().tabs.first().unwrap();
            (surface_id, state.surfaces[&surface_id].uuid)
        });
        let gui_writer = test_writer();
        let tui_writer = test_writer();
        let automation_writer = test_writer();
        let (gui, _) = register_v9_client(&mux, &gui_writer);
        let (tui, tui_uuid) = register_v9_client(&mux, &tui_writer);
        let (automation, automation_uuid) = register_v9_client(&mux, &automation_writer);
        let (gui_presentation, gui_generation) =
            open_visible_terminal_presentation(&mux, &gui_writer, gui, surface_uuid);
        let (tui_presentation, tui_generation) =
            open_visible_terminal_presentation(&mux, &tui_writer, tui, surface_uuid);

        let gui_input = handle_command(
            &mux,
            gui,
            Command::AcquireTerminalLease {
                kind: "input".into(),
                surface_uuid,
                presentation_id: gui_presentation,
                presentation_generation: gui_generation,
                ttl_ms: 5_000,
            },
            &gui_writer,
        )
        .unwrap();
        let gui_input_id = gui_input["lease_id"].as_str().unwrap().parse().unwrap();
        let gui_input_generation = gui_input["lease_generation"].as_u64().unwrap();

        let tui_geometry = handle_command(
            &mux,
            tui,
            Command::AcquireTerminalLease {
                kind: "geometry".into(),
                surface_uuid,
                presentation_id: tui_presentation,
                presentation_generation: tui_generation,
                ttl_ms: 5_000,
            },
            &tui_writer,
        )
        .unwrap();
        let tui_geometry_id = tui_geometry["lease_id"].as_str().unwrap().parse().unwrap();
        let tui_geometry_generation = tui_geometry["lease_generation"].as_u64().unwrap();

        let wrong_geometry = handle_command(
            &mux,
            gui,
            Command::TerminalGeometry {
                surface_uuid,
                presentation_id: gui_presentation,
                presentation_generation: gui_generation,
                lease_id: gui_input_id,
                lease_generation: gui_input_generation,
                sequence: 1,
                request_id: uuid::Uuid::new_v4(),
                cols: 200,
                rows: 60,
            },
            &gui_writer,
        )
        .unwrap_err();
        assert!(wrong_geometry.to_string().contains("Geometry lease"));
        assert_eq!(mux.surface(surface_id).unwrap().size(), (80, 24));

        let resized = handle_command(
            &mux,
            tui,
            Command::TerminalGeometry {
                surface_uuid,
                presentation_id: tui_presentation,
                presentation_generation: tui_generation,
                lease_id: tui_geometry_id,
                lease_generation: tui_geometry_generation,
                sequence: 1,
                request_id: uuid::Uuid::new_v4(),
                cols: 120,
                rows: 40,
            },
            &tui_writer,
        )
        .unwrap();
        assert_eq!(resized["sequence"], 1);
        assert_eq!(mux.surface(surface_id).unwrap().size(), (120, 40));

        let delegation = handle_command(
            &mux,
            gui,
            Command::GrantTerminalInputDelegation {
                surface_uuid,
                presentation_id: gui_presentation,
                presentation_generation: gui_generation,
                lease_id: gui_input_id,
                lease_generation: gui_input_generation,
                delegate_client_uuid: automation_uuid,
                ttl_ms: 2_000,
                scopes: vec!["text".into()],
            },
            &gui_writer,
        )
        .unwrap();
        let delegation_id = delegation["delegation_id"].as_str().unwrap().parse().unwrap();
        let delegation_generation = delegation["delegation_generation"].as_u64().unwrap();

        let lifecycle_group = uuid::Uuid::new_v4();
        let start = handle_command(
            &mux,
            gui,
            Command::TerminalInput {
                surface_uuid,
                presentation_id: gui_presentation,
                presentation_generation: gui_generation,
                lease_id: gui_input_id,
                lease_generation: gui_input_generation,
                sequence: 1,
                request_id: uuid::Uuid::new_v4(),
                input: TerminalInputPayload::Text { text: "press".into(), paste: false },
                input_group_id: Some(lifecycle_group),
                input_group_index: Some(0),
                input_group_end: Some(false),
            },
            &gui_writer,
        )
        .unwrap();
        assert_eq!(start["ordered_input_sequence"], 1);

        let split_attempt = handle_command(
            &mux,
            automation,
            Command::TerminalDelegatedInput {
                surface_uuid,
                delegation_id,
                delegation_generation,
                sequence: 1,
                request_id: uuid::Uuid::new_v4(),
                input: TerminalInputPayload::Text { text: "split".into(), paste: false },
                input_group_id: None,
                input_group_index: None,
                input_group_end: None,
            },
            &automation_writer,
        )
        .unwrap_err();
        assert!(split_attempt.to_string().contains("input group"));

        let end = handle_command(
            &mux,
            gui,
            Command::TerminalInput {
                surface_uuid,
                presentation_id: gui_presentation,
                presentation_generation: gui_generation,
                lease_id: gui_input_id,
                lease_generation: gui_input_generation,
                sequence: 2,
                request_id: uuid::Uuid::new_v4(),
                input: TerminalInputPayload::Text { text: "release".into(), paste: false },
                input_group_id: Some(lifecycle_group),
                input_group_index: Some(1),
                input_group_end: Some(true),
            },
            &gui_writer,
        )
        .unwrap();
        assert_eq!(end["ordered_input_sequence"], 2);

        let paste_request = uuid::Uuid::new_v4();
        let paste_group = uuid::Uuid::new_v4();
        let paste = || Command::TerminalInput {
            surface_uuid,
            presentation_id: gui_presentation,
            presentation_generation: gui_generation,
            lease_id: gui_input_id,
            lease_generation: gui_input_generation,
            sequence: 3,
            request_id: paste_request,
            input: TerminalInputPayload::Text { text: "one-paste".into(), paste: true },
            input_group_id: Some(paste_group),
            input_group_index: Some(0),
            input_group_end: Some(true),
        };
        let first_paste = handle_command(&mux, gui, paste(), &gui_writer).unwrap();
        let retry_paste = handle_command(&mux, gui, paste(), &gui_writer).unwrap();
        assert_eq!(first_paste["ordered_input_sequence"], 3);
        assert_eq!(first_paste["replayed"], false);
        assert_eq!(retry_paste["ordered_input_sequence"], 3);
        assert_eq!(retry_paste["replayed"], true, "retry must not write the PTY twice");

        let delegated = handle_command(
            &mux,
            automation,
            Command::TerminalDelegatedInput {
                surface_uuid,
                delegation_id,
                delegation_generation,
                sequence: 1,
                request_id: uuid::Uuid::new_v4(),
                input: TerminalInputPayload::Text { text: "automation".into(), paste: false },
                input_group_id: None,
                input_group_index: None,
                input_group_end: None,
            },
            &automation_writer,
        )
        .unwrap();
        assert_eq!(delegated["ordered_input_sequence"], 4);

        let transferred = handle_command(
            &mux,
            gui,
            Command::TransferTerminalLease {
                kind: "input".into(),
                surface_uuid,
                presentation_id: gui_presentation,
                presentation_generation: gui_generation,
                lease_id: gui_input_id,
                lease_generation: gui_input_generation,
                target_client_uuid: tui_uuid,
                target_presentation_id: tui_presentation,
                target_presentation_generation: tui_generation,
                ttl_ms: 5_000,
            },
            &gui_writer,
        )
        .unwrap();
        let tui_input_id = transferred["lease_id"].as_str().unwrap().parse().unwrap();
        let tui_input_generation = transferred["lease_generation"].as_u64().unwrap();
        let tui_input = handle_command(
            &mux,
            tui,
            Command::TerminalInput {
                surface_uuid,
                presentation_id: tui_presentation,
                presentation_generation: tui_generation,
                lease_id: tui_input_id,
                lease_generation: tui_input_generation,
                sequence: 1,
                request_id: uuid::Uuid::new_v4(),
                input: TerminalInputPayload::Text { text: "tui".into(), paste: false },
                input_group_id: None,
                input_group_index: None,
                input_group_end: None,
            },
            &tui_writer,
        )
        .unwrap();
        assert_eq!(tui_input["ordered_input_sequence"], 5);

        let revoked_delegate = handle_command(
            &mux,
            automation,
            Command::TerminalDelegatedInput {
                surface_uuid,
                delegation_id,
                delegation_generation,
                sequence: 2,
                request_id: uuid::Uuid::new_v4(),
                input: TerminalInputPayload::Text { text: "stale".into(), paste: false },
                input_group_id: None,
                input_group_index: None,
                input_group_end: None,
            },
            &automation_writer,
        )
        .unwrap_err();
        assert!(revoked_delegate.to_string().contains("delegation is missing"));

        assert!(disconnect_client(&mux, tui, false));
        let reconnect_writer = test_writer();
        let reconnect =
            mux.control_clients.register(ClientTransport::Unix, reconnect_writer.clone());
        handle_command(
            &mux,
            reconnect,
            Command::RegisterClient {
                protocol_min: 9,
                protocol_max: 9,
                client_uuid: tui_uuid,
                process_instance_uuid: uuid::Uuid::new_v4(),
                client_kind: None,
            },
            &reconnect_writer,
        )
        .unwrap();
        let stale_claim = handle_command(
            &mux,
            reconnect,
            Command::TerminalInput {
                surface_uuid,
                presentation_id: tui_presentation,
                presentation_generation: tui_generation,
                lease_id: tui_input_id,
                lease_generation: tui_input_generation,
                sequence: 2,
                request_id: uuid::Uuid::new_v4(),
                input: TerminalInputPayload::Text { text: "reconnected".into(), paste: false },
                input_group_id: None,
                input_group_index: None,
                input_group_end: None,
            },
            &reconnect_writer,
        )
        .unwrap_err();
        assert!(stale_claim.to_string().contains("Input lease is missing"));
    }

    #[test]
    fn protocol_v9_renderer_visibility_claims_neither_terminal_lane() {
        let v8_mux = test_mux();
        v8_mux.new_workspace(Some("legacy".into()), Some((80, 24))).unwrap();
        let v8_surface =
            v8_mux.with_state(|state| *state.panes.values().next().unwrap().tabs.first().unwrap());
        let v8_writer = test_writer();
        let v8_client = v8_mux.control_clients.register(ClientTransport::Unix, v8_writer.clone());
        v8_mux.apply_renderer_configuration_size(v8_surface, v8_client, 100, 30).unwrap();
        assert_eq!(v8_mux.surface(v8_surface).unwrap().size(), (100, 30));
        assert_eq!(v8_mux.client_surface_size(v8_surface, v8_client), Some((100, 30)));

        let v9_mux = test_mux();
        v9_mux.new_workspace(Some("leased".into()), Some((80, 24))).unwrap();
        let (v9_surface, v9_surface_uuid) = v9_mux.with_state(|state| {
            let surface = *state.panes.values().next().unwrap().tabs.first().unwrap();
            (surface, state.surfaces[&surface].uuid)
        });
        let v9_writer = test_writer();
        let (v9_client, _) = register_v9_client(&v9_mux, &v9_writer);
        let _ = open_visible_terminal_presentation(&v9_mux, &v9_writer, v9_client, v9_surface_uuid);
        v9_mux.apply_renderer_configuration_size(v9_surface, v9_client, 120, 40).unwrap();

        assert_eq!(v9_mux.surface(v9_surface).unwrap().size(), (80, 24));
        assert_eq!(v9_mux.client_surface_size(v9_surface, v9_client), None);
        assert_eq!(
            v9_mux.terminal_authority.mode(v9_surface_uuid),
            crate::terminal_authority::TerminalControlMode::LegacyShared
        );
    }

    #[test]
    fn protocol_v9_disconnect_revokes_exact_presentation_lease() {
        let mux = test_mux();
        mux.new_workspace(Some("leased".into()), Some((80, 24))).unwrap();
        let (surface_id, surface_uuid) = mux.with_state(|state| {
            let surface_id = *state.panes.values().next().unwrap().tabs.first().unwrap();
            (surface_id, state.surfaces[&surface_id].uuid)
        });
        let first_writer = test_writer();
        let (first, _) = register_v9_client(&mux, &first_writer);
        let (first_presentation, first_generation) =
            open_visible_terminal_presentation(&mux, &first_writer, first, surface_uuid);
        let first_lease = handle_command(
            &mux,
            first,
            Command::AcquireTerminalControl {
                surface_uuid,
                presentation_id: first_presentation,
                presentation_generation: first_generation,
                ttl_ms: 5_000,
            },
            &first_writer,
        )
        .unwrap();
        assert!(disconnect_client(&mux, first, false));

        let second_writer = test_writer();
        let (second, _) = register_v9_client(&mux, &second_writer);
        let (second_presentation, second_generation) =
            open_visible_terminal_presentation(&mux, &second_writer, second, surface_uuid);
        let second_lease = handle_command(
            &mux,
            second,
            Command::AcquireTerminalControl {
                surface_uuid,
                presentation_id: second_presentation,
                presentation_generation: second_generation,
                ttl_ms: 5_000,
            },
            &second_writer,
        )
        .unwrap();
        assert!(
            second_lease["lease_generation"].as_u64().unwrap()
                > first_lease["lease_generation"].as_u64().unwrap()
        );
        assert!(mux.surface(surface_id).is_some());
    }

    #[test]
    fn legacy_numeric_surface_close_cannot_bypass_canonical_mutation_fences() {
        let mux = test_mux();
        mux.new_workspace(Some("leased".into()), Some((80, 24))).unwrap();
        let (surface_id, surface_uuid) = mux.with_state(|state| {
            let surface_id = *state.panes.values().next().unwrap().tabs.first().unwrap();
            (surface_id, state.surfaces[&surface_id].uuid)
        });
        let writer = test_writer();
        let (client, _) = register_v9_client(&mux, &writer);
        let (presentation_id, presentation_generation) =
            open_visible_terminal_presentation(&mux, &writer, client, surface_uuid);
        let lease = handle_command(
            &mux,
            client,
            Command::AcquireTerminalControl {
                surface_uuid,
                presentation_id,
                presentation_generation,
                ttl_ms: 5_000,
            },
            &writer,
        )
        .unwrap();
        let lease_id = lease["lease_id"].as_str().unwrap().parse().unwrap();
        let lease_generation = lease["lease_generation"].as_u64().unwrap();

        let before = canonical_state_digest(&mux);
        let close =
            handle_command(&mux, client, Command::CloseSurface { surface: surface_id }, &writer)
                .unwrap_err();
        assert!(close.to_string().contains("legacy numeric close commands are disabled"));

        assert_eq!(mux.presentations.list_for_client(client).len(), 1);
        assert!(mux.surface(surface_id).is_some());
        assert_eq!(canonical_state_digest(&mux), before);
        handle_command(
            &mux,
            client,
            Command::ReleaseTerminalControl {
                surface_uuid,
                presentation_id,
                presentation_generation,
                lease_id,
                lease_generation,
            },
            &writer,
        )
        .unwrap();
    }

    #[test]
    fn topology_snapshot_command_preserves_numeric_ids_and_adds_stable_uuids() {
        let mux = test_mux();
        let empty = handle_command(&mux, 0, Command::TopologySnapshot, &test_writer()).unwrap();
        assert_eq!(empty["revision"], 0);
        assert_eq!(empty["topology"], json!({"workspaces": []}));

        mux.new_workspace(Some("one".into()), None).unwrap();
        let data = handle_command(&mux, 0, Command::TopologySnapshot, &test_writer()).unwrap();
        assert_eq!(data["revision"], 1);
        assert_eq!(data["daemon_instance_id"], mux.daemon_instance_id.to_string());
        assert_eq!(data["session_id"], mux.session_id.to_string());
        let workspace = &data["topology"]["workspaces"][0];
        let screen = &workspace["screens"][0];
        let pane = &screen["panes"][0];
        let tab = &pane["tabs"][0];
        for entity in [workspace, screen, pane, tab] {
            assert!(entity["id"].as_u64().is_some());
            uuid::Uuid::parse_str(entity["uuid"].as_str().unwrap()).unwrap();
        }
        let encoded = data["topology"].to_string();
        for excluded in ["presentation", "notification", "title", "size", "dead", "status"] {
            assert!(!encoded.contains(excluded), "canonical topology leaked {excluded}");
        }

        let browser = mux.new_browser_tab("about:blank".to_owned(), None, None).unwrap();
        let with_browser =
            handle_command(&mux, 0, Command::TopologySnapshot, &test_writer()).unwrap();
        let browser_tab = with_browser["topology"]["workspaces"][0]["screens"][0]["panes"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|pane| pane["tabs"].as_array().unwrap())
            .find(|tab| tab["uuid"] == browser.uuid.to_string())
            .unwrap();
        assert_eq!(browser_tab["browser_endpoint"]["transport"], "cmuxd-png-frame-stream-v1");
        assert_eq!(browser_tab["browser_endpoint"]["frontend_projection"], "frontend-optional");
    }

    #[test]
    fn topology_resume_rejects_a_stale_daemon_on_the_wire() {
        let mux = test_mux();
        let stale = DaemonInstanceId::new();
        assert_ne!(stale, mux.daemon_instance_id);
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let data = handle_command(
            &mux,
            client,
            Command::SubscribeTopology {
                daemon_instance_id: stale,
                session_id: mux.session_id,
                revision: 0,
            },
            &writer,
        )
        .unwrap();
        assert_eq!(data["status"], "resnapshot-required");
        assert_eq!(data["reason"], "stale-daemon");
        assert_eq!(data["current_revision"], 0);
        assert_eq!(data["daemon_instance_id"], mux.daemon_instance_id.to_string());
        assert_eq!(data["session_id"], mux.session_id.to_string());
        assert_eq!(mux.control_clients.active_topology_streams(), 0);
        assert_eq!(mux.topology_subscriber_slots(), 0);
    }

    #[test]
    fn topology_resume_rejects_a_stale_session_on_the_wire() {
        let mux = test_mux();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let data = handle_command(
            &mux,
            client,
            Command::SubscribeTopology {
                daemon_instance_id: mux.daemon_instance_id,
                session_id: crate::SessionId::new(),
                revision: u64::MAX,
            },
            &writer,
        )
        .unwrap();
        assert_eq!(data["status"], "resnapshot-required");
        assert_eq!(data["reason"], "stale-session");
        assert_eq!(data["current_revision"], 0);
        assert_eq!(mux.control_clients.active_topology_streams(), 0);
        assert_eq!(mux.topology_subscriber_slots(), 0);
    }

    #[test]
    fn duplicate_topology_subscriptions_do_not_register_dead_mailboxes() {
        let mux = test_mux();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let snapshot = mux.topology_snapshot();
        let subscribed = handle_command(
            &mux,
            client,
            Command::SubscribeTopology {
                daemon_instance_id: snapshot.daemon_instance_id,
                session_id: snapshot.session_id,
                revision: snapshot.revision,
            },
            &writer,
        )
        .unwrap();
        assert_eq!(subscribed["status"], "subscribed");
        assert_eq!(mux.topology_subscriber_slots(), 1);

        for _ in 0..128 {
            let error = handle_command(
                &mux,
                client,
                Command::SubscribeTopology {
                    daemon_instance_id: snapshot.daemon_instance_id,
                    session_id: snapshot.session_id,
                    revision: snapshot.revision,
                },
                &writer,
            )
            .unwrap_err();
            assert!(error.to_string().contains("already has a topology subscription"));
        }
        assert_eq!(mux.topology_subscriber_slots(), 1);
        assert_eq!(mux.control_clients.active_topology_streams(), 1);
        disconnect_client(&mux, client, false);
    }

    #[test]
    fn protocol_v7_numeric_presentation_fields_round_trip_with_v8_uuids() {
        let mux = test_mux();
        mux.new_workspace(Some("first".into()), None).unwrap();
        mux.new_workspace(Some("second".into()), None).unwrap();
        let bindings = mux.with_state(|state| {
            state
                .workspaces
                .iter()
                .map(|workspace| {
                    let screen = &workspace.screens[0];
                    let pane = state.panes.get(&screen.active_pane).unwrap();
                    let surface = state.surfaces.get(&pane.tabs[0]).unwrap();
                    (
                        workspace.id,
                        workspace.uuid,
                        screen.id,
                        screen.uuid,
                        pane.id,
                        pane.uuid,
                        surface.id,
                        surface.uuid,
                    )
                })
                .collect::<Vec<_>>()
        });
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let request: Request = serde_json::from_value(json!({
            "id": 7,
            "cmd": "open-presentation",
            "view": {
                "workspace": bindings[0].0,
                "screen": bindings[0].2,
                "pane": bindings[0].4,
                "tab": bindings[0].6
            },
            "zoom": { "pane": bindings[0].4 },
            "scroll": { "surface": bindings[0].6, "offset": 9 }
        }))
        .unwrap();
        let opened = handle_command(&mux, client, request.cmd, &writer).unwrap();

        assert_eq!(opened["view"]["workspace"], bindings[0].0);
        assert_eq!(opened["view"]["workspace_uuid"], bindings[0].1.to_string());
        assert_eq!(opened["view"]["screen"], bindings[0].2);
        assert_eq!(opened["view"]["screen_uuid"], bindings[0].3.to_string());
        assert_eq!(opened["view"]["pane"], bindings[0].4);
        assert_eq!(opened["view"]["pane_uuid"], bindings[0].5.to_string());
        assert_eq!(opened["view"]["tab"], bindings[0].6);
        assert_eq!(opened["view"]["surface_uuid"], bindings[0].7.to_string());
        assert_eq!(opened["zoom"]["pane"], bindings[0].4);
        assert_eq!(opened["zoom"]["pane_uuid"], bindings[0].5.to_string());
        assert_eq!(opened["scroll"]["surface"], bindings[0].6);
        assert_eq!(opened["scroll"]["surface_uuid"], bindings[0].7.to_string());
        assert_eq!(opened["scroll"]["offset"], 9);

        let mismatched: Request = serde_json::from_value(json!({
            "cmd": "open-presentation",
            "view": {
                "workspace": bindings[0].0,
                "workspace_uuid": bindings[1].1
            }
        }))
        .unwrap();
        let error = handle_command(&mux, client, mismatched.cmd, &writer).unwrap_err();
        assert!(error.to_string().contains("refer to different entities"));
    }

    #[test]
    fn one_client_can_open_windows_with_independent_presentation_selection() {
        let mux = test_mux();
        mux.new_workspace(Some("first".into()), None).unwrap();
        mux.new_workspace(Some("second".into()), None).unwrap();
        let bindings = mux.with_state(|state| {
            state
                .workspaces
                .iter()
                .map(|workspace| {
                    let screen = &workspace.screens[0];
                    let mut panes = Vec::new();
                    screen.root.pane_ids(&mut panes);
                    let pane = state.panes.get(&panes[0]).unwrap();
                    let surface = state.surfaces.get(&pane.tabs[0]).unwrap();
                    (workspace.uuid, screen.uuid, pane.uuid, surface.uuid)
                })
                .collect::<Vec<_>>()
        });
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let topology_revision = mux.topology_revision();

        let first = handle_command(
            &mux,
            client,
            Command::OpenPresentation {
                view: PresentationView {
                    workspace_uuid: Some(bindings[0].0),
                    screen_uuid: Some(bindings[0].1),
                    pane_uuid: Some(bindings[0].2),
                    surface_uuid: Some(bindings[0].3),
                    ..PresentationView::default()
                },
                zoom: PresentationZoom {
                    pane_uuid: Some(bindings[0].2),
                    ..PresentationZoom::default()
                },
                scroll: PresentationScroll {
                    surface_uuid: Some(bindings[0].3),
                    offset: 21,
                    ..PresentationScroll::default()
                },
            },
            &writer,
        )
        .unwrap();
        let second = handle_command(
            &mux,
            client,
            Command::OpenPresentation {
                view: PresentationView {
                    workspace_uuid: Some(bindings[1].0),
                    screen_uuid: Some(bindings[1].1),
                    pane_uuid: Some(bindings[1].2),
                    surface_uuid: Some(bindings[1].3),
                    ..PresentationView::default()
                },
                zoom: PresentationZoom::default(),
                scroll: PresentationScroll::default(),
            },
            &writer,
        )
        .unwrap();

        assert_ne!(first["presentation_id"], second["presentation_id"]);
        uuid::Uuid::parse_str(first["presentation_id"].as_str().unwrap()).unwrap();
        uuid::Uuid::parse_str(second["presentation_id"].as_str().unwrap()).unwrap();
        let listed = handle_command(&mux, client, Command::ListPresentations, &writer).unwrap();
        assert_eq!(listed.as_array().unwrap().len(), 2);
        assert!(listed.as_array().unwrap().iter().any(|presentation| {
            presentation["view"]["workspace_uuid"] == bindings[0].0.to_string()
                && presentation["view"]["surface_uuid"] == bindings[0].3.to_string()
                && presentation["zoom"]["pane_uuid"] == bindings[0].2.to_string()
                && presentation["scroll"]["offset"] == 21
                && presentation["generation"] == 1
        }));
        assert!(listed.as_array().unwrap().iter().any(|presentation| {
            presentation["view"]["workspace_uuid"] == bindings[1].0.to_string()
                && presentation["view"]["surface_uuid"] == bindings[1].3.to_string()
                && presentation["zoom"]["pane_uuid"].is_null()
                && presentation["scroll"]["offset"] == 0
        }));
        assert_eq!(mux.with_state(|state| state.workspaces.len()), 2);
        assert_eq!(mux.topology_revision(), topology_revision);

        let first_id = first["presentation_id"].as_str().unwrap().parse().unwrap();
        assert_eq!(
            handle_command(
                &mux,
                client,
                Command::ClosePresentation { presentation_id: first_id },
                &writer,
            )
            .unwrap(),
            json!({})
        );
        let remaining = handle_command(&mux, client, Command::ListPresentations, &writer).unwrap();
        assert_eq!(remaining.as_array().unwrap().len(), 1);
        assert_eq!(remaining[0]["presentation_id"], second["presentation_id"]);
    }

    #[test]
    fn projection_state_survives_disconnect_while_live_presentations_do_not() {
        let mux = test_mux();
        mux.new_workspace(Some("durable-window".into()), None).unwrap();
        let (workspace_uuid, screen_uuid) = mux.with_state(|state| {
            let workspace = &state.workspaces[0];
            (workspace.uuid, workspace.screens[0].uuid)
        });
        let topology_revision = mux.canonical_topology_revision();
        let writer = test_writer();
        let logical_client = uuid::Uuid::new_v4();
        let logical_presentation_id = uuid::Uuid::new_v4();

        let first = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        handle_command(
            &mux,
            first,
            Command::RegisterClient {
                protocol_min: 9,
                protocol_max: 9,
                client_uuid: logical_client,
                process_instance_uuid: uuid::Uuid::new_v4(),
                client_kind: None,
            },
            &writer,
        )
        .unwrap();
        let transient = handle_command(
            &mux,
            first,
            Command::OpenPresentation {
                view: PresentationView {
                    workspace_uuid: Some(workspace_uuid),
                    screen_uuid: Some(screen_uuid),
                    ..Default::default()
                },
                zoom: Default::default(),
                scroll: Default::default(),
            },
            &writer,
        )
        .unwrap();
        assert_eq!(mux.presentations.list_for_client(first).len(), 1);

        let claimed = handle_command(
            &mux,
            first,
            Command::ClaimProjectionState { logical_presentation_id },
            &writer,
        )
        .unwrap();
        let claim_id = claimed["claim_id"].as_str().unwrap().parse().unwrap();
        let generation = claimed["generation"].as_u64().unwrap();
        let updated = handle_command(
            &mux,
            first,
            Command::UpdateProjectionState {
                logical_presentation_id,
                claim_id,
                expected_generation: generation,
                workspaces: vec![ProjectionWorkspaceState {
                    workspace_uuid,
                    selected_screen_uuid: screen_uuid,
                }],
            },
            &writer,
        )
        .unwrap();
        assert_eq!(updated["workspaces"].as_array().unwrap().len(), 1);
        assert_eq!(mux.canonical_topology_revision(), topology_revision);

        assert!(disconnect_client(&mux, first, false));
        assert!(mux.presentations.list_for_client(first).is_empty());
        assert!(
            mux.renderer_worker_statuses()
                .iter()
                .all(|worker| worker.visible_presentation_count == 0)
        );

        let second = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let second_process = uuid::Uuid::new_v4();
        handle_command(
            &mux,
            second,
            Command::RegisterClient {
                protocol_min: 9,
                protocol_max: 9,
                client_uuid: logical_client,
                process_instance_uuid: second_process,
                client_kind: None,
            },
            &writer,
        )
        .unwrap();
        let listed = handle_command(&mux, second, Command::ListProjectionStates, &writer).unwrap();
        assert_eq!(listed.as_array().unwrap().len(), 1);
        assert_eq!(listed[0]["logical_presentation_id"], logical_presentation_id.to_string());
        assert!(listed[0]["claim_id"].is_null());
        assert_eq!(listed[0]["workspaces"][0]["workspace_uuid"], workspace_uuid.to_string());

        let reclaimed = handle_command(
            &mux,
            second,
            Command::ClaimProjectionState { logical_presentation_id },
            &writer,
        )
        .unwrap();
        assert_ne!(reclaimed["claim_id"], claim_id.to_string());
        assert_eq!(reclaimed["claimed_process_instance_uuid"], second_process.to_string());
        assert!(
            reclaimed["generation"].as_u64().unwrap() > updated["generation"].as_u64().unwrap()
        );
        assert_eq!(mux.canonical_topology_revision(), topology_revision);
        assert!(!transient["presentation_id"].is_null());
    }

    #[test]
    fn presentation_updates_validate_ancestry_ownership_and_generation() {
        let mux = test_mux();
        mux.new_workspace(Some("first".into()), None).unwrap();
        mux.new_workspace(Some("second".into()), None).unwrap();
        let bindings = mux.with_state(|state| {
            state
                .workspaces
                .iter()
                .map(|workspace| {
                    let screen = &workspace.screens[0];
                    let pane = state.panes.get(&screen.active_pane).unwrap();
                    let surface = state.surfaces.get(&pane.tabs[0]).unwrap();
                    (workspace.uuid, screen.uuid, pane.uuid, surface.uuid)
                })
                .collect::<Vec<_>>()
        });
        let writer = test_writer();
        let owner = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let other = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let first_view = PresentationView {
            workspace_uuid: Some(bindings[0].0),
            screen_uuid: Some(bindings[0].1),
            pane_uuid: Some(bindings[0].2),
            surface_uuid: Some(bindings[0].3),
            ..PresentationView::default()
        };
        let opened = handle_command(
            &mux,
            owner,
            Command::OpenPresentation {
                view: first_view.clone(),
                zoom: PresentationZoom::default(),
                scroll: PresentationScroll::default(),
            },
            &writer,
        )
        .unwrap();
        let presentation_id = opened["presentation_id"].as_str().unwrap().parse().unwrap();
        assert_eq!(opened["generation"], 1);

        let unchanged = handle_command(
            &mux,
            owner,
            Command::UpdatePresentation {
                presentation_id,
                expected_generation: 1,
                view: Some(first_view),
                zoom: None,
                scroll: None,
            },
            &writer,
        )
        .unwrap();
        assert_eq!(unchanged["generation"], 1);

        let second_view = PresentationView {
            workspace_uuid: Some(bindings[1].0),
            screen_uuid: Some(bindings[1].1),
            pane_uuid: Some(bindings[1].2),
            surface_uuid: Some(bindings[1].3),
            ..PresentationView::default()
        };
        let changed = handle_command(
            &mux,
            owner,
            Command::UpdatePresentation {
                presentation_id,
                expected_generation: 1,
                view: Some(second_view.clone()),
                zoom: None,
                scroll: None,
            },
            &writer,
        )
        .unwrap();
        assert_eq!(changed["generation"], 2);

        let stale = handle_command(
            &mux,
            owner,
            Command::UpdatePresentation {
                presentation_id,
                expected_generation: 1,
                view: Some(PresentationView {
                    workspace_uuid: Some(bindings[0].0),
                    screen_uuid: Some(bindings[1].1),
                    pane_uuid: Some(bindings[1].2),
                    surface_uuid: Some(bindings[1].3),
                    ..PresentationView::default()
                }),
                zoom: None,
                scroll: None,
            },
            &writer,
        )
        .unwrap_err();
        assert!(stale.to_string().contains("stale presentation generation"));

        let wrong_owner = handle_command(
            &mux,
            other,
            Command::UpdatePresentation {
                presentation_id,
                expected_generation: 2,
                view: Some(second_view),
                zoom: None,
                scroll: None,
            },
            &writer,
        )
        .unwrap_err();
        assert!(wrong_owner.to_string().contains("owned by another client"));

        let invalid = handle_command(
            &mux,
            owner,
            Command::UpdatePresentation {
                presentation_id,
                expected_generation: 2,
                view: Some(PresentationView {
                    workspace_uuid: Some(bindings[0].0),
                    screen_uuid: Some(bindings[1].1),
                    pane_uuid: Some(bindings[1].2),
                    surface_uuid: Some(bindings[1].3),
                    ..PresentationView::default()
                }),
                zoom: None,
                scroll: None,
            },
            &writer,
        )
        .unwrap_err();
        assert!(invalid.to_string().contains("outside its workspace"));
        let current = handle_command(&mux, owner, Command::ListPresentations, &writer).unwrap();
        assert_eq!(current[0]["generation"], 2);
        assert_eq!(current[0]["view"]["workspace_uuid"], bindings[1].0.to_string());
    }

    #[test]
    fn list_workspaces_returns_tree_and_revision_from_one_canonical_snapshot() {
        let mux = test_mux();
        let initial = handle_command(&mux, 0, Command::ListWorkspaces, &test_writer()).unwrap();
        assert_eq!(initial["topology_revision"], 0);
        assert!(initial["workspaces"].as_array().unwrap().is_empty());

        mux.new_workspace(Some("first".to_string()), None).unwrap();
        let created = handle_command(&mux, 0, Command::ListWorkspaces, &test_writer()).unwrap();
        assert_eq!(created["topology_revision"], 1);
        assert_eq!(created["workspaces"].as_array().unwrap().len(), 1);
        assert_eq!(created["workspaces"][0]["name"], "first");
    }

    #[test]
    fn terminal_activity_wire_is_registered_reader_specific_and_idempotent() {
        let mux = test_mux();
        let first = mux.new_workspace(Some("activity".to_string()), None).unwrap();
        let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        mux.new_tab(Some(pane), None, None).unwrap();
        let unregistered_writer = test_writer();
        let unregistered =
            mux.control_clients.register(ClientTransport::Unix, unregistered_writer.clone());
        let error = handle_command(
            &mux,
            unregistered,
            Command::TerminalActivitySnapshot,
            &unregistered_writer,
        )
        .unwrap_err();
        let error = error.to_string();
        assert!(error.contains("register-client") || error.contains("protocol v9"));

        let reader_a_writer = test_writer();
        let reader_b_writer = test_writer();
        let (reader_a, reader_a_uuid) = register_v9_client(&mux, &reader_a_writer);
        let (reader_b, reader_b_uuid) = register_v9_client(&mux, &reader_b_writer);
        mux.post_notification(
            "private title".to_string(),
            "private body".to_string(),
            NotificationLevel::Warning,
            Some(first.id),
        )
        .unwrap();

        let snapshot_a =
            handle_command(&mux, reader_a, Command::TerminalActivitySnapshot, &reader_a_writer)
                .unwrap();
        let snapshot_b =
            handle_command(&mux, reader_b, Command::TerminalActivitySnapshot, &reader_b_writer)
                .unwrap();
        assert_eq!(snapshot_a["reader_uuid"], reader_a_uuid.to_string());
        assert_eq!(snapshot_b["reader_uuid"], reader_b_uuid.to_string());
        assert!(snapshot_a["receipts"].as_array().unwrap().is_empty());
        assert!(snapshot_b["receipts"].as_array().unwrap().is_empty());
        let sequence = snapshot_a["facts"][0]["sequence"].as_u64().unwrap();
        assert_eq!(snapshot_a["facts"], snapshot_b["facts"]);
        let encoded = snapshot_a.to_string();
        assert!(!encoded.contains("private title"));
        assert!(!encoded.contains("private body"));

        let first_receipt = handle_command(
            &mux,
            reader_a,
            Command::MarkTerminalSeen { surface_uuid: first.uuid, activity_sequence: sequence },
            &reader_a_writer,
        )
        .unwrap();
        assert_eq!(first_receipt["reader_uuid"], reader_a_uuid.to_string());
        assert_eq!(first_receipt["seen_sequence"], sequence);
        let duplicate = handle_command(
            &mux,
            reader_a,
            Command::MarkTerminalSeen { surface_uuid: first.uuid, activity_sequence: sequence },
            &reader_a_writer,
        )
        .unwrap();
        assert_eq!(duplicate, first_receipt);
        let future = handle_command(
            &mux,
            reader_a,
            Command::MarkTerminalSeen { surface_uuid: first.uuid, activity_sequence: sequence + 1 },
            &reader_a_writer,
        )
        .unwrap_err();
        assert!(future.to_string().contains("beyond current sequence"));

        mux.post_notification(
            "next title".to_string(),
            "next body".to_string(),
            NotificationLevel::Error,
            Some(first.id),
        )
        .unwrap();
        let latest =
            handle_command(&mux, reader_a, Command::TerminalActivitySnapshot, &reader_a_writer)
                .unwrap()["facts"][0]["sequence"]
                .as_u64()
                .unwrap();
        assert_eq!(latest, sequence + 1);
        handle_command(
            &mux,
            reader_a,
            Command::MarkTerminalSeen { surface_uuid: first.uuid, activity_sequence: latest },
            &reader_a_writer,
        )
        .unwrap();
        let stale = handle_command(
            &mux,
            reader_a,
            Command::MarkTerminalSeen { surface_uuid: first.uuid, activity_sequence: sequence },
            &reader_a_writer,
        )
        .unwrap();
        assert_eq!(stale["seen_sequence"], latest);

        let listed_a =
            handle_command(&mux, reader_a, Command::ListWorkspaces, &reader_a_writer).unwrap();
        let listed_b =
            handle_command(&mux, reader_b, Command::ListWorkspaces, &reader_b_writer).unwrap();
        let first_tab_a = &listed_a["workspaces"][0]["screens"][0]["panes"][0]["tabs"][0];
        let first_tab_b = &listed_b["workspaces"][0]["screens"][0]["panes"][0]["tabs"][0];
        assert_eq!(first_tab_a["uuid"], first.uuid.to_string());
        assert!(first_tab_a["notification"].is_null());
        assert_eq!(first_tab_b["uuid"], first.uuid.to_string());
        assert_eq!(first_tab_b["notification"]["unread"], true);
    }

    #[test]
    fn surface_creation_returns_its_complete_canonical_placement() {
        let mux = test_mux();
        let created = handle_command(
            &mux,
            0,
            Command::NewWorkspace {
                name: Some("placement".to_string()),
                cwd: None,
                argv: None,
                command: None,
                env: Vec::new(),
                initial_input: None,
                wait_after_command: false,
                cols: Some(80),
                rows: Some(24),
            },
            &test_writer(),
        )
        .unwrap();

        let surface = created["surface"].as_u64().unwrap();
        mux.with_state(|state| {
            let pane = state.pane_of(surface).unwrap();
            let (workspace_index, screen_index) = state.screen_of(pane).unwrap();
            assert_eq!(created["pane"], pane);
            assert_eq!(
                created["screen"],
                state.workspaces[workspace_index].screens[screen_index].id
            );
            assert_eq!(created["workspace"], state.workspaces[workspace_index].id);
        });
    }

    #[test]
    fn ensure_terminals_wire_maximum_batch_materializes_in_one_revision() {
        const TERMINAL_COUNT: usize = 1_024;

        let mux = test_mux();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let identities = (0..TERMINAL_COUNT)
            .map(|_| (WorkspaceUuid::new(), SurfaceUuid::new()))
            .collect::<Vec<_>>();
        let wire_request = json!({
            "id": 1,
            "cmd": "ensure-terminals",
            "terminals": identities.iter().map(|(workspace_uuid, surface_uuid)| json!({
                "workspace_uuid": workspace_uuid,
                "surface_uuid": surface_uuid,
                "cwd": "/tmp",
                "argv": ["/bin/sh"],
                "env": [{"name": "CMUX_BATCH_TEST", "value": "1"}],
                "cols": 90,
                "rows": 30,
            })).collect::<Vec<_>>(),
        });
        let subscription = match mux.subscribe_topology(
            mux.daemon_instance_id,
            mux.session_id,
            mux.canonical_topology_revision(),
        ) {
            TopologyResume::Subscribed(subscription) => subscription,
            TopologyResume::ResnapshotRequired(required) => {
                panic!("fresh topology subscription was rejected: {:?}", required.reason)
            }
        };

        let encoded_wire_request = wire_request.to_string();
        let decoded_cost =
            account_json_decode(&encoded_wire_request, BULK_COMMAND_DECODE_MAX_BYTES).unwrap();
        assert_eq!(encoded_wire_request.len(), 216_111);
        assert_eq!(decoded_cost, 2_867_916);
        let permit = preflight_request(&mux, client, &encoded_wire_request, None).unwrap();
        assert_eq!(permit.bytes(), 3_300_138);
        assert!(permit.bytes() <= INBOUND_INFLIGHT_MAX_BYTES);
        drop(permit);

        let request: Request = serde_json::from_value(wire_request.clone()).unwrap();
        let placements = handle_command(&mux, client, request.cmd, &writer).unwrap();
        let placements = placements.as_array().unwrap();
        assert_eq!(placements.len(), TERMINAL_COUNT);
        assert!(placements.iter().all(|placement| placement["created"] == true));
        assert!(placements.iter().zip(&identities).all(
            |(placement, (workspace_uuid, surface_uuid))| {
                placement["workspace_uuid"] == workspace_uuid.to_string()
                    && placement["surface_uuid"] == surface_uuid.to_string()
            }
        ));
        let delta = subscription.receiver.recv().unwrap();
        assert_eq!(delta.base_revision, 0);
        assert_eq!(delta.revision, 1);
        assert_eq!(delta.operation, crate::TopologyOperation::LayoutApplied);
        assert_eq!(delta.targets.workspaces.len(), TERMINAL_COUNT);
        assert_eq!(delta.targets.surfaces.len(), TERMINAL_COUNT);
        assert!(matches!(subscription.receiver.try_recv(), Err(TryRecvError::Empty)));

        let retry: Request = serde_json::from_value(wire_request).unwrap();
        let retried = handle_command(&mux, client, retry.cmd, &writer).unwrap();
        assert!(retried.as_array().unwrap().iter().all(|placement| placement["created"] == false));
        assert_eq!(mux.canonical_topology_revision(), 1);
        assert!(matches!(subscription.receiver.try_recv(), Err(TryRecvError::Empty)));
    }

    #[test]
    fn client_cannot_close_another_clients_presentation() {
        let mux = test_mux();
        let writer = test_writer();
        let owner = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let other = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let opened = handle_command(
            &mux,
            owner,
            Command::OpenPresentation {
                view: PresentationView::default(),
                zoom: PresentationZoom::default(),
                scroll: PresentationScroll::default(),
            },
            &writer,
        )
        .unwrap();
        let presentation_id = opened["presentation_id"].as_str().unwrap().parse().unwrap();

        let error =
            handle_command(&mux, other, Command::ClosePresentation { presentation_id }, &writer)
                .unwrap_err();
        assert!(error.to_string().contains("owned by another client"));
        assert_eq!(
            handle_command(&mux, owner, Command::ListPresentations, &writer)
                .unwrap()
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert_eq!(
            handle_command(&mux, other, Command::ListPresentations, &writer)
                .unwrap()
                .as_array()
                .unwrap()
                .len(),
            0
        );
    }

    #[test]
    fn disconnect_removes_only_the_disconnected_clients_presentations() {
        let mux = test_mux();
        let writer = test_writer();
        let departing = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let remaining = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        for client in [departing, departing, remaining] {
            handle_command(
                &mux,
                client,
                Command::OpenPresentation {
                    view: PresentationView::default(),
                    zoom: PresentationZoom::default(),
                    scroll: PresentationScroll::default(),
                },
                &writer,
            )
            .unwrap();
        }

        assert!(disconnect_client(&mux, departing, false));
        assert!(mux.presentations.list_for_client(departing).is_empty());
        assert_eq!(mux.presentations.list_for_client(remaining).len(), 1);
        assert_eq!(
            handle_command(&mux, remaining, Command::ListPresentations, &writer)
                .unwrap()
                .as_array()
                .unwrap()
                .len(),
            1
        );
    }

    #[test]
    fn client_info_is_sanitized_recallable_and_clamped_to_64_characters() {
        let mux = test_mux();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let events = mux.subscribe();

        handle_command(
            &mux,
            client,
            Command::SetClientInfo {
                name: Some("\u{1b}]0;evil\u{07}name".to_string()),
                kind: Some("web".to_string()),
            },
            &writer,
        )
        .unwrap();
        let data = handle_command(&mux, client, Command::ListClients, &writer).unwrap();
        assert_eq!(data[0]["name"], " ]0;evil name");

        handle_command(
            &mux,
            client,
            Command::SetClientInfo { name: Some("n".repeat(80)), kind: None },
            &writer,
        )
        .unwrap();
        handle_command(
            &mux,
            client,
            Command::SetClientInfo { name: None, kind: Some("tui".to_string()) },
            &writer,
        )
        .unwrap();

        let data = handle_command(&mux, client, Command::ListClients, &writer).unwrap();
        let listed = &data[0];
        assert_eq!(listed["name"].as_str().unwrap().chars().count(), 64);
        assert_eq!(listed["kind"], "tui");
        assert_eq!(listed["self"], true);
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::ClientChanged { client: id, kind: Some(kind), .. })
                if id == client && kind == "web"
        ));
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::ClientChanged { client: id, kind: Some(kind), .. })
                if id == client && kind == "web"
        ));
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::ClientChanged { client: id, kind: Some(kind), .. })
                if id == client && kind == "tui"
        ));
    }

    #[test]
    fn client_sizing_command_updates_list_clients() {
        let mux = test_mux();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());

        let listed = handle_command(&mux, client, Command::ListClients, &writer).unwrap();
        assert_eq!(listed[0]["size_participating"], true);

        handle_command(
            &mux,
            client,
            Command::SetClientSizing { client: Some(client), enabled: false, exclusive: false },
            &writer,
        )
        .unwrap();
        let listed = handle_command(&mux, client, Command::ListClients, &writer).unwrap();
        assert_eq!(listed[0]["size_participating"], false);
    }

    #[test]
    fn client_sizing_command_applies_exclusive_and_all_modes_atomically() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((120, 40))).unwrap();
        let first_writer = test_writer();
        let second_writer = test_writer();
        let first = mux.control_clients.register(ClientTransport::Unix, first_writer.clone());
        let second = mux.control_clients.register(ClientTransport::Unix, second_writer.clone());
        for (client, writer, size) in
            [(first, &first_writer, (120, 40)), (second, &second_writer, (80, 30))]
        {
            let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
            mux.control_clients.attach_surface(client, surface.id, stream).unwrap();
            handle_command(
                &mux,
                client,
                Command::ResizeSurface { surface: surface.id, cols: size.0, rows: size.1 },
                writer,
            )
            .unwrap();
        }
        assert_eq!(surface.size(), (80, 30));

        handle_command(
            &mux,
            first,
            Command::SetClientSizing { client: Some(first), enabled: true, exclusive: true },
            &first_writer,
        )
        .unwrap();
        assert_eq!(surface.size(), (120, 40));
        assert!(mux.client_size_participates(first));
        assert!(!mux.client_size_participates(second));

        handle_command(
            &mux,
            first,
            Command::SetClientSizing { client: None, enabled: true, exclusive: false },
            &first_writer,
        )
        .unwrap();
        assert_eq!(surface.size(), (80, 30));
        assert!(mux.client_size_participates(first));
        assert!(mux.client_size_participates(second));
    }

    #[test]
    fn releasing_surface_size_keeps_attach_but_removes_visibility_lease() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((120, 40))).unwrap();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(client, surface.id, stream).unwrap();
        let events = mux.subscribe();

        handle_command(
            &mux,
            client,
            Command::ResizeSurface { surface: surface.id, cols: 80, rows: 24 },
            &writer,
        )
        .unwrap();
        assert_eq!(mux.client_surface_size(surface.id, client), Some((80, 24)));
        assert!((0..4).any(|_| matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::ClientChanged { client: id, .. }) if id == client
        )));

        handle_command(&mux, client, Command::ReleaseSurfaceSize { surface: surface.id }, &writer)
            .unwrap();
        assert_eq!(mux.client_surface_size(surface.id, client), None);
        let listed = handle_command(&mux, client, Command::ListClients, &writer).unwrap();
        assert_eq!(listed[0]["attached"], json!([surface.id]));
        assert_eq!(listed[0]["sizes"][0]["cols"], Value::Null);
        assert_eq!(listed[0]["sizes"][0]["rows"], Value::Null);
        assert!((0..4).any(|_| matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::ClientChanged { client: id, .. }) if id == client
        )));
    }

    #[test]
    fn attached_unreported_client_suppresses_global_ignore_size_fallback() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((100, 40))).unwrap();
        let reporter_writer = test_writer();
        let reporter = mux.control_clients.register(ClientTransport::Unix, reporter_writer.clone());
        let reporter_stream = reporter_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(reporter, surface.id, reporter_stream).unwrap();
        handle_command(
            &mux,
            reporter,
            Command::ResizeSurface { surface: surface.id, cols: 100, rows: 40 },
            &reporter_writer,
        )
        .unwrap();
        handle_command(
            &mux,
            reporter,
            Command::SetClientSizing { client: Some(reporter), enabled: false, exclusive: false },
            &reporter_writer,
        )
        .unwrap();

        let blocker_writer = test_writer();
        let blocker = mux.control_clients.register(ClientTransport::Unix, blocker_writer.clone());
        let blocker_stream = blocker_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(blocker, surface.id, blocker_stream).unwrap();

        handle_command(
            &mux,
            reporter,
            Command::ResizeSurface { surface: surface.id, cols: 70, rows: 20 },
            &reporter_writer,
        )
        .unwrap();
        assert_eq!(surface.size(), (100, 40));

        handle_command(
            &mux,
            blocker,
            Command::SetClientSizing { client: Some(blocker), enabled: false, exclusive: false },
            &blocker_writer,
        )
        .unwrap();
        assert_eq!(surface.size(), (70, 20));
    }

    #[test]
    fn final_stream_detach_restores_excluded_report_fallback() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((100, 40))).unwrap();
        let reporter_writer = test_writer();
        let reporter = mux.control_clients.register(ClientTransport::Unix, reporter_writer.clone());
        let reporter_stream = reporter_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(reporter, surface.id, reporter_stream).unwrap();
        handle_command(
            &mux,
            reporter,
            Command::ResizeSurface { surface: surface.id, cols: 70, rows: 20 },
            &reporter_writer,
        )
        .unwrap();
        handle_command(
            &mux,
            reporter,
            Command::SetClientSizing { client: Some(reporter), enabled: false, exclusive: false },
            &reporter_writer,
        )
        .unwrap();

        let blocker_writer = test_writer();
        let blocker = mux.control_clients.register(ClientTransport::Unix, blocker_writer.clone());
        let blocker_stream = blocker_writer.start_stream(&json!({"event": "test"})).unwrap();
        let blocker_stream_id = blocker_stream.id;
        mux.control_clients.attach_surface(blocker, surface.id, blocker_stream).unwrap();
        mux.resize_surface(surface.id, 100, 40).unwrap();

        assert!(mux.control_clients.detach_surface(blocker, surface.id, blocker_stream_id));
        mux.remove_surface_size_client(surface.id, blocker);

        assert_eq!(surface.size(), (70, 20));
        assert!(!mux.control_clients.attached_client_ids().contains(&blocker));
    }

    #[test]
    fn final_stream_detach_restores_excluded_reports_on_other_surfaces() {
        let mux = test_mux();
        let blocker_surface = mux.new_workspace(None, Some((100, 40))).unwrap();
        let reported_surface = mux.new_workspace(None, Some((100, 40))).unwrap();
        let reporter_writer = test_writer();
        let reporter = mux.control_clients.register(ClientTransport::Unix, reporter_writer.clone());
        let reporter_stream = reporter_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(reporter, reported_surface.id, reporter_stream).unwrap();
        handle_command(
            &mux,
            reporter,
            Command::ResizeSurface { surface: reported_surface.id, cols: 70, rows: 20 },
            &reporter_writer,
        )
        .unwrap();
        handle_command(
            &mux,
            reporter,
            Command::SetClientSizing { client: Some(reporter), enabled: false, exclusive: false },
            &reporter_writer,
        )
        .unwrap();

        let blocker_writer = test_writer();
        let blocker = mux.control_clients.register(ClientTransport::Unix, blocker_writer.clone());
        let blocker_stream = blocker_writer.start_stream(&json!({"event": "test"})).unwrap();
        let blocker_stream_id = blocker_stream.id;
        mux.control_clients.attach_surface(blocker, blocker_surface.id, blocker_stream).unwrap();
        mux.resize_surface(reported_surface.id, 100, 40).unwrap();

        assert!(mux.control_clients.detach_surface(blocker, blocker_surface.id, blocker_stream_id));
        mux.remove_surface_size_client(blocker_surface.id, blocker);

        assert_eq!(reported_surface.size(), (70, 20));
    }

    #[test]
    fn failed_reducer_resize_restores_registry_size() {
        let mux = test_mux();
        let missing_surface = 99_999;
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(client, missing_surface, stream).unwrap();

        assert!(mux
            .resize_surface_for_control_client_with_reservation(
                missing_surface,
                client,
                70,
                20,
            )
            .is_err());

        let clients = mux.control_clients.list_json(client);
        assert_eq!(clients[0]["sizes"][0]["surface"], missing_surface);
        assert_eq!(clients[0]["sizes"][0]["cols"], Value::Null);
        assert_eq!(clients[0]["sizes"][0]["rows"], Value::Null);
    }

    #[test]
    fn disconnect_cleanup_wins_over_a_waiting_stale_sizing_action() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((100, 40))).unwrap();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(client, surface.id, stream).unwrap();
        mux.resize_surface_for_control_client_with_reservation(surface.id, client, 80, 24).unwrap();

        let lifecycle = mux.lock_client_sizing_lifecycle();
        let (ready_tx, ready_rx) = std::sync::mpsc::sync_channel(1);
        let action_mux = mux.clone();
        let action = std::thread::spawn(move || {
            ready_tx.send(()).unwrap();
            action_mux.set_client_size_participation(client, false)
        });
        ready_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        let removed = mux.control_clients.remove(client).expect("registered client");
        mux.remove_size_client(client);
        drop(removed);
        drop(lifecycle);

        assert_eq!(action.join().unwrap(), None);
        assert!(!mux.control_clients.contains(client));
    }

    #[test]
    fn detached_client_cannot_fall_through_to_direct_resize() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((100, 40))).unwrap();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        assert!(disconnect_client(&mux, client, false));

        let error = handle_command(
            &mux,
            client,
            Command::ResizeSurface { surface: surface.id, cols: 70, rows: 20 },
            &writer,
        )
        .unwrap_err();

        assert!(error.to_string().contains(&format!("unknown client {client}")));
        assert_eq!(surface.size(), (100, 40));
    }

    #[test]
    fn unattached_live_resize_still_obeys_visible_client_minimum() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((100, 40))).unwrap();
        let viewer_writer = test_writer();
        let viewer = mux.control_clients.register(ClientTransport::Unix, viewer_writer.clone());
        let stream = viewer_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(viewer, surface.id, stream).unwrap();
        handle_command(
            &mux,
            viewer,
            Command::ResizeSurface { surface: surface.id, cols: 100, rows: 40 },
            &viewer_writer,
        )
        .unwrap();

        let control_writer = test_writer();
        let control = mux.control_clients.register(ClientTransport::Unix, control_writer.clone());
        handle_command(
            &mux,
            control,
            Command::ResizeSurface { surface: surface.id, cols: 120, rows: 50 },
            &control_writer,
        )
        .unwrap();
        assert_eq!(surface.size(), (100, 40));

        handle_command(
            &mux,
            control,
            Command::ResizeSurface { surface: surface.id, cols: 70, rows: 20 },
            &control_writer,
        )
        .unwrap();
        assert_eq!(surface.size(), (70, 20));

        assert!(disconnect_client(&mux, control, false));
        assert_eq!(surface.size(), (100, 40));
    }

    #[test]
    fn exclusive_sizing_excludes_clients_that_attach_later() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((100, 40))).unwrap();
        let target_writer = test_writer();
        let target = mux.control_clients.register(ClientTransport::Unix, target_writer.clone());
        let target_stream = target_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(target, surface.id, target_stream).unwrap();
        handle_command(
            &mux,
            target,
            Command::ResizeSurface { surface: surface.id, cols: 120, rows: 40 },
            &target_writer,
        )
        .unwrap();
        handle_command(
            &mux,
            target,
            Command::SetClientSizing { client: Some(target), enabled: true, exclusive: true },
            &target_writer,
        )
        .unwrap();

        let later_writer = test_writer();
        let later = mux.control_clients.register(ClientTransport::Unix, later_writer.clone());
        let later_stream = later_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(later, surface.id, later_stream).unwrap();
        handle_command(
            &mux,
            later,
            Command::ResizeSurface { surface: surface.id, cols: 60, rows: 20 },
            &later_writer,
        )
        .unwrap();

        assert_eq!(surface.size(), (120, 40));
        assert!(!mux.client_size_participates(later));
        let clients = mux.control_clients_json(target);
        assert_eq!(
            clients.as_array().unwrap().iter().find(|client| client["client"] == later).unwrap()["size_participating"],
            false
        );
    }

    #[test]
    fn ignored_report_does_not_replace_unsized_creation_default() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((100, 40))).unwrap();

        let blocker_writer = test_writer();
        let blocker = mux.control_clients.register(ClientTransport::Unix, blocker_writer.clone());
        let blocker_stream = blocker_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(blocker, surface.id, blocker_stream).unwrap();

        let reporter_writer = test_writer();
        let reporter = mux.control_clients.register(ClientTransport::Unix, reporter_writer.clone());
        let reporter_stream = reporter_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(reporter, surface.id, reporter_stream).unwrap();
        handle_command(
            &mux,
            reporter,
            Command::SetClientSizing { client: Some(reporter), enabled: false, exclusive: false },
            &reporter_writer,
        )
        .unwrap();
        handle_command(
            &mux,
            reporter,
            Command::ResizeSurface { surface: surface.id, cols: 60, rows: 20 },
            &reporter_writer,
        )
        .unwrap();

        assert_eq!(surface.size(), (100, 40));
        assert_eq!(mux.new_workspace(None, None).unwrap().size(), (100, 40));
    }

    #[test]
    fn reload_config_returns_path_and_emits_request() {
        let mux = test_mux();
        let events = mux.subscribe();
        let data = handle_command(&mux, 0, Command::ReloadConfig, &test_writer()).unwrap();
        assert_eq!(data["reloaded"].as_bool(), Some(true));
        assert!(data.get("path").is_some());
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::ConfigReloadRequested)
        ));
    }

    #[test]
    fn window_title_commands_emit_requests() {
        let mux = test_mux();
        let events = mux.subscribe();

        let data = handle_command(
            &mux,
            0,
            Command::SetWindowTitle { title: "hello".to_string() },
            &test_writer(),
        )
        .unwrap();
        assert_eq!(data, json!({}));
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::WindowTitleRequested(title)) if title == "hello"
        ));

        handle_command(&mux, 0, Command::ClearWindowTitle, &test_writer()).unwrap();
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::WindowTitleRequested(title)) if title.is_empty()
        ));
    }

    #[test]
    fn window_title_osc_uses_osc_0_and_2_and_strips_controls() {
        assert_eq!(window_title_osc("hello").as_slice(), b"\x1b]0;hello\x07\x1b]2;hello\x07");
        assert_eq!(window_title_osc("a\x1bb\x07c").as_slice(), b"\x1b]0;a b c\x07\x1b]2;a b c\x07");
    }

    #[test]
    fn title_changed_event_includes_authoritative_surface_title() {
        let mux = Mux::new(
            "title-event-test",
            SurfaceOptions {
                command: Some(vec![
                    "/bin/sh".to_string(),
                    "-c".to_string(),
                    "printf '\\033]2;server title\\007'; exec cat".to_string(),
                ]),
                ..SurfaceOptions::default()
            },
        );
        let events = mux.subscribe();
        let surface = mux.new_workspace(None, Some((20, 4))).unwrap();
        loop {
            match events.recv_timeout(Duration::from_secs(1)).unwrap() {
                MuxEvent::TitleChanged { surface: id, title }
                    if id == surface.id && title.as_ref() == "server title" =>
                {
                    break;
                }
                _ => {}
            }
        }

        assert_eq!(surface.title(), "server title");
        assert_eq!(
            subscribed_event_json(&MuxEvent::TitleChanged {
                surface: surface.id,
                title: Arc::<str>::from("server title"),
            }),
            json!({
                "event": "title-changed",
                "surface": surface.id,
                "title": "server title",
            })
        );
    }

    #[test]
    fn renderer_config_invalidation_event_carries_full_sparse_default_theme() {
        let mut colors = DefaultColors {
            fg: Some(Rgb { r: 0x11, g: 0x22, b: 0x33 }),
            bg: Some(Rgb { r: 0x44, g: 0x55, b: 0x66 }),
            cursor_blink: Some(false),
            ..DefaultColors::default()
        };
        colors.palette[4] = Some(Rgb { r: 0x77, g: 0x88, b: 0x99 });

        assert_eq!(
            subscribed_event_json(&MuxEvent::RendererConfigInvalidated {
                revision: 7,
                reason: Arc::<str>::from("default-colors-changed"),
                default_colors: colors,
            }),
            json!({
                "event": "renderer-config-invalidated",
                "revision": 7,
                "reason": "default-colors-changed",
                "default_colors": {
                    "fg": "#112233",
                    "bg": "#445566",
                    "cursor": null,
                    "selection_bg": null,
                    "selection_fg": null,
                    "palette": {"4": "#778899"},
                    "cursor_style": null,
                    "cursor_blink": false,
                },
            })
        );
    }

    #[test]
    fn scroll_surface_emits_one_scroll_changed_event() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((20, 4))).unwrap();
        surface
            .try_with_terminal(|term| {
                for i in 0..20 {
                    term.vt_write(format!("line{i}\r\n").as_bytes());
                }
            })
            .unwrap();
        let events = mux.subscribe();

        handle_command(
            &mux,
            0,
            Command::ScrollSurface { surface: surface.id, delta: -5 },
            &test_writer(),
        )
        .unwrap();

        let event = events.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(matches!(
            event,
            MuxEvent::ScrollChanged { surface: id, offset, at_bottom: false }
                if id == surface.id && offset > 0
        ));
        assert!(matches!(events.try_recv(), Err(TryRecvError::Empty)));

        handle_command(
            &mux,
            0,
            Command::ScrollSurface { surface: surface.id, delta: 0 },
            &test_writer(),
        )
        .unwrap();
        assert!(matches!(events.try_recv(), Err(TryRecvError::Empty)));
    }

    #[test]
    fn terminal_key_validates_and_encodes_against_the_canonical_terminal() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((20, 4))).unwrap();

        let result = handle_command(
            &mux,
            0,
            Command::TerminalKey {
                surface: surface.id,
                key: ghostty_vt::sys::GHOSTTY_KEY_A,
                modifiers: 0,
                consumed_modifiers: 0,
                text: "a".to_string(),
                unshifted_codepoint: 'a' as u32,
                action: Some("press".to_string()),
            },
            &test_writer(),
        )
        .unwrap();
        assert_eq!(result["encoded_bytes"], 1);

        let unknown_key = handle_command(
            &mux,
            0,
            Command::TerminalKey {
                surface: surface.id,
                key: ghostty_vt::sys::GHOSTTY_KEY_PASTE + 1,
                modifiers: 0,
                consumed_modifiers: 0,
                text: String::new(),
                unshifted_codepoint: 0,
                action: None,
            },
            &test_writer(),
        )
        .unwrap_err();
        assert!(unknown_key.to_string().contains("unknown terminal key"));

        let control_text = handle_command(
            &mux,
            0,
            Command::TerminalKey {
                surface: surface.id,
                key: ghostty_vt::sys::GHOSTTY_KEY_ENTER,
                modifiers: 0,
                consumed_modifiers: 0,
                text: "\n".to_string(),
                unshifted_codepoint: 0,
                action: None,
            },
            &test_writer(),
        )
        .unwrap_err();
        assert!(control_text.to_string().contains("control character"));

        let impossible_consumed_modifiers = handle_command(
            &mux,
            0,
            Command::TerminalKey {
                surface: surface.id,
                key: ghostty_vt::sys::GHOSTTY_KEY_A,
                modifiers: 0,
                consumed_modifiers: ghostty_vt::sys::GHOSTTY_MODS_SHIFT as u16,
                text: "A".to_string(),
                unshifted_codepoint: 'a' as u32,
                action: None,
            },
            &test_writer(),
        )
        .unwrap_err();
        assert!(
            impossible_consumed_modifiers.to_string().contains("invalid terminal key modifiers")
        );
    }

    #[test]
    fn canonical_terminal_interaction_commands_share_selection_search_copy_and_scroll_state() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((20, 4))).unwrap();
        let surface_uuid = surface.uuid;
        surface
            .try_with_terminal(|terminal| {
                terminal.vt_write(b"alpha-one\r\nbeta\r\nalpha-two");
            })
            .unwrap();

        let initial =
            handle_command(&mux, 0, Command::TerminalState { surface_uuid }, &test_writer())
                .unwrap();
        assert_eq!(initial["surface_uuid"], surface_uuid.to_string());
        assert_eq!(initial["selection"]["has_selection"], false);
        assert_eq!(initial["search"]["active"], false);
        assert!(initial["cursor"]["row"].is_u64());

        let mouse_selection = handle_command(
            &mux,
            0,
            Command::TerminalMouse {
                surface: surface.id,
                action: "press".to_owned(),
                button: Some("left".to_owned()),
                modifiers: 0,
                x: 1.0,
                y: 1.0,
                viewport_width: 160,
                viewport_height: 64,
                cell_width: 8,
                cell_height: 16,
                padding_left: 0,
                padding_top: 0,
                padding_right: 0,
                padding_bottom: 0,
                any_button_pressed: true,
                click_count: 2,
            },
            &test_writer(),
        )
        .unwrap();
        assert_eq!(mouse_selection["route"], "selection");
        assert_eq!(mouse_selection["handled"], true);
        assert_eq!(mouse_selection["state"]["selection"]["text"], "alpha-one");

        let searched = handle_command(
            &mux,
            0,
            Command::TerminalSearch {
                surface_uuid,
                operation: "update".to_owned(),
                query: Some("alpha".to_owned()),
            },
            &test_writer(),
        )
        .unwrap();
        assert_eq!(searched["handled"], true);
        assert_eq!(searched["state"]["search"]["active"], true);
        assert_eq!(searched["state"]["search"]["total_matches"], 2);
        assert_eq!(searched["state"]["search"]["selected_match"], 0);
        assert_eq!(searched["state"]["selection"]["text"], "alpha-one");

        let previous = handle_command(
            &mux,
            0,
            Command::TerminalSearch { surface_uuid, operation: "previous".to_owned(), query: None },
            &test_writer(),
        )
        .unwrap();
        assert_eq!(previous["state"]["search"]["selected_match"], 1);

        let selected = handle_command(
            &mux,
            0,
            Command::TerminalSelection { surface_uuid, operation: "select-all".to_owned() },
            &test_writer(),
        )
        .unwrap();
        assert_eq!(selected["selection"]["has_selection"], true);
        assert!(selected["selection"]["text"].as_str().unwrap().contains("alpha-one"));
        assert!(selected["selection"]["range"]["top_left"]["row"].is_u64());

        let copied = handle_command(
            &mux,
            0,
            Command::TerminalBindingAction {
                surface_uuid,
                action: "copy_to_clipboard".to_owned(),
                repeat_count: 1,
            },
            &test_writer(),
        )
        .unwrap();
        assert_eq!(copied["handled"], true);
        assert!(copied["clipboard_text"].as_str().unwrap().contains("alpha-two"));

        surface.try_with_terminal(|terminal| terminal.vt_write(b"\x1b[1A")).unwrap();

        let entered = handle_command(
            &mux,
            0,
            Command::TerminalCopyMode {
                surface_uuid,
                operation: "enter".to_owned(),
                adjustment: None,
                count: 1,
            },
            &test_writer(),
        )
        .unwrap();
        assert_eq!(entered["state"]["copy_mode"], true);
        assert_eq!(entered["state"]["selection"]["has_selection"], false);
        assert!(entered["state"]["copy_cursor"]["row"].is_u64());

        let started = handle_command(
            &mux,
            0,
            Command::TerminalCopyMode {
                surface_uuid,
                operation: "start-line-selection".to_owned(),
                adjustment: None,
                count: 2,
            },
            &test_writer(),
        )
        .unwrap();
        assert_eq!(started["state"]["selection"]["has_selection"], true);
        let selected_lines = started["state"]["selection"]["text"].as_str().unwrap();
        assert!(selected_lines.contains("beta"));
        assert!(selected_lines.contains("alpha-two"));

        let exited = handle_command(
            &mux,
            0,
            Command::TerminalCopyMode {
                surface_uuid,
                operation: "copy-and-exit".to_owned(),
                adjustment: None,
                count: 1,
            },
            &test_writer(),
        )
        .unwrap();
        assert_eq!(exited["state"]["copy_mode"], false);
        assert!(exited["clipboard_text"].is_string());

        surface
            .try_with_terminal(|terminal| {
                for row in 0..20 {
                    terminal.vt_write(format!("\r\nscroll-{row}").as_bytes());
                }
            })
            .unwrap();
        let top = handle_command(
            &mux,
            0,
            Command::TerminalScroll { surface_uuid, operation: "top".to_owned(), amount: None },
            &test_writer(),
        )
        .unwrap();
        assert_eq!(top["state"]["viewport"]["offset"], 0);
    }
}
