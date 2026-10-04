//! `cmux.terminal.connector/1` (host mode).

use crate::error::BackendError;
use crate::frames::FrameBody;
use crate::ids::{BackendId, LocalId};
use crate::tokens::OpenToken;

/// The interface id.
pub const CONNECTOR_INTERFACE: &str = "cmux.terminal.connector/1";

/// `connect {kind, target, open_token}`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConnectRequest {
    pub kind: String,
    /// A connector-defined id (a Cloud machine id).
    pub target: String,
    /// Issued by the host for this connect; passed on, never minted here.
    pub open_token: OpenToken,
}

/// One link to a far session host: one channel. Its frames carry the viewer
/// protocol (GHOSTSNP snapshot and bytes frames, size state, input,
/// presence); the session host relays it and does not parse.
pub trait HostLink: Send {
    /// `window_bytes` of the connect answer.
    fn window_bytes(&self) -> u32;
    /// One frame from the session host: viewer messages within the `in`
    /// credit, or `out` credit. Refused when the link is not open.
    fn push(&mut self, frame: FrameBody) -> Result<(), BackendError>;
    /// Frames for the session host since the last call, in order; the one
    /// `end` comes last.
    fn take_frames(&mut self) -> Vec<FrameBody>;
    /// Ends the link; its `end` follows in [`Self::take_frames`].
    fn close(&mut self) -> Result<(), BackendError>;
}

pub trait TerminalConnector: Send {
    fn id(&self) -> &BackendId;
    /// `options.kinds`; a connect for any other kind is `denied`.
    fn kinds(&self) -> &[LocalId];
    fn connect(&mut self, request: ConnectRequest) -> Result<Box<dyn HostLink>, BackendError>;
}
