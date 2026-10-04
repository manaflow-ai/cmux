//! [`PortTunnel`]: one byte stream to a loopback port of a Cloud machine,
//! carried by the machine's link (remote-localhost.md: loopback streams ride
//! the link; no listening socket on the machine, no new credential).
//!
//! The real tunnel is [`super::LoopbackTunnel`] (`loopback-forward-v1` on the
//! link's local socket). Tests use a fake. A tunnel never buffers for a link
//! that is down: an open on a dead carrier fails, and nothing is queued for
//! a later carrier.

use crate::connector::iface::Carrier;
use std::fmt;
use std::io::{Read, Write};

/// Why a stream could not be opened.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TunnelError {
    /// The carrier is not reachable (link down, socket gone).
    Down(String),
    /// The machine's cmux-tui lacks `loopback-forward-v1`.
    Unsupported(String),
    /// The machine refused the stream (`loopback.*` error code and message).
    Refused { code: String, message: String },
}

impl fmt::Display for TunnelError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Down(why) => write!(f, "the link to the machine is down: {why}"),
            Self::Unsupported(why) => write!(f, "{why}"),
            Self::Refused { code, message } => write!(f, "{message} ({code})"),
        }
    }
}

impl std::error::Error for TunnelError {}

/// The write half: bytes to the machine's port.
pub trait TunnelWrite: Write + Send {
    /// Half close: the machine's port sees end of stream after the bytes
    /// already written.
    fn shutdown_write(&mut self) -> std::io::Result<()>;
}

/// Ends a stream at once from any thread (both halves fail or end).
pub trait TunnelAbort: Send + Sync {
    fn abort(&self);
}

/// One open stream, split so two threads can pump it.
pub struct TunnelConn {
    pub reader: Box<dyn Read + Send>,
    pub writer: Box<dyn TunnelWrite>,
    pub abort: std::sync::Arc<dyn TunnelAbort>,
}

/// Opens streams to `host:port` on the machine of `carrier`. `host` is
/// always a loopback name or literal (the caller checks it; the machine's
/// daemon checks it again).
pub trait PortTunnel: Send + Sync {
    fn open(&self, carrier: &Carrier, host: &str, port: u16) -> Result<TunnelConn, TunnelError>;
}
