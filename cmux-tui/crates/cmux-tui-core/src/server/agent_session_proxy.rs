//! Host proxy identity is attested by the same-user socket, not by network JSON.
//! Local same-user processes already have owner access. Remote relay transports
//! cannot bind; the host proxy never forwards this verb from a teammate.
use super::*;

pub(super) fn author(mux: &Mux, client: u64) -> Option<Value> {
    mux.control_clients
        .agent_sessions
        .proxy_authors
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(&client)
        .cloned()
}

pub(super) fn bind(
    mux: &Arc<Mux>,
    client: u64,
    mut object: serde_json::Map<String, Value>,
    writer: &MessageWriter,
) -> bool {
    let id = object.remove("id");
    if !mux.control_clients.is_unix(client) || mux.is_remote_client(client) {
        return refuse(writer, id, Refusal::NotTrusted);
    }
    let Some(author) = object.remove("author") else {
        return refuse(writer, id, Refusal::BadRequest);
    };
    let login = author["login"].as_str().unwrap_or_default();
    let node = author["node"].as_str().unwrap_or_default();
    if login.is_empty() || login.len() > 320 || node.is_empty() || node.len() > 255 {
        return refuse(writer, id, Refusal::BadRequest);
    }
    let login = login.trim().to_ascii_lowercase();
    let author =
        json!({"id": format!("tailnet:{login}"), "name": login, "login": login, "node": node});
    let mut authors =
        mux.control_clients.agent_sessions.proxy_authors.lock().unwrap_or_else(|e| e.into_inner());
    if authors.contains_key(&client) || mux.control_clients.agent_sessions.lock().count(client) != 0
    {
        return refuse(writer, id, Refusal::NotTrusted);
    }
    authors.insert(client, author);
    // No host paths, session inventory or machine metadata in the handshake.
    ok(
        writer,
        id,
        json!({"app": "cmux-tui", "protocol": super::super::PROTOCOL_VERSION,
        "version": crate::release::DISTRIBUTION_VERSION, "generation": mux.registry_identity().1,
        "capabilities": ["agent-session-attach-v1", "agent-session-observe-v1"]}),
    )
}

/// The request's author, checked against the connection's binding: `Some(None)` for the
/// owner's own client, `Some(Some(author))` for a bound teammate, `None` when refused. The
/// caller uses this answer, never a later lookup a disconnect could empty.
pub(super) fn check(
    mux: &Mux,
    client: u64,
    object: &mut serde_json::Map<String, Value>,
) -> Option<Option<Value>> {
    let supplied = object.remove("_host_author");
    match author(mux, client) {
        Some(bound) => (supplied.as_ref() == Some(&bound)).then_some(Some(bound)),
        None => supplied.is_none().then_some(None),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::agent_session_attach_tests::{
        Client, FakeAcpmux, Fixture, SESSION, agent_tab, assert_code, mux_with,
    };
    use crate::server::{
        BoundedOutbound, ClientTransport, ConnectionSurfaceScheduler, QueuedSink,
        handle_connection_frame,
    };

    #[test]
    fn proxy_identity_is_fixed_and_stamps_acpmux_calls() {
        let fake = FakeAcpmux::start("proxy-author");
        let mux = mux_with(&fake, "proxy-author");
        let surface = agent_tab(&mux, Some(SESSION));
        let mut client = Client::connect(&mux, "proxy-author");
        let author = json!({"id":"tailnet:person@example.com", "name":"person@example.com",
            "login":"person@example.com", "node":"laptop"});
        let bind = json!({"cmd":"agent-session-proxy-bind", "author":author});
        assert_eq!(client.request(bind.clone())["ok"], true);
        assert_code(&client.request(bind), "agent_session.not_trusted");
        let mut attach = json!({"cmd":"agent-session-attach", "surface":surface});
        assert_code(&client.request(attach.clone()), "agent_session.not_trusted");
        attach["_host_author"] = author.clone();
        assert_eq!(client.request(attach)["ok"], true);
        // Every acpmux call carries the author: the attach and the session watch.
        for _ in 0..2 {
            assert_eq!(fake.raw_frame()["params"]["_meta"]["acpmux"]["author"], author);
        }
        // Whatever kinds a teammate asks for, it pages the transcript only.
        let events = json!({"cmd":"agent-session-events", "surface":surface,
            "kinds":["wire", "all"], "_host_author":author});
        assert_eq!(client.request(events)["ok"], true);
        assert_eq!(fake.frame()["params"]["kinds"], json!(["transcript"]));
        let prompt = json!({"cmd":"agent-session-prompt", "surface":surface,
            "prompt_id":"p1", "text":"hello", "_host_author":author});
        assert_eq!(client.request(prompt)["ok"], true);
        assert_eq!(fake.frame()["params"]["_meta"]["acpmux"]["author"], author);
        let mut other = Client::connect(&mux, "proxy-unbound");
        assert_code(
            &other.request(json!({"cmd":"agent-session-observe", "surface":surface,
            "_host_author":author})),
            "agent_session.not_trusted",
        );
        fake.no_frame();
    }

    /// The attached session's family as acpmux knows it: a child the watch
    /// answer names, and a draft record in the attach page.
    fn family() -> Fixture {
        Fixture {
            page: vec![json!({"sessionId": SESSION, "seq": 2, "at": 1, "dir": "mux",
                "kind": "composer", "msg": {"text": "unsent"}})],
            watch: vec![json!({"sessionId": "acp_watched_child", "startedBy": SESSION})],
            history: vec![
                json!({"sessionId": SESSION, "seq": 1, "at": 1, "dir": "mux", "kind": "user_message"}),
                json!({"sessionId": SESSION, "seq": 2, "at": 1, "dir": "mux", "kind": "composer",
                    "msg": {"text": "older draft"}}),
            ],
            ..Fixture::default()
        }
    }

    /// The changes of a child the watch named and of one started later.
    fn child_changes(fake: &mut FakeAcpmux) {
        fake.notify(
            "_acpmux/session_changed",
            json!({"sessionId": "acp_watched_child", "kind": "status",
                "session": {"sessionId": "acp_watched_child", "startedBy": SESSION}}),
        );
        fake.notify(
            "_acpmux/session_changed",
            json!({"sessionId": "acp_new_child", "kind": "added",
                "session": {"sessionId": "acp_new_child", "spawnedBy": SESSION}}),
        );
    }

    fn kinds(page: &Value) -> Vec<String> {
        let events = page["data"]["events"].as_array().cloned().unwrap_or_default();
        events.iter().map(|e| e["kind"].as_str().unwrap_or_default().to_owned()).collect()
    }

    /// The owner's own attachment, on the same fake answers, gets the draft in
    /// its page and both children's changes: the fixture really names them.
    #[test]
    fn the_owners_attachment_sees_the_familys_drafts_and_children() {
        use crate::server::agent_session_attach_tests::WAIT;
        let mut fake = FakeAcpmux::start_with("proxy-owner", family());
        let mux = mux_with(&fake, "proxy-owner");
        let surface = agent_tab(&mux, Some(SESSION));
        let mut client = Client::connect(&mux, "proxy-owner");
        let page = client.request(json!({"cmd":"agent-session-attach", "surface":surface}));
        assert_eq!(kinds(&page), ["user_message", "composer"]);
        let older = client.request(json!({"cmd":"agent-session-events", "surface":surface,
            "before_seq": 3}));
        assert_eq!(kinds(&older), ["user_message", "composer"], "{older}");
        child_changes(&mut fake);
        for child in ["acp_watched_child", "acp_new_child"] {
            let change = client.named_event("agent-session-changed", WAIT).expect("a child change");
            assert_eq!(change["change"]["sessionId"], child);
        }
    }

    /// A bound (teammate) attachment gets no draft record in its page or live,
    /// hears no descendant's change (one the watch named, or one started
    /// later), lists no descendants and answers no asks.
    #[test]
    fn a_teammate_attachment_never_sees_drafts_or_descendants() {
        use crate::server::agent_session_attach_tests::WAIT;
        let mut fake = FakeAcpmux::start_with("proxy-private", family());
        let mux = mux_with(&fake, "proxy-private");
        let surface = agent_tab(&mux, Some(SESSION));
        let mut client = Client::connect(&mux, "proxy-private");
        let author = json!({"id":"tailnet:person@example.com", "name":"person@example.com",
            "login":"person@example.com", "node":"laptop"});
        assert_eq!(
            client.request(json!({"cmd":"agent-session-proxy-bind", "author":author}))["ok"],
            true
        );
        let attach =
            json!({"cmd":"agent-session-attach", "surface":surface, "_host_author":author});
        let page = client.request(attach);
        assert_eq!(kinds(&page), ["user_message"], "the replayed draft is dropped");
        let older = client.request(json!({"cmd":"agent-session-events", "surface":surface,
            "before_seq": 3, "_host_author":author}));
        assert_eq!(kinds(&older), ["user_message"], "a history page drops the draft: {older}");
        let record = |seq: u64, kind: &str| json!({"sessionId": SESSION, "seq": seq, "at": 1, "dir": "mux", "kind": kind});
        fake.notify("_acpmux/event", record(3, "composer"));
        child_changes(&mut fake);
        // The chat's own change reaches the teammate, cut to what the chat shows.
        fake.notify(
            "_acpmux/session_changed",
            json!({"sessionId": SESSION, "kind": "status", "session": {"sessionId": SESSION,
                "status": "idle", "cwd": "/Users/owner/secret", "tags": {"lane": "x"}}}),
        );
        fake.notify("_acpmux/event", record(4, "user_message"));
        // Every event up to the prompt record, in order (the fake's own replies may come first):
        // none is the draft, and none is a child's change.
        let mut own_change = None;
        loop {
            let event = client.event(WAIT).expect("the prompt record");
            if event["event"] == "agent-session-changed" {
                assert_eq!(
                    event["change"]["sessionId"], SESSION,
                    "no descendant reaches a teammate"
                );
                own_change = Some(event["change"]["session"].clone());
            }
            assert_ne!(event["record"]["kind"], "composer", "the draft never arrives");
            if event["event"] == "agent-session-record" && event["record"]["kind"] == "user_message"
            {
                break;
            }
        }
        assert!(
            client.event(Duration::from_millis(300)).is_none(),
            "nothing after the prompt record"
        );
        assert_eq!(own_change, Some(json!({"sessionId": SESSION, "status": "idle"})));
        let children =
            json!({"cmd":"agent-session-children", "surface":surface, "_host_author":author});
        assert_code(&client.request(children), "agent_session.not_trusted");
        let answer = json!({"cmd":"agent-session-permission", "surface":surface,
            "permission_id":"perm_attach", "option_id":"allow", "_host_author":author});
        assert_code(&client.request(answer), "agent_session.not_trusted");
    }

    /// A teammate that disconnects while acpmux answers the attach (the
    /// binding is forgotten then) still has its author on the session watch:
    /// the author is read on the request, not after.
    #[test]
    fn a_disconnect_during_attach_never_unstamps_the_watch() {
        let (open, gate) = std::sync::mpsc::channel();
        let fixture =
            Fixture { attach_gate: Some(Arc::new(Mutex::new(gate))), ..Fixture::default() };
        let fake = FakeAcpmux::start_with("proxy-gone", fixture);
        let mux = mux_with(&fake, "proxy-gone");
        let surface = agent_tab(&mux, Some(SESSION));
        let mut client = Client::connect(&mux, "proxy-gone");
        let author = json!({"id":"tailnet:person@example.com", "name":"person@example.com",
            "login":"person@example.com", "node":"laptop"});
        assert_eq!(
            client.request(json!({"cmd":"agent-session-proxy-bind", "author":author}))["ok"],
            true
        );
        client
            .send(json!({"cmd":"agent-session-attach", "surface":surface, "_host_author":author}));
        assert_eq!(fake.raw_frame()["method"], "_acpmux/attach");
        drop(client);
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while author_of(&mux).is_some() {
            assert!(std::time::Instant::now() < deadline, "the disconnect forgets the binding");
            std::thread::sleep(Duration::from_millis(5));
        }
        open.send(()).unwrap();
        // The worker goes on to the watch or stops; whatever reaches acpmux carries the author.
        while let Some(frame) = fake.next_frame(Duration::from_millis(500)) {
            assert_eq!(frame["params"]["_meta"]["acpmux"]["author"], author, "{frame}");
        }
    }

    fn author_of(mux: &Mux) -> Option<Value> {
        let authors = mux.control_clients.agent_sessions.proxy_authors.lock().unwrap();
        authors.values().next().cloned()
    }

    /// A WebSocket connection cannot bind a proxy identity: the frame goes
    /// through the connection dispatch the WebSocket listener runs.
    #[test]
    fn a_websocket_connection_cannot_bind_a_proxy_identity() {
        let fake = FakeAcpmux::start("proxy-websocket");
        let mux = mux_with(&fake, "proxy-websocket");
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let websocket = mux.control_clients.register(ClientTransport::WebSocket, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let author = json!({"id":"tailnet:person@example.com", "login":"person@example.com"});
        let bind = json!({"id":1, "cmd":"agent-session-proxy-bind", "author":author});
        let open = handle_connection_frame(
            &mux,
            websocket,
            ClientTransport::WebSocket,
            &bind.to_string(),
            &writer,
            &scheduler,
        );
        assert!(open);
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        let reply = loop {
            if let Some(line) = outbound.try_pop() {
                let reply: Value = serde_json::from_str(&line).unwrap();
                if reply["id"] == 1 {
                    break reply;
                }
            }
            assert!(std::time::Instant::now() < deadline, "the bind is answered");
            std::thread::sleep(Duration::from_millis(5));
        };
        assert_code(&reply, "agent_session.not_trusted");
        fake.no_connection();
    }
}
