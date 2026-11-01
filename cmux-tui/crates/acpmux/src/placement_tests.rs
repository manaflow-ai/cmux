use super::*;

/// A registry shaped like fleet-registry.json; the names are made up.
fn registry() -> Value {
    json!({"machines": {
        "big": {"aliases": ["big-box"], "lanes": {"rank": 1, "build": true, "free_gb_floor": 20,
            "reserved_gb": 8, "per_lane_gb": 4, "disk_per_lane_gb": 5, "max_lanes": 12}},
        "small": {"lanes": {"rank": 1, "build": true, "free_gb_floor": 20, "reserved_gb": 4,
            "per_lane_gb": 3, "disk_per_lane_gb": 5, "max_lanes": 12}},
        "light": {"lanes": {"rank": 2, "build": "fallback", "free_gb_floor": 20,
            "reserved_gb": 6, "per_lane_gb": 3, "disk_per_lane_gb": 15, "max_lanes": 3}},
        "laptop": {"lanes": {"rank": 4, "build": false, "free_gb_floor": 20, "reserved_gb": 12,
            "per_lane_gb": 2, "disk_per_lane_gb": 3, "max_lanes": 3}},
        "desk": {"lanes": {"rank": 5, "build": false, "free_gb_floor": 20, "reserved_gb": 16,
            "per_lane_gb": 3, "disk_per_lane_gb": 5, "max_lanes": 4, "max_swap_used_fraction": 0.5}},
        "ci-mini": {"roles": ["ci-runner"]}
    }})
}

/// A health reading: GB of RAM free, cores, 1-minute load, GB of disk free, live agents.
fn health(ram_gb: f64, cores: u64, load: f64, disk_gb: f64, live: u64) -> Value {
    json!({
        "cpus": cores, "load": [load, load, load],
        "ram": {"freeBytes": (ram_gb * GB) as u64, "totalBytes": (ram_gb * 4.0 * GB) as u64},
        "swap": {"usedBytes": 0, "totalBytes": (8.0 * GB) as u64},
        "disk": {"freeBytes": (disk_gb * GB) as u64}, "liveSessions": live,
        "pressure": {"ok": true, "over": [], "cores": cores}
    })
}

fn c(name: &str, health: Value) -> Candidate {
    Candidate { name: name.into(), local: false, health }
}

fn host<'a>(v: &'a Value, name: &str) -> &'a Value {
    v["hosts"].as_array().unwrap().iter().find(|h| h["name"] == name).unwrap()
}

#[test]
fn a_big_busy_machine_beats_a_small_idle_one() {
    // big: 60 GB free, 32 cores with 12 busy, 9 agents running. small: idle, but 16 GB and 8
    // cores. Room is counted from each machine's own size, never from its session count.
    let mut reg = registry();
    reg["machines"]["big"]["lanes"]["max_lanes"] = json!(40);
    let v = place(
        &[c("small", health(16.0, 8, 0.2, 200.0, 0)), c("big", health(60.0, 32, 12.0, 400.0, 9))],
        Some(&reg),
        Work::Agent,
    );
    // big: RAM (60 - 8) / 4 = 13, CPU 20, disk 76, lanes 31 → 13. small: RAM 4.
    assert_eq!(v["pick"], "big", "{v:#}");
    assert_eq!(host(&v, "big")["room"], 13.0, "{v:#}");
    assert_eq!(host(&v, "big")["live"], 9, "{v:#}");
    let why = v["why"].as_str().unwrap();
    assert!(why.starts_with("big: 60 GB RAM free, 12.0/32 cores busy, 400 GB disk free"), "{why}");
    assert!(why.ends_with("room for 13"), "{why}");
}

#[test]
fn builds_go_to_build_hosts_and_a_fallback_host_only_when_none_has_room() {
    let roomy = || health(40.0, 16, 1.0, 300.0, 0);
    let cands = [c("laptop", roomy()), c("desk", roomy()), c("light", roomy()), c("big", roomy())];
    let v = place(&cands, Some(&registry()), Work::Build);
    assert_eq!(v["pick"], "big", "{v:#}");
    assert_eq!(v["work"], "build");
    assert!(host(&v, "laptop")["refused"].as_str().unwrap().contains("no builds here"), "{v:#}");
    assert!(host(&v, "light")["refused"].as_str().unwrap().contains("only when no build"), "{v:#}");

    // The build host is full: the fallback host takes it; the no-build hosts never do.
    let full = health(9.0, 16, 1.0, 300.0, 0);
    let cands = [c("laptop", roomy()), c("light", roomy()), c("big", full)];
    let v = place(&cands, Some(&registry()), Work::Build);
    assert_eq!(v["pick"], "light", "{v:#}");

    // An agent lane may go to a no-build host.
    let v = place(&[c("laptop", roomy())], Some(&registry()), Work::Agent);
    assert_eq!(v["pick"], "laptop", "{v:#}");
}

#[test]
fn a_full_swap_or_an_over_budget_verdict_passes_a_host_over_but_never_refuses_the_work() {
    let mut swapped = health(30.0, 15, 1.0, 300.0, 0);
    swapped["swap"] = json!({"usedBytes": (29.0 * GB) as u64, "totalBytes": (30.0 * GB) as u64});
    let mut over = health(30.0, 15, 1.0, 300.0, 0);
    over["pressure"] = json!({"ok": false, "over": ["memory pressure warn"], "cores": 15});
    let v = place(&[c("desk", swapped), c("small", over)], Some(&registry()), Work::Agent);
    assert!(["desk", "small"].contains(&v["pick"].as_str().unwrap_or_default()), "{v:#}");
    assert_eq!(v["overloaded"], true, "{v:#}");
    assert!(host(&v, "desk")["refused"].as_str().unwrap().starts_with("swap 29/30 GB"), "{v:#}");
    assert!(host(&v, "small")["refused"].as_str().unwrap().contains("memory pressure"), "{v:#}");
    assert!(v["why"].as_str().unwrap().contains("load and lane caps only warn"), "{v:#}");

    // A host whose entry sets no swap limit is never refused for a full swap.
    let mut full = health(30.0, 15, 1.0, 300.0, 0);
    full["swap"] = json!({"usedBytes": (8.0 * GB) as u64, "totalBytes": (8.0 * GB) as u64});
    let v = place(&[c("big", full)], Some(&registry()), Work::Agent);
    assert_eq!(v["pick"], "big", "{v:#}");
}

#[test]
fn a_host_at_its_lane_cap_or_out_of_ram_has_no_room_yet_the_work_still_goes_somewhere() {
    let full =
        [c("light", health(40.0, 12, 1.0, 300.0, 3)), c("laptop", health(12.5, 8, 1.0, 300.0, 0))];
    let v = place(&full, Some(&registry()), Work::Agent);
    assert_eq!(host(&v, "light")["refused"], "no room: lanes is the limit", "{v:#}");
    assert_eq!(host(&v, "laptop")["refused"], "no room: RAM is the limit", "{v:#}");
    // Both have no room: the registry's rank breaks the tie, and the verdict says it is past the room.
    assert_eq!((&v["pick"], &v["overloaded"]), (&json!("light"), &json!(true)), "{v:#}");
    let placed = placed(&v).unwrap();
    assert!(placed.starts_with("placed on light: ") && placed.contains("only warn"), "{placed}");
    // A host with room is still picked first, and that is no overload.
    let v = place(
        &[full[0].clone(), c("small", health(16.0, 8, 0.2, 200.0, 0))],
        Some(&registry()),
        Work::Agent,
    );
    assert_eq!((&v["pick"], &v["overloaded"]), (&json!("small"), &json!(false)), "{v:#}");
    // A role still refuses: a full no-build host never takes a build, even with nothing else.
    let v = place(&[full[1].clone()], Some(&registry()), Work::Build);
    assert_eq!(v["pick"], Value::Null, "{v:#}");
    assert!(v["why"].as_str().unwrap().starts_with("no host has room"), "{v:#}");
}

#[test]
fn an_old_peer_is_never_refused_for_its_build_and_ranks_after_one_with_a_reading() {
    let old = json!({"unsupported": true});
    let v = place(
        &[c("big", old.clone()), c("small", health(16.0, 8, 0.2, 200.0, 0))],
        Some(&registry()),
        Work::Agent,
    );
    assert_eq!(v["pick"], "small", "{v:#}");
    assert_eq!(host(&v, "big")["ok"], true, "{v:#}");
    assert!(host(&v, "big")["why"].as_str().unwrap().contains("unknown"), "{v:#}");
    // Alone, it is the pick; so is a peer with no reading yet.
    let v = place(&[c("big", old)], Some(&registry()), Work::Agent);
    assert_eq!(v["pick"], "big", "{v:#}");
    let v = place(&[c("big", Value::Null)], Some(&registry()), Work::Agent);
    assert_eq!(v["pick"], "big", "{v:#}");
}

#[test]
fn hosts_are_matched_by_name_or_alias_and_a_host_without_lanes_is_refused() {
    let roomy = || health(40.0, 16, 1.0, 300.0, 0);
    let v = place(
        &[c("Big-Box.local", roomy()), c("ci-mini", roomy()), c("stranger", roomy())],
        Some(&registry()),
        Work::Agent,
    );
    assert_eq!(v["pick"], "Big-Box.local", "{v:#}");
    for name in ["ci-mini", "stranger"] {
        assert!(host(&v, name)["refused"].as_str().unwrap().contains("not a lane host"), "{v:#}");
    }
}

#[test]
fn without_a_registry_every_candidate_is_sized_by_the_defaults() {
    let v = place(
        &[c("a", health(8.0, 4, 3.5, 100.0, 0)), c("b", health(30.0, 16, 2.0, 100.0, 5))],
        None,
        Work::Build,
    );
    assert_eq!(v["pick"], "b", "{v:#}");
}

#[test]
fn ties_go_to_the_registry_rank_then_fewer_live_agents() {
    let same = |live| health(20.0, 32, 0.0, 400.0, live);
    let mut reg = registry();
    reg["machines"]["small"]["lanes"]["reserved_gb"] = json!(8);
    reg["machines"]["small"]["lanes"]["per_lane_gb"] = json!(4);
    reg["machines"]["light"]["lanes"] = reg["machines"]["big"]["lanes"].clone();
    reg["machines"]["light"]["lanes"]["rank"] = json!(0);
    let v = place(&[c("big", same(0)), c("light", same(0))], Some(&reg), Work::Agent);
    assert_eq!(v["pick"], "light", "rank breaks a tie: {v:#}");
    let v = place(&[c("big", same(2)), c("small", same(1))], Some(&reg), Work::Agent);
    assert_eq!(v["pick"], "small", "fewer live agents break a tie: {v:#}");
}

#[test]
fn an_unknown_build_host_never_turns_away_a_fallback_host_with_room() {
    let v = place(
        &[c("big", Value::Null), c("light", health(40.0, 12, 1.0, 300.0, 0))],
        Some(&registry()),
        Work::Build,
    );
    assert_eq!(v["pick"], "light", "{v:#}");
    assert_eq!(host(&v, "big")["ok"], true, "{v:#}");
}

#[test]
fn bad_readings_and_bad_registry_values_are_unknown_not_room() {
    // A negative load adds no CPU room; a NaN-free JSON can still carry negatives.
    let mut neg = health(60.0, 32, 0.0, 400.0, 0);
    neg["load"] = json!([-50.0, 0.0, 0.0]);
    let mut reg = registry();
    reg["machines"]["big"]["lanes"]["max_lanes"] = json!(-1);
    reg["machines"]["big"]["lanes"]["max_swap_used_fraction"] = json!(7);
    let mut full = neg.clone();
    full["swap"] = json!({"usedBytes": (8.0 * GB) as u64, "totalBytes": (8.0 * GB) as u64});
    let v = place(&[c("big", full)], Some(&reg), Work::Agent);
    // The fraction is held to 1: a swap 100% full is refused, not ignored.
    assert!(host(&v, "big")["refused"].as_str().unwrap().starts_with("swap 8/8 GB"), "{v:#}");
    let v = place(&[c("big", neg)], Some(&reg), Work::Agent);
    // No CPU term (load unknown) and no lane cap (max_lanes invalid): RAM (60 - 8) / 4 = 13.
    assert_eq!(host(&v, "big")["room"], 13.0, "{v:#}");
    assert!(!host(&v, "big")["why"].as_str().unwrap().contains("cores busy"), "{v:#}");
}

#[test]
fn the_registry_is_matched_by_canonical_name_everywhere() {
    let reg = registry();
    let hosts = lane_hosts(Some(&reg)).unwrap();
    assert_eq!(canonical("Big-Box.local"), "big-box");
    assert!(registry_lanes(&hosts, "LAPTOP.local").is_some_and(|l| l["build"] == false));
    assert!(registry_lanes(&hosts, "ci-mini").is_some_and(|l| l.is_null()));
    assert!(registry_lanes(&hosts, "stranger").is_none());
}

#[test]
fn a_reading_without_live_agents_leaves_the_lane_cap_out_never_counts_zero() {
    let mut h = health(40.0, 16, 1.0, 300.0, 0);
    h.as_object_mut().unwrap().remove("liveSessions");
    // light's cap is 3: with live unknown its room comes from RAM ((40 - 6) / 3 = 11), not 3 - 0.
    let v = place(&[c("light", h)], Some(&registry()), Work::Agent);
    assert_eq!(host(&v, "light")["room"], 11.0, "{v:#}");
    assert_eq!(host(&v, "light")["live"], Value::Null, "{v:#}");
}

/// A machine whose registry entry carries a `hold` takes no new work, even when every other host
/// is out of room; a hold whose `until` passed holds nothing, and one whose `until` cannot be
/// read still holds.
#[test]
fn a_held_host_is_never_a_placement_candidate() {
    let both =
        [c("big", health(60.0, 32, 1.0, 400.0, 0)), c("small", health(5.0, 8, 7.9, 30.0, 0))];
    for held in [
        json!(true),
        json!("lawrence is using it"),
        json!({"owner": "lawrencecchen", "reason": "a teammate's", "until": "2999-01-01T00:00:00Z"}),
        json!({"until": "not a time"}),
    ] {
        let mut reg = registry();
        reg["machines"]["big"]["hold"] = held.clone();
        let v = place(&both, Some(&reg), Work::Agent);
        // small has no room (RAM 5 - 4 under one lane), so it takes the work anyway.
        assert_eq!(v["pick"], "small", "{held}: {v}");
        assert_eq!(v["overloaded"], true, "{held}: {v}");
        let big = host(&v, "big");
        assert_eq!(big["ok"], false);
        assert!(big["refused"].as_str().unwrap().starts_with("held"), "{big}");
        // Alone, the held host is still refused: a hold is not load.
        let v = place(&both[..1], Some(&reg), Work::Build);
        assert_eq!(v["pick"], Value::Null, "{held}: {v}");
    }
    let mut reg = registry();
    reg["machines"]["big"]["hold"] = json!({"owner": "lawrencecchen", "reason": "a teammate's", "until": "2999-01-01T00:00:00Z"});
    let v = place(&both, Some(&reg), Work::Agent);
    assert_eq!(
        host(&v, "big")["refused"],
        "held for lawrencecchen until 2999-01-01T00:00:00Z: a teammate's"
    );
    // Lapsed, or `hold: false`: big is a candidate again.
    for lapsed in [json!({"until": "2001-01-01T00:00:00Z"}), json!(false), Value::Null] {
        reg["machines"]["big"]["hold"] = lapsed.clone();
        assert_eq!(place(&both, Some(&reg), Work::Agent)["pick"], "big", "{lapsed}");
    }
    // By alias too, and at a chosen time.
    reg["machines"]["big"]["hold"] = json!({"until": "2026-10-30T20:50:00Z"});
    let hosts = lane_hosts_at(Some(&reg), 0).unwrap();
    assert!(registry_lanes(&hosts, "big-box").unwrap()[HELD].is_string());
    let after = crate::server::machine_health::rfc3339_ms("2026-10-30T20:50:01Z").unwrap();
    let hosts = lane_hosts_at(Some(&reg), after).unwrap();
    assert!(registry_lanes(&hosts, "big-box").unwrap().get(HELD).is_none());
}

/// A machine a person works at: `interactive: true`, or the registry's role for one (`leo-mac`,
/// `attended`), by name or alias. Fleet hosts and unlisted machines are not.
#[test]
fn interactive_machines_come_from_the_registry() {
    let reg = json!({"machines": {
        "cosmic": {"aliases": ["mbp"], "roles": ["mac-build", "leo-mac"]},
        "air": {"roles": ["attended", "leo-mac"]},
        "desk": {"interactive": true},
        "lane": {"roles": ["session-host", "codex-lanes"], "lanes": {}},
        "quiet": {"interactive": false}}});
    for name in ["cosmic", "MBP.local", "air", "desk"] {
        assert!(interactive(Some(&reg), name), "{name}");
    }
    for name in ["lane", "quiet", "unlisted"] {
        assert!(!interactive(Some(&reg), name), "{name}");
    }
    assert!(!interactive(None, "cosmic"), "no registry: nothing is interactive");
}

/// What `dispatch --host auto` leaves out (design/agent-dispatch.md): a person's machine, an
/// interactive one or one with the `leo-apps` role, and a host whose lanes say `last_resort`,
/// by name or alias.
#[test]
fn personal_and_last_resort_machines_come_from_the_registry() {
    let reg = json!({"machines": {
        "cosmic": {"aliases": ["mbp"], "roles": ["leo-mac"]},
        "desk": {"interactive": true},
        "apps": {"aliases": ["red"], "roles": ["leo-apps"], "lanes": {}},
        "spare": {"aliases": ["sixteen"], "lanes": {"last_resort": true}},
        "maybe": {"lanes": {"last_resort": "yes"}},
        "lane": {"roles": ["session-host"], "lanes": {"last_resort": false}}}});
    for name in ["cosmic", "MBP.local", "desk", "apps", "red"] {
        assert!(personal(Some(&reg), name), "{name}");
    }
    for name in ["spare", "lane", "unlisted"] {
        assert!(!personal(Some(&reg), name), "{name}");
    }
    assert!(!interactive(Some(&reg), "apps"), "leo-apps alone is not a machine a person works at");
    for name in ["spare", "Sixteen.local"] {
        assert!(last_resort(Some(&reg), name), "{name}");
    }
    for name in ["maybe", "lane", "cosmic", "unlisted"] {
        assert!(!last_resort(Some(&reg), name), "{name}");
    }
    assert!(!personal(None, "cosmic") && !last_resort(None, "spare"));
}

/// A host a `reservations` entry names takes no new work while the entry is active (from `from`
/// to `until`), by name or alias; an entry whose times cannot be read still holds it.
#[test]
fn a_reserved_host_is_never_a_placement_candidate() {
    let both =
        [c("big", health(60.0, 32, 1.0, 400.0, 0)), c("small", health(5.0, 8, 7.9, 30.0, 0))];
    let at = |t: &str| crate::server::machine_health::rfc3339_ms(t).unwrap();
    let mut reg = registry();
    reg["reservations"] = json!([{"id": "lawrence-2026-10-29", "owner": "lawrencecchen",
        "hosts": ["big-box"], "from": "2026-10-29T20:50:00Z", "until": "2026-10-30T20:50:00Z"}]);
    let hosts = lane_hosts_at(Some(&reg), at("2026-10-30T00:00:00Z")).unwrap();
    assert_eq!(
        registry_lanes(&hosts, "big").unwrap()[HELD],
        "reserved for lawrencecchen until 2026-10-30T20:50:00Z (lawrence-2026-10-29)"
    );
    for t in ["2026-10-29T20:00:00Z", "2026-10-30T21:00:00Z"] {
        let hosts = lane_hosts_at(Some(&reg), at(t)).unwrap();
        assert!(registry_lanes(&hosts, "big").unwrap().get(HELD).is_none(), "{t}");
    }
    // Live now: refused, never the overflow pick.
    reg["reservations"][0]["until"] = json!("2999-01-01T00:00:00Z");
    let v = place(&both, Some(&reg), Work::Agent);
    assert_eq!(v["pick"], "small", "{v}");
    assert!(host(&v, "big")["refused"].as_str().unwrap().starts_with("reserved for lawrencecchen"));
    assert!(held(Some(&reg), "BIG-BOX.local").is_some());
    assert!(held(Some(&reg), "small").is_none());
    reg["reservations"][0]["until"] = json!("someday");
    reg["reservations"][0]["from"] = json!("2001-01-01T00:00:00Z");
    assert_eq!(place(&both, Some(&reg), Work::Agent)["pick"], "small");
    reg["reservations"][0]["until"] = json!("2001-01-02T00:00:00Z");
    assert_eq!(place(&both, Some(&reg), Work::Agent)["pick"], "big");
}

/// A hold or a reservations list the registry cannot be read for fails closed: the machine (for
/// reservations, every machine it might name) takes no new work.
#[test]
fn unreadable_holds_and_reservations_hold() {
    let both =
        [c("big", health(60.0, 32, 1.0, 400.0, 0)), c("small", health(30.0, 8, 1.0, 300.0, 0))];
    for bad in [json!(" "), json!(3), json!(["x"])] {
        let mut reg = registry();
        reg["machines"]["big"]["hold"] = bad.clone();
        let v = place(&both, Some(&reg), Work::Agent);
        assert_eq!(v["pick"], "small", "{bad}: {v}");
        assert!(host(&v, "big")["refused"].as_str().unwrap().contains("cannot be read"), "{bad}");
    }
    for bad in [
        json!({"hosts": ["big"]}),
        json!([{"id": "r", "hosts": "big"}]),
        json!([{"id": "r"}]),
        json!([{"id": "r", "hosts": ["small", 7]}]),
    ] {
        let mut reg = registry();
        reg["reservations"] = bad.clone();
        let v = place(&both, Some(&reg), Work::Agent);
        assert_eq!(v["pick"], Value::Null, "{bad}: {v}");
        assert!(held(Some(&reg), "big").unwrap().contains("cannot be read"), "{bad}");
    }
    let mut reg = registry();
    reg["reservations"] = Value::Null;
    assert_eq!(place(&both, Some(&reg), Work::Agent)["pick"], "big");
}

/// The disk floor `session move --host auto` holds a host to: its `lanes.free_gb_floor`, by
/// name or alias, else the default lane host's.
#[test]
fn disk_floor_comes_from_the_registry_lanes_entry() {
    let reg = json!({"machines": {
        "lane": {"aliases": ["l1"], "lanes": {"free_gb_floor": 40}},
        "bare": {"lanes": {}},
        "none": {}}});
    assert_eq!(disk_floor(Some(&reg), "lane"), 40_000_000_000);
    assert_eq!(disk_floor(Some(&reg), "L1.local"), 40_000_000_000);
    let default = disk_floor(None, "x");
    assert_eq!(default, 10_000_000_000);
    for name in ["bare", "none", "unlisted"] {
        assert_eq!(disk_floor(Some(&reg), name), default, "{name}");
    }
}

/// A registry with a Freestyle lane VM, a GCP lane VM, an owned host and a placement_preference.
fn tiered() -> Value {
    let lanes = json!({"rank": 1, "build": false, "free_gb_floor": 20, "reserved_gb": 4,
        "per_lane_gb": 4, "disk_per_lane_gb": 5, "max_lanes": 8});
    json!({
        "lane_place": {"placement_preference": ["freestyle", "gcp", "owned"]},
        "machines": {
            "fs-vm": {"agent_vm": true, "cloud": {"pool": true}, "lanes": lanes},
            "gcp-vm": {"agent_vm": true, "gcp": {"zone": "z"}, "lanes": lanes},
            "gcp-lane-2": {"agent_vm": true, "lanes": lanes},
            "owned": {"lanes": lanes},
            "other": {"lanes": lanes}
        }
    })
}

#[test]
fn a_freestyle_vm_with_room_beats_a_less_loaded_gcp_vm() {
    // fs-vm: room for 2 (RAM). gcp-vm: idle, room for 7. Freestyle's tier wins before load.
    let cands = [
        c("gcp-vm", health(60.0, 32, 0.0, 400.0, 0)),
        c("fs-vm", health(12.0, 8, 4.0, 200.0, 3)),
        c("other", health(60.0, 32, 0.0, 400.0, 0)),
    ];
    let v = place(&cands, Some(&tiered()), Work::Agent);
    assert_eq!(v["pick"], "fs-vm", "{v:#}");
    assert_eq!(v["tier"], json!({"index": 1, "of": "freestyle"}), "{v:#}");
    assert!(
        v["why"].as_str().unwrap().ends_with("tier 1 (freestyle, lane_place.placement_preference)"),
        "{v:#}"
    );
    assert_eq!(host(&v, "gcp-vm")["tier"], json!({"index": 2, "of": "gcp"}), "{v:#}");
    assert_eq!(host(&v, "other")["tier"], Value::Null, "{v:#}");

    // A GCE lane VM named gcp-* with no gcp block is gcp too, and beats a host in no tier.
    let cands = [
        c("other", health(60.0, 32, 0.0, 400.0, 0)),
        c("gcp-lane-2", health(12.0, 8, 4.0, 200.0, 3)),
    ];
    assert_eq!(place(&cands, Some(&tiered()), Work::Agent)["pick"], "gcp-lane-2");
    // A host listed by its own name takes that tier.
    let cands =
        [c("other", health(60.0, 32, 0.0, 400.0, 0)), c("owned", health(12.0, 8, 4.0, 200.0, 3))];
    let v = place(&cands, Some(&tiered()), Work::Agent);
    assert_eq!((&v["pick"], &v["tier"]["index"]), (&json!("owned"), &json!(3)), "{v:#}");
}

#[test]
fn a_full_freestyle_vm_loses_to_a_gcp_vm_with_room() {
    // fs-vm is at its lane cap: no room, so no tier, and the gcp VM with room takes it.
    let cands =
        [c("fs-vm", health(60.0, 32, 0.0, 400.0, 8)), c("gcp-vm", health(12.0, 8, 4.0, 200.0, 3))];
    let v = place(&cands, Some(&tiered()), Work::Agent);
    assert_eq!(v["pick"], "gcp-vm", "{v:#}");
    assert_eq!(v["overloaded"], false, "{v:#}");
    assert_eq!(host(&v, "fs-vm")["tier"], Value::Null, "{v:#}");
    assert_eq!(host(&v, "fs-vm")["refused"], "no room: lanes is the limit", "{v:#}");
}

#[test]
fn no_or_a_malformed_placement_preference_keeps_the_most_room_first() {
    let cands =
        [c("fs-vm", health(12.0, 8, 4.0, 200.0, 3)), c("gcp-vm", health(60.0, 32, 0.0, 400.0, 0))];
    let mut reg = tiered();
    reg.as_object_mut().unwrap().remove("lane_place");
    let v = place(&cands, Some(&reg), Work::Agent);
    assert_eq!((&v["pick"], &v["tier"]), (&json!("gcp-vm"), &Value::Null), "{v:#}");
    for bad in
        [json!("freestyle"), json!(["freestyle", "freestyle"]), json!(["nowhere"]), json!([1])]
    {
        reg["lane_place"] = json!({"placement_preference": bad});
        let v = place(&cands, Some(&reg), Work::Agent);
        assert_eq!((&v["pick"], &v["tier"]), (&json!("gcp-vm"), &Value::Null), "{bad}: {v:#}");
    }
}
