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

/// A pacer whose connection 1000 -> 2000 has its delay window full: the
/// first `INITIAL_WINDOW` bytes left and the rest waits for an ACK.
fn held_pacer(now: Instant) -> crate::pacing::Pacer {
    let mut pacer = crate::pacing::Pacer::default();
    for index in 0..48 {
        pacer.push(tcp(1000, 2000, index * SEGMENT, Some(1), SEGMENT as usize), now);
    }
    pacer.received(&tcp(2000, 1000, 1, Some(0), 0), now);
    while let Ok(Some(_)) = pacer.pop(now) {}
    assert!(matches!(pacer.pop(now), Ok(None)), "held for an ACK");
    pacer
}

#[test]
fn a_pure_ack_leaves_ahead_of_the_fresh_data_the_window_holds() {
    if !enabled() {
        return;
    }
    let now = Instant::now();
    let mut pacer = held_pacer(now);
    // The peer's data arrives; the stack ACKs it with a pure ACK at its
    // SND.NXT (past the data held here).
    pacer.push(tcp(1000, 2000, 48 * SEGMENT, Some(5001), 0), now);
    let ack = pacer.pop(now).ok().flatten().expect("the ACK leaves");
    let ack = crate::pacing::segment(&ack).unwrap();
    assert_eq!((ack.len, ack.ack), (0, Some(5001)));
}

#[test]
fn an_ack_riding_on_held_data_leaves_on_its_own() {
    if !enabled() {
        return;
    }
    let now = Instant::now();
    let mut pacer = held_pacer(now);
    // The stack's next data segment carries the ACK of the peer's upload;
    // the window holds it, but the ACK must reach the peer.
    pacer.push(tcp(1000, 2000, 48 * SEGMENT, Some(9001), SEGMENT as usize), now);
    let packet = pacer.pop(now).ok().flatten().expect("a pure ACK leaves");
    assert_eq!(packet.len(), 40);
    assert_eq!(ones_sum(&packet[..20]), 0xFFFF, "IPv4 checksum");
    let mut pseudo = packet[12..20].to_vec();
    pseudo.extend([0, 6, 0, 20]);
    pseudo.extend(&packet[20..]);
    assert_eq!(ones_sum(&pseudo), 0xFFFF, "TCP checksum");
    let ack = crate::pacing::segment(&packet).unwrap();
    assert_eq!((ack.len, ack.ack), (0, Some(9001)));
    assert_eq!(ack.seq, INITIAL_WINDOW, "at what already left, inside the peer's window");
    assert!(matches!(pacer.pop(now), Ok(None)), "once per new ACK");
    // When the held data leaves, it carries the newest ACK, not its own.
    pacer.received(&tcp(2000, 1000, 1, Some(INITIAL_WINDOW), 0), now);
    let data = pacer.pop(now).ok().flatten().expect("the window opened");
    assert_eq!(crate::pacing::segment(&data).unwrap().ack, Some(9001));
}

#[test]
fn a_pure_ack_after_a_timeout_rewind_is_raised_into_the_peer_window() {
    if !enabled() {
        return;
    }
    let now = Instant::now();
    let mut pacer = held_pacer(now);
    // smoltcp timed out and rewound SND.NXT to SND.UNA (0): its pure ACK
    // would sit below the peer's RCV.NXT and be ignored there.
    pacer.push(tcp(1000, 2000, 0, Some(7001), 0), now);
    let ack = pacer.pop(now).ok().flatten().expect("the ACK leaves");
    let ack = crate::pacing::segment(&ack).unwrap();
    assert_eq!((ack.seq, ack.ack), (INITIAL_WINDOW, Some(7001)));
}

#[test]
fn a_full_pacer_still_sends_the_head_the_window_holds() {
    if !enabled() {
        return;
    }
    let now = Instant::now();
    let mut pacer = held_pacer(now);
    // The flight was lost and no ACK comes; the stack keeps emitting fresh
    // data until the pacer is full and refuses it more. Its retransmission
    // can then only enter once something leaves: held here for an ACK that
    // only the retransmission brings, the link stalls until it times out.
    let mut seq = 48 * SEGMENT;
    while pacer.has_room() {
        pacer.push(tcp(1000, 2000, seq, Some(1), SEGMENT as usize), now);
        seq += SEGMENT;
    }
    let head = pacer.pop(now).ok().flatten().expect("a full pacer sends its head");
    assert_eq!(crate::pacing::segment(&head).map(|segment| segment.seq), Some(INITIAL_WINDOW));
    assert!(pacer.has_room(), "room for the retransmission");
    pacer.push(tcp(1000, 2000, 0, Some(1), SEGMENT as usize), now);
    let resent = pacer.pop(now).ok().flatten().expect("the resend leaves");
    assert_eq!(crate::pacing::segment(&resent).map(|segment| segment.seq), Some(0));
}

/// The folded one's-complement sum of `bytes` (0xFFFF over a header whose
/// checksum is right).
fn ones_sum(bytes: &[u8]) -> u16 {
    let mut sum: u32 = bytes
        .chunks(2)
        .map(|pair| u32::from(u16::from_be_bytes([pair[0], *pair.get(1).unwrap_or(&0)])))
        .sum();
    while sum > 0xFFFF {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    sum as u16
}
