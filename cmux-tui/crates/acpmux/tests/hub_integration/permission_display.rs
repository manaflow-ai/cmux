//! A person's approval card reads as a sentence, not a tool's raw name and
//! JSON (hub/permissions/display.rs). Leo 2026-10-21 (cmux #89(4)): "The
//! approval prompt from a paired device shows raw JSON ("mcp__optchat__tell
//! wants to run: {"id":"a12","message":…}"). Render it as a human card:
//! "Chief wants to message a12 · Nightly train", with a preview of the
//! message".

use super::*;

const TELL: &str = "mcp__optchat__tell";

/// A new session tagged `tags`; returns its id.
async fn tagged(c: &mut TestClient, name: &str, tags: Value) -> String {
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": name}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    if tags.as_object().is_some_and(|t| !t.is_empty()) {
        c.request(method::MUX_TAG, json!({"sessionId": id, "set": tags})).await.unwrap();
    }
    id
}

/// Prompts `id` with `prompt` and returns the request of the ask it raises.
async fn asked(c: &mut TestClient, id: &str, prompt: &str) -> Value {
    asked_pending(c, id, prompt).await["request"].clone()
}

/// Prompts `id` with `prompt` and returns the `_acpmux/permission_pending` of the ask it raises.
async fn asked_pending(c: &mut TestClient, id: &str, prompt: &str) -> Value {
    c.next += 1;
    let prompt_id = c.next;
    c.tx.send(
        Message::request(
            prompt_id,
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": prompt}]}),
        )
        .to_line(),
    )
    .await
    .unwrap();
    c.wait_for(method::MUX_PERMISSION_PENDING, |p| p["sessionId"] == id).await
}

/// The Chief (its turn session) and two homes' subagents that share the handle a12.
async fn chief_and_subagents(c: &mut TestClient) -> String {
    tagged(
        c,
        "sub-a12",
        json!({"mux.parent": "optchat-chief:h0me", "mux.handle": "a12", "mux.label": "Nightly train"}),
    )
    .await;
    tagged(
        c,
        "other-a12",
        json!({"mux.parent": "optchat-chief:0ther", "mux.handle": "a12", "mux.label": "Someone else's"}),
    )
    .await;
    tagged(c, "turn", json!({"mux.label": "Chief", "mux.children": "optchat-chief:h0me"})).await
}

#[tokio::test]
async fn permission_display_a_tell_reads_as_who_messages_whom() {
    let (_hub, mut c) = setup(PermissionPolicy::Ask).await;
    let turn = chief_and_subagents(&mut c).await;
    let request =
        asked(&mut c, &turn, &format!("tool-ask: {TELL} a12 Run the nightly, then report")).await;
    assert_eq!(
        request["toolCall"]["_meta"]["acpmux"]["display"],
        json!({
            "actor": "Chief",
            "action": "message",
            "target": "a12",
            "targetLabel": "Nightly train",
            "headline": "Chief wants to message a12 · Nightly train",
            "preview": "Run the nightly, then report",
        })
    );
    // The request itself is unchanged: its title and input are still there.
    assert_eq!(request["toolCall"]["title"], TELL);
    assert_eq!(request["toolCall"]["rawInput"]["id"], "a12");
}

#[tokio::test]
async fn permission_display_an_unknown_handle_has_no_name() {
    let (_hub, mut c) = setup(PermissionPolicy::Ask).await;
    let turn = chief_and_subagents(&mut c).await;
    let request = asked(&mut c, &turn, &format!("tool-ask: {TELL} a99 hi")).await;
    let display = &request["toolCall"]["_meta"]["acpmux"]["display"];
    assert_eq!(display["headline"], "Chief wants to message a99");
    assert!(display.get("targetLabel").is_none(), "{display}");
}

#[tokio::test]
async fn permission_display_an_untagged_asker_reads_by_its_name() {
    let (_hub, mut c) = setup(PermissionPolicy::Ask).await;
    chief_and_subagents(&mut c).await;
    let plain = tagged(&mut c, "helper", json!({})).await;
    let request = asked(&mut c, &plain, &format!("tool-ask: {TELL} a12 hi")).await;
    let display = &request["toolCall"]["_meta"]["acpmux"]["display"];
    // No `mux.children`: it reaches no one's a12 by name.
    assert_eq!(display["headline"], "helper wants to message a12");
    assert_eq!(display["actor"], "helper");
}

#[tokio::test]
async fn permission_display_a_long_message_previews_on_one_line() {
    let (_hub, mut c) = setup(PermissionPolicy::Ask).await;
    let turn = chief_and_subagents(&mut c).await;
    let long = "word ".repeat(100);
    let request = asked(&mut c, &turn, &format!("tool-ask: {TELL} a12 {long}")).await;
    let preview =
        request["toolCall"]["_meta"]["acpmux"]["display"]["preview"].as_str().unwrap().to_owned();
    assert!(preview.chars().count() <= 280, "{preview}");
    assert!(preview.ends_with('…'), "{preview}");
}

#[tokio::test]
async fn permission_display_other_tools_get_none() {
    let (_hub, mut c) = setup(PermissionPolicy::Ask).await;
    let turn = chief_and_subagents(&mut c).await;
    let request = asked(&mut c, &turn, "tool-ask: mcp__other__thing a12 hi").await;
    assert!(request["toolCall"]["_meta"]["acpmux"].get("display").is_none(), "{request}");
}

/// Review of #24337: a display line the agent wrote itself never reaches a
/// person. acpmux drops it from every request, and writes its own only for a
/// tool that reads as a sentence.
#[tokio::test]
async fn permission_display_an_agents_own_display_line_is_dropped() {
    let (_hub, mut c) = setup(PermissionPolicy::Ask).await;
    let turn = chief_and_subagents(&mut c).await;
    // Another tool, and a tell with no target: no display at all.
    let untargeted = format!("forged-ask: {TELL} - hi");
    for prompt in ["forged-ask: mcp__other__thing a12 rm -rf /", untargeted.as_str()] {
        let pending = asked_pending(&mut c, &turn, prompt).await;
        let request = &pending["request"];
        assert!(request["toolCall"]["_meta"]["acpmux"].get("display").is_none(), "{request}");
        let answer =
            json!({"sessionId": turn, "permissionId": pending["permissionId"], "optionId": "no"});
        c.request(method::MUX_PERMISSION_RESPOND, answer).await.unwrap();
    }
    // A tell: acpmux's own line, not the agent's.
    let request = asked(&mut c, &turn, &format!("forged-ask: {TELL} a12 hi")).await;
    let display = &request["toolCall"]["_meta"]["acpmux"]["display"];
    assert_eq!(display["headline"], "Chief wants to message a12 · Nightly train", "{display}");
    assert_eq!(display["preview"], "hi", "{display}");
}
