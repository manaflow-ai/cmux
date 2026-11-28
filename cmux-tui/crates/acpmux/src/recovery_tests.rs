use super::*;

/// An error path never walks the chats folder (a request task must not block on it);
/// a size `daemon status` measured is reused.
#[test]
fn only_a_measure_walks_the_chats_folder() {
    let dir = std::env::temp_dir().join(format!("acpmux-chats-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("a"), vec![0u8; 4096]).unwrap();
    assert_eq!(chats_size(&dir, false), None, "an error path must not walk");
    let measured = chats_size(&dir, true);
    assert!(measured.is_some_and(|n| n >= 4096));
    assert_eq!(chats_size(&dir, false), measured, "then it reuses the measure");
    let _ = std::fs::remove_dir_all(&dir);
}

fn kind_of(e: &RpcError) -> Option<&str> {
    e.data.as_ref()?.get("errorKind")?.as_str()
}

/// A turn the agent failed because it does not know its model (Claude Code refused
/// `fable-5.2`, Leo 2026-11-22) is `model.unrecognized`, for a sweeper; capacity is not.
#[test]
fn a_model_the_agent_does_not_know_is_model_unrecognized() {
    let e = RpcError::new(
        -32603,
        "[claude-code:unrecognized_model] There's an issue with the selected model \
             (fable-5.2). It may not exist or you may not have access to it.",
    );
    let mut typed = e.clone();
    annotate_as(&mut typed, None, dead_process(&e));
    assert_eq!(kind_of(&typed), Some(kind::MODEL_UNRECOGNIZED), "{typed:?}");
    let busy =
        RpcError::new(-32603, "Selected model is at capacity. Please try a different model.");
    let mut typed = busy.clone();
    annotate_as(&mut typed, None, dead_process(&busy));
    assert_ne!(kind_of(&typed), Some(kind::MODEL_UNRECOGNIZED), "{typed:?}");
}

/// Every form the turn finalizer treats as a dead process is `agent.exited`: the bare ACP
/// closes, "Internal error" and a short -32603. A long -32603 is the agent's own answer.
#[test]
fn the_finalizers_dead_process_forms_are_agent_exited() {
    for e in [
        RpcError::internal("agent process closed"),
        RpcError::new(-32603, "Internal error"),
        RpcError::new(-32000, "Internal error"),
        RpcError::new(-32603, "simulated internal error"),
    ] {
        let mut typed = e.clone();
        annotate_as(&mut typed, None, dead_process(&e));
        assert_eq!(kind_of(&typed), Some(kind::AGENT_EXITED), "{e:?}");
    }
    let answer = RpcError::new(
        -32603,
        "stream disconnected before completion: error sending request for url",
    );
    let mut typed = answer.clone();
    annotate_as(&mut typed, None, dead_process(&answer));
    assert_eq!(kind_of(&typed), None);
}

/// A request's reply is not a turn: a short internal error there is the daemon's own
/// failure, not a dead agent, and keeps no kind.
#[test]
fn a_short_request_error_is_not_agent_exited() {
    for e in [
        RpcError::internal("no agent session"),
        RpcError::internal("session/new returned no sessionId"),
        RpcError::new(-32603, "Internal error"),
    ] {
        let mut typed = e.clone();
        annotate(&mut typed, None);
        assert_eq!(kind_of(&typed), None, "{e:?}");
    }
    let mut closed = RpcError::internal("agent process closed");
    annotate(&mut closed, None);
    assert_eq!(kind_of(&closed), Some(kind::AGENT_EXITED));
}

/// An agent that cannot start because the disk is full says to free space, with the
/// disk's details; any other start failure is still `spawn.failed`.
#[test]
fn a_full_disk_at_spawn_is_disk_full() {
    let cwd = std::env::temp_dir();
    let errors = [std::io::ErrorKind::StorageFull, std::io::ErrorKind::QuotaExceeded]
        .map(std::io::Error::from);
    #[cfg(unix)]
    let errors = errors
        .into_iter()
        .chain([libc::ENOSPC, libc::EDQUOT].map(std::io::Error::from_raw_os_error));
    for error in errors {
        let e = anyhow::Error::from(error);
        let typed = spawn_failed(&e, "claude", "claude", &cwd);
        assert_eq!(kind_of(&typed), Some(kind::DISK_FULL), "{typed:?}");
        let data = typed.data.as_ref().unwrap();
        assert!(data["recovery"].as_str().unwrap().starts_with("The disk is full."), "{data}");
        assert!(data["details"]["freeBytes"].is_u64(), "{data}");
    }
    let e = anyhow::Error::from(std::io::Error::from_raw_os_error(libc::ENOENT));
    let typed = spawn_failed(&e, "claude", "claude", &cwd);
    assert_eq!(kind_of(&typed), Some(kind::SPAWN_FAILED), "{typed:?}");
}

/// A full disk a peer reported names that peer, never this machine's disk.
#[test]
fn a_peers_full_disk_names_the_peer_not_this_disk() {
    let mut e = RpcError::internal("write chat log: No space left on device (os error 28)");
    annotate_peer(&mut e, "big-blue");
    annotate(&mut e, None);
    assert_eq!(kind_of(&e), Some(kind::DISK_FULL));
    let data = e.data.as_ref().unwrap();
    assert_eq!(data["details"], json!({"peer": "big-blue"}), "{data}");
    assert!(data["recovery"].as_str().unwrap().contains("big-blue"), "{data}");
    let mut other = RpcError::internal("no agent session");
    annotate_peer(&mut other, "big-blue");
    assert!(other.data.is_none(), "{other:?}");
}

/// The finalizer adds the agent's last stderr line before typing: a dead process stays
/// `agent.exited` under its longer message, and a full disk in that line wins.
#[test]
fn a_dead_process_with_its_stderr_line_is_still_typed() {
    let mut e = RpcError::new(-32603, "Internal error (claude): model client crashed");
    annotate_as(&mut e, None, true);
    assert_eq!(kind_of(&e), Some(kind::AGENT_EXITED));
    let mut e = RpcError::new(-32603, "Internal error (claude): write: No space left on device");
    annotate_as(&mut e, None, true);
    assert_eq!(kind_of(&e), Some(kind::DISK_FULL));
}

/// A turn whose agent says it is not signed in is `auth.signed_out`, one whose credential
/// expired `auth.expired`, before `agent.exited` when the agent died of it. A connection
/// or capacity error is never an auth kind, whatever word about a token it carries.
#[test]
fn a_sign_in_failure_is_typed_and_a_transport_error_is_not() {
    for (message, dead, want) in [
        ("Not logged in · Please run /login", false, Some(kind::AUTH_SIGNED_OUT)),
        ("Invalid API key · Fix external API key", false, Some(kind::AUTH_SIGNED_OUT)),
        (
            "agent process closed (claude): Not logged in · Please run /login",
            true,
            Some(kind::AUTH_SIGNED_OUT),
        ),
        (
            "API Error: 401 OAuth token has expired. Please obtain a new token.",
            false,
            Some(kind::AUTH_EXPIRED),
        ),
        (
            "Provided authentication token is expired. Please try signing in again.",
            false,
            Some(kind::AUTH_EXPIRED),
        ),
        ("API Error: Connection error.", false, None),
        ("HTTP 503: authentication_failed", false, None),
        ("HTTP 502: authentication_failed", false, None),
        ("HTTP 504: credential expired", false, None),
        ("Not logged in · Please run /login (connection error)", false, None),
        ("HTTP 400: invalid token expiry value", false, None),
        ("stream disconnected before completion: the token stream expired", false, None),
        (
            "API Error: 503 no non-exhausted claude accounts; the login pool expires soon",
            false,
            None,
        ),
        ("agent process closed", true, Some(kind::AGENT_EXITED)),
        (
            r#"API Error: 503 {"error":{"code":"inference.gateway_offline","message":"Your model gateway is offline"}}"#,
            false,
            Some(kind::GATEWAY_OFFLINE),
        ),
        (
            r#"API Error: 502 {"error":{"code":"inference.gateway_login","message":"the agent's sign-in on your Mac expired"}}"#,
            true,
            Some(kind::GATEWAY_LOGIN),
        ),
    ] {
        let mut e = RpcError::new(-32000, message);
        annotate_as(&mut e, None, dead);
        assert_eq!(kind_of(&e), want, "{message}");
        if want.is_some_and(|k| k.starts_with("gateway.")) {
            let recovery = e.data.as_ref().unwrap()["recovery"].as_str().unwrap().to_owned();
            assert!(
                recovery.contains("your Mac") && !recovery.contains("harness login"),
                "{recovery}"
            );
        }
        if want.is_some_and(|k| k.starts_with("auth.")) {
            let recovery = e.data.as_ref().unwrap()["recovery"].as_str().unwrap().to_owned();
            assert!(recovery.contains("cmux harness login"), "{recovery}");
        }
    }
}

/// A start the agent refused for its sign-in (cursor-agent's ACP auth_required, gemini's
/// "API key missing", grok's "Authentication required") gains `agent.sign_in_required`
/// naming the harness; any other start error, or an outage that mentions a token, does not
/// (hq#11225).
#[test]
fn a_start_refused_for_its_sign_in_names_the_harness() {
    for (code, message, harness) in [
        (ACP_AUTH_REQUIRED, "Authentication required", "cursor"),
        (-32603, "API key missing", "gemini"),
        (-32603, "agent process closed (grok): Authentication required", "grok"),
        (-32603, "Invalid API key · Please run /login", "claude"),
    ] {
        let mut e = RpcError::new(code, message);
        assert!(start_sign_in(&mut e, harness), "{message}");
        let data = e.data.unwrap();
        assert_eq!(data["reason"], SIGN_IN_REQUIRED, "{message}");
        assert_eq!(data["errorKind"], kind::AUTH_SIGNED_OUT, "{message}");
        assert_eq!(data["details"]["harness"], harness);
        let recovery = data["recovery"].as_str().unwrap();
        assert!(recovery.contains(&format!("cmux harness login {harness}")), "{recovery}");
        assert_eq!(e.message, message, "the agent's own words stay");
    }
    let mut expired = RpcError::new(-32603, "OAuth token has expired");
    assert!(start_sign_in(&mut expired, "claude"));
    assert_eq!(expired.data.unwrap()["errorKind"], kind::AUTH_EXPIRED);
    for (code, message) in [
        (-32603, "spawn harness process: No such file or directory"),
        (-32603, "HTTP 503: authentication_failed"),
        (-32602, "bad params"),
        (ACP_AUTH_REQUIRED, "quota exceeded for this project"),
        (ACP_AUTH_REQUIRED, "internal server error"),
        (-32603, "not authenticated yet, retrying"),
    ] {
        let mut e = RpcError::new(code, message);
        assert!(!start_sign_in(&mut e, "cursor"), "{message}");
        assert!(e.data.is_none(), "{message}");
    }
}

/// grok 1.0.77, signed out on a fresh Cloud machine, answers `session/new` with -32000
/// "Authentication required" and the string data "no auth method id provided" (its own
/// words, run by hand against `grok agent stdio`). A start typed only object data, so grok's
/// start reached the app as a bare `agent_session.refused` (cloud harness matrix,
/// grok-app-start). The sign-in is typed, and the agent's data stays under `agentData`.
#[test]
fn a_signed_out_start_with_string_data_names_the_harness() {
    let mut e = RpcError::new(ACP_AUTH_REQUIRED, "Authentication required");
    e.data = Some(json!("no auth method id provided"));
    assert!(start_sign_in(&mut e, "grok"));
    let data = e.data.unwrap();
    assert_eq!(data["reason"], SIGN_IN_REQUIRED);
    assert_eq!(data["details"]["harness"], "grok");
    assert_eq!(data[AGENT_DATA], "no auth method id provided");

    // The same class in the other typers: a turn error or a peer's full disk with an agent's
    // string data is still typed, and an untyped one keeps the agent's data as it was.
    let mut full = RpcError::new(-32603, "No space left on device (os error 28)");
    full.data = Some(json!("write failed"));
    annotate_peer(&mut full, "box");
    let data = full.data.unwrap();
    assert_eq!(data["errorKind"], kind::DISK_FULL);
    assert_eq!(data[AGENT_DATA], "write failed");

    let mut full = RpcError::new(-32603, "No space left on device (os error 28)");
    full.data = Some(json!(["write failed"]));
    annotate(&mut full, None);
    assert_eq!(full.data.unwrap()["errorKind"], kind::DISK_FULL);

    let mut other = RpcError::new(-32602, "bad params");
    other.data = Some(json!("the agent's own"));
    annotate(&mut other, None);
    assert_eq!(other.data, Some(json!("the agent's own")));
}

/// The gateway's 401 for a Gemini or Grok call with no team or owner key says
/// `agent.sign_in_required`: a turn or start that fails on it is a sign-in, typed
/// `auth.signed_out`, and a start's refusal names the harness (hq#11225).
#[test]
fn the_gateways_sign_in_marker_is_a_sign_in() {
    for message in [
        "[API Error: 401 cmux: sign in required (agent.sign_in_required)]",
        "agent process closed (grok): 401 Unauthorized: cmux: sign in required (agent.sign_in_required)",
    ] {
        assert_eq!(auth_kind(message), Some(kind::AUTH_SIGNED_OUT), "{message}");
    }
    let mut e = RpcError::new(
        -32603,
        "Request failed: 401 cmux: sign in required (agent.sign_in_required)",
    );
    assert!(start_sign_in(&mut e, "gemini"));
    let data = e.data.unwrap();
    assert_eq!(data["reason"], SIGN_IN_REQUIRED);
    assert_eq!(data["errorKind"], kind::AUTH_SIGNED_OUT);
    assert_eq!(data["details"]["harness"], "gemini");
}
