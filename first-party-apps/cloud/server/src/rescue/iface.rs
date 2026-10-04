//! LOCAL MIRROR of `cmux.terminal.backend/1` (bytes mode).
//!
//! The ghostty-next lead owns the real interface and traits
//! (plans/cmux-next/ghostty-next-switch.md 3.3). Same rules as
//! `crate::connector::iface`: delete this file when the real crate lands and
//! import the real types.
//!
//! Differences from the real shape, on purpose:
//! - Synchronous (see `connector::iface`); events are drained with
//!   `take_events` instead of a `BoxStream`.
//! - `write` takes an [`Input`] with a per-terminal `seq`, so the backend
//!   keeps input order even when calls arrive out of order (cloud-app.md
//!   5.2 item 4). The real `write(Bytes)` relies on call order.
//! - TODO(credit): the real trait has one bounded queue per direction and a
//!   full output queue stops reading from the backend. A drained `Vec` cannot
//!   express that backpressure; it comes with the real async stream.

pub use crate::connector::iface::{BackendError, BackendId, LocalId};

/// The terminal grid. The session host decides it (smallest viewer wins).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Grid {
    pub cols: u16,
    pub rows: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Signal {
    Interrupt,
    Terminate,
    Hangup,
    Kill,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Close {
    /// Ask the far process to end (hang up).
    Graceful,
    /// End the stream now.
    Now,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResumeToken(pub String);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct BackendCapabilities {
    pub resize: bool,
    pub signals: bool,
    pub exit_status: bool,
    pub resume: bool,
    pub cwd_reports: bool,
    pub max_write_bytes: usize,
}

/// `OpenRequest` of the real trait.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpenRequest {
    pub kind: String,
    /// The terminal id the session host chose.
    pub terminal: String,
    /// The `connection` handle (here: the machine id).
    pub target: String,
    /// argv, or the default shell when `None`.
    pub command: Option<Vec<String>>,
    pub cwd: Option<String>,
    /// Allowlisted environment.
    pub env: Vec<(String, String)>,
    pub grid: Grid,
    pub actor: Option<String>,
}

/// One input chunk. `seq` starts at 0 for each terminal and grows by 1.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Input {
    pub seq: u64,
    pub bytes: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExitStatus {
    pub code: Option<i32>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ByteEvent {
    Output(Vec<u8>),
    Exit(ExitStatus),
    /// The stream ended without an exit status (transport drop).
    Lost(String),
}

pub trait ByteTerminal: Send {
    fn take_events(&mut self) -> Vec<ByteEvent>;
    /// Ordered by `seq`. Refused when the terminal is not open; nothing queues.
    fn write(&self, input: Input) -> Result<(), BackendError>;
    fn resize(&self, grid: Grid) -> Result<(), BackendError>;
    fn signal(&self, signal: Signal) -> Result<(), BackendError>;
    fn close(&self, how: Close) -> Result<(), BackendError>;
    fn resume_token(&self) -> Option<ResumeToken>;
}

pub trait TerminalBackend: Send {
    fn id(&self) -> &BackendId;
    fn kinds(&self) -> &[LocalId];
    fn capabilities(&self) -> BackendCapabilities;
    fn open(&mut self, request: OpenRequest) -> Result<Box<dyn ByteTerminal>, BackendError>;
    fn resume(&mut self, token: &ResumeToken) -> Result<Box<dyn ByteTerminal>, BackendError>;
}
