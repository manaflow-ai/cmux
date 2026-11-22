//! Row marker and history page tests.

use super::*;

fn term(rows: u16, scrollback: usize) -> Terminal {
    Terminal::new(40, rows, scrollback, Callbacks::default()).unwrap()
}

fn write_lines(term: &mut Terminal, from: usize, to: usize) {
    for line in from..to {
        term.vt_write(format!("line {line}\r\n").as_bytes());
    }
}

#[test]
fn snapshot_history_markers_do_not_move_with_new_output() {
    let mut t = term(4, 1 << 22);
    write_lines(&mut t, 0, 50);
    let epoch = t.history_marker_epoch();
    let marker = t.history_marker(10);
    let before = t.read_marker_range(Some(epoch), (marker, 0), (marker, 39), false).unwrap();
    assert_eq!(before, "line 10");
    write_lines(&mut t, 50, 400);
    assert_eq!(t.history_marker_epoch(), epoch);
    let after = t.read_marker_range(Some(epoch), (marker, 0), (marker, 39), false).unwrap();
    assert_eq!(after, "line 10");
}

#[test]
fn snapshot_history_evicted_markers_report_range_evicted() {
    // A small byte budget: old pages are evicted as output flows.
    let mut t = term(4, 64 * 1024);
    write_lines(&mut t, 0, 10);
    let epoch = t.history_marker_epoch();
    let first = t.history_marker(0);
    write_lines(&mut t, 10, 200_000);
    assert_eq!(t.history_marker_epoch(), epoch, "eviction must not end the epoch");
    assert_eq!(
        t.read_marker_range(Some(epoch), (first, 0), (first, 39), false),
        Err(MarkerError::RangeEvicted)
    );
    // The newest history row is still addressable and reads back exactly.
    let newest = t.active_top_marker() - 1;
    let text = t.read_marker_range(Some(epoch), (newest, 0), (newest, 39), false).unwrap();
    assert!(text.starts_with("line "), "{text:?}");
}

#[test]
fn snapshot_history_reflow_starts_a_new_marker_epoch() {
    let mut t = term(4, 1 << 22);
    write_lines(&mut t, 0, 50);
    let epoch = t.history_marker_epoch();
    t.resize(30, 4, 8, 16).unwrap();
    assert_ne!(t.history_marker_epoch(), epoch);
    assert_eq!(
        t.read_marker_range(Some(epoch), (0, 0), (0, 10), false),
        Err(MarkerError::RangeEvicted)
    );
}

#[test]
fn snapshot_history_pages_walk_to_the_top_newest_first() {
    let mut t = term(4, 1 << 24);
    write_lines(&mut t, 0, 20_000);
    let epoch = t.history_marker_epoch();
    let mut before = None;
    let mut seen_rows = 0u64;
    let mut last_marker = u64::MAX;
    loop {
        let page = t.history_pages(Some(epoch), before, 64 * 1024).unwrap();
        assert_eq!(page.marker_epoch, epoch);
        for p in &page.pages {
            assert!(p.marker < last_marker, "newest first");
            last_marker = p.marker;
            seen_rows += u64::from(p.rows);
            assert_eq!(
                crate::snapshot::snapshot_records(&{
                    let mut stream = b"GHOSTSNP\x01\x00".to_vec();
                    stream.extend_from_slice(&p.record);
                    stream
                })
                .next()
                .unwrap()
                .tag,
                crate::snapshot::tag::PAGE
            );
        }
        if page.done {
            break;
        }
        before = page.next_before;
        assert!(before.is_some());
    }
    assert_eq!(last_marker, t.history_marker(0));
    assert!(seen_rows > 0 && seen_rows <= t.scrollback_rows() as u64);
}

#[test]
fn snapshot_history_read_range_vt_format_carries_escape_sequences() {
    let mut t = term(4, 1 << 22);
    t.vt_write(b"\x1b[31mred\x1b[0m\r\n");
    write_lines(&mut t, 0, 10);
    let epoch = t.history_marker_epoch();
    let marker = t.history_marker(0);
    let vt = t.read_marker_range(Some(epoch), (marker, 0), (marker, 39), true).unwrap();
    assert!(vt.contains("red"), "{vt:?}");
    assert!(vt.contains('\x1b'), "{vt:?}");
}

#[test]
fn snapshot_history_markers_survive_the_alternate_screen() {
    let mut t = term(4, 1 << 22);
    write_lines(&mut t, 0, 50);
    let epoch = t.history_marker_epoch();
    let marker = t.history_marker(10);
    t.vt_write(b"\x1b[?1049h\x1b[2Jeditor\r\nmore\r\n");
    t.vt_write(b"still editing\r\n");
    t.vt_write(b"\x1b[?1049l");
    write_lines(&mut t, 50, 60);
    assert_eq!(t.history_marker_epoch(), epoch, "vim must not end the marker epoch");
    let text = t.read_marker_range(Some(epoch), (marker, 0), (marker, 39), false).unwrap();
    assert_eq!(text, "line 10");
}

#[test]
fn snapshot_history_markers_ignore_reverse_index_and_inserted_lines() {
    let mut t = term(4, 1 << 22);
    write_lines(&mut t, 0, 50);
    let epoch = t.history_marker_epoch();
    let marker = t.history_marker(20);
    // Cursor home, reverse index (scrolls the active area down), insert lines.
    t.vt_write(b"\x1b[H\x1bM\x1b[2L\x1b[4;1H");
    write_lines(&mut t, 50, 80);
    assert_eq!(t.history_marker_epoch(), epoch);
    let text = t.read_marker_range(Some(epoch), (marker, 0), (marker, 39), false).unwrap();
    assert_eq!(text, "line 20");
}
