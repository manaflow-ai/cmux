//! What the updater last did, as the machine's Cloud status report carries
//! it (`updater`), so the Cloud's census can read why a build reached its
//! first machine when it did instead of guessing (cmux-platform Census.ts
//! `UpdaterLook`).
//!
//! The block holds fixed codes and times (Unix ms) only. No session name and
//! no error text leaves the machine: a busy check's reason is the kind of
//! thing that held it, never the names.
//!
//! - `outcome`, `reason` and `at` describe the last check: `current`,
//!   `older`, `rolled-back-before`, `held` (reason `connect-hold`), `busy`
//!   (reasons `turn`, `carrier`, `unread`, joined by `+`), `swapped`, `off`
//!   or `failed`.
//! - `seen_at` and `waited` describe the last update run: when a check first
//!   found a build to take (it was held, busy, or swapped at once), and the
//!   run's last wait (`held:<reason>` or `busy:<reason>`). A run ends at its
//!   swap or at a check that finds nothing to take. The next held, busy or
//!   swap check starts a new one.
//! - `swapped` is the last flip: the build's commit (12 characters) and when.
//!
//! The check writes the block into the updater's state ([`super::State`]).
//! [`report`] reads it, and also [`super::PENDING_FILE`]. The flip's own
//! check may not live to save its outcome, because the restart it queues
//! ends the process. The pending file, written before the flip, still names
//! the swap.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::config::Paths;

/// The updater's last check and its last update run.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Look {
    pub outcome: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    pub at: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seen_at: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub waited: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub swapped: Option<Swap>,
}

/// One flip: the build's commit (its first 12 characters) and when (Unix ms).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Swap {
    pub commit: String,
    pub at: u64,
}

/// One check's outcome as codes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Seen {
    Current,
    Older,
    RolledBackBefore,
    /// A hold the check honors stopped the flip (its reason code).
    Held(String),
    /// Sessions or a look that could not read held it (its reason code).
    Busy(String),
    /// The flip to this commit happened.
    Swapped(String),
    Off,
    Failed,
}

/// A commit as the Cloud's census names a build: its first 12 characters.
fn short(commit: &str) -> String {
    commit.chars().take(12).collect()
}

impl Look {
    /// `prev` after one check that found `seen` at `at` (Unix ms).
    pub fn next(prev: Option<Look>, seen: Seen, at: u64) -> Look {
        let prev = prev.unwrap_or_default();
        // A run is open while its last check was held, busy, off or failed.
        let open = prev.seen_at.is_some()
            && matches!(prev.outcome.as_str(), "held" | "busy" | "off" | "failed");
        let mut look = Look { at, reason: None, ..prev };
        let start_run = |look: &mut Look| {
            if !open {
                look.seen_at = Some(at);
                look.waited = None;
            }
        };
        look.outcome = match seen {
            Seen::Current => "current".to_owned(),
            Seen::Older => "older".to_owned(),
            Seen::RolledBackBefore => "rolled-back-before".to_owned(),
            Seen::Off => "off".to_owned(),
            Seen::Failed => "failed".to_owned(),
            Seen::Held(reason) => {
                start_run(&mut look);
                look.waited = Some(format!("held:{reason}"));
                look.reason = Some(reason);
                "held".to_owned()
            }
            Seen::Busy(reason) => {
                start_run(&mut look);
                look.waited = Some(format!("busy:{reason}"));
                look.reason = Some(reason);
                "busy".to_owned()
            }
            Seen::Swapped(commit) => {
                start_run(&mut look);
                look.swapped = Some(Swap { commit: short(&commit), at });
                "swapped".to_owned()
            }
        };
        look
    }

    /// The look with the swap a pending update names (`commit`, flipped at
    /// `at` ms), when the look does not have that swap yet: its check did
    /// not live to save it.
    pub fn with_pending(look: Option<Look>, commit: &str, at: u64) -> Look {
        match look {
            Some(look) if look.swapped.as_ref().is_some_and(|s| s.commit == short(commit)) => look,
            prev => Look::next(prev, Seen::Swapped(commit.to_owned()), at),
        }
    }

    /// The block the status report carries.
    pub fn to_json(&self) -> Value {
        serde_json::to_value(self).unwrap_or(Value::Null)
    }
}

/// The reason codes of a busy check's items: `connect-hold` makes it held;
/// otherwise a carrier session (attached, or a look that could not tell)
/// is `carrier`, an acpmux look that could not read is `unread`, and any
/// other item is a session mid-turn (`turn`), named by acpmux. The items
/// are the updater's own texts (`role.rs` `Outcome::Busy`).
pub fn busy_seen(items: &[String]) -> Seen {
    if items.iter().any(|i| i.starts_with("connect hold")) {
        return Seen::Held("connect-hold".to_owned());
    }
    let mut codes: Vec<&str> = items
        .iter()
        .map(|i| {
            if i.contains("carrier session") {
                "carrier"
            } else if i.starts_with("acpmux") || i.starts_with("no acpmux daemon") {
                "unread"
            } else {
                "turn"
            }
        })
        .collect();
    codes.sort_unstable();
    codes.dedup();
    if codes.is_empty() {
        codes.push("turn");
    }
    Seen::Busy(codes.join("+"))
}

/// One check's [`super::role::Outcome`] as codes.
#[cfg(target_os = "linux")]
pub fn seen_of(outcome: &super::role::Outcome) -> Seen {
    use super::role::Outcome;
    match outcome {
        Outcome::Off(_) => Seen::Off,
        Outcome::Current(_) => Seen::Current,
        Outcome::Older => Seen::Older,
        Outcome::RolledBackBefore => Seen::RolledBackBefore,
        Outcome::Busy(items) => busy_seen(items),
        Outcome::Updating(commit) => Seen::Swapped(commit.clone()),
        Outcome::Failed(_) => Seen::Failed,
    }
}

/// The `updater` block of the machine's next status report: the updater's
/// state plus a pending update's swap (seconds in the pending file, ms
/// here). None when this machine's updater never checked.
pub fn report(paths: &Paths) -> Option<Value> {
    let look = super::load_state(paths).look;
    let look = match super::load_pending(paths) {
        Some(p) => Some(Look::with_pending(look, &p.commit, p.started_at.saturating_mul(1000))),
        None => look,
    };
    look.map(|l| l.to_json())
}

/// The same block without its `at`: what makes a report due when it
/// changes. A check every 15 s that finds the same thing makes no report;
/// its time rides along with the next one.
pub fn report_key(block: &Option<Value>) -> Option<Value> {
    block.as_ref().map(|b| {
        let mut b = b.clone();
        if let Some(map) = b.as_object_mut() {
            map.remove("at");
        }
        b
    })
}

#[cfg(test)]
mod tests;
