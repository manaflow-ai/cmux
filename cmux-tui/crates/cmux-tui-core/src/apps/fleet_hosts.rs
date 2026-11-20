//! `fleet.hosts` (the `fleet.hosts` signal source, scope `fleet:read`): the person's machines and
//! how busy each is, for an extension such as a New Tab "fleet load" widget.
//!
//! The daemon asks this machine's acpmux `_acpmux/peer_status` (`server/fleet_hosts_call.rs`),
//! which answers this machine's `host_health` and asks every peer for its own at once, and keeps
//! the shaped rows for [`FRESH`]: every app, mount and page that reads within that window gets the
//! kept rows with no call, and reads that arrive while a call runs wait for it instead of starting
//! another. A failed call is remembered for the same window, so a down acpmux is asked at most
//! once per window however many read it.
//!
//! Idle cost: nothing here runs by itself. There is no thread and no timer; the only call is made
//! by a read, and the runtime reads only while a view watches the source, so with no watcher there
//! is no acpmux call at all.
//!
//! A row says what acpmux said and nothing more: a number acpmux did not give is null, never 0.

use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

/// How long a read (or a failed one) answers every reader without a call: the source's
/// `pollFloorSeconds`, so no reader pace makes acpmux ask the peers more often.
pub(crate) const FRESH: Duration = Duration::from_secs(30);

/// The op and signal name.
pub(crate) const OP: &str = "fleet.hosts";

/// The last answer: the shaped rows, or why the call failed, and when it was read.
struct Kept {
    at: Instant,
    answer: Result<Value, String>,
}

/// One cache for every reader of `fleet.hosts` on this daemon.
#[derive(Default)]
pub(crate) struct FleetHosts {
    kept: Mutex<Option<Kept>>,
    /// Held for the whole call, so concurrent readers make one call: the ones behind it find the
    /// fresh answer when they get the lock.
    calling: Mutex<()>,
}

impl FleetHosts {
    /// The rows, read through `call` (raw `_acpmux/peer_status` result) at most once per
    /// [`FRESH`] at `now`.
    pub(crate) fn get(
        &self,
        now: Instant,
        call: impl FnOnce() -> Result<Value, String>,
    ) -> Result<Value, String> {
        if let Some(answer) = self.fresh(now) {
            return answer;
        }
        let _calling = self.calling.lock().unwrap_or_else(PoisonError::into_inner);
        // The call ahead of this one may have answered while this reader waited.
        if let Some(answer) = self.fresh(now) {
            return answer;
        }
        let answer = call().map(|status| shape(&status));
        *self.kept.lock().unwrap_or_else(PoisonError::into_inner) =
            Some(Kept { at: now, answer: answer.clone() });
        answer
    }

    fn fresh(&self, now: Instant) -> Option<Result<Value, String>> {
        let kept = self.kept.lock().unwrap_or_else(PoisonError::into_inner);
        kept.as_ref()
            .filter(|k| now.saturating_duration_since(k.at) < FRESH)
            .map(|k| k.answer.clone())
    }
}

/// `{"hosts": [ROW...]}` from `_acpmux/peer_status` as the signal's rows, this machine first and
/// then the peers in acpmux's order (by name).
pub(crate) fn shape(status: &Value) -> Value {
    let rows = status
        .get("hosts")
        .and_then(Value::as_array)
        .map(|hosts| hosts.iter().filter_map(row).collect::<Vec<_>>())
        .unwrap_or_default();
    Value::Array(rows)
}

fn row(host: &Value) -> Option<Value> {
    let name = host.get("name").and_then(Value::as_str).filter(|n| !n.is_empty())?;
    let pressure = host.get("pressure").filter(|p| p.is_object());
    let number = |v: Option<&Value>| v.and_then(Value::as_f64).filter(|n| n.is_finite());
    let count = |v: Option<&Value>| v.and_then(Value::as_u64);
    let text = |key: &str| {
        host.get(key).and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_owned)
    };
    // The meter's load1 (the same sample its verdict used), else the kernel's 1-minute average.
    let load1 = number(pressure.and_then(|p| p.get("load1")))
        .or_else(|| number(host.get("load").and_then(|l| l.get(0))));
    let load_limit = number(pressure.and_then(|p| p.get("load_limit"))).filter(|l| *l > 0.0);
    let busy = load1.zip(load_limit).map(|(load, limit)| (load / limit).clamp(0.0, 1.0));
    let ram_free =
        number(pressure.and_then(|p| p.get("available_ram_fraction"))).map(|f| f.clamp(0.0, 1.0));
    // The meter's memory verdict: normal, warn, critical or unknown.
    let memory = pressure
        .and_then(|p| p.get("pressure"))
        .and_then(Value::as_str)
        .filter(|p| matches!(*p, "normal" | "warn" | "critical" | "unknown"));
    let over_budget = pressure.and_then(|p| p.get("ok")).and_then(Value::as_bool).map(|ok| !ok);
    let mut out = Map::new();
    out.insert("name".into(), json!(name));
    out.insert("self".into(), json!(host.get("self").and_then(Value::as_bool).unwrap_or(false)));
    out.insert(
        "reachable".into(),
        json!(host.get("reachable").and_then(Value::as_bool).unwrap_or(false)),
    );
    out.insert("device".into(), json!(text("device")));
    out.insert("deviceSymbol".into(), json!(text("deviceSymbol")));
    out.insert("cpus".into(), json!(count(host.get("cpus"))));
    out.insert("load1".into(), json!(load1));
    out.insert("loadLimit".into(), json!(load_limit));
    out.insert("busy".into(), json!(busy));
    out.insert("pressure".into(), json!(memory));
    out.insert("overBudget".into(), json!(over_budget));
    out.insert("liveSessions".into(), json!(count(host.get("liveSessions"))));
    out.insert("ramFreeFraction".into(), json!(ram_free));
    Some(Value::Object(out))
}

#[cfg(test)]
#[path = "fleet_hosts_tests.rs"]
mod tests;
