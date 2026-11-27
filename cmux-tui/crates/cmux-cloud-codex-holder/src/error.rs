//! What a holder operation fails with, and the text the app shows for it.

use std::fmt;

/// The holder's own refusals (the app's `CloudCodexBrokerError` cases before the move).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum BrokerError {
    ConsentRequired,
    ScopeChanged,
    SharedMachine,
    UnsupportedMachine,
    BrokerUnavailable,
    NotAuthenticated,
    InvalidReply,
    AccountChanged,
    ExpiredAccess,
    TargetOffline,
    RemoteDeliveryFailed,
    Cancelled,
}

impl BrokerError {
    pub const ALL: [Self; 12] = [
        Self::ConsentRequired,
        Self::ScopeChanged,
        Self::SharedMachine,
        Self::UnsupportedMachine,
        Self::BrokerUnavailable,
        Self::NotAuthenticated,
        Self::InvalidReply,
        Self::AccountChanged,
        Self::ExpiredAccess,
        Self::TargetOffline,
        Self::RemoteDeliveryFailed,
        Self::Cancelled,
    ];

    /// The wire code the app receives.
    pub fn code(self) -> &'static str {
        match self {
            Self::ConsentRequired => "consent_required",
            Self::ScopeChanged => "scope_changed",
            Self::SharedMachine => "shared_machine",
            Self::UnsupportedMachine => "unsupported_machine",
            Self::BrokerUnavailable => "broker_unavailable",
            Self::NotAuthenticated => "not_authenticated",
            Self::InvalidReply => "invalid_reply",
            Self::AccountChanged => "account_changed",
            Self::ExpiredAccess => "expired_access",
            Self::TargetOffline => "target_offline",
            Self::RemoteDeliveryFailed => "remote_delivery_failed",
            Self::Cancelled => "cancelled",
        }
    }

    /// The text the app shows (unchanged from the Swift holder).
    pub fn message(self) -> &'static str {
        match self {
            Self::ConsentRequired => "Confirm that Codex access will be delivered to this VM.",
            Self::ScopeChanged => {
                "The signed-in account or team changed; start the transfer again."
            }
            Self::SharedMachine => {
                "This VM is shared, so it cannot receive a personal Codex credential."
            }
            Self::UnsupportedMachine => "This VM does not support Codex access delivery yet.",
            Self::BrokerUnavailable => "The local Codex sign-in holder is unavailable.",
            Self::NotAuthenticated => "Finish signing in to Codex to continue.",
            Self::InvalidReply | Self::AccountChanged => "Codex sign-in could not be completed.",
            Self::ExpiredAccess => "Codex returned an expired access token.",
            Self::TargetOffline => {
                "This VM is offline or paused; resume it before delivering Codex access."
            }
            Self::RemoteDeliveryFailed => {
                "The Codex access token could not be delivered to this VM."
            }
            Self::Cancelled => "Codex sign-in was cancelled.",
        }
    }
}

/// Any failure: a refusal of the holder's, a machine call's own error (its text), or a cancel
/// seen in a sleep or a machine call (Swift's `CancellationError`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
    Broker(BrokerError),
    Other(String),
    Interrupted,
}

impl Error {
    pub fn is(&self, error: BrokerError) -> bool {
        matches!(self, Self::Broker(e) if *e == error)
    }

    pub fn code(&self) -> &'static str {
        match self {
            Self::Broker(e) => e.code(),
            Self::Other(_) => "failed",
            Self::Interrupted => "interrupted",
        }
    }

    pub fn message(&self) -> String {
        match self {
            Self::Broker(e) => e.message().to_owned(),
            Self::Other(text) => text.clone(),
            Self::Interrupted => "The Codex sign-in was interrupted.".to_owned(),
        }
    }
}

impl From<BrokerError> for Error {
    fn from(error: BrokerError) -> Self {
        Self::Broker(error)
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message())
    }
}

impl std::error::Error for Error {}
