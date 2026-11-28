use super::*;

#[test]
fn candidates_are_lan_v4_global_v6_and_the_mapping_never_tailscale_or_link_local() {
    let ok = ["192.168.1.20", "10.0.0.4", "203.0.113.9", "2001:db8::5", "fd12:3456::1"];
    let no = [
        "127.0.0.1",
        "169.254.10.1",
        "100.101.102.103",
        "fd7a:115c:a1e0::1",
        "fe80::1",
        "::1",
        "0.0.0.0",
        "224.0.0.251",
        "::ffff:192.168.1.20",
    ];
    for ip in ok {
        assert!(candidate_ip(ip.parse().unwrap()), "{ip}");
    }
    for ip in no {
        assert!(!candidate_ip(ip.parse().unwrap()), "{ip}");
    }
    let mapped: SocketAddr = "198.51.100.4:41000".parse().unwrap();
    let addresses: Vec<IpAddr> =
        ["192.168.1.20", "fe80::1", "2001:db8::5", "100.64.0.1", "192.168.1.20"]
            .iter()
            .map(|ip| ip.parse().unwrap())
            .collect();
    let candidates = local_candidates(40000, addresses, Some(mapped));
    let want: Vec<SocketAddr> = ["198.51.100.4:41000", "[2001:db8::5]:40000", "192.168.1.20:40000"]
        .iter()
        .map(|a| a.parse().unwrap())
        .collect();
    assert_eq!(candidates, want, "the mapping first, then IPv6, then LAN IPv4, once each");
}

#[test]
fn the_off_switch_reads_zero_false_off_and_no() {
    assert!(enabled_by(None));
    assert!(enabled_by(Some("1")));
    for off in ["0", "false", "off", "no", " 0 "] {
        assert!(!enabled_by(Some(off)), "{off}");
    }
}

#[test]
fn an_offer_is_one_json_line() {
    let offer = Offer { candidates: vec!["192.168.1.20:40000".parse().unwrap()] };
    let line = serde_json::to_string(&offer).unwrap();
    assert_eq!(line, r#"{"candidates":["192.168.1.20:40000"]}"#);
    assert_eq!(serde_json::from_str::<Offer>(&line).unwrap(), offer);
}

#[tokio::test]
async fn both_sides_opening_toward_each_other_connect_from_their_listening_ports() {
    let a = punch_listener(0).unwrap();
    let b = punch_listener(0).unwrap();
    let (pa, pb) = (a.local_addr().unwrap().port(), b.local_addr().unwrap().port());
    let to_b: SocketAddr = format!("127.0.0.1:{pb}").parse().unwrap();
    let to_a: SocketAddr = format!("127.0.0.1:{pa}").parse().unwrap();
    let (to_b, to_a) = ([to_b], [to_a]);
    let (from_a, from_b) =
        tokio::join!(open_toward(pa, &to_b, PUNCH_WINDOW), open_toward(pb, &to_a, PUNCH_WINDOW));
    // One connection opens. Where both listen (loopback, an open NAT) the first connect meets
    // the other's listener, which accepts it (`serve_direct` in the daemon), and the other
    // side's own connect then names the same pair of addresses; a simultaneous open gives both
    // sides that one connection instead.
    let (tcp, at, listener, from_port) = match (from_a, from_b) {
        (Some((tcp, at)), _) => (tcp, at, &b, pa),
        (None, Some((tcp, at))) => (tcp, at, &a, pb),
        (None, None) => panic!("neither side connected"),
    };
    assert_eq!(tcp.local_addr().unwrap().port(), from_port, "from the listening port");
    assert_eq!(at.port(), listener.local_addr().unwrap().port());
    let accepted = tokio::time::timeout(Duration::from_secs(2), listener.accept()).await;
    let (_, peer) = accepted.expect("the other side's listener accepts").unwrap();
    assert_eq!(peer.port(), from_port, "the accepted connection came from the listening port");
}

#[tokio::test]
async fn a_candidate_nobody_answers_ends_with_the_window() {
    let closed = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let to = closed.local_addr().unwrap();
    drop(closed);
    let listener = punch_listener(0).unwrap();
    let started = Instant::now();
    let found =
        open_toward(listener.local_addr().unwrap().port(), &[to], Duration::from_millis(600)).await;
    assert!(found.is_none());
    assert!(started.elapsed() < Duration::from_secs(2));
}

// ---- The NAT model: how often two machines on different networks get a direct path ----

#[derive(Clone, Copy, Debug, PartialEq)]
enum V4 {
    /// Endpoint-independent mapping and filtering (a full cone).
    EimEif,
    /// Endpoint-independent mapping, address-dependent filtering (most home routers).
    EimAdf,
    /// Address-and-port-dependent mapping (symmetric; CGNAT, many carriers).
    Symmetric,
}

#[derive(Clone, Copy, Debug)]
struct Site {
    name: &'static str,
    v4: V4,
    /// The router grants a PCP or NAT-PMP mapping of the punch port.
    portmap: bool,
    /// A global IPv6 address behind a stateful firewall (inbound only from an address this
    /// side already sent to).
    v6: bool,
}

const PORT: u16 = 40000;

impl Site {
    fn lan(self, n: u8) -> IpAddr {
        IpAddr::V4(Ipv4Addr::new(192, 168, n, 20))
    }
    fn public(self, n: u8) -> IpAddr {
        IpAddr::V4(Ipv4Addr::new(198, 51, 100, n))
    }
    fn global(self, n: u8) -> IpAddr {
        format!("2001:db8:{n}::20").parse().unwrap()
    }
    /// The candidates this site offers, through the real candidate code.
    fn offer(self, n: u8) -> Vec<SocketAddr> {
        let mut addresses = vec![self.lan(n), IpAddr::V4(Ipv4Addr::new(169, 254, 1, n))];
        if self.v6 {
            addresses.push(self.global(n));
            addresses.push("fe80::20".parse().unwrap());
        }
        let mapped = self.portmap.then(|| SocketAddr::new(self.public(n), 41000 + u16::from(n)));
        local_candidates(PORT, addresses, mapped)
    }
}

/// Whether a SYN from `from` (site `n`) to `to`, one of site `m`'s candidates, opens a
/// connection, given whether `m` also sent toward `from`'s candidate of the same family (the
/// punch) before it arrived.
fn reaches(to: SocketAddr, (m, site): (u8, Site), answered: bool) -> bool {
    match to.ip() {
        // A LAN address on another network goes nowhere.
        ip if ip == site.lan(m) => false,
        // The router's explicit mapping lets anyone in, whatever its filtering.
        ip if ip == site.public(m) => site.portmap,
        // The firewall in front of a global IPv6 address: only from an address it sent to.
        ip if ip == site.global(m) => site.v6 && answered,
        _ => false,
    }
}

/// Whether two sites get a direct connection: each opens toward the other's offer (or only
/// the dialer does, `both` false, as a listen-only accepting side would).
fn direct(a: Site, b: Site, both: bool) -> bool {
    let (oa, ob) = (a.offer(1), b.offer(2));
    let family = |list: &[SocketAddr], v6: bool| list.iter().any(|c| c.is_ipv6() == v6);
    let a_to_b = usable_toward(&ob).into_iter().any(|to| {
        let answered = both && family(&usable_toward(&oa), to.is_ipv6());
        reaches(to, (2, b), answered)
    });
    let b_to_a = both
        && usable_toward(&oa)
            .into_iter()
            .any(|to| reaches(to, (1, a), family(&usable_toward(&ob), to.is_ipv6())));
    a_to_b || b_to_a
}

/// Before: the direct path was a dial by name to a private address only, so two machines on
/// different networks never got one.
fn direct_before(_: Site, _: Site) -> bool {
    false
}

fn sites() -> Vec<Site> {
    vec![
        Site { name: "home, full cone", v4: V4::EimEif, portmap: false, v6: false },
        Site { name: "home, address-filtering", v4: V4::EimAdf, portmap: false, v6: false },
        Site { name: "symmetric / CGNAT", v4: V4::Symmetric, portmap: false, v6: false },
        Site { name: "home, PCP or NAT-PMP", v4: V4::EimAdf, portmap: true, v6: false },
        Site { name: "home, dual stack", v4: V4::EimAdf, portmap: false, v6: true },
        Site { name: "mobile, CGNAT + IPv6", v4: V4::Symmetric, portmap: false, v6: true },
    ]
}

#[test]
fn the_nat_matrix_before_and_after_punching() {
    let sites = sites();
    let (mut before, mut after, mut listen_only, mut pairs) = (0, 0, 0, 0);
    let mut rows = Vec::new();
    for a in &sites {
        for b in &sites {
            pairs += 1;
            before += usize::from(direct_before(*a, *b));
            let punched = direct(*a, *b, true);
            after += usize::from(punched);
            listen_only += usize::from(direct(*a, *b, false));
            rows.push(format!(
                "{:>26} -> {:<26} {}",
                a.name,
                b.name,
                if punched { "direct" } else { "relay" }
            ));
        }
    }
    eprintln!("{}", rows.join("\n"));
    eprintln!(
        "direct: before {before}/{pairs}, listen-only accept {listen_only}/{pairs}, \
         punched {after}/{pairs}"
    );
    assert_eq!(before, 0);
    // Either side's router mapping (11 of 36 ordered pairs), or IPv6 on both (4 more).
    assert_eq!(after, 15, "{}", rows.join("\n"));
    // A side that only listens loses IPv6 behind a stateful firewall: the mapping alone.
    assert_eq!(listen_only, 6, "only pairs whose accepting side maps its port");
    // A symmetric NAT on both sides with no mapping and no IPv6 rides the relay.
    let symmetric = sites[2];
    assert!(!direct(symmetric, symmetric, true));
    // Address-dependent filtering on both sides, no mapping, IPv4 only: the relay (no
    // reflexive candidate yet).
    assert!(!direct(sites[1], sites[1], true));
    // Dual stack on both sides: direct over IPv6 only because both open.
    assert!(direct(sites[4], sites[5], true));
    assert!(!direct(sites[4], sites[5], false));
}

#[test]
fn a_far_candidate_that_is_this_machines_own_address_is_never_opened_toward() {
    // gcp-agent-lane-12, 2026-11-25 22:37:57Z: a far machine offered its docker0 172.17.0.1;
    // lane-12 has the same address, connected to its own listener on 47791 in under a
    // millisecond, and the dial then failed its handshake (`daemon key mismatch: ... got` its
    // own key) and held the machine on the relay.
    let far: Vec<SocketAddr> = ["172.17.0.1:47791", "10.138.0.105:47791", "[2001:db8::5]:47791"]
        .iter()
        .map(|a| a.parse().unwrap())
        .collect();
    let own = |ip: IpAddr| ip == "172.17.0.1".parse::<IpAddr>().unwrap();
    let toward = usable_toward_from(&far, own);
    assert_eq!(toward, far[1..].to_vec());
    // Loopback stays (two carriers on one machine in tests).
    let local: SocketAddr = "127.0.0.1:47791".parse().unwrap();
    assert_eq!(usable_toward_from(&[local], |_| true), vec![local]);
}

#[test]
fn own_address_is_any_address_a_socket_binds_to() {
    assert!(own_address("127.0.0.1".parse().unwrap()));
    // TEST-NET-1 is never assigned to a host.
    assert!(!own_address("192.0.2.77".parse().unwrap()));
    if let Some((_, ip)) =
        cmux_netwatch::usable().unwrap_or_default().into_iter().find(|(_, ip)| ip.is_ipv4())
    {
        assert!(own_address(ip), "{ip} is on an interface here");
    }
}

#[test]
fn container_and_vm_bridges_are_never_offered() {
    for name in ["docker0", "br-3f2a9c1b", "veth12ab", "virbr0", "lxdbr0", "podman0", "cni0"] {
        assert!(host_bridge(name), "{name}");
    }
    for name in ["eth0", "ens3", "en0", "wlan0", "wlp2s0", "tailscale0", "bridge0"] {
        assert!(!host_bridge(name), "{name}");
    }
}

#[test]
fn a_miss_in_a_row_doubles_the_hold_up_to_the_cap() {
    assert_eq!(hold_for(1, 0.5), PUNCH_HOLD);
    assert_eq!(hold_for(2, 0.5), PUNCH_HOLD * 2);
    assert_eq!(hold_for(3, 0.5), PUNCH_HOLD * 4);
    assert_eq!(hold_for(40, 0.5), PUNCH_HOLD_MAX);
    assert_eq!(hold_for(40, 1.0), PUNCH_HOLD_MAX, "jitter never takes it past the cap");
    assert_eq!(hold_for(1, 0.0), PUNCH_HOLD.mul_f64(0.75));
}

/// Punches started toward one machine whose every punch fails, asked for once a second for
/// `hours`, with the hold this file applies.
fn punches_toward_a_failing_peer(hours: u64) -> u32 {
    let punches = Punches::default();
    let start = Instant::now();
    let mut started = 0;
    for second in 0..hours * 3600 {
        let now = start + Duration::from_secs(second);
        if punches.held_off_at("far", now) || !punches.may_start("far", CircuitLane::Cheap, now) {
            continue;
        }
        started += 1;
        punches.miss_at("far", now, 0.5);
    }
    started
}

/// cosmic-gray, 2026-11-27: 18.5k punch attempts across about 200 peers. Before: a flat
/// 120 s hold, 30 punches an hour per failing peer (6,000 an hour at 200 peers). After: 6 in
/// the first hour, then one an hour.
#[test]
fn a_peer_whose_every_punch_fails_is_punched_a_few_times_an_hour_not_every_two_minutes() {
    let first_hour = punches_toward_a_failing_peer(1);
    assert!(first_hour <= 6, "{first_hour} punches in the first hour");
    let day = punches_toward_a_failing_peer(24);
    assert!(day <= 6 + 23, "{day} punches in a day");
}

#[test]
fn a_punch_asked_for_again_soon_after_one_connected_is_churn_and_holds_off() {
    let punches = Punches::default();
    let t0 = Instant::now();
    punches.connected_at("far", CircuitLane::Cheap, t0);
    // Its link dropped a minute later and a dial asks again: churn, not a new punch.
    let t1 = t0 + Duration::from_secs(60);
    assert!(!punches.may_start("far", CircuitLane::Cheap, t1));
    assert!(punches.held_off_at("far", t1));
    assert_eq!(punches.hold("far").map(|h| h.misses), Some(1));
    // Each churned link in a row holds longer.
    let t2 = punches.hold("far").unwrap().until + Duration::from_secs(1);
    assert!(punches.may_start("far", CircuitLane::Cheap, t2));
    punches.connected_at("far", CircuitLane::Cheap, t2);
    let t3 = t2 + Duration::from_secs(30);
    assert!(!punches.may_start("far", CircuitLane::Cheap, t3));
    assert_eq!(punches.hold("far").map(|h| h.misses), Some(2));
    assert!(punches.hold("far").unwrap().until >= t3 + PUNCH_HOLD * 2 - Duration::from_secs(60));
    // A punched link that lasted `PUNCH_STABLE` forgets the misses.
    let t4 = punches.hold("far").unwrap().until + Duration::from_secs(1);
    assert!(punches.may_start("far", CircuitLane::Cheap, t4));
    punches.connected_at("far", CircuitLane::Cheap, t4);
    let t5 = t4 + PUNCH_STABLE + Duration::from_secs(1);
    assert!(punches.may_start("far", CircuitLane::Cheap, t5));
    assert!(punches.hold("far").is_none());
}

#[test]
fn at_most_a_few_punches_run_at_once_across_every_peer() {
    let punches = Punches::default();
    for n in 0..MAX_PUNCHES_AT_ONCE {
        assert!(punches.claim(&format!("peer-{n}"), CircuitLane::Cheap));
    }
    assert!(
        !punches.claim("one-more", CircuitLane::Cheap),
        "past the cap the dial rides the relay"
    );
    assert!(!punches.claim("peer-0", CircuitLane::Cheap), "one at a time per machine and lane");
    punches.release("peer-0", CircuitLane::Cheap);
    assert!(punches.claim("one-more", CircuitLane::Cheap));
    assert_eq!(punches.stats.capped.load(std::sync::atomic::Ordering::Relaxed), 1);
}

#[test]
fn at_most_a_few_offers_are_answered_at_once() {
    let punches = Punches::default();
    let slots: Vec<_> = (0..MAX_ANSWERS_AT_ONCE).map(|_| punches.answer_slot()).collect();
    assert!(slots.iter().all(Option::is_some));
    assert!(punches.answer_slot().is_none());
    drop(slots);
    assert!(punches.answer_slot().is_some(), "a slot frees when its answer ends");
}
