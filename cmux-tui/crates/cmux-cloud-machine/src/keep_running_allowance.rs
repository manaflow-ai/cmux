//! The numbers behind "N of M kept running, X of Y hours" (hq RFD 0135 and RFD 0078), read from
//! the `cloud.plan.get` answer. Pure: the caller reads the plan (`/v1/read`, op `cloud.plan.get`)
//! and hands the answer here; this says how many chats run now against the plan's cap, how many
//! machine hours were used this month against the plan's, and which of the two runs out first.
//! No copy: the view words it.
//!
//! Units, as the platform has them (cmux-platform `Plan.ts`, `Meter.ts`, `PricingRule.ts`):
//! - `limits.max_active` and `usage.active` count machines running at once.
//! - `usage.vm_hours_used` is wall-clock machine hours this UTC month (running seconds / 3600,
//!   floored to 0.01), null while the meter is unknown.
//! - `included_machine_minutes` counts vCPU-minutes; a standard machine has
//!   [`STANDARD_MACHINE_VCPUS`] vCPUs, so the plan's hours are minutes / 60 / 4 (the division
//!   `PricingRule.ts` makes). It is null on plans that give no term total; then the classic
//!   `limits.vm_hours_included` is used, which is null too on every plan today.
//!
//! The two hour numbers are in different units when a machine is bigger than standard: used is
//! wall hours of any size, included is standard-machine hours. [`Allowance::hours_left`] compares
//! them as they are; the platform's own meter is what charges.

use serde::Serialize;
use serde_json::{Map, Value};

use crate::json::int;

/// vCPUs in the standard machine the plan's included minutes are counted against
/// (cmux-platform `NEXT_STANDARD_MACHINE_VCPUS`).
pub const STANDARD_MACHINE_VCPUS: f64 = 4.0;

/// What the plan allows and what is used of it. Every field is `None` when the answer lacks it.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Allowance {
    /// Machines running now (`usage.active`).
    pub running_now: Option<i64>,
    /// Machines the plan runs at once (`limits.max_active`).
    pub running_limit: Option<i64>,
    /// Machine hours used this month (`usage.vm_hours_used`).
    pub hours_used: Option<f64>,
    /// Machine hours the plan includes (see the module's units).
    pub hours_included: Option<f64>,
    /// `hours_included - hours_used`, never below 0; `None` unless both are known.
    pub hours_left: Option<f64>,
    /// When this month's count resets, epoch ms (`usage.period_end`).
    pub period_end_ms: Option<i64>,
    /// Which limit stops another chat from running first.
    pub binds: Binds,
}

/// Which limit stops another chat from running.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Binds {
    /// The month's hours are used up.
    Hours,
    /// Every running slot is taken.
    Running,
    /// Room on every limit that is known.
    Neither,
    /// Neither limit is known.
    #[default]
    Unknown,
}

/// Reads the allowance from a `cloud.plan.get` answer: the plan object itself, or one wrapped
/// as `{ "value": plan }` (the `/v1/read` answer) or `{ "plan": plan }`.
#[must_use]
pub fn read(answer: &Value) -> Allowance {
    let Some(plan) = unwrap_plan(answer) else {
        return Allowance::default();
    };
    let limits = plan.get("limits").and_then(Value::as_object);
    let usage = plan.get("usage").and_then(Value::as_object);

    let running_now = usage.and_then(|u| u.get("active")).and_then(int).filter(|n| *n >= 0);
    let running_limit = limits.and_then(|l| l.get("max_active")).and_then(int).filter(|n| *n >= 0);
    let hours_used = usage.and_then(|u| number(u, "vm_hours_used"));
    let hours_included = plan
        .get("included_machine_minutes")
        .and_then(Value::as_f64)
        .filter(|m| m.is_finite() && *m >= 0.0)
        .map(|minutes| minutes / 60.0 / STANDARD_MACHINE_VCPUS)
        .or_else(|| limits.and_then(|l| number(l, "vm_hours_included")));
    let hours_left = match (hours_included, hours_used) {
        (Some(included), Some(used)) => Some((included - used).max(0.0)),
        _ => None,
    };
    let period_end_ms = usage.and_then(|u| u.get("period_end")).and_then(int).filter(|n| *n > 0);

    let binds = binds(running_now, running_limit, hours_left);
    Allowance {
        running_now,
        running_limit,
        hours_used,
        hours_included,
        hours_left,
        period_end_ms,
        binds,
    }
}

/// The allowance as the camelCase JSON object the app decodes.
#[must_use]
pub fn to_value(allowance: &Allowance) -> Value {
    serde_json::to_value(allowance).unwrap_or(Value::Null)
}

fn binds(running_now: Option<i64>, running_limit: Option<i64>, hours_left: Option<f64>) -> Binds {
    if hours_left.is_some_and(|left| left <= 0.0) {
        return Binds::Hours;
    }
    match (running_now, running_limit) {
        (Some(now), Some(limit)) if now >= limit => Binds::Running,
        (Some(_), Some(_)) => Binds::Neither,
        _ if hours_left.is_some() => Binds::Neither,
        _ => Binds::Unknown,
    }
}

fn unwrap_plan(answer: &Value) -> Option<&Map<String, Value>> {
    let object = answer.as_object()?;
    if object.contains_key("limits") || object.contains_key("usage") {
        return Some(object);
    }
    ["value", "plan"].iter().find_map(|key| object.get(*key).and_then(unwrap_plan))
}

/// A finite, non-negative number field (a `WireNumber` arrives as a JSON number).
fn number(object: &Map<String, Value>, key: &str) -> Option<f64> {
    object.get(key).and_then(Value::as_f64).filter(|n| n.is_finite() && *n >= 0.0)
}

#[cfg(test)]
mod tests;
