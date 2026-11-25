use std::net::{IpAddr, SocketAddr};
use std::time::Duration;

use super::{PeerPath, TailnetCarrierMode, TailnetHints, add_candidates, add_candidates_on_port};

struct Hints {
    own: Vec<IpAddr>,
    peer: Vec<IpAddr>,
    path: Option<PeerPath>,
}

impl TailnetHints for Hints {
    fn path_hint(&self, _ip: IpAddr) -> Option<PeerPath> {
        self.path.clone()
    }

    fn self_ips(&self) -> Vec<IpAddr> {
        self.own.clone()
    }

    fn peer_ips(&self, _host: &str) -> Vec<IpAddr> {
        self.peer.clone()
    }
}

fn address(value: &str) -> SocketAddr {
    value.parse().expect("socket address")
}

#[test]
fn disabled_leaves_the_existing_race_unchanged() {
    let existing = [address("192.0.2.10:7319")];
    let hints = Hints {
        own: vec!["100.64.0.2".parse().unwrap()],
        peer: vec!["100.64.0.3".parse().unwrap()],
        path: Some(PeerPath::Direct { endpoint: address("198.51.100.3:41641") }),
    };
    assert_eq!(add_candidates(&existing, "peer", TailnetCarrierMode::Off, &hints), existing);
}

#[test]
fn direct_tailnet_address_is_added_before_the_existing_route() {
    let existing = [address("192.0.2.10:7319")];
    let hints = Hints {
        own: vec!["100.64.0.2".parse().unwrap()],
        peer: vec!["100.64.0.3".parse().unwrap()],
        path: Some(PeerPath::Direct { endpoint: address("198.51.100.3:41641") }),
    };
    assert_eq!(
        add_candidates(&existing, "peer", TailnetCarrierMode::DirectOnly, &hints),
        [address("100.64.0.3:7319"), existing[0]]
    );
}

#[test]
fn direct_candidates_keep_the_explicit_dial_port_and_preserve_hint_order() {
    let existing = [address("[2001:db8::10]:7319")];
    let hints = Hints {
        own: vec!["100.64.0.2".parse().unwrap(), "100.64.0.4".parse().unwrap()],
        peer: vec!["100.64.0.3".parse().unwrap(), "100.64.0.5".parse().unwrap()],
        path: Some(PeerPath::Direct { endpoint: address("198.51.100.3:41641") }),
    };
    assert_eq!(
        super::direct_candidates("peer", 8443, TailnetCarrierMode::DirectOnly, &hints),
        [address("100.64.0.3:8443"), address("100.64.0.5:8443")]
    );
    assert_eq!(
        add_candidates_on_port(&existing, "peer", 8443, TailnetCarrierMode::DirectOnly, &hints),
        [address("100.64.0.3:8443"), address("100.64.0.5:8443"), existing[0]]
    );
}

#[test]
fn direct_tailnet_prefix_beats_an_ordinary_ipv6_result() {
    let addresses = [address("100.64.0.3:7319"), address("[2001:db8::10]:7319")];
    assert_eq!(super::super::hedge::v6_first_after_prefix(&addresses, 1), addresses);
}

#[test]
fn derp_tailnet_address_is_skipped_even_when_on_is_requested() {
    let existing = [address("192.0.2.10:7319")];
    let hints = Hints {
        own: vec!["100.64.0.2".parse().unwrap()],
        peer: vec!["100.64.0.3".parse().unwrap()],
        path: Some(PeerPath::Derp),
    };
    assert_eq!(add_candidates(&existing, "peer", TailnetCarrierMode::On, &hints), existing);
}

#[tokio::test(start_paused = true)]
async fn a_blackholed_tailnet_candidate_falls_back_on_the_next_hedge() {
    let existing = [address("192.0.2.10:7319")];
    let hints = Hints {
        own: vec!["100.64.0.2".parse().unwrap()],
        peer: vec!["100.64.0.3".parse().unwrap()],
        path: Some(PeerPath::Direct { endpoint: address("198.51.100.3:41641") }),
    };
    let candidates = add_candidates(&existing, "peer", TailnetCarrierMode::DirectOnly, &hints);
    assert_eq!(candidates, [address("100.64.0.3:7319"), existing[0]]);

    let started = tokio::time::Instant::now();
    let connected = super::super::hedge::connect(
        &candidates,
        super::super::hedge::HedgePolicy {
            stagger: Duration::from_millis(10),
            attempt_timeout: Duration::from_millis(50),
            max_in_flight: 2,
            max_attempts: 2,
        },
        |target| async move {
            if target == address("100.64.0.3:7319") {
                tokio::time::sleep(Duration::from_millis(100)).await;
                Err(std::io::Error::new(std::io::ErrorKind::TimedOut, "tailnet black hole"))
            } else {
                Ok(target)
            }
        },
    )
    .await
    .expect("ordinary route should win when tailnet is black-holed");
    assert_eq!(connected, existing[0]);
    eprintln!("blackholed tailnet fallback: won after {:?} (virtual)", started.elapsed());
    assert!(started.elapsed() < Duration::from_millis(80));
}

// ---- LocalApiTailnetHints over a fake tailscaled view

fn local_view(peers: &str) -> std::sync::Arc<cmux_tailnet_local::TailnetView> {
    let json = format!(
        r#"{{"BackendState":"Running","Self":{{"ID":"me","HostName":"mac","DNSName":"mac.tail1.ts.net.","TailscaleIPs":["100.64.0.1"]}},"Peer":{{{peers}}}}}"#
    );
    std::sync::Arc::new(
        cmux_tailnet_local::parse_status(json.as_bytes(), cmux_tailnet_local::Source::Supplied)
            .expect("fake status"),
    )
}

fn local_hints(
    view: std::sync::Arc<cmux_tailnet_local::TailnetView>,
    reads: &std::sync::Arc<std::sync::atomic::AtomicUsize>,
) -> super::LocalApiTailnetHints {
    let reads = reads.clone();
    super::LocalApiTailnetHints::with_reader(std::sync::Arc::new(move || {
        reads.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        Some(view.clone())
    }))
}

const DIRECT_BOX: &str = r#""k1":{"ID":"box","HostName":"box","DNSName":"box.tail1.ts.net.","TailscaleIPs":["100.64.0.2"],"CurAddr":"192.0.2.10:41641","Relay":"sfo","Online":true,"Active":true}"#;
const DERP_BOX: &str = r#""k1":{"ID":"box","HostName":"box","DNSName":"box.tail1.ts.net.","TailscaleIPs":["100.64.0.2"],"CurAddr":"","Relay":"sfo","Online":true,"Active":true}"#;
const RELAY_BOX: &str = r#""k1":{"ID":"box","HostName":"box","DNSName":"box.tail1.ts.net.","TailscaleIPs":["100.64.0.2"],"PeerRelay":"192.0.2.99:7777:vni:3","Online":true,"Active":true}"#;
const IDLE_BOX: &str = r#""k1":{"ID":"box","HostName":"box","DNSName":"box.tail1.ts.net.","TailscaleIPs":["100.64.0.2"],"Relay":"sfo","Online":true,"Active":false}"#;
const OFFLINE_BOX: &str = r#""k1":{"ID":"box","HostName":"box","DNSName":"box.tail1.ts.net.","TailscaleIPs":["100.64.0.2"],"Online":false}"#;

#[test]
fn a_localapi_direct_hint_becomes_the_first_candidate() {
    let reads = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let hints = local_hints(local_view(DIRECT_BOX), &reads);
    let existing = [address("192.0.2.50:7319")];
    for host in ["box", "box.tail1.ts.net", "box.tail1.ts.net.", "100.64.0.2"] {
        assert_eq!(
            add_candidates(&existing, host, TailnetCarrierMode::DirectOnly, &hints),
            [address("100.64.0.2:7319"), existing[0]],
            "{host}"
        );
    }
    assert_eq!(
        hints.path_hint("100.64.0.2".parse().unwrap()),
        Some(PeerPath::Direct { endpoint: address("192.0.2.10:41641") })
    );
}

#[test]
fn derp_peer_relay_idle_and_offline_localapi_hints_are_never_candidates() {
    let reads = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let existing = [address("192.0.2.50:7319")];
    for (peer, path) in [
        (DERP_BOX, PeerPath::Derp),
        (RELAY_BOX, PeerPath::PeerRelay),
        (IDLE_BOX, PeerPath::Unknown),
        (OFFLINE_BOX, PeerPath::Unknown),
    ] {
        let hints = local_hints(local_view(peer), &reads);
        assert_eq!(hints.path_hint("100.64.0.2".parse().unwrap()), Some(path.clone()));
        for mode in [TailnetCarrierMode::DirectOnly, TailnetCarrierMode::On] {
            assert_eq!(add_candidates(&existing, "box", mode, &hints), existing, "{path:?}");
        }
    }
}

#[test]
fn the_setting_off_reads_no_localapi_view() {
    let reads = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let hints = local_hints(local_view(DIRECT_BOX), &reads);
    let existing = [address("192.0.2.50:7319")];
    assert_eq!(add_candidates(&existing, "box", TailnetCarrierMode::Off, &hints), existing);
    assert!(super::direct_candidates("box", 7319, TailnetCarrierMode::Off, &hints).is_empty());
    assert_eq!(reads.load(std::sync::atomic::Ordering::SeqCst), 0, "off reads nothing");
    // And the composition root hands out the no-op source, so no snapshot thread starts.
    let off = super::hints_for_mode(TailnetCarrierMode::Off);
    assert!(off.self_ips().is_empty() && off.peer_ips("box").is_empty());
}

#[test]
fn no_view_or_a_stopped_tailscaled_gives_no_candidate() {
    let existing = [address("192.0.2.50:7319")];
    let none = super::LocalApiTailnetHints::with_reader(std::sync::Arc::new(|| None));
    assert_eq!(add_candidates(&existing, "box", TailnetCarrierMode::DirectOnly, &none), existing);
    let json = br#"{"BackendState":"Stopped","Self":{"ID":"me","TailscaleIPs":["100.64.0.1"]},"Peer":{"k1":{"ID":"box","HostName":"box","TailscaleIPs":["100.64.0.2"],"CurAddr":"192.0.2.10:41641","Online":true}}}"#;
    let stopped = std::sync::Arc::new(
        cmux_tailnet_local::parse_status(json, cmux_tailnet_local::Source::Supplied).unwrap(),
    );
    let hints = super::LocalApiTailnetHints::with_reader(std::sync::Arc::new(move || {
        Some(stopped.clone())
    }));
    assert_eq!(add_candidates(&existing, "box", TailnetCarrierMode::DirectOnly, &hints), existing);
}

/// The default (direct-only) with tailscaled absent or hung: each race reads the
/// cached snapshot from memory, never waits on tailscaled, and adds no candidate.
#[test]
fn an_absent_or_hung_tailscaled_never_delays_a_race() {
    use std::sync::Arc;
    use std::time::Instant;

    use cmux_tailnet_local::{Error, Fetcher, SnapshotConfig, TailnetLocal};

    const RACES: u32 = 2_000;
    let existing = [address("192.0.2.50:7319")];
    let absent: Fetcher = Arc::new(|_| Err(Error::Unavailable("no tailscaled")));
    let hung: Fetcher = Arc::new(|_| {
        std::thread::sleep(Duration::from_secs(2));
        Err(Error::Timeout)
    });
    let off = super::hints_for_mode(TailnetCarrierMode::Off);
    let mut sources: Vec<(&str, TailnetCarrierMode, Arc<dyn TailnetHints>)> =
        vec![("off", TailnetCarrierMode::Off, off)];
    for (name, fetch) in [("absent", absent), ("hung", hung)] {
        let local = Arc::new(TailnetLocal::with_fetcher(SnapshotConfig::default(), fetch));
        let hints = super::LocalApiTailnetHints::with_reader(Arc::new(move || local.snapshot()));
        sources.push((name, TailnetCarrierMode::DirectOnly, Arc::new(hints)));
    }
    for (name, mode, hints) in sources {
        let mut each = Vec::with_capacity(RACES as usize);
        for _ in 0..RACES {
            let started = Instant::now();
            let candidates = add_candidates(&existing, "box", mode, hints.as_ref());
            each.push(started.elapsed());
            assert_eq!(candidates, existing, "{name}: no tailnet candidate");
        }
        each.sort();
        let mean = each.iter().sum::<Duration>() / RACES;
        let p99 = each[each.len() * 99 / 100];
        let worst = each[each.len() - 1];
        eprintln!("tailnet race cost {name} ({mode:?}): mean {mean:?} p99 {p99:?} worst {worst:?}");
        assert!(mean < Duration::from_millis(1), "{name}: mean {mean:?} per race");
        assert!(p99 < Duration::from_millis(1), "{name}: p99 {p99:?} per race");
    }
}
