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
