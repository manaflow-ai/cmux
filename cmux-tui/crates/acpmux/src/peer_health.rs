//! Part of `Peer` (`peer.rs`). The peer's resources (`_acpmux/host_health`:
//! RAM, disk, load, budget verdict, live agents, the health loop's
//! problems), kept from the link's own keepalive so `host ls` and placement
//! read them from memory and ask no machine. No timer of its own: the ping tick asks once the link is ready and
//! then once every `HEALTH_EVERY` of wall time, whatever the ping cadence (a 2 s ping that asked
//! every third tick sent each peer an ask every 6 s, ten times the design), one request at a time with a
//! `HEALTH_BUDGET` deadline, and only while the link is ready; it stops when
//! the connection does. A peer on a build without the method is kept as
//! `{"unsupported": true}` and reads as unknown, never as down.

use super::Peer;
use crate::no_panic::LockExt;
use serde_json::{Value, json};
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;

/// How often the ping tick asks, measured in time, not ticks, so a faster ping does not ask more.
pub(super) const HEALTH_EVERY: Duration = Duration::from_secs(60);

/// Whether the ping tick at `now` asks: the first ready tick does, then one every `HEALTH_EVERY`.
pub(super) fn health_due(last: Option<tokio::time::Instant>, now: tokio::time::Instant) -> bool {
    last.is_none_or(|at| now.saturating_duration_since(at) >= HEALTH_EVERY)
}
/// How long one ask may take. `refresh_health` is detached from the link loop, and a timeout
/// keeps the previous reading; it never blocks a wake or launch.
// timeout: stale health is preferable to making peer/link work fail on a busy machine.
const HEALTH_BUDGET: Duration = Duration::from_secs(5);

impl Peer {
    /// Ask the peer for its health unless an ask is still out. Spawned, so the
    /// link loop never waits on it; the task ends within `HEALTH_BUDGET`.
    pub(super) fn refresh_health(self: &Arc<Self>) {
        if self.health_asking.swap(true, Ordering::SeqCst) {
            return;
        }
        let me = self.clone();
        tokio::spawn(async move {
            let reply =
                tokio::time::timeout(HEALTH_BUDGET, me.request("_acpmux/host_health", json!({})))
                    .await;
            let kept = match reply {
                Ok(Ok(v)) if v.is_object() => {
                    // A plain ssh machine that is also a paired install gets the cmux link as
                    // its backup path (`peer_overlay.rs`).
                    me.learn_overlay(&v);
                    // Where both ends run the WireGuard transport, a route beside ssh
                    // (`peer_wg_learn.rs`).
                    me.learn_wireguard(&v);
                    Some(trim(v))
                }
                // It answered with an error while still connected: a build
                // without the method (this one never errors).
                Ok(Err(_)) if me.connected.load(Ordering::SeqCst) => {
                    Some(json!({"unsupported": true}))
                }
                // Timed out or the link dropped: keep the last reading and its age.
                _ => None,
            };
            if let Some(v) = kept {
                *me.health.lock_or_recover() = Some((crate::store::now_ms(), v));
            }
            me.health_asking.store(false, Ordering::SeqCst);
        });
    }

    /// The last reading and when it was taken (ms), for `summary`.
    pub(super) fn health_summary(&self) -> (Value, Value) {
        match self.health.lock_or_recover().as_ref() {
            Some((at, v)) => (v.clone(), json!(at)),
            None => (Value::Null, Value::Null),
        }
    }
}

/// The fields a peer row carries; the rest (name, build, uptime) the row
/// already has or nobody reads. A reading through the mesh hub is cut the same way, on the
/// machine that answers it (`server/mesh_read.rs` `host_health`).
pub(crate) fn trim(v: Value) -> Value {
    let mut out = serde_json::Map::new();
    for key in [
        "os",
        "arch",
        "device",
        "deviceSymbol",
        "cpus",
        "load",
        "ram",
        "swap",
        "disk",
        "liveSessions",
        "pressure",
        "pressureAgeMs",
        // Auto chat placement weighs a peer's lid, battery and network (`host_power.rs`).
        "power",
        "network",
        // AutoCloud enrollment: the placer's enrolled tier (`autocloud_enroll.rs`).
        "autoCloud",
    ] {
        if let Some(x) = v.get(key).filter(|x| !x.is_null()) {
            out.insert(key.to_owned(), x.clone());
        }
    }
    // The peer's words reach `host ls` and the app: cleaned and capped like this machine's own.
    if let Some(problems) = v.get("problems").filter(|x| !x.is_null()) {
        out.insert("problems".to_owned(), crate::server::machine_health::sanitize(problems));
    }
    Value::Object(out)
}

/// The most bytes a pushed reading takes as JSON (the hub drops one over 2 KiB, cmux-platform
/// `MAX_HOST_HEALTH_BYTES`).
pub(crate) const WIRE_BYTES: usize = 2048;

/// `v`, a `host_health` reading, cut to what the hub's heartbeat takes (cmux-platform
/// `MeshHostHealth`): numbers and short names only, each field bounded, so a placer reading the
/// address book weighs this machine with no ask. Never more than [`WIRE_BYTES`].
pub(crate) fn wire(v: &Value) -> Value {
    let num = |p: &str| v.pointer(p).filter(|x| x.as_u64().is_some()).cloned();
    let mut out = serde_json::Map::new();
    let mut group = |key: &str, fields: &[(&str, &str)]| {
        let obj: serde_json::Map<String, Value> =
            fields.iter().filter_map(|(name, p)| Some(((*name).to_owned(), num(p)?))).collect();
        if !obj.is_empty() {
            out.insert(key.to_owned(), Value::Object(obj));
        }
    };
    group("ram", &[("freeBytes", "/ram/freeBytes"), ("totalBytes", "/ram/totalBytes")]);
    group("swap", &[("usedBytes", "/swap/usedBytes"), ("totalBytes", "/swap/totalBytes")]);
    group("disk", &[("freeBytes", "/disk/freeBytes")]);
    if let Some(load) = v.get("load").and_then(Value::as_array) {
        let load: Vec<Value> = load
            .iter()
            .filter(|x| x.as_f64().is_some_and(|n| n.is_finite() && (0.0..=1e6).contains(&n)))
            .take(3)
            .cloned()
            .collect();
        if !load.is_empty() {
            out.insert("load".into(), Value::Array(load));
        }
    }
    for key in ["cpus", "liveSessions"] {
        if let Some(n) = v.get(key).filter(|x| x.as_u64().is_some_and(|n| n <= 1_000_000)) {
            out.insert(key.into(), n.clone());
        }
    }
    let mut pressure = serde_json::Map::new();
    if let Some(ok) = v.pointer("/pressure/ok").filter(|x| x.is_boolean()) {
        pressure.insert("ok".into(), ok.clone());
    }
    if let Some(over) = v.pointer("/pressure/over").and_then(Value::as_array) {
        let over: Vec<Value> = over
            .iter()
            .filter(|x| {
                x.as_str().is_some_and(|s| {
                    (1..=32).contains(&s.len())
                        && s.bytes().all(|b| {
                            b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_' || b == b'-'
                        })
                })
            })
            .take(8)
            .cloned()
            .collect();
        pressure.insert("over".into(), Value::Array(over));
    }
    if let Some(cores) =
        v.pointer("/pressure/cores").filter(|x| x.as_u64().is_some_and(|n| n <= 1_000_000))
    {
        pressure.insert("cores".into(), cores.clone());
    }
    if !pressure.is_empty() {
        out.insert("pressure".into(), Value::Object(pressure));
    }
    if let Some(build) = v.get("build").and_then(Value::as_str).filter(|b| {
        (1..=64).contains(&b.len())
            && b.bytes().all(|c| c.is_ascii_alphanumeric() || b"._+-".contains(&c))
    }) {
        out.insert("build".into(), json!(build));
    }
    let out = Value::Object(out);
    if out.to_string().len() > WIRE_BYTES { Value::Object(Default::default()) } else { out }
}

#[cfg(test)]
#[path = "peer_health_tests.rs"]
mod tests;
