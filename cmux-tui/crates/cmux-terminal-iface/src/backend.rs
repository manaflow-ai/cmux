//! `cmux.terminal.backend/1` (bytes mode).

use crate::error::BackendError;
use crate::frames::FrameBody;
use crate::ids::{BackendId, LocalId};
use crate::tokens::{OpenToken, ResumeToken};

/// The interface id.
pub const BACKEND_INTERFACE: &str = "cmux.terminal.backend/1";

/// Longest `exit.message` (far-end text, shown and never parsed).
pub const MAX_EXIT_MESSAGE: usize = 4 * 1024;

/// The terminal grid. The session host decides it (smallest viewer wins).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Grid {
    pub cols: u16,
    pub rows: u16,
    pub cell_width_px: Option<u16>,
    pub cell_height_px: Option<u16>,
}

impl Grid {
    pub const fn new(cols: u16, rows: u16) -> Self {
        Self { cols, rows, cell_width_px: None, cell_height_px: None }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Signal {
    Interrupt,
    Terminate,
    Hangup,
    Kill,
}

impl Signal {
    /// The interface's signal name (without `SIG`).
    pub fn name(self) -> &'static str {
        match self {
            Self::Interrupt => "INT",
            Self::Terminate => "TERM",
            Self::Hangup => "HUP",
            Self::Kill => "KILL",
        }
    }

    /// The signal for an interface name; others are `unsupported`.
    pub fn from_name(name: &str) -> Result<Self, BackendError> {
        match name {
            "INT" => Ok(Self::Interrupt),
            "TERM" => Ok(Self::Terminate),
            "HUP" => Ok(Self::Hangup),
            "KILL" => Ok(Self::Kill),
            _ => Err(BackendError::Unsupported),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Close {
    /// Send the input accepted so far, then close.
    Graceful,
    /// Drop unsent input and close now.
    Now,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct BackendCapabilities {
    pub resize: bool,
    pub signals: bool,
    pub exit_status: bool,
    pub resume: bool,
    pub cwd_reports: bool,
    pub max_write_bytes: u32,
    /// True only when the far end answers DA, DSR and OSC color queries
    /// itself. A shell over SSH or a PTY is false: the session host answers.
    pub answers_queries: bool,
}

/// `open {terminal, kind, target, open_token, cols, rows, cell_width_px?,
/// cell_height_px?, cwd?, command?, env?}`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpenRequest {
    /// The terminal id the session host chose (it owns the journal).
    pub terminal: String,
    pub kind: String,
    /// An opaque `connection` handle (`conn_…`) or a backend-defined id;
    /// never a host name typed by a user or an agent.
    pub target: String,
    pub open_token: OpenToken,
    /// argv, or the default shell when `None`.
    pub command: Option<Vec<String>>,
    pub cwd: Option<String>,
    /// Allowlisted environment.
    pub env: Vec<(String, String)>,
    pub grid: Grid,
    /// The actor the session host stamps on this terminal's input.
    pub actor: Option<String>,
}

/// `resume {terminal, resume_token, open_token}`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResumeRequest {
    /// The id the session host gave the terminal at open.
    pub terminal: String,
    pub resume_token: ResumeToken,
    pub open_token: OpenToken,
}

/// One open terminal: one channel. Its frames carry output and input; the
/// methods are control only.
pub trait ByteTerminal: Send {
    /// `window_bytes` of the open or resume answer: the first credit of
    /// each direction.
    fn window_bytes(&self) -> u32;
    /// One frame from the session host: input data within the `in` credit,
    /// or `out` credit. Refused when the terminal is not open; nothing queues.
    fn push(&mut self, frame: FrameBody) -> Result<(), BackendError>;
    /// Frames for the session host since the last call, in order: output
    /// data within the `out` credit, `in` credit, and the one `end`.
    fn take_frames(&mut self) -> Vec<FrameBody>;
    fn resize(&mut self, grid: Grid) -> Result<(), BackendError>;
    fn signal(&mut self, signal: Signal) -> Result<(), BackendError>;
    /// The session host closed the terminal; it has already ended there.
    /// End after close: once `close` answers `Ok`, no frame follows, not
    /// even an `end` (output and an `end` not taken yet are dropped), and
    /// every later push, resize, signal or close is refused as `invalid` (a
    /// resize or signal may be `unsupported`). Unlike [`crate::HostLink::close`], nothing answers a
    /// terminal close. [`crate::check_closed`] checks this rule.
    fn close(&mut self, how: Close) -> Result<(), BackendError>;
    fn resume_token(&self) -> Option<ResumeToken>;
}

/// The resume answer `{capabilities, window_bytes, offset}`: output data
/// continues from `offset`. Capabilities come from
/// [`TerminalBackend::capabilities`].
pub struct Resumed {
    pub terminal: Box<dyn ByteTerminal>,
    pub offset: u64,
}

pub trait TerminalBackend: Send {
    fn id(&self) -> &BackendId;
    /// `options.kinds`; open and resume for any other kind are `denied`.
    fn kinds(&self) -> &[LocalId];
    fn capabilities(&self) -> BackendCapabilities;
    fn open(&mut self, request: OpenRequest) -> Result<Box<dyn ByteTerminal>, BackendError>;
    fn resume(&mut self, request: ResumeRequest) -> Result<Resumed, BackendError>;
}
