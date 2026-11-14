use super::*;

#[test]
fn an_acpmux_agents_prompt_names_its_sender_and_a_persons_none() {
    let params = json!({"sessionId": "s", "prompt": [],
            "_meta": {"acpmux": {"sender": {"name": "lane-a", "class": "question", "threadId": "t1"}}}});
    let sender = prompt_sender(&params).expect("sender");
    assert_eq!(sender, AgentSender::new("lane-a", Some("question"), Some("t1")).unwrap());
    assert_eq!(prompt_sender(&json!({"sessionId": "s", "prompt": []})), None);
}

#[test]
fn a_prompt_acpmux_could_not_attribute_is_never_the_owners() {
    let params = json!({"sessionId": "s", "prompt": [],
            "_meta": {"acpmux": {"sender": {"verified": false, "transport": "unix"}}}});
    let sender = prompt_sender(&params).expect("an unverified sender, not the owner");
    assert_eq!(sender.name, UNVERIFIED_SENDER);
    assert_eq!(sender.shown(), messages().unverified_sender);
    assert_eq!(reply_route(&sender, None, "agent_mux", "Chief"), None);
    // The program acpmux saw send it names it, still as an unverified sender.
    let params = json!({"sessionId": "s", "prompt": [],
            "_meta": {"acpmux": {"sender": {"verified": false, "transport": "unix",
                "program": {"name": "next-autoland"}}}}});
    let sender = prompt_sender(&params).expect("an unverified sender");
    assert_eq!(sender.name, UNVERIFIED_SENDER);
    assert_eq!(sender.shown(), format!("next-autoland ({})", messages().unverified_sender));
}

#[test]
fn a_forwarded_prompt_keeps_its_sender_and_names_the_peer_beside_it() {
    let params = json!({"sessionId": "s", "prompt": [],
            "_meta": {"acpmux": {"sender": {"name": "lane-a", "verified": false,
                "transport": "peer", "forwardedBy": {"actor": "peer"}}}}});
    let sender = prompt_sender(&params).expect("sender");
    assert_eq!(sender.name, "lane-a");
    assert_eq!(sender.shown(), "lane-a › via peer");
}

#[test]
fn another_chiefs_prompt_is_labelled_chief_and_its_reply_goes_back_to_it() {
    // Chief-to-Chief on this Mac: Codex Chief's turn `acpmux_send`s to
    // this Chief's stable session; acpmux names the sending Chief.
    let params = json!({"sessionId": "s", "prompt": [],
            "_meta": {"acpmux": {"sender": {"name": "Codex Chief", "class": "question",
                                            "threadId": "t2", "chief": "agent_codex"}}}});
    let sender = prompt_sender(&params).expect("sender");
    assert_eq!(sender.name, "chief:codex-chief");
    assert_eq!(sender_chief(&params).as_deref(), Some("agent_codex"));
    let (to, back) = reply_route(&sender, Some("agent_codex"), "agent_mux", "Chief")
        .expect("a question from a Chief gets its reply back");
    assert_eq!(to, "agent_codex");
    assert_eq!(back, AgentSender::new("chief:chief", Some("result"), Some("t2")).unwrap());
    // A reply is never answered again (no ping-pong), a Chief never
    // routes to itself, and a lane's message has no Chief to go back to.
    let result = AgentSender::new("chief:codex-chief", Some("result"), None).unwrap();
    assert_eq!(reply_route(&result, Some("agent_codex"), "agent_mux", "Chief"), None);
    let fyi = AgentSender::new("chief:codex-chief", Some("fyi"), None).unwrap();
    assert_eq!(reply_route(&fyi, Some("agent_codex"), "agent_mux", "Chief"), None);
    assert_eq!(reply_route(&sender, Some("agent_mux"), "agent_mux", "Chief"), None);
    let lane = AgentSender::new("lane-a", Some("question"), None).unwrap();
    assert_eq!(reply_route(&lane, None, "agent_mux", "Chief"), None);
    // A lane's name is kept as acpmux gave it.
    let lane_params = json!({"sessionId": "s", "prompt": [],
            "_meta": {"acpmux": {"sender": {"name": "lane-a"}}}});
    assert_eq!(prompt_sender(&lane_params).unwrap().name, "lane-a");
    assert_eq!(sender_chief(&lane_params), None);
}

#[test]
fn a_stable_chief_session_opens_that_chiefs_conversation() {
    let words = |w: &[&str]| w.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    assert_eq!(
        parse(&words(&["--chief", "agent_codex"])).unwrap().chief.as_deref(),
        Some("agent_codex")
    );
    let conv = |id: &str, at: &str, who: &str| json!({"id": id, "created_at": at, "participants": [{"id": "user_local"}, {"id": who}]});
    let chats = vec![
        conv("c-mux", "2026-01-01", "agent_mux"),
        conv("c-codex-new", "2026-03-01", "agent_codex"),
        conv("c-codex", "2026-02-01", "agent_codex"),
    ];
    assert_eq!(
        super::super::link::select_chief_of(&chats, "agent_codex").unwrap()["id"],
        "c-codex"
    );
    assert_eq!(super::super::link::select_chief_of(&chats, "agent_mux").unwrap()["id"], "c-mux");
    assert!(super::super::link::select_chief_of(&chats, "agent_other").is_none());
    // Another Chief answers in its DM with the person, never in a group
    // it is in (optchat-chief `daemon::select_chief_of`).
    let group = json!({"id": "c-group", "created_at": "2025-01-01", "participants": [
            {"id": "user_local"}, {"id": "agent_codex"}, {"id": "agent_mux"}]});
    let with_group = [vec![group], chats].concat();
    assert_eq!(
        super::super::link::select_chief_of(&with_group, "agent_codex").unwrap()["id"],
        "c-codex"
    );
}

#[test]
fn a_prompt_is_its_text_resources_and_links() {
    let prompt = json!([
        {"type": "text", "text": "look at"},
        {"type": "resource_link", "uri": "file:///a.md", "name": "a.md"},
        {"type": "resource", "resource": {"uri": "file:///b", "text": "body"}},
        {"type": "image", "data": "AAAA", "mimeType": "image/png"},
        {"type": "text", "text": "  "},
    ]);
    assert_eq!(prompt_text(Some(&prompt)), "look at\n\n[a.md](file:///a.md)\n\nbody");
    assert_eq!(prompt_text(None), "");
}

#[test]
fn options_take_a_home_a_timeout_and_wait_agents() {
    let words = |w: &[&str]| w.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    let parsed = parse(&words(&["--chief-home=/h", "--timeout", "0", "--wait-agents"])).unwrap();
    assert_eq!(parsed.chief_home.as_deref(), Some(std::path::Path::new("/h")));
    assert_eq!(parsed.timeout_secs, None);
    assert!(parsed.wait_agents);
    assert_eq!(parse(&[]).unwrap().timeout_secs, Some(DEFAULT_TIMEOUT_SECS));
    assert!(parse(&words(&["--bogus"])).is_err());
}
