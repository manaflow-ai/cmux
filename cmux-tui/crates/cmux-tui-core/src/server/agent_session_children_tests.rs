// `agent-session-children-v1` (agent_session_children.rs): an attached tab
// lists the chats its session started on this machine, follows their
// changes, and a listed child opens in a `registry:` tab of this store. The
// fake's `_acpmux/sessions` is the machine's whole list; only the attached
// session's descendants ever leave the daemon. Included by
// agent_session_attach_tests.rs.

/// A sub-session of [`SESSION`] (`start_session`, its `startedBy` link).
const CHILD: &str = "acp_child";
/// A chat [`SESSION`]'s agent started with `acpmux new` (`spawnedBy`).
const SPAWNED: &str = "acp_spawned";
/// A sub-session of [`CHILD`]: a descendant two levels down.
const GRANDCHILD: &str = "acp_grandchild";
/// Another chat of the machine, and a sub-session of it.
const UNRELATED: &str = "acp_unrelated";
const UNRELATED_CHILD: &str = "acp_unrelated_child";
/// A peer daemon's session that names [`SESSION`] as its parent.
const PEER_CHILD: &str = "acp_peer_child";

/// The fake acpmux's `_acpmux/sessions` answer, newest first.
fn machine_sessions() -> Value {
    json!({"sessions": [
        {"sessionId": GRANDCHILD, "startedBy": CHILD, "spawnedBy": null, "depth": 2,
         "updatedAt": 70},
        {"sessionId": UNRELATED, "startedBy": null, "spawnedBy": null, "updatedAt": 60},
        {"sessionId": CHILD, "startedBy": SESSION, "spawnedBy": SESSION, "depth": 1,
         "status": "running", "updatedAt": 50},
        {"sessionId": UNRELATED_CHILD, "startedBy": UNRELATED, "spawnedBy": UNRELATED,
         "updatedAt": 40},
        {"sessionId": PEER_CHILD, "startedBy": SESSION, "peer": "mac", "updatedAt": 30},
        {"sessionId": SPAWNED, "startedBy": null, "spawnedBy": SESSION, "updatedAt": 20},
        {"sessionId": SESSION, "name": "sub", "startedBy": null, "spawnedBy": null,
         "updatedAt": 10},
    ]})
}

fn children(client: &mut Client, surface: SurfaceId) -> Value {
    client.request(json!({"cmd":"agent-session-children","surface":surface}))
}

fn listed(reply: &Value) -> Vec<String> {
    reply["data"]["sessions"]
        .as_array()
        .unwrap_or_else(|| panic!("a session list: {reply}"))
        .iter()
        .map(|summary| summary["sessionId"].as_str().unwrap().to_owned())
        .collect()
}

/// `new-conversation-tab` of an agent tab on `host` with `session`, as the app sends it.
fn open_tab(mux: &Arc<Mux>, host: &str, session: &str) -> anyhow::Result<Value> {
    let (_, pane) = terminal_pane(mux);
    let command: Command = serde_json::from_value(json!({
        "cmd":"new-conversation-tab","pane":pane,
        "agent_session":{"host":host,"session":session,"harness":"claude"}}))?;
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound, control: None });
    handle_command(mux, mux.local_test_client(0), command, &writer)
}

fn own_host(mux: &Mux) -> String {
    format!("registry:{}", mux.registry_identity().0)
}

fn refused_as_mismatch(result: anyhow::Result<Value>) {
    let error = result.expect_err("a session of another chat never binds to a registry: tab");
    assert!(error.downcast_ref::<conversation_tabs_wire::MachineMismatch>().is_some(), "{error:#}");
}

#[test]
fn session_children_lists_exactly_the_attached_sessions_descendants() {
    let fake = FakeAcpmux::start("children");
    let mux = mux_with(&fake, "asa-children");
    let advertised = run(&mux, json!({"cmd":"identify"}))["capabilities"]
        .as_array()
        .unwrap()
        .contains(&json!("agent-session-children-v1"));
    assert!(advertised);
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "children");
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    let _ = fake.frame();

    let reply = children(&mut client, surface);
    assert_eq!(reply["ok"], json!(true), "{reply}");
    let sent = fake.frame();
    assert_eq!(sent["method"], json!("_acpmux/sessions"));
    assert_eq!(sent["params"], json!({}), "the daemon names no session or filter to acpmux");
    // Both links, any depth, acpmux's order; never the session itself, another
    // chat, its children or a peer's session.
    assert_eq!(listed(&reply), [GRANDCHILD, CHILD, SPAWNED]);
    let child = &reply["data"]["sessions"][1];
    assert_eq!(child["status"], json!("running"), "the summary as acpmux gave it");
    assert_eq!(child["startedBy"], json!(SESSION));
}

/// A list past acpmux's largest reply comes in pages, in no time order: a descendant
/// only the second page names is still listed, and the list is newest first.
#[test]
fn session_children_reads_every_page_of_a_list_too_big_for_one_reply() {
    let fixture = Fixture { sessions_pages: true, ..Fixture::default() };
    let fake = FakeAcpmux::start_with("children-pages", fixture);
    let mux = mux_with(&fake, "asa-children-pages");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "children-pages");
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    let _ = fake.frame();

    let reply = children(&mut client, surface);
    assert_eq!(reply["ok"], json!(true), "{reply}");
    assert_eq!(fake.frame()["params"], json!({}));
    let rest = fake.frame();
    assert_eq!(rest["method"], json!("_acpmux/sessions"));
    assert_eq!(rest["params"], json!({"cursor": "c1"}));
    assert_eq!(listed(&reply), [GRANDCHILD, CHILD, SPAWNED]);
}

/// The attach's watch list past acpmux's largest reply comes in pages too: a child
/// only the second page names is followed, so its changes reach the client even
/// when they no longer name its parent.
#[test]
fn session_children_follows_a_child_only_a_later_watch_page_names() {
    let fixture = Fixture {
        watch: vec![json!({"sessionId": CHILD, "startedBy": SESSION})],
        watch_pages: true,
        ..Fixture::default()
    };
    let mut fake = FakeAcpmux::start_with("children-watch-pages", fixture);
    let mux = mux_with(&fake, "asa-children-watch-pages");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "children-watch-pages");
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    assert_eq!(fake.frame()["method"], json!("_acpmux/attach"));
    let rest = fake.frame();
    assert_eq!(rest["method"], json!("_acpmux/sessions"));
    assert_eq!(rest["params"], json!({"cursor": "w1"}), "the watch's params, less `enabled`");
    let _ = client.event(WAIT).expect("the early record");

    fake.notify(
        "_acpmux/session_changed",
        json!({"sessionId": CHILD, "kind": "status", "recordKind": "status", "seq": 4,
               "session": {"sessionId": CHILD, "status": "idle"}}),
    );
    let change = client.event(WAIT).expect("the followed child's change");
    assert_eq!(change["event"], json!("agent-session-changed"), "{change}");
    assert_eq!(change["change"]["sessionId"], json!(CHILD));
}

/// A watch list that cannot be read whole (a bad page, or one after the first that fails)
/// would follow only some of the session's descendants: the attach is refused, and the
/// client attaches again.
#[test]
fn an_attach_whose_watch_list_cannot_be_read_whole_is_refused() {
    for (name, fixture) in [
        ("cw-bad", Fixture { watch_pages: true, watch_bad_page: true, ..Fixture::default() }),
        ("cw-fail", Fixture { watch_pages: true, watch_page_error: true, ..Fixture::default() }),
    ] {
        let fake = FakeAcpmux::start_with(name, fixture);
        let mux = mux_with(&fake, &format!("asa-{name}"));
        let surface = agent_tab(&mux, Some(SESSION));
        let mut client = Client::connect(&mux, name);
        assert_code(&attach(&mut client, surface), "agent_session.bad_list");
    }
}

#[test]
fn session_children_needs_an_attached_tab_of_a_trusted_connection() {
    let fake = FakeAcpmux::start("children-scope");
    let mux = mux_with(&fake, "asa-children-scope");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "children-scope");
    assert_code(&children(&mut client, surface), "agent_session.not_attached");
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    let _ = fake.frame();
    for extra in
        [json!({"sessionId": UNRELATED}), json!({"session": UNRELATED}), json!({"all": true})]
    {
        let mut frame = json!({"cmd":"agent-session-children","surface":surface});
        for (key, value) in extra.as_object().unwrap() {
            frame[key] = value.clone();
        }
        assert_code(&client.request(frame), "agent_session.bad_request");
    }
    fake.no_frame();

    // The remote relay and WebSocket clients never reach it.
    let frame = json!({"id":1,"cmd":"agent-session-children","surface":surface});
    assert!(remote_relay::gate::check_frame(&frame.to_string()).is_err());
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let websocket = mux.control_clients.register(ClientTransport::WebSocket, writer.clone());
    let handled = agent_session_attach::try_handle(&mux, websocket, &frame.to_string(), &writer);
    assert_eq!(handled, Some(true));
    let reply: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
    assert_code(&reply, "agent_session.not_trusted");
}

#[test]
fn session_children_listed_open_in_a_tab_of_this_store_and_no_other_session() {
    let fake = FakeAcpmux::start("children-open");
    let mux = mux_with(&fake, "asa-children-open");
    let host = own_host(&mux);
    // Before any listing, a child is just another session of the machine.
    refused_as_mismatch(open_tab(&mux, &host, CHILD));

    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "children-open");
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    assert_eq!(children(&mut client, surface)["ok"], json!(true));

    for child in [CHILD, SPAWNED, GRANDCHILD] {
        let tab = open_tab(&mux, &host, child).unwrap_or_else(|e| panic!("{child}: {e:#}"));
        let opened = tab["surface"].as_u64().unwrap();
        let record = run(&mux, json!({"cmd":"list-workspaces"}));
        let shown = record["workspaces"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|w| w["screens"].as_array().into_iter().flatten())
            .flat_map(|s| s["panes"].as_array().into_iter().flatten())
            .flat_map(|p| p["tabs"].as_array().into_iter().flatten())
            .find(|t| t["surface"] == json!(opened))
            .unwrap()["conversation"]["agent_session"]
            .clone();
        assert_eq!(shown["host"], json!(host));
        assert_eq!(shown["session"], json!(child));
    }
    for other in [UNRELATED, UNRELATED_CHILD, PEER_CHILD, SESSION] {
        refused_as_mismatch(open_tab(&mux, &host, other));
    }
    // A child is this machine's chat only: never filed under another store.
    refused_as_mismatch(open_tab(&mux, "registry:another-store", CHILD));
}

#[test]
fn session_children_changes_stream_on_the_attachment_and_no_others() {
    let mut fake = FakeAcpmux::start("children-stream");
    let mux = mux_with(&fake, "asa-children-stream");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "children-stream");
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    let _ = client.event(WAIT).expect("the early record");
    assert_eq!(listed(&children(&mut client, surface)), [GRANDCHILD, CHILD, SPAWNED]);

    let changed = |id: &str, session: Value| json!({"sessionId": id, "kind": "status", "recordKind": "status", "seq": 4, "session": session});
    fake.notify(
        "_acpmux/session_changed",
        changed(UNRELATED_CHILD, json!({"sessionId": UNRELATED_CHILD, "startedBy": UNRELATED})),
    );
    fake.notify(
        "_acpmux/session_changed",
        json!({"sessionId": "acp_peer_new", "kind": "status", "peer": "mac",
               "session": {"sessionId": "acp_peer_new", "startedBy": SESSION}}),
    );
    // A listed child's change, then a new child acpmux just made.
    fake.notify(
        "_acpmux/session_changed",
        changed(CHILD, json!({"sessionId": CHILD, "startedBy": SESSION, "status": "idle"})),
    );
    fake.notify(
        "_acpmux/session_changed",
        json!({"sessionId": "acp_new", "kind": "created", "recordKind": "created", "seq": 1,
               "session": {"sessionId": "acp_new", "spawnedBy": SESSION, "status": "running"}}),
    );
    // A sub-session of the new child: followed through its parent.
    fake.notify(
        "_acpmux/session_changed",
        changed("acp_new_child", json!({"sessionId": "acp_new_child", "startedBy": "acp_new"})),
    );
    let mut seen = Vec::new();
    while let Some(event) = client.event(Duration::from_millis(500)) {
        assert_eq!(event["event"], json!("agent-session-changed"), "{event}");
        assert_eq!(event["surface"], json!(surface));
        seen.push(event["change"]["sessionId"].as_str().unwrap().to_owned());
    }
    assert_eq!(seen, [CHILD, "acp_new", "acp_new_child"]);
    // A followed child is this machine's chat too: it opens in a tab here.
    open_tab(&mux, &own_host(&mux), "acp_new").expect("a followed child opens");
    refused_as_mismatch(open_tab(&mux, &own_host(&mux), "acp_peer_new"));

    // A purged child reaches the client once more, then is neither followed nor opened.
    fake.notify(
        "_acpmux/session_changed",
        json!({"sessionId": SPAWNED, "kind": "purged", "recordKind": "purged", "seq": 5,
               "session": {"sessionId": SPAWNED}}),
    );
    let purged = client.event(WAIT).expect("the purge");
    assert_eq!(purged["change"]["kind"], json!("purged"));
    refused_as_mismatch(open_tab(&mux, &own_host(&mux), SPAWNED));
    fake.notify("_acpmux/session_changed", changed(SPAWNED, json!({"sessionId": SPAWNED})));
    assert!(client.event(Duration::from_millis(300)).is_none(), "a purged child is not followed");
}
