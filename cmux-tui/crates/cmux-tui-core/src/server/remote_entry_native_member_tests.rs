//! A Cloud team member on a teammate's team machine (cloud multiplayer lane C): the signed `team`
//! dial reaches the chat verbs only, stamped with the member the token names; its prompts steer
//! like the owner's; answers, held-prompt decisions, starts, shares and terminals stay the owner's.
use super::*;
use crate::server::agent_session_attach_tests::{Client, FakeAcpmux, Fixture, SESSION, agent_tab};

/// The fake acpmux's fork of [`SESSION`]: the owner's side chat.
const SIDE_FORK: &str = "acp_side_1";

const MEMBER: &str = "user_0123456789abcdef0123";

fn member_stamp(user: &str, role: Option<VmKind>) -> String {
    let issued_at_ms =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis()
            as u64;
    cmux_link::stamp::encode(
        &LinkPeer { install: "inst_member".into(), user: user.into(), team: "team_a".into() },
        Some(StampCheck::NativeLinkToken { issued_at_ms, vm_kind: role }),
    )
    .unwrap()
}

fn call(stream: &mut UnixStream, reader: &mut BufReader<UnixStream>, mut frame: Value) -> Value {
    frame["id"] = json!(83);
    send(stream, &frame.to_string());
    loop {
        let reply = response(reader);
        if reply["id"] == json!(83) {
            return reply;
        }
    }
}

fn member_entry(name: &str) -> (FakeAcpmux, Entry, SurfaceId) {
    let fake = FakeAcpmux::start(name);
    let entry = entry_with(true, Arc::new(FsGate), Some(true));
    entry.mux.set_acpmux_socket(Some(fake.socket.clone()));
    entry.mux.set_agent_start_host(Arc::new(|| AgentStartHost::TeamVm));
    let surface = agent_tab(&entry.mux, Some(SESSION));
    (fake, entry, surface)
}

#[test]
fn a_team_member_attaches_and_steers_stamped_as_itself() {
    let (fake, entry, surface) = member_entry("member-steer");
    let (mut stream, mut reader) = connect_as_link(&entry);
    send(&mut stream, &member_stamp(MEMBER, Some(VmKind::Team)));
    let identity = call(&mut stream, &mut reader, json!({"cmd":"identify"}));
    assert_eq!(identity["ok"], true, "{identity}");
    let caps = identity["data"]["capabilities"].as_array().unwrap();
    assert!(caps.contains(&json!("agent-session-member-v1")), "{identity}");
    assert!(caps.contains(&json!("agent-session-steer-v1")), "{identity}");
    // No host paths or inventory in a member's identify.
    assert!(identity["data"].get("workspaces").is_none(), "{identity}");
    let info = call(
        &mut stream,
        &mut reader,
        json!({"cmd":"set-client-info", "name":"cmux NEXT", "kind":"frontend",
            "person_name":"Ana", "capabilities":["agent-session-presence-v1", "cloud-mobile-chat-v1"]}),
    );
    assert_eq!(info["ok"], true, "{info}");
    let author = json!({"id": MEMBER, "name": "Ana"});

    let list = call(&mut stream, &mut reader, json!({"cmd":"agent-session-team-list"}));
    assert_eq!(list["ok"], true, "{list}");
    assert_eq!(list["data"]["team"], "team_a");
    assert_eq!(list["data"]["role"], "member");
    assert_eq!(list["data"]["chats"][0]["surface"], json!(surface));
    assert_eq!(list["data"]["chats"][0]["session"], SESSION);
    // The list read acpmux's own `side` tags.
    assert_eq!(fake.frame()["method"], "_acpmux/sessions");

    let attach =
        call(&mut stream, &mut reader, json!({"cmd":"agent-session-attach", "surface":surface}));
    assert_eq!(attach["ok"], true, "{attach}");
    let frame = fake.frame();
    assert_eq!(frame["method"], "_acpmux/attach");
    assert_eq!(frame["params"]["_meta"]["acpmux"]["author"], author);
    assert_eq!(frame["params"]["kinds"], json!(["transcript"]));

    let prompt = call(
        &mut stream,
        &mut reader,
        json!({"cmd":"agent-session-prompt", "surface":surface, "prompt_id":"m1",
            "text":"also check the tests", "steer":true}),
    );
    assert_eq!(prompt["ok"], true, "{prompt}");
    let sent = fake.frame();
    assert_eq!(sent["method"], "session/prompt");
    assert_eq!(sent["params"]["_meta"]["acpmux"]["author"], author);
    // A member steers into the running turn like the owner; it is never held for approval.
    assert_eq!(sent["params"]["_meta"]["acpmux"]["steer"], true);
    assert!(sent["params"]["_meta"]["acpmux"]["author"].get("approval").is_none());
    assert_eq!(prompt["data"]["awaiting_owner"], false);

    for (cmd, field) in [("agent-session-typing", "on"), ("agent-session-view", "visible")] {
        let reply =
            call(&mut stream, &mut reader, json!({"cmd":cmd, "surface":surface, field:true}));
        assert_eq!(reply["ok"], true, "{cmd}: {reply}");
        assert_eq!(fake.frame()["params"]["_meta"]["acpmux"]["author"], author, "{cmd}");
    }

    // The owner answers asks and decides held prompts.
    let frame = json!({"cmd":"agent-session-permission", "surface":surface, "permission_id":"p",
            "option_id":"allow"});
    assert_eq!(
        call(&mut stream, &mut reader, frame)["error_code"],
        json!("agent_session.owner_only")
    );
    // A member's frame never names its own author or chat.
    let forged = json!({"cmd":"agent-session-prompt", "surface":surface, "prompt_id":"m2",
        "text":"x", "_host_author":{"id":"user_owner", "name":"Owner"}});
    assert_eq!(
        call(&mut stream, &mut reader, forged)["error_code"],
        json!("agent_session.not_trusted")
    );
    // Everything else stays the owner's.
    for frame in [
        json!({"cmd":"agent-session-queue-approve", "surface":surface, "prompt_id":"g1",
            "turn_id":"t", "revision":0}),
        json!({"cmd":"agent-session-start", "surface":surface, "cwd":"/tmp"}),
        json!({"cmd":"agent-session-trust", "surface":surface, "cwd":"/tmp"}),
        json!({"cmd":"agent-session-context", "surface":surface, "op":"get"}),
        // A fork, a side chat and the chat's descendants are the owner's.
        json!({"cmd":"agent-session-fork", "surface":surface, "through_seq":1}),
        json!({"cmd":"agent-session-children", "surface":surface}),
        json!({"cmd":"agent-session-side", "surface":surface, "live":true}),
        json!({"cmd":"agent-session-side", "surface":surface, "through_seq":1}),
        json!({"cmd":"agent-session-side", "surface":surface, "live":true, "prompt":"x",
            "prompt_id":"p"}),
        json!({"cmd":"agent-session-btw", "surface":surface, "question":"why?"}),
        json!({"cmd":"agent-session-share-create", "surface":surface}),
        json!({"cmd":"agent-session-of", "surface":surface}),
        json!({"cmd":"list-workspaces"}),
        json!({"cmd":"new-tab", "pane":1}),
        json!({"cmd":"send-key", "surface":surface, "key":"enter"}),
        json!({"cmd":"shutdown-daemon"}),
    ] {
        let reply = call(&mut stream, &mut reader, frame.clone());
        assert_eq!(reply["ok"], false, "{frame}: {reply}");
        assert_ne!(reply["error_code"], json!("agent_session.owner_only"), "{frame}");
    }
    // Removed from the team: the receiver's recheck closes the install's streams; a frame that
    // races it still fails the live-principal check.
    entry.mux.remote_relay().revocation.lock().unwrap().record_revoked("inst_member");
    let late =
        json!({"cmd":"agent-session-prompt", "surface":surface, "prompt_id":"m3", "text":"x"});
    assert_eq!(call(&mut stream, &mut reader, late)["ok"], false);
}

/// The owner's side chat is the owner's alone on a team machine too: a member's list leaves its
/// tab out and a member's attach to that tab is refused before acpmux is asked.
#[test]
fn a_team_member_never_lists_or_attaches_the_owners_side_chat() {
    let (fake, entry, chat) = member_entry("member-side");
    let side_tab = agent_tab(&entry.mux, Some(SIDE_FORK));
    // The owner opens the side chat of its chat (the daemon's own fork answer names it).
    let mut owner = Client::connect(&entry.mux, "member-side-owner");
    assert_eq!(owner.request(json!({"cmd":"agent-session-attach", "surface":chat}))["ok"], true);
    assert_eq!(fake.frame()["method"], "_acpmux/attach");
    let opened = owner.request(json!({"cmd":"agent-session-side", "surface":chat, "live":true}));
    assert_eq!(opened["data"]["sessionId"], SIDE_FORK, "{opened}");
    assert_eq!(fake.frame()["method"], "acp.session.fork");
    assert_eq!(fake.frame()["method"], "_acpmux/side");

    let (mut stream, mut reader) = connect_as_link(&entry);
    send(&mut stream, &member_stamp(MEMBER, Some(VmKind::Team)));
    let list = call(&mut stream, &mut reader, json!({"cmd":"agent-session-team-list"}));
    let chats = list["data"]["chats"].as_array().unwrap();
    assert_eq!(chats.len(), 1, "{list}");
    assert_eq!(chats[0]["surface"], json!(chat), "{list}");
    assert!(!list.to_string().contains(SIDE_FORK), "{list}");
    assert_eq!(fake.frame()["method"], "_acpmux/sessions");
    for frame in [
        json!({"cmd":"agent-session-attach", "surface":side_tab}),
        json!({"cmd":"agent-session-events", "surface":side_tab}),
        json!({"cmd":"agent-session-prompt", "surface":side_tab, "prompt_id":"m1", "text":"x"}),
    ] {
        let reply = call(&mut stream, &mut reader, frame.clone());
        assert_eq!(reply["ok"], false, "{frame}: {reply}");
    }
    assert_eq!(
        call(&mut stream, &mut reader, json!({"cmd":"agent-session-attach", "surface":side_tab}))["error_code"],
        json!("agent_session.not_trusted")
    );
    fake.no_frame();
    // The chat itself is still the member's to read.
    let attach =
        call(&mut stream, &mut reader, json!({"cmd":"agent-session-attach", "surface":chat}));
    assert_eq!(attach["ok"], true, "{attach}");
}

/// A daemon that restarted knows no side chat yet: acpmux's own `side` tag on the attach page
/// refuses the member, with no record sent, and the list leaves the tab out from then on.
#[test]
fn a_team_member_is_refused_a_side_chat_the_daemon_had_not_seen() {
    let fixture = Fixture { side_of: Some("acp_chat"), ..Fixture::default() };
    let fake = FakeAcpmux::start_with("member-side-tag", fixture);
    let entry = entry_with(true, Arc::new(FsGate), Some(true));
    entry.mux.set_acpmux_socket(Some(fake.socket.clone()));
    entry.mux.set_agent_start_host(Arc::new(|| AgentStartHost::TeamVm));
    let surface = agent_tab(&entry.mux, Some(SESSION));
    let (mut stream, mut reader) = connect_as_link(&entry);
    send(&mut stream, &member_stamp(MEMBER, Some(VmKind::Team)));
    let attach =
        call(&mut stream, &mut reader, json!({"cmd":"agent-session-attach", "surface":surface}));
    assert_eq!(attach["error_code"], json!("agent_session.not_trusted"), "{attach}");
    assert_eq!(entry.mux.control_clients.agent_sessions.attachment_count(), 0);
    let list = call(&mut stream, &mut reader, json!({"cmd":"agent-session-team-list"}));
    assert_eq!(list["data"]["chats"], json!([]), "{list}");
    let prompt =
        json!({"cmd":"agent-session-prompt", "surface":surface, "prompt_id":"m1", "text":"x"});
    assert_eq!(call(&mut stream, &mut reader, prompt)["ok"], false);
}

/// A daemon that just started holds no side chat in memory: the member's list, asked first,
/// reads acpmux's own `side` tags and leaves the tagged chat's surface and session id out; a
/// list acpmux cannot answer shows no chat rather than every chat.
#[test]
fn a_fresh_daemons_team_list_omits_a_side_chat_acpmux_tags() {
    for (name, fixture, listed) in [
        ("member-side-fresh", Fixture { side_of: Some("acp_chat"), ..Fixture::default() }, 1),
        ("member-list-unread", Fixture { sessions_unreadable: true, ..Fixture::default() }, 0),
    ] {
        let fake = FakeAcpmux::start_with(name, fixture);
        let entry = entry_with(true, Arc::new(FsGate), Some(true));
        entry.mux.set_acpmux_socket(Some(fake.socket.clone()));
        entry.mux.set_agent_start_host(Arc::new(|| AgentStartHost::TeamVm));
        // The tagged chat's tab and another chat's (acpmux lists it untagged).
        let side_tab = agent_tab(&entry.mux, Some(SESSION));
        let other_tab = agent_tab(&entry.mux, Some("acp_unrelated"));
        assert!(!entry.mux.control_clients.agent_sessions.sides.contains(SESSION));
        let (mut stream, mut reader) = connect_as_link(&entry);
        send(&mut stream, &member_stamp(MEMBER, Some(VmKind::Team)));
        let list = call(&mut stream, &mut reader, json!({"cmd":"agent-session-team-list"}));
        assert_eq!(list["ok"], true, "{list}");
        let chats = list["data"]["chats"].as_array().unwrap();
        assert_eq!(chats.len(), listed, "{list}");
        if listed == 1 {
            assert_eq!(chats[0]["surface"], json!(other_tab), "{list}");
            assert_eq!(chats[0]["session"], "acp_unrelated", "{list}");
        }
        let shown = list["data"]["chats"].to_string();
        assert!(!shown.contains(SESSION), "{list}");
        assert!(chats.iter().all(|chat| chat["surface"] != json!(side_tab)), "{list}");
        assert_eq!(fake.frame()["method"], "_acpmux/sessions");
    }
}

#[test]
fn a_non_member_dial_reaches_no_chat() {
    // Not a Cloud account (a token naming no `user_` id) or no signed role: refused like any
    // remote stream.
    for stamp in [member_stamp("42", Some(VmKind::Team)), member_stamp(MEMBER, None)] {
        let (fake, entry, surface) = member_entry("member-refused");
        let (mut stream, mut reader) = connect_as_link(&entry);
        send(&mut stream, &stamp);
        for frame in [
            json!({"cmd":"identify"}),
            json!({"cmd":"agent-session-team-list"}),
            json!({"cmd":"agent-session-attach", "surface":surface}),
            json!({"cmd":"agent-session-prompt", "surface":surface, "prompt_id":"x", "text":"x"}),
        ] {
            assert_eq!(call(&mut stream, &mut reader, frame)["error_code"], json!(REMOTE_DENIED));
        }
        drop(fake);
    }
}

#[test]
fn the_owner_shares_and_decides_on_their_own_cloud_machine() {
    let fake = FakeAcpmux::start("owner-share");
    let entry = entry_with(true, Arc::new(FsGate), Some(true));
    entry.mux.set_acpmux_socket(Some(fake.socket.clone()));
    entry.mux.set_agent_start_host(Arc::new(|| AgentStartHost::OwnerCloud));
    let surface = agent_tab(&entry.mux, Some(SESSION));
    let (mut stream, mut reader) = connect_as_link(&entry);
    send(&mut stream, &member_stamp("user_owner0000000000000", Some(VmKind::Owner)));
    // The Cloud chat's share verbs reach the machine's own share registry.
    let room = call(&mut stream, &mut reader, json!({"cmd":"agent-session-share-room"}));
    assert_eq!(room["ok"], true, "{room}");
    let listed = call(&mut stream, &mut reader, json!({"cmd":"agent-session-share-list"}));
    assert_eq!(listed["ok"], true, "{listed}");
    let of = call(&mut stream, &mut reader, json!({"cmd":"agent-session-of", "surface":surface}));
    assert_eq!(of["data"]["session"], SESSION, "{of}");
    let created = call(
        &mut stream,
        &mut reader,
        json!({"cmd":"agent-session-share-create", "surface":surface, "session":SESSION,
            "create_id":"c-1"}),
    );
    assert_eq!(created["ok"], true, "{created}");
    // The room bridge's redeem is never the owner's remote verb.
    let redeem = call(
        &mut stream,
        &mut reader,
        json!({"cmd":"agent-session-share-redeem", "share_id":created["data"]["share_id"]}),
    );
    assert_eq!(redeem["ok"], false, "{redeem}");
    // The owner's approval of a guest's held prompt reaches acpmux unstamped (the owner's).
    let attach =
        call(&mut stream, &mut reader, json!({"cmd":"agent-session-attach", "surface":surface}));
    assert_eq!(attach["ok"], true, "{attach}");
    assert_eq!(fake.frame()["method"], "_acpmux/attach");
    let _ = call(
        &mut stream,
        &mut reader,
        json!({"cmd":"agent-session-queue-approve", "surface":surface, "prompt_id":"g1",
            "turn_id":"turn_9", "revision":0}),
    );
    let sent = fake.frame();
    assert_eq!(sent["method"], "_acpmux/queue_approve");
    assert_eq!(
        sent["params"],
        json!({"sessionId":SESSION, "promptId":"g1", "turnId":"turn_9", "revision":0})
    );
    // The owner's own steer.
    let _ = call(
        &mut stream,
        &mut reader,
        json!({"cmd":"agent-session-prompt", "surface":surface, "prompt_id":"o1", "text":"now", "steer":true}),
    );
    let sent = fake.frame();
    assert_eq!(sent["params"]["_meta"]["acpmux"]["steer"], true);
    assert!(sent["params"]["_meta"]["acpmux"].get("author").is_none());
}
