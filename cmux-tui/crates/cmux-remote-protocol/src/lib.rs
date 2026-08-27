//! Transport-neutral protocol types for cmux remote sessions.
//!
//! This crate intentionally contains no sockets, async runtime, cryptography,
//! filesystem access, or process management. Native transports and the
//! Cloudflare Durable Object relay share these types without sharing runtime
//! dependencies.

mod frame;
mod relay;
mod rpc;

pub use frame::{
    FrameDecodeError, FrameFlags, Lane, LanePolicy, MAX_FRAME_PAYLOAD, MAX_WIRE_FRAME_BYTES,
    REMOTE_PROTOCOL_VERSION, SessionId, WireFrame,
};
pub use relay::{
    CircuitId, LaneToken, MAX_RELAY_BATCH_BYTES, RelayControl, RelayPermission, RelayRole,
    RelaySocketAttachment, RelayTicketClaims,
};
pub use rpc::{
    ByteString, ComputerUseAction, ComputerUseCapability, ComputerUseFeature,
    ComputerUseInvocation, ComputerUseInvocationId, ComputerUseOutput, ComputerUseResult,
    DiffFormat, DirectoryEntry, FileKind, FilePrecondition, FileStat, GitChange, GitStatus,
    KeyAction, MUX_INPUT_V1_FEATURE, OperationId, PageCursor, PatchFileAction, PatchFileResult,
    PointerAction, ProcessDescriptor, ProcessEnvironment, ProcessEvent, ProcessId, ProcessIo,
    ProcessIoKind, ProcessLifetime, ProcessOutputStream, ProcessOutputTruncationReason,
    ProcessReplayRange, ProcessSignal, ProcessState, ProcessTerminalColor, ProcessTerminalCursor,
    ProcessTerminalCursorStyle, ProcessTerminalRow, ProcessTerminalSize, ProcessTerminalSnapshot,
    ProcessTerminalStyledRun, ProcessTerminalUnderline, PtyEofPolicy, RemoteCapability, RequestId,
    RouteId, RoutePolicy, RpcError, RpcErrorDetails, RpcEvent, RpcRequest, RpcResponse,
    SearchMatch, Service, ServiceControl, StructuredDiffHunkV1, StructuredDiffLineKind,
    StructuredDiffLineV1, StructuredDiffV1, StructuredFileDiffV1, WorkspaceId, WorkspaceRequest,
    WorkspaceResponse,
};

/// Maximum serialized server-to-client message accepted by remote session
/// transports. Render attach and VT replay responses share this budget.
pub const REMOTE_SESSION_MESSAGE_MAX_BYTES: usize = 32 * 1024 * 1024;

/// Maximum serialized client-to-server JSON message accepted by Unix
/// JSON-lines and relay mux transports. The line delimiter is not included.
/// Keep this separate from [`REMOTE_SESSION_MESSAGE_MAX_BYTES`], because
/// render attach responses need the larger server-to-client budget.
pub const REMOTE_CLIENT_MESSAGE_MAX_BYTES: usize = 16 * 1024 * 1024;
