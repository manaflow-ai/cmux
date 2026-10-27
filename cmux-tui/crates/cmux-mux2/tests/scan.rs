//! mux2d's query scan (src/macos/mux2d_scan.rs is portable; mux2d is macOS
//! only): any byte string gets an answer, never a panic.

#[path = "../src/macos/mux2d_scan.rs"]
mod scan;

use scan::{incomplete_tail_start, needs_immediate_parse};

#[test]
fn queries_need_an_immediate_parse() {
    assert!(needs_immediate_parse(b"ab\x1b[c")); // DA1
    assert!(needs_immediate_parse(b"\x1b[6n")); // DSR/CPR
    assert!(needs_immediate_parse(b"\x1b]11;?\x07")); // OSC
    assert!(needs_immediate_parse(b"\x05")); // ENQ
    assert!(needs_immediate_parse(b"\x1b\x07[c")); // a C0 control inside ESC [
    assert!(needs_immediate_parse(b"\x1b[1\x1b[c")); // ESC cuts a CSI, then DA1
    // Cut short: the sequence may still become a query.
    assert!(needs_immediate_parse(b"\x1b"));
    assert!(needs_immediate_parse(b"\x1b[12"));
    assert!(!needs_immediate_parse(b""));
    assert!(!needs_immediate_parse(b"plain \x1b[1mbold\x1b[0m"));
}

#[test]
fn an_unfinished_csi_at_the_end_is_held_back() {
    assert_eq!(incomplete_tail_start(b""), 0);
    assert_eq!(incomplete_tail_start(b"abc"), 3);
    assert_eq!(incomplete_tail_start(b"ab\x1b"), 2);
    assert_eq!(incomplete_tail_start(b"ab\x1b[1;2"), 2);
    assert_eq!(incomplete_tail_start(b"ab\x1b[1m"), 6); // complete
    assert_eq!(incomplete_tail_start(b"ab\x1b]0;t"), 7); // not a CSI
    // Only the last 64 bytes are looked at.
    let mut long = b"\x1b[".to_vec();
    long.extend(std::iter::repeat_n(b'1', 70));
    assert_eq!(incomplete_tail_start(&long), long.len());
    let mut short = vec![b'x'; 70];
    short.extend_from_slice(b"\x1b[1");
    assert_eq!(incomplete_tail_start(&short), 70);
}
