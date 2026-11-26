use super::*;

#[test]
fn has_the_peak_burst_turns_and_sends() {
    let shape = Shape::load(None).unwrap();
    let s = script(&shape, 1, 3, 30, 7);
    let mut per_s = std::collections::BTreeMap::<u64, u64>::new();
    for e in &s {
        if matches!(e.op, Op::Event { .. }) {
            *per_s.entry(e.at_ms / 1000).or_default() += 1;
        }
    }
    let peak = per_s.values().max().copied().unwrap();
    assert_eq!(
        peak,
        shape.acpmux.global_events_per_s.p99 + shape.acpmux.per_session.peak_events_1s.max
    );
    assert!(s.iter().any(|e| e.op == Op::UserTurn));
    assert!(s.iter().any(|e| e.op == Op::SendTo { to: 2 }));
    assert!(s.windows(2).all(|w| w[0].at_ms <= w[1].at_ms && w[0].seq < w[1].seq));
    assert_eq!(script(&shape, 1, 3, 30, 7), s, "seeded");
}
