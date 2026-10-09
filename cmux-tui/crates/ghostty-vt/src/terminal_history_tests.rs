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
