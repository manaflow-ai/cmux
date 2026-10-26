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

/// What happened to session `id` after its `_acpmux/kill` (`acpmux session stop`) answered:
/// its status a moment later, as `acpmux ls` reads it, and the records after the close.
async fn after_a_stop(hub: &Arc<Hub>, c: &mut TestClient, id: &str) -> (Value, Vec<String>) {
    c.request(method::MUX_KILL, json!({"sessionId": id, "purge": false})).await.unwrap();
    let closed_at = hub.events(id, 0, 10_000).unwrap().last().map(|e| e.seq).unwrap_or(0);
    // Whatever the stopped turn still does (its end, the queue behind it) settles here.
    tokio::time::sleep(Duration::from_millis(1500)).await;
    let listed = c.request(method::MUX_SESSIONS, json!({})).await.unwrap();
    let row = listed["sessions"]
        .as_array()
        .and_then(|rows| rows.iter().find(|r| r["sessionId"] == id))
        .cloned()
        .unwrap_or(Value::Null);
    let later =
        hub.events(id, closed_at, 10_000).unwrap().into_iter().map(|e| e.kind).collect();
    (row["status"].clone(), later)
}

/// ergo-walk2 (2026-10-25): "session stop says closed but acpmux ls still shows it ready".
/// A stop while the turn waits on a permission, while it runs, and with a prompt queued
/// behind it: the session stays closed, and nothing starts it again on its own.
#[tokio::test]
async fn a_stopped_session_stays_closed_whatever_its_turn_was_doing() {
    // Waiting on a permission nobody answers (the walk: a remote Codex tool call).
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let id = new_session(&mut c, "stop-asking").await;
    c.send(method::SESSION_PROMPT, prompt(&id, "ask: run a tool", None)).await;
    c.wait_for(method::MUX_PERMISSION_PENDING, |_| true).await;
    let (status, later) = after_a_stop(&hub, &mut c, &id).await;
    assert_eq!(status, "closed", "stopped while asking; then {later:?}");

    // Running a turn the agent ends when it is cancelled.
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "stop-running").await;
    c.send(method::SESSION_PROMPT, prompt(&id, "until-cancel", None)).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["sessionUpdate"] == "agent_message_chunk")
        .await;
    let (status, later) = after_a_stop(&hub, &mut c, &id).await;
    assert_eq!(status, "closed", "stopped mid-turn; then {later:?}");

    // With a prompt queued behind the running turn.
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "stop-queued").await;
    c.send(method::SESSION_PROMPT, prompt(&id, "until-cancel", None)).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["sessionUpdate"] == "agent_message_chunk")
        .await;
    c.send(method::SESSION_PROMPT, prompt(&id, "queued", Some("p-queued"))).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-queued" && p["queued"] == true)
        .await;
    let (status, later) = after_a_stop(&hub, &mut c, &id).await;
    assert_eq!(status, "closed", "stopped with a prompt queued; then {later:?}");
    assert!(!later.iter().any(|k| k == "reopened"), "the queued prompt reopened it: {later:?}");
}
