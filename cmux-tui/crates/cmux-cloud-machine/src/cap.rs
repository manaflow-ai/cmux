//! A Cloud create at the plan's machine cap (leo-workspace design/cloud.md, "At the machine
//! cap"). Leo, 2026-11-02: "you try to create a new workspace/machine past the cap, what do we
//! wanna do? reuse existing or ask upgrade or".
//!
//! cmux-platform's CloudDO makes room itself on the app-server link: a person's create at the cap
//! pauses the least recently used of their own idle machines, then creates, and the answer names
//! it (`made_room`). Only when every machine of theirs is busy does the create come back refused
//! (`cloud.quota.exceeded`, `details.busy`), and the app shows one card: Pause one (each busy
//! machine), Upgrade, or Run on This Mac. The classic link makes no room: it shows the same card,
//! with Pause only where pausing frees room. A free plan has nothing to pause. Never another
//! workspace's machine, never a teammate's.

use std::cmp::Ordering;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::json::text;
use crate::record::Machine;

/// One of the person's own machines that counts against the cap.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Busy {
    pub machine: String,
    pub name: String,
    /// Its last activity (epoch ms), when the server knows it.
    #[serde(default)]
    pub last_active_at: Option<f64>,
}

/// The team holds as many Cloud machines as it may keep, paused ones included
/// (`cloud.quota.vm_limit`, or a machine quota other than the running cap): pausing frees nothing,
/// so the card offers Upgrade and Run on This Mac, never Pause.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MachineLimit {
    /// The team's limit, when the refusal names it.
    #[serde(default)]
    pub limit: Option<u64>,
    /// The machines the team holds, when the refusal names them.
    #[serde(default)]
    pub used: Option<u64>,
}

/// The team made as many machines as it may in an hour (`cloud.rate_limited` with `window_ms`,
/// cmux-platform's CLOUD_CREATE_PER_HOUR): the card says when the next create fits and offers Run
/// on This Mac. Neither Pause nor Upgrade frees it, so it offers neither.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateRate {
    /// The creates an hour the team may make, when the refusal names it.
    #[serde(default)]
    pub limit: Option<u64>,
    /// How long until the oldest create leaves the hour, in ms.
    #[serde(default)]
    pub retry_after_ms: Option<u64>,
}

/// The card.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Cap {
    /// Newest activity first; empty on a free plan.
    pub busy: Vec<Busy>,
    /// The plan has no Cloud machines at all: the card offers no pause.
    pub free_plan: bool,
    /// The team is at its machine-count limit (paused ones count): Upgrade, never Pause.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub machine_limit: Option<MachineLimit>,
    /// The team is at its hourly create limit: when it frees up, Run on This Mac.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub create_rate: Option<CreateRate>,
}

/// The card for an app-server refusal (its `code` and `details`) at a machine limit; None for any
/// other refusal, including a quota on something other than machines (snapshots).
///
/// - The running cap (`cmux.cloud.quota_exceeded`, upstream `cloud.quota.exceeded`, `resource`
///   `active` or unnamed): Pause one of `details.busy`, Upgrade, or Run on This Mac.
/// - The team's hourly create limit (`cloud.rate_limited` with `window_ms`): when it frees up,
///   and Run on This Mac (cmux#56154: it read as raw text).
/// - The team's machine-count limit, paused machines included (`cloud.quota.vm_limit`, the app
///   server's `cmux.cloud.vm_limit`, cmux-platform#1192; or a `quota_exceeded` on `machines`,
///   every machine held): Pause frees nothing, so the card offers Upgrade and Run on This Mac (cmux#56154: a
///   bare error there left no way to upgrade).
pub fn refusal(code: &str, details: Option<&Value>) -> Option<Cap> {
    let count = |key: &str| details.and_then(|details| details.get(key)).and_then(Value::as_u64);
    if code.ends_with("quota.vm_limit") || code.ends_with("cloud.vm_limit") {
        let limit = MachineLimit {
            limit: count("limit"),
            used: count("team_vms").or_else(|| count("used")),
        };
        return Some(Cap { machine_limit: Some(limit), ..Cap::default() });
    }
    // The hourly create limit names its window; the per-minute request limit (also
    // `rate_limited`) does not, and keeps its own words: it frees within a minute.
    if code.ends_with("rate_limited") {
        details.and_then(|details| details.get("window_ms"))?;
        let rate = CreateRate { limit: count("limit"), retry_after_ms: count("retry_after_ms") };
        return Some(Cap { create_rate: Some(rate), ..Cap::default() });
    }
    if !(code.ends_with("quota_exceeded") || code.ends_with("quota.exceeded")) {
        return None;
    }
    let resource = details
        .and_then(|details| details.get("resource"))
        .and_then(Value::as_str)
        .unwrap_or("active");
    match resource {
        "active" => Some(Cap { busy: busy_details(details), ..Cap::default() }),
        "machines" => Some(Cap {
            machine_limit: Some(MachineLimit { limit: count("limit"), used: count("used") }),
            ..Cap::default()
        }),
        _ => None,
    }
}

/// `details.busy` of a cap refusal: `[{machine, name, last_active_at}]`, in the server's order.
pub fn busy_details(details: Option<&Value>) -> Vec<Busy> {
    let entries = details.and_then(|details| details.get("busy")).and_then(Value::as_array);
    entries
        .into_iter()
        .flatten()
        .filter_map(|entry| {
            let machine = entry.get("machine")?.as_str().filter(|id| !id.is_empty())?.to_owned();
            let name = text(entry.get("name"))
                .filter(|name| !name.is_empty())
                .unwrap_or_else(|| machine.clone());
            Some(Busy {
                machine,
                name,
                last_active_at: entry.get("last_active_at").and_then(Value::as_f64),
            })
        })
        .collect()
}

/// The card for a refusal the app read itself (its plan gate, the classic link's 402): `user`'s
/// own machines only when pausing one frees what refused the create (`pause_frees`), else no
/// pause. The classic allowance counts paused machines too, so there only its vCPU and memory
/// pool refusal, which counts running machines alone, offers Pause (cmux#32710).
pub fn plan(free_plan: bool, pause_frees: bool, machines: &[Machine], user: Option<&str>) -> Cap {
    let busy = if free_plan || !pause_frees { Vec::new() } else { busy_machines(machines, user) };
    Cap { busy, free_plan, ..Cap::default() }
}

/// `user`'s own machines that count against the cap (running or on their way, with no change of
/// this app's pending), newest activity first. With no user known, none: never a teammate's.
pub fn busy_machines(machines: &[Machine], user: Option<&str>) -> Vec<Busy> {
    let Some(user) = user.filter(|user| !user.is_empty()) else { return Vec::new() };
    let mut busy: Vec<Busy> = machines
        .iter()
        .filter(|machine| {
            machine.created_by.as_deref() == Some(user)
                && machine.status.is_live()
                && machine.pending_change.is_none()
        })
        .map(|machine| {
            let api = machine
                .idle_pause
                .as_ref()
                .and_then(|idle| idle.last_api_activity_at)
                .map(|at| at as f64);
            Busy {
                machine: machine.id.clone(),
                name: machine.title().to_owned(),
                last_active_at: api.or(machine.running_since),
            }
        })
        .collect();
    let at = |busy: &Busy| busy.last_active_at.unwrap_or(f64::NEG_INFINITY);
    busy.sort_by(|left, right| at(right).partial_cmp(&at(left)).unwrap_or(Ordering::Equal));
    busy
}

/// The machine a create's answer paused to make room (`made_room.machine`), None when it paused none.
pub fn made_room(answer: &Value) -> Option<&Value> {
    answer.get("made_room")?.get("machine")
}

#[cfg(test)]
mod tests;
