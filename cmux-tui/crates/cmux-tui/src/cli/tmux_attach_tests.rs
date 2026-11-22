use super::*;

#[test]
fn output_is_unescaped_and_names_its_pane() {
    let mut parser = Parser::default();
    assert_eq!(
        parser.line(b"%output %3 hi\\015\\012back\\134slash\n"),
        Event::Output { pane: "%3".into(), bytes: b"hi\r\nback\\slash".to_vec() }
    );
}

#[test]
fn a_reply_hides_lines_that_look_like_notifications() {
    let mut parser = Parser::default();
    assert_eq!(parser.line(b"%begin 1700000000 12 1\n"), Event::Other);
    assert_eq!(parser.line(b"%output %3 not output\n"), Event::Other);
    assert_eq!(parser.line(b"%exit\n"), Event::Other);
    assert_eq!(parser.line(b"%end 1700000000 12 1\n"), Event::Other);
    assert_eq!(parser.line(b"%exit\n"), Event::Exit);
    assert_eq!(parser.line(b"%begin 1 13 1\n"), Event::Other);
    assert_eq!(parser.line(b"%error 1 13 1\n"), Event::Other);
    assert_eq!(
        parser.line(b"%layout-change @2 b25d,80x24,0,0,3 b25d,80x24,0,0,3 *\n"),
        Event::WindowChanged { window: "@2".into() }
    );
}

#[test]
fn unescape_keeps_a_backslash_without_three_octal_digits() {
    assert_eq!(unescape(b"a\\9b\\01"), b"a\\9b\\01".to_vec());
    assert_eq!(unescape(b"\\033[1m"), b"\x1b[1m".to_vec());
}

#[test]
fn keys_go_as_hex_in_bounded_commands() {
    assert_eq!(send_keys("%1", b"\x1b[A"), "send-keys -H -t %1 1b 5b 41\n");
    let commands = send_keys("%1", &[b'x'; 300]);
    assert_eq!(commands.lines().count(), 3);
}

#[test]
fn enter_tilde_dot_detaches_and_sends_what_came_before() {
    let mut key = DetachKey::default();
    assert_eq!(key.scan(b"ls\r~."), (3, true));
    let mut key = DetachKey::default();
    assert_eq!(key.scan(b"a~."), (3, false));
    let mut key = DetachKey::default();
    assert_eq!(key.scan(b"\r"), (1, false));
    assert_eq!(key.scan(b"~"), (1, false));
    assert_eq!(key.scan(b"."), (0, true));
}

#[test]
fn a_pane_line_needs_all_three_ids() {
    assert_eq!(
        parse_pane("%4 $1 @2\n"),
        Some(Pane { id: "%4".into(), session: "$1".into(), window: "@2".into() })
    );
    assert_eq!(parse_pane("4 $1 @2"), None);
    assert_eq!(parse_pane("%4 $1"), None);
}

/// A pane at rest: main screen, visible cursor, no modes set.
fn plain(cursor_x: u16, cursor_y: u16, height: u16) -> Modes {
    parse_modes(&format!(
        "0,1,0,0,0,0,1,0,0,0,0,0,0,{},{cursor_x},{cursor_y},{height},0,0,0",
        height - 1
    ))
    .unwrap()
}

#[test]
fn the_snapshot_puts_the_cursor_on_the_panes_screen() {
    let snapshot = Snapshot {
        text: "old\nscreen 1\nscreen 2\n".into(),
        alternate: None,
        modes: plain(4, 1, 2),
    };
    let bytes = String::from_utf8(snapshot_bytes(&snapshot, 24)).unwrap();
    assert!(bytes.contains("old\r\nscreen 1\r\nscreen 2"));
    assert!(bytes.ends_with("\x1b[0m\x1b[3;5H"), "{bytes:?}");
    // History taller than the terminal: the screen ends on the bottom row.
    let tall = Snapshot { text: "x\n".repeat(100), alternate: None, modes: plain(0, 0, 24) };
    assert!(String::from_utf8(snapshot_bytes(&tall, 24)).unwrap().ends_with("\x1b[1;1H"));
}

#[test]
fn modes_parse_in_format_order_and_unknown_flags_keep_defaults() {
    let modes = parse_modes("1,0,1,1,0,0,1,0,1,0,1,0,2,9,3,4,24,5,6,8\n").expect("twenty fields");
    assert!(modes.alternate && !modes.cursor_visible && modes.cursor_keys && modes.keypad);
    assert_eq!(modes.mouse, Some(1002));
    assert!(modes.mouse_sgr && !modes.mouse_utf8);
    assert_eq!(modes.scroll_region, (2, 9));
    assert!(modes.has_scroll_region());
    assert_eq!((modes.cursor_x, modes.cursor_y, modes.height), (3, 4, 24));
    assert_eq!((modes.saved_x, modes.saved_y, modes.history), (5, 6, 8));
    // An older tmux prints nothing for a variable it lacks (`mouse_all_flag`).
    let old = parse_modes("0,,0,0,0,0,,1,0,,0,0,0,23,0,0,24,0,0,0").unwrap();
    assert!(old.cursor_visible && old.wrap);
    assert_eq!(old.mouse, Some(1000));
    assert!(!old.has_scroll_region());
    assert_eq!(parse_modes("0,1,0"), None);
}

#[test]
fn a_full_screen_program_comes_back_on_the_alternate_screen() {
    let modes = parse_modes("1,0,1,0,0,0,1,0,0,1,1,0,0,1,7,1,2,0,1,3").unwrap();
    let snapshot = Snapshot {
        text: "h1\nh2\nh3\nmain 1\nmain 2\n".into(),
        alternate: Some("vim 1\nvim 2\n".into()),
        modes,
    };
    let bytes = String::from_utf8(snapshot_bytes(&snapshot, 24)).unwrap();
    // History and the main screen first, the main cursor parked on it,
    // then the alternate screen over them with the program's own cursor.
    let main = bytes.find("h1\r\nh2\r\nh3\r\nmain 1\r\nmain 2").expect("main screen");
    let parked = bytes.find("\x1b[5;1H\x1b[?1049h").expect("main cursor, then alternate");
    let program = bytes.find("vim 1\r\nvim 2").expect("alternate screen");
    assert!(main < parked && parked < program, "{bytes:?}");
    for mode in ["\x1b[?25l", "\x1b[?1h", "\x1b[?1003h", "\x1b[?1006h"] {
        assert!(bytes[program..].contains(mode), "{mode:?} in {bytes:?}");
    }
    assert!(!bytes.contains("\x1b[?1002h") && !bytes.contains("\x1b=") && !bytes.contains("r\x1b"));
    assert!(bytes.ends_with("\x1b[2;8H"), "{bytes:?}");
}

#[test]
fn a_scroll_region_is_set_before_the_cursor_and_origin_counts_from_it() {
    let modes = parse_modes("0,1,0,0,0,1,0,0,0,0,0,0,2,9,0,5,24,0,0,0").unwrap();
    let snapshot = Snapshot { text: "line\n".repeat(24), alternate: None, modes };
    let bytes = String::from_utf8(snapshot_bytes(&snapshot, 24)).unwrap();
    assert!(bytes.contains("\x1b[?7l"), "{bytes:?}");
    assert!(bytes.ends_with("\x1b[3;10r\x1b[?6h\x1b[4;1H"), "{bytes:?}");
}

#[test]
fn leaving_puts_the_terminal_back() {
    let on = parse_modes("1,1,1,1,0,1,1,0,1,0,1,0,2,9,0,0,24,0,0,0").unwrap();
    let bytes = String::from_utf8(leave_bytes(Some(&on))).unwrap();
    for reset in ["\x1b[?1l", "\x1b>", "\x1b[?1002l", "\x1b[?1006l", "\x1b[?6l", "\x1b[r"] {
        assert!(bytes.contains(reset), "{reset:?} in {bytes:?}");
    }
    assert!(bytes.ends_with("\x1b[?1049l"), "the alternate screen is left last: {bytes:?}");
    // Nothing that homes the cursor when the pane never set it, or is gone.
    let off = plain(0, 0, 24);
    for bytes in [leave_bytes(Some(&off)), leave_bytes(None)] {
        let bytes = String::from_utf8(bytes).unwrap();
        assert!(!bytes.contains("\x1b[r") && !bytes.contains("\x1b[?6l"), "{bytes:?}");
        assert!(!bytes.contains("1049"), "{bytes:?}");
    }
}

/// The whole path against a real tmux server on a private socket:
/// resolve the pane, snapshot its history, stream its `%output`, type
/// into it with `send-keys -H`, detach and leave it running.
#[test]
fn attaches_to_a_real_tmux_pane() {
    if Command::new("tmux").arg("-V").output().is_err() {
        eprintln!("skipped: no tmux on PATH");
        return;
    }
    let tmux = Tmux { socket: Some(format!("cmux-test-{}", std::process::id())) };
    tmux.output(&[
        "new-session",
        "-d",
        "-s",
        "probe",
        "-x",
        "80",
        "-y",
        "24",
        "printf 'first line\\n'; exec cat",
    ])
    .expect("tmux new-session");
    let cleanup = Cleanup(tmux.clone());

    let pane = resolve(&tmux, Some("probe")).expect("resolve");
    let mut history = String::new();
    for _ in 0..50 {
        history = snapshot(&tmux, &pane.id).expect("snapshot").text;
        if history.contains("first line") {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    assert!(history.contains("first line"), "{history:?}");

    std::thread::scope(|scope| {
        let gateway = Gateway::start(scope, &tmux, &pane.session).expect("gateway");
        assert!(gateway.send("refresh-client -C 80x24\n"));
        assert!(gateway.send(&send_keys(&pane.id, b"typed\r")));
        let mut seen = Vec::new();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while std::time::Instant::now() < deadline
            && !String::from_utf8_lossy(&seen).contains("typed")
        {
            if let Ok(Event::Output { pane: id, bytes }) =
                gateway.events.recv_timeout(std::time::Duration::from_millis(100))
            {
                assert_eq!(id, pane.id);
                seen.extend(bytes);
            }
        }
        assert!(String::from_utf8_lossy(&seen).contains("typed"), "{seen:?}");
        gateway.close();
    });
    assert!(pane_alive(&tmux, &pane.id), "detaching left the pane running");
    drop(cleanup);
}

/// A real pane with a full-screen program on tmux's alternate screen: the
/// snapshot keeps the history and main screen apart from the program's
/// screen, and carries the modes the program set.
#[test]
fn snapshots_a_real_panes_alternate_screen_and_modes() {
    if Command::new("tmux").arg("-V").output().is_err() {
        eprintln!("skipped: no tmux on PATH");
        return;
    }
    let tmux = Tmux { socket: Some(format!("cmux-test-alt-{}", std::process::id())) };
    tmux.output(&[
        "new-session",
        "-d",
        "-s",
        "full",
        "-x",
        "40",
        "-y",
        "5",
        "seq 1 12; printf '\\033[?1049h\\033[?1h\\033[?1002h\\033[?1006h\\033[HFULL SCREEN'; exec cat",
    ])
    .expect("tmux new-session");
    let cleanup = Cleanup(tmux.clone());
    let pane = resolve(&tmux, Some("full")).expect("resolve");
    let mut found = None;
    for _ in 0..50 {
        let snapshot = snapshot(&tmux, &pane.id).expect("snapshot");
        if snapshot.alternate.as_deref().is_some_and(|screen| screen.contains("FULL SCREEN")) {
            found = Some(snapshot);
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    let snapshot = found.expect("the alternate screen");
    assert!(snapshot.modes.alternate && snapshot.modes.cursor_keys, "{:?}", snapshot.modes);
    assert_eq!(snapshot.modes.mouse, Some(1002));
    assert!(snapshot.modes.mouse_sgr);
    // History (1..8) then the main screen (9..12): every number, none on the program's screen.
    let numbers: Vec<&str> = snapshot.text.lines().filter(|line| !line.is_empty()).collect();
    assert_eq!(numbers, (1..=12).map(|n| n.to_string()).collect::<Vec<_>>(), "{:?}", snapshot.text);
    assert!(!snapshot.text.contains("FULL SCREEN"));
    drop(cleanup);
}

struct Cleanup(Tmux);

impl Drop for Cleanup {
    fn drop(&mut self) {
        let _ = self.0.output(&["kill-server"]);
    }
}
