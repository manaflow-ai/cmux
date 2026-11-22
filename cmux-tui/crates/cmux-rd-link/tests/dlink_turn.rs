//! The desktop link's viewer with the platform's TURN relay (cmuxterm-hq#7976):
//! given a relay and its credentials, the viewer allocates on it and offers its
//! relayed address to the host as a `relay` candidate, the link's last path
//! before the stream. That the relay then carries a session is tests/turn.rs.

#[path = "support/fake_turn.rs"]
mod fake_turn;
#[path = "support/stun.rs"]
mod stun;

use cmux_rd_link::dlink::{DatagramLink, LinkOut, TurnName, ViewerOffer};
use fake_turn::{FakeTurn, Options};
use std::net::SocketAddr;
use std::time::{Duration, Instant};

fn any() -> SocketAddr {
    "0.0.0.0:0".parse().unwrap()
}

#[test]
fn a_viewer_with_a_turn_relay_offers_its_relayed_address() {
    let turn = FakeTurn::start(Options::default());
    let o = Options::default();
    let name = TurnName {
        addr: turn.addr.to_string(),
        username: o.username.into(),
        password: o.password.into(),
    };
    let mut offer = ViewerOffer::new(Vec::new(), vec![name]).unwrap();
    assert!(offer.wait_resolved(Duration::from_secs(5)), "the relay's address never resolved");
    let (mut host, host_key) = DatagramLink::respond(offer.session(), &offer.key(), any()).unwrap();
    let mut viewer = offer.start(&host_key, any()).unwrap();

    let relayed = |c: &str| c.starts_with("relay ");
    let mut seen = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline && !seen.iter().any(|c: &String| relayed(c)) {
        let (mut h, mut v) = (Vec::new(), Vec::new());
        host.poll(&mut h);
        viewer.poll(&mut v);
        for out in h {
            if let LinkOut::Candidate(c) = out {
                viewer.add_remote_candidate(&c);
            }
        }
        for out in v {
            if let LinkOut::Candidate(c) = out {
                host.add_remote_candidate(&c);
                seen.push(c);
            }
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(seen.iter().any(|c| relayed(c)), "no relay candidate from the viewer: {seen:?}");
    assert!(turn.stats().allocations >= 1, "the relay was never allocated");
}
