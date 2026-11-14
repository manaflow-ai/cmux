//! `_acpmux/place` (`acpmux host place`): where new work should go, from
//! this machine's health and each connected peer's last reading
//! (`peer_health.rs`), weighed by `placement.rs`. Asks no machine: the peers'
//! numbers are the ones their links already keep. Part of the request
//! handler (`requests.rs`); `dispatch --host auto` calls `pick`, which leaves
//! out the hosts design/agent-dispatch.md keeps new lanes off
//! (`dispatch_hosts`), and the sub-session tool's host `auto` weighs this
//! machine with the same engine (`subsession_host`).

use super::Origin;
use crate::hub::Hub;
use crate::placement::{Candidate, Work};
use crate::rpc::RpcError;
use serde_json::{Value, json};

/// `{"work": "agent"|"build", "offInteractive": bool}` → `placement::place`'s verdict. With
/// `offInteractive` (a command-line `new` on a machine a person works at, `cli/place.rs`), the
/// machines the registry marks interactive (`placement::interactive`), this one included, are
/// not candidates.
pub(super) async fn place(hub: &Hub, params: &Value) -> Value {
    let work = match params.get("work").and_then(Value::as_str) {
        Some("build") => Work::Build,
        _ => Work::Agent,
    };
    let off_interactive = params.get("offInteractive").and_then(Value::as_bool) == Some(true);
    let (mut candidates, mut down) = candidates(hub).await;
    let registry = crate::placement::load_registry();
    if off_interactive {
        candidates = off_interactive_hosts(candidates, registry.as_ref());
        down.retain(|(name, _)| !crate::placement::interactive(registry.as_ref(), name));
    }
    let verdict = crate::placement::place(&candidates, registry.as_ref(), work);
    let verdict = crate::placement::with_down(verdict, &down);
    crate::shadow_admission::with_shadow("place", verdict, &candidates)
}

/// `candidates` without the machines the registry marks interactive.
fn off_interactive_hosts(candidates: Vec<Candidate>, registry: Option<&Value>) -> Vec<Candidate> {
    leave_out(candidates, |name| crate::placement::interactive(registry, name)).0
}

/// `candidates` without the ones `out` names, and the names of those left out.
fn leave_out(
    candidates: Vec<Candidate>,
    out: impl Fn(&str) -> bool,
) -> (Vec<Candidate>, Vec<String>) {
    let (left_out, kept): (Vec<Candidate>, Vec<Candidate>) =
        candidates.into_iter().partition(|c| out(&c.name));
    (kept, left_out.into_iter().map(|c| c.name).collect())
}

/// This machine as a candidate, with its health read now.
async fn this_machine(hub: &Hub) -> Candidate {
    Candidate {
        name: crate::hub::host_label().to_owned(),
        local: true,
        health: super::peer_status::host_health(hub, Origin::Peer).await,
        health_at: Some(crate::store::now_ms()),
    }
}

/// `dispatch --host auto`'s pick (and the host a dispatch on a busy machine suggests): this
/// machine and every connected peer `dispatch_hosts` keeps, weighed for `work`.
pub(super) async fn pick(hub: &Hub, work: Work) -> Value {
    let registry = crate::placement::load_registry();
    let (candidates, _) = candidates(hub).await;
    // The shadow judges only the hosts the pick weighs, not the ones `dispatch_hosts` leaves out.
    let (weighed, _) = dispatch_hosts(candidates.clone(), registry.as_ref(), work);
    let verdict = dispatch_place(candidates, registry.as_ref(), work);
    crate::shadow_admission::with_shadow("pick", verdict, &weighed)
}

/// `placement::place` over the hosts `dispatch_hosts` keeps. With no pick, `why` also names
/// the hosts it left out and why, which the verdict's `hosts` no longer lists.
fn dispatch_place(candidates: Vec<Candidate>, registry: Option<&Value>, work: Work) -> Value {
    let (kept, left_out) = dispatch_hosts(candidates, registry, work);
    let mut v = crate::placement::place(&kept, registry, work);
    if v.get("pick").is_some_and(Value::is_null) && !left_out.is_empty() {
        let why = v.get("why").and_then(Value::as_str).unwrap_or_default();
        let why = format!(
            "{why}. `dispatch --machine auto` never starts a new lane on {}: a machine a person \
works at or that runs a person's own apps (fleet-registry.json interactive, leo-mac, attended \
or leo-apps), and for an agent lane a last-resort host (lanes.last_resort), which takes \
captures and builds only (design/agent-dispatch.md)",
            left_out.join(", ")
        );
        if let Some(o) = v.as_object_mut() {
            o.insert("why".into(), json!(why));
        }
    }
    v
}

/// The hosts `dispatch --host auto` may start a new lane on, and the names of those it may not
/// (design/agent-dispatch.md, "Placement and host policy"): the `off_interactive_hosts` filter,
/// widened to every machine that is a person's own (`placement::personal`: the interactive ones,
/// this one included, and the registry's `leo-apps` ones), and for an agent lane also without a
/// last-resort host (`placement::last_resort`).
fn dispatch_hosts(
    candidates: Vec<Candidate>,
    registry: Option<&Value>,
    work: Work,
) -> (Vec<Candidate>, Vec<String>) {
    leave_out(candidates, |name| {
        crate::placement::personal(registry, name)
            || (work == Work::Agent && crate::placement::last_resort(registry, name))
    })
}

/// This machine and every connected peer, with their last readings, and every other peer with
/// why it is none (`split_peers`).
async fn candidates(hub: &Hub) -> (Vec<Candidate>, Vec<(String, String)>) {
    let (peers, down) = split_peers(hub.peers());
    let mut candidates = vec![this_machine(hub).await];
    candidates.extend(peers);
    (candidates, down)
}

/// Peer rows split into candidates and the names of the others with why
/// (`placement::peer_down`): a peer is one only while its link is up.
fn split_peers(rows: Vec<Value>) -> (Vec<Candidate>, Vec<(String, String)>) {
    let mut down = Vec::new();
    let mut peers = Vec::new();
    for row in rows {
        match crate::placement::peer_down(&row) {
            None => peers.extend(Candidate::peer(&row)),
            Some(why) => {
                if let Some(name) = row.get("name").and_then(Value::as_str) {
                    down.push((name.to_owned(), why));
                }
            }
        }
    }
    (peers, down)
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
            "start_session refused: a sub-session starts only on this machine ({here}), not on {host:?}. Pass host \"auto\" to check this machine has room first, or leave host out. To run work on another machine, tell the user: `acpmux new --machine auto` places a session on the machine with the most room."
        ))
        .with_data(json!({"reason": "subsessions.host_unsupported", "host": here})));
    };
    let here = [this_machine(hub).await];
    let verdict = crate::placement::place(&here, crate::placement::load_registry().as_ref(), work);
    let verdict = crate::shadow_admission::with_shadow("subsession", verdict, &here);
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
/// builds; an agent lane on a last-resort host), whatever its load: the check an
/// explicit `dispatch --host` gets. A host the registry does not list, or no
/// registry, forbids nothing.
pub(super) fn role_refusal(host: &str, work: Work) -> Option<String> {
    named_refusal(&crate::placement::load_registry()?, host, work)
}

/// `role_refusal` against `registry`.
fn named_refusal(registry: &Value, host: &str, work: Work) -> Option<String> {
    let hosts = crate::placement::lane_hosts(Some(registry))?;
    crate::placement::registry_lanes(&hosts, host)?;
    let only =
        [Candidate { name: host.to_owned(), local: false, health: Value::Null, health_at: None }];
    let v = crate::placement::place(&only, Some(registry), work);
    if let Some(r) = v.pointer("/hosts/0/refused").and_then(Value::as_str) {
        return Some(format!("{host}: {r}"));
    }
    last_resort_refusal(Some(registry), host, work)
}

/// Why a dispatch that runs on this machine (`--host local`, a peer's dispatch, a forwarded
/// one, or `auto` placed here) may not: an agent lane on a last-resort host
/// (`last_resort_refusal`), checked where the lane would start, whatever the sender checked.
pub(super) fn here_refusal(work: Work) -> Option<String> {
    let registry = crate::placement::load_registry();
    last_resort_refusal(registry.as_ref(), crate::hub::host_label(), work)
}

/// design/agent-dispatch.md: an explicit target of the last-resort host "is rejected unless its
/// work kind is `capture` or `build`": an agent lane on a `lanes.last_resort` host.
fn last_resort_refusal(registry: Option<&Value>, host: &str, work: Work) -> Option<String> {
    (work == Work::Agent && crate::placement::last_resort(registry, host)).then(|| {
        format!(
            "{host}: a last-resort host (lanes.last_resort) takes a dispatched capture or build, never an agent lane"
        )
    })
}

/// What a dispatched brief is: a build when it mentions building or captures
/// (the rule `dispatch` always had), else an agent lane.
pub(super) fn brief_work(brief: &str) -> Work {
    let text = brief.to_ascii_lowercase();
    if text.contains("capture") || text.contains("build") { Work::Build } else { Work::Agent }
}

#[cfg(test)]
mod tests;
