use cmux_rd_core::pacer::{DatagramClass, Pacer, PacerPolicy, StrictWireBudget};

fn frame(n: usize) -> Vec<Vec<u8>> {
    (0..n).map(|i| vec![i as u8; 1_152]).collect()
}

fn drain(pacer: &mut Pacer, from: u64) -> Vec<(u64, Vec<u8>)> {
    let mut out = Vec::new();
    let mut now = from;
    for _ in 0..100_000 {
        for datagram in pacer.due(now) {
            out.push((now, datagram));
        }
        match pacer.next_deadline_us() {
            Some(deadline) => now = deadline.max(now + 1),
            None => break,
        }
    }
    out
}

#[test]
fn balanced_default_preserves_frame_pacing() {
    let mut pacer = Pacer::new();
    pacer.push_frame(frame(300), 30_000_000, 16_667, 1_000);
    let sent = drain(&mut pacer, 1_000);
    assert_eq!(sent.len(), 300);
    let last = sent.last().expect("frame").0;
    // 345 KB is past LARGE_FRAME_BYTES, so it goes at LARGE_FRAME_FACTOR (6) times the
    // target, about 15 ms, not in 8 ms at 345 Mbit/s into a slower path (hq#19915).
    assert!(last - 1_000 <= 15_600, "keyframe took {} us", last - 1_000);
    assert!(last - 1_000 >= 12_000, "frame was not spread: {} us", last - 1_000);
}

#[test]
fn strict_budget_accounts_full_wire_bytes_for_media_fec_repair_and_probe() {
    let budget = StrictWireBudget::with_limits(80_000, 1_000, 8_000, 256);
    let mut pacer = Pacer::strict(budget);
    assert_eq!(pacer.policy(), PacerPolicy::Strict(budget));
    assert!(pacer.enqueue_media(vec![0; 200], 10, 0));
    assert!(pacer.enqueue_fec(vec![1; 200], 11, 0));
    assert!(pacer.enqueue_repair(vec![2; 200], 12, 0));
    assert!(pacer.enqueue_probe(vec![3; 200], 13, 0));
    assert!(pacer.enqueue_media(vec![4; 200], 14, 0));
    assert!(pacer.enqueue_fec(vec![5; 200], 15, 0));
    assert!(pacer.enqueue_repair(vec![6; 200], 16, 0));
    assert!(pacer.enqueue_probe(vec![7; 200], 17, 0));

    // 80,000 bits/s is 10,000 bytes/s. No idle credit exists at t=0;
    // each 80 ms interval makes exactly 800 wire bytes eligible.
    assert!(pacer.due_with_metadata(0).is_empty());
    let first = pacer.due_with_metadata(80_000);
    assert_eq!(first.len(), 4);
    assert_eq!(first.iter().map(|d| d.datagram.len()).sum::<usize>(), 800);
    assert_eq!(first.iter().map(|d| d.departure_id).collect::<Vec<_>>(), vec![10, 11, 12, 13]);
    assert!(first.iter().all(|d| d.class != DatagramClass::Control));
    let second = pacer.due_with_metadata(160_000);
    assert_eq!(second.len(), 4);
    assert_eq!(second.iter().map(|d| d.datagram.len()).sum::<usize>(), 800);
    assert_eq!(second.iter().map(|d| d.departure_id).collect::<Vec<_>>(), vec![14, 15, 16, 17]);
}

#[test]
fn strict_budget_has_no_accumulated_burst_after_idle() {
    let mut pacer = Pacer::strict(StrictWireBudget::with_limits(80_000, 1_000, 4_000, 256));
    assert!(pacer.enqueue_media(vec![0; 100], 1, 0));
    assert!(pacer.due(9_000).is_empty());
    assert_eq!(pacer.due(20_000).len(), 1);
    assert!(pacer.is_empty());

    // The one-second idle interval does not mint a token burst for the next frame.
    assert!(pacer.enqueue_media(vec![0; 100], 2, 1_020_000));
    assert!(pacer.due(1_020_000).is_empty());
    assert_eq!(pacer.due(1_030_000).len(), 1);
}

#[test]
fn strict_zero_and_tiny_rates_are_bounded() {
    let mut zero = Pacer::strict(StrictWireBudget::with_limits(0, 1_000, 2_000, 100));
    assert!(zero.enqueue_media(vec![0; 10], 1, 0));
    assert!(zero.due(10_000_000).is_empty());
    assert_eq!(zero.next_deadline_us(), None);

    let mut tiny = Pacer::strict(StrictWireBudget::with_limits(1, 1_000, 2_000, 100));
    assert!(tiny.enqueue_media(vec![0; 1], 2, 0));
    let deadline = tiny.next_deadline_us().expect("tiny-rate deadline");
    assert!(deadline >= 7_999_999);
}

#[test]
fn strict_control_queue_is_bounded_and_bypasses_media_budget() {
    let mut pacer = Pacer::strict(StrictWireBudget::with_limits(0, 1_000, 2_000, 100));
    assert!(pacer.enqueue_control(vec![7; 60], 50, 0));
    assert!(!pacer.enqueue_control(vec![8; 60], 51, 0));
    let controls = pacer.due_with_metadata(0);
    assert_eq!(controls.len(), 1);
    assert_eq!(controls[0].class, DatagramClass::Control);
    assert_eq!(controls[0].departure_id, 50);
    assert_eq!(controls[0].datagram.len(), 60);
}

#[test]
fn strict_queue_limit_rejects_without_partial_accounting() {
    let mut pacer = Pacer::strict(StrictWireBudget::with_limits(1_000_000, 1_000, 100, 100));
    assert!(pacer.enqueue_probe(vec![0; 100], 1, 0));
    assert!(!pacer.enqueue_repair(vec![0; 1], 2, 0));
    assert_eq!(pacer.queued_bytes(), 100);
}

/// Ultra's one budget through the calls the host makes: a frame's datagrams (media and
/// its FEC parity, `push_frame`), a NACK resend (`push_repair`) and a probe train the
/// host sent back to back outside the queue (`charge`) all take wire time at the held
/// rate, so the last byte leaves when the total would at that rate.
#[test]
fn strict_frame_repair_and_charged_probe_train_share_one_budget() {
    // 8 Mbps is one byte per microsecond.
    let mut pacer = Pacer::strict(StrictWireBudget::with_limits(8_000_000, 1_000, 1 << 20, 1_024));
    // A 4,000-byte probe train left at t=0.
    pacer.charge(4_000, 0);
    // The target and frame interval are the balanced pacer's inputs; strict ignores them.
    pacer.push_frame(frame(2), 999_000_000, 16_667, 0);
    pacer.push_repair(vec![vec![9; 1_152]], 999_000_000, 0);
    let sent = drain(&mut pacer, 0);
    assert_eq!(sent.len(), 3);
    assert_eq!(sent[0].1, vec![9; 1_152], "the repair leaves first");
    // Nothing before the probe's 4 ms, then one 1,152-byte datagram per 1,152 us:
    // 4,000 + 3 x 1,152 bytes at one byte per microsecond.
    assert_eq!(sent.iter().map(|s| s.0).collect::<Vec<_>>(), vec![5_152, 6_304, 7_456]);
}

/// Balanced pacing (standard) ignores a charge.
#[test]
fn balanced_pacer_ignores_a_charge() {
    let mut charged = Pacer::new();
    charged.charge(1 << 20, 1_000);
    charged.push_frame(frame(30), 30_000_000, 16_667, 1_000);
    let mut plain = Pacer::new();
    plain.push_frame(frame(30), 30_000_000, 16_667, 1_000);
    let times = |p: &mut Pacer| drain(p, 1_000).into_iter().map(|s| s.0).collect::<Vec<_>>();
    assert_eq!(times(&mut charged), times(&mut plain));
}

/// D2 at the strict queue limit: newest frame wins. A frame that does not fit drops
/// whole older frames none of whose datagrams has left (oldest first), never datagrams
/// out of a frame's middle, and never the newest frame; the drop is counted and the
/// dropped datagrams are handed back to retire.
#[test]
fn strict_queue_limit_drops_whole_older_unstarted_frames() {
    let frame_of = |tag: u8| vec![vec![tag; 1_000], vec![tag; 1_000]];
    // One byte per microsecond, a 1,000-byte burst, room for three 1,000-byte datagrams.
    let mut pacer = Pacer::strict(StrictWireBudget::with_limits(8_000_000, 1_000, 3_000, 100));
    pacer.push_frame(frame_of(1), 0, 16_667, 0);
    // Frame 1 starts to leave: its head goes, its tail stays queued.
    assert_eq!(pacer.due(1_000), vec![vec![1; 1_000]]);
    pacer.push_frame(frame_of(2), 0, 16_667, 1_000);
    assert_eq!(pacer.queued_bytes(), 3_000, "frame 2 fits beside frame 1's tail");
    assert!(pacer.take_dropped().is_empty());
    assert_eq!(pacer.frames_dropped(), 0);

    // Frame 3 does not fit: unstarted frame 2 goes whole; frame 1's tail stays.
    pacer.push_frame(frame_of(3), 0, 16_667, 1_000);
    assert_eq!(pacer.take_dropped(), frame_of(2));
    assert_eq!(pacer.frames_dropped(), 1);
    assert_eq!(pacer.queued_bytes(), 3_000);
    let sent: Vec<Vec<u8>> = drain(&mut pacer, 1_000).into_iter().map(|s| s.1).collect();
    assert_eq!(sent, vec![vec![1; 1_000], vec![3; 1_000], vec![3; 1_000]]);

    // With nothing unstarted to drop, the newest frame is still queued whole.
    let mut full = Pacer::strict(StrictWireBudget::with_limits(8_000_000, 1_000, 1_500, 100));
    full.push_frame(frame_of(4), 0, 16_667, 0);
    assert_eq!(full.take_dropped(), Vec::<Vec<u8>>::new());
    full.push_frame(frame_of(5), 0, 16_667, 0);
    assert_eq!(full.take_dropped(), frame_of(4), "the older frame goes, never part of one");
    assert_eq!(full.queued_bytes(), 2_000);
    assert_eq!(full.frames_dropped(), 1);
}
