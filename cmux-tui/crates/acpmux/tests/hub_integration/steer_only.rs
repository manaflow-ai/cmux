//! `_meta.acpmux.steerOnly`: a client that steers (the Chief delivering a
//! message between tool calls) gets a refusal, never a queued prompt, when
//! the session cannot steer now: no turn runs, or its agent does not steer
//! (the fake agent advertises no steering).
//!
//! Also the queue's steering ops (`hub/queue_edit.rs`): `_acpmux/queue_edit`
//! moves, edits, sends a queued prompt now or stops the turn for it (`interrupt`), and a steer with
//! `_meta.acpmux.interrupt` stops a turn its agent cannot steer and runs next.

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

fn text_prompt(id: &str, prompt_id: &str, text: &str) -> Value {
    json!({"sessionId": id, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": {"promptId": prompt_id}}})
}

/// A session whose agent runs "until-cancel" now, with `queued` prompts waiting behind it.
async fn busy_with_queue(c: &mut TestClient, queued: &[(&str, &str)]) -> String {
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.send(method::SESSION_PROMPT, text_prompt(&id, "p-turn", "until-cancel")).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "running").await;
    for (prompt_id, text) in queued {
        c.send(method::SESSION_PROMPT, text_prompt(&id, prompt_id, text)).await;
        c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| {
            p["promptId"] == *prompt_id && p["queued"] == true
        })
        .await;
    }
    id
}

/// The order the agent answered queued prompts in ("echo: <text>" chunks), up to `last`.
async fn echoes_until(c: &mut TestClient, last: &str) -> Vec<String> {
    let seen = c
        .collect_until(|m, p| m == method::SESSION_UPDATE && p["update"]["content"]["text"] == last)
        .await;
    seen.iter()
        .filter(|(m, _)| m == method::SESSION_UPDATE)
        .filter_map(|(_, p)| p["update"]["content"]["text"].as_str())
        .filter(|t| t.starts_with("echo: "))
        .map(str::to_owned)
        .collect()
}

async fn queue_order(c: &mut TestClient, id: &str) -> Vec<String> {
    let attached =
        c.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await.unwrap();
    attached["session"]["queue"]
        .as_array()
        .unwrap()
        .iter()
        .map(|q| q["promptId"].as_str().unwrap().to_owned())
        .collect()
}

#[tokio::test]
async fn queue_ops_move_and_rewrite_queued_prompts_before_their_turn() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = busy_with_queue(&mut c, &[("p-a", "a"), ("p-b", "b"), ("p-c", "c")]).await;
    let moved = c
        .request(
            "_acpmux/queue_edit",
            json!({"sessionId": id, "promptId": "p-c", "op": "move", "index": 0}),
        )
        .await
        .unwrap();
    assert_eq!(moved["ok"], true, "{moved}");
    let edited = c
        .request(
            "_acpmux/queue_edit",
            json!({"sessionId": id, "promptId": "p-b", "op": "update", "text": "b2"}),
        )
        .await
        .unwrap();
    assert_eq!(edited["ok"], true, "{edited}");
    assert_eq!(queue_order(&mut c, &id).await, ["p-c", "p-a", "p-b"]);

    c.send(method::SESSION_CANCEL, json!({"sessionId": id})).await;
    assert_eq!(echoes_until(&mut c, "echo: b2").await, ["echo: c", "echo: a", "echo: b2"]);
    let gone = c
        .request(
            "_acpmux/queue_edit",
            json!({"sessionId": id, "promptId": "p-a", "op": "move", "index": 0}),
        )
        .await
        .unwrap();
    assert_eq!(gone["ok"], false, "a prompt that ran no longer waits: {gone}");
}

/// Send now never stops a turn (`interrupt` does): to an agent that cannot steer, the prompt goes
/// next and runs once the turn ends. A send now that stopped the turn cut the running tool call
/// off as "rejected" (claude-sr2, 2026-10-20).
#[tokio::test]
async fn queue_ops_send_now_puts_next_and_never_stops_a_turn_its_agent_cannot_steer() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = busy_with_queue(&mut c, &[("p-a", "a"), ("p-b", "b")]).await;
    let attached =
        c.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await.unwrap();
    assert_eq!(attached["session"]["steering"], false, "{attached}");
    let sent = c
        .request(
            "_acpmux/queue_edit",
            json!({"sessionId": id, "promptId": "p-b", "op": "send_now"}),
        )
        .await
        .unwrap();
    assert_eq!(sent["sent"], "next", "{sent}");
    tokio::time::sleep(Duration::from_millis(300)).await;
    let attached =
        c.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await.unwrap();
    assert!(!attached["session"]["turn"].is_null(), "the turn still runs: {attached}");
    assert_eq!(queue_order(&mut c, &id).await, ["p-b", "p-a"]);
    c.send(method::SESSION_CANCEL, json!({"sessionId": id})).await;
    assert_eq!(echoes_until(&mut c, "echo: a").await, ["echo: b", "echo: a"]);
}

#[tokio::test]
async fn queue_ops_steer_with_interrupt_stops_a_turn_its_agent_cannot_steer() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = busy_with_queue(&mut c, &[("p-a", "a")]).await;
    let mut now = text_prompt(&id, "p-now", "now");
    now["_meta"]["acpmux"]["steer"] = json!(true);
    now["_meta"]["acpmux"]["interrupt"] = json!(true);
    c.send(method::SESSION_PROMPT, now).await;
    assert_eq!(echoes_until(&mut c, "echo: a").await, ["echo: now", "echo: a"]);
}

/// A steer without `interrupt` never stops a turn: to an agent that does not steer (or whose
/// steering is unknown, as after a daemon restart re-adopts it), it queues behind the running
/// turn.
#[tokio::test]
async fn a_steer_without_interrupt_queues_behind_a_turn_its_agent_cannot_steer() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = busy_with_queue(&mut c, &[]).await;
    let mut message = text_prompt(&id, "p-msg", "msg");
    message["_meta"]["acpmux"]["steer"] = json!(true);
    c.send(method::SESSION_PROMPT, message).await;
    let accepted = c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-msg").await;
    assert_eq!(accepted["queued"], true, "{accepted}");
    assert_ne!(accepted["steer"], true, "{accepted}");
    let attached =
        c.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await.unwrap();
    assert_eq!(attached["session"]["steering"], false, "{attached}");
    assert_eq!(attached["session"]["turn"]["promptId"], "p-turn", "the turn runs on: {attached}");
    assert_eq!(queue_order(&mut c, &id).await, ["p-msg"]);
    c.send(method::SESSION_CANCEL, json!({"sessionId": id})).await;
    assert_eq!(echoes_until(&mut c, "echo: msg").await, ["echo: msg"]);
}

#[tokio::test]
async fn queue_ops_send_now_steers_into_a_turn_its_agent_can_steer() {
    let env = BTreeMap::from([("FAKE_CODEX_STEER".to_owned(), "1".to_owned())]);
    let (hub, mut c) = setup_env(PermissionPolicy::ApproveAll, env).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.send(method::SESSION_PROMPT, text_prompt(&id, "p-turn", "work")).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "turn: work").await;
    // Its sender waits on its own connection for the answer.
    let mut a = connect(&hub).await;
    let pa = a.send(method::SESSION_PROMPT, text_prompt(&id, "p-a", "more")).await;
    a.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-a" && p["queued"] == true)
        .await;
    let attached =
        c.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await.unwrap();
    assert_eq!(attached["session"]["steering"], true, "{attached}");

    let sent = c
        .request(
            "_acpmux/queue_edit",
            json!({"sessionId": id, "promptId": "p-a", "op": "send_now"}),
        )
        .await
        .unwrap();
    assert_eq!(sent["sent"], "steer", "{sent}");
    // The running turn took it: one turn answered both prompts.
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "answered 2").await;
    assert!(queue_order(&mut c, &id).await.is_empty());
    // Its sender hears how it ran (a steer, under its own id), not that it was withdrawn.
    let (answer, _) = a.response(pa).await;
    let answer = answer.unwrap();
    assert_eq!(answer["_meta"]["acpmux"]["promptId"], "p-a", "{answer}");
    assert_eq!(answer["_meta"]["acpmux"]["steer"], true, "{answer}");
    assert_ne!(answer["_meta"]["acpmux"]["withdrawn"], true, "{answer}");
}

/// `interrupt`: the queued prompt goes next and the running turn stops, even when its agent could
/// take it as a steer; send now would have steered it in.
#[tokio::test]
async fn queue_ops_interrupt_stops_a_turn_its_agent_can_steer() {
    let env = BTreeMap::from([("FAKE_CLAUDE_STEER".to_owned(), "1".to_owned())]);
    let (_hub, mut c) = setup_env(PermissionPolicy::ApproveAll, env).await;
    let id = busy_with_queue(&mut c, &[("p-a", "a"), ("p-b", "b")]).await;
    let attached =
        c.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await.unwrap();
    assert_eq!(attached["session"]["steering"], true, "{attached}");
    let sent = c
        .request(
            "_acpmux/queue_edit",
            json!({"sessionId": id, "promptId": "p-b", "op": "interrupt"}),
        )
        .await
        .unwrap();
    assert_eq!(sent["ok"], true, "{sent}");
    assert_eq!(sent["sent"], "interrupt", "{sent}");
    assert_eq!(echoes_until(&mut c, "echo: a").await, ["echo: b", "echo: a"]);
}

/// A turn that fails stops its queue: the prompts behind it were written for a turn that went
/// well. They wait, in order, until a client resumes the queue; prompts sent meanwhile run first.
#[tokio::test]
async fn queue_ops_a_failed_turn_pauses_the_queue_until_resumed() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = busy_with_queue(&mut c, &[("p-f", "fail-streamed: boom"), ("p-a", "a"), ("p-b", "b")])
        .await;
    // A stopped turn is no failure: the queue goes on to "boom".
    c.send(method::SESSION_CANCEL, json!({"sessionId": id})).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "boom").await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        let attached =
            c.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await.unwrap();
        if attached["session"]["turn"].is_null() {
            break;
        }
        assert!(tokio::time::Instant::now() < deadline, "the failed turn never ended: {attached}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    // Settled: the failed turn ended, and nothing behind it started.
    tokio::time::sleep(Duration::from_millis(300)).await;
    let attached =
        c.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await.unwrap();
    assert_eq!(attached["session"]["queuePaused"], true, "{attached}");
    assert_eq!(queue_order(&mut c, &id).await, ["p-a", "p-b"]);

    // Sent after the failure: each runs, the second behind the first, ahead of the held ones.
    c.send(method::SESSION_PROMPT, text_prompt(&id, "p-c", "slow")).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "tick0 ").await;
    c.send(method::SESSION_PROMPT, text_prompt(&id, "p-d", "d")).await;
    assert_eq!(echoes_until(&mut c, "echo: d").await, ["echo: d"]);
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(queue_order(&mut c, &id).await, ["p-a", "p-b"], "the held prompts still wait");

    let resumed = c
        .request("_acpmux/queue_edit", json!({"sessionId": id, "promptId": "p-a", "op": "resume"}))
        .await
        .unwrap();
    assert_eq!(resumed["ok"], true, "{resumed}");
    assert_eq!(echoes_until(&mut c, "echo: b").await, ["echo: a", "echo: b"]);
    let attached =
        c.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await.unwrap();
    assert_eq!(attached["session"]["queuePaused"], false, "{attached}");
}
