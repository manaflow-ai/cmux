//! One machine's transient power states, as every caller that needs it running meets them (a chat's start, a send,
//! an exec, a status read that attaches, a fork): what it does on each look at the machine's record. A machine that is
//! `pausing` (cmux Cloud's idle auto-pause, or a Pause landing) or `starting` (a resume on its way) is waited out and
//! a paused one resumed, inside the caller's own step, never answered as an error.
//!
//! Leo, 2026-11-25 09:50Z, on a new Cloud chat that failed at "Set up a Cloud machine" with "This machine is pausing.
//! Try again once it is paused.": "whoa what happened here" (ask-259986a6c4). The machine the composer leased at Cloud
//! pick idled out (60 s idle window past the 180 s start grace) before Send, and the start refused the pause in flight
//! at once (`requireAttachableState`), where a resume had been waited out since 2026-11-05.
//!
//! The app observes the record and runs the waits and the resume; this decides each step. Kill switch:
//! `CMUX_CLOUD_SETTLE=0` refuses a machine in a transient state at once, as before.

use serde::{Deserialize, Serialize};

/// The kill switch's environment variable: `0` answers a transient state with [`Settle::Refuse`], as before.
pub const KILL_SWITCH: &str = "CMUX_CLOUD_SETTLE";

/// How long one caller waits for a machine to settle in all, pause and resume together: a pause lands in seconds
/// (the provider's memory snapshot) and a resume within a minute; past this the caller's own failure applies.
pub const SETTLE_LIMIT_MS: u64 = 180_000;

/// How many resumes one caller sends at most. A machine that settles back to paused after one is the platform's
/// answer (a pool pause, a cap), and a second resume is sent only because an idle pause can land again after the
/// first resume ran while the caller still waited on its link.
pub const RESUMES: u32 = 2;

/// A machine record's power status, as the app reads it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Power {
    Provisioning,
    Starting,
    Running,
    Pausing,
    Paused,
    Deleting,
    Destroyed,
    Failed,
    #[serde(other)]
    Unknown,
}

/// One look at the machine a caller waits on.
#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SettleLook {
    pub status: Power,
    /// How long this caller has waited on the machine so far.
    #[serde(default)]
    pub waited_ms: u64,
    /// Resumes this caller sent so far.
    #[serde(default)]
    pub resumes: u32,
    /// The caller's own bound, when shorter than [`SETTLE_LIMIT_MS`] (a start's connect wait).
    #[serde(default)]
    pub limit_ms: Option<u64>,
    /// The kill switch is off (`CMUX_CLOUD_SETTLE=0`).
    #[serde(default)]
    pub killed: bool,
}

/// What a caller does on one look.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "act")]
pub enum Settle {
    /// The machine runs (or is still being made, which the caller's own create wait covers): go on.
    Proceed,
    /// A pause is on its way: wait until the record reads something else, then look again. The caller shows
    /// "Waking machine", not the pause.
    WaitPausing,
    /// A resume is on its way: wait until it runs, then look again.
    WaitStarting,
    /// The machine is paused: resume it, then look again.
    Resume,
    /// Not for this caller: a delete, a failed machine, the deadline, or the kill switch on a transient state.
    Refuse { reason: Refusal },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Refusal {
    Deleting,
    Failed,
    /// Still pausing or starting at [`SETTLE_LIMIT_MS`], or paused again after [`RESUMES`] resumes.
    Deadline,
    /// The kill switch is off and the machine was pausing or starting.
    Transient,
}

/// The one rule: what a caller does on `look`.
pub fn settle(look: SettleLook) -> Settle {
    let transient = matches!(look.status, Power::Pausing | Power::Starting | Power::Paused);
    if look.killed && transient && look.status != Power::Paused {
        return Settle::Refuse { reason: Refusal::Transient };
    }
    match look.status {
        Power::Running | Power::Provisioning | Power::Unknown => Settle::Proceed,
        Power::Deleting | Power::Destroyed => Settle::Refuse { reason: Refusal::Deleting },
        Power::Failed => Settle::Refuse { reason: Refusal::Failed },
        _ if look.waited_ms
            >= look.limit_ms.map_or(SETTLE_LIMIT_MS, |l| l.min(SETTLE_LIMIT_MS)) =>
        {
            Settle::Refuse { reason: Refusal::Deadline }
        }
        Power::Pausing => Settle::WaitPausing,
        Power::Starting => Settle::WaitStarting,
        // A paused machine resumes; the caller's attach does that by itself when it was the only resume (the app's
        // `attach` resumes a paused machine), so a caller that already resumed `RESUMES` times stops here.
        Power::Paused if look.resumes >= RESUMES => Settle::Refuse { reason: Refusal::Deadline },
        Power::Paused => Settle::Resume,
    }
}

impl Settle {
    /// Whether the caller's start shows "Waking machine" under its machine step for this act: while it waits out a
    /// pause or a resume in flight (Leo, 2026-11-25 09:50Z: "whoa what happened here", ask-259986a6c4). Never for a
    /// refusal, so `CMUX_CLOUD_SETTLE=0` shows nothing new.
    pub fn waking(self) -> bool {
        matches!(self, Settle::WaitPausing | Settle::WaitStarting)
    }
}

/// Whether the kill switch is off in `value` (the variable's value, if set).
pub fn killed(value: Option<&str>) -> bool {
    value.is_some_and(|v| matches!(v.trim(), "0" | "false" | "off"))
}

#[cfg(test)]
#[path = "settle_tests.rs"]
mod tests;
