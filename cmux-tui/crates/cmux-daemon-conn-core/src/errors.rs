//! The classes of the app's connection errors (Swift `DaemonError`), by the
//! error's kind (its case name), and the failure rules that read them.

use serde::Serialize;

/// Every kind of connection error the app has.
pub const KINDS: [&str; 17] = [
    "notConnected",
    "connectionClosed",
    "daemonShutdown",
    "socketPathTooLong",
    "connectFailed",
    "command",
    "malformedResponse",
    "wrongApp",
    "unsupportedProtocol",
    "missingCapabilities",
    "binaryNotFound",
    "launchFailed",
    "timedOut",
    "terminalStartTimedOut",
    "invalidSessionName",
    "endpointBlocked",
    "sessionRestoreTimedOut",
];

/// A class of errors, and the kinds in it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Class {
    /// No retry can fix it: the binary or the daemon is wrong, or the
    /// endpoint waits for the user (`DaemonStartup.isPermanent`).
    Permanent,
    /// The owner is alive and still restoring: the retry spends no budget.
    OwnerRestoring,
    /// A lost or restarting connection (retry), not the daemon's refusal.
    LostConnection,
    /// The reply missed its deadline: the command may still apply.
    MissedDeadline,
    /// A change already shown is asked again after this (after a backoff
    /// for a dropped connection).
    LateReplyRecoverable,
    /// The daemon may still be doing the work: a keyed creation is sent again.
    LateStart,
}

impl Class {
    pub const ALL: [Class; 6] = [
        Self::Permanent,
        Self::OwnerRestoring,
        Self::LostConnection,
        Self::MissedDeadline,
        Self::LateReplyRecoverable,
        Self::LateStart,
    ];

    pub fn kinds(self) -> &'static [&'static str] {
        match self {
            Self::Permanent => &[
                "binaryNotFound",
                "wrongApp",
                "unsupportedProtocol",
                "missingCapabilities",
                "invalidSessionName",
                "endpointBlocked",
            ],
            Self::OwnerRestoring => &["sessionRestoreTimedOut"],
            Self::LostConnection => {
                &["notConnected", "connectionClosed", "daemonShutdown", "connectFailed", "timedOut"]
            }
            Self::MissedDeadline => &["timedOut"],
            Self::LateReplyRecoverable => {
                &["connectionClosed", "daemonShutdown", "connectFailed", "timedOut"]
            }
            Self::LateStart => &["terminalStartTimedOut", "timedOut"],
        }
    }

    pub fn contains(self, kind: &str) -> bool {
        self.kinds().contains(&kind)
    }
}

/// What a first-connect loop does after one failed attempt.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
pub struct StartupFailure {
    /// Stop retrying: no retry can fix it.
    pub stop: bool,
    /// Reset the pacer: the owner is alive and restoring.
    pub reset_pacer: bool,
    /// Note a busy refusal on the pacer.
    pub refused_busy: bool,
}

pub fn startup_failure(kind: &str, busy_refusal: bool) -> StartupFailure {
    StartupFailure {
        stop: Class::Permanent.contains(kind),
        reset_pacer: Class::OwnerRestoring.contains(kind),
        refused_busy: busy_refusal,
    }
}

/// How the first connection to a daemon is going.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StartupState {
    Connecting,
    Connected,
    Unavailable,
}

impl StartupState {
    pub fn from_name(name: &str) -> Option<Self> {
        match name {
            "connecting" => Some(Self::Connecting),
            "connected" => Some(Self::Connected),
            "unavailable" => Some(Self::Unavailable),
            _ => None,
        }
    }
}

/// Whether a failed connect attempt marks the store failed now. While
/// connecting only a failure no retry can fix shows (or one no attempt
/// follows); past the deadline or after a connection was up, every one does.
pub fn shows_failure(state: StartupState, kind: &str, retries: bool) -> bool {
    state != StartupState::Connecting || !retries || Class::Permanent.contains(kind)
}

/// How long the window shows "connecting" before it shows the failure.
pub const STARTUP_DEADLINE_MS: u64 = 10_000;
