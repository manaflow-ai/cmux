use super::*;

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
    let admitted = Admitted { admitting: &admitting, made: made.clone(), warning: None };
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
        assert_eq!(at(machine, max as usize - 1), Verdict::default(), "{machine} under its cap");
        for live in [max as usize, 16] {
            let v = at(machine, live);
            assert_eq!(v.under_floor, None, "{machine} at {live}: a cap never refuses");
            assert_eq!(v.over, over(machine, live, max), "{machine} at {live}: warned");
        }
    }
    assert_eq!(at("cmux-lawrence", 50).over, None, "no lanes entry: no warning");
    let cap = over("cmux16", 16, 3).unwrap();
    let message = cap.warning(true, true, Some("placed on big-red: 31 GB RAM free"));
    assert!(
        message.contains("16 live sessions")
            && message.contains("cap of 3")
            && message.contains("lanes.max_lanes of cmux16 in /r/fleet-registry.json")
            && message.contains("started anyway")
            && message.contains("`acpmux new --machine auto` (placed on big-red: 31 GB RAM free)"),
        "the warning names the count, the cap, where it comes from and a host with room: {message}"
    );
    assert!(cap.warning(true, true, None).contains("No connected host has room"));
    let peer = cap.warning(true, false, None);
    assert!(!peer.contains("connected host"), "a peer hears of no peer: {peer}");
    let web = cap.warning(false, false, None);
    assert!(!web.contains("/r/"), "a Web client learns no path: {web}");
    assert!(!web.contains("cmux16"), "nor the machine: {web}");
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
