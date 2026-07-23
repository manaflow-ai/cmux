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
/// Opaque identifier unique among requests active in one authenticated client
/// session. Independent humans may safely use the same numeric request ID.
pub struct RequestId(pub u64);

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct WorkspaceId(pub String);

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct OperationId(pub String);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ProcessId(pub u64);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct RouteId(pub u64);

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct PageCursor(pub String);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ComputerUseInvocationId(pub u64);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Service {
    MuxControl,
    WorkspaceRpc,
    ProcessStream,
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
    StructuredDiffV1,
    ProcessLifecycleV2,
    ProcessReplayV1,
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
pub enum ProcessEvent {
    Stdout { process: ProcessId, sequence: u64, data: ByteString },
    Stderr { process: ProcessId, sequence: u64, data: ByteString },
    Exit { process: ProcessId, code: Option<i32>, signal: Option<i32> },
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
            "id": 7,
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
