use super::*;

#[test]
fn the_token_is_read_bare_or_from_json_and_nothing_else_passes() {
    assert_eq!(parse_token("tok.abc\n").unwrap().0.as_str(), "tok.abc");
    let (token, expires) =
        parse_token(r#"{"access_token": "t1", "expires_at": 1700000000000}"#).unwrap();
    assert_eq!((token.as_str(), expires), ("t1", 1_700_000_000_000));
    assert_eq!(parse_token(r#"{"accessToken": "t2"}"#).unwrap().0.as_str(), "t2");
    for bad in ["", "  ", "two words", r#"{"token": "x"}"#] {
        assert!(parse_token(bad).is_err(), "{bad:?}");
    }
}

/// Team messaging is a feature, not a Labs opt-in: a hub with no `teamMessaging` has it on,
/// and only an explicit `false` turns it off and survives a save.
#[test]
fn team_messaging_is_on_unless_the_config_says_false() {
    let on: MeshRelayConfig =
        serde_json::from_value(json!({"url": "https://hub.example.com"})).unwrap();
    assert!(on.team_messaging);
    assert!(MeshRelayConfig::default().team_messaging);
    assert!(serde_json::to_value(&on).unwrap().get("teamMessaging").is_none());
    let off: MeshRelayConfig =
        serde_json::from_value(json!({"url": "https://hub.example.com", "teamMessaging": false}))
            .unwrap();
    assert!(!off.team_messaging);
    let saved = serde_json::to_value(&off).unwrap();
    assert_eq!(saved["teamMessaging"], false);
    assert!(!serde_json::from_value::<MeshRelayConfig>(saved).unwrap().team_messaging);
}

#[test]
fn only_https_or_loopback_http_with_a_token_command_is_used() {
    let config = |url: &str, cmd: &[&str]| MeshRelayConfig {
        url: url.into(),
        token_command: cmd.iter().map(|s| (*s).to_owned()).collect(),
        team_messaging: false,
        control_from: Vec::new(),
        credential: None,
    };
    let hub = "https://cmux-platform-development.debussy.workers.dev/";
    assert_eq!(
        config(hub, &["mint"]).origin().unwrap(),
        "https://cmux-platform-development.debussy.workers.dev"
    );
    assert!(config("http://127.0.0.1:8787", &["mint"]).origin().is_ok());
    assert!(config("http://hub.example.com", &["mint"]).origin().is_err());
    assert!(config(hub, &[]).origin().is_err());
    assert!(config("not a url", &["mint"]).origin().is_err());
    assert!(config("https://user:secret@hub.example.com", &["mint"]).origin().is_err());
    assert!(config("https://hub.example.com/?access_token=abc", &["mint"]).origin().is_err());
    assert!(config("https://hub.example.com/#t", &["mint"]).origin().is_err());
    assert_eq!(
        config("https://hub.example.com/mesh/", &["mint"]).origin().unwrap(),
        "https://hub.example.com/mesh"
    );
    // A log names the hub's origin only, never its path.
    assert_eq!(
        config("https://hub.example.com/s3cret", &["mint"]).shown(),
        "https://hub.example.com"
    );
}

#[tokio::test]
async fn a_token_command_that_prints_without_end_is_stopped_not_buffered() {
    let config = MeshRelayConfig {
        url: "http://127.0.0.1:9".into(),
        token_command: ["sh", "-c", "yes"].map(str::to_owned).to_vec(),
        team_messaging: false,
        control_from: Vec::new(),
        credential: None,
    };
    let hub = HttpHub::new(&config).unwrap();
    let e = hub.token(true).await.unwrap_err();
    assert!(e.to_string().contains("too much"), "{e}");
}

#[tokio::test]
async fn invalid_control_operations_are_refused_before_token_or_http() {
    let hub = HttpHub::new(&MeshRelayConfig {
        url: "http://127.0.0.1:9".into(),
        token_command: vec!["/nonexistent/mesh-token-command".into()],
        control_from: vec![],
        credential: None,
        team_messaging: false,
    })
    .unwrap();
    for (kind, op) in [
        (crate::mesh::Kind::Control, None),
        (crate::mesh::Kind::Control, Some("pause")),
        (crate::mesh::Kind::Prompt, Some("start")),
    ] {
        let message = OutMessage {
            to: Default::default(),
            from: Default::default(),
            kind,
            op: op.map(str::to_owned),
            body: String::new(),
            mode: crate::mesh::Mode::Now,
            idempotency_key: "control-invalid".into(),
        };
        let expected = message.validate().unwrap_err();
        let error = hub.send(&message).await.unwrap_err();
        assert!(error.refused);
        assert_eq!(error.message, expected);
    }
}

#[test]
fn a_401_on_a_credential_rotated_since_is_tried_again_with_the_new_one() {
    // A heartbeat sent with the old credential, answered 401 after the rotation saved the new.
    assert!(rotated_since("cmm_old", Some("cmm_new")));
    // The credential on disk is the one refused: a revoke.
    assert!(!rotated_since("cmm_new", Some("cmm_new")));
    // No credential on disk (left, or revoked): nothing to try.
    assert!(!rotated_since("cmm_old", None));
}

#[test]
fn only_a_refused_credential_ends_the_relay() {
    assert!(answer(401, br#"{"code": "mesh.unauthorized"}"#).unwrap_err().ends_relay());
    assert!(answer(401, br#"{"code": "machine.revoked"}"#).unwrap_err().ends_relay());
    assert!(answer(403, b"").unwrap_err().ends_relay());
    // A duplicate name or another bad heartbeat is tried again, not the end of the relay.
    assert!(!answer(400, br#"{"code": "mesh.bad_request"}"#).unwrap_err().ends_relay());
    assert!(!answer(409, b"").unwrap_err().ends_relay());
    assert!(!answer(429, b"").unwrap_err().ends_relay());
    assert!(HubError::refused("no token command").ends_relay());
}

fn from(daemon: Option<&str>, user: Option<&str>) -> crate::mesh::Sender {
    crate::mesh::Sender {
        daemon_id: daemon.map(str::to_owned),
        user: user.map(str::to_owned),
        // Claims a sender makes about itself, never authority.
        name: Some("u1".into()),
        host: Some("u1".into()),
        ..Default::default()
    }
}

#[test]
fn control_sender_allowlist_uses_only_the_stamped_daemon_and_selected_ops() {
    let d1 = from(Some("d1"), None);
    let default: MeshControlFrom = serde_json::from_value(json!({"daemonId":"d1"})).unwrap();
    for op in ["start", "resume", "stop"] {
        assert!(default.allows(&d1, None, op));
    }
    let all: MeshControlFrom = serde_json::from_value(json!({"daemonId":"d1", "ops":[]})).unwrap();
    let round_trip: MeshControlFrom =
        serde_json::from_value(serde_json::to_value(&all).unwrap()).unwrap();
    assert!(!round_trip.allows(&d1, None, "start"));
    assert!(!all.allows(&d1, None, "start"));
    assert!(!all.allows(&from(Some("d2"), None), None, "start"));
    let resume = MeshControlFrom {
        daemon_id: "d1".into(),
        ops: vec!["resume".into()],
        ..Default::default()
    };
    assert!(resume.allows(&d1, None, "resume"));
    assert!(!resume.allows(&d1, None, "stop"));
    assert!(!MeshControlFrom::default().allows(&d1, None, "start"));
    assert!(!MeshControlFrom { ops: vec![], ..Default::default() }.allows(
        &from(Some(""), None),
        None,
        "start"
    ));
    // A daemonId entry never matches on the person alone.
    assert!(!default.allows(&from(Some("d2"), Some("u1")), Some("u1"), "start"));
}

#[test]
fn same_user_allows_only_the_hub_stamped_person_this_machine_recorded() {
    let entry: MeshControlFrom = serde_json::from_value(json!({"sameUser": true})).unwrap();
    assert_eq!(entry, MeshControlFrom::same_user());
    // Same person, any of its daemons: allowed for every lifecycle op.
    for op in ["start", "resume", "stop"] {
        assert!(entry.allows(&from(Some("d9"), Some("u1")), Some("u1"), op), "{op}");
    }
    assert!(!entry.allows(&from(Some("d9"), Some("u1")), Some("u1"), "delete"));
    // A read of one session goes to the same person's other machine, never to another's.
    assert!(entry.allows(&from(Some("d9"), Some("u1")), Some("u1"), "read"));
    assert!(!entry.allows(&from(Some("d9"), Some("u2")), Some("u1"), "read"));
    assert!(!entry.allows(&from(Some("d9"), Some("u1")), None, "read"));
    // Another person is refused.
    assert!(!entry.allows(&from(Some("d9"), Some("u2")), Some("u1"), "start"));
    // No recorded person here (an old join, or the hub sent no userId) grants nothing.
    assert!(!entry.allows(&from(Some("d9"), Some("u1")), None, "start"));
    assert!(!entry.allows(&from(Some("d9"), Some("")), Some(""), "start"));
    // A sender the hub stamped with no person is refused.
    assert!(!entry.allows(&from(Some("d9"), None), Some("u1"), "start"));
    // An explicit empty ops list grants nothing.
    let none: MeshControlFrom =
        serde_json::from_value(json!({"sameUser": true, "ops": []})).unwrap();
    assert!(!none.allows(&from(Some("d9"), Some("u1")), Some("u1"), "start"));
    assert!(!none.allows(&from(Some("d9"), Some("u1")), Some("u1"), "read"));
    let round_trip: MeshControlFrom =
        serde_json::from_value(serde_json::to_value(&none).unwrap()).unwrap();
    assert_eq!(round_trip, none);
    // Without `sameUser` the person is no authority.
    let off: MeshControlFrom = serde_json::from_value(json!({"sameUser": false})).unwrap();
    assert!(!off.allows(&from(Some("d9"), Some("u1")), Some("u1"), "start"));
    assert_eq!(
        serde_json::to_value(MeshControlFrom::same_user()).unwrap(),
        json!({"sameUser": true, "ops": ["start", "resume", "stop"]})
    );
}

#[test]
fn a_malformed_answer_logs_none_of_its_values() {
    let reply = json!({"daemonId": "inst_1", "ttlSeconds": "Bearer abc.def"});
    let e = decode::<HeartbeatReply>(reply).unwrap_err();
    assert!(!e.to_string().contains("abc.def"), "{e}");
}

#[test]
fn a_hub_error_logs_no_free_text_from_the_answer() {
    let e =
        answer(400, br#"{"code": "mesh.bad_request", "message": "Bearer abc.def"}"#).unwrap_err();
    assert!(!e.to_string().contains("abc.def"), "{e}");
    assert_eq!(e.code.as_deref(), Some("mesh.bad_request"));
    // A code the contract does not name is dropped, however tidy: it could be a token.
    let e = answer(400, br#"{"code": "eyJhbGciOi.abc.def"}"#).unwrap_err();
    assert!(!e.to_string().contains("abc.def") && e.code.is_none(), "{e}");
    let e = answer(400, br#"{"code": "Bearer abc.def ghi"}"#).unwrap_err();
    assert!(!e.to_string().contains("abc.def") && e.code.is_none(), "{e}");
}

#[test]
fn the_hubs_refusals_say_whether_to_try_again() {
    let e = answer(404, br#"{"code": "mesh.unknown_recipient", "message": "no"}"#).unwrap_err();
    assert!(e.refused && e.code.as_deref() == Some("mesh.unknown_recipient"), "{e:?}");
    let e = answer(429, br#"{"code": "mesh.rate_limited", "retryAfterSeconds": 7}"#).unwrap_err();
    assert!(!e.refused && e.retry_after == Some(Duration::from_secs(7)), "{e:?}");
    assert!(!answer(503, b"").unwrap_err().refused);
    let e =
        answer(409, br#"{"code": "mesh.ambiguous", "candidates": [{"host": "a"}]}"#).unwrap_err();
    assert_eq!(e.candidates, Some(json!([{"host": "a"}])));
    assert_eq!(answer(200, br#"{"ok": 1}"#).unwrap(), json!({"ok": 1}));
}
