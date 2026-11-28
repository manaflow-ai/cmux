use super::*;
use crate::style::OVERLINE;

fn term(cols: usize, rows: usize, bytes: &[u8]) -> Terminal {
    let mut t = Terminal::new(cols, rows, 1000);
    for &b in bytes {
        t.advance(b);
    }
    t
}

fn feed(t: &mut Terminal, bytes: &[u8]) {
    for &b in bytes {
        t.advance(b);
    }
}

fn roundtrip(base: Option<&ScreenState>, latest: &ScreenState) -> usize {
    let payload = diff(base, latest);
    let got = apply(base, &payload).expect("apply");
    assert_eq!(&got, latest);
    payload.len()
}

#[test]
fn keyframe_and_diffs_round_trip() {
    let mut t = term(80, 24, b"$ echo hi\r\nhi\r\n$ ");
    let a = ScreenState::capture(&t);
    roundtrip(None, &a);
    feed(&mut t, b"\x1b[1;31mred\x1b[0m and \x1b[4:3;58;5;9mcurly\x1b[0m \x1b[7minv\x1b[27m");
    let b = ScreenState::capture(&t);
    let n = roundtrip(Some(&a), &b);
    assert!(n < 80, "small edit is small: {n}");
    roundtrip(None, &b);
    // Nothing changed: still a valid payload.
    roundtrip(Some(&b), &b);
}

#[test]
fn wide_emoji_and_combining_round_trip() {
    let text = "漢字 👍🏽 👨\u{200d}👩\u{200d}👧 🇯🇵 ❤\u{fe0f} cafe\u{301} क्ष \x1b]8;;https://x.y\x1b\\link\x1b]8;;\x1b\\";
    let mut bytes = text.as_bytes().to_vec();
    // A wide glyph at the last column leaves a spacer head.
    bytes.extend_from_slice(b"\r\n");
    bytes.extend_from_slice("x".repeat(19).as_bytes());
    bytes.extend_from_slice("中文".as_bytes());
    let t = term(20, 6, &bytes);
    let s = ScreenState::capture(&t);
    assert!(s.cells.iter().any(|c| c.width == WIDE));
    assert!(s.cells.iter().any(|c| c.width == WIDE_TAIL));
    assert!(s.cells.iter().any(|c| c.width == SPACER_HEAD));
    assert!(s.cells.iter().any(|c| c.text == "e\u{301}"));
    assert!(s.cells.iter().any(|c| !c.style.link.is_empty()));
    roundtrip(None, &s);
    roundtrip(Some(&ScreenState::blank(20, 6)), &s);
}

#[test]
fn styles_round_trip() {
    let t = term(
        60,
        4,
        b"\x1b[38;2;1;2;3;48;5;200;1;2;3;5;7;8;9;53mall\x1b[0m \x1b[21mdbl\x1b[0m\x1b[44m\x1b[K",
    );
    let s = ScreenState::capture(&t);
    assert!(s.cells.iter().any(|c| c.style.flags & OVERLINE != 0));
    roundtrip(None, &s);
}

#[test]
fn resize_is_a_keyframe_from_blank() {
    let mut t = term(80, 24, b"hello\r\nworld");
    let a = ScreenState::capture(&t);
    t.resize(100, 30);
    feed(&mut t, b"\x1b[Hresized");
    let b = ScreenState::capture(&t);
    let payload = diff(Some(&a), &b);
    assert_eq!(apply(Some(&a), &payload).unwrap(), b);
    assert_eq!(apply(None, &payload).unwrap(), b);
    // A diff from a base cannot be applied without it, or to another grid.
    let mut t2 = term(100, 30, b"x");
    let c = ScreenState::capture(&t2);
    feed(&mut t2, b"y");
    let d = ScreenState::capture(&t2);
    let payload = diff(Some(&c), &d);
    assert_eq!(apply(None, &payload), Err(SyncError::NoBase));
    // A version 3 diff names no grid (only a keyframe does): one applied to a base of
    // another grid is refused by its digest, which covers the grid.
    assert!(apply(Some(&a), &payload).is_err());
    // The wrong base of the right grid is caught by the digest.
    assert_eq!(apply(Some(&b), &payload), Err(SyncError::Digest));
}

#[test]
fn modes_cursor_and_alternate_are_captured() {
    let t = term(40, 10, b"\x1b[?1h\x1b=\x1b[?2004h\x1b[?1000h\x1b[?1006h\x1b[5 q\x1b[?25l\x1b[>5u\x1b[?1049h\x1b[3;7H");
    let s = ScreenState::capture(&t);
    assert!(s.alternate);
    for bit in [
        MODE_ALTERNATE,
        MODE_APP_CURSOR,
        MODE_KEYPAD_APP,
        MODE_BRACKETED_PASTE,
        MODE_MOUSE_NORMAL,
        MODE_MOUSE_SGR,
        MODE_GRAPHEME_CLUSTER,
    ] {
        assert_ne!(s.modes & bit, 0, "bit {bit:#x}");
    }
    assert_eq!(s.modes >> KITTY_FLAGS_SHIFT, 5);
    assert_eq!(s.cursor_shape, 5);
    assert!(!s.cursor_visible);
    assert_eq!(s.cursor, (6, 2));
    roundtrip(None, &s);
}

#[test]
fn a_typical_redraw_fits_one_datagram() {
    // Claude Code repaints its prompt box and status rows.
    let mut t = term(100, 40, b"");
    for i in 0..30 {
        feed(
            &mut t,
            format!("line {i} of earlier output, some text to fill the row\r\n").as_bytes(),
        );
    }
    let a = ScreenState::capture(&t);
    let frame = |n: usize| {
        format!(
            "\x1b[34;1H\x1b[38;5;174m╭{}╮\x1b[0m\r\n\x1b[38;5;174m│\x1b[0m > typing {n}{}\x1b[38;5;174m│\x1b[0m\r\n\x1b[38;5;174m╰{}╯\x1b[0m\r\n  \x1b[2m? for shortcuts · {n} tokens\x1b[0m\x1b[K\r\n\x1b[1m✻ Thinking… ({n}s · esc to interrupt)\x1b[0m\x1b[K",
            "─".repeat(98),
            " ".repeat(86),
            "─".repeat(98),
        )
    };
    feed(&mut t, frame(1).as_bytes());
    let b = ScreenState::capture(&t);
    feed(&mut t, frame(2).as_bytes());
    let c = ScreenState::capture(&t);
    let full = roundtrip(Some(&a), &b);
    let small = roundtrip(Some(&b), &c);
    assert!(full < 1100, "five new rows of 100 cols: {full} bytes");
    assert!(small < 100, "a counter tick: {small} bytes");
    assert_eq!(fragment(&diff(Some(&a), &b), 1200, 7, 2, 1).len(), 1);
}

// Sender and receiver.

#[test]
fn a_scroll_sends_row_moves_not_rows() {
    // A full-screen TUI scrolls its transcript by repainting every row
    // one line up (no DECSTBM): the diff names the moved rows.
    let line =
        |i: usize| format!("\x1b[38;5;{}m{i:04} {}\x1b[0m", i % 200, "reply text ".repeat(9));
    let paint = |top: usize| {
        let mut s = String::from("\x1b[H");
        for y in 0..38 {
            s.push_str(&format!("\x1b[{};1H{}\x1b[K", y + 1, line(top + y)));
        }
        s.push_str("\x1b[39;1H\x1b[2m status \x1b[0m\x1b[K\x1b[40;1H> \x1b[K");
        s
    };
    let mut t = term(120, 40, paint(0).as_bytes());
    let a = ScreenState::capture(&t);
    feed(&mut t, paint(1).as_bytes());
    let b = ScreenState::capture(&t);
    feed(&mut t, paint(4).as_bytes());
    let c = ScreenState::capture(&t);
    let one = roundtrip(Some(&a), &b);
    let three = roundtrip(Some(&b), &c);
    let keyframe = roundtrip(None, &b);
    assert!(one < 250, "a one-line scroll: {one} bytes (keyframe {keyframe})");
    assert!(three < 500, "a three-line scroll: {three} bytes (keyframe {keyframe})");
    // Scrolling back down too.
    assert!(roundtrip(Some(&c), &a) < 700);
}

fn states(n: usize) -> Vec<ScreenState> {
    let mut t = term(30, 8, b"");
    let mut out = Vec::new();
    for i in 0..n {
        feed(&mut t, format!("step {i} 漢 👍\r\n").as_bytes());
        out.push(ScreenState::capture(&t));
    }
    out
}

#[test]
fn in_order_delivery_and_acks() {
    let s = states(5);
    let mut tx = SyncSender::with_epoch(1200, 1);
    let mut rx = SyncReceiver::new();
    assert!(tx.datagrams().is_empty());
    for (i, state) in s.iter().enumerate() {
        assert_eq!(tx.update(state.clone()), i as u64 + 1);
        assert_eq!(tx.update(state.clone()), i as u64 + 1, "same state, same seq");
        for d in tx.datagrams() {
            if let Some(ack) = rx.on_datagram(&d) {
                tx.on_ack(&ack);
            }
        }
        assert_eq!(rx.screen(), Some(state));
        assert_eq!(tx.acked_seq(), i as u64 + 1);
        assert!(!tx.unacked());
        assert!(tx.datagrams().is_empty());
    }
}

#[test]
fn diffs_are_from_the_acked_state_and_newest_wins() {
    let s = states(4);
    let mut tx = SyncSender::with_epoch(1200, 1);
    let mut rx = SyncReceiver::new();
    tx.update(s[0].clone());
    let d1 = tx.datagrams();
    tx.update(s[1].clone());
    let d2 = tx.datagrams();
    // Both keyframes (nothing acked yet): base 0.
    assert_eq!(parse_diff_datagram(&d2[0]).unwrap().0.base, 0);
    // Reordered: 2 first, then the stale 1.
    let a2 = rx.on_datagram(&d2[0]).unwrap();
    assert_eq!(rx.seq(), 2);
    let a1 = rx.on_datagram(&d1[0]).unwrap();
    assert_eq!(rx.seq(), 2);
    assert_eq!(rx.screen(), Some(&s[1]));
    assert_eq!(parse_ack_datagram(&a1), Some((1, 2)));
    // Duplicate.
    assert!(rx.on_datagram(&d2[0]).is_some());
    assert_eq!(rx.seq(), 2);
    tx.on_ack(&a2);
    assert_eq!(tx.acked_seq(), 2);
    // A stale ack changes nothing.
    tx.on_ack(&ack_datagram(1, 1));
    assert_eq!(tx.acked_seq(), 2);
    // Unknown epoch, future seq: ignored.
    tx.on_ack(&ack_datagram(9, 2));
    tx.on_ack(&ack_datagram(1, 99));
    assert_eq!(tx.acked_seq(), 2);
    tx.update(s[2].clone());
    let d3 = tx.datagrams();
    assert_eq!(parse_diff_datagram(&d3[0]).unwrap().0.base, 2);
    // d3 lost; s[3] diffs from the acked 2 again.
    tx.update(s[3].clone());
    let d4 = tx.datagrams();
    let h = parse_diff_datagram(&d4[0]).unwrap().0;
    assert_eq!((h.seq, h.base), (4, 2));
    let a4 = rx.on_datagram(&d4[0]).unwrap();
    assert_eq!(rx.screen(), Some(&s[3]));
    // d3 arrives late: stale, ignored.
    rx.on_datagram(&d3[0]);
    assert_eq!(rx.screen(), Some(&s[3]));
    tx.on_ack(&a4);
    assert!(!tx.unacked());
}

#[test]
fn ten_diffs_in_a_row_on_an_unacked_base_all_apply() {
    let s = states(12);
    let mut tx = SyncSender::with_epoch(1200, 1);
    let mut rx = SyncReceiver::new();
    tx.update(s[0].clone());
    for d in tx.datagrams() {
        tx.on_ack(&rx.on_datagram(&d).unwrap());
    }
    assert_eq!(tx.acked_seq(), 1);
    // Every ack after this is lost: each diff is from seq 1, which the
    // phone no longer shows but still holds.
    for (i, st) in s.iter().enumerate().skip(1) {
        tx.update(st.clone());
        let d = tx.datagrams();
        assert_eq!(d.len(), 1);
        let h = parse_diff_datagram(&d[0]).unwrap().0;
        assert_eq!((h.seq, h.base), (i as u64 + 1, 1));
        rx.on_datagram(&d[0]);
        assert_eq!(rx.seq(), i as u64 + 1, "diff {i} applied");
        assert_eq!(rx.screen(), Some(st));
    }
    assert_eq!(tx.acked_seq(), 1);
}

#[test]
fn a_long_round_trip_applies_every_diff_without_keyframes() {
    // 60 Hz, 1.2 s round trip: 36 ticks each way, a new screen every tick.
    const ONE_WAY: usize = 36;
    let s = states(400);
    let mut tx = SyncSender::with_epoch(1200, 1);
    let mut rx = SyncReceiver::new();
    let mut to_phone: VecDeque<(usize, Vec<u8>)> = VecDeque::new();
    let mut to_host: VecDeque<(usize, Vec<u8>)> = VecDeque::new();
    let mut first_diff_seq = None;
    let mut max_kept = 0;
    for tick in 0..s.len() + 4 * ONE_WAY {
        if let Some(st) = s.get(tick) {
            tx.update(st.clone());
        }
        let acked_before = tx.acked_seq();
        while to_host.front().is_some_and(|a| a.0 <= tick) {
            tx.on_ack(&to_host.pop_front().unwrap().1);
        }
        assert!(tx.acked_seq() >= acked_before, "no keyframe fallback");
        if tick < s.len() {
            for d in tx.datagrams() {
                to_phone.push_back((tick + ONE_WAY, d));
            }
        }
        while to_phone.front().is_some_and(|d| d.0 <= tick) {
            let d = to_phone.pop_front().unwrap().1;
            let h = parse_diff_datagram(&d).unwrap().0;
            if h.base != 0 {
                first_diff_seq.get_or_insert(h.seq);
            } else {
                assert!(first_diff_seq.is_none(), "a keyframe after diffs began: {}", h.seq);
            }
            let ack = rx.on_datagram(&d).unwrap();
            assert_eq!(rx.seq(), h.seq, "diff {} from {} applied", h.seq, h.base);
            to_host.push_back((tick + ONE_WAY, ack));
        }
        max_kept = max_kept.max(rx.kept());
    }
    assert!(first_diff_seq.is_some_and(|f| f <= 2 * ONE_WAY as u64 + 2));
    assert_eq!(rx.screen(), s.last());
    assert!(!tx.unacked());
    assert!(max_kept <= 2 * ONE_WAY + 4, "kept {max_kept}");
}

#[test]
fn a_stale_ack_of_nothing_does_not_lock_out_the_held_state() {
    let s = states(3);
    let mut tx = SyncSender::with_epoch(1200, 1);
    let mut rx = SyncReceiver::new();
    tx.update(s[0].clone());
    let early = rx.on_datagram(&{
        // A fragment-less diff from a base the phone never had: acks 0.
        let mut d = Vec::new();
        diff_header(&mut d, 1, 5, 4, 0, 1);
        d
    });
    assert_eq!(parse_ack_datagram(early.as_ref().unwrap()), Some((1, 0)));
    for d in tx.datagrams() {
        tx.on_ack(&rx.on_datagram(&d).unwrap());
    }
    assert!(!tx.unacked());
    // The stale ack 0 arrives late: the sender restarts from a keyframe,
    // and the phone's ack of what it holds (the latest) settles it.
    tx.on_ack(early.as_ref().unwrap());
    assert!(tx.unacked());
    for d in tx.datagrams() {
        tx.on_ack(&rx.on_datagram(&d).unwrap());
    }
    assert!(!tx.unacked());
    // The same once the phone is behind the latest.
    tx.update(s[1].clone());
    for d in tx.datagrams() {
        tx.on_ack(&rx.on_datagram(&d).unwrap());
    }
    tx.update(s[2].clone());
    let lost = tx.datagrams();
    tx.on_ack(early.as_ref().unwrap());
    assert_eq!(tx.acked_seq(), 0);
    // The phone acks seq 2 (held) for the old diff: taken.
    let ack = rx.on_datagram(&lost[0]).unwrap();
    assert_eq!(rx.seq(), 3);
    tx.on_ack(&ack_datagram(1, 2));
    assert_eq!(tx.acked_seq(), 2);
    tx.on_ack(&ack);
    assert!(!tx.unacked());
    assert_eq!(rx.screen(), Some(&s[2]));
}

#[test]
fn a_base_not_held_is_ignored() {
    let s = states(3);
    let mut tx = SyncSender::with_epoch(1200, 1);
    let mut other = SyncReceiver::new();
    tx.update(s[0].clone());
    for d in tx.datagrams() {
        tx.on_ack(&other.on_datagram(&d).unwrap());
    }
    tx.update(s[1].clone());
    let d = tx.datagrams();
    // A phone that never got the keyframe (restarted): it holds nothing,
    // so a diff from base 1 is ignored and it acks 0.
    let mut fresh = SyncReceiver::new();
    let ack = fresh.on_datagram(&d[0]).unwrap();
    assert!(fresh.screen().is_none());
    assert_eq!(parse_ack_datagram(&ack), Some((1, 0)));
    // The ack of 0 makes the sender start over with a keyframe.
    tx.on_ack(&ack);
    assert_eq!(tx.acked_seq(), 0);
    let d = tx.datagrams();
    assert_eq!(parse_diff_datagram(&d[0]).unwrap().0.base, 0);
    fresh.on_datagram(&d[0]);
    assert_eq!(fresh.screen(), Some(&s[1]));
}

#[test]
fn a_new_sender_epoch_takes_over_with_a_keyframe() {
    let s = states(3);
    let mut rx = SyncReceiver::new();
    let mut a = SyncSender::with_epoch(1200, 1);
    for st in &s {
        a.update(st.clone());
        for d in a.datagrams() {
            a.on_ack(&rx.on_datagram(&d).unwrap());
        }
    }
    assert_eq!(rx.seq(), 3);
    let mut b = SyncSender::with_epoch(1200, 2);
    b.update(s[0].clone());
    for d in b.datagrams() {
        b.on_ack(&rx.on_datagram(&d).unwrap());
    }
    assert_eq!(rx.epoch(), Some(2));
    assert_eq!(rx.seq(), 1);
    assert_eq!(rx.screen(), Some(&s[0]));
    assert_eq!(b.acked_seq(), 1);
}

#[test]
fn fragments_reassemble_and_loss_is_recovered_by_resend() {
    let mut t = term(120, 40, b"");
    for i in 0..40 {
        feed(
            &mut t,
            format!("\x1b[3{}m{i:03} {}\x1b[0m\r\n", i % 8, "αβγ漢".repeat(20)).as_bytes(),
        );
    }
    let big = ScreenState::capture(&t);
    let mut tx = SyncSender::with_epoch(300, 3);
    let mut rx = SyncReceiver::new();
    tx.update(big.clone());
    let d = tx.datagrams();
    assert!(d.len() > 3, "fragmented: {}", d.len());
    assert!(d.iter().all(|x| x.len() <= 300));
    // Lose one fragment, deliver the rest out of order.
    let lost = d.len() / 2;
    for (i, x) in d.iter().enumerate().rev() {
        if i != lost {
            rx.on_datagram(x);
        }
    }
    assert!(rx.screen().is_none());
    // The resend (same datagrams) completes it; duplicates are fine.
    let again = tx.datagrams();
    assert_eq!(again, d);
    for x in &again {
        if let Some(ack) = rx.on_datagram(x) {
            tx.on_ack(&ack);
        }
    }
    assert_eq!(rx.screen(), Some(&big));
    assert!(!tx.unacked());
}

#[test]
fn stale_partials_are_dropped_for_newer_seqs() {
    let s = states(8);
    let mut tx = SyncSender::with_epoch(32, 4);
    let mut rx = SyncReceiver::new();
    let mut first_frags = Vec::new();
    for st in &s {
        tx.update(st.clone());
        let d = tx.datagrams();
        assert!(d.len() > 1);
        // Only the first fragment of every seq arrives.
        first_frags.push(d);
        rx.on_datagram(&first_frags.last().unwrap()[0]);
        assert!(rx.partials.len() <= PARTIALS);
    }
    assert!(rx.screen().is_none());
    // The newest seq completes.
    for x in first_frags.last().unwrap() {
        rx.on_datagram(x);
    }
    assert_eq!(rx.screen(), s.last());
    // Older partials cannot complete after it.
    for x in &first_frags[2] {
        rx.on_datagram(x);
    }
    assert_eq!(rx.screen(), s.last());
    assert!(rx.partials.iter().all(|p| p.seq > rx.seq()));
}

#[test]
fn an_ack_echoes_the_stamp_of_the_datagram_it_answers() {
    let s = states(2);
    let mut tx = SyncSender::with_epoch(1200, 3);
    let mut rx = SyncReceiver::new();
    tx.update(s[0].clone());
    let mut d = tx.datagrams();
    assert_eq!(d.len(), 1);
    assert_eq!(parse_diff_datagram(&d[0]).unwrap().0.stamp, 0);
    assert!(stamp_datagram(&mut d[0], 77));
    assert_eq!(parse_diff_datagram(&d[0]).unwrap().0.stamp, 77);
    let mut ack = rx.on_datagram(&d[0]).unwrap();
    assert_eq!(parse_ack_stamp(&ack), Some(77));
    assert_eq!(parse_ack_datagram(&ack), Some((3, 1)));
    assert!(!stamp_datagram(&mut ack, 1));
    // A stale copy is acked with its own stamp and the seq held.
    assert!(stamp_datagram(&mut d[0], 78));
    let again = rx.on_datagram(&d[0]).unwrap();
    assert_eq!(parse_ack_stamp(&again), Some(78));
    assert_eq!(parse_ack_datagram(&again), Some((3, 1)));
}

#[test]
fn malformed_datagrams_are_ignored() {
    let mut rx = SyncReceiver::new();
    assert!(rx.on_datagram(b"").is_none());
    assert!(rx.on_datagram(b"XX\x01").is_none());
    assert!(rx.on_datagram(&ack_datagram(1, 1)).is_none());
    let mut d = Vec::new();
    diff_header(&mut d, 1, 1, 0, 0, 1);
    d.extend_from_slice(&[VERSION_V2, 0, 5, 5, 0, 0, 0, 0]);
    assert!(rx.on_datagram(&d).is_some());
    assert!(rx.screen().is_none());
    for cut in 0..40 {
        let s = states(2);
        let payload = diff(None, &s[1]);
        let _ = apply(None, payload.get(..cut).unwrap_or_default());
    }
}

#[test]
fn lossy_channel_converges() {
    // Random drops, duplicates and reordering both ways.
    let s = states(30);
    let mut rng = 0x1234_5678_u64;
    let mut next = move || {
        rng ^= rng << 13;
        rng ^= rng >> 7;
        rng ^= rng << 17;
        rng % 100
    };
    let mut tx = SyncSender::with_epoch(120, 5);
    let mut rx = SyncReceiver::new();
    let mut to_phone: Vec<Vec<u8>> = Vec::new();
    let mut to_host: Vec<Vec<u8>> = Vec::new();
    for round in 0..2000 {
        if let Some(st) = s.get(round / 3) {
            tx.update(st.clone());
        }
        for d in tx.datagrams() {
            if next() >= 40 {
                to_phone.push(d.clone());
            }
            if next() < 10 {
                to_phone.push(d);
            }
        }
        // Deliver in a shuffled order.
        while !to_phone.is_empty() {
            let i = (next() as usize) % to_phone.len();
            let d = to_phone.swap_remove(i);
            if let Some(ack) = rx.on_datagram(&d)
                && next() >= 40
            {
                to_host.push(ack);
            }
        }
        while !to_host.is_empty() {
            let i = (next() as usize) % to_host.len();
            tx.on_ack(&to_host.swap_remove(i));
        }
        if round > s.len() * 3 && !tx.unacked() {
            break;
        }
    }
    assert!(!tx.unacked());
    assert_eq!(rx.screen(), s.last());
}

// History.

fn replay(cols: usize, bytes: &[u8]) -> Terminal {
    // A tall terminal holds what was written without scrolling.
    let mut t = Terminal::new(cols, 400, 1000);
    // RIS restarts it.
    for &b in bytes {
        t.advance(b);
    }
    t
}

fn texts(t: &Terminal, rows: &[Row]) -> Vec<(String, bool)> {
    rows.iter()
        .map(|r| {
            let mut s = String::new();
            for c in &r.cells {
                if c.kind == WIDE_TAIL || c.kind == SPACER_HEAD {
                    continue;
                }
                s.push_str(if c.ch == 0 { " " } else { "" });
                if c.ch != 0 {
                    s.push_str(&t.cell_text(*c));
                }
            }
            (s.trim_end().to_string(), r.wrapped)
        })
        .collect()
}

#[test]
fn history_rows_replay_exactly() {
    let mut host = Terminal::new(20, 4, 1000);
    let mut tracker = HistoryTracker::new();
    let mut stream = Vec::new();
    let chunks: Vec<String> = vec![
        "one\r\ntwo\r\n".into(),
        "\x1b[31mred\x1b[0m   gap\r\n".into(),
        format!("{}\r\n", "w".repeat(45)),
        format!("{}中文\r\n", "x".repeat(19)),
        "  lead\r\n漢字 👍🏽 e\u{301}\r\n".into(),
        "\x1b]8;;http://a\x1b\\lnk\x1b]8;;\x1b\\\r\n".into(),
        "a\r\nb\r\nc\r\nd\r\ne\r\n".into(),
    ];
    for c in &chunks {
        feed(&mut host, c.as_bytes());
        stream.extend(tracker.take_new_rows(&host));
    }
    let phone = replay(20, &stream);
    let n = host.history.len();
    let host_rows: Vec<Row> = host.history.iter().cloned().collect();
    let got = texts(&phone, phone.screen_rows().get(..n).unwrap());
    let want = texts(&host, &host_rows);
    assert_eq!(got, want);
    // Styles: the red cell.
    let red =
        phone.screen_rows().iter().flat_map(|r| &r.cells).find(|c| c.ch == u32::from('r')).unwrap();
    assert_eq!(phone.styles.get(red.style).fg, Color::Indexed(1));
    // Nothing new: nothing written.
    assert!(tracker.take_new_rows(&host).is_empty());
    // The alternate screen adds nothing.
    feed(&mut host, b"\x1b[?1049hfoo\r\nbar\r\n\r\n\r\n\r\n");
    assert!(tracker.take_new_rows(&host).is_empty());
    feed(&mut host, b"\x1b[?1049l");
    // A scrollback clear starts over.
    feed(&mut host, b"\x1b[3Jnew\r\n1\r\n2\r\n3\r\n");
    let again = tracker.take_new_rows(&host);
    assert!(again.starts_with(b"\x1bc"));
    let phone = replay(20, &again);
    let host_rows: Vec<Row> = host.history.iter().cloned().collect();
    assert_eq!(
        texts(&phone, phone.screen_rows().get(..host_rows.len()).unwrap()),
        texts(&host, &host_rows)
    );
}
