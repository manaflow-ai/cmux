//! Both peers initiate at tunnel start, over a link with round trips in
//! flight.
//!
//! A phone's tunnel and the Mac's each know the other's address when they
//! start (the Mac from the phone's offer, the phone from the answer), so
//! each sends a handshake initiation at once, and each has a segment queued
//! (the phone's link SYN, the Mac's own traffic). The initiations cross:
//! each side answers the other's. The driver then saw a segment queued and
//! no session, and started a fresh initiation, which made boringtun drop the
//! state the peer's response to its first initiation needed; both responses
//! were refused, round after round, until boringtun's rate limit answered
//! with cookies and its 5 s REKEY_TIMEOUT retry got through (the lte profile,
//! 70 ms: 5.6-8.8 s to the first handshake on every dial).
//!
//! Each datagram leaves three times here, as a dialer with no route chosen
//! yet sends on every candidate address of its peer. On a single copy the
//! storm ended after one wasted round (222 ms); with copies each refused
//! response is followed by another fresh initiation, and on the simulated
//! link the tunnel never came up within 20 s.
//!
//! At 73 ms round trip both connections must open well inside 500 ms: the
//! first crossed pair completes the session (148 ms: the handshake and the
//! SYN's round trip). Tokio's paused clock, so
//! durations are simulated.

use std::io;
use std::net::SocketAddr;
use std::task::{Context, Poll};
use std::time::Duration;

use cmux_transport::PathId;
use cmux_wg::testing::config_pair;
use cmux_wg::testing::sim::{LinkProfile, SimNet};
use cmux_wg::{Origin, Received, SocketPath, Underlay, WgNet};
use tokio::time::Instant;

/// Every datagram leaves `copies` times: a dialer with no route chosen yet
/// sends on every candidate address of the peer, and here they all reach
/// the same socket.
struct Copies<U> {
    inner: U,
    copies: usize,
}

impl<U: Underlay> Underlay for Copies<U> {
    fn send(&mut self, datagram: &[u8]) {
        for _ in 0..self.copies {
            self.inner.send(datagram);
        }
    }

    fn send_on(&mut self, path: PathId, datagram: &[u8]) {
        self.inner.send_on(path, datagram);
    }

    fn flush(&mut self) {
        self.inner.flush();
    }

    fn backlogged(&self) -> bool {
        self.inner.backlogged()
    }

    fn poll_flush(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        self.inner.poll_flush(cx)
    }

    fn poll_recv(&mut self, cx: &mut Context<'_>, buffer: &mut [u8]) -> Poll<io::Result<Received>> {
        self.inner.poll_recv(cx, buffer)
    }

    fn authenticated(&mut self, origin: Origin) {
        self.inner.authenticated(origin);
    }

    fn has_peer(&self) -> bool {
        self.inner.has_peer()
    }

    fn peer_hint(&self) -> Option<SocketAddr> {
        self.inner.peer_hint()
    }
}

const PHONE: &str = "192.0.2.96:51820";
const MAC: &str = "192.0.2.97:51820";

fn addr(text: &str) -> SocketAddr {
    text.parse().expect("literal address")
}

#[tokio::test(start_paused = true)]
async fn crossed_initiations_open_both_connections_within_a_few_round_trips() {
    let sim = SimNet::new();
    // 36.5 ms each way: the 73 ms round trip of a phone on LTE.
    let link = LinkProfile { latency: Duration::from_micros(36_500), ..LinkProfile::default() };
    sim.set_link(addr(PHONE), addr(MAC), link);
    let configs = config_pair(addr(MAC));
    // Each side starts knowing the other's address, so each initiates at start.
    // Three candidate addresses each way (loopback, LAN, tailnet in the
    // phone harness), all reaching the one socket.
    let copies = 3;
    let mac = WgNet::start_with_underlay(
        configs.server,
        Copies { inner: SocketPath::new(sim.bind(addr(MAC)).unwrap(), Some(addr(PHONE))), copies },
    )
    .unwrap();
    let phone = WgNet::start_with_underlay(
        configs.client,
        Copies { inner: SocketPath::new(sim.bind(addr(PHONE)).unwrap(), Some(addr(MAC))), copies },
    )
    .unwrap();
    let mut mac_listener = mac.listen(7000).await.unwrap();
    tokio::spawn(async move { while mac_listener.accept().await.is_some() {} });
    let mut phone_listener = phone.listen(7001).await.unwrap();
    tokio::spawn(async move { while phone_listener.accept().await.is_some() {} });

    let started = Instant::now();
    // Each side has a segment queued before any session: a SYN each way.
    let (to_mac, to_phone) = tokio::join!(
        tokio::time::timeout(
            Duration::from_secs(20),
            phone.connect(SocketAddr::new(configs.server_v4, 7000))
        ),
        tokio::time::timeout(
            Duration::from_secs(20),
            mac.connect(SocketAddr::new(configs.client_v4, 7001))
        ),
    );
    let opened = started.elapsed();
    let to_mac = to_mac.expect("phone to Mac within 20 s").expect("phone to Mac");
    let to_phone = to_phone.expect("Mac to phone within 20 s").expect("Mac to phone");
    eprintln!("both connections open after {opened:?} (simulated)");
    // The handshake and the SYN's round trip: about 150 ms here. A crossed
    // pair that never completes waits out the 5 s retry, or longer.
    assert!(opened < Duration::from_millis(500), "open after {opened:?}, not a few round trips");
    drop((to_mac, to_phone));
    phone.shutdown().await;
    mac.shutdown().await;
}
