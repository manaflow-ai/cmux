//! The host side of the session clock (rd change C8): answer pings at once
//! and keep the viewer's estimate for the sources (remote-tab-r2.md B3.4).

use cmux_rd_engine::{EngineConfig, MediaEngine};
use cmux_rd_proto::{ClockEstimate, ClockPing, ClockPong, DatagramHeader, DatagramKind};

fn ping_datagram(ping: &ClockPing) -> Vec<u8> {
    let mut d = DatagramHeader {
        flags: 0,
        kind: DatagramKind::ClockPing,
        stream: 0,
        frame: 0,
        index: 0,
        count: 0,
        fec_count: 0,
        transport_seq: 0,
    }
    .encode()
    .to_vec();
    d.extend_from_slice(&ping.encode());
    d
}

#[test]
fn a_ping_is_answered_at_once_and_its_estimate_is_kept() {
    let mut e = MediaEngine::new(EngineConfig::default(), 0);
    assert_eq!(e.clock(), None);
    let estimate = ClockEstimate { offset_us: -7_000, rtt_us: 900 };
    let ping = ClockPing { seq: 3, t_viewer_us: 123_456, estimate: Some(estimate) };
    let out = e.on_datagram(&ping_datagram(&ping), false, 50_000);
    assert_eq!(out.datagrams.len(), 1, "a pong even without control");
    let (h, payload) = DatagramHeader::decode(&out.datagrams[0]).expect("pong");
    assert_eq!(h.kind, DatagramKind::ClockPong);
    let pong = ClockPong::decode(payload).expect("pong payload");
    assert_eq!(
        (pong.seq, pong.t_viewer_us, pong.t_host_rx_us, pong.t_host_tx_us),
        (3, 123_456, 50_000, 50_000)
    );
    assert_eq!(e.clock(), Some(estimate));
    // A ping without an estimate keeps the last one.
    e.on_datagram(
        &ping_datagram(&ClockPing { seq: 4, t_viewer_us: 1, estimate: None }),
        false,
        60_000,
    );
    assert_eq!(e.clock(), Some(estimate));
}
