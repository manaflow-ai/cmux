//! `HomeChiefArchive`: Archive Chief hides the row on this Mac at once and
//! the cloud's `chief.archive` follows when it can run. Swift keeps the
//! `hidden` set's storage and the calls; these are its decisions.

use super::chiefs::Record;
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

/// The account as the archive reads it (`HomeChiefArchive.Account`'s
/// values).
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Account {
    /// The active Chiefs of the last `chief.list`.
    #[serde(default)]
    pub chiefs: Vec<Record>,
    /// The archived and deleted Chiefs of the last `chief.list`.
    #[serde(default)]
    pub gone: BTreeSet<String>,
    /// `chief.list` answered this launch.
    #[serde(default)]
    pub listed: bool,
}

/// The cloud's answer to one `chief.archive` (`HomeChiefArchive.Reply`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Reply {
    Archived,
    Conflict,
    IsDefault,
    NotFound,
    Refused { message: String },
    Unreachable,
}

/// One step of the cloud archive (`cloudArchive`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Step {
    /// Call `chief.archive` of this record.
    Call { record: Record },
    /// The cloud archived it (or it is already gone); when `dropped`, tell
    /// the account (`archived(id)`).
    Done { dropped: bool },
    /// Hidden here; the cloud archive waits.
    Waits,
    /// Read `chief.list` again, then plan the next attempt.
    Reread,
    /// Shown again; `reason` nil is the default `archiveFailed` text.
    Refused { reason: Option<String> },
}

/// `cloudArchive` before a call: the record to archive, or the outcome.
pub fn plan(id: &str, account: &Account) -> Step {
    let Some(record) = account.chiefs.iter().find(|c| c.id == id) else {
        if account.gone.contains(id) {
            return Step::Done { dropped: false };
        }
        return if account.listed { Step::Refused { reason: None } } else { Step::Waits };
    };
    if record.is_default {
        return Step::Waits;
    }
    Step::Call { record: record.clone() }
}

/// `cloudArchive` after the call's `reply` on `attempt` (0 or 1): one
/// revision conflict reads again and retries.
pub fn after(reply: &Reply, attempt: u32) -> Step {
    match reply {
        Reply::Archived | Reply::NotFound => Step::Done { dropped: true },
        Reply::Conflict if attempt == 0 => Step::Reread,
        Reply::Conflict | Reply::IsDefault | Reply::Unreachable => Step::Waits,
        Reply::Refused { message } => {
            Step::Refused { reason: (!message.is_empty()).then(|| message.clone()) }
        }
    }
}

/// `archive(_:in:)`'s outcome from the cloud step's end.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Outcome {
    Archived,
    HiddenHere,
    /// Shown again (unhide); `reason` nil is `archiveFailed`.
    Refused {
        reason: Option<String>,
    },
}

/// The outcome of a finished cloud step; nil while the step is not an end
/// (`call`, `reread`).
pub fn outcome(step: &Step) -> Option<Outcome> {
    match step {
        Step::Done { .. } => Some(Outcome::Archived),
        Step::Waits => Some(Outcome::HiddenHere),
        Step::Refused { reason } => Some(Outcome::Refused { reason: reason.clone() }),
        Step::Call { .. } | Step::Reread => None,
    }
}

/// One hidden Chief at a `sync` pass.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Sync {
    /// Nothing now (no list yet, or no longer hidden).
    Skip,
    /// The cloud archived it, or it is not this account's: unhide.
    Unhide,
    /// Run the cloud archive.
    Archive,
    /// The default Chief: stays hidden here only.
    Keep,
}

/// `sync(_:)` for one id (Swift runs the ids sorted, re-reading the
/// account after each await).
pub fn sync_one(id: &str, hidden: &BTreeSet<String>, account: &Account) -> Sync {
    if !account.listed || !hidden.contains(id) {
        return Sync::Skip;
    }
    match account.chiefs.iter().find(|c| c.id == id) {
        _ if account.gone.contains(id) => Sync::Unhide,
        None => Sync::Unhide,
        Some(listed) if !listed.is_default => Sync::Archive,
        Some(_) => Sync::Keep,
    }
}
