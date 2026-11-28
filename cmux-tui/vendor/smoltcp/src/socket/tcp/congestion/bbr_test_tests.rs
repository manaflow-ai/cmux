use super::*;

const MSS: usize = 1160;

fn rtte(ms: u32) -> RttEstimator {
    let mut rtt = RttEstimator::default();
    rtt.sample(ms);
    rtt
}

fn bbr() -> Bbr {
    let mut bbr = Bbr::new();
    bbr.set_mss(MSS);
    bbr.set_remote_window(4 << 20);
    bbr
}

/// Drives `rounds` rounds of `rtt_ms` each, delivering `rate` bytes per
/// second in ACKs of `ack` bytes, with a full window in flight.
fn drive(bbr: &mut Bbr, now: &mut Instant, rounds: usize, rtt_ms: u32, rate: u64, ack: usize) {
    let rtt = rtte(rtt_ms);
    let per_round = (rate * rtt_ms as u64 / 1000) as usize;
    let acks = (per_round / ack).max(1);
    let step = Duration::from_micros(rtt_ms as u64 * 1000 / acks as u64);
    for _ in 0..rounds {
        for _ in 0..acks {
            *now += step;
            let in_flight = bbr.window();
            bbr.on_ack(*now, ack, in_flight, &rtt);
        }
    }
}

#[test]
fn startup_ends_near_the_path_bdp() {
    let mut bbr = bbr();
    let mut now = Instant::from_millis(0);
    // 1.25 MB/s over a 50 ms path: a BDP of 62.5 KB.
    drive(&mut bbr, &mut now, 30, 50, 1_250_000, MSS);
    assert!(!bbr.startup, "startup never ended");
    let bdp = bbr.bdp().unwrap();
    assert!((50_000..=80_000).contains(&bdp), "bdp {bdp}");
    assert!(
        bbr.window() >= bdp && bbr.window() <= 3 * bdp,
        "window {}",
        bbr.window()
    );
}

#[test]
fn a_loss_bounds_the_window_but_never_under_the_bdp() {
    let mut bbr = bbr();
    let mut now = Instant::from_millis(0);
    drive(&mut bbr, &mut now, 30, 50, 1_250_000, MSS);
    let window = bbr.window();
    let bdp = bbr.bdp().unwrap();
    assert!(window >= 2 * bdp - MSS, "window {window} bdp {bdp}");
    // Losses in every round: the window stays at the BDP or above, so a
    // random loss costs no throughput.
    for _ in 0..10 {
        bbr.on_sack_loss(now, bbr.window());
        bbr.on_loss(now, bbr.window());
        bbr.on_dup_ack(now, MSS, bbr.window());
        drive(&mut bbr, &mut now, 1, 50, 1_250_000, MSS);
    }
    let bounded = bbr.window();
    assert!(
        bounded >= bdp && bounded < window,
        "{bounded} bdp {bdp} window {window}"
    );
    // With no more loss the bound grows a segment a round.
    drive(&mut bbr, &mut now, 5, 50, 1_250_000, MSS);
    assert!(bbr.window() > bounded && bbr.window() <= bounded + 6 * MSS);
    // One RTO alone (a tail loss) resends one segment, then the next ACK
    // of new data restores the window.
    let window = bbr.window();
    bbr.on_rto(now, window);
    assert_eq!(bbr.window(), MSS);
    now += Duration::from_millis(50);
    bbr.on_ack(now, MSS, 0, &rtte(50));
    assert!(bbr.window() >= window);
}

#[test]
fn a_loss_in_startup_ends_it() {
    let mut bbr = bbr();
    let mut now = Instant::from_millis(0);
    drive(&mut bbr, &mut now, 3, 50, 1_250_000, MSS);
    assert!(bbr.startup);
    let window = bbr.window();
    bbr.on_loss(now, window);
    assert!(!bbr.startup);
    assert!(
        bbr.window() <= window * 7 / 10 + MSS,
        "{} of {window}",
        bbr.window()
    );
}

#[test]
fn a_repaired_hole_is_not_a_burst_of_bandwidth() {
    let mut bbr = bbr();
    let mut now = Instant::from_millis(0);
    drive(&mut bbr, &mut now, 30, 50, 1_250_000, MSS);
    let bw = bbr.max_bw();
    let rtt = rtte(50);
    // A round's first ACK, then the hole's repair: the cumulative ACK
    // covers a hundred windows SACKed long ago.
    now += Duration::from_millis(1);
    bbr.on_ack(now, MSS, bbr.window(), &rtt);
    now += Duration::from_millis(50);
    bbr.on_ack(now, 100 * bbr.window(), bbr.window(), &rtt);
    assert!(bbr.max_bw() <= bw * 2, "{} vs {bw}", bbr.max_bw());
}

#[test]
fn rtos_in_a_row_collapse_and_restart() {
    let mut bbr = bbr();
    let mut now = Instant::from_millis(0);
    drive(&mut bbr, &mut now, 30, 50, 1_250_000, MSS);
    bbr.on_rto(now, bbr.window());
    bbr.on_rto(now, bbr.window());
    assert_eq!(bbr.window(), MSS);
    assert!(bbr.startup);
    assert_eq!(bbr.max_bw(), 0);
    // Nothing to restore: the next ACK grows from one segment in startup.
    bbr.on_ack(now, MSS, 0, &rtte(50));
    assert_eq!(bbr.window(), 2 * MSS);
}

#[test]
fn app_limited_rounds_do_not_age_the_estimate() {
    let mut bbr = bbr();
    let mut now = Instant::from_millis(0);
    drive(&mut bbr, &mut now, 30, 50, 1_250_000, MSS);
    let bw = bbr.max_bw();
    let rtt = rtte(50);
    // Fifty rounds of a trickle with almost nothing in flight.
    for _ in 0..50 {
        now += Duration::from_millis(50);
        bbr.on_ack(now, MSS, 0, &rtt);
    }
    assert_eq!(bbr.max_bw(), bw);
}

#[test]
fn mss_resizes_only_the_initial_window() {
    let mut bbr = Bbr::new();
    bbr.set_remote_window(1 << 20);
    bbr.set_mss(MSS);
    assert_eq!(bbr.window(), initial_window(MSS));
    bbr.on_ack(Instant::from_millis(1), MSS, 0, &rtte(50));
    let window = bbr.window();
    bbr.set_mss(536);
    assert_eq!(bbr.window(), window);
}

#[test]
fn window_never_exceeds_the_receive_window() {
    let mut bbr = Bbr::new();
    bbr.set_mss(MSS);
    bbr.set_remote_window(32 * 1024);
    let mut now = Instant::from_millis(0);
    drive(&mut bbr, &mut now, 30, 50, 5_000_000, MSS);
    assert!(bbr.window() <= 64 * 1024);
}
