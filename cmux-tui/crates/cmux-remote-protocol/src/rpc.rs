use std::collections::BTreeMap;

use base64::Engine;
use serde::{Deserialize, Serialize};

pub const MUX_INPUT_V1_FEATURE: &str = "mux-input-v1";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ByteString(String);

impl ByteString {
    pub fn from_bytes(bytes: &[u8]) -> Self {
        Self(base64::engine::general_purpose::STANDARD.encode(bytes))
    }

    pub fn decode(&self) -> Result<Vec<u8>, base64::DecodeError> {
        base64::engine::general_purpose::STANDARD.decode(&self.0)
    }

    pub fn encoded(&self) -> &str {
        &self.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
/// Opaque UUID allocated once per request and never reused during an
/// authenticated client session. The JSON string form preserves identity in
/// JavaScript clients.
pub struct RequestId(uuid::Uuid);

impl RequestId {
    pub const fn from_uuid(value: uuid::Uuid) -> Self {
        Self(value)
    }

    pub const fn from_u128(value: u128) -> Self {
        Self(uuid::Uuid::from_u128(value))
    }
}

impl std::fmt::Display for RequestId {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.0.fmt(formatter)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct WorkspaceId(pub String);

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct OperationId(pub String);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ProcessId(pub uuid::Uuid);

impl ProcessId {
    pub const fn from_u128(value: u128) -> Self {
        Self(uuid::Uuid::from_u128(value))
    }

    pub fn parse_str(value: &str) -> Result<Self, uuid::Error> {
        uuid::Uuid::parse_str(value).map(Self)
    }

    pub fn is_nil(self) -> bool {
        self.0.is_nil()
    }
}

impl std::fmt::Display for ProcessId {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.0.fmt(formatter)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct RouteId(pub u64);

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct PageCursor(pub String);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ComputerUseInvocationId(pub uuid::Uuid);

impl ComputerUseInvocationId {
    pub const fn from_u128(value: u128) -> Self {
        Self(uuid::Uuid::from_u128(value))
    }
}

impl std::fmt::Display for ComputerUseInvocationId {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.0.fmt(formatter)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Service {
    MuxControl,
    WorkspaceRpc,
    ProcessStream,
    /// A dedicated, ordered binary CMTH terminal renderer stream.
    ///
    /// Each service stream names exactly one cmux surface. The daemon uses a
    /// short-lived renderer capability to bridge that surface's terminal host;
    /// carriers, authentication, reconnect, and replay remain properties of
    /// the enclosing remote session.
    #[serde(rename = "terminal-bytes-v1")]
    TerminalBytes,
    TcpTunnel,
    ComputerUse,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
pub enum ServiceControl {
    Open { service: Service, metadata: BTreeMap<String, String> },
    Opened { service: Service },
    Rejected { code: String, message: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum RemoteCapability {
    MuxControlV9,
    WorkspaceFilesV1,
    WorkspaceSearchV1,
    WorkspacePatchV1,
    WorkspaceDiffV1,
    ProcessPipesV1,
    ProcessPtyV1,
    TcpRoutesV1,
    ComputerUseNegotiationV1,
    WorkspacePaginationV1,
    WorkspacePatchV2,
    WorkspacePatchV3,
    StructuredDiffV1,
    ProcessLifecycleV2,
    ProcessReplayV1,
    ProcessHandlesV2,
    ProcessCatalogV1,
    ProcessTerminalSnapshotV1,
    RequestControlV1,
    ComputerUseV1,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RpcRequest {
    pub id: RequestId,
    /// Maximum server-side execution time after the request is received.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timeout_ms: Option<u64>,
    pub request: WorkspaceRequest,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RpcResponse {
    pub id: RequestId,
    pub result: Result<WorkspaceResponse, RpcError>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RpcEvent {
    pub sequence: u64,
    pub event: ProcessEvent,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RpcError {
    pub code: String,
    pub message: String,
    pub retryable: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub details: Option<RpcErrorDetails>,
}

impl RpcError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self { code: code.into(), message: message.into(), retryable: false, details: None }
    }

    pub fn with_details(mut self, details: RpcErrorDetails) -> Self {
        self.details = Some(details);
        self
    }
}

impl std::fmt::Display for RpcError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for RpcError {}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
pub enum RpcErrorDetails {
    PatchRollback { failed_paths: Vec<String> },
    ProcessReplayGap { requested_after: u64, range: ProcessReplayRange },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
pub enum WorkspaceRequest {
    Capabilities,
    OpenWorkspace {
        root: String,
    },
    ListWorkspaces,
    Stat {
        workspace: WorkspaceId,
        path: String,
        follow_symlinks: bool,
    },
    ReadFile {
        workspace: WorkspaceId,
        path: String,
        offset: u64,
        limit: u32,
    },
    WriteFile {
        workspace: WorkspaceId,
        path: String,
        data: ByteString,
        precondition: FilePrecondition,
        create_parents: bool,
    },
    ListDirectory {
        workspace: WorkspaceId,
        path: String,
        include_hidden: bool,
        limit: u32,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cursor: Option<PageCursor>,
    },
    Search {
        workspace: WorkspaceId,
        query: String,
        paths: Vec<String>,
        globs: Vec<String>,
        include_hidden: bool,
        max_results: u32,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cursor: Option<PageCursor>,
    },
    ApplyPatch {
        workspace: WorkspaceId,
        patch: String,
        dry_run: bool,
        #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
        preconditions: BTreeMap<String, FilePrecondition>,
    },
    GitStatus {
        workspace: WorkspaceId,
    },
    Diff {
        workspace: WorkspaceId,
        paths: Vec<String>,
        staged: bool,
        context: u16,
        format: DiffFormat,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cursor: Option<PageCursor>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        max_bytes: Option<u32>,
    },
    SpawnProcess {
        workspace: WorkspaceId,
        argv: Vec<String>,
        cwd: Option<String>,
        env: BTreeMap<String, String>,
        #[serde(default)]
        io: ProcessIo,
        lifetime: ProcessLifetime,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        operation: Option<OperationId>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        timeout_ms: Option<u64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        retained_output_bytes: Option<u32>,
        #[serde(default, skip_serializing_if = "ProcessEnvironment::is_inherit")]
        environment: ProcessEnvironment,
    },
    /// Spawn with a caller-generated daemon-wide handle. Clients can reserve a
    /// process stream for this handle before starting the command, so output
    /// cannot race the spawn response.
    SpawnProcessWithHandle {
        process: ProcessId,
        workspace: WorkspaceId,
        argv: Vec<String>,
        cwd: Option<String>,
        env: BTreeMap<String, String>,
        #[serde(default)]
        io: ProcessIo,
        lifetime: ProcessLifetime,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        operation: Option<OperationId>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        timeout_ms: Option<u64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        retained_output_bytes: Option<u32>,
        #[serde(default, skip_serializing_if = "ProcessEnvironment::is_inherit")]
        environment: ProcessEnvironment,
        /// Maximum idle time after the direct child exits while inherited
        /// stdout/stderr descriptors remain open.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        output_drain_idle_timeout_ms: Option<u64>,
        /// Absolute output-drain deadline after the direct child exits.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        output_drain_total_timeout_ms: Option<u64>,
    },
    WriteProcess {
        process: ProcessId,
        write_id: u64,
        data: ByteString,
        eof: bool,
    },
    ResizeProcess {
        process: ProcessId,
        cols: u16,
        rows: u16,
    },
    SignalProcess {
        process: ProcessId,
        signal: ProcessSignal,
    },
    WaitProcess {
        process: ProcessId,
    },
    ReadProcessEvents {
        process: ProcessId,
        after_sequence: u64,
        limit: u32,
    },
    /// Discover every active and recently completed process retained by this
    /// fully authorized daemon. Client scopes are lifecycle leases, not an
    /// authorization boundary, so this catalog is intentionally daemon-wide.
    ListProcesses,
    SnapshotProcessTerminal {
        process: ProcessId,
    },
    FinishOperation {
        operation: OperationId,
    },
    CloseWorkspace {
        workspace: WorkspaceId,
    },
    CancelRequest {
        request: RequestId,
    },
    CreateRoute {
        workspace: WorkspaceId,
        host: String,
        port: u16,
        policy: RoutePolicy,
    },
    CloseRoute {
        route: RouteId,
    },
    ComputerUseCapabilities,
    ComputerUseCapabilitiesV1,
    InvokeComputerUse {
        invocation: ComputerUseInvocation,
    },
    CancelComputerUse {
        invocation: ComputerUseInvocationId,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
pub enum WorkspaceResponse {
    Capabilities {
        capabilities: Vec<RemoteCapability>,
    },
    Workspace {
        id: WorkspaceId,
        root: String,
    },
    Workspaces {
        workspaces: Vec<(WorkspaceId, String)>,
    },
    Stat {
        stat: FileStat,
    },
    File {
        data: ByteString,
        offset: u64,
        eof: bool,
        content_hash: String,
    },
    Written {
        bytes: u64,
        content_hash: String,
    },
    Directory {
        entries: Vec<DirectoryEntry>,
        truncated: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        next_cursor: Option<PageCursor>,
    },
    Search {
        matches: Vec<SearchMatch>,
        truncated: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        next_cursor: Option<PageCursor>,
    },
    Patch {
        changed_paths: Vec<String>,
        applied: bool,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        files: Vec<PatchFileResult>,
    },
    GitStatus {
        status: GitStatus,
    },
    Diff {
        data: ByteString,
        format: DiffFormat,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        next_cursor: Option<PageCursor>,
    },
    StructuredDiff {
        diff: StructuredDiffV1,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        next_cursor: Option<PageCursor>,
    },
    ProcessStarted {
        process: ProcessId,
        pid: Option<u32>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        operation: Option<OperationId>,
    },
    ProcessWriteAccepted {
        process: ProcessId,
        write_id: u64,
    },
    ProcessResized {
        process: ProcessId,
        cols: u16,
        rows: u16,
    },
    ProcessSignaled {
        process: ProcessId,
        signal: ProcessSignal,
    },
    ProcessExit {
        process: ProcessId,
        code: Option<i32>,
        signal: Option<i32>,
    },
    ProcessEvents {
        process: ProcessId,
        range: ProcessReplayRange,
        events: Vec<RpcEvent>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        next_cursor: Option<u64>,
    },
    ProcessReplayGap {
        process: ProcessId,
        requested_after: u64,
        range: ProcessReplayRange,
    },
    Processes {
        processes: Vec<ProcessDescriptor>,
    },
    ProcessTerminalSnapshot {
        snapshot: ProcessTerminalSnapshot,
    },
    OperationFinished {
        operation: OperationId,
        processes_signaled: u32,
    },
    WorkspaceClosed {
        workspace: WorkspaceId,
    },
    RequestCanceled {
        request: RequestId,
        accepted: bool,
    },
    RouteCreated {
        route: RouteId,
        host: String,
        port: u16,
    },
    Closed,
    ComputerUseCapabilities {
        capabilities: Vec<String>,
    },
    ComputerUseCapabilitiesV1 {
        capabilities: Vec<ComputerUseCapability>,
    },
    ComputerUseAccepted {
        invocation: ComputerUseInvocationId,
    },
    ComputerUseResult {
        result: ComputerUseResult,
    },
    ComputerUseCanceled {
        invocation: ComputerUseInvocationId,
        accepted: bool,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum FilePrecondition {
    Any,
    Missing,
    ContentHash(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum PatchFileAction {
    Created,
    Modified,
    Deleted,
    Renamed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PatchFileResult {
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub previous_path: Option<String>,
    pub action: PatchFileAction,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub old_content_hash: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub new_content_hash: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum FileKind {
    File,
    Directory,
    Symlink,
    Other,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileStat {
    pub path: String,
    pub kind: FileKind,
    pub size: u64,
    pub modified_unix_ms: Option<u64>,
    pub executable: bool,
    pub content_hash: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DirectoryEntry {
    pub name: String,
    pub path: String,
    pub kind: FileKind,
    pub size: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SearchMatch {
    pub path: String,
    pub line: u64,
    pub column: u64,
    pub text: String,
    pub before: Vec<String>,
    pub after: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum DiffFormat {
    Unified,
    /// Legacy structured JSON encoded inside `ByteString`.
    Structured,
    StructuredV1,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StructuredDiffV1 {
    pub version: u16,
    pub files: Vec<StructuredFileDiffV1>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StructuredFileDiffV1 {
    pub old_path: Option<String>,
    pub new_path: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub metadata: Vec<String>,
    pub hunks: Vec<StructuredDiffHunkV1>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StructuredDiffHunkV1 {
    pub header: String,
    pub lines: Vec<StructuredDiffLineV1>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StructuredDiffLineV1 {
    pub kind: StructuredDiffLineKind,
    pub text: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum StructuredDiffLineKind {
    Context,
    #[serde(rename = "add")]
    Added,
    #[serde(rename = "delete")]
    Deleted,
    Metadata,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitStatus {
    pub branch: Option<String>,
    pub head: Option<String>,
    pub changes: Vec<GitChange>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitChange {
    pub path: String,
    pub original_path: Option<String>,
    pub index_status: char,
    pub worktree_status: char,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
pub enum ProcessIo {
    Pipes {
        stdin: bool,
    },
    Pty {
        cols: u16,
        rows: u16,
        term: String,
        #[serde(default, skip_serializing_if = "PtyEofPolicy::is_reject")]
        eof: PtyEofPolicy,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ProcessIoKind {
    Pipes,
    Pty,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProcessDescriptor {
    pub process: ProcessId,
    pub workspace: WorkspaceId,
    /// A bounded, control-character-escaped basename suitable for display.
    pub command_label: String,
    /// A bounded, control-character-escaped argv preview. This is display
    /// metadata and must never be treated as an executable command.
    pub display_argv: Vec<String>,
    pub display_argv_truncated: bool,
    /// Resolved daemon-side cwd, escaped and bounded for display.
    pub cwd: String,
    pub lifetime: ProcessLifetime,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub operation: Option<OperationId>,
    pub pid: Option<u32>,
    pub io: ProcessIoKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pty_size: Option<ProcessTerminalSize>,
    pub state: ProcessState,
    pub replay: ProcessReplayRange,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
pub enum ProcessState {
    Running,
    Exited { code: Option<i32>, signal: Option<i32> },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProcessTerminalSize {
    pub cols: u16,
    pub rows: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProcessTerminalColor {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ProcessTerminalCursorStyle {
    Bar,
    Block,
    Underline,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ProcessTerminalUnderline {
    Single,
    Double,
    Curly,
    Dotted,
    Dashed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProcessTerminalStyledRun {
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fg: Option<ProcessTerminalColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bg: Option<ProcessTerminalColor>,
    pub attrs: u16,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub underline: Option<ProcessTerminalUnderline>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub width_hint: Option<u16>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProcessTerminalRow {
    pub row: u16,
    pub runs: Vec<ProcessTerminalStyledRun>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProcessTerminalCursor {
    pub x: u16,
    pub y: u16,
    pub style: ProcessTerminalCursorStyle,
    pub blink: bool,
    pub visible: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<ProcessTerminalColor>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProcessTerminalSnapshot {
    pub process: ProcessId,
    pub size: ProcessTerminalSize,
    pub rows: Vec<ProcessTerminalRow>,
    pub cursor: ProcessTerminalCursor,
    pub default_fg: ProcessTerminalColor,
    pub default_bg: ProcessTerminalColor,
    pub scrollback_rows: u32,
    /// Highest process output sequence applied to this terminal model. A
    /// reconnecting client subscribes after this cursor; after a replay gap it
    /// takes a fresh snapshot and retries from the new cursor.
    pub through_sequence: u64,
}

impl Default for ProcessIo {
    fn default() -> Self {
        Self::Pipes { stdin: true }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum PtyEofPolicy {
    #[default]
    Reject,
    ControlD,
    Hangup,
}

impl PtyEofPolicy {
    pub fn is_reject(&self) -> bool {
        *self == Self::Reject
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ProcessEnvironment {
    #[default]
    Inherit,
    Clean,
}

impl ProcessEnvironment {
    pub fn is_inherit(&self) -> bool {
        *self == Self::Inherit
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ProcessLifetime {
    Operation,
    Workspace,
    Detached,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ProcessSignal {
    Interrupt,
    Terminate,
    Kill,
    Hangup,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProcessReplayRange {
    pub first_available: Option<u64>,
    pub last_produced: u64,
    pub exited: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
pub enum ProcessOutputTruncationReason {
    DrainIdleTimeout { idle_timeout_ms: u64 },
    DrainTotalTimeout { total_timeout_ms: u64 },
    ReadError { stream: ProcessOutputStream, message: String },
    ReaderTaskFailed { message: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ProcessOutputStream {
    Stdout,
    Stderr,
    Pty,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
pub enum ProcessEvent {
    Stdout {
        process: ProcessId,
        sequence: u64,
        data: ByteString,
    },
    Stderr {
        process: ProcessId,
        sequence: u64,
        data: ByteString,
    },
    OutputTruncated {
        process: ProcessId,
        sequence: u64,
        reason: ProcessOutputTruncationReason,
    },
    /// A stream control marker. `RpcEvent.sequence` is the latest sequence
    /// known when the gap was detected and is not a newly produced event.
    ReplayGap {
        process: ProcessId,
        requested_after: u64,
        range: ProcessReplayRange,
    },
    Exit {
        process: ProcessId,
        code: Option<i32>,
        signal: Option<i32>,
    },
}

impl ProcessEvent {
    pub fn is_terminal(&self) -> bool {
        matches!(self, Self::ReplayGap { .. } | Self::Exit { .. })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum RoutePolicy {
    LoopbackOnly,
    PrivateNetwork,
    Any,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ComputerUseFeature {
    Screenshot,
    AccessibilityTree,
    Pointer,
    Keyboard,
    TextInput,
    Scroll,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ComputerUseCapability {
    pub feature: ComputerUseFeature,
    pub version: u16,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ComputerUseInvocation {
    pub id: ComputerUseInvocationId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace: Option<WorkspaceId>,
    pub action: ComputerUseAction,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timeout_ms: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
pub enum ComputerUseAction {
    Screenshot {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        display: Option<u32>,
    },
    AccessibilityTree {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        root: Option<String>,
    },
    Pointer {
        x: i32,
        y: i32,
        action: PointerAction,
    },
    Keyboard {
        key: String,
        action: KeyAction,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        modifiers: Vec<String>,
    },
    TextInput {
        text: String,
    },
    Scroll {
        x: i32,
        y: i32,
        delta_x: i32,
        delta_y: i32,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum PointerAction {
    Move,
    LeftDown,
    LeftUp,
    RightDown,
    RightUp,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum KeyAction {
    Down,
    Up,
    Press,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ComputerUseResult {
    pub invocation: ComputerUseInvocationId,
    pub output: ComputerUseOutput,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
pub enum ComputerUseOutput {
    Acknowledged,
    Screenshot { mime_type: String, data: ByteString, width: u32, height: u32 },
    AccessibilityTree { format: String, data: ByteString },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn terminal_bytes_service_uses_the_versioned_wire_name() {
        let encoded = serde_json::to_value(Service::TerminalBytes).unwrap();
        assert_eq!(encoded, "terminal-bytes-v1");
        assert_eq!(serde_json::from_value::<Service>(encoded).unwrap(), Service::TerminalBytes);
    }

    #[test]
    fn arbitrary_file_bytes_round_trip_through_json() {
        let bytes = ByteString::from_bytes(&[0, 1, 2, 255]);
        let json = serde_json::to_string(&bytes).unwrap();
        let decoded: ByteString = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.decode().unwrap(), [0, 1, 2, 255]);
    }

    #[test]
    fn pty_is_explicit_in_process_request() {
        let request = WorkspaceRequest::SpawnProcess {
            workspace: WorkspaceId("w".into()),
            argv: vec!["bash".into()],
            cwd: None,
            env: BTreeMap::new(),
            io: ProcessIo::Pty {
                cols: 80,
                rows: 24,
                term: "xterm-256color".into(),
                eof: PtyEofPolicy::Reject,
            },
            lifetime: ProcessLifetime::Workspace,
            operation: None,
            timeout_ms: None,
            retained_output_bytes: None,
            environment: ProcessEnvironment::Inherit,
        };
        let json = serde_json::to_value(request).unwrap();
        assert_eq!(json["io"]["type"], "pty");
    }

    #[test]
    fn legacy_spawn_request_defaults_new_lifecycle_fields() {
        let json = serde_json::json!({
            "id": "00000000-0000-4000-8000-000000000007",
            "request": {
                "type": "spawn-process",
                "workspace": "w",
                "argv": ["/bin/sh"],
                "cwd": null,
                "env": {},
                "io": { "type": "pty", "cols": 80, "rows": 24, "term": "xterm-256color" },
                "lifetime": "workspace"
            }
        });
        let request: RpcRequest = serde_json::from_value(json).unwrap();
        assert_eq!(request.timeout_ms, None);
        let WorkspaceRequest::SpawnProcess {
            io,
            operation,
            timeout_ms,
            retained_output_bytes,
            environment,
            ..
        } = request.request
        else {
            panic!()
        };
        assert_eq!(operation, None);
        assert_eq!(timeout_ms, None);
        assert_eq!(retained_output_bytes, None);
        assert_eq!(environment, ProcessEnvironment::Inherit);
        assert!(matches!(io, ProcessIo::Pty { eof: PtyEofPolicy::Reject, .. }));
    }

    #[test]
    fn omitted_process_io_defaults_to_writable_pipes() {
        let request: WorkspaceRequest = serde_json::from_value(serde_json::json!({
            "type": "spawn-process",
            "workspace": "w",
            "argv": ["/bin/sh"],
            "cwd": null,
            "env": {},
            "lifetime": "workspace"
        }))
        .unwrap();

        let WorkspaceRequest::SpawnProcess { io, .. } = request else { panic!() };
        assert_eq!(io, ProcessIo::Pipes { stdin: true });
    }

    #[test]
    fn process_handle_spawn_has_a_stable_wire_shape() {
        let request = WorkspaceRequest::SpawnProcessWithHandle {
            process: ProcessId::from_u128(0x5a17),
            workspace: WorkspaceId("w".into()),
            argv: vec!["/bin/sh".into()],
            cwd: None,
            env: BTreeMap::new(),
            io: ProcessIo::Pipes { stdin: false },
            lifetime: ProcessLifetime::Workspace,
            operation: None,
            timeout_ms: None,
            retained_output_bytes: Some(1024),
            environment: ProcessEnvironment::Clean,
            output_drain_idle_timeout_ms: Some(750),
            output_drain_total_timeout_ms: Some(2_500),
        };

        let json = serde_json::to_value(request).unwrap();
        assert_eq!(json["type"], "spawn-process-with-handle");
        assert_eq!(json["process"], "00000000-0000-0000-0000-000000005a17");
        assert_eq!(json["retained_output_bytes"], 1024);
        assert_eq!(json["environment"], "clean");
        assert_eq!(json["output_drain_idle_timeout_ms"], 750);
        assert_eq!(json["output_drain_total_timeout_ms"], 2_500);
    }

    #[test]
    fn process_handles_are_json_strings() {
        assert!(
            serde_json::to_value(ProcessId::from_u128(0x5a17)).unwrap().is_string(),
            "numeric process handles lose precision in JavaScript clients"
        );
    }

    #[test]
    fn computer_use_invocation_ids_are_json_strings() {
        assert!(
            serde_json::to_value(ComputerUseInvocationId::from_u128(0x5a17)).unwrap().is_string(),
            "numeric computer-use handles lose precision in JavaScript clients"
        );
    }

    #[test]
    fn process_catalog_and_terminal_snapshot_have_stable_wire_shapes() {
        let process = ProcessId::from_u128(0x5a17);
        let descriptor = ProcessDescriptor {
            process,
            workspace: WorkspaceId("workspace-a".into()),
            command_label: "bash".into(),
            display_argv: vec!["/bin/bash".into(), "-l".into()],
            display_argv_truncated: false,
            cwd: "/srv/project".into(),
            lifetime: ProcessLifetime::Detached,
            operation: None,
            pid: Some(42),
            io: ProcessIoKind::Pty,
            pty_size: Some(ProcessTerminalSize { cols: 120, rows: 40 }),
            state: ProcessState::Running,
            replay: ProcessReplayRange {
                first_available: Some(7),
                last_produced: 12,
                exited: false,
            },
        };
        let response = WorkspaceResponse::Processes { processes: vec![descriptor] };
        let json = serde_json::to_value(response).unwrap();
        assert_eq!(json["type"], "processes");
        assert_eq!(json["processes"][0]["process"], process.to_string());
        assert_eq!(json["processes"][0]["io"], "pty");
        assert_eq!(json["processes"][0]["state"]["type"], "running");
        assert!(
            !json["processes"][0].as_object().unwrap().keys().any(|key| key.contains("env")),
            "catalog descriptors must never grow an environment field"
        );

        let snapshot = ProcessTerminalSnapshot {
            process,
            size: ProcessTerminalSize { cols: 4, rows: 1 },
            rows: vec![ProcessTerminalRow {
                row: 0,
                runs: vec![ProcessTerminalStyledRun {
                    text: "cmux".into(),
                    fg: Some(ProcessTerminalColor { r: 255, g: 0, b: 0 }),
                    bg: None,
                    attrs: 1,
                    underline: Some(ProcessTerminalUnderline::Single),
                    width_hint: None,
                }],
            }],
            cursor: ProcessTerminalCursor {
                x: 3,
                y: 0,
                style: ProcessTerminalCursorStyle::Block,
                blink: false,
                visible: true,
                color: None,
            },
            default_fg: ProcessTerminalColor { r: 255, g: 255, b: 255 },
            default_bg: ProcessTerminalColor { r: 0, g: 0, b: 0 },
            scrollback_rows: 2,
            through_sequence: 19,
        };
        let json =
            serde_json::to_value(WorkspaceResponse::ProcessTerminalSnapshot { snapshot }).unwrap();
        assert_eq!(json["type"], "process-terminal-snapshot");
        assert_eq!(json["snapshot"]["through_sequence"], 19);
        assert_eq!(json["snapshot"]["rows"][0]["runs"][0]["underline"], "single");

        assert_eq!(
            serde_json::to_value(WorkspaceRequest::ListProcesses).unwrap()["type"],
            "list-processes"
        );
        assert_eq!(
            serde_json::to_value(WorkspaceRequest::SnapshotProcessTerminal { process }).unwrap()["type"],
            "snapshot-process-terminal"
        );
        assert_eq!(
            serde_json::to_value(RemoteCapability::ProcessCatalogV1).unwrap(),
            "process-catalog-v1"
        );
        assert_eq!(
            serde_json::to_value(RemoteCapability::ProcessTerminalSnapshotV1).unwrap(),
            "process-terminal-snapshot-v1"
        );
    }

    #[test]
    fn request_ids_are_uuid_json_strings() {
        const ENCODED: &str = "\"018f47a2-17d6-4c16-a8b1-7b3d5d998271\"";
        let request: RequestId =
            serde_json::from_str(ENCODED).expect("request ID should decode from a UUID string");

        assert_eq!(serde_json::to_string(&request).unwrap(), ENCODED);
    }

    #[test]
    fn legacy_responses_and_errors_default_new_detail_fields() {
        let patch: WorkspaceResponse = serde_json::from_value(serde_json::json!({
            "type": "patch",
            "changed_paths": ["a.txt"],
            "applied": true
        }))
        .unwrap();
        assert!(matches!(patch, WorkspaceResponse::Patch { files, .. } if files.is_empty()));

        let error: RpcError = serde_json::from_value(serde_json::json!({
            "code": "conflict",
            "message": "changed",
            "retryable": false
        }))
        .unwrap();
        assert_eq!(error.details, None);
    }

    #[test]
    fn legacy_structured_line_names_remain_stable() {
        assert_eq!(serde_json::to_value(StructuredDiffLineKind::Added).unwrap(), "add");
        assert_eq!(serde_json::to_value(StructuredDiffLineKind::Deleted).unwrap(), "delete");
    }
}
