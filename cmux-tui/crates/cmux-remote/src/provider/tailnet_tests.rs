use std::net::{IpAddr, SocketAddr};

use super::{PeerPath, TailnetCarrierMode, TailnetHints, add_candidates};

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
fn derp_tailnet_address_is_skipped_even_when_on_is_requested() {
    let existing = [address("192.0.2.10:7319")];
    let hints = Hints {
        own: vec!["100.64.0.2".parse().unwrap()],
        peer: vec!["100.64.0.3".parse().unwrap()],
        path: Some(PeerPath::Derp),
    };
    assert_eq!(add_candidates(&existing, "peer", TailnetCarrierMode::On, &hints), existing);
}
