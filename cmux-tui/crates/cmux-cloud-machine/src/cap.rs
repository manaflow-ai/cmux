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

/// The card.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Cap {
    /// Newest activity first; empty on a free plan.
    pub busy: Vec<Busy>,
    /// The plan has no Cloud machines at all: the card offers no pause.
    pub free_plan: bool,
}

/// The card for an app-server refusal (its `code` and `details`) at the cap
/// (`cmux.cloud.quota_exceeded`, upstream `cloud.quota.exceeded`); None for any other refusal,
/// including another quota and the team's VM limit (`cloud.quota.vm_limit`, cmux-platform#1192):
/// paused machines count there, so the card's Pause and Upgrade free nothing, and the refusal's
/// own words (its limit, delete one) stand.
pub fn refusal(code: &str, details: Option<&Value>) -> Option<Cap> {
    if !(code.ends_with("quota_exceeded") || code.ends_with("quota.exceeded")) {
        return None;
    }
    let resource = details
        .and_then(|details| details.get("resource"))
        .and_then(Value::as_str)
        .unwrap_or("active");
    (resource == "active").then(|| Cap { busy: busy_details(details), free_plan: false })
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
    Cap { busy, free_plan }
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
