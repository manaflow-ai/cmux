use super::*;

fn addr(text: &str) -> SocketAddr {
    text.parse().unwrap()
}

fn targets(paths: &mut MeshPaths, now: Instant) -> Vec<SocketAddr> {
    let mut out = Vec::new();
    paths.send(now, |address| out.push(address));
    out
}

/// Ping every path, and answer the pings on `answering`.
fn probe_round(paths: &mut MeshPaths, answering: &[SocketAddr], now: Instant) {
    let due = paths.poll(now);
    for (id, probe) in due.pings {
        let address = paths.address_of(id).unwrap();
        if answering.contains(&address) {
            paths.pong(id, probe, address, now + std::time::Duration::from_millis(1));
        }
    }
}

#[test]
fn until_the_peer_answers_a_probe_datagrams_follow_its_latest_source() {
    let now = Instant::now();
    let lan = addr("192.168.1.20:4101");
    let mut paths = MeshPaths::new(Some(lan), &[], &[], now);
    assert_eq!(targets(&mut paths, now), vec![lan]);
    let roamed = addr("[::ffff:10.0.0.9]:4101");
    paths.heard(roamed, true, &[], now);
    assert_eq!(targets(&mut paths, now), vec![addr("10.0.0.9:4101")], "roams as before");
}

#[test]
fn an_advertised_address_carries_data_only_once_a_probe_answered_there() {
    let now = Instant::now();
    let lan = addr("192.168.1.20:4101");
    let tailnet = addr("100.64.0.20:4101");
    let mut paths = MeshPaths::new(Some(lan), &[], &[], now);
    paths.advertised(&[tailnet, addr("0.0.0.0:1"), addr("10.0.0.1:0")], &[], now);
    assert_eq!(paths.views().len(), 2, "unspecified and port 0 are ignored");
    // Only the LAN answers: the tailnet address never gets data.
    probe_round(&mut paths, &[lan], now);
    assert_eq!(targets(&mut paths, now), vec![lan]);
    let lost = now + std::time::Duration::from_secs(2);
    let _ = paths.poll(lost);
    assert!(!targets(&mut paths, lost).contains(&tailnet));
}

#[test]
fn a_quiet_chosen_path_sprays_every_proven_path_then_falls_back() {
    let start = Instant::now();
    let lan = addr("192.168.1.20:4101");
    let relay = addr("203.0.113.5:4101");
    let candidates = [
        PeerCandidate { address: lan, kind: Some(PathKind::DirectLan) },
        PeerCandidate { address: relay, kind: Some(PathKind::DoRelay) },
    ];
    let mut paths = MeshPaths::new(Some(lan), &candidates, &[], start);
    probe_round(&mut paths, &[lan, relay], start);
    assert_eq!(targets(&mut paths, start), vec![lan], "a direct path beats the relay");
    // The LAN goes quiet: datagrams out, nothing back.
    let mut now = start;
    let mut sprayed = false;
    for _ in 0..100 {
        now += std::time::Duration::from_millis(50);
        probe_round(&mut paths, &[relay], now);
        let sent = targets(&mut paths, now);
        sprayed |= sent.len() == 2;
        if sent == vec![relay] {
            break;
        }
    }
    assert!(sprayed, "every proven path while the LAN is suspect");
    assert_eq!(targets(&mut paths, now), vec![relay]);
    assert!(now - start < std::time::Duration::from_secs(5), "fell back after {:?}", now - start);
}

#[test]
fn a_slow_chosen_path_that_loses_a_probe_probes_the_others_at_once() {
    let ms = std::time::Duration::from_millis;
    let start = Instant::now();
    let lan = addr("192.168.1.20:4101");
    let relay = addr("203.0.113.5:4101");
    let candidates = [
        PeerCandidate { address: lan, kind: Some(PathKind::DirectLan) },
        PeerCandidate { address: relay, kind: Some(PathKind::DoRelay) },
    ];
    let mut paths = MeshPaths::new(Some(lan), &candidates, &[], start);
    // A 400 ms LAN: four round trips of silence outlast the 1 s probe
    // timeout, so the chosen path turns suspect by a lost probe. Answer
    // everything for 2 s, so each path is on its alive interval (the
    // relay's next probe is 30 s out).
    let mut now = start;
    while now < start + ms(2000) {
        for (id, probe) in paths.poll(now).pings {
            let address = paths.address_of(id).unwrap();
            paths.pong(id, probe, address, now + ms(400));
        }
        now += ms(10);
    }
    assert_eq!(targets(&mut paths, now), vec![lan]);
    // The LAN is cut; nothing is answered from here on.
    let mut refreshed = None;
    for _ in 0..1000 {
        now += ms(10);
        let due = paths.poll(now);
        let sprayed = targets(&mut paths, now).len() == 2;
        if due.pings.iter().any(|(id, _)| paths.address_of(*id) == Some(relay)) {
            refreshed = Some((now, sprayed));
            break;
        }
    }
    let (at, sprayed) = refreshed.expect("the relay is probed before its 30 s turn");
    assert!(sprayed, "the relay is probed when the LAN turns suspect, at {:?}", at - start);
}

#[test]
fn a_thunderbolt_address_learned_before_the_bridge_came_up_wins_once_it_is_up() {
    let ms = std::time::Duration::from_millis;
    let start = Instant::now();
    let wan = addr("198.51.100.20:4101");
    let bridge = addr("10.254.2.2:4101");
    // Before the cable: no interface on the bridge's network, so its
    // address is routed like the WAN one.
    let before = vec![LocalNetwork {
        interface: "en0".into(),
        address: "192.168.1.10".parse().unwrap(),
        prefix: 24,
    }];
    let mut paths = MeshPaths::new(Some(wan), &[], &before, start);
    paths.advertised(&[bridge], &before, start);
    // The WAN answers first and is held; the bridge is 1 ms faster,
    // under the 3 ms margin, so RTT alone never moves the session.
    let mut now = start;
    for _ in 0..3 {
        for (id, probe) in paths.poll(now).pings {
            let address = paths.address_of(id).unwrap();
            let rtt = if address == wan { ms(2) } else { ms(1) };
            paths.pong(id, probe, address, now + rtt);
        }
        now += ms(6000);
    }
    assert_eq!(targets(&mut paths, now), vec![wan]);
    // The bridge comes up.
    let mut after = before.clone();
    after.push(LocalNetwork {
        interface: "bridge0".into(),
        address: "10.254.2.1".parse().unwrap(),
        prefix: 30,
    });
    paths.reclassify(&after, now);
    let due = paths.poll(now);
    assert!(
        due.pings.iter().any(|(id, _)| paths.address_of(*id) == Some(bridge)),
        "the reclassified path is probed at once"
    );
    for (id, probe) in due.pings {
        let address = paths.address_of(id).unwrap();
        paths.pong(id, probe, address, now + ms(1));
    }
    assert_eq!(targets(&mut paths, now + ms(1)), vec![bridge]);
}

#[test]
fn the_path_set_is_bounded_and_keeps_the_chosen_path() {
    let now = Instant::now();
    let lan = addr("192.168.1.20:4101");
    let mut paths = MeshPaths::new(Some(lan), &[], &[], now);
    probe_round(&mut paths, &[lan], now);
    for port in 1..40 {
        paths.advertised(&[SocketAddr::new([10, 0, 0, 1].into(), port)], &[], now);
        paths.heard(SocketAddr::new([10, 0, 1, 1].into(), port), true, &[], now);
    }
    let views = paths.views();
    assert_eq!(views.len(), MAX_PATHS);
    assert!(views.iter().any(|view| view.address == lan && view.current));
}

#[test]
fn a_pong_counts_only_from_the_address_its_probe_went_to() {
    let now = Instant::now();
    let lan = addr("192.168.1.20:4101");
    let elsewhere = addr("198.51.100.7:4101");
    let mut paths = MeshPaths::new(Some(lan), &[], &[], now);
    paths.advertised(&[elsewhere], &[], now);
    let due = paths.poll(now);
    let later = now + std::time::Duration::from_millis(1);
    for (id, probe) in due.pings {
        // The peer answers every probe from its own address.
        paths.pong(id, probe, lan, later);
    }
    assert_eq!(targets(&mut paths, later), vec![lan]);
    let elsewhere_view = paths.views().into_iter().find(|view| view.address == elsewhere);
    assert_ne!(elsewhere_view.map(|view| view.state), Some(PathState::Alive));
}

#[test]
fn probe_ids_are_not_sequential_across_polls() {
    let now = Instant::now();
    let lan = addr("192.168.1.20:4101");
    let relay = addr("203.0.113.5:4101");
    let mut paths = MeshPaths::new(Some(lan), &[relay.into()], &[], now);
    let first: Vec<u64> = paths.poll(now).pings.iter().map(|(_, probe)| *probe).collect();
    let later = now + std::time::Duration::from_secs(2);
    let second: Vec<u64> = paths.poll(later).pings.iter().map(|(_, probe)| *probe).collect();
    assert!(!first.is_empty() && !second.is_empty());
    assert!(second.iter().all(|probe| first.iter().all(|before| probe.abs_diff(*before) > 1024)));
}

#[test]
fn address_churn_never_runs_out_of_path_ids() {
    let now = Instant::now();
    let lan = addr("192.168.1.20:4101");
    let mut paths = MeshPaths::new(Some(lan), &[], &[], now);
    probe_round(&mut paths, &[lan], now);
    for round in 0..4_000u32 {
        let port = 1 + (round % 60_000) as u16;
        paths.advertised(&[SocketAddr::new([10, 0, 0, 1].into(), port)], &[], now);
    }
    assert!(paths.next_id <= MAX_PATH_IDS);
    assert_eq!(paths.views().len(), MAX_PATHS);
    assert!(paths.views().iter().any(|view| view.address == lan));
    // A new address is still taken after all that churn.
    let fresh = addr("10.9.9.9:4101");
    paths.heard(fresh, true, &[], now);
    assert!(paths.views().iter().any(|view| view.address == fresh));
}

#[test]
fn a_handshake_initiation_tries_every_named_address_before_any_answer() {
    let now = Instant::now();
    let down = addr("192.168.1.20:4101");
    let up = addr("10.0.0.20:4101");
    let mut paths = MeshPaths::new(Some(down), &[down.into(), up.into()], &[], now);
    let mut sent = Vec::new();
    paths.send_initiation(now, |address| sent.push(address));
    assert_eq!(sent, vec![down, up]);
    assert_eq!(targets(&mut paths, now), vec![down], "data still follows the route");
}
