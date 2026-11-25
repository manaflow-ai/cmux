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
    assert!(started.elapsed() < Duration::from_millis(80));
}
