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
        assert_eq!(fake.frame()["params"]["_meta"]["acpmux"]["author"], author);
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
}
