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
    CircuitId, LaneToken, RelayControl, RelayPermission, RelayRole, RelaySocketAttachment,
    RelayTicketClaims,
};
pub use rpc::{
    ByteString, ComputerUseAction, ComputerUseCapability, ComputerUseFeature,
    ComputerUseInvocation, ComputerUseInvocationId, ComputerUseOutput, ComputerUseResult,
    DiffFormat, DirectoryEntry, FileKind, FilePrecondition, FileStat, GitChange, GitStatus,
    KeyAction, MUX_INPUT_V1_FEATURE, OperationId, PageCursor, PatchFileAction, PatchFileResult,
    PointerAction, ProcessEnvironment, ProcessEvent, ProcessId, ProcessIo, ProcessLifetime,
    ProcessReplayRange, ProcessSignal, PtyEofPolicy, RemoteCapability, RequestId, RouteId,
    RoutePolicy, RpcError, RpcErrorDetails, RpcEvent, RpcRequest, RpcResponse, SearchMatch,
    Service, ServiceControl, StructuredDiffHunkV1, StructuredDiffLineKind, StructuredDiffLineV1,
    StructuredDiffV1, StructuredFileDiffV1, WorkspaceId, WorkspaceRequest, WorkspaceResponse,
};
