//! This daemon's cell record (RFD 0181 B1): the numbers placement weighs a machine by
//! (`placement.rs` `weigh`: RAM, swap, disk, load, cores, live sessions, the host budget's
//! verdict) carried on each mesh heartbeat (`server/mesh_relay.rs`) as its `health`. The hub keeps
//! the last one on this daemon's address-book row (cmux-platform `MeshHostHealth`, `healthAt`),
//! and every other daemon's book read keeps it as that machine's reading (`hub/hub_health.rs`
//! `published`). A placer then weighs a machine only the hub reaches from its replica of the
//! book, not by asking it: before this, every pick from a lane VM asked each of N machines
//! through the hub and waited on the slowest (about 1.0 s at 40 machines, up to six seconds for
//! one with no reading).
//!
//! [`publishable`] keeps only the keys the hub's schema names, each inside its bounds: a value the
//! hub would refuse is left out, never sent, so a record can never cost the heartbeat that carries
//! it (the heartbeat is what keeps this machine's sessions reachable). Numbers only: no path, no
//! session name, no text a person wrote.

use crate::hub::Hub;
use cmux_json::JsonSet as _;
use serde_json::{Map, Value, json};

/// The largest count the hub takes (`HealthCount`).
const MAX_COUNT: u64 = 1_000_000;
/// The largest byte size the hub takes (`Bytes`, JavaScript's `MAX_SAFE_INTEGER`).
const MAX_BYTES: u64 = (1 << 53) - 1;
/// The most `pressure.over` names the hub takes.
const MAX_OVER: usize = 8;
/// The most bytes a record takes as JSON (cmux-platform `MAX_HOST_HEALTH_BYTES`).
pub(crate) const MAX_RECORD_BYTES: usize = 2048;

/// This machine's record now, as [`publishable`] keeps it, or none when it has no reading.
/// Read each heartbeat (every 30 s at most): local reads only (`/proc`, `statvfs`, the host
/// budget's last verdict), no process run and no file written.
pub(crate) async fn own(hub: &Hub) -> Option<Value> {
    use super::peer_status::{disk, load, ram_total, swap};
    let mut v = json!({
        "build": crate::hub::build(),
        "cpus": std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1),
        "liveSessions": hub.live_session_count(),
    });
    if let Some((free, _)) = crate::config::home().ancestors().find_map(disk) {
        v.set("disk", json!({"freeBytes": free}));
    }
    if let Some(load) = load() {
        v.set("load", json!(load));
    }
    let pressure = hub.host_pressure_status().await;
    if let Some(total) = ram_total() {
        let mut ram = json!({"totalBytes": total});
        if let Some(f) = pressure["available_ram_fraction"].as_f64() {
            ram.set("freeBytes", json!((total as f64 * f.clamp(0.0, 1.0)) as u64));
        }
        v.set("ram", ram);
    }
    if let Some((used, total)) = swap() {
        v.set("swap", json!({"usedBytes": used, "totalBytes": total}));
    }
    v.set("pressure", pressure);
    publishable(&v)
}

/// The keys of `reading` (a `_acpmux/host_health` reading, or [`own`]'s) the hub's
/// `MeshHostHealth` names, each one kept only when the hub would take it. None when none is.
pub(crate) fn publishable(reading: &Value) -> Option<Value> {
    let mut out = Map::new();
    let bytes = |v: Option<&Value>| v.and_then(Value::as_u64).filter(|n| *n <= MAX_BYTES);
    let mut sizes = |key: &str, fields: &[&str]| {
        let part: Map<String, Value> = fields
            .iter()
            .filter_map(|f| {
                Some(((*f).to_owned(), json!(bytes(reading.pointer(&format!("/{key}/{f}")))?)))
            })
            .collect();
        if !part.is_empty() {
            out.insert(key.to_owned(), Value::Object(part));
        }
    };
    sizes("ram", &["freeBytes", "totalBytes"]);
    sizes("swap", &["usedBytes", "totalBytes"]);
    sizes("disk", &["freeBytes"]);
    let load: Option<Vec<f64>> = reading.get("load").and_then(Value::as_array).and_then(|a| {
        a.iter()
            .take(3)
            .map(|n| n.as_f64().filter(|n| n.is_finite() && (0.0..=MAX_COUNT as f64).contains(n)))
            .collect()
    });
    if let Some(load) = load.filter(|l| !l.is_empty()) {
        out.insert("load".into(), json!(load));
    }
    for key in ["cpus", "liveSessions"] {
        if let Some(n) = count(reading.get(key)) {
            out.insert(key.into(), json!(n));
        }
    }
    if let Some(p) = reading.get("pressure").filter(|p| p.is_object()) {
        let mut verdict = Map::new();
        if let Some(ok) = p.get("ok").and_then(Value::as_bool) {
            verdict.insert("ok".into(), json!(ok));
        }
        if let Some(over) = p.get("over").and_then(Value::as_array) {
            let names: Vec<&str> = over
                .iter()
                .filter_map(Value::as_str)
                .filter(|s| is_name(s))
                .take(MAX_OVER)
                .collect();
            verdict.insert("over".into(), json!(names));
        }
        if let Some(n) = count(p.get("cores")) {
            verdict.insert("cores".into(), json!(n));
        }
        if !verdict.is_empty() {
            out.insert("pressure".into(), Value::Object(verdict));
        }
    }
    if let Some(build) = reading.get("build").and_then(Value::as_str).filter(|b| is_build(b)) {
        out.insert("build".into(), json!(build));
    }
    let record = Value::Object(out);
    let fits = record.to_string().len() <= MAX_RECORD_BYTES;
    (record.as_object().is_some_and(|o| !o.is_empty()) && fits).then_some(record)
}

/// A count the hub takes: a whole number from 0 to [`MAX_COUNT`]. A whole-valued float (a
/// meter's `cores: 32.0`) counts; a fraction does not.
fn count(v: Option<&Value>) -> Option<u64> {
    let v = v?;
    let n = v
        .as_u64()
        .or_else(|| v.as_f64().filter(|f| f.fract() == 0.0 && *f >= 0.0).map(|f| f as u64))?;
    (n <= MAX_COUNT).then_some(n)
}

/// `^[a-z0-9_-]{1,32}$`, a `pressure.over` name.
fn is_name(s: &str) -> bool {
    (1..=32).contains(&s.len())
        && s.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_' || b == b'-')
}

/// `^[A-Za-z0-9._+-]{1,64}$`, a daemon version.
fn is_build(s: &str) -> bool {
    (1..=64).contains(&s.len())
        && s.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'+' | b'-'))
}

#[cfg(test)]
#[path = "cell_record_tests.rs"]
mod tests;
