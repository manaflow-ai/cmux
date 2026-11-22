//! `_meta.acpmux.steerOnly`: a client that steers (the Chief delivering a
//! message between tool calls) gets a refusal, never a queued prompt, when
//! the session cannot steer now: no turn runs, or its agent does not steer
//! (the fake agent advertises no steering).

use super::*;

fn steer(id: &str, text: &str) -> Value {
    json!({"sessionId": id, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": {"steer": true, "steerOnly": true}}})
}

#[tokio::test]
async fn a_steer_only_prompt_is_refused_with_no_turn_running() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let refused = c.request(method::SESSION_PROMPT, steer(&id, "late")).await;
    assert!(refused.as_ref().is_err_and(|e| e.contains("steer.unavailable")), "{refused:?}");
}

#[tokio::test]
async fn a_steer_only_prompt_is_refused_by_an_agent_that_does_not_steer() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.next += 1;
    c.tx.send(
        Message::request(
            c.next,
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "slow"}]}),
        )
        .to_line(),
    )
    .await
    .unwrap();
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["sessionUpdate"] == "agent_message_chunk")
        .await;
    let refused = c.request(method::SESSION_PROMPT, steer(&id, "late")).await;
    assert!(refused.as_ref().is_err_and(|e| e.contains("steer.unavailable")), "{refused:?}");
}

/// E19 (2026-10-09): codex-acp folds a steered prompt into the running turn
/// and, at the turn's end, answers only the last prompt it got. The turn's
/// own prompt then never got an answer, and the Chief's turn waited forever
/// (three concurrent messages). acpmux answers every prompt of that turn.
#[tokio::test]
async fn a_codex_turn_that_took_a_steer_answers_its_own_prompt_too() {
    let env = BTreeMap::from([("FAKE_CODEX_STEER".to_owned(), "1".to_owned())]);
    let (_hub, mut c) = setup_env(PermissionPolicy::ApproveAll, env).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let turn = c
        .send(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "work"}]}),
        )
        .await;
    c.wait_for(method::SESSION_UPDATE, |p| {
        p["update"]["content"]["text"].as_str().is_some_and(|t| t.starts_with("turn: "))
    })
    .await;
    let first = c.send(method::SESSION_PROMPT, steer(&id, "more")).await;
    let second = c.send(method::SESSION_PROMPT, steer(&id, "and more")).await;
    let mut answered = BTreeMap::new();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while answered.len() < 3 {
        let line = tokio::time::timeout_at(deadline, c.rx.recv()).await.unwrap_or_else(|_| {
            panic!("prompts left unanswered: answered only {:?}", answered.keys())
        });
        let line = line.expect("connection closed");
        if let Message::Response { id: rid, result, error } = Message::parse(&line).unwrap()
            && let Some(rid) = rid.as_i64()
        {
            answered.insert(rid, (result, error));
        }
    }
    for rid in [turn, first, second] {
        let (result, error) = &answered[&rid];
        assert!(error.is_none(), "prompt {rid}: {error:?}");
        let reason = result.as_ref().and_then(|r| r.get("stopReason")).cloned();
        assert_eq!(reason, Some(json!("end_turn")), "prompt {rid}: {result:?}");
    }
}
