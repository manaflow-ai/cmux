//! Host proxy identity is attested by the same-user socket, not by network JSON.
//! Local same-user processes already have owner access. Remote relay transports
//! cannot bind; the host proxy never forwards this verb from a teammate.
//! A link share's guest binds the same way (`link_guest`, agent_session_shares.rs).
use super::*;

#[path = "agent_session_shares.rs"]
pub(super) mod shares;

/// A teammate's verbs: the shared chat's own, never start, trust, media, children, permission,
/// typing or view, whatever the proxy forwards.
const TEAMMATE_VERBS: [&str; 6] = [
    "agent-session-attach",
    "agent-session-observe",
    "agent-session-events",
    "agent-session-prompt",
    "agent-session-cancel",
    "agent-session-detach",
];
/// A link guest's verbs: watch and write (every prompt held for the owner), its typing and view.
/// Never cancel, permission, children or media. An attach is the guest's writable observe.
const GUEST_VERBS: [&str; 7] = [
    "agent-session-attach",
    "agent-session-observe",
    "agent-session-events",
    "agent-session-prompt",
    "agent-session-typing",
    "agent-session-view",
    "agent-session-detach",
];

/// Whether `author` is a link guest's (`guest:<share_id>.<guest_id>`).
pub(super) fn is_guest(author: &Value) -> bool {
    author["id"].as_str().is_some_and(|id| id.starts_with(shares::GUEST_PREFIX))
}

/// The refusal of a frame outside a bound link's verbs.
pub(super) fn scope_refusal(mux: &Mux, client: u64) -> Refusal {
    match author(mux, client) {
        Some(author) if is_guest(&author) => Refusal::ScopeNotGranted,
        _ => Refusal::NotTrusted,
    }
}

/// A frame `check` accepted: a bound link's frame outside its verbs is refused; the owner's own
/// verbs (`agent-session-of`, `agent-session-share-*`) are answered here. `None` goes on.
pub(super) fn scope(
    mux: &Arc<Mux>,
    client: u64,
    object: &mut serde_json::Map<String, Value>,
    author: Option<&Value>,
    writer: &MessageWriter,
) -> Option<bool> {
    let cmd = object.get("cmd").and_then(Value::as_str).unwrap_or_default().to_owned();
    if let Some(author) = author {
        let guest = is_guest(author);
        let verbs: &[&str] = if guest { &GUEST_VERBS } else { &TEAMMATE_VERBS };
        if !verbs.contains(&cmd.as_str()) {
            let refusal = if guest { Refusal::ScopeNotGranted } else { Refusal::NotTrusted };
            return Some(refuse(writer, object.remove("id"), refusal));
        }
    }
    if cmd == "agent-session-of" {
        return Some(session_of(mux, client, std::mem::take(object), author.is_some(), writer));
    }
    if cmd.starts_with("agent-session-share-") {
        let object = std::mem::take(object);
        return Some(shares::handle(mux, client, &cmd, object, author.is_some(), writer));
    }
    None
}

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
    // The bind carries no host markers: those are only ever the proxy's stamps on later frames.
    if object.keys().any(|key| key.starts_with("_host_")) {
        return refuse(writer, id, Refusal::NotTrusted);
    }
    // Only as the connection's first line: a link that already subscribed or asked for anything
    // else keeps no daemon state into the teammate's session.
    if mux.control_clients.agent_sessions.past_first_line(client) {
        return refuse(writer, id, Refusal::NotTrusted);
    }
    let author = match (object.remove("author"), object.remove("link_guest")) {
        (Some(author), None) => {
            let login = author["login"].as_str().unwrap_or_default();
            let node = author["node"].as_str().unwrap_or_default();
            if login.is_empty() || login.len() > 320 || node.is_empty() || node.len() > 255 {
                return refuse(writer, id, Refusal::BadRequest);
            }
            let login = login.trim().to_ascii_lowercase();
            json!({"id": format!("tailnet:{login}"), "name": login, "login": login, "node": node})
        }
        // A redeemed guest of a live share: the daemon names it, never the binding connection.
        (None, Some(link)) => match shares::guest_author(mux, link) {
            Ok(author) => author,
            Err(refusal) => return refuse(writer, id, refusal),
        },
        _ => return refuse(writer, id, Refusal::BadRequest),
    };
    let mut authors =
        mux.control_clients.agent_sessions.proxy_authors.lock().unwrap_or_else(|e| e.into_inner());
    if authors.contains_key(&client) || mux.control_clients.agent_sessions.lock().count(client) != 0
    {
        return refuse(writer, id, Refusal::NotTrusted);
    }
    authors.insert(client, author.clone());
    drop(authors);
    // A share or guest that ended while this bind ran: its sweep may have missed this connection,
    // which was not bound yet. Checked after the insert, so any end later sees it bound.
    if is_guest(&author) && !mux.control_clients.agent_sessions.link_shares().guest_live(&author) {
        mux.control_clients
            .agent_sessions
            .proxy_authors
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&client);
        return refuse(writer, id, Refusal::ShareEnded);
    }
    // No host paths, session inventory or machine metadata in the handshake.
    ok(
        writer,
        id,
        json!({"app": "cmux-tui", "protocol": super::super::PROTOCOL_VERSION,
        "version": crate::release::distribution_version(), "generation": mux.registry_identity().1,
        "capabilities": ["agent-session-attach-v1", "agent-session-observe-v1"]}),
    )
}

/// A bound teammate's request, as [`check`] accepted it: the author and the chat its share
/// pinned (`None` only for a detach). The caller uses exactly this chat, never a later lookup a
/// rebind could change.
pub(super) struct Teammate {
    pub(super) author: Value,
    pub(super) pinned: Option<String>,
}

/// The request's author, checked against the connection's binding: `Ok(None)` for the owner's
/// own client, `Ok(Some(teammate))` for a bound teammate, a refusal otherwise. The caller uses this
/// answer, never a later lookup a disconnect could empty. A bound teammate's frame also names the
/// chat its share pinned (`_host_session`), and is refused unless the surface shows that chat now:
/// a surface rebound to another chat is not shared. A detach needs no chat.
pub(super) fn check(
    mux: &Mux,
    client: u64,
    object: &mut serde_json::Map<String, Value>,
) -> Result<Option<Teammate>, Refusal> {
    let supplied = object.remove("_host_author");
    let pinned = object.remove("_host_session");
    // Only the proxy's two markers exist; any other `_host_` field is a forgery.
    if object.keys().any(|key| key.starts_with("_host_")) {
        return Err(Refusal::NotTrusted);
    }
    let Some(bound) = author(mux, client) else {
        return if supplied.is_none() && pinned.is_none() {
            Ok(None)
        } else {
            Err(Refusal::NotTrusted)
        };
    };
    if is_guest(&bound) {
        return shares::check_guest(mux, client, bound, supplied, pinned, object).map(Some);
    }
    if supplied.as_ref() != Some(&bound) {
        return Err(Refusal::NotTrusted);
    }
    if object.get("cmd").and_then(Value::as_str) == Some("agent-session-detach") {
        return Ok(Some(Teammate { author: bound, pinned: None }));
    }
    let pinned = pinned.as_ref().and_then(Value::as_str).filter(|s| !s.is_empty());
    let current = object.get("surface").and_then(Value::as_u64).and_then(|s| tab_session(mux, s));
    if pinned.is_none() || pinned != current.as_deref() {
        return Err(Refusal::NotShared);
    }
    Ok(Some(Teammate { author: bound, pinned: pinned.map(str::to_owned) }))
}

/// `agent-session-of {surface}`: the surface's agent session, for `cmux host share` to pin. The
/// owner's own same-user client only; a teammate learns no session ids.
pub(super) fn session_of(
    mux: &Mux,
    client: u64,
    mut object: serde_json::Map<String, Value>,
    bound: bool,
    writer: &MessageWriter,
) -> bool {
    let id = object.remove("id");
    if bound || !mux.control_clients.is_unix(client) || mux.is_remote_client(client) {
        return refuse(writer, id, Refusal::NotTrusted);
    }
    let Some(surface) = object.get("surface").and_then(Value::as_u64) else {
        return refuse(writer, id, Refusal::BadRequest);
    };
    match tab_session(mux, surface) {
        Some(session) => ok(writer, id, json!({"surface": surface, "session": session})),
        None => refuse(writer, id, Refusal::UnknownTab),
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
        attach["_host_session"] = json!(SESSION);
        assert_eq!(client.request(attach)["ok"], true);
        // Every acpmux call carries the author: the attach and the session watch.
        for _ in 0..2 {
            assert_eq!(fake.raw_frame()["params"]["_meta"]["acpmux"]["author"], author);
        }
        // Whatever kinds a teammate asks for, it pages the transcript only.
        let events = json!({"cmd":"agent-session-events", "surface":surface,
            "kinds":["wire", "all"], "_host_author":author, "_host_session":SESSION});
        assert_eq!(client.request(events)["ok"], true);
        assert_eq!(fake.frame()["params"]["kinds"], json!(["transcript"]));
        let prompt = json!({"cmd":"agent-session-prompt", "surface":surface,
            "prompt_id":"p1", "text":"hello", "_host_author":author, "_host_session":SESSION});
        assert_eq!(client.request(prompt)["ok"], true);
        assert_eq!(fake.frame()["params"]["_meta"]["acpmux"]["author"], author);
        let mut other = Client::connect(&mux, "proxy-unbound");
        assert_code(
            &other.request(json!({"cmd":"agent-session-observe", "surface":surface,
            "_host_author":author, "_host_session":SESSION})),
            "agent_session.not_trusted",
        );
        fake.no_frame();
    }

    /// A share pins one chat: once the owner rebinds the shared surface to another chat, a fresh
    /// teammate attach or observe (and any frame of an attachment made before) is refused, while
    /// the owner's own connection is unaffected. Only the owner reads a surface's session id.
    #[test]
    fn a_teammate_never_follows_a_rebound_surface_to_another_chat() {
        let fake = FakeAcpmux::start("proxy-rebound");
        let mux = mux_with(&fake, "proxy-rebound");
        let surface = agent_tab(&mux, Some(SESSION));
        let mut owner = Client::connect(&mux, "proxy-rebound-owner");
        let of = json!({"cmd":"agent-session-of", "surface":surface});
        assert_eq!(owner.request(of.clone())["data"]["session"], SESSION);
        let mut client = Client::connect(&mux, "proxy-rebound");
        let author = json!({"id":"tailnet:person@example.com", "name":"person@example.com",
            "login":"person@example.com", "node":"laptop"});
        let bind = json!({"cmd":"agent-session-proxy-bind", "author":author});
        assert_eq!(client.request(bind)["ok"], true);
        let mut of_bound = of.clone();
        of_bound["_host_author"] = author.clone();
        of_bound["_host_session"] = json!(SESSION);
        assert_code(&client.request(of_bound), "agent_session.not_trusted");
        let frame = |cmd: &str| {
            let mut frame = json!({"cmd":cmd, "surface":surface, "_host_author":author, "_host_session":SESSION});
            if cmd == "agent-session-prompt" {
                frame["prompt_id"] = json!("p1");
                frame["text"] = json!("hello");
            }
            frame
        };
        let mut unpinned = frame("agent-session-attach");
        unpinned.as_object_mut().unwrap().remove("_host_session");
        assert_code(&client.request(unpinned), "agent_session.not_shared");
        assert_eq!(client.request(frame("agent-session-attach"))["ok"], true);
        // The owner's own connection names no chat and is never pinned.
        assert_eq!(
            owner.request(json!({"cmd":"agent-session-observe", "surface":surface}))["ok"],
            true
        );
        crate::server::agent_session_attach_tests::run(
            &mux,
            json!({"cmd":"bind-conversation-tab-session","surface":surface,
                "session":"acp_session_2","expected_session":SESSION}),
        );
        for cmd in [
            "agent-session-events",
            "agent-session-prompt",
            "agent-session-cancel",
            "agent-session-attach",
            "agent-session-observe",
        ] {
            assert_code(&client.request(frame(cmd)), "agent_session.not_shared");
        }
        let mut fresh = Client::connect(&mux, "proxy-rebound-fresh");
        assert_eq!(
            fresh.request(json!({"cmd":"agent-session-proxy-bind", "author":author}))["ok"],
            true
        );
        for cmd in ["agent-session-attach", "agent-session-observe"] {
            assert_code(&fresh.request(frame(cmd)), "agent_session.not_shared");
        }
        assert_eq!(
            fresh.request(frame("agent-session-detach"))["ok"],
            true,
            "a detach needs no chat"
        );
        // The owner reads the new chat, and cannot claim a pin.
        assert_eq!(owner.request(of)["data"]["session"], "acp_session_2");
        let mut claimed = json!({"cmd":"agent-session-observe", "surface":surface});
        claimed["_host_session"] = json!("acp_session_2");
        assert_code(&owner.request(claimed), "agent_session.not_trusted");
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
        // A bound link cannot ask for presence; even one that had the capability gets none.
        let info = client.request(json!({"cmd":"set-client-info","name":"proxy",
            "capabilities":[AGENT_SESSION_PRESENCE_CAPABILITY]}));
        assert_code(&info, "agent_session.not_trusted");
        let bound = *mux
            .control_clients
            .agent_sessions
            .proxy_authors
            .lock()
            .unwrap()
            .keys()
            .next()
            .unwrap();
        mux.control_clients
            .set_info(bound, None, None, Some(vec![AGENT_SESSION_PRESENCE_CAPABILITY.to_owned()]))
            .unwrap();
        let attach = json!({"cmd":"agent-session-attach", "surface":surface, "_host_author":author, "_host_session":SESSION});
        let page = client.request(attach);
        assert_eq!(kinds(&page), ["user_message"], "the replayed draft is dropped");
        let older = client.request(json!({"cmd":"agent-session-events", "surface":surface,
            "before_seq": 3, "_host_author":author, "_host_session":SESSION}));
        assert_eq!(kinds(&older), ["user_message"], "a history page drops the draft: {older}");
        let record = |seq: u64, kind: &str| json!({"sessionId": SESSION, "seq": seq, "at": 1, "dir": "mux", "kind": kind});
        fake.notify("_acpmux/event", record(3, "composer"));
        child_changes(&mut fake);
        // The chat's own change reaches the teammate, cut to what the chat shows.
        fake.notify(
            "_acpmux/session_changed",
            json!({"sessionId": SESSION, "kind": "status", "seq": 3, "peer": "owner-mini",
                "session": {"sessionId": SESSION, "status": "idle", "cwd": "/Users/owner/secret",
                "tags": {"lane": "x"}}}),
        );
        fake.notify(
            "_acpmux/presence",
            json!({"sessionId": SESSION, "participants": [{"id": "owner", "name": "Owner"}]}),
        );
        fake.notify("_acpmux/event", record(4, "user_message"));
        // Every event up to the prompt record, in order (the fake's own replies may come first):
        // none is the draft, the chat's presence or a child's change.
        let mut own_change = None;
        loop {
            let event = client.event(WAIT).expect("the prompt record");
            if event["event"] == "agent-session-changed" {
                assert_eq!(
                    event["change"]["sessionId"], SESSION,
                    "no descendant reaches a teammate"
                );
                own_change = Some(event["change"].clone());
            }
            assert_ne!(event["record"]["kind"], "composer", "the draft never arrives");
            assert_ne!(event["event"], "agent-session-presence", "no presence reaches a teammate");
            if event["event"] == "agent-session-record" && event["record"]["kind"] == "user_message"
            {
                break;
            }
        }
        assert!(
            client.event(Duration::from_millis(300)).is_none(),
            "nothing after the prompt record"
        );
        assert_eq!(
            own_change,
            Some(json!({"sessionId": SESSION, "kind": "status", "seq": 3,
                "session": {"sessionId": SESSION, "status": "idle"}})),
            "no peer, folder or tags reach a teammate"
        );
        let children = json!({"cmd":"agent-session-children", "surface":surface, "_host_author":author, "_host_session":SESSION});
        assert_code(&client.request(children), "agent_session.not_trusted");
        let answer = json!({"cmd":"agent-session-permission", "surface":surface,
            "permission_id":"perm_attach", "option_id":"allow", "_host_author":author, "_host_session":SESSION});
        assert_code(&client.request(answer), "agent_session.not_trusted");
        // Its typing or view would count as the owner's: refused, and nothing reaches acpmux.
        for frame in [
            json!({"cmd":"agent-session-typing", "surface":surface, "on":true,
                "_host_author":author, "_host_session":SESSION}),
            json!({"cmd":"agent-session-view", "surface":surface, "visible":true,
                "_host_author":author, "_host_session":SESSION}),
        ] {
            assert_code(&client.request(frame), "agent_session.not_trusted");
        }
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
            .send(json!({"cmd":"agent-session-attach", "surface":surface, "_host_author":author, "_host_session":SESSION}));
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

    /// A teammate's link reaches the six shared-chat verbs and nothing else: not start, trust,
    /// media, children, permission, typing or view, and no other daemon command. A `_host_` field
    /// other than the proxy's two is refused on any connection.
    #[test]
    fn a_teammate_link_reaches_only_the_shared_chats_verbs() {
        let fake = FakeAcpmux::start("proxy-only");
        let mux = mux_with(&fake, "proxy-only");
        let surface = agent_tab(&mux, Some(SESSION));
        let mut owner = Client::connect(&mux, "proxy-only-owner");
        let mut forged = json!({"cmd":"agent-session-of", "surface":surface, "_host_fake":true});
        assert_code(&owner.request(forged.clone()), "agent_session.not_trusted");
        assert_eq!(
            owner.request(json!({"cmd":"list-workspaces"}))["ok"],
            true,
            "the owner is served"
        );
        let mut client = Client::connect(&mux, "proxy-only");
        let author = json!({"id":"tailnet:person@example.com", "name":"person@example.com",
            "login":"person@example.com", "node":"laptop"});
        let bind = json!({"cmd":"agent-session-proxy-bind", "author":author});
        assert_eq!(client.request(bind)["ok"], true);
        let pinned = |mut frame: Value| {
            frame["surface"] = json!(surface);
            frame["_host_author"] = author.clone();
            frame["_host_session"] = json!(SESSION);
            frame
        };
        assert_eq!(client.request(pinned(json!({"cmd":"agent-session-attach"})))["ok"], true);
        for frame in [
            json!({"cmd":"agent-session-trust", "cwd":"/tmp"}),
            json!({"cmd":"agent-session-start", "cwd":"/tmp"}),
            json!({"cmd":"agent-session-media", "media_id":"m1"}),
            json!({"cmd":"agent-session-children"}),
            json!({"cmd":"agent-session-permission", "permission_id":"perm_attach", "option_id":"allow"}),
            json!({"cmd":"agent-session-typing", "on":true}),
            json!({"cmd":"agent-session-view", "visible":true}),
        ] {
            let reply = client.request(pinned(frame.clone()));
            assert_code(&reply, "agent_session.not_trusted");
        }
        for frame in [
            json!({"cmd":"list-workspaces"}),
            json!({"cmd":"identify"}),
            json!({"cmd":"subscribe"}),
            json!({"protocol":"cmux.protocol/2", "type":"request",
                "operation":"agent_session.trust.get", "params":{"cwd":"/tmp"}}),
            json!({"protocol":"cmux.protocol/2", "type":"request",
                "operation":"workspace.create", "params":{}}),
        ] {
            assert_code(&client.request(frame), "agent_session.not_trusted");
        }
        forged["_host_author"] = author.clone();
        forged["_host_session"] = json!(SESSION);
        forged["cmd"] = json!("agent-session-events");
        assert_code(&client.request(forged), "agent_session.not_trusted");
        // Still attached and served for the shared chat's own verbs.
        assert_eq!(client.request(pinned(json!({"cmd":"agent-session-events"})))["ok"], true);
    }

    /// The owner rebinds the shared surface while acpmux answers a teammate's attach: the page
    /// (and the attachment) never reach the teammate.
    #[test]
    fn a_rebind_during_a_teammate_attach_refuses_the_page() {
        let (open, gate) = std::sync::mpsc::channel();
        let fixture =
            Fixture { attach_gate: Some(Arc::new(Mutex::new(gate))), ..Fixture::default() };
        let fake = FakeAcpmux::start_with("proxy-race", fixture);
        let mux = mux_with(&fake, "proxy-race");
        let surface = agent_tab(&mux, Some(SESSION));
        let mut client = Client::connect(&mux, "proxy-race");
        let author = json!({"id":"tailnet:person@example.com", "name":"person@example.com",
            "login":"person@example.com", "node":"laptop"});
        assert_eq!(
            client.request(json!({"cmd":"agent-session-proxy-bind", "author":author}))["ok"],
            true
        );
        let attach = client.send(json!({"cmd":"agent-session-attach", "surface":surface,
            "_host_author":author, "_host_session":SESSION}));
        assert_eq!(fake.raw_frame()["method"], "_acpmux/attach");
        crate::server::agent_session_attach_tests::run(
            &mux,
            json!({"cmd":"bind-conversation-tab-session","surface":surface,
                "session":"acp_session_2","expected_session":SESSION}),
        );
        open.send(()).unwrap();
        assert_code(&client.answer(attach), "agent_session.not_shared");
        assert!(
            client.named_event("agent-session-record", Duration::from_millis(300)).is_none(),
            "no record of the chat follows"
        );
    }

    /// A remote-relay connection never binds a proxy identity nor reads a surface's session.
    #[test]
    fn a_remote_relay_connection_cannot_bind_or_read_a_session() {
        let fake = FakeAcpmux::start("proxy-remote");
        let mux = mux_with(&fake, "proxy-remote");
        let surface = agent_tab(&mux, Some(SESSION));
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let remote = mux.control_clients.register(ClientTransport::Remote, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let author =
            json!({"id":"tailnet:person@example.com", "login":"person@example.com", "node":"n"});
        for frame in [
            json!({"id":1, "cmd":"agent-session-proxy-bind", "author":author}),
            json!({"id":2, "cmd":"agent-session-of", "surface":surface}),
        ] {
            handle_connection_frame(
                &mux,
                remote,
                ClientTransport::Remote,
                &frame.to_string(),
                &writer,
                &scheduler,
            );
        }
        while let Some(line) = outbound.try_pop() {
            assert!(!line.contains(SESSION), "no session id reaches a remote client: {line}");
        }
        assert!(author_of(&mux).is_none(), "no identity is bound");
        fake.no_connection();
    }

    /// A bind is a link's first line only, and carries no host markers: a connection that
    /// subscribed or asked anything first keeps no daemon state into a teammate's session.
    #[test]
    fn a_bind_is_the_first_line_and_names_no_host_marker() {
        let fake = FakeAcpmux::start("proxy-first");
        let mux = mux_with(&fake, "proxy-first");
        let author = json!({"id":"tailnet:person@example.com", "name":"person@example.com",
            "login":"person@example.com", "node":"laptop"});
        let bind = json!({"cmd":"agent-session-proxy-bind", "author":author});
        let mut late = Client::connect(&mux, "proxy-first-late");
        assert_eq!(late.request(json!({"cmd":"list-workspaces"}))["ok"], true);
        assert_code(&late.request(bind.clone()), "agent_session.not_trusted");
        for marker in ["_host_fake", "_host_author", "_host_session"] {
            let mut marked = bind.clone();
            marked[marker] = json!("x");
            let mut client = Client::connect(&mux, "proxy-first-marked");
            assert_code(&client.request(marked), "agent_session.not_trusted");
        }
        assert!(author_of(&mux).is_none(), "nothing bound");
        let mut first = Client::connect(&mux, "proxy-first-ok");
        assert_eq!(first.request(bind)["ok"], true);
    }

    /// The chat a teammate's request names is the one `check` validated: an attach, a page or a
    /// command for an attachment of another chat is refused, never followed to a rebound chat.
    #[test]
    fn a_teammate_request_uses_the_validated_pin() {
        let fake = FakeAcpmux::start("proxy-pin");
        let mux = mux_with(&fake, "proxy-pin");
        let surface = agent_tab(&mux, Some(SESSION));
        let socket = mux.control_clients.agent_sessions.socket().unwrap();
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let author = json!({"id":"tailnet:person@example.com", "name":"person@example.com",
            "login":"person@example.com", "node":"laptop"});
        let params: PageParams = serde_json::from_value(json!({"surface": surface})).unwrap();
        // The tab shows SESSION, but the request was validated for another chat (a rebind landed
        // between the check and the attach's own read).
        attach(
            &mux,
            client,
            Some(json!(1)),
            socket,
            params,
            false,
            Some(author),
            Some("acp_other".into()),
            &writer,
        );
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        let reply = loop {
            if let Some(line) = outbound.try_pop() {
                let reply: Value = serde_json::from_str(&line).unwrap();
                if reply["id"] == 1 {
                    break reply;
                }
            }
            assert!(std::time::Instant::now() < deadline, "the attach is answered");
            std::thread::sleep(Duration::from_millis(5));
        };
        assert_code(&reply, "agent_session.not_shared");
        fake.no_connection();
    }

    /// A rebind while acpmux answers a history page or a repeated attach of a teammate's existing
    /// attachment refuses the page.
    #[test]
    fn a_rebind_during_a_teammate_page_refuses_it() {
        let (open, gate) = std::sync::mpsc::channel();
        let fixture =
            Fixture { attach_gate: Some(Arc::new(Mutex::new(gate))), ..Fixture::default() };
        let fake = FakeAcpmux::start_with("proxy-page", fixture);
        let mux = mux_with(&fake, "proxy-page");
        let surface = agent_tab(&mux, Some(SESSION));
        let mut client = Client::connect(&mux, "proxy-page");
        let author = json!({"id":"tailnet:person@example.com", "name":"person@example.com",
            "login":"person@example.com", "node":"laptop"});
        assert_eq!(
            client.request(json!({"cmd":"agent-session-proxy-bind", "author":author}))["ok"],
            true
        );
        let frame = json!({"cmd":"agent-session-attach", "surface":surface,
            "_host_author":author, "_host_session":SESSION});
        open.send(()).unwrap();
        assert_eq!(client.request(frame.clone())["ok"], true);
        // Attached: a second attach only pages, through the same gated acpmux answer.
        while fake.next_frame(Duration::from_millis(300)).is_some() {}
        let again = client.send(frame);
        assert_eq!(fake.raw_frame()["method"], "_acpmux/attach");
        crate::server::agent_session_attach_tests::run(
            &mux,
            json!({"cmd":"bind-conversation-tab-session","surface":surface,
                "session":"acp_session_2","expected_session":SESSION}),
        );
        open.send(()).unwrap();
        assert_code(&client.answer(again), "agent_session.not_shared");
    }

    /// A rebind waits for a write to or for a teammate's attachment that already checked its tab
    /// (held here as that write would hold it), so none lands after the tab shows another chat.
    #[test]
    fn a_rebind_waits_for_a_teammate_write_in_flight() {
        let fake = FakeAcpmux::start("proxy-atomic");
        let mux = mux_with(&fake, "proxy-atomic");
        let surface = agent_tab(&mux, Some(SESSION));
        let in_flight = mux.control_clients.agent_sessions.shared();
        let (done, rebound) = std::sync::mpsc::channel();
        let rebinder = mux.clone();
        let thread = std::thread::spawn(move || {
            crate::server::agent_session_attach_tests::run(
                &rebinder,
                json!({"cmd":"bind-conversation-tab-session","surface":surface,
                    "session":"acp_session_2","expected_session":SESSION}),
            );
            done.send(()).unwrap();
        });
        assert!(
            rebound.recv_timeout(Duration::from_millis(300)).is_err(),
            "the rebind waits for the write in flight"
        );
        assert_eq!(tab_session(&mux, surface).as_deref(), Some(SESSION), "the tab still shows it");
        drop(in_flight);
        rebound.recv_timeout(Duration::from_secs(5)).expect("the rebind lands after the write");
        thread.join().unwrap();
        assert_eq!(tab_session(&mux, surface).as_deref(), Some("acp_session_2"));
    }

    /// A blank line is a line: a bind after one is refused.
    #[test]
    fn a_bind_after_a_blank_line_is_refused() {
        let fake = FakeAcpmux::start("proxy-blank");
        let mux = mux_with(&fake, "proxy-blank");
        let author = json!({"id":"tailnet:person@example.com", "name":"person@example.com",
            "login":"person@example.com", "node":"laptop"});
        let mut client = Client::connect(&mux, "proxy-blank");
        client.raw("\n");
        let bind = json!({"cmd":"agent-session-proxy-bind", "author":author});
        assert_code(&client.request(bind), "agent_session.not_trusted");
        assert!(author_of(&mux).is_none(), "nothing bound");
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
