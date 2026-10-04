//! LOCAL MIRROR of `cmux.terminal.backend/1` (bytes mode).
//!
//! The ghostty-next lead owns the real interface and the Rust traits
//! (plans/cmux-next/ghostty-next-switch.md 3.3, module `terminal_backend` in
//! cmux-tui-core). They are not on feat-cmux-next yet. This file copies the
//! shape that the cmux Cloud rescue shell (cloud-app.md 3.4, package C2)
//! copies too, so both implementations swap to the real crate the same way:
//! delete this file and import the real types. Keep the names and keep it
//! small.
//!
//! An outside author cannot depend on a cmux crate yet, so this sample copies
//! the shape instead of depending on the Cloud app server.
//!
//! Differences from the real shape, on purpose (same as the Cloud copy):
//! - Synchronous. The real traits are `async fn`; each method here maps 1:1.
//!   The SSH backend runs its own async runtime behind these calls.
//! - Events are drained with `take_events` instead of a `BoxStream`.
//! - `write` takes an [`Input`] with a per-terminal `seq`, so the backend
//!   keeps input order even when calls arrive out of order (cloud-app.md 5.2
//!   item 4). The real `write(Bytes)` relies on call order.

use std::fmt;

/// The interface id.
pub const BACKEND_INTERFACE: &str = "cmux.terminal.backend/1";

/// A local id (`options.kinds` entry, implementation id): `[a-z][a-z0-9-]{0,31}`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct LocalId(String);

impl LocalId {
    pub fn new(value: &str) -> Result<Self, BackendError> {
        let mut chars = value.chars();
        let ok = chars.next().is_some_and(|c| c.is_ascii_lowercase())
            && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
            && value.len() <= 32;
        if ok {
            Ok(Self(value.to_owned()))
        } else {
            Err(BackendError::Invalid(format!("{value:?} is not a local id")))
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
            return Err(BackendError::Invalid(format!("kind {kind} is declared twice")));
        }
        seen.push(kind);
    }
    if (1..=16).contains(&kinds.len()) {
        Ok(())
    } else {
        Err(BackendError::Invalid("options.kinds needs 1 to 16 kinds".into()))
    }
}

/// Default deny: `kind` must be one of `kinds`.
pub fn allow_kind(kinds: &[LocalId], kind: &str) -> Result<(), BackendError> {
    if kinds.iter().any(|k| k.as_str() == kind) {
        Ok(())
    } else {
        Err(BackendError::KindRefused { kind: kind.to_owned() })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BackendError {
    /// The kind is not in `options.kinds` (default deny).
    KindRefused {
        kind: String,
    },
    /// The far end or the transport is not reachable now; a later call may work.
    Unavailable {
        reason: String,
        retryable: bool,
    },
    /// Access to the target ended (machine gone, access lost, app revoked).
    Revoked {
        reason: String,
    },
    /// The terminal or link is not open. Nothing is queued.
    Closed,
    /// The implementation cannot do this (missing route or capability).
    Unsupported(String),
    Invalid(String),
}

impl fmt::Display for BackendError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::KindRefused { kind } => write!(f, "kind {kind} is not served here"),
            Self::Unavailable { reason, .. } => write!(f, "unavailable: {reason}"),
            Self::Revoked { reason } => write!(f, "revoked: {reason}"),
            Self::Closed => f.write_str("the terminal or link is not open"),
            Self::Unsupported(why) => write!(f, "unsupported: {why}"),
            Self::Invalid(why) => write!(f, "invalid: {why}"),
        }
    }
}

impl std::error::Error for BackendError {}

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
    /// The `connection` handle (here: the opaque `conn_…` id the host gave the app).
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
