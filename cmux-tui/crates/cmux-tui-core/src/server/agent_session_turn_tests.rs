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
    for origin in [None, Some("http://platform.test"), Some("https://user:secret@platform.test")] {
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
        "turn":"turn_1","expiresAt":9999999999999u64})
}

#[test]
fn cloud_turn_transport_is_conditional_and_preserves_scope_and_capability() {
    let fake = FakeAcpmux::start("turn-bridge");
    let mux = mux_with(&fake, "turn-bridge");
    assert!(!capabilities::identify_capabilities(&mux).contains(&"agent-session-turn-rewind-v1"));
    configure_turns(&mux);
    assert!(!capabilities::identify_capabilities(&mux).contains(&"agent-session-turn-rewind-v1"));
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "turn-bridge");
    assert_eq!(attach(&mut client, surface)["ok"], true);
    assert_eq!(fake.frame()["method"], "initialize");
    let _ = fake.frame();
    assert!(capabilities::identify_capabilities(&mux).contains(&"agent-session-turn-rewind-v1"));
    let reply = client.request(json!({"cmd":"agent-session-turn-prepare","surface":surface,
        "prompt_id":"p1","workspace":"ws_one","machine":"vm_logical","generation":3}));
    assert_eq!(reply["data"], json!({"session":SESSION,"turn":"turn_1"}));
    let frame = fake.frame();
    assert_eq!(frame["method"], "agent-session-turn-prepare");
    assert!(frame["params"]["deadline_ms"].as_u64().is_some());
    let mut sent = frame["params"].clone();
    sent.as_object_mut().unwrap().remove("deadline_ms");
    assert_eq!(
        sent,
        json!({"sessionId":SESSION,"prompt_id":"p1",
        "workspace":"ws_one","machine":"vm_logical","generation":3})
    );
    assert_eq!(
        client.request(
            json!({"cmd":"agent-session-turn-abandon","surface":surface,"prompt_id":"p1"})
        )["ok"],
        true
    );
    assert_eq!(fake.frame()["params"], json!({"sessionId":SESSION,"prompt_id":"p1"}));
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
    for envelope in [Some(Value::Null), Some(json!({})), Some(wrong)] {
        let mut frame =
            json!({"cmd":"agent-session-prompt","surface":surface,"prompt_id":"p1","text":"hi"});
        if let Some(envelope) = envelope {
            frame["cloud_turn"] = envelope;
        }
        assert_code(&client.request(frame), "agent_session.bad_request");
    }
    assert_code(
        &client.request(json!({"cmd":"agent-session-turn-prepare","surface":surface,
        "prompt_id":"p1","workspace":"ws_other","machine":"vm_logical","generation":3})),
        "agent_session.bad_request",
    );
    mux.set_cloud_turn_config(None);
    assert_code(
        &client.request(json!({"cmd":"agent-session-turn-prepare","surface":surface,
        "prompt_id":"p1","workspace":"ws_one","machine":"vm_logical","generation":3})),
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
    let prepared = client.send(json!({"cmd":"agent-session-turn-prepare","surface":surface,
        "prompt_id":"p1","workspace":"ws_one","machine":"vm_logical","generation":3}));
    assert_eq!(fake.frame()["method"], "agent-session-turn-prepare");
    assert_eq!(client.request(json!({"cmd":"agent-session-cancel","surface":surface}))["ok"], true);
    assert_eq!(fake.frame()["method"], "session/cancel");
    release.send(()).unwrap();
    assert_eq!(client.answer(prepared)["data"]["turn"], "turn_1");
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
            "deadline_ms":deadline})),
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
    assert!(!capabilities::identify_capabilities(&mux).contains(&"agent-session-turn-rewind-v1"));
    assert_eq!(
        client.request(json!({"cmd":"agent-session-prompt","surface":surface,
        "prompt_id":"legacy","text":"hello"}))["ok"],
        true
    );
    assert_eq!(fake.frame()["method"], "session/prompt");
    assert_code(
        &client.request(json!({"cmd":"agent-session-turn-prepare","surface":surface,
        "prompt_id":"p1","workspace":"ws_one","machine":"vm_logical","generation":3})),
        "agent_session.unavailable",
    );
    fake.no_frame();
}
