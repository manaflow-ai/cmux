//! LOCAL MIRROR of `cmux.terminal.connector/1` (host mode) and the types it
//! shares with `cmux.terminal.backend/1`.
//!
//! The ghostty-next lead owns the real interfaces and the Rust traits
//! (plans/cmux-next/ghostty-next-switch.md 3.2 to 3.4, module
//! `terminal_backend` in cmux-tui-core). They are not on feat-cmux-next yet.
//! This file copies their shape so the Cloud server can implement them now.
//! When the real crate lands, delete this file and import the real types; the
//! swap must stay mechanical, so keep this file small and keep the names.
//!
//! Differences from the real shape, on purpose:
//! - Synchronous. The Cloud server is a single-threaded op loop with no async
//!   runtime. The real traits are `async fn`; each method here maps 1:1.
//! - Events are drained with `take_events` instead of a `BoxStream`.
//! - `HostLink` exposes the carrier only. In the real system the daemon
//!   speaks the viewer protocol (frames in, messages out) on the carrier the
//!   app gives it (cloud-app.md 5.1 item 2), so the app never parses frames.

use std::fmt;
use std::path::PathBuf;

/// The interface ids and the namespace of app-provided implementations.
pub const CONNECTOR_INTERFACE: &str = "cmux.terminal.connector/1";
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
    KindRefused { kind: String },
    /// The far end or the transport is not reachable now; a later call may work.
    Unavailable { reason: String, retryable: bool },
    /// Access to the target ended (machine gone, access lost, app revoked).
    Revoked { reason: String },
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

/// `ConnectRequest` of the real trait: the kind, the `connection` handle
/// (here: the target, a machine id) and the actor.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConnectRequest {
    pub kind: String,
    pub target: String,
    pub actor: Option<String>,
}

/// The byte carrier to the far session host. In the real system the app
/// supervisor passes a socketpair fd; until fd passing exists this is the
/// local socket of the link process (owner-only directory).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Carrier {
    /// `<kind>/<target>#<generation>`; a new id after every reconnect.
    pub id: String,
    pub target: String,
    pub generation: u64,
    pub socket: PathBuf,
}

/// Carrier events. On `Down` the daemon shows the disconnected state and
/// refuses changes; nothing queues. Reconnect is one `connect` call.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CarrierEvent {
    Up { carrier: Carrier },
    Down { target: String, generation: u64, retryable: bool, reason: String },
    Revoked { target: String, reason: String },
}

/// The link the daemon gets from `connect`.
pub trait HostLink: Send {
    fn carrier(&self) -> &Carrier;
}

/// `cmux.terminal.connector/1`: the far end runs its own session host.
pub trait TerminalConnector {
    fn id(&self) -> &BackendId;
    fn kinds(&self) -> &[LocalId];
    /// At most one carrier per target: a second call while it is up returns it.
    fn connect(&mut self, request: ConnectRequest) -> Result<Box<dyn HostLink>, BackendError>;
    /// Carrier events since the last call, in order.
    fn take_events(&mut self) -> Vec<CarrierEvent>;
}
