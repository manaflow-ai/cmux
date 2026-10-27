//! `_acpmux/place` (`acpmux host place`): where new work should go, from
//! this machine's health and each connected peer's last reading
//! (`peer_health.rs`), weighed by `placement.rs`. Asks no machine: the peers'
//! numbers are the ones their links already keep. Part of the request
//! handler (`requests.rs`); `new --host auto` and `dispatch --host auto` call
//! `pick` too, and the sub-session tool's host `auto` weighs this machine
//! with the same engine (`subsession_host`).

use super::Origin;
use crate::hub::Hub;
use crate::placement::{Candidate, Work};
use crate::rpc::RpcError;
use serde_json::{Value, json};

/// `{"work": "agent"|"build"}` → `placement::place`'s verdict.
pub(super) async fn place(hub: &Hub, params: &Value) -> Value {
    let work = match params.get("work").and_then(Value::as_str) {
        Some("build") => Work::Build,
        _ => Work::Agent,
    };
    pick(hub, work).await
}

/// This machine as a candidate, with its health read now.
async fn this_machine(hub: &Hub) -> Candidate {
    Candidate {
        name: crate::hub::host_label().to_owned(),
        local: true,
        health: super::peer_status::host_health(hub, Origin::Peer).await,
    }
}

/// This machine and every connected peer, weighed for `work`.
pub(super) async fn pick(hub: &Hub, work: Work) -> Value {
    let mut candidates = vec![this_machine(hub).await];
    candidates.extend(
        hub.peers()
            .into_iter()
            .filter(|p| p.get("connected").and_then(Value::as_bool) == Some(true))
            .filter_map(|p| {
                Some(Candidate {
                    name: p.get("name")?.as_str()?.to_owned(),
                    local: false,
                    health: p.get("health").cloned().unwrap_or(Value::Null),
                })
            }),
    );
    crate::placement::place(&candidates, crate::placement::load_registry().as_ref(), work)
}

/// A sub-session's `host` (`start_session`, `server/subsessions.rs`). A
/// family lives on one daemon, so this machine is the only host a sub-session
/// starts on: `auto` (`auto-build` for a build) weighs it alone with
/// `placement::place`, as `pick` weighs every host, and the start goes ahead
/// only when the engine places the work here. `Ok(None)`: no host, or this
/// machine's own name (an explicit host, unchecked, as `new --host`);
/// `Ok(Some(line))`: placed here, and why (`placement::placed`).
pub(super) async fn subsession_host(
    hub: &Hub,
    host: Option<&str>,
) -> Result<Option<String>, RpcError> {
    let Some(host) = host.filter(|h| !h.trim().is_empty()) else { return Ok(None) };
    let here = crate::hub::host_label();
    let Some(work) = Work::of_host(host) else {
        if crate::placement::canonical(host) == crate::placement::canonical(here) {
            return Ok(None);
        }
        return Err(RpcError::invalid_params(format!(
            "start_session refused: a sub-session starts only on this machine ({here}), not on {host:?}. Pass host \"auto\" to check this machine has room first, or leave host out. To run work on another machine, tell the user: `acpmux new --host auto` places a session on the machine with the most room."
        ))
        .with_data(json!({"reason": "subsessions.host_unsupported", "host": here})));
    };
    let verdict = crate::placement::place(
        &[this_machine(hub).await],
        crate::placement::load_registry().as_ref(),
        work,
    );
    placed_here(&verdict).map(Some)
}

/// The placed line of a verdict on this machine alone, or why it has no room.
fn placed_here(verdict: &Value) -> Result<String, RpcError> {
    if let Some(placed) = crate::placement::placed(verdict) {
        return Ok(placed);
    }
    let me = verdict.pointer("/hosts/0").cloned().unwrap_or(Value::Null);
    let text = |k: &str| me.get(k).and_then(Value::as_str).filter(|s| !s.is_empty());
    let name = text("name").unwrap_or("this machine");
    let refused = text("refused").unwrap_or("no room");
    let why = text("why").map(|w| format!(" ({w})")).unwrap_or_default();
    Err(RpcError::invalid_params(format!(
        "start_session refused: not placed on {name}: {refused}{why}. A sub-session starts only on this machine, so host auto weighs only this one. Do the work in this session, or leave host out to start it here regardless."
    ))
    .with_data(json!({"reason": "subsessions.no_room", "placement": verdict})))
}

/// Why the registry's role for `host` forbids `work` (no lanes entry; no
/// builds), whatever its load: the check an explicit `--host` gets. A host the
/// registry does not list, or no registry, forbids nothing.
pub(super) fn role_refusal(host: &str, work: Work) -> Option<String> {
    let registry = crate::placement::load_registry()?;
    let hosts = crate::placement::lane_hosts(Some(&registry))?;
    crate::placement::registry_lanes(&hosts, host)?;
    let only = [Candidate { name: host.to_owned(), local: false, health: Value::Null }];
    let v = crate::placement::place(&only, Some(&registry), work);
    v.pointer("/hosts/0/refused").and_then(Value::as_str).map(|r| format!("{host}: {r}"))
}

/// What a dispatched brief is: a build when it mentions building or captures
/// (the rule `dispatch` always had), else an agent lane.
pub(super) fn brief_work(brief: &str) -> Work {
    let text = brief.to_ascii_lowercase();
    if text.contains("capture") || text.contains("build") { Work::Build } else { Work::Agent }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn here(health: Value) -> [Candidate; 1] {
        [Candidate { name: "box".into(), local: true, health }]
    }

    fn health(ram_gb: u64, live: u64) -> Value {
        json!({"cpus": 16, "load": [2.0, 2.0, 2.0], "ram": {"freeBytes": ram_gb * 1_000_000_000},
            "disk": {"freeBytes": 500_000_000_000u64}, "liveSessions": live,
            "pressure": {"ok": true, "over": [], "cores": 16}})
    }

    /// The sub-session's `auto` is the engine's verdict on this machine:
    /// placed with `new --host auto`'s words, past its room with a warning, or
    /// refused when its role forbids the work.
    #[test]
    fn a_sub_session_is_placed_here_unless_its_role_forbids_the_work() {
        let reg = json!({"machines": {"box": {"lanes": {"build": false, "reserved_gb": 8,
            "per_lane_gb": 4, "free_gb_floor": 20, "disk_per_lane_gb": 5, "max_lanes": 6}}}});
        let v = crate::placement::place(&here(health(40, 2)), Some(&reg), Work::Agent);
        assert_eq!(
            placed_here(&v).unwrap(),
            "placed on box: 40 GB RAM free, 2.0/16 cores busy, 500 GB disk free, 2/6 lanes, room for 4"
        );
        assert_eq!(Some(placed_here(&v).unwrap()), crate::placement::placed(&v));
        // A build on a host whose role takes none.
        let v = crate::placement::place(&here(health(40, 2)), Some(&reg), Work::Build);
        let e = placed_here(&v).unwrap_err();
        assert!(
            e.message.contains(
                "not placed on box: no builds here (lanes.build is false) (40 GB RAM free"
            ),
            "{}",
            e.message
        );
        assert_eq!(e.data.as_ref().unwrap()["reason"], "subsessions.no_room");
        // Out of RAM ((10 - 8) / 4 is under one lane) or at its lane cap: it
        // starts here all the same, and says so. Load and caps only warn.
        for (ram, live, limit) in [(10, 0, "RAM"), (40, 6, "lanes")] {
            let v = crate::placement::place(&here(health(ram, live)), Some(&reg), Work::Agent);
            let placed = placed_here(&v).unwrap();
            assert!(
                placed.starts_with("placed on box: ")
                    && placed.contains(&format!("no room: {limit} is the limit"))
                    && placed.contains("only warn"),
                "{placed}"
            );
        }
        // Not a lane host.
        let v = crate::placement::place(
            &here(health(40, 0)),
            Some(&json!({"machines": {}})),
            Work::Agent,
        );
        let e = placed_here(&v).unwrap_err();
        assert!(e.message.contains("not a lane host"), "{}", e.message);
    }
}
