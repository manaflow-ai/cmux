use super::*;

fn jws(payload: &Value) -> String {
    format!(
        "eyJhbGciOiJFUzI1NiJ9.{}.c2ln",
        b64::encode(payload.to_string().as_bytes())
            .trim_end_matches('=')
            .replace('+', "-")
            .replace('/', "_")
    )
}

fn push(role: &str, sid_in_jws: &str, key_in_jws: &str) -> Value {
    json!({
        "type": "session.ticket", "sessionId": "s1", "role": role, "scope": "view",
        "ticket": jws(&json!({"sid": sid_in_jws, "role": role, "peerKey": key_in_jws})),
        "signalURL": "wss://hub.example/v1/sessions/s1/ws", "ice": [],
        "peer": {"id": "v1", "name": "Mac", "signingKey": "KEY"}
    })
}

#[test]
fn host_tickets_must_agree_with_their_jws() {
    assert!(Ticket::from_push(&push("host", "s1", "KEY")).is_ok());
    assert!(Ticket::from_push(&push("viewer", "s1", "KEY")).is_err());
    assert!(Ticket::from_push(&push("host", "s2", "KEY")).is_err());
    assert!(Ticket::from_push(&push("host", "s1", "OTHER")).is_err());
}

#[test]
fn viewer_tickets_are_read_for_the_viewer_role_only() {
    assert!(Ticket::from_push_as(&push("viewer", "s1", "KEY"), "viewer").is_ok());
    assert!(Ticket::from_push_as(&push("host", "s1", "KEY"), "viewer").is_err());
    assert!(Ticket::from_push_as(&push("viewer", "s1", "OTHER"), "viewer").is_err());
}

#[test]
fn a_failed_end_says_why_within_the_hubs_limit() {
    assert_eq!(failed_reason(""), "failed");
    assert_eq!(failed_reason("  "), "failed");
    assert_eq!(failed_reason("the screen host stopped"), "failed: the screen host stopped");
    // cmux-rd's own `failed: <error>` is not doubled; newlines and escapes go.
    assert_eq!(
        failed_reason("failed: capture: no display\n\u{1b}[31mred"),
        "failed: capture: no display red"
    );
    let long = failed_reason(&"é".repeat(300));
    assert!(long.encode_utf16().count() <= HUB_REASON_MAX, "{long}");
    assert!(long.starts_with("failed: é"));
    // A character of two UTF-16 units is never cut in half.
    let wide = failed_reason(&"😀".repeat(100));
    assert!(wide.encode_utf16().count() <= HUB_REASON_MAX);
    assert!(wide.ends_with('😀'));
}

#[test]
fn the_hubs_own_closes_end_the_session() {
    // The Session DO closes 4002 on revocation or sharing off, 1000 on /end or bye, 4000
    // when another socket took this role. Any code it may choose ends the media too.
    for code in [1000, 1008, 4000, 4002, 4004, 4999] {
        assert!(close_ends_session(code), "{code} must end the session");
    }
    // Lost transport, not the hub's word: a connected session outlives it.
    for code in [1001, 1005, 1006, 1011, 1012, 1013, 1014] {
        assert!(!close_ends_session(code), "{code} is signaling loss");
    }
}

#[test]
fn setup_line_is_the_macs_and_view_only_wins() {
    let ticket = Ticket::from_push(&push("host", "s1", "KEY")).unwrap();
    let offer = RdDocument {
        key: "ab".repeat(32),
        max_fps: Some(240),
        display: Some(1),
        ..RdDocument::default()
    };
    let line = setup_line(&ticket, &offer, true);
    assert_eq!(line["scope"], "view");
    assert_eq!(line["max_fps"], 120);
    assert_eq!(line["display"], "1");
    assert_eq!(line["viewer"]["user"], "v1");
    assert_eq!(setup_line(&ticket, &RdDocument::default(), false)["display"], "main");
    assert_eq!(setup_line(&ticket, &RdDocument::default(), false)["scope"], "control");
    // The viewer's profile reaches serve as it was asked; no attribute leaves it unset.
    assert!(line["encode_profile"].is_null());
    let ultra = RdDocument { encode_profile: Some("ultra".into()), ..RdDocument::default() };
    assert_eq!(setup_line(&ticket, &ultra, false)["encode_profile"], "ultra");
}

#[test]
fn the_helper_is_the_command_given_and_hears_the_setup_line() {
    // A helper that answers its first line back as `{"echo": ..}`, then waits for the end
    // of its input, as `cmux-rd serve` waits for `stop`.
    let script = r#"read -r line; printf '{"echo":%s}\n' "$line"; cat >/dev/null"#;
    for disclaim in [false, true] {
        let command = ServeCommand {
            program: "/bin/sh".into(),
            args: vec!["-c".into(), script.into()],
            disclaim,
            log_prefix: "share-host".into(),
            status_prefix: "share-host".into(),
        };
        let mut serve = Serve::start(&command).unwrap();
        serve.send(&json!({ "session": "s1" }));
        let line = serve.lines.recv_timeout(Duration::from_secs(10)).unwrap();
        assert_eq!(line, json!({ "echo": { "session": "s1" } }));
        let started = std::time::Instant::now();
        serve.stop();
        // It ended at its end of input, well before the 3 s kill.
        assert!(started.elapsed() < Duration::from_secs(3));
    }
}
