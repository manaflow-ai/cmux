//! Host ops for `connection` handles of kind `ssh` (`hostOps` in
//! `cmux.terminal.backend/1`). The host owns the SSH transport: it resolves
//! the handle, dials, checks the host key the user pinned (else
//! [`crate::BackendError::HostKey`]) and authenticates with the user's
//! credential. A backend never sees the host name, a key or a signature,
//! and there is no signing op.

use crate::backend::Signal;
use crate::error::BackendError;
use crate::frames::{Frame, FrameBody};
use crate::tokens::OpenToken;

/// `pty: {term, cols, rows}`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PtyRequest {
    pub term: String,
    pub cols: u16,
    pub rows: u16,
}

/// `connection.channel.open {connection, open_token, pty, command?}`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChannelOpenRequest {
    pub connection: String,
    pub open_token: OpenToken,
    pub pty: PtyRequest,
    pub command: Option<Vec<String>>,
}

/// The answer `{channel, window_bytes}`; the host chose the channel id.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChannelOpen {
    pub channel: String,
    pub window_bytes: u32,
}

/// What a backend calls on the host. No op waits and none calls back into
/// the backend. Data, credit and end move as frames.
pub trait HostChannels: Send {
    /// `connection.channel.open`: refused without a fresh open token issued
    /// to this app.
    fn open(&mut self, request: ChannelOpenRequest) -> Result<ChannelOpen, BackendError>;
    /// `connection.channel.resize`.
    fn resize(&mut self, channel: &str, cols: u16, rows: u16) -> Result<(), BackendError>;
    /// `connection.channel.signal`.
    fn signal(&mut self, channel: &str, signal: Signal) -> Result<(), BackendError>;
    /// `connection.channel.close`: the channel's `end` follows.
    fn close(&mut self, channel: &str) -> Result<(), BackendError>;
    /// One frame for a host channel: input data within its `in` credit, or
    /// `out` credit.
    fn push(&mut self, channel: &str, frame: FrameBody) -> Result<(), BackendError>;
    /// Frames of every host channel of this backend since the last call.
    fn take_frames(&mut self) -> Vec<Frame>;
}
