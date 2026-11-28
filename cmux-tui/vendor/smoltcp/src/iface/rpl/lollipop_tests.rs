use super::*;

#[test]
fn sequence_counter_increment() {
    let mut seq = SequenceCounter::new(253);
    seq.increment();
    assert_eq!(seq.value(), 254);
    seq.increment();
    assert_eq!(seq.value(), 255);
    seq.increment();
    assert_eq!(seq.value(), 0);

    let mut seq = SequenceCounter::new(126);
    seq.increment();
    assert_eq!(seq.value(), 127);
    seq.increment();
    assert_eq!(seq.value(), 0);
}

#[test]
fn sequence_counter_comparison() {
    use core::cmp::Ordering;

    assert!(SequenceCounter::new(240) != SequenceCounter::new(1));
    assert!(SequenceCounter::new(1) != SequenceCounter::new(240));
    assert!(SequenceCounter::new(1) != SequenceCounter::new(240));
    assert!(SequenceCounter::new(240) == SequenceCounter::new(240));
    assert!(SequenceCounter::new(240 - 17) != SequenceCounter::new(240));

    assert_eq!(
        SequenceCounter::new(240).partial_cmp(&SequenceCounter::new(5)),
        Some(Ordering::Greater)
    );
    assert_eq!(
        SequenceCounter::new(250).partial_cmp(&SequenceCounter::new(5)),
        Some(Ordering::Less)
    );
    assert_eq!(
        SequenceCounter::new(5).partial_cmp(&SequenceCounter::new(250)),
        Some(Ordering::Greater)
    );
    assert_eq!(
        SequenceCounter::new(127).partial_cmp(&SequenceCounter::new(129)),
        Some(Ordering::Less)
    );
    assert_eq!(
        SequenceCounter::new(120).partial_cmp(&SequenceCounter::new(121)),
        Some(Ordering::Less)
    );
    assert_eq!(
        SequenceCounter::new(121).partial_cmp(&SequenceCounter::new(120)),
        Some(Ordering::Greater)
    );
    assert_eq!(
        SequenceCounter::new(240).partial_cmp(&SequenceCounter::new(241)),
        Some(Ordering::Less)
    );
    assert_eq!(
        SequenceCounter::new(241).partial_cmp(&SequenceCounter::new(240)),
        Some(Ordering::Greater)
    );
    assert_eq!(
        SequenceCounter::new(120).partial_cmp(&SequenceCounter::new(120)),
        Some(Ordering::Equal)
    );
    assert_eq!(
        SequenceCounter::new(240).partial_cmp(&SequenceCounter::new(240)),
        Some(Ordering::Equal)
    );
    assert_eq!(
        SequenceCounter::new(130).partial_cmp(&SequenceCounter::new(241)),
        None
    );
}
