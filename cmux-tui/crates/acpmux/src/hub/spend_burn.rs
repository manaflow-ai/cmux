//! A task's spend burn-rate warnings, during its turn (`turn_cost.rs` puts its cost on the
//! `turn_result` only once the turn ends). Leo, 2026-11-24: "i never only want top x changes. you
//! all need to be working through all useful ones end to end to end."
//!
//! Every live `usage_update` of a running turn updates the task's running spend, and the spend is
//! checked against the per-task budget. Two kinds of warning, each a `spend_warning` event on the
//! session (a client hears it as it hears `turn_result`), each fired at most once a turn:
//! - fast burn (`level: "fast_burn"`): at the spend rate so far, the budget runs out within
//!   [`FAST_BURN_HORIZON_S`], a long turn, and at least [`FAST_BURN_MIN_SHARE`] of it is spent (the
//!   SRE Workbook's multiwindow burn-rate alerts, chapter "Alerting on SLOs": a high burn rate over
//!   a short window, with a floor so one early call cannot page). With no budget, the rate alone:
//!   [`FAST_BURN_USD_PER_MIN`] or more once [`NO_BUDGET_MIN_USD`] is spent.
//! - slow burn (`level: "budget_50"`, `"budget_90"`): half and nine tenths of the budget spent;
//!   `"over_budget"`: all of it (SEC Rule 15c3-5's pre-set credit thresholds, here only reported).
//!
//! Warnings only: nothing here stops, cancels or holds a turn. The budget is
//! `ACPMUX_TASK_BUDGET_USD` (default [`DEFAULT_BUDGET_USD`]; `0`, `off` or `none` sets none, which
//! leaves the fast-burn heuristic alone), the no-budget rate `ACPMUX_FAST_BURN_USD_PER_MIN`, and
//! `ACPMUX_SPEND_WARNINGS=0` turns the warnings off; all read once.
//!
//! The running spend: a harness that reports its cumulative cost on `usage_update` (ACP's
//! `cost: {amount, currency: "USD"}`) gives it as the rise since the session's last report before
//! the turn; else each model call's `usage_update` (`_meta.acpmux.call`, `claude_stdio`) adds its
//! tokens at the bundled price table (`crate::pricing`) for the chat's model.
//!
//! The turn's `turn_result` carries `spendBurn.checks`, `spendBurn.checkUs` (the turn's checks'
//! time added up), `spendBurn.checkMaxUs`, `spendBurn.warnings` and `spendBurn.overBudget`;
//! [`counters`] has the daemon's totals (warnings fired, tasks over budget), which every warning
//! carries too.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

use serde_json::{Map, Value, json};

use super::{Hub, Session};
use crate::store::TurnUsage;

/// A task's budget when `ACPMUX_TASK_BUDGET_USD` sets none: a long agent turn on a frontier model
/// costs a few dollars; ten is well past a normal one.
pub const DEFAULT_BUDGET_USD: f64 = 10.0;
/// The window a fast burn is projected over: a long turn.
pub const FAST_BURN_HORIZON_S: f64 = 600.0;
/// The share of the budget a fast burn needs spent before it warns.
pub const FAST_BURN_MIN_SHARE: f64 = 0.1;
/// With no budget: the spend rate that is a fast burn, USD a minute.
pub const FAST_BURN_USD_PER_MIN: f64 = 1.0;
/// With no budget: what a task has spent before its rate can warn.
pub const NO_BUDGET_MIN_USD: f64 = 0.5;
/// Elapsed time below this counts as this, so the first call's rate is finite.
const MIN_ELAPSED_S: f64 = 1.0;

/// The thresholds, in the order they fire.
const LEVELS: [(&str, f64); 3] = [("budget_50", 0.5), ("budget_90", 0.9), ("over_budget", 1.0)];
const FAST: &str = "fast_burn";
const COUNTER: &str = "spendBurn";

/// The warning settings, read once from the environment.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Settings {
    pub enabled: bool,
    pub budget_usd: Option<f64>,
    pub fast_usd_per_min: f64,
}

impl Settings {
    /// From the three variables' values (module docs).
    pub fn parse(enabled: Option<&str>, budget: Option<&str>, rate: Option<&str>) -> Self {
        let enabled = !matches!(enabled.map(str::trim), Some("0" | "off" | "false" | "no"));
        let budget_usd = match budget.map(str::trim) {
            None | Some("") => Some(DEFAULT_BUDGET_USD),
            Some("off" | "none") => None,
            Some(v) => match v.parse::<f64>() {
                Ok(b) if b.is_finite() && b > 0.0 => Some(b),
                Ok(_) => None,
                Err(_) => Some(DEFAULT_BUDGET_USD),
            },
        };
        let fast_usd_per_min = rate
            .and_then(|v| v.trim().parse::<f64>().ok())
            .filter(|r| r.is_finite() && *r > 0.0)
            .unwrap_or(FAST_BURN_USD_PER_MIN);
        Self { enabled, budget_usd, fast_usd_per_min }
    }
}

fn settings() -> Settings {
    static S: OnceLock<Settings> = OnceLock::new();
    *S.get_or_init(|| {
        let var = |k: &str| std::env::var(k).ok();
        Settings::parse(
            var("ACPMUX_SPEND_WARNINGS").as_deref(),
            var("ACPMUX_TASK_BUDGET_USD").as_deref(),
            var("ACPMUX_FAST_BURN_USD_PER_MIN").as_deref(),
        )
    })
}

static WARNINGS_FIRED: AtomicU64 = AtomicU64::new(0);
static TASKS_OVER_BUDGET: AtomicU64 = AtomicU64::new(0);

/// The daemon's totals since it started: warnings fired and tasks that went over budget.
pub fn counters() -> Value {
    json!({
        "warningsFired": WARNINGS_FIRED.load(Ordering::Relaxed),
        "tasksOverBudget": TASKS_OVER_BUDGET.load(Ordering::Relaxed),
    })
}

/// One warning a check found.
#[derive(Clone, Debug, PartialEq)]
pub struct Warning {
    pub level: &'static str,
    pub spent_usd: f64,
    pub usd_per_min: f64,
    /// Seconds until the budget runs out at this rate; None with no budget or past it.
    pub exhausts_in_s: Option<f64>,
}

/// A running turn's spend and what it warned of.
#[derive(Debug, Default)]
pub struct Burn {
    turn_id: String,
    started_ms: u64,
    /// The task's spend from priced model calls.
    calls_usd: f64,
    /// The harness's cumulative cost the turn's spend is measured from, and its latest.
    cumulative_base: Option<f64>,
    cumulative_last: Option<f64>,
    /// Bits: one per entry of [`LEVELS`], then fast burn.
    fired: u8,
    checks: u64,
    check_ns: u64,
    check_max_ns: u64,
    warnings: u64,
}

const FAST_BIT: u8 = 1 << LEVELS.len();

impl Burn {
    /// The task's spend so far.
    pub fn spent(&self) -> f64 {
        match (self.cumulative_base, self.cumulative_last) {
            (Some(base), Some(last)) => (last - base).max(0.0) + self.calls_usd,
            _ => self.calls_usd,
        }
    }

    /// Starts `turn_id` (begun at `started_ms`, Unix ms) when it is not the one held, keeping the
    /// harness's last cumulative cost as the new turn's base.
    pub fn enter(&mut self, turn_id: &str, started_ms: u64) {
        if self.turn_id == turn_id {
            return;
        }
        let last = self.cumulative_last;
        *self = Burn {
            turn_id: turn_id.to_owned(),
            started_ms,
            cumulative_base: last,
            cumulative_last: last,
            ..Burn::default()
        };
    }

    /// Adds a usage update's spend: a cumulative cost, or one priced call. `first_turn`: the
    /// session had no earlier turn, so a cumulative cost with no base counts from 0.
    pub fn add(&mut self, cumulative: Option<f64>, call_usd: Option<f64>, first_turn: bool) {
        if let Some(c) = cumulative.filter(|c| c.is_finite() && *c >= 0.0) {
            if self.cumulative_base.is_none() {
                self.cumulative_base = Some(if first_turn { 0.0 } else { c });
            }
            // A total that went down (a restart, a new conversation): the turn keeps what it had
            // spent, and counts on from the new total.
            if let (Some(last), Some(base)) = (self.cumulative_last, self.cumulative_base)
                && c < last
            {
                self.cumulative_base = Some(c - (last - base).max(0.0));
            }
            self.cumulative_last = Some(c);
        } else if let Some(u) = call_usd.filter(|u| u.is_finite() && *u > 0.0) {
            self.calls_usd += u;
        }
    }

    /// The warnings due at `now_ms` under `s`, each marked fired so it never fires again this turn.
    pub fn check(&mut self, s: &Settings, now_ms: u64) -> Vec<Warning> {
        let spent = self.spent();
        let elapsed = (now_ms.saturating_sub(self.started_ms) as f64 / 1000.0).max(MIN_ELAPSED_S);
        let per_s = spent / elapsed;
        let mut out = Vec::new();
        let warn = |level, exhausts_in_s| Warning {
            level,
            spent_usd: spent,
            usd_per_min: per_s * 60.0,
            exhausts_in_s,
        };
        match s.budget_usd {
            Some(budget) => {
                let left = budget - spent;
                let exhausts = (left > 0.0 && per_s > 0.0).then(|| left / per_s);
                let fast = spent >= FAST_BURN_MIN_SHARE * budget
                    && left > 0.0
                    && exhausts.is_some_and(|t| t <= FAST_BURN_HORIZON_S);
                if fast && self.fired & FAST_BIT == 0 {
                    self.fired |= FAST_BIT;
                    out.push(warn(FAST, exhausts));
                }
                for (i, (level, share)) in LEVELS.iter().enumerate() {
                    if spent >= share * budget && self.fired & (1 << i) == 0 {
                        self.fired |= 1 << i;
                        out.push(warn(level, exhausts));
                    }
                }
            }
            None => {
                let fast = spent >= NO_BUDGET_MIN_USD && per_s * 60.0 >= s.fast_usd_per_min;
                if fast && self.fired & FAST_BIT == 0 {
                    self.fired |= FAST_BIT;
                    out.push(warn(FAST, None));
                }
            }
        }
        out
    }

    fn over_budget(&self) -> bool {
        self.fired & (1 << (LEVELS.len() - 1)) != 0
    }
}

fn burns() -> std::sync::MutexGuard<'static, HashMap<String, Burn>> {
    static BURNS: OnceLock<Mutex<HashMap<String, Burn>>> = OnceLock::new();
    BURNS.get_or_init(Default::default).lock().unwrap_or_else(|e| e.into_inner())
}

/// A `usage_update`'s cumulative USD cost (ACP `cost`), if it reports one.
fn cumulative_cost(update: &Value) -> Option<f64> {
    let cost = update.get("cost")?;
    let currency = cost.get("currency").and_then(Value::as_str).unwrap_or("USD");
    currency.eq_ignore_ascii_case("USD").then(|| cost.get("amount")?.as_f64()).flatten()
}

/// A model call's `usage_update` (`claude_stdio` `call_usage`) as its tokens.
fn call_usage(update: &Value) -> Option<TurnUsage> {
    if update.pointer("/_meta/acpmux/call") != Some(&Value::Bool(true)) {
        return None;
    }
    let n = |k: &str| update.get(k).and_then(Value::as_u64);
    Some(TurnUsage {
        input_tokens: n("inputTokens"),
        output_tokens: n("outputTokens"),
        cache_read_tokens: n("cachedReadTokens"),
        cache_write_tokens: n("cachedWriteTokens"),
        ..TurnUsage::default()
    })
}

/// The `spend_warning` event's record for `w` under `budget`.
pub fn warning_record(w: &Warning, budget: Option<f64>, turn_id: &str) -> Value {
    let round = |x: f64| (x * 1e6).round() / 1e6;
    let mut msg = json!({
        "level": w.level,
        "turnId": turn_id,
        "spentUsd": round(w.spent_usd),
        "usdPerMin": round(w.usd_per_min),
        "budgetUsd": budget,
        "counters": counters(),
    });
    if let (Some(b), Some(m)) = (budget, msg.as_object_mut()) {
        m.insert("budgetShare".into(), json!((w.spent_usd / b * 1000.0).round() / 1000.0));
        if let Some(t) = w.exhausts_in_s {
            m.insert("exhaustsInS".into(), json!((t * 10.0).round() / 10.0));
        }
    }
    msg
}

impl Hub {
    /// A live `usage_update` of `session` (`permissions/inbound.rs`, beside `on_update_cache`):
    /// adds its spend to the running turn's and appends any warning it brings (module docs).
    pub(in crate::hub) fn spend_burn_on_update(
        self: &Arc<Self>,
        session: &Arc<Session>,
        params: Option<&Value>,
        replayed: bool,
    ) {
        let Some(update) = params.and_then(|p| p.get("update")).filter(|_| !replayed) else {
            return;
        };
        if update.get("sessionUpdate").and_then(Value::as_str) != Some("usage_update") {
            return;
        }
        let s = settings();
        if !s.enabled {
            return;
        }
        let cumulative = cumulative_cost(update);
        let call = if cumulative.is_none() { call_usage(update) } else { None };
        if cumulative.is_none() && call.is_none() {
            return;
        }
        let started = Instant::now();
        let Some((turn_id, started_ms)) = session
            .turn
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
            .map(|t| (t.turn_id.clone(), t.started_at))
        else {
            return;
        };
        let (first_turn, call_usd) = session.read_meta(|m| {
            let usd = call.as_ref().and_then(|u| {
                super::current_model(m).and_then(|model| crate::pricing::table().cost(&model, u))
            });
            (m.turn_count <= 1, usd)
        });
        let warnings = {
            let mut burns = burns();
            let burn = burns.entry(session.id.clone()).or_default();
            burn.enter(&turn_id, started_ms);
            burn.add(cumulative, call_usd, first_turn);
            let warnings = burn.check(&s, crate::store::now_ms());
            burn.warnings += warnings.len() as u64;
            let ns = started.elapsed().as_nanos() as u64;
            burn.checks += 1;
            burn.check_ns += ns;
            burn.check_max_ns = burn.check_max_ns.max(ns);
            warnings
        };
        for w in &warnings {
            WARNINGS_FIRED.fetch_add(1, Ordering::Relaxed);
            if w.level == "over_budget" {
                TASKS_OVER_BUDGET.fetch_add(1, Ordering::Relaxed);
            }
            tracing::info!(session = %session.id, level = w.level, spent = w.spent_usd, "task spend warning");
            self.append(session, "mux", "spend_warning", warning_record(w, s.budget_usd, &turn_id));
        }
    }
}

/// The turn's spend-check fields for its `turn_result` (module docs), when it had a check; the
/// turn's counts then start over, and its cumulative cost stays the next turn's base.
pub(crate) fn turn_fields(session: &str, turn_id: &str) -> Map<String, Value> {
    let mut fields = Map::new();
    let mut burns = burns();
    let Some(b) = burns.get_mut(session).filter(|b| b.turn_id == turn_id && b.checks > 0) else {
        return fields;
    };
    let key = |name: &str| format!("{COUNTER}.{name}");
    fields.insert(key("checks"), json!(b.checks));
    let us = |ns: u64| (ns as f64 / 1000.0 * 1000.0).round() / 1000.0;
    fields.insert(key("checkUs"), json!(us(b.check_ns)));
    fields.insert(key("checkMaxUs"), json!(us(b.check_max_ns)));
    fields.insert(key("warnings"), json!(b.warnings));
    fields.insert(key("spentUsd"), json!((b.spent() * 1e6).round() / 1e6));
    fields.insert(key("overBudget"), json!(b.over_budget()));
    (b.checks, b.check_ns, b.check_max_ns, b.warnings) = (0, 0, 0, 0);
    fields
}

/// Forgets `session`'s spend (the session is gone).
pub(crate) fn forget(session: &str) {
    burns().remove(session);
}

#[cfg(test)]
#[path = "spend_burn_tests.rs"]
mod tests;
