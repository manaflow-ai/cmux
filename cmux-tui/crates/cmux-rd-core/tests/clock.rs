//! The session clock estimator (rd change C8).

use cmux_rd_core::clock::{BURST_INTERVAL_US, ClockEstimator, PING_BURST, PING_INTERVAL_US};
use cmux_rd_proto::{ClockEstimate, ClockPong};

/// The host's answer to `ping` when the host clock is `offset` ahead, the
/// path takes `up` and `down` microseconds and the host turns around in `turn`.
fn pong(seq: u32, t_viewer: u64, offset: i64, up: u64, turn: u64) -> ClockPong {
    let rx = (t_viewer + up) as i64 + offset;
    ClockPong {
        seq,
        t_viewer_us: t_viewer,
        t_host_rx_us: rx as u64,
        t_host_tx_us: rx as u64 + turn,
    }
}

#[test]
fn a_symmetric_path_gives_the_exact_offset_and_rtt() {
    let mut c = ClockEstimator::new();
    assert_eq!(c.estimate(), None);
    let ping = c.ping(1_000_000).expect("first ping at once");
    let p = pong(ping.seq, ping.t_viewer_us, 5_000, 3_000, 100);
    assert!(c.on_pong(&p, 1_000_000 + 3_000 + 100 + 3_000));
    assert_eq!(c.estimate(), Some(ClockEstimate { offset_us: 5_000, rtt_us: 6_000 }));
}

#[test]
fn the_minimum_rtt_sample_wins_and_unknown_pongs_are_ignored() {
    let mut c = ClockEstimator::new();
    let mut now = 10_000_000;
    // A queued sample (asymmetric 40 ms up) first, then a clean one.
    let a = c.ping(now).expect("ping");
    assert!(c.on_pong(&pong(a.seq, a.t_viewer_us, -2_000, 40_000, 0), now + 41_000));
    now += BURST_INTERVAL_US;
    let b = c.ping(now).expect("ping");
    assert!(c.on_pong(&pong(b.seq, b.t_viewer_us, -2_000, 1_000, 0), now + 2_000));
    assert_eq!(c.estimate(), Some(ClockEstimate { offset_us: -2_000, rtt_us: 2_000 }));
    // A pong for a seq never sent, or answered twice, changes nothing.
    assert!(!c.on_pong(&pong(999, now, 0, 1, 0), now + 10));
    assert!(!c.on_pong(&pong(b.seq, b.t_viewer_us, -2_000, 1_000, 0), now + 2_000));
    // The next ping carries the estimate for the host.
    now += BURST_INTERVAL_US;
    assert_eq!(c.ping(now).expect("ping").estimate, c.estimate());
}

#[test]
fn pings_come_in_a_short_burst_then_once_a_second() {
    let mut c = ClockEstimator::new();
    let mut times = Vec::new();
    let mut now = 0;
    for _ in 0..20 {
        if times.len() == PING_BURST as usize + 2 {
            break;
        }
        if c.ping(now).is_some() {
            times.push(now);
        }
        now = c.next_ping_us();
    }
    assert_eq!(times.len(), PING_BURST as usize + 2, "pings at {times:?}");
    let gaps: Vec<u64> = times.windows(2).map(|w| w[1] - w[0]).collect();
    assert!(gaps[..PING_BURST as usize - 1].iter().all(|g| *g == BURST_INTERVAL_US), "{gaps:?}");
    assert_eq!(gaps[PING_BURST as usize], PING_INTERVAL_US);
    assert!(c.ping(now - 1).is_none(), "not before the next ping time");
}
