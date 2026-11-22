fn args(argv: &[&str]) -> crate::Args {
    crate::parse_args(argv.iter().map(|arg| (*arg).to_string()))
}

#[test]
fn a_headless_websocket_listener_needs_a_token() {
    let token = |args: &crate::Args, ws: &Option<String>, configured: &Option<String>| {
        super::ws_token(args, ws, configured).map(|value| value.token)
    };
    let ws = Some("127.0.0.1:0".to_string());
    let wide = Some("0.0.0.0:0".to_string());
    let headless = args(&["--headless", "--ws", "127.0.0.1:0"]);
    assert!(token(&headless, &wide, &None).is_err());
    assert!(token(&headless, &wide, &Some(" ".into())).is_err());
    // A loopback listener mints its own credential (cx-hnmbt.2).
    let minted = super::ws_token(&headless, &ws, &None).unwrap();
    assert!(minted.minted && minted.token.is_some_and(|value| value.len() == 64));
    assert_eq!(token(&headless, &ws, &Some("t".into())).unwrap().as_deref(), Some("t"));
    let flagged = args(&["--headless", "--ws", "127.0.0.1:0", "--ws-token", "f"]);
    assert_eq!(token(&flagged, &ws, &None).unwrap().as_deref(), Some("f"));
    // The TUI that runs the daemon approves pairings itself.
    let interactive = args(&["--ws", "127.0.0.1:0"]);
    assert_eq!(token(&interactive, &ws, &None).unwrap(), None);
    assert_eq!(token(&headless, &None, &None).unwrap(), None);
}
