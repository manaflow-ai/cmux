use super::*;

const SEGMENT: u32 = 1200;

/// A bulk sender held to a [`DelayWindow`] into one FIFO bottleneck of
/// `rate` bytes a second and `base` round trip, with an ACK per segment.
/// Returns the window and, over the last half of `run`, the bytes acked a
/// second and the largest queueing delay a segment met.
fn bottleneck(rate: f64, base: Duration, run: Duration) -> (u32, f64, Duration) {
    let start = Instant::now();
    let mut delay = DelayWindow::default();
    let mut now = start;
    let mut link_free = start;
    let (mut snd_max, mut snd_una) = (0u32, 0u32);
    // (ack time, ack number), in ack order (a FIFO keeps it).
    let mut acks: VecDeque<(Instant, u32)> = VecDeque::new();
    let half = start + run / 2;
    let (mut acked_after_half, mut worst_queue) = (0u64, Duration::ZERO);
    while now < start + run {
        // Send what the window allows.
        while snd_max.wrapping_sub(snd_una) + SEGMENT <= delay.window.max(SEGMENT) {
            let begin = link_free.max(now);
            let queued = begin - now;
            if now >= half {
                worst_queue = worst_queue.max(queued);
            }
            link_free = begin + Duration::from_secs_f64(f64::from(SEGMENT) / rate);
            snd_max = snd_max.wrapping_add(SEGMENT);
            delay.departed(snd_max, snd_max.wrapping_sub(snd_una), now);
            acks.push_back((link_free + base, snd_max));
        }
        let Some((at, ack)) = acks.pop_front() else { break };
        now = at;
        if now >= half {
            acked_after_half += u64::from(ack.wrapping_sub(snd_una));
        }
        snd_una = ack;
        delay.acked(ack, snd_max, now);
    }
    (delay.window, acked_after_half as f64 / (run / 2).as_secs_f64(), worst_queue)
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
    assert!(worst <= TARGET * 4, "queue reached {worst:?}");
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
