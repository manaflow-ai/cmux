use super::*;

/// The note an Auto start's caller hears when its wait begins says a machine is being added
/// and how long the start waits; a Web caller's names no host.
#[test]
fn the_waiting_note_says_a_machine_is_being_added() {
    let over = OverCap { live: 9, max: 8, machine: "m".into(), source: "/r.json".into() };
    let ask = Ask {
        force: false,
        can_force: false,
        person: true,
        name: None,
        who: "test",
        local: false,
        peers: true,
        redirect: true,
        auto: true,
        waiting: None,
        harness: None,
        caller: None,
    };
    let note = waiting_note(&over, &ask);
    assert_eq!(note["scalingUp"], json!(true));
    assert_eq!(note["live"], json!(9));
    assert_eq!(note["maxLanes"], json!(8));
    assert_eq!(
        note["waitSecs"],
        json!(super::super::admission_scale_up::AUTO_WAIT_BOUND.as_secs())
    );
    let text = note["warning"].as_str().unwrap();
    assert!(text.starts_with("this machine has 9 live sessions"), "{text}");
    assert!(text.contains("a machine is being added"), "{text}");
}

#[test]
fn a_session_whose_agent_host_runs_is_live_whatever_its_status() {
    // After a daemon restart every kept session reads Idle until it is reattached.
    assert!(is_live(SessionStatus::Idle, true));
    assert!(is_live(SessionStatus::Disconnected, true));
    assert!(!is_live(SessionStatus::Idle, false));
    assert!(!is_live(SessionStatus::Closed, true));
    assert!(is_live(SessionStatus::Ready, false));
}

/// A registry that turns unreadable keeps its last good copy: a partial write
/// never drops the cap's warning.
#[test]
fn an_unreadable_registry_keeps_the_last_good_copy() {
    let dir = std::env::temp_dir().join(format!("acpmux-reg-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    // Its own last good copy: the process-wide one is shared with every test that admits.
    let mut last = None;
    let mut read_registry = |source: &Path, set: bool| read_registry_in(&mut last, source, set);
    let path = dir.join("fleet-registry.json");
    std::fs::write(&path, br#"{"machines":{"m":{"max_lanes":1}}}"#).unwrap();
    let fresh = dir.join("first-read-truncated.json");
    std::fs::write(&fresh, br#"{"machines":"#).unwrap();
    assert_eq!(read_registry(&fresh, false), (None, true), "no good copy yet: unreadable");
    let good = read_registry(&path, false).0.unwrap();
    std::fs::write(&path, br#"{"machines":{"m":"#).unwrap();
    assert_eq!(read_registry(&path, false), (Some(good.clone()), false));
    assert_eq!(read_registry(&dir.join("never-there.json"), false), (None, false));
    // FLEET_REGISTRY names a file that is missing: unreadable, or its last good copy.
    assert_eq!(read_registry(&dir.join("never-there.json"), true), (None, true));
    std::fs::remove_file(&path).unwrap();
    assert_eq!(read_registry(&path, true), (Some(good), false));
    let _ = std::fs::remove_dir_all(&dir);
    let unreadable = check(&Inputs {
        flag: None,
        registry: None,
        unreadable: true,
        source: &fresh,
        machine: None,
        live: 99,
    });
    assert_eq!(
        (&unreadable.under_floor, &unreadable.over),
        (&None, &None),
        "admitted: {unreadable:?}"
    );
    let why = unreadable.uncapped.unwrap_or_default();
    assert!(why.contains("cannot be read") && why.contains("first-read-truncated.json"), "{why}");
}

#[test]
fn a_create_whose_session_runs_counts_once() {
    let (starting, made, gone) =
        (Arc::new(Making::default()), Arc::new(Making::default()), Arc::new(Making::default()));
    made.made.set("child".to_owned()).unwrap();
    gone.made.set("ended".to_owned()).unwrap();
    let live: std::collections::HashSet<&str> = ["parent", "child"].into();
    // parent, child (once, not again for its create), the create still starting,
    // and the create whose session is not live (yet, or any more).
    assert_eq!(counted(&live, &[starting, made, gone]), 4);
    assert_eq!(counted(&live, &[]), 2);
}

#[tokio::test]
async fn the_session_a_create_inserts_is_claimed_by_its_own_admission() {
    let admitting = Admitting::default();
    let made = Arc::new(Making::default());
    admitting.0.lock().unwrap().push(made.clone());
    let admitted = Admitted {
        admitting: &admitting,
        made: made.clone(),
        warning: None,
        placed: None,
        freed: None,
    };
    claim("outside");
    assert_eq!(made.made.get(), None, "a session inserted outside the create is not its");
    admitted.run(async { claim("mine") }).await;
    assert_eq!(made.made.get().map(String::as_str), Some("mine"));
    drop(admitted);
    assert!(admitting.0.lock().unwrap().is_empty(), "a dropped admission is no longer counted");
}

/// The four lane hosts as leo-workspace's registry has them.
fn registry() -> Value {
    json!({
        "origins": {
            "huge-blue": {"hostnames": ["huge-blue"]},
            "air-blue": {"hostnames": ["air-blue", "air-blue.local", "macbook-air"]},
        },
        "machines": {
            "huge-blue": {"lanes": {"max_lanes": 12}},
            "cmux16": {"lanes": {"max_lanes": 3}},
            "big-red": {"lanes": {"max_lanes": 6}},
            "air-blue": {"aliases": ["macbook-air"], "lanes": {"max_lanes": 3}},
            "cmux-lawrence": {},
        },
    })
}

#[test]
fn this_machine_is_found_by_name_alias_or_origin_hostname() {
    let r = registry();
    assert_eq!(machine_of(&r, None, "huge-blue").as_deref(), Some("huge-blue"));
    assert_eq!(machine_of(&r, None, "cmux16").as_deref(), Some("cmux16"));
    assert_eq!(machine_of(&r, None, "cmux16.local").as_deref(), Some("cmux16"));
    assert_eq!(machine_of(&r, None, "Air-Blue.local").as_deref(), Some("air-blue"));
    assert_eq!(machine_of(&r, None, "MacBook-Air").as_deref(), Some("air-blue"));
    assert_eq!(machine_of(&r, None, "somewhere-else"), None);
    assert_eq!(machine_of(&r, Some("huge-blue"), "air-blue").as_deref(), Some("huge-blue"));
    assert_eq!(machine_of(&r, Some("nowhere"), "huge-blue"), None);
}

#[test]
fn each_host_warns_at_its_own_max_lanes_and_never_refuses() {
    // huge-blue at its 12 refused the stall reconciler's PONG (2026-10-26):
    // a cap only warns.
    let r = registry();
    let source = Path::new("/r/fleet-registry.json");
    let at = |machine: &str, live| {
        check(&Inputs {
            flag: None,
            registry: Some(&r),
            unreadable: false,
            source,
            machine: Some(machine),
            live,
        })
    };
    let over = |machine: &str, live, max| {
        Some(OverCap { live, max, machine: machine.into(), source: source.into() })
    };
    for (machine, max) in [("huge-blue", 12), ("cmux16", 3), ("big-red", 6), ("air-blue", 3)] {
        let last = at(machine, max as usize - 1);
        assert_eq!((&last.under_floor, &last.over), (&None, &None), "{machine} under its cap");
        // Taking the last free slot is marked for the warm spare, and warns nothing.
        assert_eq!(last.last_slot, over(machine, max as usize - 1, max), "{machine} last slot");
        assert_eq!(at(machine, max as usize - 2), Verdict::default(), "{machine} has room");
        for live in [max as usize, 16] {
            let v = at(machine, live);
            assert_eq!(v.under_floor, None, "{machine} at {live}: a cap never refuses");
            assert_eq!(v.over, over(machine, live, max), "{machine} at {live}: warned");
        }
    }
    assert_eq!(at("cmux-lawrence", 50).over, None, "no lanes entry: no warning");
    let cap = over("cmux16", 16, 3).unwrap();
    let message = cap.warning(true, true, Some("placed on big-red: 31 GB RAM free"), false);
    assert!(
        message.contains("16 live sessions")
            && message.contains("cap of 3")
            && message.contains("lanes.max_lanes of cmux16 in /r/fleet-registry.json")
            && message.contains("started anyway")
            && message.contains("`acpmux new --machine auto` (placed on big-red: 31 GB RAM free)"),
        "the warning names the count, the cap, where it comes from and a host with room: {message}"
    );
    assert!(cap.warning(true, true, None, false).contains("No connected host has room"));
    let adding = cap.warning(true, true, None, true);
    assert!(
        adding.contains("No connected host has room") && adding.contains("machine is being added"),
        "with nowhere to go the fleet adds a machine: {adding}"
    );
    let web_adding = cap.warning(false, false, None, true);
    assert!(web_adding.contains("machine is being added") && !web_adding.contains("cmux16"));
    assert!(
        !cap.warning(true, true, Some("placed on big-red"), true).contains("being added"),
        "a host with room is suggested instead"
    );
    let peer = cap.warning(true, false, None, false);
    assert!(!peer.contains("connected host"), "a peer hears of no peer: {peer}");
    let web = cap.warning(false, false, None, false);
    assert!(!web.contains("/r/"), "a Web client learns no path: {web}");
    assert!(!web.contains("cmux16"), "nor the machine: {web}");
}

#[test]
fn one_lane_per_host_caps_at_one() {
    let mut r = registry();
    r["lane_place"] = json!({"one_lane_per_host": true});
    let source = Path::new("/r/fleet-registry.json");
    let at = |live| {
        check(&Inputs {
            flag: None,
            registry: Some(&r),
            unreadable: false,
            source,
            machine: Some("huge-blue"),
            live,
        })
    };
    assert_eq!(at(0).over, None, "the first lane fits");
    assert_eq!(at(1).over.map(|o| o.max), Some(1), "a second lane is over");
}

#[test]
fn the_flag_warns_alongside_the_cap_and_without_a_registry() {
    let r = registry();
    let source = Path::new("");
    let none = check(&Inputs {
        flag: None,
        registry: None,
        unreadable: false,
        source,
        machine: None,
        live: 99,
    });
    assert_eq!((none.under_floor, none.over), (None, None), "no registry: admitted");
    let stray = check(&Inputs {
        flag: None,
        registry: Some(&r),
        unreadable: false,
        source,
        machine: None,
        live: 99,
    });
    assert_eq!((stray.under_floor, stray.over), (None, None), "not a registry machine: admitted");
    let dir = std::env::temp_dir().join(format!("acpmux-admission-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let flag = dir.join("under-floor");
    std::fs::write(&flag, "").unwrap();
    let refusal = check(&Inputs {
        flag: Some(&flag),
        registry: None,
        unreadable: false,
        source,
        machine: None,
        live: 0,
    })
    .under_floor;
    assert_eq!(refusal, Some(UnderFloor { flag: flag.clone() }));
    let both = check(&Inputs {
        flag: Some(&flag),
        registry: Some(&r),
        unreadable: false,
        source,
        machine: Some("cmux16"),
        live: 6,
    });
    assert!(both.under_floor.is_some());
    assert_eq!(both.over.unwrap().max, 3);
    let floor = UnderFloor { flag: flag.clone() };
    assert!(floor.warning(true).contains(&flag.display().to_string()));
    assert!(!floor.warning(false).contains(&flag.display().to_string()));
    let missing = dir.join("absent");
    let verdict = check(&Inputs {
        flag: Some(&missing),
        registry: Some(&r),
        unreadable: false,
        source,
        machine: Some("huge-blue"),
        live: 0,
    });
    assert_eq!(verdict, Verdict::default());
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test(start_paused = true)]
async fn auto_waits_for_the_provider_machine_join_but_falls_back_safely() {
    use crate::peer_states::{Observed, PeerStates};
    use crate::protocol::peer_state::MachineLink;
    use std::time::Duration;

    // A spawned wait needs a 'static borrow; the test leaks its two small tables.
    let states: &'static PeerStates = Box::leak(Box::default());
    let (sender, receiver) = tokio::sync::watch::channel(None);
    let task = tokio::spawn(wait_for_scale_up(
        receiver,
        states,
        states.subscribe(),
        Duration::from_secs(10),
    ));
    sender.send(Some(Some("new-machine".into()))).unwrap();
    states.register("other-machine", 1, Observed::new(MachineLink::Connected, None, None));
    tokio::task::yield_now().await;
    assert!(!task.is_finished(), "an unrelated peer does not satisfy the wait");
    states.register("new-machine", 1, Observed::new(MachineLink::Connected, None, None));
    assert!(task.await.unwrap(), "a connected machine is used for placement");

    let states: &'static PeerStates = Box::leak(Box::default());
    let (_sender, receiver) = tokio::sync::watch::channel(None);
    let joined = tokio::spawn(wait_for_scale_up(
        receiver,
        states,
        states.subscribe(),
        Duration::from_secs(10),
    ));
    tokio::task::yield_now().await;
    tokio::time::advance(Duration::from_secs(10)).await;
    assert!(!joined.await.unwrap(), "the bound falls back to the existing over-cap start");

    let states = PeerStates::default();
    let (sender, receiver) = tokio::sync::watch::channel(None);
    let _ = sender.send(Some(None));
    let failed =
        wait_for_scale_up(receiver, &states, states.subscribe(), Duration::from_secs(1)).await;
    assert!(!failed, "a provider failure falls back immediately");

    assert!(!should_wait_for_scale_up(false, true), "an explicit machine never waits");
    assert!(should_wait_for_scale_up(true, true), "a movable create waits with no room");
    assert!(!should_wait_for_scale_up(true, false), "a peer with room takes it at once");
}
