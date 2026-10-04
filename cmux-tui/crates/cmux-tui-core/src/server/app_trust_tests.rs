use super::*;

const KEY_HEX: &str = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";

#[test]
fn the_launcher_payload_round_trips_and_rejects_anything_else() {
    let key = FrontendKey::parse(&format!("cmuxik1 inst_a {KEY_HEX}\n")).unwrap();
    assert_eq!(key.install_id(), "inst_a");
    assert_eq!(FrontendKey::parse(&key.to_payload()).unwrap().key.as_slice(), key.key.as_slice());
    let zero = "0".repeat(64);
    for bad in [
        String::new(),
        format!("cmuxik2 inst_a {KEY_HEX}"),
        format!("cmuxik1 inst_a {KEY_HEX} extra"),
        format!("cmuxik1 inst/a {KEY_HEX}"),
        format!("cmuxik1 inst_a {}", &KEY_HEX[..62]),
        format!("cmuxik1 inst_a {zero}"),
        format!("cmuxik1  inst_a {KEY_HEX}"),
    ] {
        assert!(FrontendKey::parse(&bad).is_none(), "{bad:?}");
    }
}

#[test]
fn the_key_never_shows_in_debug_output() {
    let key = FrontendKey::parse(&format!("cmuxik1 inst_a {KEY_HEX}")).unwrap();
    let shown = format!("{key:?}");
    assert!(shown.contains("inst_a") && !shown.contains(&KEY_HEX[..16]), "{shown}");
}

#[test]
fn reading_the_pipe_is_bounded() {
    let payload = format!("cmuxik1 inst_a {KEY_HEX}\n");
    assert_eq!(read_frontend_key(payload.as_bytes()).unwrap().install_id(), "inst_a");
    let long = format!("cmuxik1 inst_a {KEY_HEX}{}", " ".repeat(600));
    assert!(read_frontend_key(long.as_bytes()).is_err());
    assert!(read_frontend_key(&b""[..]).is_err());
}

#[test]
fn only_a_local_connection_may_hello() {
    let trust = AppTrust::default();
    trust
        .install_key
        .set(FrontendKey::parse(&format!("cmuxik1 inst_a {KEY_HEX}")).unwrap())
        .unwrap();
    let mut remote = HelloGate::new(false);
    let reply = remote
        .observe(&trust, 7, r#"{"id":1,"cmd":"client-hello","install_id":"inst_a"}"#)
        .expect("handled");
    assert_eq!(reply["error_code"], "client_hello.local_only");
    // The window is closed now, and the connection was never registered.
    assert!(
        remote
            .observe(&trust, 7, r#"{"id":2,"cmd":"client-hello","install_id":"inst_a"}"#)
            .is_none()
    );
    assert!(!trust.verified_app(7));
}

#[test]
fn an_unregistered_or_disconnected_connection_is_never_verified() {
    let trust = AppTrust::default();
    assert!(!trust.verified_app(1));
    trust.prove_for_test(1, "inst_a");
    assert!(trust.verified_app(1));
    trust.disconnect(1);
    assert!(!trust.verified_app(1));
    // A local connection with no token and no hello is not the app.
    trust.connect_local(2, None);
    assert!(!trust.verified_app(2));
}
