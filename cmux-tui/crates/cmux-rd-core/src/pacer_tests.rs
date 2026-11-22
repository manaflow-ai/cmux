use super::*;

fn frame(n: usize) -> Vec<Vec<u8>> {
    (0..n).map(|i| vec![i as u8; 1152]).collect()
}

/// Runs the pacer by its own deadlines; returns (send time, datagram) pairs.
fn drain(p: &mut Pacer, from: u64) -> Vec<(u64, Vec<u8>)> {
    let mut out = Vec::new();
    let mut now = from;
    for _ in 0..100_000 {
        for d in p.due(now) {
            out.push((now, d));
        }
        match p.next_deadline_us() {
            Some(t) => now = t.max(now + 1),
            None => break,
        }
    }
    out
}

#[test]
fn a_keyframe_leaves_within_half_a_frame_interval_in_order() {
    let mut p = Pacer::new();
    // 300 datagrams (345 KB) at 30 Mbps and 60 fps.
    p.push_frame(frame(300), 30_000_000, 16_667, 1_000);
    let sent = drain(&mut p, 1_000);
    assert_eq!(sent.len(), 300);
    let last = sent.last().unwrap().0;
    assert!(last - 1_000 <= 8_400, "keyframe took {} us", last - 1_000);
    // Less the first burst allowance, which goes at once.
    assert!(last - 1_000 >= 5_500, "keyframe was not spread: {} us", last - 1_000);
    for (i, (_, d)) in sent.iter().enumerate() {
        assert_eq!(d[0], i as u8, "order");
    }
    // No wakeup sends more than the burst allowance plus one datagram.
    let mut per_time = std::collections::BTreeMap::new();
    for (t, _) in &sent {
        *per_time.entry(*t).or_insert(0usize) += 1;
    }
    let rate = 345_600.0 / 8_333.0_f64.min(MAX_SPREAD_US); // bytes per us
    let burst = (rate * BURST_US as f64 / 1152.0).ceil() as usize + 1;
    assert!(per_time.values().all(|&n| n <= burst), "{per_time:?}");
}

/// Design D6, detector for the class "a recovery leaves as an unpaced burst": a
/// NACK answer (64 resends, the most one feedback asks for) leaves ahead of the
/// queued frame, in order, no more than the burst allowance per wakeup, and within
/// half a frame interval.
#[test]
fn repairs_leave_paced_ahead_of_queued_frames() {
    let mut p = Pacer::new();
    p.push_frame(frame(100), 10_000_000, 16_667, 0);
    let first = p.due(0).len();
    assert_eq!(p.take_frame_datagrams_sent(), first);
    let repairs: Vec<Vec<u8>> = (0..64).map(|_| vec![0xaa; 1152]).collect();
    p.push_repair(repairs, 10_000_000, 1_000);
    p.push_repair(vec![vec![0xbb; 1152]], 10_000_000, 1_000);
    let sent = drain(&mut p, 1_000);
    assert_eq!(sent.len(), 100 - first + 65);
    assert!(sent[..64].iter().all(|(_, d)| d[0] == 0xaa), "repairs first, in order");
    assert_eq!(sent[64].1[0], 0xbb);
    assert_eq!(p.take_frame_datagrams_sent(), 100 - first);
    let at_once = sent.iter().filter(|(t, _)| *t == 1_000).count();
    assert!(at_once < 65, "the repairs left as one burst: {at_once} datagrams at once");
    let last = sent.last().unwrap().0 - 1_000;
    assert!(last <= 8_400, "repairs and the frame behind them took {last} us");
}

/// D12 with D6: an outage-end drop sees and takes only queued frame datagrams. A
/// queued repair (a NACK answer or tail-loss probe of a frame that already left)
/// is neither a candidate nor taken, stays ahead of the frames and still counts as
/// a repair, so the frames left keep their send times.
#[test]
fn an_outage_drop_leaves_queued_repairs_alone() {
    let mut p = Pacer::new();
    p.push_frame(frame(100), 10_000_000, 16_667, 0);
    let first = p.due(0).len();
    p.take_frame_datagrams_sent();
    p.push_repair(vec![vec![0xee; 1152], vec![0xaa; 1152]], 10_000_000, 1_000);
    p.push_frame(vec![vec![0xee; 1152]; 10], 10_000_000, 16_667, 1_000);
    assert_eq!(p.queued().count(), 100 - first + 10, "repairs are not candidates");
    let stale = p.take_where(|d| d[0] == 0xee);
    assert_eq!(stale.len(), 10, "only the queued frame's datagrams");
    let sent = drain(&mut p, 1_000);
    assert_eq!(sent.len(), 2 + 100 - first);
    assert_eq!((sent[0].1[0], sent[1].1[0]), (0xee, 0xaa), "repairs still first");
    assert_eq!(p.take_frame_datagrams_sent(), 100 - first);
}

#[test]
fn a_repair_on_an_idle_pacer_goes_at_once() {
    let mut p = Pacer::new();
    p.push_repair(vec![vec![1; 1152]; 3], 30_000_000, 5_000);
    assert_eq!(p.due(5_000).len(), 3);
    assert!(p.is_empty());
    assert_eq!(p.take_frame_datagrams_sent(), 0);
}

#[test]
fn a_small_frame_goes_at_once_and_a_p_frame_at_two_and_a_half_times_the_target() {
    let mut p = Pacer::new();
    p.push_frame(frame(3), 30_000_000, 16_667, 0);
    assert_eq!(p.due(0).len(), 3);
    assert!(p.is_empty());
    assert_eq!(p.next_deadline_us(), None);
    // 54 datagrams (62 KB, one 30 Mbps frame at 60 fps) at 75 Mbps: about 6.6 ms, less
    // the first burst allowance.
    p.push_frame(frame(54), 30_000_000, 16_667, 100_000);
    let sent = drain(&mut p, 100_000);
    let span = sent.last().unwrap().0 - 100_000;
    assert!((4_200..=7_000).contains(&span), "span {span}");
}

/// Detector for the class "the send stage scales with the frame interval": an
/// at-budget frame at 30 fps (and at 15 fps) leaves within `MAX_SPREAD_US`, not
/// 0.4 of its interval.
#[test]
fn a_low_frame_rate_frame_leaves_within_the_absolute_spread_window() {
    for (fps, interval_us) in [(30u64, 33_333u64), (15, 66_667)] {
        let mut p = Pacer::new();
        // One 30 Mbps frame at this rate.
        let n = (30_000_000 / 8 / fps as usize).div_ceil(1152);
        p.push_frame(frame(n), 30_000_000, interval_us, 0);
        let sent = drain(&mut p, 0);
        assert_eq!(sent.len(), n);
        let span = sent.last().unwrap().0;
        assert!(span <= MAX_SPREAD_US as u64, "{fps} fps: span {span} us");
    }
}

#[test]
fn a_frame_pushed_while_one_is_queued_follows_it() {
    let mut p = Pacer::new();
    p.push_frame(frame(100), 10_000_000, 16_667, 0);
    let first = p.due(0).len();
    assert!(first < 100);
    p.push_frame(vec![vec![0xee; 1152]], 10_000_000, 16_667, 1_000);
    let rest = drain(&mut p, 1_000);
    assert_eq!(first + rest.len(), 101);
    assert_eq!(rest.last().unwrap().1[0], 0xee);
}

#[test]
fn taking_the_whole_queue_leaves_an_idle_pacer_that_sends_the_next_frame_at_once() {
    let mut p = Pacer::new();
    p.push_frame(frame(100), 10_000_000, 16_667, 0);
    let first = p.due(0).len();
    assert_eq!(p.queued().count(), 100 - first);
    let stale = p.take_where(|_| true);
    assert_eq!(first + stale.len(), 100);
    assert_eq!(stale[0][0], first as u8, "the unsent tail, in order");
    assert!(p.is_empty());
    assert_eq!(p.queued_bytes(), 0);
    assert_eq!(p.next_deadline_us(), None);
    p.push_frame(frame(2), 10_000_000, 16_667, 1_000);
    assert_eq!(p.due(1_000).len(), 2, "the newest frame is not paced behind the stale one");
}

#[test]
fn taking_part_of_the_queue_keeps_the_rest_in_order() {
    let mut p = Pacer::new();
    p.push_frame(frame(10), 10_000_000, 16_667, 0);
    p.push_frame(vec![vec![0xee; 1200]; 5], 10_000_000, 16_667, 0);
    let first = p.due(0).len();
    let stale = p.take_where(|d| d[0] == 0xee);
    assert_eq!(stale.len(), 5);
    assert_eq!(p.queued_bytes(), (10 - first) * 1152);
    let rest: Vec<u8> = p.queued().map(|d| d[0]).collect();
    assert_eq!(rest, (first as u8..10).collect::<Vec<_>>());
}

#[test]
fn a_late_wakeup_does_not_release_a_burst() {
    let mut p = Pacer::new();
    p.push_frame(frame(200), 20_000_000, 16_667, 0);
    p.due(0);
    // The caller slept 5 ms instead of the deadline: still at most the burst allowance.
    let late = p.due(5_000).len();
    let rate = 230_400.0 / 8_333.0;
    assert!(late as f64 <= (rate * BURST_US as f64 / 1152.0).ceil() + 1.0, "{late}");
}

#[test]
fn strict_integer_refill_keeps_fractional_remainder() {
    let mut p = Pacer::strict(StrictWireBudget::with_limits(1, 64, 256, 64));
    assert!(p.enqueue_media(vec![0; 1], 7, 0));
    assert!(p.due_with_metadata(0).is_empty());
    assert!(p.due_with_metadata(1_000_000).is_empty());
    // One bit per second is one byte every eight seconds; the first byte is now due.
    assert_eq!(p.due_with_metadata(8_000_000).len(), 1);
}
