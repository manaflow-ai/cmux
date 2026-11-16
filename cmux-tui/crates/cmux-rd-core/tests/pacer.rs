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
    assert!(last - 1_000 <= 8_400, "keyframe took {} us", last - 1_000);
    assert!(last - 1_000 >= 5_500, "frame was not spread: {} us", last - 1_000);
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
fn strict_control_queue_is_bounded_and_uses_the_wire_budget() {
    let mut pacer = Pacer::strict(StrictWireBudget::with_limits(480_000, 1_000, 2_000, 100));
    assert!(pacer.enqueue_control(vec![7; 60], 50, 0));
    assert!(!pacer.enqueue_control(vec![8; 60], 51, 0));
    assert!(pacer.due_with_metadata(0).is_empty(), "the pin has no initial credit");
    let controls = pacer.due_with_metadata(1_000);
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
