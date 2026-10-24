//! `acpmux peer status` (`_acpmux/peer_status`): this machine's health and
//! every peer's, each asked live (`_acpmux/host_health`), so an agent learns
//! that a peer is down or full from one call instead of a request that waits
//! out the peer timeout. Part of the request handler (`requests.rs`).
//!
//! A peer that is offline is reported from its link (`downSince`, `lastSeen`,
//! the last error). One that answers `_acpmux/host_health` with an error (a
//! build older than this command) is reachable with no numbers. A peer
//! connection is never asked on to its own peers, so two daemons that list
//! each other cannot ask back and forth.

use super::Origin;
use crate::hub::Hub;
use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::time::{Duration, Instant};

/// How long each peer may take to answer; they are asked at once.
const PEER_BUDGET: Duration = Duration::from_secs(5);

/// The next step an unreachable or unknown peer's row names.
const NEXT: &str = "acpmux host doctor";

/// This machine's own health (`_acpmux/host_health`). A Web or peer caller
/// gets no host name (`hub::host_label`): the caller names its peer.
pub(super) fn host_health(hub: &Hub, origin: Origin) -> Value {
    let mut v = json!({
        "version": crate::hub::VERSION,
        "build": crate::hub::BUILD,
        "cpus": std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1),
        "liveSessions": hub.live_session_count(),
        "uptimeSecs": crate::store::now_ms().saturating_sub(hub.started_at) / 1000,
    });
    if let Some((free, total)) = disk(&crate::config::home()) {
        v["disk"] = json!({"freeBytes": free, "totalBytes": total});
    }
    if let Some(load) = load() {
        v["load"] = json!(load);
    }
    if !origin.web_class() {
        v["host"] = json!(crate::hub::host_label());
    }
    v
}

/// `_acpmux/peer_status`: `{"hosts": [ROW...]}`, this machine first (`self`),
/// then the peers by name; `name` keeps that peer's row only.
pub(super) async fn peer_status(
    hub: &Hub,
    origin: Origin,
    params: &Value,
) -> Result<Value, RpcError> {
    let only = params.get("name").and_then(Value::as_str);
    let listed = hub.peers();
    if let Some(name) = only
        && !listed.iter().any(|p| p["name"] == name)
    {
        return Err(RpcError::invalid_params(format!(
            "no peer named {name:?}: `acpmux host ls` lists the peers"
        )));
    }
    let mut hosts = Vec::new();
    if only.is_none() {
        let mut me = host_health(hub, origin);
        me["name"] = me.get("host").cloned().unwrap_or_else(|| json!("this machine"));
        me["self"] = json!(true);
        me["reachable"] = json!(true);
        hosts.push(me);
    }
    // A peer's connection gets this machine's row only (module docs).
    if origin == Origin::Peer {
        return Ok(json!({"hosts": hosts}));
    }
    let wanted: Vec<Value> =
        listed.into_iter().filter(|p| only.is_none_or(|n| p["name"] == n)).collect();
    let rows = futures::future::join_all(wanted.iter().map(|p| peer_row(hub, p))).await;
    hosts.extend(rows);
    Ok(json!({"hosts": hosts}))
}

async fn peer_row(hub: &Hub, listed: &Value) -> Value {
    let name = listed["name"].as_str().unwrap_or_default().to_owned();
    let mut row = json!({"name": name, "self": false, "reachable": false});
    for key in ["state", "lastSeen", "downSince", "remoteBuild", "outdated", "sessions"] {
        if let Some(v) = listed.get(key).filter(|v| !v.is_null()) {
            row[key] = v.clone();
        }
    }
    let peer = hub.connected_peers().into_iter().find(|p| p.name == name);
    let Some(peer) = peer else {
        let why = listed["error"].as_str().unwrap_or("not connected");
        row["error"] = json!(format!("{why}; `{NEXT} {name}` checks it step by step"));
        return row;
    };
    let started = Instant::now();
    match tokio::time::timeout(PEER_BUDGET, peer.request("_acpmux/host_health", json!({}))).await {
        Ok(Ok(health)) => {
            row["reachable"] = json!(true);
            row["latencyMs"] = json!(started.elapsed().as_millis() as u64);
            if let Some(fields) = health.as_object() {
                for (k, v) in fields {
                    row[k.as_str()] = v.clone();
                }
            }
            row["name"] = json!(name);
            row["self"] = json!(false);
            row["outdated"] = json!(health["build"].as_str() != Some(crate::hub::BUILD));
        }
        // It answered, so it is up: an older build without this method.
        Ok(Err(e)) => {
            row["reachable"] = json!(true);
            row["latencyMs"] = json!(started.elapsed().as_millis() as u64);
            row["healthUnsupported"] = json!(true);
            row["error"] = json!(format!(
                "{}; `acpmux host update {name}` brings it to this build",
                e.message
            ));
        }
        Err(_) => {
            row["error"] = json!(format!(
                "no answer in {} s; `{NEXT} {name}` checks it step by step",
                PEER_BUDGET.as_secs()
            ));
        }
    }
    row
}

/// Free and total bytes of the disk that holds `path`.
#[cfg(unix)]
fn disk(path: &std::path::Path) -> Option<(u64, u64)> {
    use std::os::unix::ffi::OsStrExt;
    let c = std::ffi::CString::new(path.as_os_str().as_bytes()).ok()?;
    let mut s: libc::statvfs = unsafe { std::mem::zeroed() };
    // SAFETY: a NUL-terminated path and a writable statvfs.
    if unsafe { libc::statvfs(c.as_ptr(), &mut s) } != 0 {
        return None;
    }
    let unit = s.f_frsize as u64;
    Some((s.f_bavail as u64 * unit, s.f_blocks as u64 * unit))
}

#[cfg(not(unix))]
fn disk(_: &std::path::Path) -> Option<(u64, u64)> {
    None
}

/// The 1, 5 and 15 minute load averages.
#[cfg(unix)]
fn load() -> Option<[f64; 3]> {
    let mut l = [0f64; 3];
    // SAFETY: a writable array of the three entries asked for.
    (unsafe { libc::getloadavg(l.as_mut_ptr(), 3) } == 3).then_some(l)
}

#[cfg(not(unix))]
fn load() -> Option<[f64; 3]> {
    None
}
