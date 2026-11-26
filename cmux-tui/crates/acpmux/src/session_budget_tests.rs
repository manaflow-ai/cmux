use super::*;
use std::collections::BTreeMap;

const GB60: u64 = 60 * GIB;

fn reader(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
    let map: BTreeMap<String, String> =
        pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect();
    move |key| map.get(key).cloned()
}

/// A lane VM as of 2026-11-24: 16 cores, 60 GB, no swap, 6 lanes, 8 GB of disk a lane, no `io`
/// delegated to the user manager.
fn lane_host() -> Host {
    Host {
        memory: GB60,
        swap: 0,
        cores: 16,
        lanes: Some(6),
        disk_total: 247 * GIB,
        disk_per_lane: Some(8 * GIB),
        io: IoState { delegated: Some(false), policy: None },
    }
}

#[test]
fn a_lane_host_gives_each_session_two_lanes_of_ram_and_three_quarters_of_its_cores() {
    let b = Budget::read(&reader(&[]), &lane_host());
    assert_eq!(b.memory_max, GB60 / 6 * 2);
    assert_eq!(b.memory_high, b.memory_max / 10 * 9);
    assert_eq!(b.swap_max, 0);
    assert_eq!(b.tasks_max, Some(crate::session_scope::SESSION_TASKS_MAX));
    assert_eq!(b.cpu_weight, 50);
    assert_eq!(b.cpu_quota, 1200);
    assert_eq!(b.io_weight, 50);
    assert_eq!(b.disk, 8 * GIB);
}

#[test]
fn memory_has_a_floor_and_a_ceiling_of_half_the_ram() {
    // No lane cap: half the RAM, as before.
    assert_eq!(memory_default(&Host { memory: GB60, ..Host::default() }), GB60 / 2);
    // Many lanes on a small host: the floor.
    assert_eq!(
        memory_default(&Host { memory: 8 * GIB, lanes: Some(40), ..Host::default() }),
        MEMORY_FLOOR
    );
    // One lane: never more than half.
    assert_eq!(memory_default(&Host { memory: GB60, lanes: Some(1), ..Host::default() }), GB60 / 2);
    // Floor over half (a 3 GB host): half wins.
    assert_eq!(
        memory_default(&Host { memory: 3 * GIB, lanes: Some(8), ..Host::default() }),
        3 * GIB / 2
    );
    // Lanes 0 is no cap.
    assert_eq!(memory_default(&Host { memory: GB60, lanes: Some(0), ..Host::default() }), GB60 / 2);
}

#[test]
fn disk_defaults_to_the_lane_share_else_a_tenth_with_lanes_else_half_clamped() {
    assert_eq!(disk_default(&lane_host()), 8 * GIB);
    // A shared host with a lane cap and no per-lane share: a tenth.
    let capped = Host { disk_total: 247 * GIB, lanes: Some(8), ..Host::default() };
    assert_eq!(disk_default(&capped), 247 * GIB / 10);
    // One person's machine (no lane cap): half. A 20 GiB Cloud VM gets 10 GiB, not the 2 GiB
    // floor a tenth gave (under one blobless cmux clone plus its build).
    assert_eq!(disk_default(&Host { disk_total: 20 * GIB, ..Host::default() }), 10 * GIB);
    assert_eq!(disk_default(&Host { disk_total: 2000 * GIB, ..Host::default() }), 64 * GIB);
    assert_eq!(
        disk_default(&Host { disk_total: 2000 * GIB, lanes: Some(8), ..Host::default() }),
        64 * GIB
    );
    assert_eq!(
        disk_default(&Host { disk_total: 10 * GIB, lanes: Some(8), ..Host::default() }),
        2 * GIB
    );
    // Unknown disk: still the floor, never more than the disk when it is known.
    assert_eq!(disk_default(&Host::default()), 2 * GIB);
    assert_eq!(disk_default(&Host { disk_total: GIB, ..Host::default() }), GIB);
}

#[test]
fn each_knob_overrides_and_zero_turns_it_off() {
    let host = lane_host();
    let b = Budget::read(
        &reader(&[
            ("ACPMUX_SESSION_MEMORY_MB", "1024"),
            ("ACPMUX_SESSION_MEMORY_HIGH_MB", "4096"),
            ("ACPMUX_SESSION_CPU_WEIGHT", "20"),
            ("ACPMUX_SESSION_CPU_QUOTA_PCT", "50"),
            ("ACPMUX_SESSION_IO_WEIGHT", "10"),
            ("ACPMUX_SESSION_DISK_MB", "100"),
            ("ACPMUX_SESSION_SWAP_MB", "64"),
        ]),
        &host,
    );
    assert_eq!(b.memory_max, 1024 * MIB);
    // High never over Max.
    assert_eq!(b.memory_high, 1024 * MIB);
    assert_eq!((b.cpu_weight, b.cpu_quota, b.io_weight), (20, 800, 10));
    assert_eq!((b.disk, b.swap_max), (100 * MIB, 64 * MIB));

    let off = Budget::read(
        &reader(&[
            ("ACPMUX_SESSION_MEMORY_MB", "0"),
            ("ACPMUX_SESSION_MEMORY_HIGH_MB", "0"),
            ("ACPMUX_SESSION_TASKS_MAX", "0"),
            ("ACPMUX_SESSION_CPU_WEIGHT", "0"),
            ("ACPMUX_SESSION_CPU_QUOTA_PCT", "0"),
            ("ACPMUX_SESSION_IO_WEIGHT", "0"),
            ("ACPMUX_SESSION_DISK_MB", "0"),
        ]),
        &host,
    );
    assert_eq!(off, Budget { tasks_max: None, ..Budget::default() });
    assert!(off.properties().is_empty());
    assert_eq!(
        off.bus_properties(),
        vec![
            ["TasksMax".to_owned(), "t".into(), u64::MAX.to_string()],
            ["OOMPolicy".into(), "s".into(), "continue".into()],
        ]
    );
}

#[test]
fn the_properties_in_both_spellings() {
    let b = Budget::read(&reader(&[("ACPMUX_SESSION_MEMORY_MB", "1024")]), &lane_host());
    let p: Vec<String> = b.properties().into_iter().map(|(k, v)| format!("{k}={v}")).collect();
    assert_eq!(
        p,
        [
            "MemoryMax=1073741824",
            "MemoryHigh=966367638",
            "TasksMax=4096",
            "CPUWeight=50",
            "CPUQuota=1200%",
            "IOWeight=50",
        ]
    );
    let bus: Vec<String> = b.bus_properties().into_iter().map(|t| t.join(" ")).collect();
    assert_eq!(
        bus,
        [
            "MemoryMax t 1073741824",
            "MemoryHigh t 966367638",
            "TasksMax t 4096",
            "CPUWeight t 50",
            "CPUQuotaPerSecUSec t 12000000",
            "IOWeight t 50",
            "OOMPolicy s continue",
        ]
    );
    // No task cap: an explicit infinity, not systemd's DefaultTasksMax.
    let open = Budget::read(&reader(&[("ACPMUX_SESSION_TASKS_MAX", "0")]), &lane_host());
    assert!(open.properties().contains(&("TasksMax", "infinity".to_owned())));
    assert!(
        open.bus_properties().iter().any(|t| t[0] == "TasksMax" && t[2] == u64::MAX.to_string())
    );
}

#[test]
fn lanes_are_found_by_a_full_or_short_host_name() {
    let registry = serde_json::json!({
        "machines": {
            "gcp-agent-lane-8": {"lanes": {"max_lanes": 6, "disk_per_lane_gb": 8}},
            "fs-agent-lane-18": {"lanes": {"max_lanes": 8}},
        }
    });
    assert_eq!(
        lanes_of(Some(&registry), "gcp-agent-lane-8.us-west1-c.c.manaflow-437420.internal"),
        (Some(6), Some(8 * GIB))
    );
    assert_eq!(lanes_of(Some(&registry), "fs-agent-lane-18"), (Some(8), None));
    assert_eq!(lanes_of(Some(&registry), "elsewhere"), (None, None));
    assert_eq!(lanes_of(None, "gcp-agent-lane-8"), (None, None));
}

#[test]
fn status_carries_its_version_and_what_it_was_sized_from() {
    let host = lane_host();
    let b = Budget::read(&reader(&[]), &host);
    let totals =
        (session_total_from(&reader(&[]), &host, &b), hosts_total_from(&reader(&[]), &host, 16384));
    let v = status(
        &b,
        &b,
        (&totals.0, &totals.1),
        &host,
        serde_json::json!({"enabled": true, "use": []}),
        Value::Null,
    );
    assert_eq!(v["version"], VERSION);
    assert_eq!(v["perSession"]["memoryMaxBytes"], GB60 / 6 * 2);
    assert_eq!(v["hostsSlice"]["memoryMaxBytes"], GB60 * 85 / 100);
    assert_eq!(v["hostsSlice"]["cpuQuotaPercent"], 1440);
    assert_eq!(v["perScope"]["cpuQuotaPercent"], 1200);
    assert_eq!(v["perScope"]["diskBytes"], 8 * GIB);
    assert_eq!(v["sizedFrom"]["lanes"], 6);
    assert_eq!(v["sizedFrom"]["cores"], 16);
    assert_eq!(
        v["io"],
        serde_json::json!({"delegated": false, "policy": null, "weightEffective": false})
    );
}

/// The cgroup and sysfs text a lane VM gave on 2026-11-24, before and after `Delegate=cpu cpuset
/// io memory pids` on `user@.service` and `enable=1` in the root `io.cost.qos`.
#[test]
fn io_state_reads_delegation_and_the_weight_policy() {
    let cgroup = "0::/user.slice/user-1003.slice/user@1003.service/app.slice/acpmux.service\n";
    let manager = "/user.slice/user-1003.slice/user@1003.service/cgroup.controllers";
    let controllers = |c: &'static str| move |p: &str| (p == manager).then(|| c.to_owned());
    let off = "259:0 enable=0 ctrl=auto rpct=0.00 rlat=25000 wpct=0.00 wlat=25000 min=1.00 max=10000.00\n";
    let on = "259:0 enable=1 ctrl=auto rpct=0.00 rlat=25000 wpct=0.00 wlat=25000 min=1.00 max=10000.00\n";
    let none = vec!["[none] mq-deadline\n".to_owned()];

    let before = IoState::from(cgroup, &controllers("cpu memory pids\n"), off, &none);
    assert_eq!(before, IoState { delegated: Some(false), policy: None });
    assert_eq!(before.effective(), Some(false));

    let delegated = IoState::from(cgroup, &controllers("cpuset cpu io memory pids\n"), off, &none);
    assert_eq!(delegated, IoState { delegated: Some(true), policy: None });
    assert_eq!(delegated.effective(), Some(false));

    let after = IoState::from(cgroup, &controllers("cpuset cpu io memory pids\n"), on, &none);
    assert_eq!(after.policy, Some(IoPolicy::Iocost));
    assert_eq!(after.effective(), Some(true));

    let bfq = vec!["mq-deadline kyber [bfq] none\n".to_owned()];
    let with_bfq = IoState::from(cgroup, &controllers("io memory\n"), "", &bfq);
    assert_eq!(with_bfq.policy, Some(IoPolicy::Bfq));
    assert_eq!(with_bfq.effective(), Some(true));

    // `iomem` is not `io`; a daemon outside any user manager does not know.
    assert_eq!(
        IoState::from(cgroup, &controllers("iomem cpu\n"), on, &none).delegated,
        Some(false)
    );
    let system = IoState::from("0::/system.slice/acpmux.service\n", &|_: &str| None, on, &none);
    assert_eq!(system.delegated, None);
    assert_eq!(system.effective(), None);
}

/// The old/new compatibility check: a CLI reads any daemon's `sessionBudgets`.
#[test]
fn the_budget_line_reads_old_this_and_newer_daemons() {
    // An older daemon: no `sessionBudgets` at all, no line.
    assert_eq!(budget_line(&Value::Null), None);
    assert_eq!(budget_line(&serde_json::json!({"version": 1})), None);

    let host = lane_host();
    let b = Budget::read(&reader(&[]), &host);
    let session = session_total_from(&reader(&[]), &host, &b);
    let hosts = hosts_total_from(&reader(&[("ACPMUX_HOSTS_MEMORY_MAX_MB", "0")]), &host, 16384);
    let watch =
        serde_json::json!({"use": [{"state": "ok"}, {"state": "over"}, {"state": "stopped"}]});
    // Version 2 (#54455): `io`, no `store`; the line is as it read then.
    let mut v2 = status(&b, &b, (&session, &hosts), &host, watch.clone(), Value::Null);
    v2["version"] = 2.into();
    for key in ["store", "perSession", "hostsSlice"] {
        v2.as_object_mut().unwrap().remove(key);
    }
    assert_eq!(
        budget_line(&v2).unwrap(),
        "mem 20.0G (high 18.0G), cpu 1200% weight 50, disk 8.0G, io weight 50 (inert: io not \
         delegated), sized for 6 lanes, 2 scope(s) over"
    );

    // This version (3): the store budget, on, with a chat over it.
    let mut store = crate::session_store::Watch {
        budget: crate::session_store::store_default(b.disk),
        compress: true,
        ..Default::default()
    };
    store.apply(vec![("a".into(), 2 * GIB, false), ("b".into(), 1, false)]);
    let mut v3 = status(&b, &b, (&session, &hosts), &host, watch.clone(), store.json(true));
    v3["version"] = 3.into();
    for key in ["perSession", "hostsSlice"] {
        v3.as_object_mut().unwrap().remove(key);
    }
    assert_eq!(v3["store"]["budgetBytes"], GIB);
    assert_eq!(
        budget_line(&v3).unwrap(),
        "mem 20.0G (high 18.0G), cpu 1200% weight 50, disk 8.0G, io weight 50 (inert: io not \
         delegated), sized for 6 lanes, 2 scope(s) over, store 1.0G a chat (1 chat(s) over)"
    );
    // Store off: no store part.
    let off_store = crate::session_store::Watch::default().json(true);
    let off = status(&b, &b, (&session, &hosts), &host, watch.clone(), off_store);
    assert!(!budget_line(&off).unwrap().contains("store"));

    // This version (4): the totals too.
    assert_eq!(
        budget_line(&status(&b, &b, (&session, &hosts), &host, watch, store.json(true))).unwrap(),
        "mem 20.0G (high 18.0G), cpu 1200% weight 50, disk 8.0G, session total 20.0G, \
         hosts total off, io weight 50 (inert: io not delegated), sized for 6 lanes, 2 scope(s) \
         over, store 1.0G a chat (1 chat(s) over)"
    );

    // Version 1 (no `io`, no `store`): its line is what it always was.
    let mut v1 =
        status(&b, &b, (&session, &hosts), &host, serde_json::json!({"use": []}), Value::Null);
    v1["version"] = 1.into();
    for key in ["io", "store", "perSession", "hostsSlice"] {
        v1.as_object_mut().unwrap().remove(key);
    }
    assert_eq!(
        budget_line(&v1).unwrap(),
        "mem 20.0G (high 18.0G), cpu 1200% weight 50, disk 8.0G, sized for 6 lanes"
    );

    // Delegated with iocost on: the weight shows with no "inert".
    let mut live =
        status(&b, &b, (&session, &hosts), &host, serde_json::json!({"use": []}), Value::Null);
    live["io"] = IoState { delegated: Some(true), policy: Some(IoPolicy::Iocost) }.json();
    assert!(budget_line(&live).unwrap().contains(", io weight 50, sized for"));
    live["io"] = IoState { delegated: Some(true), policy: None }.json();
    assert!(budget_line(&live).unwrap().contains("io weight 50 (inert: no iocost or bfq)"));

    // A newer daemon: fields this CLI does not know, and some it knows missing.
    let newer = serde_json::json!({
        "version": 5,
        "perSession": {"memoryMaxBytes": 2 * GIB, "ioMax": "a shape this CLI does not know"},
        "hostsSlice": "not an object",
        "store": {"on": true, "budgetBytes": "a shape this CLI does not know"},
        "io": {"delegated": "a shape this CLI does not know"},
        "perScope": {"memoryMaxBytes": 0, "cpuWeight": 30, "netWeight": 9, "diskBytes": GIB},
        "aggregate": {"slice": "acpmuxlanes.slice"},
        "watch": {"use": "a shape this CLI does not know"},
    });
    assert_eq!(
        budget_line(&newer).unwrap(),
        "mem off (high off), cpu no ceiling weight 30, disk 1.0G, session total 2.0G"
    );
}

#[test]
fn a_session_total_defaults_to_one_scopes_budget_and_each_knob_overrides_or_turns_off() {
    let host = lane_host();
    let b = Budget::read(&reader(&[]), &host);
    let t = session_total_from(&reader(&[]), &host, &b);
    assert_eq!(t.memory_max, GB60 / 6 * 2);
    assert_eq!(t.tasks_max, b.tasks_max.map(|n| n * 2));
    assert_eq!(t.cpu_quota, 1200);
    assert!(t.on());
    let set = reader(&[
        ("ACPMUX_SESSION_TOTAL_MEMORY_MB", "4096"),
        ("ACPMUX_SESSION_TOTAL_TASKS_MAX", "500"),
        ("ACPMUX_SESSION_TOTAL_CPU_QUOTA_PCT", "25"),
    ]);
    let t = session_total_from(&set, &host, &b);
    assert_eq!((t.memory_max, t.tasks_max, t.cpu_quota), (4096 * MIB, Some(500), 400));
    let off = reader(&[
        ("ACPMUX_SESSION_TOTAL_MEMORY_MB", "0"),
        ("ACPMUX_SESSION_TOTAL_TASKS_MAX", "0"),
        ("ACPMUX_SESSION_TOTAL_CPU_QUOTA_PCT", "0"),
    ]);
    let t = session_total_from(&off, &host, &b);
    assert!(!t.on(), "{t:?}");
    assert!(t.bus_properties().is_empty());
    assert_eq!(
        t.properties(),
        vec![
            ("MemoryMax", "infinity".into()),
            ("TasksMax", "infinity".into()),
            ("CPUQuota", String::new())
        ]
    );
}

#[test]
fn the_hosts_total_is_most_of_the_ram_and_cores_and_each_knob_overrides_or_turns_off() {
    let host = lane_host();
    let t = hosts_total_from(&reader(&[]), &host, 16384);
    assert_eq!((t.memory_max, t.tasks_max, t.cpu_quota), (GB60 * 85 / 100, Some(16384), 1440));
    assert_eq!(
        t.bus_properties(),
        vec![
            ["MemoryMax".to_owned(), "t".into(), (GB60 * 85 / 100).to_string()],
            ["TasksMax".into(), "t".into(), "16384".into()],
            ["CPUQuotaPerSecUSec".into(), "t".into(), "14400000".into()],
        ]
    );
    assert_eq!(t.properties()[2], ("CPUQuota", "1440%".to_owned()));
    let off = reader(&[
        ("ACPMUX_HOSTS_MEMORY_MAX_MB", "0"),
        ("ACPMUX_HOSTS_TASKS_MAX", "0"),
        ("ACPMUX_HOSTS_CPU_QUOTA_PCT", "0"),
    ]);
    assert!(!hosts_total_from(&off, &host, 16384).on());
    let set = reader(&[("ACPMUX_HOSTS_MEMORY_MAX_MB", "30720")]);
    assert_eq!(hosts_total_from(&set, &host, 16384).memory_max, 30 * GIB);
}

#[test]
fn a_task_scope_on_a_host_without_swap_gets_no_default_throttle() {
    let host = lane_host();
    let task = task_budget_from(&reader(&[]), &host);
    assert_eq!(task.memory_high, 0);
    assert_eq!(task.memory_max, GB60 / 6 * 2);
    assert!(!task.bus_properties().iter().any(|t| t[0] == "MemoryHigh"));
    // A set throttle stays, and with swap the default does.
    let set = task_budget_from(&reader(&[("ACPMUX_SESSION_MEMORY_HIGH_MB", "1024")]), &host);
    assert_eq!(set.memory_high, 1024 * MIB);
    let swap = Host { swap: 8 * GIB, ..host };
    assert_eq!(task_budget_from(&reader(&[]), &swap).memory_high, swap_budget_high(&swap));
}

fn swap_budget_high(host: &Host) -> u64 {
    Budget::read(&reader(&[]), host).memory_high
}

#[test]
fn cpu_classes_are_off_by_default_and_change_nothing() {
    let off = reader(&[]);
    assert!(!cpu_classes_on(&off));
    assert_eq!(Budget::read(&off, &lane_host()).cpu_weight, CPU_WEIGHT);
    assert_eq!(task_budget_from(&off, &lane_host()).cpu_weight, CPU_WEIGHT);
    assert_eq!(sessions_slice_weight(&off), None);
    for word in ["0", "off", "no", ""] {
        assert!(!cpu_classes_on(&reader(&[("ACPMUX_SESSION_CPU_CLASSES", word)])), "{word}");
    }
}

#[test]
fn cpu_classes_give_sessions_four_times_their_builds_weight() {
    for word in ["1", "on", "TRUE", " true\n"] {
        let on = reader(&[("ACPMUX_SESSION_CPU_CLASSES", word)]);
        assert!(cpu_classes_on(&on), "{word:?}");
        let session = Budget::read(&on, &lane_host());
        let task = task_budget_from(&on, &lane_host());
        assert_eq!((session.cpu_weight, task.cpu_weight), (400, 100));
        assert_eq!(sessions_slice_weight(&on), Some(400));
        // Everything else is as it was: classes move weights only.
        let off = reader(&[]);
        let as_was = Budget { cpu_weight: session.cpu_weight, ..Budget::read(&off, &lane_host()) };
        assert_eq!(session, as_was);
        assert_eq!(task_budget_from(&off, &lane_host()).memory_high, task.memory_high);
        assert!(session.properties().contains(&("CPUWeight", "400".to_owned())));
        assert!(task.properties().contains(&("CPUWeight", "100".to_owned())));
    }
}

#[test]
fn a_set_cpu_weight_wins_over_cpu_classes() {
    let set = reader(&[("ACPMUX_SESSION_CPU_CLASSES", "1"), ("ACPMUX_SESSION_CPU_WEIGHT", "70")]);
    assert_eq!(Budget::read(&set, &lane_host()).cpu_weight, 70);
    assert_eq!(task_budget_from(&set, &lane_host()).cpu_weight, 70);
    assert_eq!(sessions_slice_weight(&set), None, "the slice is left as it is");
}
