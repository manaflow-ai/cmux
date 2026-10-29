fn observe(client: &mut Client, surface: SurfaceId) -> Value {
    client.request(json!({"cmd":"agent-session-observe","surface":surface,"limit":400,
                          "kinds":["transcript"]}))
}

fn attached_verbs(surface: SurfaceId) -> Vec<Value> {
    vec![
        json!({"id":2,"cmd":"agent-session-events","surface":surface}),
        json!({"id":3,"cmd":"agent-session-prompt","surface":surface,"prompt_id":"p1","text":"hi"}),
        json!({"id":4,"cmd":"agent-session-cancel","surface":surface}),
        json!({"id":5,"cmd":"agent-session-permission","surface":surface,
               "permission_id":"perm_attach","option_id":"allow"}),
    ]
}

#[test]
fn observe_replays_and_streams_but_rejects_session_mutations() {
    let mut fake = FakeAcpmux::start("observe");
    let mux = mux_with(&fake, "asa-observe");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "observe");
    let reply = observe(&mut client, surface);
    assert_eq!(reply["ok"], json!(true), "{reply}");
    assert_eq!(reply["data"]["lastSeq"], json!(1));
    assert_eq!(reply["data"]["events"][0]["seq"], json!(1));
    let sent = fake.frame();
    assert_eq!(sent["method"], json!("_acpmux/attach"));
    assert_eq!(sent["params"]["sessionId"], json!(SESSION));
    assert_eq!(sent["params"]["eventStream"], json!(true));

    let early = client.event(WAIT).expect("the early record");
    assert_eq!(early["event"], json!("agent-session-record"));
    assert_eq!(early["record"]["seq"], json!(2));
    fake.notify("_acpmux/event", json!({"sessionId":SESSION,"seq":3,"kind":"agent_message"}));
    let live = client.event(WAIT).expect("the live record");
    assert_eq!(live["event"], json!("agent-session-record"));
    assert_eq!(live["record"]["seq"], json!(3));

    for mutation in [
        json!({"cmd":"agent-session-prompt","surface":surface,"prompt_id":"p1","text":"hi"}),
        json!({"cmd":"agent-session-cancel","surface":surface}),
        json!({"cmd":"agent-session-permission","surface":surface,
               "permission_id":"perm_attach","option_id":"allow"}),
        // An observer never composes, so it never types.
        json!({"cmd":"agent-session-typing","surface":surface,"on":true}),
    ] {
        assert_code(&client.request(mutation), "agent_session.read_only");
    }
    fake.no_frame();
    // Whether the observer's window shows the chat is still its own to say.
    let viewed = client.request(json!({"cmd":"agent-session-view","surface":surface,"visible":false}));
    assert_eq!(viewed["ok"], json!(true), "{viewed}");
    assert_eq!(fake.frame()["method"], json!("_acpmux/view"));
}

#[test]
fn observe_pages_from_a_cursor_and_preserves_close_reasons() {
    let mut fake = FakeAcpmux::start("observe-cursor");
    let mux = mux_with(&fake, "asa-observe-cursor");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "observe-cursor");
    assert_eq!(observe(&mut client, surface)["ok"], json!(true));
    let _ = fake.frame();
    let _ = client.event(WAIT).expect("the early record");

    let page = client.request(json!({"cmd":"agent-session-events","surface":surface,
                                      "after_seq":2,"limit":100000}));
    assert_eq!(page["ok"], json!(true), "{page}");
    let sent = fake.frame();
    assert_eq!(sent["method"], json!("_acpmux/events"));
    assert_eq!(sent["params"]["sessionId"], json!(SESSION));
    assert_eq!(sent["params"]["afterSeq"], json!(2));
    assert_eq!(sent["params"]["limit"], json!(500));

    fake.notify("_acpmux/lagged", json!({"dropped":3}));
    let closed = client.event(WAIT).expect("the close reason");
    assert_eq!(closed["event"], json!("agent-session-closed"));
    assert_eq!(closed["reason"], json!("lagged"));
}

#[test]
fn observe_rejects_mode_change_on_existing_writable_attach() {
    let fake = FakeAcpmux::start("observe-upgrade");
    let mux = mux_with(&fake, "asa-observe-upgrade");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "observe-upgrade");
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    let _ = fake.frame();
    let _ = client.event(WAIT).expect("the early record");

    assert_code(&observe(&mut client, surface), "agent_session.mode_conflict");
    fake.no_frame();
}

#[test]
fn attach_rejects_mode_change_on_existing_read_only_observer() {
    let fake = FakeAcpmux::start("observe-preserve");
    let mux = mux_with(&fake, "asa-observe-preserve");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "observe-preserve");
    assert_eq!(observe(&mut client, surface)["ok"], json!(true));
    assert_eq!(fake.frame()["method"], json!("_acpmux/attach"));
    let _ = client.event(WAIT).expect("the early record");

    assert_code(&attach(&mut client, surface), "agent_session.mode_conflict");
    for mutation in attached_verbs(surface).into_iter().skip(1) {
        assert_code(&client.request(mutation), "agent_session.read_only");
    }
    fake.no_frame();
}

/// The attach and observe routes are found by the line's decoded `cmd`, never by
/// a substring of the raw line: a `cmd` spelled with a JSON escape
/// reaches their handlers, which answer that this daemon has no acpmux.
#[test]
fn an_escaped_agent_session_cmd_reaches_its_route() {
    let mux = Mux::new_for_test("asa-escaped-cmd", crate::SurfaceOptions::default());
    let (outbound, writer) = queued_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    // The JSON escape of `-`.
    let dash = "\\u002d";
    let lines = [
        format!(r#"{{"id":1,"cmd":"agent-session{dash}observe","surface":1}}"#),
        format!(r#"{{"id":2,"cmd":"agent{dash}session-detach","surface":1}}"#),
        format!(r#"{{"id":3,"cmd":"agent-session{dash}attach","surface":1}}"#),
    ];
    for (index, line) in lines.iter().enumerate() {
        assert!(handle_connection_frame(
            &mux,
            client,
            ClientTransport::Unix,
            line,
            &writer,
            &scheduler
        ));
        let reply: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(reply["id"], json!(index + 1), "{line}");
        assert_code(&reply, "agent_session.unavailable");
    }
}
