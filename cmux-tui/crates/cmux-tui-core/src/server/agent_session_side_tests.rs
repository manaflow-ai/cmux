// `agent-session-side-v1` (agent_session_side.rs): the owner's attachment forks the attached
// chat and tags the fork its side chat in one step, asks a side question, prompts and discards
// the side chats it opened, and names no other session. Who else is refused the verb and the
// side chat itself: agent_session_shares_tests.rs (a link guest), agent_session_proxy.rs
// (a teammate link) and remote_entry_native_member_tests.rs (a Cloud team member). Included by
// agent_session_attach_tests.rs.

/// The fake acpmux's fork of [`SESSION`] and its side question's session.
pub(super) const SIDE_FORK: &str = "acp_side_fork";
pub(super) const SIDE_BTW: &str = "acp_side_btw";

/// An owner's client attached to a chat tab, with the attach frames read.
fn side_owner(label: &str, fixture: Fixture) -> (FakeAcpmux, Arc<Mux>, SurfaceId, Client) {
    let fake = FakeAcpmux::start_with(label, fixture);
    let mux = mux_with(&fake, label);
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, label);
    let reply = client.request(json!({"cmd":"agent-session-attach","surface":surface}));
    assert_eq!(reply["ok"], json!(true), "{reply}");
    while fake.next_frame(Duration::from_millis(200)).is_some() {}
    (fake, mux, surface, client)
}

fn side(client: &mut Client, surface: SurfaceId, mut frame: Value) -> Value {
    frame["cmd"] = json!("agent-session-side");
    frame["surface"] = json!(surface);
    client.request(frame)
}

#[test]
fn the_owner_opens_a_side_chat_as_a_tagged_fork_of_the_attached_chat() {
    let (fake, mux, surface, mut client) = side_owner("side-open", Fixture::default());
    let opened = side(&mut client, surface, json!({"op":"open","through_seq":7}));
    assert_eq!(opened["ok"], json!(true), "{opened}");
    assert_eq!(opened["data"]["sessionId"], json!(SIDE_FORK));
    let fork = fake.frame();
    assert_eq!(fork["method"], json!("acp.session.fork"));
    assert_eq!(fork["params"], json!({"sessionId":SESSION,"throughSeq":7}));
    // The tag names the fork acpmux answered and the attached chat, never a frame's id.
    let tag = fake.frame();
    assert_eq!(tag["method"], json!("_acpmux/side"));
    assert_eq!(tag["params"], json!({"sessionId":SIDE_FORK,"chat":SESSION}));
    assert!(mux.control_clients.agent_sessions.sides.contains(SIDE_FORK));
    assert!(!mux.control_clients.agent_sessions.sides.contains(SESSION));

    let live = side(&mut client, surface, json!({"op":"open","live":true}));
    assert_eq!(live["ok"], json!(true), "{live}");
    assert_eq!(fake.frame()["params"], json!({"sessionId":SESSION,"live":true}));
    assert_eq!(fake.frame()["method"], json!("_acpmux/side"));
}

#[test]
fn the_owner_prompts_and_discards_only_the_side_chats_it_opened() {
    let (fake, _mux, surface, mut client) = side_owner("side-prompt", Fixture::default());
    // Before any side chat is open, no id is this attachment's: not the fork's, not the chat's.
    for frame in [
        json!({"op":"prompt","session":SIDE_FORK,"prompt_id":"p0","text":"x"}),
        json!({"op":"prompt","session":SESSION,"prompt_id":"p0","text":"x"}),
        json!({"op":"prompt","session":"acp_unrelated","prompt_id":"p0","text":"x"}),
        json!({"op":"discard","session":SIDE_FORK}),
        json!({"op":"discard","session":SESSION}),
    ] {
        assert_code(&side(&mut client, surface, frame), "agent_session.bad_request");
    }
    fake.no_frame();

    assert_eq!(side(&mut client, surface, json!({"op":"open","live":true}))["ok"], json!(true));
    assert_eq!(fake.frame()["method"], json!("acp.session.fork"));
    assert_eq!(fake.frame()["method"], json!("_acpmux/side"));
    let reply = side(
        &mut client,
        surface,
        json!({"op":"prompt","session":SIDE_FORK,"prompt_id":"p1","text":"try it"}),
    );
    assert_eq!(reply["ok"], json!(true), "{reply}");
    assert_eq!(reply["data"]["turn_id"], json!("turn_1"));
    let sent = fake.frame();
    assert_eq!(sent["method"], json!("session/prompt"));
    assert_eq!(sent["params"]["sessionId"], json!(SIDE_FORK));
    assert_eq!(sent["params"]["prompt"], json!([{"type":"text","text":"try it"}]));
    // Another session is still not this attachment's.
    assert_code(
        &side(
            &mut client,
            surface,
            json!({"op":"prompt","session":"acp_unrelated","prompt_id":"p2","text":"x"}),
        ),
        "agent_session.bad_request",
    );
    fake.no_frame();

    let gone = side(&mut client, surface, json!({"op":"discard","session":SIDE_FORK}));
    assert_eq!(gone["ok"], json!(true), "{gone}");
    let kill = fake.frame();
    assert_eq!(kill["method"], json!("_acpmux/kill"));
    assert_eq!(kill["params"], json!({"sessionId":SIDE_FORK,"purge":true,"cancelFork":true}));
    // Discarded: no longer this attachment's to prompt or end.
    for frame in [
        json!({"op":"prompt","session":SIDE_FORK,"prompt_id":"p3","text":"x"}),
        json!({"op":"discard","session":SIDE_FORK}),
    ] {
        assert_code(&side(&mut client, surface, frame), "agent_session.bad_request");
    }
    fake.no_frame();
}

#[test]
fn the_owner_asks_a_side_question_about_the_attached_chat() {
    let (fake, mux, surface, mut client) = side_owner("side-btw", Fixture::default());
    let reply = side(&mut client, surface, json!({"op":"btw","text":"why this file?"}));
    assert_eq!(reply["ok"], json!(true), "{reply}");
    assert_eq!(reply["data"], json!({"sessionId":SIDE_BTW}));
    let ask = fake.frame();
    assert_eq!(ask["method"], json!("_acpmux/btw"));
    assert_eq!(ask["params"], json!({"sessionId":SESSION,"question":"why this file?"}));
    assert!(mux.control_clients.agent_sessions.sides.contains(SIDE_BTW));
}

#[test]
fn a_side_frame_names_no_folder_command_or_other_chat() {
    let (fake, mux, surface, mut client) = side_owner("side-shape", Fixture::default());
    for frame in [
        // One boundary: a completed turn or the chat as it is now.
        json!({"op":"open"}),
        json!({"op":"open","through_seq":0}),
        json!({"op":"open","through_seq":3,"live":true}),
        json!({"op":"open","live":true,"session":"acp_unrelated"}),
        json!({"op":"open","live":true,"text":"x"}),
        // Nothing a fork could run or land elsewhere.
        json!({"op":"open","live":true,"cwd":"/etc"}),
        json!({"op":"open","live":true,"name":"x"}),
        json!({"op":"open","live":true,"command":"sh"}),
        json!({"op":"open","live":true,"chat":"acp_unrelated"}),
        json!({"op":"open","live":true,"tags":{"side":"acp_unrelated"}}),
        json!({"op":"btw"}),
        json!({"op":"btw","text":"  "}),
        json!({"op":"btw","text":"why?","session":"acp_unrelated"}),
        json!({"op":"btw","text":"why?","model":"opus"}),
        json!({"op":"prompt","session":SIDE_FORK,"text":"x"}),
        json!({"op":"prompt","session":SIDE_FORK,"prompt_id":"p","text":"x",
               "content":[{"type":"resource_link","uri":"file:///etc/passwd"}]}),
        json!({"op":"discard"}),
        json!({"op":"discard","session":SIDE_FORK,"text":"x"}),
        json!({"op":"tag","session":"acp_unrelated"}),
        json!({"op":"attach","session":SIDE_FORK}),
        json!({}),
    ] {
        let reply = side(&mut client, surface, frame.clone());
        assert_eq!(reply["error_code"], json!("agent_session.bad_request"), "{frame}: {reply}");
    }
    fake.no_frame();
    assert!(!mux.control_clients.agent_sessions.sides.contains(SIDE_FORK));
}

/// acpmux tags only a fork of the chat (`side.not_fork`): a fork whose tag is refused is ended,
/// so no untagged copy stays, and it is not this attachment's afterwards.
#[test]
fn a_fork_whose_tag_is_refused_is_discarded() {
    let fixture = Fixture { side_refused: true, ..Fixture::default() };
    let (fake, _mux, surface, mut client) = side_owner("side-refused", fixture);
    assert_code(
        &side(&mut client, surface, json!({"op":"open","live":true})),
        "agent_session.refused",
    );
    assert_eq!(fake.frame()["method"], json!("acp.session.fork"));
    assert_eq!(fake.frame()["method"], json!("_acpmux/side"));
    let kill = fake.frame();
    assert_eq!(kill["method"], json!("_acpmux/kill"));
    assert_eq!(kill["params"], json!({"sessionId":SIDE_FORK,"purge":true,"cancelFork":true}));
    assert_code(
        &side(
            &mut client,
            surface,
            json!({"op":"prompt","session":SIDE_FORK,"prompt_id":"p1","text":"x"}),
        ),
        "agent_session.bad_request",
    );
}

#[test]
fn a_side_chat_needs_the_owners_own_writable_attachment() {
    let fake = FakeAcpmux::start("side-unattached");
    let mux = mux_with(&fake, "side-unattached");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "side-unattached");
    for frame in [
        json!({"op":"open","live":true}),
        json!({"op":"btw","text":"why?"}),
        json!({"op":"prompt","session":SIDE_FORK,"prompt_id":"p","text":"x"}),
        json!({"op":"discard","session":SIDE_FORK}),
    ] {
        assert_code(&side(&mut client, surface, frame), "agent_session.not_attached");
    }
    // An observer reads; it opens no side chat.
    let watching = observe(&mut client, surface);
    assert_eq!(watching["ok"], json!(true), "{watching}");
    while fake.next_frame(Duration::from_millis(200)).is_some() {}
    for frame in [
        json!({"op":"open","live":true}),
        json!({"op":"btw","text":"why?"}),
        json!({"op":"prompt","session":SIDE_FORK,"prompt_id":"p","text":"x"}),
        json!({"op":"discard","session":SIDE_FORK}),
    ] {
        assert_code(&side(&mut client, surface, frame), "agent_session.read_only");
    }
    fake.no_frame();
}
