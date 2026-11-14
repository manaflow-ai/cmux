use super::*;

#[test]
fn an_agent_message_names_its_sender_class_and_thread() {
    let provenance = json!({"kind": "agent_message", "threadId": "t1"});
    let params = prompt_params("s", json!([]), Some("lane-a"), Some("question"), Some(&provenance));
    assert_eq!(
        params["_meta"]["acpmux"]["sender"],
        json!({"name": "lane-a", "class": "question", "threadId": "t1"})
    );
    assert_eq!(params["sessionId"], "s");
}

#[test]
fn a_steer_keeps_its_own_meta_and_names_its_sender() {
    let mut params = json!({"sessionId": "s", "prompt": [], "_meta": {"steer": true}});
    add_sender(&mut params, Some("lane-a"), None, None);
    assert_eq!(params["_meta"], json!({"steer": true, "acpmux": {"sender": {"name": "lane-a"}}}));
}

#[test]
fn a_chiefs_message_names_its_chief() {
    // A Chief's turn session sent it (`prompt_provenance::stamp_chief`):
    // the relay of another Chief (`cmux chief acp`) routes its reply
    // back into that Chief's chat by this id.
    let provenance = json!({"kind": "session_message", "from": "s-turn",
            "fromName": "Codex Chief", "fromChief": "agent_codex", "threadId": "t2"});
    let params =
        prompt_params("s", json!([]), Some("Codex Chief"), Some("question"), Some(&provenance));
    assert_eq!(
        params["_meta"]["acpmux"]["sender"],
        json!({"name": "Codex Chief", "sessionId": "s-turn", "class": "question", "threadId": "t2",
                   "chief": "agent_codex"})
    );
}

#[test]
fn the_agent_learns_who_the_daemon_knows_sent_it_apart_from_its_name() {
    let session = crate::prompt_provenance::session_message("s-a", "lane-a", "s-b");
    let session = crate::prompt_provenance::observed(session, "unix");
    let params = prompt_params("s", json!([]), Some("lane-a"), None, Some(&session));
    assert_eq!(
        params["_meta"]["acpmux"]["sender"],
        json!({"name": "lane-a", "verified": true, "transport": "unix", "sessionId": "s-a"})
    );
    let named = crate::prompt_provenance::observed(
        crate::prompt_provenance::named_sender("codex@box", "s-b"),
        "unix",
    );
    let params = prompt_params("s", json!([]), Some("codex@box"), None, Some(&named));
    assert_eq!(params["_meta"]["acpmux"]["sender"]["verified"], false);
    // A prompt no proof attributes says so, with no name: never the owner's.
    let unknown = crate::prompt_provenance::unverified("s-b", "unix", Map::new());
    let params = prompt_params("s", json!([]), None, None, Some(&unknown));
    assert_eq!(
        params["_meta"]["acpmux"]["sender"],
        json!({"verified": false, "transport": "unix"})
    );
    // The program the daemon saw send it goes along (`sender_program.rs`).
    let mut seen = unknown.clone();
    seen["program"] = json!({"name": "next-autoland"});
    let params = prompt_params("s", json!([]), None, None, Some(&seen));
    assert_eq!(params["_meta"]["acpmux"]["sender"]["program"], json!({"name": "next-autoland"}));
}

#[test]
fn an_edited_agent_message_still_names_its_sender_to_the_agent() {
    let provenance = json!({
        "kind": "agent_message",
        "from": "lane-a",
        "editedBy": {"actor": "owner"},
    });
    let params = prompt_params("s", json!([]), None, None, Some(&provenance));
    assert_eq!(
        params["_meta"]["acpmux"]["sender"],
        json!({"name": "lane-a", "editedBy": {"actor": "owner"}})
    );
}

#[test]
fn a_fan_in_turn_routes_its_sender_by_its_heads_chief_and_thread() {
    // A fan-in turn marks its blocks by its digest (`turns.rs`), but a relay
    // (`cmux chief acp`) still routes the reply by the head message's Chief and thread.
    let head = json!({"kind": "session_message", "from": "s-turn",
            "fromName": "Codex Chief", "fromChief": "agent_codex", "threadId": "t2"});
    let digest = json!({"kind": "agent_digest", "messages": [head.clone()]});
    let params = turn_params(
        "s",
        json!([{"type": "text", "text": "hi"}]),
        Some("Codex Chief"),
        Some("question"),
        Some(&head),
        Some(&digest),
    );
    let sender = &params["_meta"]["acpmux"]["sender"];
    assert_eq!(sender["chief"], "agent_codex");
    assert_eq!(sender["threadId"], "t2");
    assert_eq!(sender["sessionId"], "s-turn");
}

#[test]
fn a_persons_prompt_names_no_sender() {
    let params = prompt_params("s", json!([{"type": "text", "text": "hi"}]), None, None, None);
    assert_eq!(params, json!({"sessionId": "s", "prompt": [{"type": "text", "text": "hi"}]}));
}
