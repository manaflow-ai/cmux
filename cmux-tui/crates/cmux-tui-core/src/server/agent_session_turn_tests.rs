fn configure_turns(mux: &Mux) {
    mux.set_cloud_turn_config(
        CloudTurnConfig::from_lookup(|key| {
            Some(
                match key {
                    "CMUX_PLATFORM_ORIGIN" => "https://platform.test",
                    "CMUX_PLATFORM_WORKSPACE_ID" => "ws_one",
                    "CMUX_PLATFORM_MACHINE_ID" => "vm_logical",
                    _ => return None,
                }
                .into(),
            )
        })
        .unwrap(),
    );
}

#[test]
fn cloud_turn_partial_or_invalid_configuration_cannot_become_unconfigured() {
    assert!(CloudTurnConfig::from_lookup(|_| None).unwrap().is_none());
    assert!(
        CloudTurnConfig::from_lookup(
            |key| (key == "CMUX_PLATFORM_ORIGIN").then(|| "https://platform.test".into())
        )
        .unwrap()
        .is_none()
    );
    for origin in [
        None,
        Some("http://platform.test"),
        Some("https://user:secret@platform.test"),
        Some("https://platform.test/path"),
    ] {
        assert!(
            CloudTurnConfig::from_lookup(|key| match key {
                "CMUX_PLATFORM_WORKSPACE_ID" => Some("ws_one".into()),
                "CMUX_PLATFORM_MACHINE_ID" => Some("vm_one".into()),
                "CMUX_PLATFORM_ORIGIN" => origin.map(str::to_owned),
                _ => None,
            })
            .is_err()
        );
    }
    assert!(
        CloudTurnConfig::from_lookup(
            |key| (key == "CMUX_PLATFORM_MACHINE_ID").then(|| "vm_one".into())
        )
        .is_err()
    );
}

fn turn_capability() -> Value {
    json!({"capability":format!("trc_{}", "a".repeat(43)),"team":"team_one","user":"user_one",
        "workspace":"ws_one","machine":"vm_logical","generation":3,"session":SESSION,
        "turn":"p1","expiresAt":9999999999999u64,"purpose":"execute","attemptId":"attempt_1"})
}

fn preparation_capability() -> Value {
    let mut cap = turn_capability();
    cap["purpose"] = json!("prepare");
    cap
}

fn turn_command(command: &str, surface: SurfaceId) -> Value {
    json!({"cmd":command,"surface":surface,"prompt_id":"p1","workspace":"ws_one",
        "machine":"vm_logical","generation":3,"attempt_id":"attempt_1",
        "authorization":preparation_capability()})
}

#[test]
fn cloud_turn_transport_is_conditional_and_preserves_scope_and_capability() {
    let fake = FakeAcpmux::start("turn-bridge");
    let mux = mux_with(&fake, "turn-bridge");
    assert!(!identify_capabilities(&mux).contains(&"agent-session-turn-rewind-v1"));
    configure_turns(&mux);
    assert!(!identify_capabilities(&mux).contains(&"agent-session-turn-rewind-v1"));
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "turn-bridge");
    assert_eq!(attach(&mut client, surface)["ok"], true);
    assert_eq!(fake.frame()["method"], "initialize");
    let _ = fake.frame();
    assert!(identify_capabilities(&mux).contains(&"agent-session-turn-rewind-v1"));
    let reply = client.request(turn_command("agent-session-turn-prepare", surface));
    assert_eq!(
        reply["data"],
        json!({"session":SESSION,"turn":"p1","generation":3,"attempt_id":"attempt_1"})
    );
    let frame = fake.frame();
    assert_eq!(frame["method"], "agent-session-turn-prepare");
    assert!(frame["params"]["deadline_ms"].as_u64().is_some());
    let mut sent = frame["params"].clone();
    sent.as_object_mut().unwrap().remove("deadline_ms");
    assert_eq!(
        sent,
        json!({"sessionId":SESSION,"prompt_id":"p1",
        "workspace":"ws_one","machine":"vm_logical","generation":3,
        "attempt_id":"attempt_1","authorization":preparation_capability()})
    );
    assert_eq!(client.request(turn_command("agent-session-turn-abandon", surface))["ok"], true);
    let mut expected = turn_command("agent-session-turn-abandon", surface);
    expected.as_object_mut().unwrap().remove("cmd");
    expected.as_object_mut().unwrap().remove("surface");
    expected["sessionId"] = json!(SESSION);
    assert_eq!(fake.frame()["params"], expected);
    let envelope = turn_capability();
    assert_eq!(
        client.request(json!({"cmd":"agent-session-prompt","surface":surface,
        "prompt_id":"p1","text":"hello","cloud_turn":envelope}))["ok"],
        true
    );
    assert_eq!(fake.frame()["params"]["cloud_turn"], envelope);
}

#[test]
fn cloud_turn_transport_keeps_legacy_prompts_and_refuses_malformed_or_wrong_scope() {
    let fake = FakeAcpmux::start("turn-refusal");
    let mux = mux_with(&fake, "turn-refusal");
    configure_turns(&mux);
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "turn-refusal");
    assert_eq!(attach(&mut client, surface)["ok"], true);
    assert_eq!(fake.frame()["method"], "initialize");
    let _ = fake.frame();
    let mut wrong = turn_capability();
    wrong["machine"] = json!("other");
    assert_eq!(
        client.request(json!({"cmd":"agent-session-prompt","surface":surface,
        "prompt_id":"legacy","text":"hello"}))["ok"],
        true
    );
    assert!(fake.frame()["params"].get("cloud_turn").is_none());
    for envelope in
        [Some(Value::Null), Some(json!({})), Some(wrong), Some(preparation_capability())]
    {
        let mut frame =
            json!({"cmd":"agent-session-prompt","surface":surface,"prompt_id":"p1","text":"hi"});
        if let Some(envelope) = envelope {
            frame["cloud_turn"] = envelope;
        }
        assert_code(&client.request(frame), "agent_session.bad_request");
    }
    for (field, value) in [
        ("purpose", json!("execute")),
        ("generation", json!(4)),
        ("attemptId", json!("another")),
        ("turn", json!("another")),
    ] {
        for command in ["agent-session-turn-prepare", "agent-session-turn-abandon"] {
            let mut frame = turn_command(command, surface);
            frame["authorization"][field] = value.clone();
            assert_code(&client.request(frame), "agent_session.bad_request");
        }
    }
    assert_code(
        &client.request(json!({"cmd":"agent-session-turn-prepare","surface":surface,
        "prompt_id":"p1","workspace":"ws_other","machine":"vm_logical","generation":3,
        "attempt_id":"attempt_1","authorization":preparation_capability()})),
        "agent_session.bad_request",
    );
    mux.set_cloud_turn_config(None);
    assert_code(
        &client.request(turn_command("agent-session-turn-prepare", surface)),
        "agent_session.unavailable",
    );
    fake.no_frame();
}

#[test]
fn cloud_turn_wait_does_not_block_cancel_on_the_same_native_connection() {
    let (release, gate) = channel();
    let fake = FakeAcpmux::start_with(
        "turn-wait",
        Fixture { turn_prepare_gate: Some(Arc::new(Mutex::new(gate))), ..Fixture::default() },
    );
    let mux = mux_with(&fake, "turn-wait");
    configure_turns(&mux);
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "turn-wait");
    assert_eq!(attach(&mut client, surface)["ok"], true);
    assert_eq!(fake.frame()["method"], "initialize");
    let _ = fake.frame();
    let prepared = client.send(turn_command("agent-session-turn-prepare", surface));
    assert_eq!(fake.frame()["method"], "agent-session-turn-prepare");
    assert_eq!(client.request(json!({"cmd":"agent-session-cancel","surface":surface}))["ok"], true);
    assert_eq!(fake.frame()["method"], "session/cancel");
    release.send(()).unwrap();
    assert_eq!(client.answer(prepared)["data"]["turn"], "p1");
}

#[test]
fn cloud_turn_prepare_refuses_expired_or_unbounded_deadlines() {
    let fake = FakeAcpmux::start("turn-deadline");
    let mux = mux_with(&fake, "turn-deadline");
    configure_turns(&mux);
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "turn-deadline");
    assert_eq!(attach(&mut client, surface)["ok"], true);
    assert_eq!(fake.frame()["method"], "initialize");
    let _ = fake.frame();
    for deadline in [0, u64::MAX] {
        assert_code(
            &client.request(json!({"cmd":"agent-session-turn-prepare","surface":surface,
            "prompt_id":"p1","workspace":"ws_one","machine":"vm_logical","generation":3,
            "deadline_ms":deadline,"attempt_id":"attempt_1","authorization":preparation_capability()})),
            "agent_session.bad_request",
        );
    }
    fake.no_frame();
}

#[test]
fn configured_machine_with_old_acpmux_keeps_plain_prompts_without_advertising_rewind() {
    let fake = FakeAcpmux::start_with(
        "turn-old",
        Fixture { turn_unsupported: true, ..Fixture::default() },
    );
    let mux = mux_with(&fake, "turn-old");
    configure_turns(&mux);
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "turn-old");
    let attached = attach(&mut client, surface);
    assert_eq!(attached["data"]["cloud_turn_supported"], false);
    assert_eq!(fake.frame()["method"], "initialize");
    let _ = fake.frame();
    assert!(!identify_capabilities(&mux).contains(&"agent-session-turn-rewind-v1"));
    assert_eq!(
        client.request(json!({"cmd":"agent-session-prompt","surface":surface,
        "prompt_id":"legacy","text":"hello"}))["ok"],
        true
    );
    assert_eq!(fake.frame()["method"], "session/prompt");
    assert_code(
        &client.request(turn_command("agent-session-turn-prepare", surface)),
        "agent_session.unavailable",
    );
    fake.no_frame();
}

#[test]
fn uncertain_turn_support_fails_attach_instead_of_allowing_uncaptured_prompts() {
    let fake = FakeAcpmux::start_with(
        "turn-unknown",
        Fixture { turn_initialize_malformed: true, ..Fixture::default() },
    );
    let mux = mux_with(&fake, "turn-unknown");
    configure_turns(&mux);
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "turn-unknown");
    assert_code(&attach(&mut client, surface), "agent_session.unavailable");
    assert_eq!(fake.frame()["method"], "initialize");
    assert!(!identify_capabilities(&mux).contains(&"agent-session-turn-rewind-v1"));
    fake.no_frame();
}

#[test]
fn scoped_attach_hands_off_unscoped_acpmux_once_and_rechecks_before_attach() {
    let ready = Arc::new(AtomicBool::new(false));
    let fake = FakeAcpmux::start_with(
        "turn-handoff",
        Fixture { turn_scope_ready: Some(ready.clone()), ..Fixture::default() },
    );
    let mux = mux_with(&fake, "turn-handoff");
    configure_turns(&mux);
    let calls = Arc::new(AtomicU64::new(0));
    let count = calls.clone();
    mux.set_acpmux_handoff(Some(Arc::new(move || {
        count.fetch_add(1, Ordering::AcqRel);
        ready.store(true, Ordering::Release);
        Ok(())
    })));
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "turn-handoff");
    let reply = attach(&mut client, surface);
    assert_eq!(reply["ok"], true);
    assert_eq!(reply["data"]["cloud_turn_supported"], true);
    // Discovery, post-handoff verification, then discovery on the actual stream.
    for _ in 0..3 {
        assert_eq!(fake.frame()["method"], "initialize");
    }
    assert_eq!(fake.frame()["method"], "_acpmux/attach");
    assert_eq!(calls.load(Ordering::Acquire), 1);
    let surface = agent_tab(&mux, Some(SESSION));
    assert_eq!(attach(&mut client, surface)["ok"], true);
    assert_eq!(calls.load(Ordering::Acquire), 1);
}

#[test]
fn failed_scope_handoff_never_attaches_or_restarts_repeatedly() {
    let fake = FakeAcpmux::start_with(
        "turn-handoff-old",
        Fixture { turn_unsupported: true, ..Fixture::default() },
    );
    let mux = mux_with(&fake, "turn-handoff-old");
    configure_turns(&mux);
    let calls = Arc::new(AtomicU64::new(0));
    let count = calls.clone();
    mux.set_acpmux_handoff(Some(Arc::new(move || {
        count.fetch_add(1, Ordering::AcqRel);
        Ok(())
    })));
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "turn-handoff-old");
    assert_code(&attach(&mut client, surface), "agent_session.unavailable");
    for _ in 0..2 {
        assert_eq!(fake.frame()["method"], "initialize");
    }
    fake.no_frame();
    assert_code(&attach(&mut client, surface), "agent_session.unavailable");
    assert_eq!(fake.frame()["method"], "initialize");
    fake.no_frame();
    assert_eq!(calls.load(Ordering::Acquire), 1);
}
