use super::*;

/// A frame line of kind 3 whose payload is `bytes` long.
fn line(bytes: usize) -> String {
    let pad = "a".repeat(bytes - r#"{"x":""}"#.len());
    format!(
        r#"{{"jsonrpc":"2.0","method":"_acpmux/v2","params":{{"kind":3,"payload":{{"x":"{pad}"}}}}}}"#
    ) + "\n"
}

#[test]
fn a_line_counts_its_frame_bytes() {
    let line = line(1000);
    assert!(link_v2::is_frame_line(&line));
    assert_eq!(link_v2::parse(&line).map(|frame| frame.payload.len()), Some(1000));
    assert_eq!(link_v2::frame_bytes(&line), 1000 + 5);
}

/// A peer that ignores credit: nothing drains the inbox. Frames queue up
/// to the bound, the first past it ends the mirror and is counted, and the
/// bytes held never pass the bound.
#[test]
fn a_peer_past_its_credit_ends_the_mirror_at_the_bound() {
    let counters = Arc::new(DialCounters::default());
    let (inbox, mut lines) = Inbox::new(7, counters.clone());
    let frame = 64 * 1024;
    let mut queued = 0;
    let end = loop {
        match inbox.offer(7, line(frame)) {
            Offer::Queued => queued += 1,
            other => break other,
        }
        assert!(inbox.held() <= MIRROR_INBOX_BYTES as u64);
    };
    assert_eq!(end, Offer::Overflow);
    assert_eq!(queued, MIRROR_INBOX_BYTES / (frame + 5));
    assert_eq!(counters.inbox_overflows.load(Ordering::Relaxed), 1);
    let mut held = 0;
    while let Some(line) = lines.try_recv() {
        held += link_v2::frame_bytes(&line);
    }
    assert_eq!(held as u64, inbox.held());
    assert!(held <= MIRROR_INBOX_BYTES);
}

/// A peer within its credit: the mirror takes each frame, and the inbox
/// never fills however many frames come.
#[test]
fn a_peer_within_its_credit_never_fills_the_inbox() {
    let counters = Arc::new(DialCounters::default());
    let (inbox, mut lines) = Inbox::new(7, counters.clone());
    for _ in 0..1000 {
        assert_eq!(inbox.offer(7, line(200 * 1024)), Offer::Queued);
        let line = lines.try_recv().expect("the queued line");
        lines.handed(&line);
    }
    assert_eq!(inbox.held(), 0);
    assert_eq!(counters.inbox_overflows.load(Ordering::Relaxed), 0);
}

#[test]
fn a_line_of_another_link_is_dropped() {
    let counters = Arc::new(DialCounters::default());
    let (inbox, _lines) = Inbox::new(7, counters.clone());
    assert_eq!(inbox.offer(8, line(100)), Offer::Dropped);
    assert_eq!(inbox.held(), 0);
}

/// An earlier link's task can hand a line after the next link's inbox
/// opened (it was inside the adapter's deliver). It takes the bytes off
/// its own inbox's count: the new inbox's count does not wrap, and it
/// takes a frame.
#[test]
fn an_old_link_handing_a_line_leaves_the_new_inbox_whole() {
    let counters = Arc::new(DialCounters::default());
    let (old, mut old_lines) = Inbox::new(7, counters.clone());
    assert_eq!(old.offer(7, line(100 * 1024)), Offer::Queued);
    let buffered = old_lines.try_recv().expect("the buffered line");
    let (new, mut new_lines) = Inbox::new(8, counters.clone());
    old_lines.handed(&buffered);
    assert_eq!(new.held(), 0);
    assert_eq!(new.offer(8, line(1000)), Offer::Queued);
    assert_eq!(new.held(), 1005);
    assert!(new_lines.try_recv().is_some());
    assert_eq!(counters.inbox_overflows.load(Ordering::Relaxed), 0);
}
