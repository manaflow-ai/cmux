//! The shadow admission verdict at each placement and each session create
//! (cmuxterm-hq#7342): beside the pick acpmux makes, what
//! `cmux_host_budget::shadow_verdict` says about each host. Shadow only: no
//! pick changes and nothing is refused or deferred on it.
//!
//! Each decision logs one line through `tracing` at info, so it lands in the
//! daemon's log (`daemon.log`, or the journal under systemd):
//! `shadow-admission {JSON}`, with `ts`, `site` (`place`, `pick`, `subsession`
//! or `admit`), `pick`, the pick's `would_defer`, `reason`, `inputs_digest`,
//! `formula_version`, and `hosts`, one compact verdict per host weighed.
//!
//! The readings come from `_acpmux/host_health` (this machine's, read now, or a
//! peer's last one). A reading's time is when it arrived (`healthAt`, or now for
//! this machine) less the age of the meter sample behind it (`pressureAgeMs`),
//! so no two hosts' clocks are compared. Swap growth is the meter's; PSI cpu and
//! per-session CPU and RSS are not carried yet, so they read as unknown.
//!
//! The daemon keeps each host's last state (the formula's hysteresis input)
//! and last verdict, for at most [`MAX_HOSTS`] hosts; `daemon status` reports the
//! verdicts as `shadowAdmission` and `acpmux ls` prints a line for each one
//! that would defer.

use crate::host_pressure::{ShadowInputs, ShadowState, ShadowVerdict, shadow_verdict};
use crate::placement::Candidate;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

/// The most hosts whose state is kept; past it the oldest-seen are dropped.
const MAX_HOSTS: usize = 256;

/// The `tracing` message every shadow line starts with.
pub const LOG_PREFIX: &str = "shadow-admission";

struct Kept {
    state: ShadowState,
    verdict: Value,
    seen_ms: u64,
}

fn kept() -> &'static Mutex<HashMap<String, Kept>> {
    static KEPT: OnceLock<Mutex<HashMap<String, Kept>>> = OnceLock::new();
    KEPT.get_or_init(Mutex::default)
}

fn lock() -> std::sync::MutexGuard<'static, HashMap<String, Kept>> {
    kept().lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// The formula's inputs for one candidate at `now_ms` (module docs).
pub fn inputs(c: &Candidate, now_ms: u64, previous: Option<ShadowState>) -> ShadowInputs {
    let h = &c.health;
    let num = |ptr: &str| h.pointer(ptr).and_then(Value::as_f64);
    let int = |ptr: &str| h.pointer(ptr).and_then(Value::as_u64);
    let age = int("/pressureAgeMs").unwrap_or(0);
    let cores = int("/pressure/cores")
        .filter(|n| *n > 0)
        .or_else(|| int("/cpus"))
        .and_then(|n| u32::try_from(n).ok());
    ShadowInputs {
        host: c.name.clone(),
        now_ms: Some(now_ms),
        health_at_ms: (!h.is_null())
            .then_some(c.health_at)
            .flatten()
            .map(|at| at.saturating_sub(age)),
        cores,
        load1: num("/load/0").or_else(|| num("/pressure/load1")),
        psi_cpu_some_avg10: None,
        mem_pressure: h.pointer("/pressure/pressure").and_then(Value::as_str).map(str::to_owned),
        available_fraction: num("/pressure/available_ram_fraction"),
        ram_total_bytes: int("/ram/totalBytes"),
        swap_used_bytes: int("/swap/usedBytes"),
        swap_total_bytes: int("/swap/totalBytes"),
        swap_growth_mb_per_min: num("/pressure/swap_mb_per_min"),
        sessions: Vec::new(),
        new_session: None,
        previous,
    }
}

/// Each candidate's verdict at `now_ms`, from and into the kept states.
pub fn judge(candidates: &[Candidate], now_ms: u64) -> Vec<ShadowVerdict> {
    let mut kept = lock();
    let verdicts: Vec<ShadowVerdict> = candidates
        .iter()
        .map(|c| {
            let previous = kept.get(&c.name).map(|k| k.state);
            let v = shadow_verdict(&inputs(c, now_ms, previous));
            kept.insert(
                c.name.clone(),
                Kept { state: v.next, verdict: compact(&v), seen_ms: now_ms },
            );
            v
        })
        .collect();
    while kept.len() > MAX_HOSTS {
        let Some(oldest) = kept.iter().min_by_key(|(_, k)| k.seen_ms).map(|(n, _)| n.clone())
        else {
            break;
        };
        kept.remove(&oldest);
    }
    verdicts
}

/// One host's verdict as the log line and `daemon status` carry it.
fn compact(v: &ShadowVerdict) -> Value {
    json!({
        "host": v.host,
        "would_defer": v.would_defer,
        "reason": v.reason,
        "cpu": v.cpu.state,
        "mem": v.mem.state,
        "health_age_s": v.health_age_s,
        "inputs_digest": v.inputs_digest,
    })
}

/// The log line's JSON for one decision at `site` that picked `pick`.
pub fn line(site: &str, pick: Option<&str>, verdicts: &[ShadowVerdict], now_ms: u64) -> Value {
    let picked = pick.and_then(|p| verdicts.iter().find(|v| v.host == p));
    json!({
        "ts": now_ms,
        "site": site,
        "pick": pick,
        "would_defer": picked.map(|v| v.would_defer),
        "reason": picked.map(|v| v.reason),
        "inputs_digest": picked.map(|v| v.inputs_digest.as_str()),
        "formula_version": crate::host_pressure::SHADOW_FORMULA_VERSION,
        "hosts": verdicts.iter().map(compact).collect::<Vec<_>>(),
    })
}

/// Judges `candidates` and logs one line for a decision at `site` (module docs).
/// Returns the line, which a placement adds to its verdict as `shadow`.
pub fn record(site: &str, pick: Option<&str>, candidates: &[Candidate]) -> Value {
    let now = crate::store::now_ms();
    let verdicts = judge(candidates, now);
    let line = line(site, pick, &verdicts, now);
    tracing::info!("{LOG_PREFIX} {line}");
    line
}

/// A placement's verdict with the shadow line added as `shadow`; every other
/// key, the pick included, as `placement::place` made it.
pub fn with_shadow(site: &str, mut verdict: Value, candidates: &[Candidate]) -> Value {
    let pick = verdict.get("pick").and_then(Value::as_str).map(str::to_owned);
    let line = record(site, pick.as_deref(), candidates);
    if let Some(obj) = verdict.as_object_mut() {
        obj.insert("shadow".into(), line);
    }
    verdict
}

/// This machine as a candidate from readings that never wait: the meter's last
/// verdict, load, RAM and swap. Blocking (`/proc` reads): call it on a blocking
/// thread.
pub fn local_candidate() -> Candidate {
    use crate::server::peer_status::{load, pressure_age_ms, ram_total, swap};
    let mut health = json!({
        "cpus": std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1),
    });
    let verdict = crate::host_pressure::Meter::shared().last();
    if let Some(v) = verdict.and_then(|v| serde_json::to_value(v).ok()) {
        health["pressure"] = v;
    }
    if let Some(age) = pressure_age_ms() {
        health["pressureAgeMs"] = json!(age);
    }
    if let Some(l) = load() {
        health["load"] = json!(l);
    }
    if let Some(total) = ram_total() {
        health["ram"] = json!({"totalBytes": total});
    }
    if let Some((used, total)) = swap() {
        health["swap"] = json!({"usedBytes": used, "totalBytes": total});
    }
    Candidate {
        name: crate::hub::host_label().to_owned(),
        local: true,
        health,
        health_at: Some(crate::store::now_ms()),
    }
}

/// Each kept host's last verdict, for `daemon status` (`shadowAdmission`).
pub fn last_verdicts() -> Vec<Value> {
    let kept = lock();
    let mut out: Vec<Value> = kept.values().map(|k| k.verdict.clone()).collect();
    out.sort_by(|a, b| a["host"].as_str().cmp(&b["host"].as_str()));
    out
}

/// `acpmux ls`'s lines for the hosts whose last shadow verdict would defer.
pub fn ls_lines(status: &Value) -> Vec<String> {
    let Some(rows) = status.get("shadowAdmission").and_then(Value::as_array) else {
        return Vec::new();
    };
    rows.iter()
        .filter(|r| r.get("would_defer").and_then(Value::as_bool) == Some(true))
        .filter_map(|r| {
            let host = r.get("host")?.as_str()?;
            let reason = r.get("reason")?.as_str()?;
            Some(format!("{host}: would-defer: {reason} (shadow; nothing is deferred)"))
        })
        .collect()
}

#[cfg(test)]
#[path = "shadow_admission_tests.rs"]
mod tests;
