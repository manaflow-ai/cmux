use super::*;

/// A bulk sender held to a [`DelayWindow`] into one FIFO bottleneck of
/// `rate` bytes a second and `base` round trip, with an ACK per segment,
/// paced as the pacer paces bulk (twice the window a smoothed round trip,
/// unpaced before the first sample).
/// Returns the window and, over the last half of `run`, the bytes acked a
/// second and the largest queueing delay a segment met.
fn bottleneck(rate: f64, base: Duration, run: Duration) -> (u32, f64, Duration) {
    let (window, goodput, worst, _) = bottleneck_from_start(rate, base, run);
    (window, goodput, worst)
}

/// [`bottleneck`], and the largest queueing delay over the whole run, slow
/// start included.
fn bottleneck_from_start(
    rate: f64,
    base: Duration,
    run: Duration,
) -> (u32, f64, Duration, Duration) {
    let start = Instant::now();
    let mut delay = DelayWindow::default();
    let mut now = start;
    let mut link_free = start;
    let (mut snd_max, mut snd_una) = (0u32, 0u32);
    // (ack time, ack number), in ack order (a FIFO keeps it).
    let mut acks: VecDeque<(Instant, u32)> = VecDeque::new();
    let half = start + run / 2;
    let (mut acked_after_half, mut worst_queue) = (0u64, Duration::ZERO);
    let mut worst_ever = Duration::ZERO;
    let (mut srtt, mut next_send): (Option<Duration>, Instant) = (None, start);
    let mut departed: VecDeque<(u32, Instant)> = VecDeque::new();
    while now < start + run {
        // Send what the window and the pacing allow.
        while next_send <= now
            && snd_max.wrapping_sub(snd_una) + SEGMENT <= delay.window.max(SEGMENT)
        {
            let begin = link_free.max(now);
            let queued = begin - now;
            if now >= half {
                worst_queue = worst_queue.max(queued);
            }
            worst_ever = worst_ever.max(queued);
            link_free = begin + Duration::from_secs_f64(f64::from(SEGMENT) / rate);
            snd_max = snd_max.wrapping_add(SEGMENT);
            delay.departed(snd_max, snd_max.wrapping_sub(snd_una), now);
            departed.push_back((snd_max, now));
            acks.push_back((link_free + base, snd_max));
            if let Some(srtt) = srtt {
                let pace = 2.0 * f64::from(delay.window) / srtt.as_secs_f64();
                next_send = now + Duration::from_secs_f64(f64::from(SEGMENT) / pace);
            }
        }
        // The next event: an ACK, or the pacer's next send.
        let Some(&(at, ack)) = acks.front() else { break };
        if next_send > now && next_send < at {
            now = next_send;
            continue;
        }
        acks.pop_front();
        now = at;
        if let Some((_, sent)) = departed.pop_front() {
            let sample = now - sent;
            srtt = Some(srtt.map_or(sample, |srtt| (srtt * 7 + sample) / 8));
        }
        if now >= half {
            acked_after_half += u64::from(ack.wrapping_sub(snd_una));
        }
        snd_una = ack;
        delay.acked(ack, snd_max, now);
    }
    (delay.window, acked_after_half as f64 / (run / 2).as_secs_f64(), worst_queue, worst_ever)
}

#[test]
fn bulk_keeps_the_queue_near_the_target_at_full_rate_on_lte() {
    // lte: 12 Mbit/s, 70 ms.
    let rate = 12e6 / 8.0;
    let (window, goodput, worst) =
        bottleneck(rate, Duration::from_millis(70), Duration::from_secs(8));
    assert!(goodput > 0.95 * rate, "goodput {goodput:.0} of {rate:.0} B/s");
    assert!(worst <= TARGET * 3, "queue reached {worst:?}");
    let bdp = rate * 0.070;
    assert!(f64::from(window) < bdp * 1.3, "window {window} for a {bdp:.0} B product");
}

#[test]
fn slow_start_stops_near_the_product_on_lte() {
    // Doubling blind from half the product to past it queued a whole
    // round's extra (40 ms here, 60 to 110 ms behind the real stack's
    // jitter): every keystroke echo behind it waited that long.
    let rate = 12e6 / 8.0;
    let (_, goodput, _, worst) =
        bottleneck_from_start(rate, Duration::from_millis(70), Duration::from_secs(8));
    assert!(goodput > 0.95 * rate, "goodput {goodput:.0} of {rate:.0} B/s");
    // The first window leaves unpaced (no round trip yet): its own burst
    // is the largest queue left, 32 segments at 12 Mbit/s, about 25 ms.
    let first_burst = Duration::from_secs_f64(f64::from(INITIAL_WINDOW) / rate);
    assert!(worst <= first_burst + TARGET, "queue reached {worst:?}");
}

#[test]
fn a_fast_short_path_is_not_slowed() {
    // A LAN: 300 Mbit/s, 2 ms.
    let rate = 300e6 / 8.0;
    let (_, goodput, worst) = bottleneck(rate, Duration::from_millis(2), Duration::from_secs(2));
    assert!(goodput > 0.95 * rate, "goodput {goodput:.0} of {rate:.0} B/s");
    assert!(worst <= TARGET * 3, "queue reached {worst:?}");
}

#[test]
fn a_slow_long_path_keeps_a_short_queue() {
    // 1 Mbit/s, 600 ms.
    let rate = 1e6 / 8.0;
    let (_, goodput, worst) = bottleneck(rate, Duration::from_millis(600), Duration::from_secs(30));
    assert!(goodput > 0.9 * rate, "goodput {goodput:.0} of {rate:.0} B/s");
    // A segment alone takes 9.6 ms here: the target is two of them.
    let segment = Duration::from_secs_f64(f64::from(SEGMENT) / rate);
    assert!(worst <= segment * 3, "queue reached {worst:?}");
}

#[test]
fn a_standing_queue_shrinks_the_window() {
    let start = Instant::now();
    let mut delay = DelayWindow { window: 400_000, slow_start: false, ..DelayWindow::default() };
    delay.note_base(Duration::from_millis(70), start);
    delay.round_flight = 400_000;
    delay.adjust(Duration::from_millis(320));
    assert_eq!(delay.window, 200_000, "at most halved in one step");
    delay.round_flight = 200_000;
    delay.adjust(Duration::from_millis(100));
    // 200 000 x 75 / 100.
    assert_eq!(delay.window, 150_000);
}

#[test]
fn an_application_limited_round_does_not_grow_the_window() {
    let start = Instant::now();
    let mut delay = DelayWindow::default();
    delay.note_base(Duration::from_millis(70), start);
    delay.round_flight = INITIAL_WINDOW / 4;
    delay.adjust(Duration::from_millis(70));
    assert_eq!(delay.window, INITIAL_WINDOW);
    delay.round_flight = INITIAL_WINDOW;
    delay.adjust(Duration::from_millis(70));
    assert_eq!(delay.window, 2 * INITIAL_WINDOW, "slow start doubles a used window");
}

#[test]
fn a_resend_clears_the_samples() {
    let start = Instant::now();
    let mut delay = DelayWindow::default();
    delay.departed(1200, 1200, start);
    delay.departed(2400, 2400, start);
    delay.resent();
    assert!(delay.departures.is_empty(), "no sample after a resend (Karn)");
    delay.acked(2400, 2400, start + Duration::from_millis(500));
    assert_eq!(delay.base(), None);
}

#[test]
fn sequence_numbers_wrap() {
    let start = Instant::now();
    let mut delay = DelayWindow::default();
    let first = u32::MAX - 600;
    delay.departed(first, 1200, start);
    delay.departed(first.wrapping_add(1200), 2400, start);
    delay.acked(
        first.wrapping_add(1200),
        first.wrapping_add(1200),
        start + Duration::from_millis(70),
    );
    assert!(delay.departures.is_empty());
    assert_eq!(delay.base(), Some(Duration::from_millis(70)));
}

/// An IPv4 TCP segment from port `from` to port `to` (checksums left zero:
/// the pacer does not read them).
fn tcp(from: u16, to: u16, seq: u32, ack: Option<u32>, payload: usize) -> Vec<u8> {
    let total = u16::try_from(40 + payload).unwrap();
    let mut packet = vec![0x45, 0, 0, 0, 0, 0, 0, 0, 64, 6, 0, 0, 10, 0, 0, 1, 10, 0, 0, 2];
    packet[2..4].copy_from_slice(&total.to_be_bytes());
    if from > to {
        packet[12..20].rotate_left(4);
    }
    packet.extend(from.to_be_bytes());
    packet.extend(to.to_be_bytes());
    packet.extend(seq.to_be_bytes());
    packet.extend(ack.unwrap_or(0).to_be_bytes());
    packet.extend([0x50, if ack.is_some() { 0x10 } else { 0 }, 0xFF, 0xFF, 0, 0, 0, 0]);
    packet.resize(40 + payload, 0);
    packet
}

#[test]
fn a_resend_leaves_ahead_of_the_fresh_data_the_window_holds() {
    if !enabled() {
        return;
    }
    let now = Instant::now();
    let mut pacer = crate::pacing::Pacer::default();
    let (local, remote) = (1000, 2000);
    for index in 0..48 {
        pacer.push(tcp(local, remote, index * SEGMENT, Some(1), SEGMENT as usize), now);
    }
    // The handshake's ACK: none of the data acknowledged yet.
    pacer.received(&tcp(remote, local, 1, Some(0), 0), now);
    let mut sent = 0;
    while let Ok(Some(_)) = pacer.pop(now) {
        sent += 1;
    }
    assert_eq!(sent * SEGMENT, INITIAL_WINDOW, "the window holds the rest");
    assert!(matches!(pacer.pop(now), Ok(None)), "held for an ACK, not a time");
    // No ACK comes; TCP sends the first segment again.
    pacer.push(tcp(local, remote, 0, Some(1), SEGMENT as usize), now);
    let resent = pacer.pop(now).ok().flatten().expect("the resend leaves");
    assert_eq!(crate::pacing::segment(&resent).map(|segment| segment.seq), Some(0));
}
