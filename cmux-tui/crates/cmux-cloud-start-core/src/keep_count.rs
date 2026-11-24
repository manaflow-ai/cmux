//! The keep-running switch's count (cmuxterm-hq RFD 0135, Onboarding): how many chats the plan
//! keeps running at once, how many it keeps now, the awake hours behind them, and what turning
//! this chat's switch on or off will do, so the plan limit is met at the switch ("2 of 3 kept
//! running"; "3 kept running, 41 of 100 hours used") and not on a pricing page.
//!
//! Pure: the caller sends the plan, the count of chats holding a slot, whether this chat holds
//! one, and the pool's awake hours used; [`count`] answers the numbers and one [`Next`]. The
//! words are the UI's. Served over the app FFI's JSON channel as `cloud_hybrid_keep_count`.
//!
//! The table is RFD 0135's, which RFD 0078's slot rule follows:
//!
//! | Plan | Kept running at once | Awake hours |
//! | --- | --- | --- |
//! | No plan | 1, on the no-card taste | 10 in 7 days (RFD 0052) |
//! | $1 first month | 3 | 100 a month, shared |
//! | Plus | 3 | 100 a month, shared |
//! | Pro | 5 | 1,000 |
//! | 20 agents | 20 | 4,000 |
//! | Max | 50 | 10,000 |

use serde::{Deserialize, Serialize};

/// A plan the switch counts for. The names match the slot rule's (`moves::priority::Plan` on the
/// hybrid-chats branch) so one wire value serves both.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Plan {
    /// The no-card taste the first turn-on starts (RFD 0052).
    Trial,
    /// The $1 first month: Plus's first month, with Plus's limits.
    Intro,
    Plus,
    Pro,
    Agents20,
    Max,
}

impl Plan {
    /// The plan a `cloud.plan.get` grant names, or None for no plan (or one this table does not
    /// know, which counts as no plan rather than guessing a limit). The older Cloud grants follow
    /// the platform's ranks (`backend/apps/api/src/cloud-vm-plan.ts`): `go` is Plus's rank, `pro`,
    /// `founders` and `team` Pro's, `max` Max's.
    pub fn from_id(id: &str) -> Option<Self> {
        match id.trim() {
            "next_taste" | "trial" => Some(Self::Trial),
            "next_intro" | "intro" => Some(Self::Intro),
            "next_plus" | "plus" | "go" => Some(Self::Plus),
            "next_pro" | "pro" | "founders" | "team" => Some(Self::Pro),
            "next_agents20" | "agents20" => Some(Self::Agents20),
            "next_max" | "max" => Some(Self::Max),
            _ => None,
        }
    }

    /// What the plan includes.
    pub fn allowance(self) -> Allowance {
        let (slots, hours, window) = match self {
            Self::Trial => (1, 10, Window::Week),
            Self::Intro | Self::Plus => (3, 100, Window::Month),
            Self::Pro => (5, 1_000, Window::Month),
            Self::Agents20 => (20, 4_000, Window::Month),
            Self::Max => (50, 10_000, Window::Month),
        };
        Allowance { slots, hours, window }
    }
}

/// The span the hours are counted over.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Window {
    /// The taste's 7 days.
    Week,
    Month,
}

/// A plan's chats kept running at once and the pooled awake hours behind them.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Allowance {
    pub slots: u32,
    pub hours: u32,
    pub window: Window,
}

/// What the caller knows. `plan` is a [`Plan`] or a grant id ([`Plan::from_id`]).
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Facts {
    pub plan: Option<String>,
    /// Chats holding a slot now, this one included when it is on.
    pub kept: u32,
    /// This chat's switch is on (it holds a slot, or waits for one).
    pub on: bool,
    /// Awake hours the pool used in this window; None when not read.
    pub hours_used: Option<f64>,
}

/// What flipping this chat's switch will do.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "do", rename_all = "camelCase")]
pub enum Next {
    /// No plan: turning it on starts the no-card taste, which keeps this one.
    StartsTrial { slots: u32, hours: u32 },
    /// Room left: turning it on keeps this one too, `after` of the plan's slots.
    Keeps { after: u32 },
    /// Every slot is taken: one kept chat has to stop first (the slot rule's holders).
    Full,
    /// The window's hours are spent: a kept chat waits for this Mac until they reset.
    HoursUsedUp,
    /// This one is kept: turning it off gives its slot back, `after` of the plan's slots.
    Frees { after: u32 },
}

/// The switch's count.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Count {
    /// The plan counted, None for no plan.
    pub plan: Option<Plan>,
    /// Chats kept running now.
    pub kept: u32,
    /// The plan's chats kept running at once (0 with no plan).
    pub slots: u32,
    /// Whole awake hours used, rounded down; None when not read or with no plan.
    pub hours_used: Option<u32>,
    /// The plan's awake hours in its window; None with no plan.
    pub hours: Option<u32>,
    pub window: Option<Window>,
    /// The window's hours are 80% used or more: on Plus the hours bite before the count does
    /// (RFD 0135: three chats fit 100 hours only for a light user).
    pub hours_low: bool,
    pub next: Next,
}

/// The share of the hours past which [`Count::hours_low`] is set.
pub const HOURS_LOW: f64 = 0.8;

fn plan_of(text: &str) -> Option<Plan> {
    serde_json::from_value(serde_json::Value::String(text.to_owned()))
        .ok()
        .or_else(|| Plan::from_id(text))
}

/// The count and what the switch will do.
pub fn count(facts: &Facts) -> Count {
    let plan = facts.plan.as_deref().and_then(plan_of);
    let Some(plan) = plan else {
        let taste = Plan::Trial.allowance();
        return Count {
            plan: None,
            kept: facts.kept,
            slots: 0,
            hours_used: None,
            hours: None,
            window: None,
            hours_low: false,
            next: Next::StartsTrial { slots: taste.slots, hours: taste.hours },
        };
    };
    let allowance = plan.allowance();
    let used = facts.hours_used.filter(|h| h.is_finite()).map(|h| h.max(0.0));
    let spent = used.is_some_and(|h| h >= f64::from(allowance.hours));
    let next = if facts.on {
        Next::Frees { after: facts.kept.saturating_sub(1) }
    } else if spent {
        Next::HoursUsedUp
    } else if facts.kept >= allowance.slots {
        Next::Full
    } else {
        Next::Keeps { after: facts.kept + 1 }
    };
    Count {
        plan: Some(plan),
        kept: facts.kept,
        slots: allowance.slots,
        hours_used: used.map(|h| h.floor().min(f64::from(u32::MAX)) as u32),
        hours: Some(allowance.hours),
        window: Some(allowance.window),
        hours_low: used.is_some_and(|h| h >= f64::from(allowance.hours) * HOURS_LOW),
        next,
    }
}

#[cfg(test)]
#[path = "keep_count/tests.rs"]
mod tests;
