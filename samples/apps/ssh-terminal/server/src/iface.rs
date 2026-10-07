//! LOCAL MIRROR of `cmux.terminal.backend/1` (bytes mode) and of its host
//! ops (`connection.channel.*`).
//!
//! The ghostty-next lead owns the real interface
//! (cmux-tui/crates/cmux-app-host/interfaces/cmux.terminal.backend/1.json)
//! and the Rust traits (plans/cmux-next/ghostty-next-switch.md 3.3, module
//! `terminal_backend` in cmux-tui-core). The traits are not on
//! feat-cmux-next yet. This file copies the landed JSON so the cmux Cloud
//! rescue shell (cloud-app.md 3.4, package C2) can copy it too, and both swap
//! to the real crate the same way: delete this file and import the real
//! types. Keep the names and keep it small.
//!
//! Differences from the real shape, on purpose:
//! - Synchronous. The real traits are `async fn`; each method here maps 1:1.
//!   No call here waits: a full buffer is an `Unavailable {retryable: true}`
//!   answer.
//! - Events are drained with `take_events` instead of a `BoxStream`.
//! - The host's byte channel has two data-plane calls,
//!   [`HostChannels::send`] and [`HostChannels::receive`]. The JSON says
//!   the channel carries "data in and out" but names no op or frame for it
//!   (README, "Interface gaps").

use std::fmt;

/// The interface id.
pub const BACKEND_INTERFACE: &str = "cmux.terminal.backend/1";

/// Longest local id (the `{0,63}` of the pattern plus the first letter).
pub const MAX_LOCAL_ID: usize = 64;

/// Longest `exit.message` (far-end text, shown and never parsed).
pub const MAX_EXIT_MESSAGE: usize = 4 * 1024;

/// A local id (`options.kinds` entry, implementation id), the interface
/// schema's pattern `^[a-z][a-zA-Z0-9-]{0,63}$`: at most 64 ASCII characters.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct LocalId(String);

impl LocalId {
    pub fn new(value: &str) -> Result<Self, BackendError> {
        let mut chars = value.chars();
        let ok = chars.next().is_some_and(|c| c.is_ascii_lowercase())
            && chars.all(|c| c.is_ascii_alphanumeric() || c == '-')
            && value.len() <= MAX_LOCAL_ID;
        if ok {
            Ok(Self(value.to_owned()))
        } else {
            Err(BackendError::invalid(format!("{value:?} is not a local id")))
        }
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for LocalId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// A registry id: `local-pty` or `app:<app id>/<local id>`.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct BackendId(String);

impl BackendId {
    pub fn app(app: &str, id: &LocalId) -> Self {
        Self(format!("app:{app}/{id}"))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// `options.kinds`: 1 to 16 unique local ids. Anything else is refused.
pub fn check_kinds(kinds: &[LocalId]) -> Result<(), BackendError> {
    let mut seen: Vec<&LocalId> = Vec::with_capacity(kinds.len());
    for kind in kinds {
        if seen.contains(&kind) {
            return Err(BackendError::invalid(format!("kind {kind} is declared twice")));
        }
        seen.push(kind);
    }
    if (1..=16).contains(&kinds.len()) {
        Ok(())
    } else {
        Err(BackendError::invalid("options.kinds needs 1 to 16 kinds"))
    }
}

/// Default deny: `kind` must be one of `kinds`.
pub fn allow_kind(kinds: &[LocalId], kind: &str) -> Result<(), BackendError> {
    if kinds.iter().any(|k| k.as_str() == kind) {
        Ok(())
    } else {
        Err(BackendError::Denied { reason: format!("kind {kind:?} is not served here") })
    }
}

/// `hostKey.decision`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostKeyRefusal {
    /// No key is pinned for the connection handle.
    Unknown,
    /// A different key is pinned for the connection handle.
    Changed,
}

/// The interface's typed errors (`errors` in the JSON).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BackendError {
    /// `unsupported {}`: the implementation cannot do this.
    Unsupported,
    /// `unavailable {reason, retryable}`: not reachable now, or a full buffer.
    Unavailable { reason: String, retryable: bool },
    /// `hostKey {decision, fingerprint}`: typed host key refusal; the host
    /// shows its accept sheet from these fields. Nothing reached the far shell.
    HostKey { decision: HostKeyRefusal, fingerprint: String },
    /// `denied {reason}`: a handle or token was refused, or a check failed.
    Denied { reason: String },
    /// `invalid {reason}`: a bad argument, or a terminal that is not open.
    Invalid { reason: String },
}

impl BackendError {
    pub fn invalid(reason: impl Into<String>) -> Self {
        Self::Invalid { reason: reason.into() }
    }

    /// The terminal is closed, exited or lost. Nothing is queued.
    pub fn not_open() -> Self {
        Self::invalid("the terminal is not open")
    }
}

impl fmt::Display for BackendError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unsupported => f.write_str("unsupported"),
            Self::Unavailable { reason, .. } => write!(f, "unavailable: {reason}"),
            Self::HostKey { decision, fingerprint } => {
                write!(f, "host key {decision:?}: {fingerprint}")
            }
            Self::Denied { reason } => write!(f, "denied: {reason}"),
            Self::Invalid { reason } => write!(f, "invalid: {reason}"),
        }
    }
}

impl std::error::Error for BackendError {}

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
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Close {
    /// Send the input accepted so far, then close.
    Graceful,
    /// Drop unsent input and close now.
    Now,
}

/// A bearer credential for one session: `Debug` hides the value.
#[derive(Clone, PartialEq, Eq)]
pub struct ResumeToken(pub String);

impl fmt::Debug for ResumeToken {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("ResumeToken(..)")
    }
}

/// `open_token`: issued by the host for one open or resume of one terminal
/// after the user's gesture. The backend passes it on and never mints it.
/// `Debug` hides the value so it never reaches a log.
#[derive(Clone, PartialEq, Eq)]
pub struct OpenToken(pub String);

impl fmt::Debug for OpenToken {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("OpenToken(..)")
    }
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

/// `open {kind, target, open_token, cols, rows, cell_width_px?,
/// cell_height_px?, cwd?, command?, env?}`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpenRequest {
    pub kind: String,
    /// The terminal id the session host chose.
    pub terminal: String,
    /// The opaque `connection` handle (`conn_…`), never a host name.
    pub target: String,
    pub open_token: OpenToken,
    /// argv, or the default shell when `None`.
    pub command: Option<Vec<String>>,
    pub cwd: Option<String>,
    /// Allowlisted environment.
    pub env: Vec<(String, String)>,
    pub grid: Grid,
    pub actor: Option<String>,
}

/// `resume {resume_token, open_token}`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResumeRequest {
    pub resume_token: ResumeToken,
    pub open_token: OpenToken,
}

/// One input chunk. `seq` starts at 0 for each terminal and grows by 1.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Input {
    pub seq: u64,
    pub bytes: Vec<u8>,
}

/// `exit {terminal, code?, signal?, core_dumped, message?}`.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ExitStatus {
    /// The exit code, when the far end sent one.
    pub code: Option<i32>,
    /// The signal name without `SIG` (SSH exit-signal or POSIX).
    pub signal: Option<String>,
    pub core_dumped: bool,
    /// Far-end text, at most [`MAX_EXIT_MESSAGE`] bytes; shown, never parsed.
    pub message: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ByteEvent {
    /// `offset` is the running byte total after this chunk since open; a
    /// resumed terminal continues it. A gap or an overlap is lost.
    Output {
        offset: u64,
        bytes: Vec<u8>,
    },
    Exit(ExitStatus),
    /// The stream ended without an exit status.
    Lost {
        reason: String,
        retryable: bool,
    },
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

/// `resume` answers `{terminal, capabilities, offset}`; output continues
/// from `offset`. Capabilities come from [`TerminalBackend::capabilities`].
pub struct Resumed {
    pub terminal: Box<dyn ByteTerminal>,
    pub offset: u64,
}

pub trait TerminalBackend: Send {
    fn id(&self) -> &BackendId;
    fn kinds(&self) -> &[LocalId];
    fn capabilities(&self) -> BackendCapabilities;
    fn open(&mut self, request: OpenRequest) -> Result<Box<dyn ByteTerminal>, BackendError>;
    fn resume(&mut self, request: ResumeRequest) -> Result<Resumed, BackendError>;
}

// --- Host ops (`hostOps` in the JSON). The host owns the SSH transport. ---

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

/// `{channel}`: an opaque id the host gave out.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ChannelId(pub String);

/// What the host's byte channel carries toward the backend.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChannelEvent {
    Data(Vec<u8>),
    /// The far end sent an exit status or exit signal, or closed the channel.
    Exit(ExitStatus),
    /// The transport ended with no exit.
    Dropped {
        reason: String,
        retryable: bool,
    },
}

/// The host side of an `ssh` connection handle. The host resolves the
/// handle, dials, checks the host key the user pinned (else `HostKey`) and
/// authenticates with the user's credential. The backend never sees the
/// host name, a key or a signature, and there is no signing op.
///
/// Contract: no op waits (a full buffer is `Unavailable {retryable: true}`)
/// and no op calls back into the backend. The sample calls these ops while
/// it holds a session lock.
pub trait HostChannels: Send + Sync {
    /// `connection.channel.open`.
    fn open(&self, request: ChannelOpenRequest) -> Result<ChannelId, BackendError>;
    /// `connection.channel.resize`.
    fn resize(&self, channel: &ChannelId, cols: u16, rows: u16) -> Result<(), BackendError>;
    /// `connection.channel.signal`.
    fn signal(&self, channel: &ChannelId, signal: Signal) -> Result<(), BackendError>;
    /// `connection.channel.close`.
    fn close(&self, channel: &ChannelId) -> Result<(), BackendError>;
    /// Data in (gap: not named in the JSON). All or nothing; a full host
    /// buffer answers `Unavailable {retryable: true}`.
    fn send(&self, channel: &ChannelId, bytes: &[u8]) -> Result<(), BackendError>;
    /// Data out (gap: not named in the JSON). At most `max_bytes` of data;
    /// the end event comes once, after the last data. Never waits.
    fn receive(&self, channel: &ChannelId, max_bytes: usize) -> Vec<ChannelEvent>;
}
