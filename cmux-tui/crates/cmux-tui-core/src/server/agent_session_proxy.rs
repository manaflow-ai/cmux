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

pub(super) fn check(mux: &Mux, client: u64, object: &mut serde_json::Map<String, Value>) -> bool {
    let supplied = object.remove("_host_author");
    match author(mux, client) {
        Some(bound) => supplied.as_ref() == Some(&bound),
        None => supplied.is_none(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::agent_session_attach_tests::{
        Client, FakeAcpmux, SESSION, agent_tab, assert_code, mux_with,
    };
    use crate::server::{BoundedOutbound, ClientTransport, QueuedSink};

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

    /// A bound (teammate) attachment gets no draft records live, lists no
    /// descendants, and hears no other session's changes; WebSocket clients
    /// cannot bind.
    #[test]
    fn a_teammate_attachment_never_sees_drafts_or_descendants() {
        use crate::server::agent_session_attach_tests::WAIT;
        let mut fake = FakeAcpmux::start("proxy-private");
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
        assert_eq!(client.request(attach)["ok"], true);
        let record = |seq: u64, kind: &str| json!({"sessionId": SESSION, "seq": seq, "at": 1, "dir": "mux", "kind": kind});
        fake.notify("_acpmux/event", record(2, "composer"));
        fake.notify(
            "_acpmux/session_changed",
            json!({"sessionId": "acp_child", "parentId": SESSION}),
        );
        fake.notify("_acpmux/event", record(3, "user_message"));
        // Records arrive in order (the fake's own replies may come first): none is the draft.
        loop {
            let event =
                client.named_event("agent-session-record", WAIT).expect("the prompt record");
            assert_ne!(event["record"]["kind"], "composer", "the draft never arrives");
            if event["record"]["kind"] == "user_message" {
                break;
            }
        }
        assert!(client.named_event("agent-session-changed", Duration::from_millis(300)).is_none());
        let children =
            json!({"cmd":"agent-session-children", "surface":surface, "_host_author":author});
        assert_code(&client.request(children), "agent_session.not_trusted");
        let answer = json!({"cmd":"agent-session-permission", "surface":surface,
            "permission_id":"perm_attach", "option_id":"allow", "_host_author":author});
        assert_code(&client.request(answer), "agent_session.not_trusted");

        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let websocket = mux.control_clients.register(ClientTransport::WebSocket, writer.clone());
        let bind = json!({"id":1, "cmd":"agent-session-proxy-bind", "author":author});
        assert_eq!(try_handle(&mux, websocket, &bind.to_string(), &writer), Some(true));
        let reply: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_code(&reply, "agent_session.not_trusted");
    }
}
