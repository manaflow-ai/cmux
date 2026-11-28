use super::*;

#[test]
fn bench_session_mode_defaults_to_control_and_accepts_only_wire_modes() {
    let parse = |args: &[&str]| {
        Opts::parse(&args.iter().map(|s| s.to_string()).collect::<Vec<_>>()).unwrap()
    };
    assert_eq!(session_mode(&parse(&[])).unwrap(), "control");
    for mode in ["view", "control"] {
        assert_eq!(session_mode(&parse(&["--mode", mode])).unwrap(), mode);
    }
    assert!(session_mode(&parse(&["--mode", "viewer"])).is_err());
}

#[test]
fn clipboard_probe_matches_the_echo_prefix_and_its_echo_never_echoes_again() {
    // screen-share-vs.py clip-echo answers only texts starting with CLIP_PREFIX, with "ack:" + text.
    let a = clipboard_probe(41, 0xabc, 0);
    let b = clipboard_probe(41, 0xabc, 1);
    assert!(a.starts_with("cmux-vs-clip-") && b.starts_with("cmux-vs-clip-"));
    assert_ne!(a, b);
    let echo = clipboard_echo(&a);
    assert_eq!(echo, format!("ack:{a}"));
    assert!(!echo.starts_with("cmux-vs-clip-"));
    // One whole part: the host's ClipboardSync joins it without offset and total.
    let wire =
        serde_json::to_value(Control::Clipboard { seq: 1, text: a, offset: None, total: None })
            .unwrap();
    assert!(wire.get("offset").is_none() && wire.get("total").is_none());
}
