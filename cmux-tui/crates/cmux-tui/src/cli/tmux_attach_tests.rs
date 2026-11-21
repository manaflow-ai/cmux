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

#[test]
fn the_snapshot_puts_the_cursor_on_the_panes_screen() {
    let snapshot =
        Snapshot { text: "old\nscreen 1\nscreen 2\n".into(), cursor_x: 4, cursor_y: 1, height: 2 };
    let bytes = String::from_utf8(snapshot_bytes(&snapshot, 24)).unwrap();
    assert!(bytes.contains("old\r\nscreen 1\r\nscreen 2"));
    assert!(bytes.ends_with("\x1b[3;5H"), "{bytes:?}");
    // History taller than the terminal: the screen ends on the bottom row.
    let tall = Snapshot { text: "x\n".repeat(100), cursor_x: 0, cursor_y: 0, height: 24 };
    assert!(String::from_utf8(snapshot_bytes(&tall, 24)).unwrap().ends_with("\x1b[1;1H"));
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

struct Cleanup(Tmux);

impl Drop for Cleanup {
    fn drop(&mut self) {
        let _ = self.0.output(&["kill-server"]);
    }
}
