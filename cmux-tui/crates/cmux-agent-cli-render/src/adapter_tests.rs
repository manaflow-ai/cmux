use super::*;

#[test]
fn agents_and_every_other_program() {
    assert_eq!(Adapter::of(Some("claude")), Adapter::Agent);
    assert_eq!(Adapter::of(Some("opencode")), Adapter::Agent);
    assert_eq!(Adapter::of(Some("vim")), Adapter::Lines);
    assert_eq!(Adapter::of(None), Adapter::Lines);
}

#[test]
fn a_full_screen_mode_set_is_found_where_it_starts() {
    let mut scan = FullScreenScan::new();
    assert_eq!(scan.scan(b"ls\r\n\x1b[1;32mok\x1b[0m\x1b[?25l\x1b[?2004h"), None);
    let found = scan.scan(b"abc\x1b[?1049h\x1b[H").unwrap();
    assert_eq!(found, FullScreenStart { carried: Vec::new(), at: 3 });
    // Among other modes, and mouse tracking.
    assert_eq!(scan.scan(b"\x1b[?12;1002hx").unwrap().at, 0);
    // A reset is not a set.
    assert_eq!(scan.scan(b"\x1b[?1049l\x1b[?1000l"), None);
}

#[test]
fn input_modes_are_handed_on_and_drawing_is_not() {
    let mut scan = FullScreenScan::new();
    assert_eq!(scan.scan(b"\x1b[?2004h$ \x1b[1mls\x1b[0m\x1b[?1h\x1b=\x1b[?25l\x1b[?20"), None);
    assert_eq!(scan.scan(b"04l\x1b[?2004;1004h"), None);
    assert_eq!(scan.take_modes(), b"\x1b[?2004h\x1b[?1h\x1b=\x1b[?2004l\x1b[?2004;1004h".to_vec());
    assert!(scan.take_modes().is_empty());
    // A sequence that also sets something else is not handed on.
    assert_eq!(scan.scan(b"\x1b[?2004;25h"), None);
    assert!(scan.take_modes().is_empty());
}

#[test]
fn a_mode_set_split_across_writes_carries_its_start() {
    let mut scan = FullScreenScan::new();
    assert_eq!(scan.scan(b"vim\r\n\x1b[?10"), None);
    let found = scan.scan(b"49h\x1b[H").unwrap();
    assert_eq!(found, FullScreenStart { carried: b"\x1b[?10".to_vec(), at: 0 });
    assert_eq!(scan.scan(b"\x1b"), None);
    assert_eq!(scan.scan(b"["), None);
    let found = scan.scan(b"?47h").unwrap();
    assert_eq!(found.carried, b"\x1b[".to_vec());
}
