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
use cmux_host_budget::place::{
    Asked, Headroom, HereBudget, Inputs, Override, Room, Setting, Work as BudgetWork, decide,
};
use serde_json::{Value, json};

#[path = "place_hub_health.rs"]
mod hub_health;

/// `{"work": "agent"|"build", "offInteractive": bool, "outdatedOk": bool}` →
/// `placement::place`'s verdict. With `offInteractive` (a command-line `new` on a machine a
/// person works at, `cli/place.rs`), the machines the registry marks interactive
/// (`placement::interactive`), this one included, are not candidates. With `outdatedOk` (a
/// `session move`, which reaches the peer's own daemon over ssh), a peer whose only fault is a
/// stale build (`placement::only_outdated`) stays a candidate, its host row marked
/// `outdated: true` with the `refresh` command that updates it.
pub(super) async fn place(hub: &Hub, params: &Value) -> Value {
    let work = match params.get("work").and_then(Value::as_str) {
        Some("build") => Work::Build,
        _ => Work::Agent,
    };
    let off_interactive = params.get("offInteractive").and_then(Value::as_bool) == Some(true);
    let outdated_ok = params.get("outdatedOk").and_then(Value::as_bool) == Some(true);
    // The app's chat chip weighs only this machine and the linked ones (`chat_place.rs`): it
    // asks no machine through the hub.
    if params.get("hubHealth").and_then(Value::as_bool) != Some(false) {
        hub_health::refresh(hub).await;
    }
    let (mut candidates, mut down, outdated) = candidates_with(hub, outdated_ok).await;
    let registry = crate::placement::load_registry();
    if off_interactive {
        candidates = off_interactive_hosts(candidates, registry.as_ref());
        down.retain(|(name, _)| !crate::placement::interactive(registry.as_ref(), name));
    }
    let verdict = crate::placement::place(&candidates, registry.as_ref(), work);
    let verdict = with_outdated(crate::placement::with_down(verdict, &down), &outdated);
    crate::shadow_admission::with_shadow("place", verdict, &candidates)
}

/// `verdict` with each host `outdated` names marked `outdated: true` and its `refresh` command.
fn with_outdated(mut verdict: Value, outdated: &[String]) -> Value {
    for h in verdict.get_mut("hosts").and_then(Value::as_array_mut).into_iter().flatten() {
        let Some(name) = h.get("name").and_then(Value::as_str).map(str::to_owned) else {
            continue;
        };
        if outdated.contains(&name)
            && let Some(o) = h.as_object_mut()
        {
            o.insert("outdated".into(), json!(true));
            o.insert("refresh".into(), json!(crate::placement::refresh_command(&name)));
        }
    }
    verdict
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
        via_hub: false,
    }
}

/// `dispatch --host auto`'s pick (and the host a dispatch on a busy machine suggests): this
/// machine and every connected peer `dispatch_hosts` keeps, weighed for `work`.
pub(super) async fn pick(hub: &Hub, work: Work) -> Value {
    let registry = crate::placement::load_registry();
    hub_health::refresh(hub).await;
    let (candidates, _) = candidates(hub).await;
    // A brief goes to its host's daemon over a direct link (`requests.rs` `dispatch_brief`):
    // a machine only the hub reaches takes none yet.
    let candidates: Vec<Candidate> = candidates.into_iter().filter(|c| !c.via_hub).collect();
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
    let (candidates, down, _) = candidates_with(hub, false).await;
    (candidates, down)
}

/// [`candidates`], and with `outdated_ok` the peers whose only fault is a stale build kept as
/// candidates (`split_peers_with`), named in the third list.
async fn candidates_with(
    hub: &Hub,
    outdated_ok: bool,
) -> (Vec<Candidate>, Vec<(String, String)>, Vec<String>) {
    let (peers, down, outdated) = split_peers_with(hub.peers(), outdated_ok);
    let mut candidates = vec![this_machine(hub).await];
    candidates.extend(peers);
    (candidates, down, outdated)
}

/// Peer rows split into candidates and the names of the others with why
/// (`placement::peer_down`): a peer is one only while its link is up.
#[cfg(test)]
fn split_peers(rows: Vec<Value>) -> (Vec<Candidate>, Vec<(String, String)>) {
    let (peers, down, _) = split_peers_with(rows, false);
    (peers, down)
}

/// [`split_peers`]; with `outdated_ok`, a peer whose only fault is its build
/// (`placement::only_outdated`) is a candidate too, and named in the third list.
fn split_peers_with(
    rows: Vec<Value>,
    outdated_ok: bool,
) -> (Vec<Candidate>, Vec<(String, String)>, Vec<String>) {
    let mut down = Vec::new();
    let mut peers = Vec::new();
    let mut outdated = Vec::new();
    for row in rows {
        if outdated_ok && crate::placement::only_outdated(&row) {
            if let Some(c) = Candidate::peer(&row) {
                outdated.push(c.name.clone());
                peers.push(c);
            }
            continue;
        }
        match crate::placement::peer_down(&row) {
            None => peers.extend(Candidate::peer(&row)),
            Some(why) => {
                if let Some(name) = row.get("name").and_then(Value::as_str) {
                    down.push((name.to_owned(), why));
                }
            }
        }
    }
    (peers, down, outdated)
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
    let only = [Candidate {
        name: host.to_owned(),
        local: false,
        health: Value::Null,
        health_at: None,
        via_hub: false,
    }];
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

/// `_acpmux/place_chat`: where a new chat runs when the person picked Auto in its Where menu,
/// decided by `cmux_host_budget::place::decide` from this host's budget read now.
pub(super) async fn place_chat(params: &Value) -> Value {
    let here = crate::host_pressure::Meter::shared().current().await.map(|verdict| {
        let reading = crate::host_pressure::Reading::from(&verdict);
        let level = crate::host_pressure::level_for(&reading, crate::host_pressure::Level::Normal);
        HereBudget { level, over: verdict.over }
    });
    with_fork(place_chat_decision(params, here), params, crate::fork_place::enabled())
}

/// `reply` with fork placement's `fork` (`fork_place.rs`) when `cloud.autoCloud` is on: a chat
/// started from a chat on a forkable Cloud machine (`parent`) goes to a fork of that machine
/// under `key`; otherwise `fork` says why it keeps `placement` (the warm path). Off, the reply is
/// as it was.
pub(super) fn with_fork(mut reply: Value, params: &Value, enabled: bool) -> Value {
    let parent = crate::fork_place::parent_of(params);
    let key = params.get("key").and_then(Value::as_str).unwrap_or_default();
    if let (Some(place), Some(obj)) =
        (crate::fork_place::decide(enabled, parent.as_ref(), key), reply.as_object_mut())
    {
        obj.insert("fork".into(), crate::fork_place::to_json(&place));
    }
    reply
}

/// `{"where": "auto"|"here"|PLACE, "targets": [{"place", "headroom"}]}` and this host's budget
/// (`None`: not read) -> the serialized `Decision`, its reason's words as `why`, and the number
/// of `targets`. Picking Auto for this chat is the opt-in, so Auto is on for this call only.
/// No targets (no Cloud machine, or not signed in) keeps the chat here and says why.
pub(super) fn place_chat_decision(params: &Value, here: Option<HereBudget>) -> Value {
    let force = match params.get("where").and_then(Value::as_str) {
        None | Some("auto") => Override::None,
        Some("here") => Override::Here,
        Some(other) => Override::To(other.to_owned()),
    };
    let rooms: Vec<Room> = params
        .get("targets")
        .and_then(Value::as_array)
        .map(|targets| targets.iter().filter_map(chat_target).collect())
        .unwrap_or_default();
    let count = params.get("targets").and_then(Value::as_array).map_or(0, Vec::len);
    let setting = Setting { auto: true, ..Setting::default() };
    let inputs =
        Inputs { work: BudgetWork::Session, asked: Asked::Auto, here, setting: &setting, force };
    let decision = decide(&inputs, || rooms);
    let mut v = serde_json::to_value(&decision).unwrap_or_else(|_| json!({}));
    if let Some(obj) = v.as_object_mut() {
        obj.insert("why".into(), json!(decision.reason.to_string()));
        obj.insert("targets".into(), json!(count));
    }
    v
}

/// One `targets` entry as a place and its room: "room", "stale", `{"full": [phrases]}`, and
/// anything else unknown (never room). An entry without a `place` name is skipped.
fn chat_target(target: &Value) -> Option<Room> {
    let place = target.get("place").and_then(Value::as_str)?.to_owned();
    let headroom = match target.get("headroom") {
        Some(Value::String(s)) if s == "room" => Headroom::Room,
        Some(Value::String(s)) if s == "stale" => Headroom::Stale,
        Some(Value::Object(o)) if o.contains_key("full") => Headroom::Full(
            o.get("full")
                .and_then(Value::as_array)
                .map(|a| a.iter().filter_map(Value::as_str).map(str::to_owned).collect())
                .unwrap_or_default(),
        ),
        _ => Headroom::Unknown,
    };
    Some(Room { place, headroom })
}

#[cfg(test)]
#[path = "place_chat_tests.rs"]
mod place_chat_tests;

#[cfg(test)]
mod tests {
    use super::*;

    fn here(health: Value) -> [Candidate; 1] {
        [Candidate { name: "box".into(), local: true, health, health_at: None, via_hub: false }]
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

    /// Only a peer whose link is up is weighed; the others come back named, with why.
    #[test]
    fn only_peers_whose_link_is_up_are_candidates() {
        let rows = vec![
            json!({"name": "up", "connected": true, "state": "connected", "health": health(40, 0)}),
            json!({"name": "stale", "connected": true, "state": "reconnecting"}),
            json!({"name": "gone", "connected": false, "state": "offline"}),
            json!({"name": "old-disk", "connected": true, "state": "connected", "outdated": true}),
        ];
        let (peers, down) = split_peers(rows);
        assert_eq!(peers.iter().map(|c| c.name.as_str()).collect::<Vec<_>>(), ["up"]);
        assert_eq!(
            down,
            [
                ("stale".to_owned(), "not connected (reconnecting)".to_owned()),
                ("gone".to_owned(), "not connected (offline)".to_owned()),
                ("old-disk".to_owned(), "outdated peer build (stale disk copy)".to_owned()),
            ]
        );
    }

    /// Item A: a move (`outdatedOk`) keeps a peer whose only fault is a stale build as a
    /// candidate, marked with the one command that refreshes it; a peer whose link is down, or
    /// that is outdated and down, still is none.
    #[test]
    fn a_move_ranks_a_peer_whose_only_fault_is_its_build_with_its_refresh_command() {
        let rows = vec![
            json!({"name": "up", "connected": true, "state": "connected", "health": health(40, 0)}),
            json!({"name": "old-disk", "connected": true, "state": "connected", "outdated": true,
                   "health": health(40, 0)}),
            json!({"name": "old-gone", "connected": false, "state": "offline", "outdated": true}),
        ];
        let (peers, down, outdated) = split_peers_with(rows.clone(), true);
        assert_eq!(peers.iter().map(|c| c.name.as_str()).collect::<Vec<_>>(), ["up", "old-disk"]);
        assert_eq!(outdated, ["old-disk"]);
        assert_eq!(
            down,
            [("old-gone".to_owned(), "outdated peer build (stale disk copy)".to_owned())]
        );
        // Every other caller is unchanged: an outdated peer takes no placed work.
        let (peers, _, outdated) = split_peers_with(rows, false);
        assert_eq!(peers.iter().map(|c| c.name.as_str()).collect::<Vec<_>>(), ["up"]);
        assert!(outdated.is_empty());

        let verdict = with_outdated(
            json!({"hosts": [{"name": "up"}, {"name": "old-disk"}]}),
            &["old-disk".to_owned()],
        );
        assert_eq!(verdict["hosts"][0].get("outdated"), None);
        assert_eq!(verdict["hosts"][1]["outdated"], json!(true));
        assert_eq!(verdict["hosts"][1]["refresh"], json!("acpmux machine update old-disk"));
    }

    /// gcp-codex-swarm-07, 2026-11-20: a lane VM at its lane cap whose only other machine is one
    /// the mesh hub lists; and a lane VM, 2026-11-24, where every fleet host was one.
    /// A hub machine is a candidate: with a reading through the hub it is weighed as a linked
    /// peer is, and its start goes through the hub's start relay (`requests.rs` `hub_start`).
    #[test]
    fn a_machine_only_the_hub_reaches_is_weighed_by_its_hub_reading() {
        let reg = json!({"machines": {
            "box": {"lanes": {"max_lanes": 6}},
            "swarm-01": {"lanes": {"max_lanes": 6}},
            "swarm-02": {"lanes": {"max_lanes": 6}}}});
        let row = |name: &str, live: Option<u64>| {
            let mut row = json!({"name": name, "connected": true, "state": "connected",
                "via": "hub", "lastSeen": 1, "sessions": 0});
            if let Some(live) = live {
                row["health"] = health(40, live);
                row["healthAt"] = json!(1);
            }
            row
        };
        let (peers, down) = split_peers(vec![row("swarm-01", Some(6)), row("swarm-02", Some(1))]);
        assert!(down.is_empty(), "{down:?}");
        assert!(peers.iter().all(|p| p.via_hub), "{peers:?}");

        let mut all = here(health(40, 6)).to_vec();
        all.extend(peers);
        let verdict = crate::placement::place(&all, Some(&reg), Work::Agent);
        assert_eq!(verdict["pick"], json!("swarm-02"), "the one with room: {verdict:#}");

        // With no reading yet it reads as unknown, and says what it waits for.
        let (peers, _) = split_peers(vec![row("swarm-01", None)]);
        let mut all = here(health(40, 2)).to_vec();
        all.extend(peers);
        let verdict = crate::placement::place(&all, Some(&reg), Work::Agent);
        assert_eq!(verdict["pick"], json!("box"), "a host with a reading first: {verdict:#}");
        let listed = verdict["hosts"].as_array().unwrap();
        let hub = listed.iter().find(|h| h["name"] == "swarm-01").expect("listed");
        assert!(hub["why"].as_str().unwrap().contains("health read through the hub"), "{hub}");

        // A move over ssh still needs a link.
        let why = crate::placement::link_down(&row("swarm-01", Some(1))).expect("no link");
        assert!(why.contains("`acpmux machine add swarm-01`"), "{why}");
    }

    /// A command-line `new` on a machine a person works at weighs only the others: this one and
    /// every interactive peer drop out, the fleet hosts stay.
    #[test]
    fn off_interactive_drops_the_machines_people_work_at() {
        let reg = json!({"machines": {
            "mac": {"roles": ["leo-mac"], "lanes": {"max_lanes": 4}},
            "air": {"aliases": ["laptop"], "roles": ["attended"], "lanes": {"max_lanes": 3}},
            "desk": {"interactive": true, "lanes": {}},
            "lane": {"roles": ["session-host"], "lanes": {"max_lanes": 12}}}});
        let c = |name: &str, local: bool| Candidate {
            name: name.into(),
            local,
            health: Value::Null,
            health_at: None,
            via_hub: false,
        };
        let kept = off_interactive_hosts(
            vec![c("mac", true), c("laptop", false), c("desk", false), c("lane", false)],
            Some(&reg),
        );
        assert_eq!(kept.iter().map(|c| c.name.as_str()).collect::<Vec<_>>(), ["lane"]);
        let v = crate::placement::place(&kept, Some(&reg), Work::Agent);
        assert_eq!(v["pick"], "lane");
        assert_eq!(v["local"], false);
    }

    /// A registry shaped like fleet-registry.json for `dispatch` (the names are made up): two of
    /// a person's Macs, a machine running their own apps, a last-resort build host and a lane VM.
    fn dispatch_registry() -> Value {
        let lanes = |build: Value| {
            json!({"build": build, "reserved_gb": 8, "per_lane_gb": 4, "free_gb_floor": 20,
                "disk_per_lane_gb": 5, "max_lanes": 6})
        };
        let mut spare = lanes(json!("fallback"));
        spare["last_resort"] = json!(true);
        json!({"machines": {
            "mac": {"roles": ["mac-build", "leo-mac"], "lanes": lanes(json!(false))},
            "air": {"aliases": ["laptop"], "roles": ["attended", "leo-mac"],
                "lanes": lanes(json!(false))},
            "apps": {"roles": ["leo-apps"], "lanes": lanes(json!(false))},
            "spare": {"roles": ["mac-build"], "lanes": spare},
            "lane": {"roles": ["session-host"], "lanes": lanes(json!(false))}}})
    }

    fn named(name: &str, local: bool, health: Value) -> Candidate {
        Candidate { name: name.into(), local, health, health_at: None, via_hub: false }
    }

    /// design/agent-dispatch.md: `dispatch --host auto` never starts a new lane on a person's
    /// machine (interactive, leo-mac, attended, leo-apps), this one included, nor an agent lane on
    /// a last-resort host. They stay out even when the one host left has no room: it takes the
    /// work over its caps (load and caps only warn), never a person's machine with room.
    #[test]
    fn dispatch_auto_leaves_out_a_persons_machines_and_a_last_resort_host() {
        let reg = dispatch_registry();
        let hosts = || {
            vec![
                named("mac", true, health(60, 0)),
                named("laptop", false, health(60, 0)),
                named("apps", false, health(60, 0)),
                named("spare", false, health(60, 0)),
                named("lane", false, health(60, 6)),
            ]
        };
        let v = dispatch_place(hosts(), Some(&reg), Work::Agent);
        assert_eq!(v["pick"], "lane", "{v:#}");
        assert_eq!(v["overloaded"], true, "{v:#}");
        assert_eq!(v["local"], false);
        let weighed: Vec<&str> =
            v["hosts"].as_array().unwrap().iter().filter_map(|h| h["name"].as_str()).collect();
        assert_eq!(weighed, ["lane"]);

        // A build may go to the last-resort host (its lanes.build "fallback"); a person's
        // machines stay out, and the lane VM takes no builds.
        let v = dispatch_place(hosts(), Some(&reg), Work::Build);
        assert_eq!(v["pick"], "spare", "{v:#}");

        // Nothing left: no pick, and the answer names who was left out and why.
        let v = dispatch_place(
            vec![
                named("mac", true, health(60, 0)),
                named("apps", false, health(60, 0)),
                named("spare", false, health(60, 0)),
            ],
            Some(&reg),
            Work::Agent,
        );
        assert!(v["pick"].is_null(), "{v:#}");
        let why = v["why"].as_str().unwrap();
        assert!(why.contains("never starts a new lane on mac, apps, spare"), "{why}");

        // Without a registry nothing is left out.
        let v = dispatch_place(vec![named("mac", true, health(60, 0))], None, Work::Agent);
        assert_eq!(v["pick"], "mac", "{v:#}");
    }

    /// An explicit `dispatch --host`: a last-resort host takes a capture or build, never an agent
    /// lane; a person's machine may be named for an agent lane, but takes no build.
    #[test]
    fn a_named_last_resort_host_takes_only_captures_and_builds() {
        let reg = dispatch_registry();
        let refusal = named_refusal(&reg, "spare", Work::Agent).unwrap();
        assert!(refusal.starts_with("spare: a last-resort host (lanes.last_resort)"), "{refusal}");
        assert_eq!(named_refusal(&reg, "spare", Work::Build), None);
        assert_eq!(named_refusal(&reg, "laptop", Work::Agent), None);
        assert_eq!(named_refusal(&reg, "apps", Work::Agent), None);
        assert_eq!(named_refusal(&reg, "lane", Work::Agent), None);
        let refusal = named_refusal(&reg, "air", Work::Build).unwrap();
        assert!(refusal.contains("no builds here"), "{refusal}");
        assert_eq!(named_refusal(&reg, "unlisted", Work::Agent), None);
        // The same rule where the lane would start (`here_refusal`): a peer's or a local
        // dispatch on the last-resort host itself.
        let here = last_resort_refusal(Some(&reg), "spare", Work::Agent).unwrap();
        assert!(here.starts_with("spare: a last-resort host"), "{here}");
        assert_eq!(last_resort_refusal(Some(&reg), "spare", Work::Build), None);
        assert_eq!(last_resort_refusal(Some(&reg), "lane", Work::Agent), None);
        assert_eq!(last_resort_refusal(None, "spare", Work::Agent), None);
    }
}
