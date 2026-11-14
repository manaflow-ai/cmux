use super::*;

#[test]
fn a_query_token_moves_out_of_a_peer_url() {
    assert_eq!(
        lift_query_token("ws://h:1/?token=abc"),
        ("ws://h:1/".to_owned(), Some("abc".to_owned()))
    );
    assert_eq!(
        lift_query_token("ws://h:1/acp?x=1&token=abc&y=2"),
        ("ws://h:1/acp?x=1&y=2".to_owned(), Some("abc".to_owned()))
    );
    assert_eq!(lift_query_token("ws://h:1/"), ("ws://h:1/".to_owned(), None));
    assert_eq!(lift_query_token("ws://h:1/?mytoken=a"), ("ws://h:1/?mytoken=a".to_owned(), None));
}

#[test]
fn the_links_own_attach_names_its_byte_limit() {
    let attach = hidden_attach("s");
    assert_eq!(attach["sessionId"], "s");
    assert_eq!(attach["limit"], 0);
    assert_eq!(attach["visible"], false);
    assert_eq!(attach["maxBytes"], crate::hub::page_bytes(&json!({})));
}

#[test]
fn a_remote_config_gives_its_token_and_listen_address() {
    let cfg = br#"{"websocket": {"listen": "127.0.0.1:47811", "token": "abc"}}"#;
    let parsed = remote_daemon_config(cfg).unwrap();
    assert_eq!(parsed.token, "abc");
    assert_eq!(parsed.listen.as_deref(), Some("127.0.0.1:47811"));
    let no_listen = remote_daemon_config(br#"{"websocket": {"token": "abc"}}"#).unwrap();
    assert_eq!(no_listen.listen, None);
}

#[test]
fn a_remote_config_without_a_token_is_refused_without_quoting_it() {
    assert_eq!(remote_daemon_config(b"not json"), Err(RemoteConfigError::Unreadable));
    for cfg in
        [&br#"{}"#[..], br#"{"websocket": {"listen": "x"}}"#, br#"{"websocket": {"token": ""}}"#]
    {
        assert_eq!(remote_daemon_config(cfg), Err(RemoteConfigError::NoToken));
    }
}

#[test]
fn a_peer_token_is_64_hex_digits() {
    let good = "a".repeat(64);
    assert_eq!(peer_token_text(format!("{good}\n").as_bytes()), Some(good.clone()));
    assert_eq!(peer_token_text(b""), None);
    assert_eq!(peer_token_text("g".repeat(64).as_bytes()), None);
    assert_eq!(peer_token_text("a".repeat(63).as_bytes()), None);
    let read = [br#"{"websocket":{"token":"t"}}"#.as_slice(), b"\0", good.as_bytes()].concat();
    assert_eq!(split_remote_read(&read).1, Some(good));
}
