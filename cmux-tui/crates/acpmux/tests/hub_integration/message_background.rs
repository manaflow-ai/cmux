//! The person's message does not wait behind a long foreground call (`hub/auto_background.rs`):
//! Claude Code reads a steer only when its step ends, so while the person's steer waits, a Bash
//! or Agent call of the chat's own turn that has run past the threshold goes to the background
//! (`background_tasks` for that call), the agent reads the message at once, and the call's own
//! result still comes when it ends. fake_claude.py's "fg-work KIND MS" is one such call.

use super::*;

/// The threshold these tests set (`Hub::set_message_background_after`).
const AFTER: Duration = Duration::from_millis(800);

/// Well under the call's own run: the reply came while it still ran.
const PROMPTLY: Duration = Duration::from_secs(3);

/// A Claude hub (fake_claude.py) with `after` as the threshold.
async fn hub_with(after: Duration) -> (Arc<Hub>, TestClient, std::path::PathBuf) {
    let root = std::env::temp_dir().join(format!("acpmux-msg-bg-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, _setup) = claude_setup(&claude, &[]).await;
    hub.set_message_background_after(Some(after));
    // The person's message is the person's only by a proof (`server/requests.rs`
    // `person_admitted`): the app's connection, which proved the key; a unix client that proves
    // nothing sends an unverified one, which moves nothing.
    hold_person_key(&hub);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut c = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    c.become_person().await;
    (hub, c, root)
}

/// A new chat whose turn runs "fg-work KIND MS"; returns it and the turn's request id once the
/// call is on screen.
async fn fg_work(c: &mut TestClient, kind: &str, ms: u64) -> (String, i64) {
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let said = format!("fg-work {kind} {ms}");
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": said}]});
    let turn = c.send(method::SESSION_PROMPT, prompt).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["toolCallId"] == "toolu_work").await;
    (id, turn)
}

/// A steer of `text` into the chat's running turn, the person's unless `agent` names a sender.
fn steer(id: &str, prompt_id: &str, text: &str, agent: Option<&str>) -> Value {
    let mut meta = json!({"promptId": prompt_id, "steer": true});
    if let Some(agent) = agent {
        meta["fromAgent"] = json!(agent);
    }
    json!({"sessionId": id, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": meta}})
}

/// The `background_tasks` requests acpmux wrote to Claude Code's stdin.
fn background_asks(hub: &Arc<Hub>, id: &str) -> Vec<Value> {
    hub.events(id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "claude.stdin")
        .filter(|e| e.msg.pointer("/request/subtype") == Some(&json!("background_tasks")))
        .map(|e| e.msg["request"].clone())
        .collect()
}

/// How long until the agent's reply to `text` shows on `c`.
async fn reply_after(c: &mut TestClient, text: &str) -> Duration {
    let sent = std::time::Instant::now();
    let read = format!("read: {text}");
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == read).await;
    sent.elapsed()
}

/// The chat's process for the call, from `_acpmux/process/list`.
async fn work_process(c: &mut TestClient, id: &str) -> Value {
    let r = c.request("_acpmux/process/list", json!({"sessionId": id})).await.unwrap();
    let list = r["processes"].as_array().cloned().unwrap_or_default();
    list.into_iter().find(|p| p["toolCallId"] == "toolu_work").unwrap_or(Value::Null)
}

/// A shell past the threshold when the person writes: it goes to the background, the reply comes
/// within seconds while it runs on, and its end still comes, listed as moved by acpmux.
#[tokio::test]
async fn the_persons_message_moves_a_long_foreground_shell_and_is_answered_at_once() {
    let (hub, mut c, root) = hub_with(AFTER).await;
    let (id, turn) = fg_work(&mut c, "bash", 8000).await;
    tokio::time::sleep(AFTER + Duration::from_millis(200)).await;
    c.send(method::SESSION_PROMPT, steer(&id, "p-ping", "PING", None)).await;
    let took = reply_after(&mut c, "PING").await;
    assert!(took < PROMPTLY, "the reply waited {took:?} for the shell");
    let running = work_process(&mut c, &id).await;
    assert_eq!(running["state"], "running", "{running}");
    assert_eq!(running["origin"], "auto_backgrounded", "{running}");
    assert_eq!(
        background_asks(&hub, &id),
        vec![json!({"subtype": "background_tasks", "tool_use_id": "toolu_work"})]
    );
    let (answer, _) = c.response(turn).await;
    assert_eq!(answer.unwrap()["stopReason"], "end_turn");
    assert_eq!(work_process(&mut c, &id).await["state"], "exited");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// A message sent while a foreground subagent is still under the threshold waits only until the
/// subagent reaches it: then the subagent goes to the background and the message is read; the
/// subagent's own end still comes.
#[tokio::test]
async fn a_message_before_the_threshold_moves_a_foreground_subagent_when_it_reaches_it() {
    let (hub, mut c, root) = hub_with(AFTER).await;
    let (id, turn) = fg_work(&mut c, "agent", 8000).await;
    c.send(method::SESSION_PROMPT, steer(&id, "p-pong", "PONG", None)).await;
    let took = reply_after(&mut c, "PONG").await;
    assert!(took < PROMPTLY, "the reply waited {took:?} for the subagent");
    assert_eq!(
        background_asks(&hub, &id),
        vec![json!({"subtype": "background_tasks", "tool_use_id": "toolu_work"})]
    );
    let (answer, seen) = c.response(turn).await;
    assert_eq!(answer.unwrap()["stopReason"], "end_turn");
    assert!(
        seen.iter().any(|(m, p)| m == method::SESSION_UPDATE
            && p["update"]["sessionUpdate"] == "subagent_state_update"
            && p["update"]["state"] == "completed"),
        "the subagent's end never came: {seen:?}"
    );
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// A call that ends before the threshold is never moved: the message is read after it, as before.
#[tokio::test]
async fn a_call_shorter_than_the_threshold_is_not_moved() {
    let (hub, mut c, root) = hub_with(Duration::from_secs(4)).await;
    let (id, turn) = fg_work(&mut c, "bash", 1000).await;
    c.send(method::SESSION_PROMPT, steer(&id, "p-short", "SHORT", None)).await;
    reply_after(&mut c, "SHORT").await;
    let (answer, _) = c.response(turn).await;
    assert_eq!(answer.unwrap()["stopReason"], "end_turn");
    assert_eq!(background_asks(&hub, &id), Vec::<Value>::new());
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// With no tool call running, a message moves nothing: one into a step without a call waits for
/// the step as before, and one with no turn running starts a turn.
#[tokio::test]
async fn a_message_with_no_call_running_moves_nothing() {
    let (hub, mut c, root) = hub_with(AFTER).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    let step = json!({"sessionId": id, "prompt": [{"type": "text", "text": "long-step"}]});
    let turn = c.send(method::SESSION_PROMPT, step).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "stepping").await;
    c.send(method::SESSION_PROMPT, steer(&id, "p-idle", "IDLE", None)).await;
    tokio::time::sleep(AFTER * 2).await;
    assert_eq!(background_asks(&hub, &id), Vec::<Value>::new());
    c.tx.send(Message::notification(method::SESSION_CANCEL, json!({"sessionId": id})).to_line())
        .await
        .unwrap();
    let _ = c.response(turn).await;
    assert_eq!(background_asks(&hub, &id), Vec::<Value>::new());
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// Another agent's message moves nothing: it waits for the call, as before.
#[tokio::test]
async fn an_agents_message_does_not_move_the_call() {
    let (hub, mut c, root) = hub_with(AFTER).await;
    let (id, turn) = fg_work(&mut c, "bash", 3000).await;
    tokio::time::sleep(AFTER + Duration::from_millis(200)).await;
    let mut lane = connect(&hub).await;
    lane.send(method::SESSION_PROMPT, steer(&id, "p-lane", "FROM LANE", Some("lane-a"))).await;
    tokio::time::sleep(AFTER * 2).await;
    assert_eq!(background_asks(&hub, &id), Vec::<Value>::new());
    let (answer, _) = c.response(turn).await;
    assert_eq!(answer.unwrap()["stopReason"], "end_turn");
    assert_eq!(background_asks(&hub, &id), Vec::<Value>::new());
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}
