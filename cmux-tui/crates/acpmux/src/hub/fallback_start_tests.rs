use super::*;

#[test]
fn a_cloud_or_remote_chat_never_falls_over_onto_the_coderouter() {
    let profile = |env: &[(&str, &str)]| crate::config::HarnessProfile {
        kind: crate::config::HarnessKind::ClaudeStdio,
        argv: vec!["claude".into()],
        env: env.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect(),
        description: None,
        fallback: None,
        family: Some("claude".into()),
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let plain = profile(&[]);
    let routed = profile(&[(crate::routes::PROFILE_ROUTE_KEY, crate::routes::CMUX_ROUTE_ID)]);
    // On a Cloud machine, or for a remote connection's chat: neither the `cmux` profile nor
    // a profile on the `cmux` route.
    for (cloud, remote) in [(true, false), (false, true), (true, true)] {
        assert!(coderouter_fallback_skipped(cloud, remote, "cmux", &plain));
        assert!(coderouter_fallback_skipped(cloud, remote, "direct", &routed));
        // Another fallback (the subrouter pool, a direct login) still takes the turn.
        assert!(!coderouter_fallback_skipped(cloud, remote, "claude-sr", &plain));
    }
    // A Mac's own chat keeps it.
    assert!(!coderouter_fallback_skipped(false, false, "cmux", &plain));
    assert!(!coderouter_fallback_skipped(false, false, "direct", &routed));
}

#[test]
fn the_turn_error_names_the_fallback_that_could_not_start() {
    let e = RpcError::new(-32603, "agent process closed");
    let mut out = fallback_not_started(&e, "claude", "cmux", "the local CodeRouter is not running");
    // The message stays the agent's own until the turn ends, so it still reads as a dead
    // process (`recovery::dead_process`), whose stderr line `finish_turn` adds.
    assert_eq!(out.message, "agent process closed");
    assert!(crate::recovery::dead_process(&out));
    assert_eq!(out.data.as_ref().unwrap()[NOTE_KEY]["profile"], "cmux");
    say_fallback(&mut out);
    assert!(out.message.starts_with("agent process closed"), "{}", out.message);
    assert!(out.message.contains("cmux cannot start"), "{}", out.message);
    assert!(out.message.contains("CodeRouter is not running"), "{}", out.message);
    assert!(out.message.contains("stays on claude"), "{}", out.message);
    // Data the error had stays.
    let e = e.with_data(json!({"reason": "limit"}));
    let out = fallback_not_started(&e, "claude", "cmux", "down");
    let data = out.data.unwrap();
    assert_eq!(data["reason"], "limit");
    assert_eq!(data[NOTE_KEY]["error"], "down");
    // An error no fallback marked keeps its message.
    let mut plain = RpcError::new(-32603, "agent process closed");
    say_fallback(&mut plain);
    assert_eq!(plain.message, "agent process closed");
}
