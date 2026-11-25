use super::*;

#[test]
fn view_scope_is_view_only_and_unknown_scopes_are_refused() {
    assert!(view_only_for("view").unwrap());
    assert!(!view_only_for("control").unwrap());
    assert!(view_only_for("full").is_err());
}

#[test]
fn setup_line_reads_the_linux_hosts_fields() {
    // What cmux_hub_host::session::setup_line writes.
    let line = r#"{"session":"s1","peer_key":"ab","viewer":{"user":"v1","install":"v1"},
        "scope":"view","stun":["127.0.0.1:3478"],"turn":[],"display":"main",
        "max_fps":120,"max_width":null}"#;
    let setup: Setup = serde_json::from_str(line).unwrap();
    assert_eq!(setup.scope, "view");
    assert_eq!(setup.max_fps, Some(120));
    assert_eq!(setup.stun.iter().filter_map(|s| resolve(s)).count(), 1);
    assert_eq!(unhex32(&"ab".repeat(32)), Some([0xab; 32]));
    assert_eq!(unhex32("ab"), None);
}

#[test]
fn a_stop_line_or_closed_input_ends_the_session() {
    let net = Net::start(NetConfig {
        role: Role::Responder,
        session: b"stop".to_vec(),
        local: KeyPair::generate().unwrap(),
        expected_remote: KeyPair::generate().unwrap().public,
        stun: Vec::new(),
        bind: "127.0.0.1:0".parse().unwrap(),
        turn: Vec::new(),
        relay_only: true,
    })
    .unwrap();
    let (tx, app) = mpsc::channel();
    let mut wire = LinkWire { net, app };
    tx.send(r#"{"candidate":"host 127.0.0.1:9"}"#.to_owned()).unwrap();
    assert!(wire.pump_app().is_ok());
    tx.send(r#"{"stop":true}"#.to_owned()).unwrap();
    assert_eq!(wire.pump_app().unwrap_err(), "stopped by the host");
    drop(tx);
    assert_eq!(wire.pump_app().unwrap_err(), "the app closed the session's input");
}
