//! Health: probe facts to alerts and feed posts (server.md 9.3), and the fix
//! descriptors (server.md 9.4).
//!
//! The `health` role is the single writer of the alert set. It calls
//! [`reduce`] after every probe event and at [`AlertSet::wake_at_ms`], a
//! one-shot deadline (no polling). [`reduce`] is pure: the same previous set,
//! facts and `now` give the same result.

mod checks;
mod facts;
mod fixes;
mod reduce;

pub use facts::{BackupFacts, DiskFacts, Facts, HealthSettings, LockFacts, PowerFacts, PowerSource, QuotaUsage};
pub use fixes::{FIXES, Fix, FixError, FixValues, fixes_for, render_argv};
pub use reduce::reduce;

use std::collections::BTreeMap;
use std::fmt;

/// The checks of server.md 9.3.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum CheckId {
    PowerOnBattery,
    NetworkOffline,
    DiskLow,
    LockPending,
    SleepEnabled,
    RestartNoAutoRestart,
    RestartFileVaultWait,
    RestartNotLoggedIn,
    LingerOff,
    EncryptionOff,
    PostgresQuota,
    BackupStale,
}

impl CheckId {
    pub const ALL: [CheckId; 12] = [
        CheckId::PowerOnBattery,
        CheckId::NetworkOffline,
        CheckId::DiskLow,
        CheckId::LockPending,
        CheckId::SleepEnabled,
        CheckId::RestartNoAutoRestart,
        CheckId::RestartFileVaultWait,
        CheckId::RestartNotLoggedIn,
        CheckId::LingerOff,
        CheckId::EncryptionOff,
        CheckId::PostgresQuota,
        CheckId::BackupStale,
    ];

    /// The stable check id used in dedupe keys and settings
    /// (`server.health.alerts.<check>`).
    pub fn as_str(self) -> &'static str {
        match self {
            CheckId::PowerOnBattery => "power.onBattery",
            CheckId::NetworkOffline => "network.offline",
            CheckId::DiskLow => "disk.low",
            CheckId::LockPending => "lock.pending",
            CheckId::SleepEnabled => "sleep.enabled",
            CheckId::RestartNoAutoRestart => "restart.noAutoRestart",
            CheckId::RestartFileVaultWait => "restart.fileVaultWait",
            CheckId::RestartNotLoggedIn => "restart.notLoggedIn",
            CheckId::LingerOff => "linger.off",
            CheckId::EncryptionOff => "encryption.off",
            CheckId::PostgresQuota => "postgres.quota",
            CheckId::BackupStale => "backup.stale",
        }
    }

    pub fn parse(s: &str) -> Option<CheckId> {
        CheckId::ALL.into_iter().find(|c| c.as_str() == s)
    }

    /// Localization key of the alert title; the body key is `….body`.
    pub fn title_key(self) -> String {
        format!("server.health.{}.title", self.as_str())
    }
}

impl fmt::Display for CheckId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Severity {
    Info,
    Warning,
    Critical,
}

impl Severity {
    pub fn as_str(self) -> &'static str {
        match self {
            Severity::Info => "info",
            Severity::Warning => "warning",
            Severity::Critical => "critical",
        }
    }
}

/// One alert instance: a check, plus the app for per-app checks
/// (`postgres.quota`).
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct AlertKey {
    pub check: CheckId,
    pub subject: Option<String>,
}

impl AlertKey {
    pub fn check(check: CheckId) -> AlertKey {
        AlertKey { check, subject: None }
    }

    /// `server:<host>:<check>`, or `server:<host>:<check>:<subject>`.
    pub fn dedupe_key(&self, host: &str) -> String {
        match &self.subject {
            None => format!("server:{host}:{}", self.check),
            Some(s) => format!("server:{host}:{}:{s}", self.check),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Alert {
    pub severity: Severity,
    /// When the alert was raised.
    pub raised_at_ms: u64,
}

/// The health role's state: raised alerts and the timers of delayed checks.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AlertSet {
    alerts: BTreeMap<AlertKey, Alert>,
    /// Delayed checks (`power.onBattery`, `network.offline`): when the
    /// condition became true. Present while the condition holds.
    pending: BTreeMap<AlertKey, u64>,
    /// The next time `reduce` must run with unchanged facts, if any.
    wake_at_ms: Option<u64>,
}

impl AlertSet {
    pub fn alerts(&self) -> &BTreeMap<AlertKey, Alert> {
        &self.alerts
    }

    pub fn get(&self, key: &AlertKey) -> Option<&Alert> {
        self.alerts.get(key)
    }

    pub fn is_empty(&self) -> bool {
        self.alerts.is_empty()
    }

    pub fn pending(&self) -> &BTreeMap<AlertKey, u64> {
        &self.pending
    }

    /// One-shot deadline for the caller's timer: a delayed check fires or a
    /// backup becomes stale at this time if facts do not change.
    pub fn wake_at_ms(&self) -> Option<u64> {
        self.wake_at_ms
    }

    /// The same timers with no raised alerts: the start of a from-scratch
    /// evaluation (used by the property tests).
    pub fn timers_only(&self) -> AlertSet {
        AlertSet { alerts: BTreeMap::new(), pending: self.pending.clone(), wake_at_ms: None }
    }
}

/// A fix offered with an alert (server.md 9.3 `actions`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FixRef {
    pub id: &'static str,
    pub title_key: &'static str,
    pub needs_admin: bool,
}

/// A feed post (lane 9 `feed.notify` / `feed.resolve`, kind `server.health`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Post {
    /// On raise and on every severity change.
    Notify {
        dedupe_key: String,
        host: String,
        check: CheckId,
        subject: Option<String>,
        severity: Severity,
        title_key: String,
        fixes: Vec<FixRef>,
    },
    /// On clear.
    Resolve { dedupe_key: String },
}

pub const FEED_KIND: &str = "server.health";
