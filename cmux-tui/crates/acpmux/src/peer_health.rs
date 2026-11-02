//! Part of `Peer` (`peer.rs`). The peer's resources (`_acpmux/host_health`:
//! RAM, disk, load, budget verdict, live agents, the health loop's
//! problems), kept from the link's own keepalive so `host ls` and placement
//! read them from memory and ask no machine. No timer of its own: the ping tick asks every `HEALTH_EVERY`
//! ticks (60 s at the default 20 s ping), one request at a time with a
//! `HEALTH_BUDGET` deadline, and only while the link is ready; it stops when
//! the connection does. A peer on a build without the method is kept as
//! `{"unsupported": true}` and reads as unknown, never as down.

use super::Peer;
use crate::no_panic::LockExt;
use serde_json::{Value, json};
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;

/// Ask on every this many ping ticks.
pub(super) const HEALTH_EVERY: u64 = 3;
/// How long one ask may take.
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
                Ok(Ok(v)) if v.is_object() => Some(trim(v)),
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
/// already has or nobody reads.
fn trim(v: Value) -> Value {
    let mut out = serde_json::Map::new();
    for key in ["os", "arch", "cpus", "load", "ram", "swap", "disk", "liveSessions", "pressure"] {
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
