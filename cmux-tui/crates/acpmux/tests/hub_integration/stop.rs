//! Stop (`hub/cancel.rs`): `session/cancel` is answered even as a request,
//! and it always ends the turn, even when the agent never answers it.

use super::*;

/// Stop always ends the turn: an agent that never answers the cancel (Claude
/// Code idle after a local slash command, cosmic-gray 2026-10-14) left the chat
/// running, its queue stuck behind it. acpmux ends the turn itself and says so.
#[tokio::test]
async fn a_cancel_the_agent_never_answers_still_ends_the_turn() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.next += 1;
    c.tx.send(
        Message::request(
            c.next,
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "deaf-to-cancel"}]}),
        )
        .to_line(),
    )
    .await
    .unwrap();
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["sessionUpdate"] == "agent_message_chunk")
        .await;
    let stopped = std::time::Instant::now();
    c.tx.send(Message::notification(method::SESSION_CANCEL, json!({"sessionId": id})).to_line())
        .await
        .unwrap();
    let done = tokio::time::timeout(
        Duration::from_secs(15),
        c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_end"),
    )
    .await
    .expect("the turn stayed open after Stop");
    assert_eq!(done["msg"]["stopReason"], "cancelled", "{done}");
    assert!(stopped.elapsed() < Duration::from_secs(15));
    let result = c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_result").await;
    assert_eq!(result["msg"]["cancelForced"], true, "{result}");
}

#[tokio::test]
async fn session_cancel_as_a_request_is_answered() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "cancel-req").await;
    let rid = c.send(method::SESSION_PROMPT, prompt(&id, "slow", None)).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["sessionUpdate"] == "agent_message_chunk")
        .await;
    let cancel = c.send(method::SESSION_CANCEL, json!({"sessionId": id})).await;
    let (r, _) = c.response(cancel).await;
    assert_eq!(r.unwrap(), json!({}));
    let r = c.response(rid).await.0.unwrap();
    assert_eq!(r["stopReason"], "cancelled");
    // With no turn running it still answers.
    assert_eq!(
        c.request(method::SESSION_CANCEL, json!({"sessionId": id})).await.unwrap(),
        json!({})
    );
}

/// A hub whose one profile is Claude Code (`fake_claude.py`).
async fn claude_setup() -> (Arc<Hub>, TestClient) {
    claude_setup_env(BTreeMap::new()).await
}

/// `claude_setup` with the fake's env (FAKE_CLAUDE_* switches).
pub(super) async fn claude_setup_env(env: BTreeMap<String, String>) -> (Arc<Hub>, TestClient) {
    let fake_claude = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
    let profile = HarnessProfile {
        kind: acpmux::config::HarnessKind::ClaudeStdio,
        argv: vec!["python3".into(), fake_claude.into()],
        env,
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let mut cfg = Config {
        harnesses: BTreeMap::from([("claude".to_owned(), profile)]),
        default_harness: Some("claude".into()),
        ..Default::default()
    };
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hold_person_key(&hub);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut c = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    c.become_person().await;
    (hub, c)
}

/// Stop the running turn with a second prompt queued behind it; returns that prompt's id.
async fn stop_with_a_queued_prompt(c: &mut TestClient, id: &str, queued: &str) -> i64 {
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["sessionUpdate"] == "agent_message_chunk")
        .await;
    let next = c.send(method::SESSION_PROMPT, prompt(id, queued, Some("p-next"))).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-next" && p["queued"] == true)
        .await;
    c.tx.send(Message::notification(method::SESSION_CANCEL, json!({"sessionId": id})).to_line())
        .await
        .unwrap();
    next
}

/// cx-he737: Claude Code slow to answer a Stop. acpmux ended the turn after
/// its grace and sent the queued prompt; Claude Code echoed it before the stopped
/// turn's result, and that result then answered the queued prompt too, as
/// cancelled, while its real reply streamed after it with no turn open.
#[tokio::test]
async fn a_slow_stop_leaves_the_next_claude_prompt_its_own_answer() {
    let (_hub, mut c) = claude_setup().await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.send(method::SESSION_PROMPT, prompt(&id, "slow-stop", None)).await;
    let next = stop_with_a_queued_prompt(&mut c, &id, "name three fruits").await;
    let (r, seen) = c.response(next).await;
    let r = r.expect("the queued prompt failed");
    assert_eq!(r["stopReason"], "end_turn", "the stopped turn answered the queued prompt: {r}");
    assert!(
        seen.iter().any(|(m, p)| m == method::SESSION_UPDATE
            && p["update"]["sessionUpdate"] == "agent_message_chunk"),
        "the queued prompt's reply did not stream before its answer: {seen:?}"
    );
}

/// cx-he737: codex-acp slow to answer a Stop. acpmux ended the turn after 3 s
/// and sent the queued prompt, which codex-acp folded into the stopped turn:
/// it ended cancelled and never ran.
#[tokio::test]
async fn a_slow_stop_does_not_fold_the_next_prompt_into_the_stopped_turn() {
    let env = BTreeMap::from([("FAKE_CODEX_STEER".to_owned(), "1".to_owned())]);
    let (_hub, mut c) = setup_env(PermissionPolicy::ApproveAll, env).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.send(method::SESSION_PROMPT, prompt(&id, "slow-stop", None)).await;
    let next = stop_with_a_queued_prompt(&mut c, &id, "the next one").await;
    let (r, seen) = c.response(next).await;
    let r = r.expect("the queued prompt failed");
    assert_eq!(r["stopReason"], "end_turn", "the queued prompt never ran: {r}");
    assert!(
        seen.iter().any(|(m, p)| m == method::SESSION_UPDATE
            && p["update"]["content"]["text"] == "turn: the next one"),
        "the queued prompt never started its own turn: {seen:?}"
    );
}

/// How soon after Stop a person sees it (Lawrence 2026-10-19: "interrupt them
/// faster"): the cancel's answer must not wait for the agent, and an agent
/// that honours the cancel has its turn end within the budget.
const STOP_BUDGET: Duration = Duration::from_millis(200);

/// Stop timing: the agent that takes the cancel (it checks every 50 ms) ends
/// its turn, as cancelled, within [`STOP_BUDGET`] of the cancel.
#[tokio::test]
async fn a_cancel_ends_an_honouring_agents_turn_within_the_budget() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "stop-timing").await;
    c.send(method::SESSION_PROMPT, prompt(&id, "until-cancel", None)).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["sessionUpdate"] == "agent_message_chunk")
        .await;
    let asked = std::time::Instant::now();
    c.tx.send(Message::notification(method::SESSION_CANCEL, json!({"sessionId": id})).to_line())
        .await
        .unwrap();
    let done = tokio::time::timeout(
        Duration::from_secs(5),
        c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_end"),
    )
    .await
    .expect("the turn did not end after Stop");
    let took = asked.elapsed();
    assert_eq!(done["msg"]["stopReason"], "cancelled", "{done}");
    assert!(took < STOP_BUDGET, "the turn ended {took:?} after Stop (budget {STOP_BUDGET:?})");
}

/// Stop timing: the cancel's answer (the CLI's "cancel sent") never waits for
/// the agent, even one that never takes the cancel.
#[tokio::test]
async fn a_cancel_is_answered_within_the_budget_while_the_agent_ignores_it() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "stop-ack").await;
    c.send(method::SESSION_PROMPT, prompt(&id, "deaf-to-cancel", None)).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["sessionUpdate"] == "agent_message_chunk")
        .await;
    let asked = std::time::Instant::now();
    let cancel = c.send(method::SESSION_CANCEL, json!({"sessionId": "stop-ack"})).await;
    let (r, _) = tokio::time::timeout(Duration::from_secs(5), c.response(cancel))
        .await
        .expect("the cancel was not answered");
    let took = asked.elapsed();
    assert_eq!(r.unwrap(), json!({}));
    assert!(took < STOP_BUDGET, "the cancel was answered {took:?} after it was sent");
}

/// Stops session `id` (`_acpmux/kill`, what `acpmux session stop` sends), then waits for its
/// answer and the answer to each prompt in `prompts`: those answers come after their turns' last status writes
/// (`finish_turn`), so nothing the stopped turns still do is left to land. Returns the status
/// `acpmux ls` reads then, and every status record and lifecycle event from the stop on.
async fn after_a_stop(
    hub: &Arc<Hub>,
    c: &mut TestClient,
    id: &str,
    prompts: &[i64],
) -> (Value, Vec<String>) {
    let before = hub.events(id, 0, 10_000).unwrap().last().map(|e| e.seq).unwrap_or(0);
    // Sent, not awaited: a request drops what comes before its answer, and a stopped prompt
    // can be answered first.
    let stop = c.send(method::MUX_KILL, json!({"sessionId": id, "purge": false})).await;
    if let Err(left) = answers(c, &[prompts, &[stop]].concat()).await {
        let later = mux_events_after(hub, id, before);
        panic!("no answer to the stopped prompts {left:?}: {later:?}");
    }
    (listed_status(c, id).await, mux_events_after(hub, id, before))
}

/// Waits for the answer to each request in `ids`, in whatever order they come; `Err` names
/// those with no answer after 20 s.
async fn answers(c: &mut TestClient, ids: &[i64]) -> Result<(), Vec<Value>> {
    let mut left: Vec<Value> = ids.iter().map(|id| json!(id)).collect();
    while !left.is_empty() {
        let Ok(line) = tokio::time::timeout(Duration::from_secs(20), c.rx.recv()).await else {
            return Err(left);
        };
        if let Message::Response { id, .. } =
            Message::parse(&line.expect("connection closed")).unwrap()
        {
            left.retain(|l| *l != id);
        }
    }
    Ok(())
}

/// Session `id`'s status in `_acpmux/sessions` (`acpmux ls`).
async fn listed_status(c: &mut TestClient, id: &str) -> Value {
    let listed = c.request(method::MUX_SESSIONS, json!({})).await.unwrap();
    listed["sessions"]
        .as_array()
        .and_then(|rows| rows.iter().find(|r| r["sessionId"] == id))
        .map(|row| row["status"].clone())
        .unwrap_or(Value::Null)
}

/// Session `id`'s mux events after `seq`, a status record as "status <status>".
fn mux_events_after(hub: &Arc<Hub>, id: &str, seq: u64) -> Vec<String> {
    hub.events(id, seq, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.dir == "mux")
        .map(|e| match e.msg.get("status").and_then(Value::as_str) {
            Some(status) => format!("{} {status}", e.kind),
            None => e.kind,
        })
        .collect()
}

// ergo-walk2 (2026-10-25): "session stop says closed but acpmux ls still shows it ready".
// A stopped session stays closed, as `acpmux ls` reads it, whatever its turn was doing.

/// Stopped while its turn waits on a permission nobody answers (the walk: a remote Codex
/// tool call).
#[tokio::test]
async fn a_session_stopped_while_it_asks_stays_closed() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let id = new_session(&mut c, "stop-asking").await;
    let turn = c.send(method::SESSION_PROMPT, prompt(&id, "ask: run a tool", None)).await;
    c.wait_for(method::MUX_PERMISSION_PENDING, |_| true).await;
    let (status, later) = after_a_stop(&hub, &mut c, &id, &[turn]).await;
    assert_eq!(status, "closed", "{later:?}");
}

/// Stopped mid-turn, with an agent that ends the turn when it is cancelled.
#[tokio::test]
async fn a_session_stopped_mid_turn_stays_closed() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "stop-running").await;
    let turn = c.send(method::SESSION_PROMPT, prompt(&id, "until-cancel", None)).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["sessionUpdate"] == "agent_message_chunk")
        .await;
    let (status, later) = after_a_stop(&hub, &mut c, &id, &[turn]).await;
    assert_eq!(status, "closed", "{later:?}");
}

/// Stopped with a prompt queued behind the running turn: the queued prompt is withdrawn, and
/// does not start it again.
#[tokio::test]
async fn a_session_stopped_with_a_queued_prompt_stays_closed() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "stop-queued").await;
    let turn = c.send(method::SESSION_PROMPT, prompt(&id, "until-cancel", None)).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["sessionUpdate"] == "agent_message_chunk")
        .await;
    let queued = c.send(method::SESSION_PROMPT, prompt(&id, "queued", Some("p-queued"))).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-queued" && p["queued"] == true)
        .await;
    let (status, later) = after_a_stop(&hub, &mut c, &id, &[turn, queued]).await;
    assert_eq!(status, "closed", "{later:?}");
    assert!(later.iter().any(|e| e == "queue_removed"), "{later:?}");
}

/// Stopped while a prompt starts its agent again (the agent takes 1.5 s to answer
/// `initialize`): the start ends, and the session stays closed.
#[tokio::test]
async fn a_session_stopped_while_its_agent_starts_stays_closed() {
    let env = BTreeMap::from([("FAKE_INIT_DELAY_MS".to_owned(), "1500".to_owned())]);
    let (hub, mut c) = setup_env(PermissionPolicy::ApproveAll, env).await;
    let id = new_session(&mut c, "stop-starting").await;
    c.request(method::MUX_KILL, json!({"sessionId": id, "purge": false})).await.unwrap();
    let turn = c.send(method::SESSION_PROMPT, prompt(&id, "hello", None)).await;
    c.wait_for(method::MUX_EVENT, |p| p["kind"] == "reopened").await;
    let (status, later) = after_a_stop(&hub, &mut c, &id, &[turn]).await;
    assert_eq!(status, "closed", "{later:?}");
}

/// The agent asks for a secret just after the stop cancelled the session's cards: the late
/// card is cancelled at once, and does not set the session waiting.
#[tokio::test]
async fn a_secret_asked_after_the_stop_is_cancelled_and_the_session_stays_closed() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let id = new_session(&mut c, "stop-secret").await;
    c.request(method::MUX_KILL, json!({"sessionId": id, "purge": false})).await.unwrap();
    let before = hub.events(&id, 0, 10_000).unwrap().last().map(|e| e.seq).unwrap_or(0);
    let session = hub.resolve(&id).unwrap();
    let asked = tokio::time::timeout(
        Duration::from_secs(5),
        hub.request_secret(&session, "API_KEY", "a late ask"),
    )
    .await
    .expect("the card asked after the stop waited for an answer");
    assert_eq!(asked.unwrap()["outcome"], "cancelled");
    let later = mux_events_after(&hub, &id, before);
    assert_eq!(listed_status(&mut c, &id).await, "closed", "{later:?}");
    assert!(!later.iter().any(|e| e == "secret_request"), "{later:?}");
}

/// A session resumed from stopped: its agent's load replays the earlier turns' replies, and the
/// session's `lastMessage` is still the new turn's reply alone, as `wait --print` prints it.
/// remote-ergo walk 4 (2026-10-26): "`acpmux session info HOST/S --json` lastMessage.text after
/// a session resumed from stopped concatenates earlier turns' replies and commentary with the new
/// reply".
#[tokio::test]
async fn a_session_resumed_from_stopped_keeps_only_the_new_reply_as_its_last_message() {
    let env =
        BTreeMap::from([("FAKE_LOAD_REPLAY_REPLY".to_owned(), "an earlier reply".to_owned())]);
    let (hub, mut c) = setup_env(PermissionPolicy::ApproveAll, env).await;
    let id = new_session(&mut c, "resume-last-message").await;
    c.request(method::SESSION_PROMPT, prompt(&id, "first", None)).await.unwrap();
    let last =
        |hub: &Arc<Hub>| hub.session_summary(&hub.resolve(&id).unwrap())["lastMessage"].clone();
    assert_eq!(last(&hub), json!({"role": "agent", "text": "echo: first"}));
    c.request(method::MUX_KILL, json!({"sessionId": id, "purge": false})).await.unwrap();
    c.request(method::SESSION_PROMPT, prompt(&id, "second", None)).await.unwrap();
    let events = hub.events(&id, 0, 10_000).unwrap();
    assert!(!find(&events, "agent_message_chunk.replay").is_empty(), "the load replayed no reply");
    assert_eq!(last(&hub), json!({"role": "agent", "text": "echo: second"}));
}

/// The same with a history longer than the session's inbound queue (1024 items): the load's
/// last replayed words still never reach `lastMessage`.
#[tokio::test]
async fn a_long_replayed_history_stays_out_of_the_resumed_sessions_last_message() {
    let env = BTreeMap::from([
        ("FAKE_LOAD_REPLAY_REPLY".to_owned(), "old ".to_owned()),
        ("FAKE_LOAD_REPLAY_CHUNKS".to_owned(), "3000".to_owned()),
    ]);
    let (hub, mut c) = setup_env(PermissionPolicy::ApproveAll, env).await;
    let id = new_session(&mut c, "resume-long-history").await;
    c.request(method::SESSION_PROMPT, prompt(&id, "first", None)).await.unwrap();
    c.request(method::MUX_KILL, json!({"sessionId": id, "purge": false})).await.unwrap();
    c.request(method::SESSION_PROMPT, prompt(&id, "second", None)).await.unwrap();
    let summary = hub.session_summary(&hub.resolve(&id).unwrap());
    assert_eq!(summary["lastMessage"], json!({"role": "agent", "text": "echo: second"}));
}
