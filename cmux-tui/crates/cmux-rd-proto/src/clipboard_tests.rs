use super::*;

fn drain(s: &mut ClipboardSync) -> Vec<ClipboardPart> {
    let mut now = 0;
    let mut parts = Vec::new();
    while let Some(due) = s.next_deadline_us() {
        now = now.max(due);
        parts.extend(s.next_part(now));
    }
    parts
}

#[test]
fn a_short_text_is_one_whole_part() {
    let mut a = ClipboardSync::new();
    assert_eq!(a.offer("hello"), Offer::Queued(1));
    let parts = drain(&mut a);
    assert_eq!(
        parts,
        vec![ClipboardPart { seq: 1, text: "hello".into(), offset: None, total: None }]
    );
    let mut b = ClipboardSync::new();
    assert_eq!(b.receive(parts[0].clone()), Ok(Some((1, "hello".into()))));
}

#[test]
fn a_long_text_travels_in_paced_parts_and_joins_whole() {
    let text: String = (0..100_000).map(|i| ['a', 'é', '"', '\u{1}', '😀'][i % 5]).collect();
    let mut a = ClipboardSync::new();
    assert_eq!(a.offer(&text), Offer::Queued(1));
    // Pacing: a second part is not due within the interval.
    assert!(a.next_part(0).is_some());
    assert!(a.next_part(PART_INTERVAL_US - 1).is_none());
    let mut a = ClipboardSync::new();
    a.offer(&text);
    let parts = drain(&mut a);
    assert!(parts.len() > 1);
    let mut b = ClipboardSync::new();
    let mut out = None;
    for part in parts {
        let json_len = part.text.chars().map(escaped_len).sum::<usize>();
        assert!(json_len <= MAX_PART_ENCODED, "{json_len}");
        assert_eq!(part.total, Some(text.len() as u64));
        if let Some(done) = b.receive(part).expect("part") {
            out = Some(done);
        }
    }
    assert_eq!(out, Some((1, text)));
}

#[test]
fn a_text_over_the_bound_is_refused_and_counted_never_truncated() {
    let mut a = ClipboardSync::new();
    let big = "x".repeat(MAX_CLIPBOARD_TEXT + 1);
    assert_eq!(a.offer(&big), Offer::TooLarge);
    assert!(a.next_part(0).is_none());
    assert_eq!(a.dropped().local_too_large, 1);
    assert_eq!(a.offer(&"x".repeat(MAX_CLIPBOARD_TEXT)), Offer::Queued(1));
    let mut b = ClipboardSync::new();
    let part = ClipboardPart {
        seq: 1,
        text: "x".into(),
        offset: Some(0),
        total: Some(MAX_CLIPBOARD_TEXT as u64 + 1),
    };
    assert_eq!(b.receive(part), Err(PartError::TooLarge));
    let whole = ClipboardPart { seq: 2, text: big, offset: None, total: None };
    assert_eq!(b.receive(whole), Err(PartError::TooLarge));
    assert_eq!(b.dropped().remote_too_large, 2);
}

#[test]
fn the_peers_text_is_not_sent_back() {
    let mut host = ClipboardSync::new();
    let mut viewer = ClipboardSync::new();
    viewer.offer("from viewer");
    for part in drain(&mut viewer) {
        host.receive(part).expect("part");
    }
    // The host's pasteboard now changes to the viewer's text: no echo.
    assert_eq!(host.offer("from viewer"), Offer::Unchanged);
    // The viewer reads its own clipboard again: still the same.
    assert_eq!(viewer.offer("from viewer"), Offer::Unchanged);
    // A real change goes out.
    assert_eq!(host.offer("from host"), Offer::Queued(1));
}

#[test]
fn a_newer_text_replaces_the_unsent_parts_of_an_older_one() {
    let mut a = ClipboardSync::new();
    a.offer(&"o".repeat(MAX_PART_ENCODED * 3));
    let first = a.next_part(0).expect("first part");
    assert_eq!(a.offer("new"), Offer::Queued(2));
    let rest = drain(&mut a);
    assert_eq!(rest, vec![ClipboardPart { seq: 2, text: "new".into(), offset: None, total: None }]);
    let mut b = ClipboardSync::new();
    assert_eq!(b.receive(first), Ok(None));
    assert_eq!(b.receive(rest[0].clone()), Ok(Some((2, "new".into()))));
}

#[test]
fn parts_out_of_order_or_malformed_are_dropped() {
    let mut b = ClipboardSync::new();
    let p =
        |seq, text: &str, offset, total| ClipboardPart { seq, text: text.into(), offset, total };
    assert_eq!(b.receive(p(1, "ab", Some(2), Some(4))), Err(PartError::OutOfOrder));
    assert_eq!(b.receive(p(1, "ab", Some(0), None)), Err(PartError::Invalid));
    assert_eq!(b.receive(p(2, "ab", Some(0), Some(4))), Ok(None));
    assert_eq!(b.receive(p(2, "abc", Some(2), Some(4))), Err(PartError::Invalid));
    assert_eq!(b.receive(p(3, "x", None, None)), Ok(Some((3, "x".into()))));
    assert_eq!(b.receive(p(3, "y", None, None)), Err(PartError::OutOfOrder));
    assert_eq!(b.dropped().remote_invalid, 4);
}

#[test]
fn a_completed_peer_text_ends_a_local_text_being_sent() {
    let mut a = ClipboardSync::new();
    a.offer(&"o".repeat(MAX_PART_ENCODED * 3));
    a.next_part(0);
    assert!(a.sending());
    let peer = ClipboardPart { seq: 1, text: "peer".into(), offset: None, total: None };
    assert_eq!(a.receive(peer), Ok(Some((1, "peer".into()))));
    assert!(!a.sending());
    assert_eq!(a.offer("peer"), Offer::Unchanged);
}
