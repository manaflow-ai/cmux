//! A daemon's host health as it rides the mesh hub (cmux-platform `MeshHostHealth`): each heartbeat
//! carries this daemon's reading (`server/mesh_relay.rs`), and the address book returns every
//! daemon's, so a machine only the hub reaches is weighed for `--host auto` and shown in
//! `machine ls` as a linked peer is (`hub/mesh_book.rs`). Numbers only, plus the budget's short
//! limit names and the daemon's version: no path, no session name, no text a person wrote.

use serde_json::{Map, Value, json};

/// The most bytes a reading takes as JSON; the hub drops a larger one.
pub const MAX_HEALTH_BYTES: usize = 2048;

/// The most limit names `pressure.over` lists.
const MAX_OVER: usize = 8;

/// A reading the hub returned older than this reads as unread: the hub keeps a daemon's row 30 s
/// past its last heartbeat (ttl, heartbeats every 10 s) and this daemon reads the book after each
/// of its own, so a reading past three of those windows means the book itself went unread here.
pub const HUB_HEALTH_STALE_MS: u64 = 90_000;

/// This daemon's `_acpmux/host_health` reply (`server/peer_status.rs`) cut to what a heartbeat
/// carries. `None` when nothing is left or it would pass [`MAX_HEALTH_BYTES`].
pub fn heartbeat_health(reading: &Value) -> Option<Value> {
    let mut out = numbers(reading);
    if let Some(p) = reading.get("pressure").filter(|p| p.is_object()) {
        let mut pressure = Map::new();
        if let Some(ok) = p.get("ok").and_then(Value::as_bool) {
            pressure.insert("ok".into(), json!(ok));
        }
        // The verdict's phrases (`cmux-host-budget` `evaluate`) carry numbers and words; the hub
        // takes a short name for each limit.
        let mut over: Vec<&str> = Vec::new();
        for phrase in p.get("over").and_then(Value::as_array).into_iter().flatten() {
            let name = limit_name(phrase.as_str().unwrap_or_default());
            if !over.contains(&name) && over.len() < MAX_OVER {
                over.push(name);
            }
        }
        if p.get("over").is_some_and(Value::is_array) {
            pressure.insert("over".into(), json!(over));
        }
        if let Some(cores) = p.get("cores").and_then(Value::as_u64) {
            pressure.insert("cores".into(), json!(cores));
        }
        if !pressure.is_empty() {
            out.insert("pressure".into(), Value::Object(pressure));
        }
    }
    if let Some(v) = reading.get("version").and_then(Value::as_str).filter(|v| is_build(v)) {
        out.insert("build".into(), json!(v));
    }
    fits(out)
}

/// A daemon's `health` as the address book returned it, kept to the same field set (a hub that
/// sent more, or other kinds, keeps only these). `None` for null or nothing usable.
pub fn book_health(v: &Value) -> Option<Value> {
    let mut out = numbers(v);
    if let Some(p) = v.get("pressure").filter(|p| p.is_object()) {
        let mut pressure = Map::new();
        if let Some(ok) = p.get("ok").and_then(Value::as_bool) {
            pressure.insert("ok".into(), json!(ok));
        }
        if let Some(over) = p.get("over").and_then(Value::as_array) {
            let names: Vec<&str> = over
                .iter()
                .filter_map(Value::as_str)
                .filter(|n| is_limit_name(n))
                .take(MAX_OVER)
                .collect();
            pressure.insert("over".into(), json!(names));
        }
        if let Some(cores) = p.get("cores").and_then(Value::as_u64) {
            pressure.insert("cores".into(), json!(cores));
        }
        if !pressure.is_empty() {
            out.insert("pressure".into(), Value::Object(pressure));
        }
    }
    if let Some(b) = v.get("build").and_then(Value::as_str).filter(|b| is_build(b)) {
        out.insert("build".into(), json!(b));
    }
    fits(out)
}

/// The numeric fields both directions share: RAM, swap, disk, load, CPUs, live sessions.
fn numbers(v: &Value) -> Map<String, Value> {
    let mut out = Map::new();
    for (key, fields) in [
        ("ram", &["freeBytes", "totalBytes"][..]),
        ("swap", &["usedBytes", "totalBytes"][..]),
        ("disk", &["freeBytes"][..]),
    ] {
        let Some(part) = v.get(key) else { continue };
        let kept: Map<String, Value> = fields
            .iter()
            .filter_map(|f| {
                part.get(*f).and_then(Value::as_u64).map(|n| ((*f).to_owned(), json!(n)))
            })
            .collect();
        if !kept.is_empty() {
            out.insert(key.into(), Value::Object(kept));
        }
    }
    if let Some(load) = v.get("load").and_then(Value::as_array) {
        let load: Vec<f64> = load
            .iter()
            .filter_map(Value::as_f64)
            .filter(|n| n.is_finite() && *n >= 0.0)
            .take(3)
            .collect();
        if !load.is_empty() {
            out.insert("load".into(), json!(load));
        }
    }
    for key in ["cpus", "liveSessions"] {
        if let Some(n) = v.get(key).and_then(Value::as_u64) {
            out.insert(key.into(), json!(n));
        }
    }
    out
}

fn fits(out: Map<String, Value>) -> Option<Value> {
    if out.is_empty() {
        return None;
    }
    let v = Value::Object(out);
    (v.to_string().len() <= MAX_HEALTH_BYTES).then_some(v)
}

/// The short name of one budget phrase: `load1 9.0 >= 8 (8 cores)` is `load`.
fn limit_name(phrase: &str) -> &'static str {
    let p = phrase.trim_start();
    if p.starts_with("load") {
        "load"
    } else if p.starts_with("memory") {
        "memory"
    } else if p.starts_with("available RAM") {
        "ram"
    } else if p.starts_with("swap") {
        "swap"
    } else {
        "other"
    }
}

/// The hub's limit names: `^[a-z0-9_-]{1,32}$`.
fn is_limit_name(n: &str) -> bool {
    (1..=32).contains(&n.len())
        && n.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_' || b == b'-')
}

/// The hub's version strings: `^[A-Za-z0-9._+-]{1,64}$`.
fn is_build(b: &str) -> bool {
    (1..=64).contains(&b.len())
        && b.bytes().all(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'_' | b'+' | b'-'))
}

#[cfg(test)]
#[path = "mesh_health_tests.rs"]
mod tests;
