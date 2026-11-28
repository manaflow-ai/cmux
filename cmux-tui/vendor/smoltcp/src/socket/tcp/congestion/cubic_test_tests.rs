use crate::{socket::tcp::RttEstimator, time::Instant};

use super::*;

const MSS: usize = 1024;

#[test]
fn test_sack_loss_cuts_without_inflation() {
    let mut cubic = Cubic::new();
    cubic.set_mss(MSS);
    cubic.set_remote_window(usize::MAX);
    let in_flight = 20 * MSS;
    cubic.on_sack_loss(Instant::from_millis(0), in_flight);
    let ssthresh = (in_flight as f64 * BETA_CUBIC) as usize;
    assert_eq!(cubic.ssthresh, ssthresh);
    assert_eq!(cubic.cwnd, ssthresh);
    assert!(cubic.in_fast_recovery);
    // A second report in the same recovery changes nothing.
    cubic.on_sack_loss(Instant::from_millis(1), in_flight);
    assert_eq!(cubic.cwnd, ssthresh);
}

fn ack(cubic: &mut Cubic, len: usize, now: Instant) {
    cubic.on_ack(now, len, cubic.window().saturating_sub(MSS), &rtte())
}

#[test]
fn congestion_avoidance_credits_bytes_in_delayed_acks() {
    fn recovered() -> Cubic {
        let mut cubic = Cubic::new();
        cubic.set_mss(MSS);
        cubic.cwnd = 32 * MSS;
        cubic.on_sack_loss(Instant::from_millis(0), cubic.cwnd);
        ack(&mut cubic, MSS, Instant::from_millis(1));
        cubic
    }

    let mut individual = recovered();
    let mut delayed = recovered();
    let start = individual.window();
    // The receiver delivered exactly the same twenty segments in both
    // cases. Delayed/cumulative ACKs must not halve window recovery.
    for _ in 0..20 {
        ack(&mut individual, MSS, Instant::from_millis(2));
    }
    for _ in 0..10 {
        ack(&mut delayed, 2 * MSS, Instant::from_millis(2));
    }
    let individual_growth = individual.window() - start;
    let delayed_growth = delayed.window() - start;
    assert!(
        delayed_growth >= individual_growth * 95 / 100,
        "same delivered bytes: individual ACKs grew {individual_growth}, delayed ACKs {delayed_growth}"
    );
}

fn rtte() -> RttEstimator {
    RttEstimator::default()
}

// cmux patch: RFC 6928 initial window.
#[test]
fn initial_window_is_ten_segments() {
    let mut cubic = Cubic::new();
    assert_eq!(cubic.window(), 10 * MSS);

    // The tunnel's MSS, learned from the handshake.
    cubic.set_mss(1160);
    assert_eq!(cubic.window(), 11_600);

    // A large MSS is capped at 14600 bytes, a small one floored at 2 MSS.
    let mut cubic = Cubic::new();
    cubic.set_mss(8960);
    assert_eq!(cubic.window(), 2 * 8960);
    let mut cubic = Cubic::new();
    cubic.set_mss(1460);
    assert_eq!(cubic.window(), 14_600);
}

// cmux patch: once data flows, an MSS change no longer resets the window.
#[test]
fn set_mss_after_ack_keeps_window() {
    let mut cubic = Cubic::new();
    cubic.set_mss(MSS);
    ack(&mut cubic, MSS, Instant::from_millis(1));
    let cwnd = cubic.window();
    cubic.set_mss(1160);
    assert_eq!(cubic.window(), cwnd);

    let mut cubic = Cubic::new();
    cubic.on_rto(Instant::from_millis(1), 10 * MSS);
    cubic.set_mss(1160);
    assert_eq!(cubic.window(), MSS);
}

#[test]
fn congestion_avoidance_works() {
    let mut cubic = Cubic::new();
    cubic.set_mss(MSS);
    cubic.w_max = MSS * 32;
    cubic.recompute_k();

    // Post-fast-recovery state: cwnd = ssthresh ≈ w_max * beta.
    cubic.cwnd = (MSS * 32 * 7) / 10;
    cubic.ssthresh = cubic.cwnd;
    cubic.recovery_start = Some(Instant::from_millis(0));

    // CA at small time intervals should grow by less than 1 MSS per ACK.
    for i in 1..10 {
        let initial_cwnd = cubic.window();
        ack(&mut cubic, MSS, Instant::from_millis(i));
        assert!(cubic.window() < initial_cwnd + MSS);
    }

    // CA approaches w_max as t approaches K, and exceeds it past K.
    let pre = cubic.window();
    for i in 0..60 {
        ack(&mut cubic, MSS, Instant::from_millis(i * 100));
    }
    assert!(cubic.window() >= cubic.w_max);
    assert!(cubic.window() > pre);

    // RFC 9438 §4.2: the target is clamped to 1.5 * cwnd
    let pre = cubic.window();
    ack(&mut cubic, MSS, Instant::from_millis(100_000));
    assert!(cubic.window() <= pre + MSS);

    // CA should still cap at the receive window once enough ACKs accrue.
    for i in 0..200 {
        ack(&mut cubic, MSS, Instant::from_millis(100_000 + i * 100));
    }
    assert_eq!(cubic.window(), cubic.rwnd);
}

#[test]
fn fast_recovery_works() {
    let mut cubic = Cubic::new();
    cubic.set_mss(MSS);
    cubic.cwnd = MSS * 32;

    // duplicate ACKs before fast recovery should do nothing
    let initial_cwnd = cubic.window();
    for _ in 0..3 {
        cubic.on_dup_ack(Instant::from_millis(0), MSS, initial_cwnd);
    }
    assert_eq!(cubic.window(), initial_cwnd);

    // we enter fast recovery upon minor loss (three duplicate ACKs).
    // ssthresh = flight_size * beta_cubic, cwnd = ssthresh + 3*MSS, recovery_start = now.
    // w_max = cwnd since the prior w_max (initial 2*MSS) is below cwnd.
    let in_flight = initial_cwnd / 2;
    let expected_ssthresh = (in_flight as f64 * BETA_CUBIC) as usize;
    cubic.on_loss(Instant::from_millis(0), in_flight);
    assert_eq!(cubic.ssthresh, expected_ssthresh);
    assert_eq!(cubic.cwnd, expected_ssthresh + 3 * MSS);
    assert_eq!(cubic.w_max, initial_cwnd);
    assert!(cubic.in_fast_recovery);
    assert_eq!(cubic.recovery_start, Some(Instant::from_millis(0)));

    // in fast recovery, each dup-ACK should increase the cwnd by 1 MSS
    let initial_cwnd = cubic.window();
    for i in 0..3 {
        for _ in 0..3 {
            let initial_cwnd = cubic.window();
            cubic.on_dup_ack(Instant::from_millis(i), MSS, initial_cwnd);
            assert_eq!(cubic.window(), initial_cwnd + MSS);
        }

        // multiple loss events (trip-dup-ack) should not trigger additional fast recovery reductions
        let initial_cwnd = cubic.window();
        let initial_ssthresh = cubic.ssthresh;
        let initial_w_max = cubic.w_max;
        cubic.on_loss(Instant::from_millis(i), initial_cwnd);
        assert_eq!(cubic.window(), initial_cwnd);
        assert_eq!(cubic.ssthresh, initial_ssthresh);
        assert_eq!(cubic.w_max, initial_w_max);
    }
    assert_eq!(cubic.window(), initial_cwnd + MSS * 9);

    // a non-duplicate ACK exits fast recovery and deflates cwnd to ssthresh
    ack(&mut cubic, MSS, Instant::from_millis(10));
    assert_eq!(cubic.window(), cubic.ssthresh);
    assert!(!cubic.in_fast_recovery);
}

#[test]
fn zero_length_ack_does_not_exit_fast_recovery() {
    let mut cubic = Cubic::new();
    cubic.set_mss(MSS);
    cubic.cwnd = MSS * 32;

    cubic.on_loss(Instant::from_millis(0), cubic.cwnd);
    assert!(cubic.in_fast_recovery);

    let cwnd = cubic.window();
    let ssthresh = cubic.ssthresh;

    // Accepted segments that acknowledge no new data (window updates,
    // data segments from the remote) must not end fast recovery or
    // change the window.
    ack(&mut cubic, 0, Instant::from_millis(1));
    assert!(cubic.in_fast_recovery);
    assert_eq!(cubic.window(), cwnd);
    assert_eq!(cubic.ssthresh, ssthresh);

    // The first ACK of new data still exits and deflates.
    ack(&mut cubic, MSS, Instant::from_millis(2));
    assert!(!cubic.in_fast_recovery);
    assert_eq!(cubic.window(), ssthresh);
}

#[test]
fn repeated_rto_holds_ssthresh() {
    let mut cubic = Cubic::new();
    cubic.set_mss(MSS);
    cubic.cwnd = MSS * 32;

    // First RTO reduces ssthresh based on the flight size.
    cubic.on_rto(Instant::from_millis(0), MSS * 32);
    let ssthresh = cubic.ssthresh;
    assert_eq!(ssthresh, (32.0 * MSS as f64 * BETA_CUBIC) as usize);

    // Until new data is ACKed, further RTOs are retransmissions of the
    // same segment and must hold ssthresh constant instead of collapsing
    // it towards the minimum.
    cubic.on_rto(Instant::from_millis(1), MSS);
    assert_eq!(cubic.ssthresh, ssthresh);

    // Once new data is ACKed, the next RTO is a fresh loss detection
    // and reduces ssthresh again.
    ack(&mut cubic, MSS, Instant::from_millis(2));
    cubic.on_rto(Instant::from_millis(3), MSS * 4);
    assert_eq!(cubic.ssthresh, (4.0 * MSS as f64 * BETA_CUBIC) as usize);
}

#[test]
fn slow_start_works() {
    let mut cubic = Cubic::new();
    cubic.set_mss(MSS);
    cubic.cwnd = MSS * 32;
    cubic.ssthresh = MSS * 16;

    // we enter slow start upon major loss (an RTO)
    // window resets to MSS, ssthresh becomes a fraction of the inflight bytes,
    // recovery_start is cleared so any later CA uses a fresh epoch,
    // and w_max is preserved (RFC 9438 §4.8 defers it to the next CA stage).
    let w_max_before_rto = cubic.w_max;
    let inflight = cubic.window();
    cubic.on_rto(Instant::from_millis(0), inflight);
    assert_eq!(cubic.ssthresh, (inflight as f64 * BETA_CUBIC) as usize);
    assert_eq!(cubic.window(), MSS);
    assert!(!cubic.in_fast_recovery);
    assert_eq!(cubic.recovery_start, None);
    assert_eq!(cubic.w_max, w_max_before_rto);

    // slow start grows by at most the MSS per ack
    let initial_cwnd = cubic.window();
    for i in 0..10 {
        let initial_cwnd = cubic.window();
        let now = Instant::from_millis(i);
        ack(&mut cubic, MSS * 2, now);
        assert_eq!(cubic.window(), initial_cwnd + MSS);
    }
    assert_eq!(cubic.window(), initial_cwnd + MSS * 10);

    // slow start uses the number of ACKed bytes if they're less than the MSS
    let initial_cwnd = cubic.window();
    for i in 0..10 {
        let initial_cwnd = cubic.window();
        let now = Instant::from_millis(10 + i);
        ack(&mut cubic, MSS / 2, now);
        assert_eq!(cubic.window(), initial_cwnd + MSS / 2);
    }
    assert_eq!(cubic.window(), initial_cwnd + MSS / 2 * 10);

    // slow start transitions to congestion avoidance at ssthresh
    let initial_cwnd = cubic.window();
    cubic.ssthresh = initial_cwnd + MSS;
    ack(&mut cubic, MSS, Instant::from_millis(30));
    assert_eq!(cubic.window(), initial_cwnd + MSS);
    assert_eq!(cubic.ssthresh, initial_cwnd + MSS);
}

#[test]
fn progress_to_ca_via_rto() {
    let mut cubic = Cubic::new();
    cubic.set_mss(MSS);

    let mut time = 0;

    // slow start from default state
    let initial_cwnd = cubic.window();
    for _ in 0..30 {
        time += 1;
        ack(&mut cubic, MSS, Instant::from_millis(time));
    }
    assert_eq!(cubic.window(), initial_cwnd + MSS * 30);
    assert!(cubic.window() < cubic.ssthresh);

    // rto: cwnd resets to MSS and sstresh reduces
    let rto_cwnd = cubic.window();
    cubic.on_rto(Instant::from_millis(time), rto_cwnd);
    assert_eq!(cubic.window(), MSS);
    assert_eq!(cubic.ssthresh, (rto_cwnd as f64 * BETA_CUBIC) as usize);

    // slow start again until cwnd reaches new ssthresh
    while cubic.window() < cubic.ssthresh {
        time += 1;
        let initial_cwnd = cubic.window();
        ack(&mut cubic, MSS, Instant::from_millis(time));
        assert_eq!(cubic.window(), initial_cwnd + MSS);
    }
    assert!(cubic.window() >= cubic.ssthresh);
    assert!(cubic.window() < cubic.ssthresh + MSS);

    // ca: first CA ACK starts a fresh epoch with W_max = cwnd and K = 0.
    time += 1;
    let cwnd_at_ca_entry = cubic.window();
    ack(&mut cubic, MSS, Instant::from_millis(time));
    assert_eq!(cubic.w_max, cwnd_at_ca_entry);
    assert_eq!(cubic.k, 0.0);
    assert!(cubic.window() >= cwnd_at_ca_entry);
}

#[test]
fn progress_to_ca_via_loss() {
    let mut cubic = Cubic::new();
    cubic.set_mss(MSS);

    let mut time = 0;

    // slow start from default state
    let initial_cwnd = cubic.window();
    for _ in 0..30 {
        time += 1;
        ack(&mut cubic, MSS, Instant::from_millis(time));
    }
    assert_eq!(cubic.window(), initial_cwnd + MSS * 30);
    assert!(cubic.window() < cubic.ssthresh);

    // dup ACKs: ssthresh = cwnd * beta, cwnd = ssthresh + 3*MSS, recovery_start = now
    time += 1;
    let loss_cwnd = cubic.window();
    let expected_ssthresh = (loss_cwnd as f64 * BETA_CUBIC) as usize;
    cubic.on_loss(Instant::from_millis(time), loss_cwnd);
    assert_eq!(cubic.ssthresh, expected_ssthresh);
    assert_eq!(cubic.window(), expected_ssthresh + 3 * MSS);
    assert!(cubic.in_fast_recovery);
    assert_eq!(cubic.recovery_start, Some(Instant::from_millis(time)));

    // inflate cwnd on each duplicate ACK
    for _ in 0..9 {
        time += 1;
        let initial_cwnd = cubic.window();
        cubic.on_dup_ack(Instant::from_millis(time), MSS, cubic.cwnd);
        assert_eq!(cubic.window(), initial_cwnd + MSS);
    }

    // non-duplicate ACK deflates cwnd to ssthresh
    time += 1;
    ack(&mut cubic, MSS, Instant::from_millis(time));
    assert_eq!(cubic.window(), expected_ssthresh);
    assert!(!cubic.in_fast_recovery);

    // ca: subsequent ACKs follow the cubic curve
    time += 1;
    let initial_cwnd = cubic.window();
    ack(&mut cubic, MSS, Instant::from_millis(time));
    assert!(cubic.window() >= initial_cwnd);
}

#[test]
fn fast_convergence_reduces_w_max() {
    let mut cubic = Cubic::new();
    cubic.set_mss(MSS);
    cubic.w_max = MSS * 50;
    cubic.cwnd = MSS * 30;

    // Loss while cwnd < w_max (a new competing flow) should pull w_max down.
    let w_max_prev = cubic.w_max;
    cubic.on_loss(Instant::from_millis(0), cubic.cwnd);
    assert!(cubic.w_max < w_max_prev);
}

#[test]
fn test_cube_root() {
    let mut max_err = 0.0;
    let mut max_err_at = 0;
    let mut max_err_expected = 0.0;
    let mut max_err_found = 0.0;

    for i in (1..1_000_000).step_by(99) {
        let found = cube_root(i as f64);
        let expected = (i as f64).cbrt();
        let err = (found - expected).abs() / expected;

        if err > max_err {
            max_err = err;
            max_err_at = i;
            max_err_found = found;
            max_err_expected = expected;
        }
    }

    assert!(
        max_err < 0.0005,
        "cube_root({max_err_at}) = {max_err_found}, expected ~{max_err_expected}, rel err {max_err:.3e}"
    );
}
