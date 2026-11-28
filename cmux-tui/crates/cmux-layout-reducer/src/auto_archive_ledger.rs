//! Auto-archive's ledger and what a pass does with its plan, moved from Swift's
//! `AutoArchiveLedger.swift` and `AutoArchiveCoordinator.swift` (plans/cmux-next/auto-archive-DESIGN.md).
//!
//! The ledger holds when this Mac last saw each workspace used, the items auto-archive archived itself
//! (they come back when shown) and the suggestion card's snooze. The plan is [`crate::auto_archive`]'s;
//! these rules decide what the coordinator does around it: the sights a plan records and the records it
//! drops, whether a background pass archives, suggests or does nothing, the card's names, which shown
//! workspaces come back, and what an archive, a restore and Not Now write. The app keeps the clock, the
//! deadlines, the toasts and the `archive` sends.

use crate::auto_archive::Style;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

/// Not Now keeps the card away this long (seconds).
pub const SNOOZE: f64 = 86_400.0;
/// The card lists at most this many names.
pub const CARD_NAMES: usize = 5;
/// A pass never schedules the next one sooner than this (seconds).
pub const MINIMUM_DELAY: f64 = 1.0;

/// The ledger, in the shape the app stores it (`AutoArchiveLedger`'s Codable keys).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Ledger {
    /// Last use by workspace id, seconds since 1970.
    #[serde(default)]
    pub seen: BTreeMap<String, f64>,
    /// Document items auto-archive archived.
    #[serde(default)]
    pub auto_archived: BTreeSet<String>,
    /// No suggestion card before this time (Not Now), seconds since 1970.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub snoozed_until: Option<f64>,
}

impl Ledger {
    /// Records a use of `workspace` at `time` (the newer of the two wins).
    pub fn saw(&mut self, workspace: &str, time: f64) {
        if self.seen.get(workspace).is_none_or(|seen| *seen < time) {
            self.seen.insert(workspace.to_owned(), time);
        }
    }

    /// Drops the records of workspaces and items that are gone.
    pub fn keep(&mut self, workspaces: &BTreeSet<String>, items: &BTreeSet<String>) {
        self.seen.retain(|workspace, _| workspaces.contains(workspace));
        self.auto_archived.retain(|item| items.contains(item));
    }
}

/// What a background pass does with the workspaces its plan finds due.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Action {
    /// Archive them now (a refusal is logged, never a toast).
    Archive,
    /// Show the suggestion card.
    Suggest,
    /// Nothing is due, or the style archives nothing on its own.
    None,
}

/// The pass's decision: what it does, when the next pass runs (seconds from now) and the idle days the card says.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Pass {
    pub action: Action,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recheck_after: Option<f64>,
    pub days: i64,
}

/// A background pass with `due` workspaces due, the plan's `next_check` and the clock `now`.
pub fn pass(style: Style, idle_days: f64, due: usize, next_check: Option<f64>, now: f64) -> Pass {
    let recheck_after = next_check.map(|next| (next - now).max(MINIMUM_DELAY));
    let action = match style {
        _ if due == 0 => Action::None,
        Style::Quiet | Style::Groups => Action::Archive,
        Style::Suggest => Action::Suggest,
        Style::Manual | Style::Off => Action::None,
    };
    Pass { action, recheck_after, days: whole(idle_days) }
}

/// Swift's `Int(x.rounded())`: half away from zero, saturating.
fn whole(value: f64) -> i64 {
    let rounded = value.round();
    if rounded.is_nan() {
        0
    } else if rounded >= i64::MAX as f64 {
        i64::MAX
    } else if rounded <= i64::MIN as f64 {
        i64::MIN
    } else {
        rounded as i64
    }
}

/// The ledger after a plan at `now`: each first sight recorded, and (unless the card is snoozed) the records of
/// workspaces and items that are gone dropped. `dirty`: it must be saved.
pub fn planned(
    mut ledger: Ledger,
    first_sight: &[String],
    snoozed: bool,
    workspaces: &BTreeSet<String>,
    items: &BTreeSet<String>,
    now: f64,
) -> (Ledger, bool) {
    for workspace in first_sight {
        ledger.saw(workspace, now);
    }
    if !snoozed {
        ledger.keep(workspaces, items);
    }
    (ledger, !first_sight.is_empty())
}

/// The card's lines: the first [`CARD_NAMES`] titles, and how many more there are (the app words "and N more").
pub fn card(titles: &[String]) -> (Vec<String>, Option<usize>) {
    let lines = titles.iter().take(CARD_NAMES).cloned().collect();
    let more = (titles.len() > CARD_NAMES).then(|| titles.len() - CARD_NAMES);
    (lines, more)
}

/// A workspace a window shows now: its document item (none while unplaced) and whether that item is archived.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Shown {
    pub workspace: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub item: Option<String>,
    #[serde(default)]
    pub archived: bool,
}

/// The windows show `shown` at `now`: each is seen, and the items auto-archive archived that are still archived come
/// back (`back`, restored next). `dirty`: anything was shown.
pub fn shown(mut ledger: Ledger, shown: &[Shown], now: f64) -> (Ledger, Vec<String>, bool) {
    let mut back = Vec::new();
    for row in shown {
        ledger.saw(&row.workspace, now);
        if ledger.auto_archived.is_empty() || !row.archived {
            continue;
        }
        if let Some(item) = row.item.as_ref().filter(|item| ledger.auto_archived.contains(*item)) {
            back.push(item.clone());
        }
    }
    let dirty = !shown.is_empty();
    (ledger, back, dirty)
}

/// The ledger after auto-archive archived `items`.
pub fn archived(mut ledger: Ledger, items: &[String]) -> Ledger {
    ledger.auto_archived.extend(items.iter().cloned());
    ledger
}

/// The ledger after `items` were restored at `now`; `workspaces` names the workspace of each restored workspace item:
/// it counts as used now.
pub fn restored(mut ledger: Ledger, items: &[String], workspaces: &[String], now: f64) -> Ledger {
    for item in items {
        ledger.auto_archived.remove(item);
    }
    for workspace in workspaces {
        ledger.saw(workspace, now);
    }
    ledger
}

/// The ledger after Not Now at `now`, and when the next pass runs (seconds from now).
pub fn snoozed(mut ledger: Ledger, now: f64) -> (Ledger, f64) {
    ledger.snoozed_until = Some(now + SNOOZE);
    (ledger, SNOOZE)
}

/// What the card's Archive takes: its `items` still due now, in order.
pub fn still_due(items: &[String], due: &[String]) -> Vec<String> {
    let due: BTreeSet<&String> = due.iter().collect();
    items.iter().filter(|item| due.contains(item)).cloned().collect()
}

/// A request to the `auto_archive_ledger` FFI op.
#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Request {
    /// `{action, recheck_after?, days}`.
    Pass {
        style: Style,
        idle_days: f64,
        due: usize,
        #[serde(default)]
        next_check: Option<f64>,
        now: f64,
    },
    /// `{ledger, dirty}`.
    Planned {
        #[serde(default)]
        ledger: Ledger,
        #[serde(default)]
        first_sight: Vec<String>,
        #[serde(default)]
        snoozed: bool,
        #[serde(default)]
        workspaces: BTreeSet<String>,
        #[serde(default)]
        items: BTreeSet<String>,
        now: f64,
    },
    /// `{lines, more?}`.
    Card { titles: Vec<String> },
    /// `{ledger, back, dirty}`.
    Shown {
        #[serde(default)]
        ledger: Ledger,
        shown: Vec<Shown>,
        now: f64,
    },
    /// `{ledger}`.
    Archived {
        #[serde(default)]
        ledger: Ledger,
        items: Vec<String>,
    },
    /// `{ledger}`.
    Restored {
        #[serde(default)]
        ledger: Ledger,
        items: Vec<String>,
        #[serde(default)]
        workspaces: Vec<String>,
        now: f64,
    },
    /// `{ledger, recheck_after}`.
    Snoozed {
        #[serde(default)]
        ledger: Ledger,
        now: f64,
    },
    /// `{items}`.
    StillDue { items: Vec<String>, due: Vec<String> },
}

/// The answer to one request.
pub fn respond(request: Request) -> Value {
    match request {
        Request::Pass { style, idle_days, due, next_check, now } => {
            json!(pass(style, idle_days, due, next_check, now))
        }
        Request::Planned { ledger, first_sight, snoozed, workspaces, items, now } => {
            let (ledger, dirty) = planned(ledger, &first_sight, snoozed, &workspaces, &items, now);
            json!({"ledger": ledger, "dirty": dirty})
        }
        Request::Card { titles } => {
            let (lines, more) = card(&titles);
            match more {
                Some(more) => json!({"lines": lines, "more": more}),
                None => json!({"lines": lines}),
            }
        }
        Request::Shown { ledger, shown: rows, now } => {
            let (ledger, back, dirty) = shown(ledger, &rows, now);
            json!({"ledger": ledger, "back": back, "dirty": dirty})
        }
        Request::Archived { ledger, items } => json!({"ledger": archived(ledger, &items)}),
        Request::Restored { ledger, items, workspaces, now } => {
            json!({"ledger": restored(ledger, &items, &workspaces, now)})
        }
        Request::Snoozed { ledger, now } => {
            let (ledger, recheck_after) = snoozed(ledger, now);
            json!({"ledger": ledger, "recheck_after": recheck_after})
        }
        Request::StillDue { items, due } => json!({"items": still_due(&items, &due)}),
    }
}

#[cfg(test)]
#[path = "auto_archive_ledger_tests.rs"]
mod tests;
