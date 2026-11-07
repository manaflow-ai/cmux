//! Which workspaces are idle enough to archive, and when to look again
//! (plans/cmux-next/auto-archive-DESIGN.md). Ported from cmux-next macOS
//! `AutoArchivePlanner.swift` and the snooze rule of
//! `AutoArchiveCoordinator.plan`.
//!
//! Pure: the app gathers one [`Candidate`] per placed workspace (its own
//! last activity, the activity ledger's last sight, its groups nearest
//! first and what keeps it), the groups' rules and the clock, and performs
//! the [`Plan`]. The planner never archives anything that is pinned, shown
//! in a window, running a command or an agent turn, or asking for the
//! person (unread, waiting, error), and never a workspace whose nearest
//! group with a rule says Never. The app reaches it once per background
//! pass, sweep or review list through `cmux_layout_reducer_json`
//! (`auto_archive_plan`); the card's words and the toasts stay in the app.

use crate::sidebar_doc::model::AutoArchiveRule;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

/// Never look again sooner than this after a pass (seconds): a burst of
/// wakes stays one pass a minute.
pub const MINIMUM_RECHECK: f64 = 60.0;

/// Seconds in a day (the setting's `idleDays` unit).
const DAY: f64 = 86_400.0;

/// How idle workspaces leave the way (`workspaces.autoArchive.style`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Style {
    /// A sidebar card lists them.
    Suggest,
    /// They archive on their own; a toast offers Undo.
    Quiet,
    /// Only members of groups with their own rule archive on their own.
    Groups,
    /// Only Archive Idle Workspaces archives. The default.
    #[default]
    Manual,
    /// Never in the background; group rules are ignored.
    Off,
}

/// The `workspaces.autoArchive` setting.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Policy {
    pub style: Style,
    /// Days a workspace stays idle before it counts (a group's own rule wins).
    pub idle_days: f64,
}

impl Default for Policy {
    fn default() -> Self {
        Policy { style: Style::Manual, idle_days: 3.0 }
    }
}

impl Policy {
    /// `idle_days` in seconds.
    pub fn idle_seconds(self) -> f64 {
        self.idle_days * DAY
    }
}

/// What asks for the plan.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Trigger {
    /// The background pass (launch, a deadline, a setting change): obeys the style.
    #[default]
    Background,
    /// Archive Idle Workspaces: the person asked, so it runs under every
    /// style and uses the idle time even where the style would only suggest.
    /// A group's Never still keeps its members.
    Sweep,
}

/// One placed workspace and what keeps it. Times are seconds since 1970.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Candidate {
    /// The newest sign of use the app knows (output, an agent update, a notification).
    pub last_active: Option<f64>,
    /// The activity ledger's last sight of it on this Mac.
    pub seen: Option<f64>,
    /// Its group items, nearest first (the nearest group with a rule decides).
    pub groups: Vec<String>,
    pub pinned: bool,
    pub archived: bool,
    /// Shown in a window right now: counts as used now.
    pub shown: bool,
    /// A command or an agent turn runs in one of its tabs.
    pub running: bool,
    /// It asks for the person: unread, waiting for an answer, an error.
    pub needs_attention: bool,
}

impl Candidate {
    /// The newer of the app's last activity and the ledger's last sight.
    pub fn last_used(&self) -> Option<f64> {
        match (self.last_active, self.seen) {
            (Some(a), Some(b)) => Some(a.max(b)),
            (a, b) => a.or(b),
        }
    }
}

/// One plan request.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Request {
    pub candidates: Vec<Candidate>,
    /// Each group's own rule by item id, as the document stores it
    /// (`"never"` or whole hours; anything else is no rule).
    pub rules: BTreeMap<String, Value>,
    pub policy: Policy,
    pub trigger: Trigger,
    pub now: f64,
    /// No suggestion card before this time (the card's Not Now).
    pub snoozed_until: Option<f64>,
}

/// What is due now, and when the next one comes due.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Plan {
    /// Indices into the request's candidates to archive (or suggest), idlest first.
    pub due: Vec<usize>,
    /// When the next kept-for-age workspace comes due; none when none will without a change.
    pub next_check: Option<f64>,
    /// Indices of candidates never seen before: the app records the first
    /// sight at `now`, so a workspace is never idle on arrival.
    pub first_sight: Vec<usize>,
    /// The suggestion card is snoozed: nothing is due before the snooze
    /// ends, and the app keeps its ledger as it is.
    pub snoozed: bool,
}

/// The plan for `request`.
pub fn plan(request: &Request) -> Plan {
    let first_sight = request
        .candidates
        .iter()
        .enumerate()
        .filter(|(_, candidate)| candidate.last_used().is_none())
        .map(|(index, _)| index)
        .collect();
    let policy = request.policy;
    let snooze = request.snoozed_until.filter(|until| {
        request.trigger == Trigger::Background
            && policy.style == Style::Suggest
            && request.now < *until
    });
    let mut plan = plan_due(request);
    plan.first_sight = first_sight;
    if let Some(until) = snooze {
        plan.due.clear();
        // Never sooner than a minute, also when the snooze ends sooner and nothing else is pending.
        let floor = request.now + MINIMUM_RECHECK;
        plan.next_check = Some(plan.next_check.map_or(until, |next| next.max(until)).max(floor));
        plan.snoozed = true;
    }
    plan
}

fn plan_due(request: &Request) -> Plan {
    let policy = request.policy;
    if request.trigger == Trigger::Background && matches!(policy.style, Style::Off | Style::Manual)
    {
        return Plan::default();
    }
    let now = request.now;
    let mut due: Vec<(usize, f64)> = Vec::new();
    let mut next: Option<f64> = None;
    for (index, candidate) in request.candidates.iter().enumerate() {
        if candidate.archived
            || candidate.pinned
            || candidate.shown
            || candidate.running
            || candidate.needs_attention
        {
            continue;
        }
        let Some(idle) = idle_seconds(candidate, &request.rules, policy, request.trigger) else {
            continue;
        };
        // First sight: the app records it at `now`, so its clock starts now. It is never due on
        // arrival, but its deadline still counts toward the next check.
        let first_sight = candidate.last_used().is_none();
        let last = candidate.last_used().unwrap_or(now);
        let deadline = last + idle;
        if deadline <= now && !first_sight {
            due.push((index, now - last));
        } else if next.is_none_or(|soonest| deadline < soonest) {
            next = Some(deadline);
        }
    }
    // Idlest first; equal idle times keep the candidates' order.
    due.sort_by(|a, b| b.1.total_cmp(&a.1));
    let floor = now + MINIMUM_RECHECK;
    Plan {
        due: due.into_iter().map(|(index, _)| index).collect(),
        next_check: next.map(|deadline| deadline.max(floor)),
        first_sight: Vec::new(),
        snoozed: false,
    }
}

/// Seconds `candidate` must stay idle, or none when nothing archives it: the
/// nearest group with a rule decides (Never: none). Without one, the
/// setting's days, except the Groups style, which only archives where a
/// group set a rule (the person's sweep still uses the days).
pub fn idle_seconds(
    candidate: &Candidate,
    rules: &BTreeMap<String, Value>,
    policy: Policy,
    trigger: Trigger,
) -> Option<f64> {
    let ruled = trigger == Trigger::Sweep || policy.style != Style::Off;
    if ruled
        && let Some(rule) = candidate
            .groups
            .iter()
            .find_map(|group| rules.get(group).and_then(AutoArchiveRule::read))
    {
        return rule_idle_seconds(rule);
    }
    if trigger == Trigger::Background && policy.style == Style::Groups {
        return None;
    }
    Some(policy.idle_seconds())
}

/// Seconds a member of a group with `rule` must stay idle; none for Never.
pub fn rule_idle_seconds(rule: AutoArchiveRule) -> Option<f64> {
    match rule {
        AutoArchiveRule::Never => None,
        AutoArchiveRule::AfterHours(hours) => Some(hours as f64 * 3600.0),
    }
}

#[cfg(test)]
#[path = "auto_archive_tests.rs"]
mod tests;
