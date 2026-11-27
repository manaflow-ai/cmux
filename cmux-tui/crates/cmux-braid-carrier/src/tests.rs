use super::*;

fn at(kind: CarrierKind, address: &str) -> Endpoint {
    Endpoint { kind, address: address.to_owned(), host: "t.example".to_owned(), login: None }
}

#[test]
fn a_firewall_rules_out_what_it_drops() {
    let udp = at(CarrierKind::TurnUdp, "t.example:3478");
    let tls443 = at(CarrierKind::TurnTls, "t.example:443");
    let tls5349 = at(CarrierKind::TurnTls, "t.example:5349");
    let hub = at(CarrierKind::LocalHub, "192.168.1.4:50000");
    let relay = at(CarrierKind::WssRelay, "relay.example:443");
    let blocked = NetFacts { udp_blocked: true, ..NetFacts::default() };
    assert!(!usable(&udp, blocked) && usable(&tls5349, blocked));
    let proxy = NetFacts { proxy_only: true, udp_blocked: true, ..NetFacts::default() };
    assert!(usable(&tls443, proxy) && usable(&relay, proxy));
    assert!(!usable(&tls5349, proxy), "a CONNECT proxy lets 443 out");
    assert!(usable(&hub, proxy), "the hub is on the LAN, not behind the proxy");
    let offline = NetFacts { internet: false, ..NetFacts::default() };
    assert!(usable(&hub, offline) && !usable(&tls443, offline) && !usable(&relay, offline));
    let relay_only = NetFacts { relay_only: true, ..NetFacts::default() };
    assert!(!usable(&hub, relay_only) && usable(&udp, relay_only));
}

#[test]
fn tls_on_443_comes_before_other_tls_and_tcp() {
    let servers = [
        at(CarrierKind::TurnTcp, "t.example:80"),
        at(CarrierKind::TurnTls, "t.example:5349"),
        at(CarrierKind::TurnUdp, "t.example:3478"),
        at(CarrierKind::TurnTls, "t.example:443"),
    ];
    let stream = [CarrierKind::TurnTls, CarrierKind::TurnTcp];
    let best_stream = best(&servers, &stream, NetFacts::default()).map(|e| e.address.as_str());
    assert_eq!(best_stream, Some("t.example:443"));
    let only_tcp = &servers[..1];
    assert_eq!(
        best(only_tcp, &stream, NetFacts::default()).map(|e| e.kind),
        Some(CarrierKind::TurnTcp)
    );
    assert_eq!(best(&servers[..2], &[CarrierKind::TurnUdp], NetFacts::default()), None);
}

#[test]
fn a_ladder_staggers_rungs_and_skips_empty_ones() {
    let servers = [
        at(CarrierKind::WssRelay, "relay.example:443"),
        at(CarrierKind::TurnTls, "t.example:443"),
        at(CarrierKind::TurnUdp, "t.example:3478"),
    ];
    let stagger = Duration::from_millis(500);
    let open = ladder(&servers, NetFacts::default(), stagger);
    let plan: Vec<_> = open.iter().map(|s| (s.endpoint.kind, s.start_after.as_millis())).collect();
    assert_eq!(
        plan,
        [(CarrierKind::TurnUdp, 0), (CarrierKind::TurnTls, 500), (CarrierKind::WssRelay, 1000)]
    );
    let blocked = ladder(&servers, NetFacts { udp_blocked: true, ..NetFacts::default() }, stagger);
    let plan: Vec<_> =
        blocked.iter().map(|s| (s.endpoint.kind, s.start_after.as_millis())).collect();
    assert_eq!(plan, [(CarrierKind::TurnTls, 0), (CarrierKind::WssRelay, 500)]);
}

#[test]
fn kinds_say_what_they_are() {
    assert_eq!(CarrierKind::TurnTcp.path_name(), "turn-tls");
    assert!(CarrierKind::WssRelay.reliable() && !CarrierKind::TurnUdp.reliable());
    assert!(CarrierKind::TurnUdp.mtu() < CarrierKind::Udp.mtu());
    assert_eq!(CarrierKind::LocalHub.cost(), CostClass::Free);
    let login = Login { user: "u".into(), secret: "hunter2".into() };
    assert!(!format!("{login:?}").contains("hunter2"));
}
