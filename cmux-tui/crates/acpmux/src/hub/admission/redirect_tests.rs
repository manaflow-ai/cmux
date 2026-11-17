use super::*;

/// The lane hosts as leo-workspace's registry has them (2026-11-16), roles included.
fn registry() -> Value {
    json!({
        "machines": {
            "huge-blue": {"roles": ["session-host"], "lanes": {"max_lanes": 12}},
            "cosmic-gray": {"roles": ["leo-mac"], "lanes": {"max_lanes": 8}},
            "big-red": {"roles": ["leo-apps"], "lanes": {"max_lanes": 6}},
            "gcp-agent-lane-3": {"roles": ["session-host"], "lanes": {
                "max_lanes": 6, "headroom_max_lanes": 12, "measured_lane_gb": 2}},
            "gcp-agent-lane-4": {"roles": ["session-host"], "lanes": {
                "max_lanes": 6, "headroom_max_lanes": 12, "measured_lane_gb": 2}},
        },
    })
}

/// A health reading: GB of RAM free, live agents.
fn health(ram_gb: f64, live: u64) -> Value {
    json!({
        "cpus": 32, "load": [2.0, 2.0, 2.0],
        "ram": {"freeBytes": (ram_gb * GB) as u64, "totalBytes": (128.0 * GB) as u64},
        "swap": {"usedBytes": 0, "totalBytes": (8.0 * GB) as u64},
        "disk": {"freeBytes": (500.0 * GB) as u64}, "liveSessions": live,
        "pressure": {"ok": true, "over": [], "cores": 32}
    })
}

fn peer(name: &str, health: Value) -> Candidate {
    Candidate { name: name.into(), local: false, health, health_at: None }
}

/// huge-blue at 51 live sessions against its cap of 12 (2026-11-16), with every kind of peer.
fn at_huge_blue<'a>(
    r: &'a Value,
    here: &'a Value,
    peers: &'a [Candidate],
    cwd: &'a Cwd,
) -> Plan<'a> {
    Plan {
        registry: Some(r),
        machine: Some("huge-blue"),
        host: "huge-blue",
        live: 51,
        here,
        peers,
        cwd,
        person: false,
        app: false,
    }
}

fn peers() -> Vec<Candidate> {
    vec![
        // A person's Mac and a Leo-apps host never take a redirected lane.
        peer("cosmic-gray", health(90.0, 0)),
        peer("big-red", health(90.0, 0)),
        // The busier GCP lane VM and the idle one: the idle one has more room.
        peer("gcp-agent-lane-3", health(30.0, 5)),
        peer("gcp-agent-lane-4", health(30.0, 1)),
    ]
}

#[test]
fn a_full_host_sends_a_recreatable_create_to_the_least_loaded_host() {
    let (r, here, peers) = (registry(), health(1.0, 51), peers());
    let checkout = Cwd::Checkout { origin: "https://github.com/manaflow-ai/cmux".into() };
    for cwd in [Cwd::None, Cwd::Scratch, checkout.clone()] {
        let placed = plan(&at_huge_blue(&r, &here, &peers, &cwd));
        let placed = placed.unwrap_or_else(|| panic!("{cwd:?} stayed on a full huge-blue"));
        assert_eq!(placed.peer, "gcp-agent-lane-4", "{cwd:?}: the least-loaded fleet host");
        assert!(placed.placed.starts_with("placed on gcp-agent-lane-4"), "{}", placed.placed);
    }
    let over = plan(&at_huge_blue(&r, &here, &peers, &checkout)).unwrap();
    let notice = notice(&over, "huge-blue", 51, &checkout, Some(Path::new("/w/cmux/lane")));
    let text = notice["warning"].as_str().unwrap();
    assert!(
        text.contains("huge-blue is full (51 live sessions")
            && text.contains("started on gcp-agent-lane-4 instead")
            && text.contains("/w/cmux/lane is a checkout of https://github.com/manaflow-ai/cmux")
            && text.contains("`wt new`"),
        "{text}"
    );
    assert_eq!(notice["redirectedTo"], "gcp-agent-lane-4");
}

#[test]
fn a_create_that_needs_this_hosts_files_stays_with_the_caps_warning() {
    let (r, here, peers) = (registry(), health(1.0, 51), peers());
    assert_eq!(plan(&at_huge_blue(&r, &here, &peers, &Cwd::Local)), None, "a local folder stays");
    // It still starts here with the cap's warning: a cap never refuses.
    let verdict = check(&Inputs {
        flag: None,
        registry: Some(&r),
        unreadable: false,
        source: Path::new("/r/fleet-registry.json"),
        machine: Some("huge-blue"),
        live: 51,
    });
    assert_eq!(verdict.over.map(|o| (o.live, o.max)), Some((51, 12)));
}

#[test]
fn the_persons_own_chat_stays_on_the_mac_they_opened_it_on() {
    let (r, here, peers) = (registry(), health(1.0, 51), peers());
    let mut at = at_huge_blue(&r, &here, &peers, &Cwd::None);
    at.app = true;
    assert_eq!(plan(&at), None, "the app's own chat stays where it was opened");
    let mut at = at_huge_blue(&r, &here, &peers, &Cwd::None);
    (at.machine, at.host, at.person) = (Some("cosmic-gray"), "cosmic-gray", true);
    assert_eq!(plan(&at), None, "the person on a person's Mac");
    // An agent's create on a person's Mac goes, as the CLI's own `new` does.
    at.person = false;
    assert_eq!(plan(&at).map(|e| e.peer).as_deref(), Some("gcp-agent-lane-4"));
}

#[test]
fn no_peer_with_room_keeps_it_here() {
    let (r, here) = (registry(), health(1.0, 51));
    let full =
        vec![peer("gcp-agent-lane-3", health(30.0, 6)), peer("gcp-agent-lane-4", health(30.0, 6))];
    assert_eq!(plan(&at_huge_blue(&r, &here, &full, &Cwd::None)), None, "overloaded: no better");
    assert_eq!(plan(&at_huge_blue(&r, &here, &[], &Cwd::None)), None, "no peer at all");
    let personal = vec![peer("cosmic-gray", health(90.0, 0))];
    assert_eq!(plan(&at_huge_blue(&r, &here, &personal, &Cwd::None)), None, "only a person's Mac");
}

#[test]
fn past_max_lanes_measured_headroom_admits_until_the_ceiling() {
    let r = registry();
    let lane = "gcp-agent-lane-3";
    assert!(!full(&r, lane, 5, &health(1.0, 5)), "under max_lanes");
    // Past max_lanes 6, under headroom_max_lanes 12: room while RAM holds 4 GB reserved + 2 GB.
    assert!(!full(&r, lane, 8, &health(10.0, 8)), "RAM holds one more measured lane");
    assert!(full(&r, lane, 8, &health(5.0, 8)), "RAM does not");
    assert!(full(&r, lane, 8, &json!({})), "no reading: max_lanes decides");
    assert!(full(&r, lane, 12, &health(90.0, 12)), "at the ceiling, whatever the RAM");
    assert!(full(&r, "huge-blue", 12, &health(90.0, 12)), "no ceiling: max_lanes");
    assert!(!full(&r, "nowhere", 99, &health(1.0, 99)), "no lanes entry: never full");
}

#[test]
fn a_folder_is_recreatable_when_scratch_or_a_checkout_with_an_origin() {
    let tmp = tempfile::tempdir().unwrap();
    let scratch = tmp.path().join("job");
    std::fs::create_dir_all(&scratch).unwrap();
    assert_eq!(Cwd::of(None, tmp.path()), Cwd::None);
    assert_eq!(Cwd::of(Some(&scratch), tmp.path()), Cwd::Scratch);
    // Outside the temporary folder: a plain folder is this host's own.
    let other = tempfile::tempdir().unwrap();
    let plain = other.path().join("notes");
    std::fs::create_dir_all(&plain).unwrap();
    assert_eq!(Cwd::of(Some(&plain), tmp.path()), Cwd::Local);
    let git = |args: &[&str]| {
        std::process::Command::new("git").arg("-C").arg(&plain).args(args).output().unwrap()
    };
    if !git(&["init", "-q"]).status.success() {
        return; // no git on this host
    }
    assert_eq!(Cwd::of(Some(&plain), tmp.path()), Cwd::Local, "a repository with no origin");
    git(&["remote", "add", "origin", "https://example.com/r.git"]);
    assert_eq!(
        Cwd::of(Some(&plain), tmp.path()),
        Cwd::Checkout { origin: "https://example.com/r.git".into() }
    );
}
