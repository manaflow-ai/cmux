// Context inventory and edits use the attached session's local acpmux link.
// Included by agent_session_attach_tests.rs for the real command dispatcher
// and private fake acpmux socket.

#[test]
fn session_context_reads_and_overrides_are_pinned_to_the_attachment() {
    let fake = FakeAcpmux::start("context");
    let mux = mux_with(&fake, "asa-context");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "context");
    let get = json!({"cmd":"agent-session-context", "surface":surface, "op":"get"});
    assert_eq!(attach(&mut client, surface)["ok"], true);
    let _ = fake.frame();
    let mut passed = 0;
    for (frame, method, params) in [
        (get, "_acpmux/context", json!({"sessionId":SESSION})),
        (
            json!({"cmd":"agent-session-context", "surface":surface, "op":"set",
                   "scope":"user", "text":"Read early.\nRun independent reads together."}),
            "_acpmux/context_override",
            json!({"sessionId":SESSION, "scope":"user", "text":"Read early.\nRun independent reads together."}),
        ),
        (
            json!({"cmd":"agent-session-context", "surface":surface, "op":"set",
                   "scope":"project", "text":""}),
            "_acpmux/context_override",
            json!({"sessionId":SESSION, "scope":"project", "text":""}),
        ),
        (
            json!({"cmd":"agent-session-context", "surface":surface, "op":"set",
                   "scope":"project", "text":null}),
            "_acpmux/context_override",
            json!({"sessionId":SESSION, "scope":"project", "text":null}),
        ),
    ] {
        let reply = client.request(frame);
        if reply["ok"] != true {
            continue;
        }
        assert_eq!(reply["data"], json!({
            "sessionId":SESSION,
            "parts":[{"source":"cmux", "text":"Read early.", "tokens":3}],
            "overrides":{"scope":params["scope"], "text":params["text"]},
        }), "the inventory is forwarded unchanged");
        let sent = fake.frame();
        assert_eq!(sent["method"], method);
        assert_eq!(sent["params"], params);
        passed += 1;
    }
    eprintln!("Context owner operations: {passed}/4");
    assert_eq!(passed, 4, "read, user edit, project edit and reset must all reach acpmux");
    assert_code(
        &client.request(json!({"cmd":"agent-session-context", "surface":surface + 1000, "op":"get"})),
        "agent_session.not_attached",
    );
    for extra in [json!({"sessionId":"other"}), json!({"cwd":"/another-project"}),
                  json!({"_meta":{"origin":"local"}})] {
        let mut frame = json!({"cmd":"agent-session-context", "surface":surface, "op":"set",
                              "scope":"project", "text":"elsewhere"});
        frame.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
        assert_code(&client.request(frame), "agent_session.bad_request");
    }
    for bad in [
        json!({"cmd":"agent-session-context", "surface":surface, "op":"get", "text":"ignored"}),
        json!({"cmd":"agent-session-context", "surface":surface, "op":"set", "scope":"machine"}),
        json!({"cmd":"agent-session-context", "surface":surface, "op":"set", "scope":"user", "text":7}),
        json!({"cmd":"agent-session-context", "surface":surface, "op":"set"}),
        json!({"cmd":"agent-session-context", "surface":surface, "op":"run"}),
    ] {
        assert_code(&client.request(bad), "agent_session.bad_request");
    }
    fake.no_frame();
}

#[test]
fn session_context_is_unavailable_to_read_only_attachments() {
    let fake = FakeAcpmux::start("context-observe");
    let mux = mux_with(&fake, "asa-context-observe");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "context-observe");
    assert_eq!(observe(&mut client, surface)["ok"], true);
    let _ = fake.frame();
    for frame in [
        json!({"cmd":"agent-session-context", "surface":surface, "op":"get"}),
        json!({"cmd":"agent-session-context", "surface":surface, "op":"set", "scope":"user", "text":"edit"}),
    ] {
        assert_code(&client.request(frame), "agent_session.read_only");
    }
    fake.no_frame();
}
