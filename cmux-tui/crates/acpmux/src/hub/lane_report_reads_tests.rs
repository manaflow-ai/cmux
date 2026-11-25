use super::*;

#[test]
fn receipts_are_exact_turns_and_bounded_without_dropping_live_waits() {
    let mut reads = Reads::default();
    reads.waits.insert("live".into(), 1);
    reads.turns.insert(1, Receipt { turn_id: "live".into(), ..Default::default() });
    for turn in 2..100 {
        reads.turns.insert(turn, Receipt { ended: true, read: turn == 98, ..Default::default() });
        reads.trim();
    }
    assert_eq!(reads.turns.len(), 64);
    assert!(reads.turns.contains_key(&1));
    assert!(reads.turns.get(&98).unwrap().read);
    assert!(!reads.turns.get(&99).unwrap().read);
}
