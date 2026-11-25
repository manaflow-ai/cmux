//! The fault-injection tests at model level, one module per part: register,
//! drive the clock until the part hangs, assert the exact action sequence
//! through the ticks (backoff, the cap, `failed`, the user's click), then
//! the recovery when the signal comes back, the receipts, and that no timer
//! is armed when every part is healthy or hidden.

mod daemon;
mod page;
mod parts;
mod scale;

use crate::model::Health;
use crate::{Kind, Outcome, PartView, RepairAction};

fn model() -> Health {
    Health::new()
}

/// Ticks at each `nextTickMs` up to `until`: `(at, action, attempt)` of
/// every action.
fn run(health: &mut Health, until: u64) -> Vec<(u64, RepairAction, u32)> {
    let mut out = Vec::new();
    while let Some(at) = health.next_tick_ms().filter(|&at| at <= until) {
        out.extend(health.tick(at).into_iter().map(|a| (at, a.action, a.attempt)));
    }
    out
}

fn part(health: &Health, id: &str) -> Option<PartView> {
    health.snapshot().parts.into_iter().find(|p| p.id == id)
}

/// Receipts of `id`, oldest first: `(action, outcome)`.
fn receipts(health: &Health, id: &str) -> Vec<(RepairAction, Outcome)> {
    let mut all: Vec<_> = health
        .snapshot()
        .receipts
        .into_iter()
        .filter(|r| r.id == id)
        .map(|r| (r.action, r.outcome))
        .collect();
    all.reverse();
    all
}

fn register(health: &mut Health, id: &str, kind: Kind, label: &str, now: u64) {
    health.register(id, kind, label, Some(now), true);
}
