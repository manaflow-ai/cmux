use super::*;

#[test]
fn missing_bytes_are_exact_and_the_ring_is_bounded() {
    let ring = ResumeRing::with_budget(8);
    ring.append(b"abcd");
    let stamp = ring.stamp();
    let held = (stamp.nonce, stamp.epoch);
    assert_eq!(ring.missing_after(held, 2).unwrap().0, b"cd");
    assert_eq!(ring.missing_after(held, 4).unwrap().0, b"");
    assert!(ring.missing_after(held, 5).is_none());
    {
        let released = ResumeRing::with_budget(8);
        released.append(b"abcd");
        let before = released.stamp();
        released.release();
        assert_eq!(released.stamp(), before);
        assert_eq!(released.inner.lock().unwrap().bytes.capacity(), 0);
        assert_eq!(released.missing_after((before.nonce, before.epoch), 4).unwrap().0, b"");
        assert!(released.missing_after((before.nonce, before.epoch), 2).is_none());
    }
    ring.append(b"efghij");
    // Ten bytes written, the last eight kept: offsets 2.. resume.
    assert_eq!(ring.missing_after(held, 2).unwrap().0, b"cdefghij");
    assert!(ring.missing_after(held, 1).is_none());
    ring.append(&[b'z'; 100]);
    assert_eq!(ring.stamp().offset, 110);
    assert_eq!(ring.missing_after(held, 102).unwrap().0.len(), 8);
    ring.bump_epoch();
    assert!(ring.missing_after(held, 110).is_none());
    assert!(ring.missing_after((held.0 ^ 1, ring.stamp().epoch), 110).is_none());
}

#[test]
fn a_bounded_resume_refuses_more_missed_bytes_than_its_bound() {
    let ring = ResumeRing::with_budget(64);
    ring.append(b"0123456789");
    let stamp = ring.stamp();
    let held = (stamp.nonce, stamp.epoch);
    assert_eq!(ring.missing_within(held, 6, Some(4)).unwrap().0, b"6789");
    assert!(ring.missing_within(held, 5, Some(4)).is_none());
    assert_eq!(ring.missing_within(held, 10, Some(0)).unwrap().0, b"");
    assert_eq!(ring.missing_within(held, 0, None).unwrap().0.len(), 10);
}

#[test]
fn generation_strings_round_trip() {
    let stamp = StreamStamp { nonce: 0xdead_beef_0123, epoch: 7, offset: 9 };
    assert_eq!(
        StreamStamp::parse_generation(&stamp.generation()),
        Some((stamp.nonce, stamp.epoch))
    );
    assert_eq!(StreamStamp::parse_generation("nope"), None);
}
