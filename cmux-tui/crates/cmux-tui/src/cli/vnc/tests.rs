use crossterm::event::{
    KeyCode, KeyEvent, KeyEventKind, KeyEventState, KeyModifiers, ModifierKeyCode,
};

use super::keys::{Command, KeyAction, Keyboard};
use super::layout::{Pane, Placement, scale_rgb};
use super::*;

fn strings(args: &[&str]) -> Vec<String> {
    args.iter().map(|arg| (*arg).to_owned()).collect()
}

fn no_env(_: &str) -> Option<String> {
    None
}

fn parsed(args: &[&str]) -> Config {
    parse(&strings(args), &no_env).unwrap().unwrap()
}

#[test]
fn vnc_parses_addresses_machines_and_proxies() {
    let config = parsed(&["mac-mini.local:1"]);
    assert_eq!(config.target, Target::Tcp(Endpoint { host: "mac-mini.local".into(), port: 5901 }));
    assert_eq!(config.label, "mac-mini.local:5901");
    assert_eq!(config.resize, ResizeMode::Auto);
    assert!(config.reconnect);
    assert_eq!(config.fps, 30);
    assert!(!config.remote_clipboard);

    let config = parsed(&["machine:m_123"]);
    assert_eq!(config.target, Target::Machine { id: "m_123".into(), port: 5901 });
    let config = parsed(&["machine:m_123", "--port=5902"]);
    assert_eq!(config.target, Target::Machine { id: "m_123".into(), port: 5902 });

    let config = parsed(&[
        "--proxy-command",
        "ssh -W localhost:5901 box",
        "--view-only",
        "--resize",
        "scale",
    ]);
    assert_eq!(config.target, Target::Proxy("ssh -W localhost:5901 box".into()));
    assert!(config.view_only);
    assert_eq!(config.resize, ResizeMode::Scale);

    let config =
        parsed(&["h", "--fps", "60", "--no-reconnect", "--mouse", "cells", "--username", "leo"]);
    assert_eq!(config.fps, 60);
    assert!(!config.reconnect);
    assert_eq!(config.pixel_mouse, Some(false));
    assert_eq!(config.credentials.username.as_deref(), Some("leo"));
    assert!(parsed(&["h", "--remote-clipboard"]).remote_clipboard);

    assert!(parse(&strings(&["--help"]), &no_env).unwrap().is_none());
}

#[test]
fn vnc_refuses_bad_arguments() {
    for args in [
        &[][..],
        &["a", "b"],
        &["host", "--fps", "0"],
        &["host", "--resize", "stretch"],
        &["host", "--port", "5901"],
        &["machine:"],
        &["host", "--proxy-command", "nc x 1"],
        &["host", "--bogus"],
        &["host:notaport"],
        &["host", "--username"],
    ] {
        assert!(parse(&strings(args), &no_env).is_err(), "{args:?} was accepted");
    }
}

#[test]
fn vnc_reads_credentials_from_the_environment_and_files() {
    let env = |name: &str| match name {
        "CMUX_VNC_PASSWORD" => Some("from-env".to_owned()),
        "CMUX_VNC_USERNAME" => Some("envuser".to_owned()),
        "OTHER" => Some("other".to_owned()),
        _ => None,
    };
    let config = parse(&strings(&["h"]), &env).unwrap().unwrap();
    assert_eq!(config.credentials.password.as_deref(), Some("from-env"));
    assert_eq!(config.credentials.username.as_deref(), Some("envuser"));
    let config = parse(&strings(&["h", "--password-env", "OTHER"]), &env).unwrap().unwrap();
    assert_eq!(config.credentials.password.as_deref(), Some("other"));

    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("pw");
    std::fs::write(&file, "line-one\nline-two\n").unwrap();
    let config =
        parse(&strings(&["h", "--password-file", file.to_str().unwrap()]), &env).unwrap().unwrap();
    assert_eq!(config.credentials.password.as_deref(), Some("line-one"));
    assert!(parse(&strings(&["h", "--password-file", "/nonexistent/pw"]), &env).is_err());
}

#[test]
fn vnc_reads_the_port_forward_answer() {
    let answer =
        r#"{"ok":true,"result":{"machine_id":"m","port":5901,"url":"http://127.0.0.1:61234"}}"#;
    assert_eq!(
        forwarded_endpoint(answer),
        Some(Endpoint { host: "127.0.0.1".into(), port: 61234 })
    );
    assert_eq!(
        forwarded_endpoint(r#"{"url":"http://[::1]:7000/"}"#),
        Some(Endpoint { host: "::1".into(), port: 7000 })
    );
    assert_eq!(forwarded_endpoint(r#"{"ok":false}"#), None);
    assert_eq!(forwarded_endpoint("not json"), None);
}

#[test]
fn vnc_layout_fits_and_maps_the_pointer() {
    // 100x26 cells of 10x20 px: the picture area is 1000x500 (the last row is status).
    let pane = Pane::new(100, 26, 1000, 520);
    assert_eq!(pane.area(), (1000, 500));

    // A 1920x1080 screen is height-bound: 1000 / 1920 * 1080 = 562 > 500.
    let fit = Placement::fit(&pane, 1920, 1080);
    assert_eq!((fit.width, fit.height), (888, 500));
    assert_eq!((fit.left, fit.top), (56, 0));
    assert_eq!(fit.anchor(&pane), (5, 0, 6, 0));
    assert_eq!(fit.remote_point(56, 0), (0, 0));
    assert_eq!(fit.remote_point(56 + 444, 250), (960, 540));
    assert_eq!(fit.remote_point(5000, 5000), (1917, 1077), "clamped to the last drawn pixel");
    assert_eq!(fit.remote_point(0, 0), (0, 0));

    // A smaller screen is never scaled up, and is centered.
    let small = Placement::fit(&pane, 640, 480);
    assert_eq!((small.width, small.height, small.left, small.top), (640, 480, 180, 10));
    assert_eq!(small.remote_point(180 + 10, 10 + 20), (10, 20));

    // A terminal that reports no pixel size uses 8x16 cells.
    let unknown = Pane::new(80, 24, 0, 0);
    assert_eq!(unknown.area(), (640, 368));
}

#[test]
fn vnc_scaling_averages_boxes() {
    // 2x2 → 1x1 averages the four pixels.
    let src = [0, 0, 0, 255, 100, 100, 100, 255, 200, 200, 200, 255, 100, 100, 100, 255];
    assert_eq!(scale_rgb(&src, 2, 2, 1, 1), vec![100, 100, 100]);
    // Same size drops alpha only.
    assert_eq!(
        scale_rgb(&src, 2, 2, 2, 2),
        vec![0, 0, 0, 100, 100, 100, 200, 200, 200, 100, 100, 100]
    );
    // 3x1 → 2x1 keeps every source column.
    let src = [10, 0, 0, 255, 20, 0, 0, 255, 30, 0, 0, 255];
    assert_eq!(scale_rgb(&src, 3, 1, 2, 1).len(), 6);
}

#[test]
fn vnc_kitty_frames_chunk_and_replace_the_previous_image() {
    let rgb: Vec<u8> = (0..64 * 64 * 3).map(|i| (i * 7919 % 251) as u8).collect();
    let mut out = Vec::new();
    kitty::frame(
        &mut out,
        &rgb,
        64,
        64,
        4,
        2,
        3,
        5,
        kitty::IMAGE_IDS[1],
        Some(kitty::IMAGE_IDS[0]),
    )
    .unwrap();
    let text = String::from_utf8(out).unwrap();
    assert!(text.starts_with("\x1b[3;5H\x1b_Ga=T,f=24,o=z,s=64,v=64,"), "{text:.80}");
    assert!(text.contains(&format!("i={},p=1,X=3,Y=5,C=1,q=2,", kitty::IMAGE_IDS[1])));
    assert!(text.ends_with(&format!("\x1b_Ga=d,d=I,i={},q=2\x1b\\", kitty::IMAGE_IDS[0])));
    // Every chunk is at most 4096 base64 bytes, and only the last has m=0.
    let chunks: Vec<&str> =
        text.split("\x1b_G").skip(1).filter(|c| !c.starts_with("a=d")).collect();
    for (index, chunk) in chunks.iter().enumerate() {
        let (control, payload) = chunk.split_once(';').unwrap();
        let payload = payload.trim_end_matches("\x1b\\");
        assert!(payload.len() <= 4096);
        assert_eq!(control.ends_with("m=0"), index == chunks.len() - 1, "{control}");
    }
}

fn key(code: KeyCode, modifiers: KeyModifiers, kind: KeyEventKind) -> KeyEvent {
    KeyEvent { code, modifiers, kind, state: KeyEventState::NONE }
}

fn press(code: KeyCode, modifiers: KeyModifiers) -> KeyEvent {
    key(code, modifiers, KeyEventKind::Press)
}

#[test]
fn vnc_legacy_keys_press_and_release_inside_their_modifiers() {
    let mut keyboard = Keyboard::new(false);
    assert_eq!(
        keyboard.handle(&press(KeyCode::Char('a'), KeyModifiers::NONE), None),
        KeyAction::Send(vec![(0x61, true), (0x61, false)])
    );
    // Ctrl-C: Control down, c down/up, Control up.
    assert_eq!(
        keyboard.handle(&press(KeyCode::Char('c'), KeyModifiers::CONTROL), None),
        KeyAction::Send(vec![(0xFFE3, true), (0x63, true), (0x63, false), (0xFFE3, false)])
    );
    // An uppercase character carries Shift in its keysym; Shift-Left needs Shift.
    assert_eq!(
        keyboard.handle(&press(KeyCode::Char('A'), KeyModifiers::SHIFT), None),
        KeyAction::Send(vec![(0x41, true), (0x41, false)])
    );
    assert_eq!(
        keyboard.handle(&press(KeyCode::Left, KeyModifiers::SHIFT), None),
        KeyAction::Send(vec![(0xFFE1, true), (0xFF51, true), (0xFF51, false), (0xFFE1, false)])
    );
    assert_eq!(
        keyboard.handle(&press(KeyCode::BackTab, KeyModifiers::NONE), None),
        KeyAction::Send(vec![(0xFFE1, true), (0xFF09, true), (0xFF09, false), (0xFFE1, false)])
    );
    assert!(keyboard.release_all().is_empty());
}

#[test]
fn vnc_kitty_protocol_keys_follow_presses_and_releases() {
    let mut keyboard = Keyboard::new(true);
    let shift = KeyCode::Modifier(ModifierKeyCode::LeftShift);
    assert_eq!(
        keyboard.handle(&press(shift, KeyModifiers::SHIFT), None),
        KeyAction::Send(vec![(0xFFE1, true)])
    );
    // The shifted character the protocol reports is the keysym.
    assert_eq!(
        keyboard.handle(&press(KeyCode::Char('1'), KeyModifiers::SHIFT), Some('!')),
        KeyAction::Send(vec![(0x21, true)])
    );
    assert_eq!(
        keyboard
            .handle(&key(KeyCode::Char('1'), KeyModifiers::SHIFT, KeyEventKind::Repeat), Some('!')),
        KeyAction::Send(vec![(0x21, true)])
    );
    assert_eq!(
        keyboard.handle(
            &key(KeyCode::Char('1'), KeyModifiers::SHIFT, KeyEventKind::Release),
            Some('!')
        ),
        KeyAction::Send(vec![(0x21, false)])
    );
    // A key held at focus loss is released.
    keyboard.handle(&press(KeyCode::Char('x'), KeyModifiers::SHIFT), None);
    assert_eq!(keyboard.release_all(), vec![(0xFFE1, false), (0x78, false)]);
    // A release of a key never pressed sends nothing.
    assert_eq!(
        keyboard.handle(&key(KeyCode::Char('z'), KeyModifiers::NONE, KeyEventKind::Release), None),
        KeyAction::Send(vec![])
    );
}

#[test]
fn vnc_ctrl_bracket_runs_viewer_commands() {
    for enhanced in [false, true] {
        let mut keyboard = Keyboard::new(enhanced);
        assert_eq!(
            keyboard.handle(&press(KeyCode::Char(']'), KeyModifiers::CONTROL), None),
            KeyAction::AwaitCommand
        );
        // A modifier or a release while waiting is ignored.
        assert_eq!(
            keyboard.handle(
                &key(KeyCode::Char(']'), KeyModifiers::CONTROL, KeyEventKind::Release),
                None
            ),
            KeyAction::None
        );
        assert_eq!(
            keyboard.handle(&press(KeyCode::Char('q'), KeyModifiers::NONE), None),
            KeyAction::Command(Command::Quit)
        );
        // Legacy terminals report Ctrl-] as Ctrl-5; with the Kitty
        // protocol Ctrl-5 is its own key and reaches the server.
        let ctrl_5 = keyboard.handle(&press(KeyCode::Char('5'), KeyModifiers::CONTROL), None);
        if enhanced {
            assert_eq!(ctrl_5, KeyAction::Send(vec![(0xFFE3, true), (0x35, true)]));
            keyboard.release_all();
            keyboard.handle(&press(KeyCode::Char(']'), KeyModifiers::CONTROL), None);
        } else {
            assert_eq!(ctrl_5, KeyAction::AwaitCommand);
        }
        assert_eq!(
            keyboard.handle(&press(KeyCode::Char(']'), KeyModifiers::CONTROL), None),
            KeyAction::Command(Command::SendEscape)
        );
        keyboard.handle(&press(KeyCode::Char(']'), KeyModifiers::CONTROL), None);
        assert_eq!(
            keyboard.handle(&press(KeyCode::Char('x'), KeyModifiers::NONE), None),
            KeyAction::Command(Command::Cancel)
        );
        // Back to sending keys.
        assert!(matches!(
            keyboard.handle(&press(KeyCode::Char('x'), KeyModifiers::NONE), None),
            KeyAction::Send(_)
        ));
    }
}

#[test]
fn vnc_kitty_release_matches_the_key_pressed_even_after_shift_changes() {
    let mut keyboard = Keyboard::new(true);
    let shift = KeyCode::Modifier(ModifierKeyCode::LeftShift);
    assert_eq!(
        keyboard.handle(&press(KeyCode::Char('1'), KeyModifiers::NONE), None),
        KeyAction::Send(vec![(0x31, true)])
    );
    keyboard.handle(&press(shift, KeyModifiers::SHIFT), None);
    // The release now reports the shifted `!`; the key that went down was `1`.
    assert_eq!(
        keyboard.handle(
            &key(KeyCode::Char('1'), KeyModifiers::SHIFT, KeyEventKind::Release),
            Some('!')
        ),
        KeyAction::Send(vec![(0x31, false)])
    );
    // A repeat with a new meaning lets go of the old keysym first.
    keyboard.handle(&press(KeyCode::Char('2'), KeyModifiers::SHIFT), Some('@'));
    keyboard.handle(&key(shift, KeyModifiers::NONE, KeyEventKind::Release), None);
    assert_eq!(
        keyboard.handle(&key(KeyCode::Char('2'), KeyModifiers::NONE, KeyEventKind::Repeat), None),
        KeyAction::Send(vec![(0x40, false), (0x32, true)])
    );
    assert_eq!(keyboard.release_all(), vec![(0x32, false)]);
}

#[test]
fn vnc_server_text_cannot_carry_terminal_escapes() {
    assert_eq!(printable("Office \u{1b}]52;c;aGk=\u{7}Mac"), "Office ?]52;c;aGk=?Mac");
    assert_eq!(printable("a\u{9b}31mb\u{7f}"), "a?31mb?");
    assert_eq!(printable("Léo’s Mac"), "Léo’s Mac");
}
