//! A fork of a chat whose turn runs (the person's "fork it now", cmux-next
//! Fork Conversation while the chat works): the fork is the chat as it is
//! now, idle, its running turn cut off there (the tool still running shown
//! cancelled in the fork only), and the chat's own turn goes on untouched.

use super::*;

fn prompt(id: &str, text: &str) -> Value {
    json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]})
}

async fn until(what: &str, mut ok: impl FnMut() -> bool) {
    for _ in 0..500 {
        if ok() {
            return;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    panic!("timed out waiting for {what}");
}

fn kinds(hub: &Arc<Hub>, id: &str, kind: &str) -> Vec<Value> {
    hub.events(id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == kind)
        .map(|e| e.msg)
        .collect()
}

fn text_of(hub: &Arc<Hub>, id: &str) -> String {
    kinds(hub, id, "agent_message_chunk")
        .iter()
        .filter_map(|m| m.pointer("/params/update/content/text").and_then(Value::as_str))
        .collect()
}

/// The fork's copy of the chat: its finished turn, the running turn's prompt
/// and partial reply, the running tool call settled as failed, and the turn
/// ended as cancelled, so the fork is idle and its next prompt is a new turn.
fn assert_cut_off_copy(hub: &Arc<Hub>, fid: &str) {
    let prompts: Vec<String> = kinds(hub, fid, "user_message")
        .iter()
        .filter_map(|m| m["text"].as_str().map(str::to_owned))
        .collect();
    assert_eq!(prompts.len(), 2, "{prompts:?}");
    assert_eq!(prompts[0], "first");
    assert!(prompts[1].starts_with("tool-hold: "), "{prompts:?}");
    assert!(text_of(hub, fid).contains("partial words"), "the partial reply is copied");
    let updates = kinds(hub, fid, "tool_call_update");
    assert!(
        updates.iter().any(|u| u["params"]["update"]["status"] == "failed"),
        "the running tool call is settled in the fork: {updates:?}"
    );
    let results = kinds(hub, fid, "turn_result");
    let last = results.last().expect("the running turn ends in the fork");
    assert_eq!(last["status"], "cancelled", "{results:?}");
    assert_eq!(results.len(), 2, "one finished turn and the cut-off one: {results:?}");
}

/// A Claude chat forks while a tool call of its turn runs, twice in a row.
/// Each fork is its own idle conversation holding the chat's prompts with no
/// tool call left without a result (Claude's API would refuse the fork's
/// first prompt). The chat's turn is not touched: its tool finishes, its
/// turn completes and its conversation holds that tool's result.
#[tokio::test]
async fn a_claude_chat_forks_while_its_tool_call_runs_and_its_turn_goes_on() {
    let root = std::env::temp_dir().join(format!("acpmux-fork-busy-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "busy"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(method::SESSION_PROMPT, prompt(&id, "first")).await.unwrap();
    let gate = root.join("gate");
    c.send(method::SESSION_PROMPT, prompt(&id, &format!("tool-hold: {}", gate.display()))).await;
    until("the running tool call", || !kinds(&hub, &id, "tool_call").is_empty()).await;

    // Twice in a row, by both ways in: plain session/fork (the CLI) and the pane's
    // acp.session.fork with `live` (Fork Conversation).
    let f1 = c.request(method::SESSION_FORK, json!({"sessionId": id, "cwd": cwd()})).await;
    let f1 = f1.unwrap_or_else(|e| panic!("a working chat forks now: {e}"));
    let f2 = c.request(FORK_OP, json!({"sessionId": id, "live": true})).await;
    let f2 = f2.unwrap_or_else(|e| panic!("a working chat forks now again: {e}"));
    let (fid1, fid2) = (
        f1["sessionId"].as_str().unwrap().to_owned(),
        f2["sessionId"].as_str().unwrap().to_owned(),
    );
    assert_ne!(fid1, fid2);
    for fid in [&fid1, &fid2] {
        let status = hub.resolve(fid).unwrap().meta().status;
        assert!(
            matches!(
                status,
                acpmux::store::SessionStatus::Idle | acpmux::store::SessionStatus::Ready
            ),
            "the fork is idle at once: {status:?}"
        );
        assert_cut_off_copy(&hub, fid);
    }
    let chat = hub.resolve(&id).unwrap().meta().status;
    assert!(
        matches!(chat, acpmux::store::SessionStatus::Running),
        "the chat still works its turn: {chat:?}"
    );

    let h1 = claude_history(&hub, &mut c, &fid1).await;
    let h2 = claude_history(&hub, &mut c, &fid2).await;
    for h in [&h1, &h2] {
        assert_eq!(h["prompts"][0], "first", "{h}");
        assert!(h["prompts"][1].as_str().is_some_and(|p| p.starts_with("tool-hold: ")), "{h}");
        assert_eq!(h["unresolved"], json!([]), "no tool call without a result: {h}");
        assert_eq!(h["sessions"].as_array().map(Vec::len), Some(1), "{h}");
    }
    assert_ne!(h1["sessions"], h2["sessions"], "each fork is its own conversation");

    // The chat's own turn goes on and completes as it would have.
    std::fs::write(&gate, "").unwrap();
    until("the chat's turn to end", || kinds(&hub, &id, "turn_result").len() == 2).await;
    let results = kinds(&hub, &id, "turn_result");
    assert_eq!(results[1]["status"], "completed", "{results:?}");
    assert!(
        !kinds(&hub, &id, "tool_call_update")
            .iter()
            .any(|u| u["params"]["update"]["status"] == "failed"),
        "the fork's cancel never reaches the chat"
    );
    let source = claude_history(&hub, &mut c, &id).await;
    assert_eq!(source["unresolved"], json!([]), "{source}");
    assert_ne!(source["sessions"], h1["sessions"]);
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}
