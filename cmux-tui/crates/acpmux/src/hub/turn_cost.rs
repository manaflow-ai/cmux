//! What a task cost, on its turn's end (RFD 0167 row 16, cmuxterm-hq
//! goals/competitive-cost-per-task.md). Leo, 2026-11-24: "i never only want top x changes. you all
//! need to be working through all useful ones end to end to end."
//!
//! `hub/turn_usage.rs` puts the turn's model and tokens on its `turn_result`, and its cost when the
//! harness reports one. This adds, on the same record, so a client draws it the moment the turn
//! ends with no second read:
//! - `modelCostUsd`: the harness's own cost, else the turn's tokens at the bundled price table
//!   (`crate::pricing`), the ledger's rule (`ledger::Totals::priced`); `modelCostSource` says which
//!   (`harness` or `table`). A model the table lacks leaves both out: unpriced, never 0.
//! - `computeSeconds` and `computeCostUsd`: on a cmux Cloud VM (`cloud_host::is_cloud_vm`), the
//!   turn's wall time at the VM's list rate (Freestyle's per-hour vCPU and memory prices, as the API
//!   prices a sandbox, backend chief-brain-cc/sandbox-size.ts). Nothing on a person's own machine.
//! - `taskCostUsd`: the two added up, and `sessionCostUsd`: the chat's running total of it
//!   (`SessionMeta::task_cost_usd`).
//! - `costReadyUs`: microseconds from the turn's end (its harness's answer reaching
//!   `finish_turn`) to these fields being ready, the goal's measured stage.
//!
//! cmux shows cost; RFD 0071 sets prices. The rates here are list prices, the same ones billing
//! meters at, never a markup. The ledger (`hub/ledger`) adds `computeCostUsd` into its buckets, so a
//! pull request's rollup (`_acpmux/ledger` with `groupBy: ["pr"]`) carries compute beside model
//! spend.

use std::sync::OnceLock;
use std::time::Instant;

use serde_json::{Map, Value, json};

use super::Session;
use crate::store::TurnUsage;

/// Freestyle's list prices (freestyle.sh/docs/vms/pricing-and-limits, as of 2026-10-21): USD per
/// vCPU hour and per GiB of memory per hour while a VM runs. Disk bills whether or not it runs, so
/// a turn adds none.
pub const CPU_USD_PER_HOUR: f64 = 0.04032;
pub const GIB_MEMORY_USD_PER_HOUR: f64 = 0.0129;

/// USD per second for a machine of `cpus` vCPUs and `memory_gib` GiB, at list price.
pub fn compute_usd_per_second(cpus: f64, memory_gib: f64) -> f64 {
    (cpus.max(0.0) * CPU_USD_PER_HOUR + memory_gib.max(0.0) * GIB_MEMORY_USD_PER_HOUR) / 3600.0
}

/// This machine's rate when it is a cmux Cloud VM, read once (its CPUs and `/proc/meminfo`).
fn this_machine_rate() -> Option<f64> {
    static RATE: OnceLock<Option<f64>> = OnceLock::new();
    *RATE.get_or_init(|| {
        if !crate::cloud_host::is_cloud_vm() {
            return None;
        }
        let cpus = std::thread::available_parallelism().map_or(1, |n| n.get()) as f64;
        let memory_gib = std::fs::read_to_string("/proc/meminfo")
            .ok()
            .and_then(|text| memory_kib(&text))
            .map_or(0.0, |kib| kib as f64 / (1024.0 * 1024.0));
        Some(compute_usd_per_second(cpus, memory_gib))
    })
}

/// `MemTotal` in KiB from `/proc/meminfo`'s text.
fn memory_kib(meminfo: &str) -> Option<u64> {
    meminfo
        .lines()
        .find_map(|line| line.strip_prefix("MemTotal:"))
        .and_then(|rest| rest.split_whitespace().next())
        .and_then(|n| n.parse().ok())
}

/// The turn's token counts back from its `turn_result` fields (`turn_usage`'s output).
fn usage_of(fields: &Map<String, Value>) -> TurnUsage {
    let n = |key: &str| fields.get(key).and_then(Value::as_u64);
    TurnUsage {
        cost_usd: fields.get("costUsd").and_then(Value::as_f64),
        input_tokens: n("inputTokens"),
        output_tokens: n("outputTokens"),
        cache_read_tokens: n("cacheReadTokens"),
        cache_write_tokens: n("cacheWriteTokens"),
        cache_write_1h_tokens: n("cacheWrite1hTokens"),
    }
}

/// Rounded to a millionth of a dollar, so a record never carries float noise.
fn usd(x: f64) -> f64 {
    (x * 1e6).round() / 1e6
}

/// The cost fields for a turn whose usage fields are `fields`, that ran `wall_ms`, on a machine
/// billed `rate` USD a second (None off Cloud), with the session's total before it `before`.
/// Returns them and the session's new total (unchanged when the turn has no cost).
pub fn cost_fields(
    fields: &Map<String, Value>,
    wall_ms: u64,
    rate: Option<f64>,
    before: Option<f64>,
) -> (Map<String, Value>, Option<f64>) {
    let usage = usage_of(fields);
    let model = fields.get("model").and_then(Value::as_str);
    let mut out = Map::new();
    let model_cost = match usage.cost_usd.filter(|c| c.is_finite() && *c >= 0.0) {
        Some(cost) => Some((cost, "harness")),
        None => model
            .and_then(|m| crate::pricing::table().cost(m, &usage))
            .filter(|c| c.is_finite() && *c >= 0.0)
            .map(|cost| (cost, "table")),
    };
    if let Some((cost, source)) = model_cost {
        out.insert("modelCostUsd".into(), json!(usd(cost)));
        out.insert("modelCostSource".into(), json!(source));
    }
    let compute = rate.filter(|r| r.is_finite() && *r > 0.0).map(|rate| {
        let seconds = wall_ms as f64 / 1000.0;
        out.insert("computeSeconds".into(), json!((seconds * 1000.0).round() / 1000.0));
        out.insert("computeCostUsd".into(), json!(usd(seconds * rate)));
        seconds * rate
    });
    if model_cost.is_none() && compute.is_none() {
        return (out, before);
    }
    let task = model_cost.map_or(0.0, |(c, _)| c) + compute.unwrap_or(0.0);
    let total = before.unwrap_or(0.0) + task;
    out.insert("taskCostUsd".into(), json!(usd(task)));
    out.insert("sessionCostUsd".into(), json!(usd(total)));
    (out, Some(total))
}

/// `cost_fields` for `session`'s turn that started at `started_at` (Unix ms) and whose harness
/// answered at `ended`: adds them to `msg` and the session's running total, with `costReadyUs`.
pub(super) fn add_turn_cost(
    session: &Session,
    msg: &mut Map<String, Value>,
    started_at: Option<u64>,
    ended: Instant,
) {
    let now_ms = crate::store::now_ms();
    let wall_ms = started_at.map_or(0, |start| now_ms.saturating_sub(start));
    let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
    let (fields, total) = cost_fields(msg, wall_ms, this_machine_rate(), meta.task_cost_usd);
    meta.task_cost_usd = total;
    drop(meta);
    if fields.is_empty() {
        return;
    }
    msg.extend(fields);
    msg.insert("costReadyUs".into(), json!(ended.elapsed().as_micros() as u64));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fields(v: Value) -> Map<String, Value> {
        v.as_object().cloned().unwrap()
    }

    #[test]
    fn a_harness_cost_is_the_model_cost_and_adds_to_the_session() {
        let (out, total) = cost_fields(&fields(json!({"costUsd": 0.25})), 4000, None, Some(1.0));
        assert_eq!(out["modelCostUsd"], json!(0.25));
        assert_eq!(out["modelCostSource"], json!("harness"));
        assert_eq!(out["taskCostUsd"], json!(0.25));
        assert_eq!(out["sessionCostUsd"], json!(1.25));
        assert!(out.get("computeCostUsd").is_none(), "no compute off Cloud");
        assert_eq!(total, Some(1.25));
    }

    #[test]
    fn tokens_with_no_harness_cost_are_priced_at_the_table() {
        let usage =
            json!({"model": "claude-opus-4-5", "inputTokens": 1_000_000, "outputTokens": 0});
        let (out, total) = cost_fields(&fields(usage), 0, None, None);
        assert_eq!(out["modelCostSource"], json!("table"));
        let cost = out["modelCostUsd"].as_f64().unwrap();
        assert!(cost > 0.0, "{out:?}");
        assert_eq!(total, Some(cost));
    }

    #[test]
    fn a_model_the_table_lacks_is_unpriced_not_zero() {
        let usage = json!({"model": "no-such-model-x", "inputTokens": 10});
        let (out, total) = cost_fields(&fields(usage), 1000, None, Some(2.0));
        assert!(out.is_empty(), "{out:?}");
        assert_eq!(total, Some(2.0));
    }

    #[test]
    fn a_cloud_turn_adds_its_compute_at_the_machine_rate() {
        // 4 vCPU and 16 GiB: (4 x 0.04032 + 16 x 0.0129) / 3600 USD a second.
        let rate = compute_usd_per_second(4.0, 16.0);
        let (out, total) = cost_fields(&fields(json!({"costUsd": 0.1})), 60_000, Some(rate), None);
        assert_eq!(out["computeSeconds"], json!(60.0));
        let compute = out["computeCostUsd"].as_f64().unwrap();
        assert!((compute - 60.0 * rate).abs() < 1e-6, "{compute}");
        assert!((out["taskCostUsd"].as_f64().unwrap() - (0.1 + compute)).abs() < 1e-6);
        assert!((total.unwrap() - (0.1 + 60.0 * rate)).abs() < 1e-9);
    }

    #[test]
    fn meminfo_total_is_read_in_kib() {
        assert_eq!(memory_kib("MemTotal:       16384000 kB\nMemFree: 1 kB\n"), Some(16_384_000));
        assert_eq!(memory_kib("MemFree: 1 kB\n"), None);
    }
}
