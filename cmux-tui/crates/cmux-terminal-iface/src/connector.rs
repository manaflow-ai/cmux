//! `cmux.terminal.connector/1` (host mode).

use std::path::PathBuf;

use crate::error::BackendError;
use crate::frames::{FrameBody, Lost};
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

/// Where the bytes of a link move. A link reports it once, at connect, and
/// it does not change for the life of the channel.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DataPlane {
    /// `data` and `credit` frames through [`HostLink::push`] and
    /// [`HostLink::take_frames`] (`dataPlane` in the JSON). The only form
    /// on the app host's stream.
    Frames,
    /// The bytes move on a carrier socket: the session host dials the
    /// local stream socket at `path` (in an owner-only directory) and relays the viewer
    /// protocol on it. In-process connectors only (the JSON has no wire
    /// form for it). On such a link `push` refuses `data` and `credit`
    /// frames with `invalid` (the session host never sends them), only
    /// `end` frames move, and [`HostLink::window_bytes`] has no meaning.
    /// Close and the one `end` work as on a frame link.
    Socket { path: PathBuf },
}

/// A connector's event, for a caller that holds no link handle.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConnectorEvent {
    /// `end {channel, lost}`: exactly once per channel a connect answered,
    /// after its last data. The channel's [`HostLink`] gets the same end
    /// as its `end` frame. Nothing follows it; a reconnect is a new
    /// `connect`.
    End { channel: String, lost: Lost },
}

/// One link to a far session host: one channel. Its frames carry the viewer
/// protocol (GHOSTSNP snapshot and bytes frames, size state, input,
/// presence); the session host relays it and does not parse.
pub trait HostLink: Send {
    /// The channel id of this link: the id [`TerminalConnector::close`]
    /// takes and [`ConnectorEvent::End`] names. A second `connect` to the
    /// same target while the link is up answers the same id. On the wire
    /// the host assigns the id (`cmux.terminal.connector.open`); an
    /// in-process connector names its own.
    fn channel(&self) -> &str;
    /// Where this link's bytes move ([`DataPlane`]).
    fn data_plane(&self) -> DataPlane;
    /// `window_bytes` of the connect answer.
    fn window_bytes(&self) -> u32;
    /// One frame from the session host: viewer messages within the `in`
    /// credit, or `out` credit. Refused when the link is not open.
    fn push(&mut self, frame: FrameBody) -> Result<(), BackendError>;
    /// Frames for the session host since the last call, in order; the one
    /// `end` comes last.
    fn take_frames(&mut self) -> Vec<FrameBody>;
    /// Ends the link; its `end` follows in [`Self::take_frames`] once the
    /// connector has applied the close (an in-process connector may apply
    /// it at its next event drain). Unlike [`crate::ByteTerminal::close`], a
    /// link close is answered by its `end`.
    fn close(&mut self) -> Result<(), BackendError>;
}

pub trait TerminalConnector: Send {
    fn id(&self) -> &BackendId;
    /// `options.kinds`; a connect for any other kind is `denied`.
    fn kinds(&self) -> &[LocalId];
    fn connect(&mut self, request: ConnectRequest) -> Result<Box<dyn HostLink>, BackendError>;
    /// `close {channel}`: ends the link of `channel` (the id of
    /// [`HostLink::channel`]) for a caller that holds no link handle. Its
    /// `end` follows, as a [`ConnectorEvent`] and as the link's `end`
    /// frame. A channel that is not open is `invalid`.
    fn close(&mut self, channel: &str) -> Result<(), BackendError>;
    /// The events since the last call, in order. Each event is given once.
    fn take_events(&mut self) -> Vec<ConnectorEvent>;
}
