use super::*;

#[test]
fn plain_output_never_authors() {
    let mut p = CursorStyleProvenance::default();
    p.scan(b"hello world\r\nprompt $ ");
    assert!(!p.authored());
}

#[test]
fn decscusr_nonzero_authors_and_zero_resets() {
    let mut p = CursorStyleProvenance::default();
    p.scan(b"\x1b[5 q");
    assert!(p.authored());
    p.scan(b"\x1b[0 q");
    assert!(!p.authored());
    p.scan(b"\x1b[2 q");
    assert!(p.authored());
    p.scan(b"\x1b[ q");
    assert!(!p.authored(), "an absent parameter defaults to 0 (reset)");
}

#[test]
fn sequences_split_across_chunks_are_detected() {
    let mut p = CursorStyleProvenance::default();
    p.scan(b"\x1b");
    p.scan(b"[");
    p.scan(b"6");
    p.scan(b" ");
    assert!(!p.authored());
    p.scan(b"q");
    assert!(p.authored());
}

#[test]
fn ris_and_decstr_reset_authorship() {
    let mut p = CursorStyleProvenance::default();
    p.scan(b"\x1b[3 q");
    assert!(p.authored());
    p.scan(b"\x1bc");
    assert!(!p.authored());
    p.scan(b"\x1b[4 q");
    assert!(p.authored());
    p.scan(b"\x1b[!p");
    assert!(!p.authored());
}

#[test]
fn non_decscusr_csi_with_q_finals_do_not_author() {
    let mut p = CursorStyleProvenance::default();
    // DECLL (CSI Ps q, no space intermediate) and private-prefixed and
    // multi-parameter sequences must not count.
    p.scan(b"\x1b[1q");
    p.scan(b"\x1b[?5 q");
    p.scan(b"\x1b[1;2 q");
    assert!(!p.authored());
}

#[test]
fn string_bodies_are_skipped() {
    let mut p = CursorStyleProvenance::default();
    // An OSC body containing DECSCUSR-looking payload bytes is not CSI.
    p.scan(b"\x1b]0;cursor 5 q style\x07");
    assert!(!p.authored(), "OSC body must not author");
    p.scan(b"\x1bP+q544e\x1b\\");
    assert!(!p.authored(), "DCS body must not author");
    // A real DECSCUSR after the strings still counts.
    p.scan(b"\x1b[5 q");
    assert!(p.authored());
}

#[test]
fn c1_string_terminator_ends_all_string_bodies() {
    let mut p = CursorStyleProvenance::default();
    for opener in [b']', b'P', b'_', b'^', b'X'] {
        p.scan(&[0x1b, opener]);
        p.scan(b"payload 5 q");
        p.scan(&[0x9c]);
        assert!(!p.authored(), "string body payload must not author");
    }

    p.scan(b"\x1b[5 q");
    assert!(p.authored(), "C1 ST must return the parser to ground");
}

#[test]
fn c1_csi_decscusr_authors_and_resets() {
    let mut p = CursorStyleProvenance::default();
    // CSI may be encoded as the single C1 byte 0x9B instead of ESC [.
    p.scan(&[0x9b]);
    p.scan(b"5 ");
    p.scan(b"q");
    assert!(p.authored());
    p.scan(b"\x9b0 q");
    assert!(!p.authored());
}

#[test]
fn c1_string_introducers_skip_payload_until_st() {
    let mut p = CursorStyleProvenance::default();
    // Every ECMA-48 string opener has an 8-bit C1 spelling.  Payloads
    // can contain bytes that look like either 7-bit or 8-bit CSI, but
    // neither is a control sequence while the string is open.
    for opener in [0x90, 0x98, 0x9d, 0x9e, 0x9f] {
        p.scan(&[opener]);
        p.scan(b"payload \x9b6 q");
        assert!(!p.authored(), "C1 string payload must not author");
        p.scan(&[0x9c]);
    }

    p.scan(b"\x9b7 q");
    assert!(p.authored(), "C1 ST must return the parser to ground");
}

#[test]
fn c1_string_openers_and_st_split_across_chunks() {
    let mut p = CursorStyleProvenance::default();
    p.scan(&[0x9d]);
    p.scan(b"payload \x9b");
    p.scan(b"5 q");
    assert!(!p.authored());
    p.scan(&[0x9c]);
    p.scan(b"\x9b5 q");
    assert!(p.authored());
}

#[test]
fn replay_reset_clears_authorship_and_parser_state() {
    let mut p = CursorStyleProvenance::default();
    p.scan(b"\x1b[5 q\x1b[");
    assert!(p.authored());
    p.reset_for_replay();
    assert!(!p.authored());
    // Parser is back at ground: the next bytes parse from scratch.
    p.scan(b"6 q");
    assert!(!p.authored(), "stale partial CSI must not leak across a replay");
    p.scan(b"\x1b[6 q");
    assert!(p.authored());
}
