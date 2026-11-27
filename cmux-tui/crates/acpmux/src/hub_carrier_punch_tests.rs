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
