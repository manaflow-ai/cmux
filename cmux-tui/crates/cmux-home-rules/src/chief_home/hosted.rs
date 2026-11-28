//! The hosted Chief's copy ledger and run decisions (CmuxNextHostedChief `HostedChiefLedger.swift`,
//! `HostedChiefMigration.swift`). The network calls, UserDefaults and the memory export stay Swift.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// `HostedChiefLedger.maxFailures`: refused copies before the run gives up.
pub const MAX_FAILURES: i64 = 3;

/// The UserDefaults keys of one Chief home's ledger (`HostedChiefLedger`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LedgerKeys {
    pub account: String,
    pub history: String,
    pub memory: String,
    pub memory_started: String,
    pub brain: String,
    pub failures: String,
}

/// `HostedChiefLedger`'s keys for `session` and `chief`.
pub fn ledger_keys(session: &str, chief: &str) -> LedgerKeys {
    let step = |name: &str| format!("home.chief.hosted.{session}.{chief}.{name}");
    LedgerKeys {
        account: format!("home.chief.hostedAccount.{session}"),
        history: step("history"),
        memory: step("memory"),
        memory_started: step("memoryStarted"),
        brain: step("brain"),
        failures: step("failures"),
    }
}

/// `HostedChiefLedger.isRefusal`: an owner error the server will refuse again (not transient, not busy, not auth).
/// `owner_code` is `HostedChiefError.owner`'s code; None for any other error.
pub fn is_refusal(owner_code: Option<&str>) -> bool {
    let Some(code) = owner_code else { return false };
    let transient = ["rate", "unavailable"].iter().any(|part| code.contains(part))
        || ["http_5", "internal", "auth"].iter().any(|prefix| code.starts_with(prefix));
    !(transient || ["brain_busy", "http_401", "http_403"].contains(&code))
}

/// `HostedChiefLedger.host(session:)`: `mac-<printable ASCII of the session>`, at most 128 characters.
pub fn host(session: &str) -> String {
    let token: String = session.chars().filter(|c| ('\u{21}'..='\u{7e}').contains(c)).collect();
    format!("mac-{token}").chars().take(128).collect()
}

/// `HostedChiefMigration.Wiring.copies`: a release build copies; a DEV build only with
/// `CMUX_NEXT_HOSTED_CHIEF_COPY=1`.
pub fn wiring_copies(debug_build: bool, environment: &BTreeMap<String, String>) -> bool {
    !debug_build || environment.get("CMUX_NEXT_HOSTED_CHIEF_COPY").map(String::as_str) == Some("1")
}

/// `HostedChiefMigration.start`'s inputs.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StartInputs {
    #[serde(default)]
    pub user: Option<String>,
    /// The hosted Chief's main conversation; None when there is no hosted Chief or it has none.
    #[serde(default)]
    pub main_conversation: Option<String>,
    #[serde(default)]
    pub has_hosted: bool,
    #[serde(default)]
    pub wiring_copies: bool,
    #[serde(default)]
    pub ledger_account: Option<String>,
    #[serde(default)]
    pub tool_bundled: bool,
    #[serde(default)]
    pub memory_exists: bool,
    #[serde(default)]
    pub history_done: bool,
    #[serde(default)]
    pub memory_done: bool,
}

/// What `start` decides.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StartPlan {
    /// Signed in with a hosted Chief that has a main conversation: a run may start.
    pub runs: bool,
    /// This home copies (one account per Chief home).
    pub copies: bool,
    pub memory_due: bool,
    /// The local Chief keeps the tab until the history and memory are in.
    pub pending: bool,
}

/// `HostedChiefMigration.start`'s rules.
pub fn start(inputs: &StartInputs) -> StartPlan {
    let Some(user) = inputs.user.as_deref() else { return StartPlan::default() };
    if !inputs.has_hosted || inputs.main_conversation.is_none() {
        return StartPlan::default();
    }
    let copies = inputs.wiring_copies
        && inputs.ledger_account.as_deref().is_none_or(|account| account == user);
    let memory_due = inputs.tool_bundled && inputs.memory_exists && !inputs.memory_done;
    StartPlan {
        runs: true,
        copies,
        memory_due,
        pending: copies && (!inputs.history_done || memory_due),
    }
}

/// The memory step of a run (`HostedChiefMigration.run` step 2): `done` (nothing to do), `skip` (no memory store:
/// mark it done), `export` (copy it with the bundled tool) or `wait` (no tool in this build: leave it unmarked).
pub fn memory_step(memory_done: bool, memory_exists: bool, tool_bundled: bool) -> &'static str {
    if memory_done {
        "done"
    } else if !memory_exists {
        "skip"
    } else if tool_bundled {
        "export"
    } else {
        "wait"
    }
}

/// The brain step's inputs (`HostedChiefMigration.run` step 3).
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BrainInputs {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub brain_turned_off: bool,
    #[serde(default)]
    pub copied: bool,
    #[serde(default)]
    pub created_here: bool,
}

/// What the brain step does.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BrainPlan {
    /// Turn the brain on (a PUT); `enabled` is the state after it succeeds.
    pub turn_on: bool,
    pub enabled: bool,
    /// Mark the ledger's brain step and forget `createdHere`.
    pub mark_brain: bool,
    /// `brainOff` when the brain stays off (the user turned it off), else None.
    pub notice: Option<&'static str>,
}

/// The brain answers from now on: turned on only after this run turned it off or copied into it, or for a hosted
/// Chief this Home created. A brain the user turned off stays off, and Home says so.
pub fn brain(inputs: &BrainInputs) -> BrainPlan {
    let turn_on =
        !inputs.enabled && (inputs.brain_turned_off || inputs.copied || inputs.created_here);
    let enabled = inputs.enabled || turn_on;
    BrainPlan { turn_on, enabled, mark_brain: enabled, notice: (!enabled).then_some("brainOff") }
}

/// A failed run's inputs.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FailureInputs {
    /// `HostedChiefError.owner`'s code; None for another error.
    #[serde(default)]
    pub owner_code: Option<String>,
    #[serde(default)]
    pub cancelled: bool,
    /// The run is still the current one.
    #[serde(default = "yes")]
    pub current: bool,
    #[serde(default)]
    pub brain_read: bool,
    #[serde(default)]
    pub copies: bool,
    /// The ledger's failure count before this one.
    #[serde(default)]
    pub failures: i64,
}

fn yes() -> bool {
    true
}

/// What a failed run does.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FailurePlan {
    /// `busy` (the brain is busy: again on the next connect), `cancelled`, `stale` (another run took over),
    /// `brainFailed`, `giveUp`, `copyFailed` or `none` (a brain read that failed: nothing changes).
    pub action: &'static str,
    /// The notice Home shows: `brainFailed`, `copyFailed`, None to clear it, absent to keep it.
    pub notice: Option<&'static str>,
    pub sets_notice: bool,
    /// `brainOn` becomes false (only for `brainFailed`).
    pub brain_off: bool,
    pub record_failure: bool,
    /// Mark history and memory done and settle (give up).
    pub mark_steps: bool,
}

/// `HostedChiefMigration.run`'s catch.
pub fn failure(inputs: &FailureInputs) -> FailurePlan {
    let code = inputs.owner_code.as_deref();
    let plan = |action| FailurePlan { action, ..FailurePlan::default() };
    if code == Some("brain_busy") {
        return plan("busy");
    }
    if inputs.cancelled {
        return plan("cancelled");
    }
    if !inputs.current {
        return plan("stale");
    }
    if inputs.brain_read {
        return FailurePlan {
            notice: Some("brainFailed"),
            sets_notice: true,
            brain_off: true,
            ..plan("brainFailed")
        };
    }
    let refusal = is_refusal(code);
    if inputs.copies && refusal && inputs.failures >= MAX_FAILURES {
        return FailurePlan { notice: None, sets_notice: true, mark_steps: true, ..plan("giveUp") };
    }
    if inputs.copies {
        return FailurePlan {
            notice: Some("copyFailed"),
            sets_notice: true,
            record_failure: refusal,
            ..plan("copyFailed")
        };
    }
    plan("none")
}
