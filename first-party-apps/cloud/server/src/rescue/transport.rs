//! [`RescueTransport`]: the interactive byte stream to a Cloud machine when
//! its cmux-tui daemon is down.
//!
//! PLATFORM GAP: the cmux Cloud API has no route for an interactive stream
//! today (checked 2026-10-04 in `web/app/api/vm/[id]/*`):
//! - `exec` runs one command and answers once (no stdin, no PTY, 15 min cap);
//! - `scp-endpoint` authorizes a 15-minute Ed25519 key with `restrict`
//!   (no PTY) for file transfer over the private network;
//! - `sessions` (legacy websocket attach) answers 409
//!   `vm_attach_transport_unsupported`;
//! - `attach-endpoint` and `cmux-remote` reach the daemon, which is the part
//!   that is down in a rescue.
//!
//! So production uses [`MissingRescueRoute`], which refuses every open with
//! `unsupported`. Tests use a fake. No route is invented here.

use super::iface::{BackendError, ExitStatus, Grid, Signal};

pub type StreamId = u64;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TransportEvent {
    Output(Vec<u8>),
    /// The remote shell ended with this status.
    Closed(ExitStatus),
    /// The stream broke (network, machine stopped, credential expired).
    Dropped {
        reason: String,
        /// A new open may work (network); false when it cannot (revoked).
        retryable: bool,
    },
}

pub trait RescueTransport: Send {
    /// Whether this transport can open streams at all.
    fn available(&self) -> bool {
        true
    }
    fn open(&mut self, machine: &str, grid: Grid) -> Result<StreamId, BackendError>;
    fn write(&mut self, stream: StreamId, bytes: &[u8]) -> Result<(), BackendError>;
    fn resize(&mut self, stream: StreamId, grid: Grid) -> Result<(), BackendError>;
    fn signal(&mut self, stream: StreamId, signal: Signal) -> Result<(), BackendError>;
    fn close(&mut self, stream: StreamId) -> Result<(), BackendError>;
    /// Events since the last call, in order, for every stream.
    fn take_events(&mut self) -> Vec<(StreamId, TransportEvent)>;
}

/// The production transport until the Cloud API has an interactive route.
pub struct MissingRescueRoute;

pub(crate) const MISSING_ROUTE: &str =
    "The cmux Cloud API has no interactive shell route yet, so the rescue shell is not available";

impl RescueTransport for MissingRescueRoute {
    fn available(&self) -> bool {
        false
    }

    fn open(&mut self, _machine: &str, _grid: Grid) -> Result<StreamId, BackendError> {
        // `unsupported {}` carries no text; `cloud.rescue.open` answers
        // MISSING_ROUTE before it reaches this backend.
        Err(BackendError::Unsupported)
    }

    fn write(&mut self, _stream: StreamId, _bytes: &[u8]) -> Result<(), BackendError> {
        Err(BackendError::not_open())
    }

    fn resize(&mut self, _stream: StreamId, _grid: Grid) -> Result<(), BackendError> {
        Err(BackendError::not_open())
    }

    fn signal(&mut self, _stream: StreamId, _signal: Signal) -> Result<(), BackendError> {
        Err(BackendError::not_open())
    }

    fn close(&mut self, _stream: StreamId) -> Result<(), BackendError> {
        Err(BackendError::not_open())
    }

    fn take_events(&mut self) -> Vec<(StreamId, TransportEvent)> {
        Vec::new()
    }
}
