use super::*;

fn here(health: Value) -> [Candidate; 1] {
    [Candidate {
        name: "box".into(),
        local: true,
        health,
        health_at: None,
        via_hub: false,
        unreachable: None,
    }]
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
        e.message
            .contains("not placed on box: no builds here (lanes.build is false) (40 GB RAM free"),
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
    let v =
        crate::placement::place(&here(health(40, 0)), Some(&json!({"machines": {}})), Work::Agent);
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
    assert_eq!(down, [("old-gone".to_owned(), "outdated peer build (stale disk copy)".to_owned())]);
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
            row["healthAt"] = json!(crate::store::now_ms());
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

/// A peer whose own remote chain refused a start goes after the hosts that stand as well
/// against their cap and room while the record is fresh, listed with the refusal and its time, and is still the pick when no other
/// host has room; after 30 minutes, or once a start there works, it is weighed as before.
#[test]
fn a_peer_whose_chain_refused_a_start_is_demoted_while_the_refusal_is_fresh() {
    let refusals = crate::start_refusals::StartRefusals::default();
    let at = 1_763_464_980_000; // 2025-11-18T11:23:00Z
    refusals.record("roomy", at, "remote chain refused: the sandbox canary shows no sandbox");
    // roomy has more room than lean: without the record it is the pick.
    let lean = |gb| named("lean", false, health(gb, 0));
    let weigh = |now: u64, lean_gb: u64| {
        let peers = vec![named("roomy", false, health(60, 0)), lean(lean_gb)];
        let demoted = refusing(&peers, &refusals, now);
        crate::placement::place_demoting(&peers, &demoted, None, Work::Agent)
    };
    let v = weigh(at + 5 * 60_000, 20);
    assert_eq!(v["pick"], "lean", "{v:#}");
    let roomy = v["hosts"].as_array().unwrap().iter().find(|h| h["name"] == "roomy").unwrap();
    assert_eq!(roomy["ok"], json!(true), "demoted, never refused: {v:#}");
    let line = roomy["demoted"].as_str().unwrap();
    assert!(
        line.starts_with("its remote chain refused a start at 2025-11-18T11:23:00")
            && line.contains("(5 min ago;")
            && line.ends_with("the sandbox canary shows no sandbox"),
        "{line}"
    );
    // lean with no room: roomy is still picked, and the pick says why.
    let v = weigh(at + 5 * 60_000, 1);
    assert_eq!((&v["pick"], &v["overloaded"]), (&json!("roomy"), &json!(false)), "{v:#}");
    assert!(v["why"].as_str().unwrap().contains("picked although its remote chain"), "{v:#}");
    // Stale after 30 minutes: weighed as before, and the pick.
    assert_eq!(weigh(at + crate::start_refusals::FRESH_MS, 20)["pick"], "roomy");
    // A start that works there clears it at once.
    refusals.record("roomy", at, "remote chain refused: x");
    refusals.note("roomy", &Ok(()), at + 1);
    assert_eq!(weigh(at + 2, 20)["pick"], "roomy");
}

/// The machines that refused this one start (`skip`) are out of its next pick, each listed
/// down with why; the others stay.
#[test]
fn a_machine_that_refused_this_start_is_out_for_the_rest_of_it() {
    let peers =
        vec![named("Roomy.local", false, health(60, 0)), named("lean", false, health(20, 0))];
    let mut down = Vec::new();
    let kept = skipped(peers, Some(&json!(["roomy"])), &mut down);
    assert_eq!(kept.iter().map(|c| c.name.as_str()).collect::<Vec<_>>(), ["lean"]);
    assert_eq!(
        down,
        [("Roomy.local".to_owned(), "its remote chain refused this start".to_owned())]
    );
    let mut none = Vec::new();
    assert_eq!(skipped(kept, None, &mut none).len(), 1);
    assert!(none.is_empty());
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
        unreachable: None,
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
    Candidate {
        name: name.into(),
        local,
        health,
        health_at: None,
        via_hub: false,
        unreachable: None,
    }
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
    let v = dispatch_place(hosts(), &[], Some(&reg), Work::Agent);
    assert_eq!(v["pick"], "lane", "{v:#}");
    assert_eq!(v["overloaded"], true, "{v:#}");
    assert_eq!(v["local"], false);
    let weighed: Vec<&str> =
        v["hosts"].as_array().unwrap().iter().filter_map(|h| h["name"].as_str()).collect();
    assert_eq!(weighed, ["lane"]);

    // A build may go to the last-resort host (its lanes.build "fallback"); a person's
    // machines stay out, and the lane VM takes no builds.
    let v = dispatch_place(hosts(), &[], Some(&reg), Work::Build);
    assert_eq!(v["pick"], "spare", "{v:#}");

    // Nothing left: no pick, and the answer names who was left out and why.
    let v = dispatch_place(
        vec![
            named("mac", true, health(60, 0)),
            named("apps", false, health(60, 0)),
            named("spare", false, health(60, 0)),
        ],
        &[],
        Some(&reg),
        Work::Agent,
    );
    assert!(v["pick"].is_null(), "{v:#}");
    let why = v["why"].as_str().unwrap();
    assert!(why.contains("never starts a new lane on mac, apps, spare"), "{why}");

    // Without a registry nothing is left out.
    let v = dispatch_place(vec![named("mac", true, health(60, 0))], &[], None, Work::Agent);
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
