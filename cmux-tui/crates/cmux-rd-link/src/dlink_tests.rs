use super::*;

/// Every interface: the host routes are this machine's non-loopback addresses.
fn any() -> SocketAddr {
    "0.0.0.0:0".parse().unwrap()
}

/// Pumps both sides until `done` or 5 s; candidates cross as the stream would carry them.
fn pump(
    host: &mut DatagramLink,
    viewer: &mut DatagramLink,
    mut done: impl FnMut(&[LinkOut], &[LinkOut]) -> bool,
) -> (Vec<LinkOut>, Vec<LinkOut>) {
    let (mut h_all, mut v_all) = (Vec::new(), Vec::new());
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        let (mut h, mut v) = (Vec::new(), Vec::new());
        host.poll(&mut h);
        viewer.poll(&mut v);
        for out in &h {
            if let LinkOut::Candidate(c) = out {
                viewer.add_remote_candidate(c);
            }
        }
        for out in &v {
            if let LinkOut::Candidate(c) = out {
                host.add_remote_candidate(c);
            }
        }
        h_all.extend(h);
        v_all.extend(v);
        if done(&h_all, &v_all) {
            break;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    (h_all, v_all)
}

#[test]
fn an_offer_and_answer_bring_up_a_link_that_carries_datagrams_both_ways() {
    let offer = ViewerOffer::new(Vec::new(), Vec::new()).unwrap();
    let (mut host, host_key) = DatagramLink::respond(offer.session(), &offer.key(), any()).unwrap();
    let mut viewer = offer.start(&host_key, any()).unwrap();
    let up = LinkOut::State(LinkState::Up);
    pump(&mut host, &mut viewer, |h, v| h.contains(&up) && v.contains(&up));
    assert!(host.is_up() && viewer.is_up(), "both sides up");
    viewer.send_datagram(b"input");
    host.send_datagram(b"frame");
    let (h, v) = pump(&mut host, &mut viewer, |h, v| {
        h.contains(&LinkOut::Datagram(b"input".to_vec()))
            && v.contains(&LinkOut::Datagram(b"frame".to_vec()))
    });
    assert!(h.contains(&LinkOut::Datagram(b"input".to_vec())), "{h:?}");
    assert!(v.contains(&LinkOut::Datagram(b"frame".to_vec())), "{v:?}");
}

#[test]
fn a_viewer_given_another_hosts_key_never_comes_up() {
    let offer = ViewerOffer::new(Vec::new(), Vec::new()).unwrap();
    let (mut host, _) = DatagramLink::respond(offer.session(), &offer.key(), any()).unwrap();
    // A key the stream did not vouch for (a different host).
    let other = hex(&KeyPair::generate().unwrap().public);
    let mut viewer = offer.start(&other, any()).unwrap();
    let up = LinkOut::State(LinkState::Up);
    let (h, v) = pump(&mut host, &mut viewer, |h, v| h.contains(&up) || v.contains(&up));
    assert!(!h.contains(&up) && !v.contains(&up), "no side came up: {h:?} {v:?}");
    assert!(!host.is_up() && !viewer.is_up());
}

#[test]
fn a_key_that_is_not_64_hex_is_refused_on_both_sides() {
    let offer = ViewerOffer::new(Vec::new(), Vec::new()).unwrap();
    assert!(DatagramLink::respond(offer.session(), "zz", any()).is_err());
    assert!(ViewerOffer::new(Vec::new(), Vec::new()).unwrap().start("00", any()).is_err());
}

#[test]
fn a_stun_name_that_does_not_resolve_leaves_the_link_without_it() {
    let offer = ViewerOffer::new(vec!["stun.invalid:3478".into()], Vec::new()).unwrap();
    let (_host, host_key) = DatagramLink::respond(offer.session(), &offer.key(), any()).unwrap();
    // Starting never waits for the resolver.
    assert!(offer.start(&host_key, any()).is_ok());
}

#[test]
fn a_list_still_resolving_at_start_arrives_later() {
    let (tx, rx) = mpsc::channel();
    let (now, later) = Resolving { rx, done: None }.now_or_later();
    assert!(now.is_empty());
    let mut later = later.expect("a later list while resolving");
    assert_eq!(later(), None);
    let server: SocketAddr = "127.0.0.1:3478".parse().unwrap();
    tx.send(vec![server]).unwrap();
    assert_eq!(later(), Some(vec![server]));
    // A resolver that is gone answers with nothing, so the driver stops asking.
    let (tx, rx) = mpsc::channel::<Vec<SocketAddr>>();
    let mut later = Resolving { rx, done: None }.now_or_later().1.unwrap();
    drop(tx);
    assert_eq!(later(), Some(Vec::new()));
}

#[test]
fn a_slow_turn_lookup_never_holds_the_stun_servers() {
    fn slow(_: &[TurnName]) -> Vec<TurnServer> {
        std::thread::sleep(Duration::from_secs(5));
        Vec::new()
    }
    let turn = resolved("rd-link-turn", vec![turn_name("turn.example:3478")], slow).unwrap();
    let stun = resolved("rd-link-stun", vec!["127.0.0.1:3478".to_owned()], stun_servers).unwrap();
    let found = stun.recv_timeout(Duration::from_secs(2)).expect("STUN resolves on its own");
    assert_eq!(found, vec!["127.0.0.1:3478".parse::<SocketAddr>().unwrap()]);
    assert!(turn.try_recv().is_err(), "the TURN lookup is still running");
}

fn turn_name(addr: &str) -> TurnName {
    TurnName { addr: addr.into(), username: "alice".into(), password: "correct horse".into() }
}

#[test]
fn turn_relays_resolve_to_ipv4_with_their_credentials_and_are_bounded() {
    let names: Vec<TurnName> =
        (0..6).map(|i| turn_name(&format!("127.0.0.1:{}", 3478 + i))).collect();
    let mut all = vec![turn_name("turn.invalid:3478")];
    all.extend(names);
    let servers = turn_servers(&all);
    // The bound applies to names, before resolving: the unresolvable one takes a slot.
    assert_eq!(servers.len(), MAX_TURN - 1);
    assert!(
        servers
            .iter()
            .all(|s| s.addr.is_ipv4() && s.username == "alice" && s.password == "correct horse")
    );
    assert!(!format!("{:?}", all[1]).contains("correct horse"), "the password stays out of Debug");
}

#[test]
fn the_peers_routes_are_bounded_and_malformed_ones_dropped() {
    let offer = ViewerOffer::new(Vec::new(), Vec::new()).unwrap();
    let (mut host, _) = DatagramLink::respond(offer.session(), &offer.key(), any()).unwrap();
    host.add_remote_candidate("not a candidate");
    assert_eq!(host.remote_candidates, 0);
    for port in 0..(MAX_REMOTE_CANDIDATES as u16 + 10) {
        host.add_remote_candidate(&format!("host 127.0.0.1:{}", 20000 + port));
    }
    assert_eq!(host.remote_candidates, MAX_REMOTE_CANDIDATES);
}
