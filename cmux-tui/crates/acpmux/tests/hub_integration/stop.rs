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

/// Another agent's message (`acpmux send --from`), queued as `prompt_id`.
fn from_agent(id: &str, prompt_id: &str, text: &str) -> Value {
    json!({"sessionId": id, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": {"promptId": prompt_id, "fromAgent": "coordinator"}}})
}

/// Sends `params` and waits until it is queued.
async fn queued(c: &mut TestClient, params: Value) {
    let prompt_id = params["_meta"]["acpmux"]["promptId"].as_str().unwrap().to_owned();
    c.send(method::SESSION_PROMPT, params).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == *prompt_id && p["queued"] == true)
        .await;
}

fn summary(hub: &Arc<Hub>, id: &str) -> Value {
    hub.session_summary(&hub.resolve(id).unwrap())
}

/// The queued prompts' ids and whether each is held.
fn held(row: &Value) -> Vec<(String, bool)> {
    let queue = row["queue"].as_array().cloned().unwrap_or_default();
    queue.iter().map(|q| (q["promptId"].as_str().unwrap().to_owned(), q["held"] == true)).collect()
}

/// An agent that goes on working after Stop (2026-10-29: a coordinator kept making tool calls
/// after Stop, the chat read as running, and its queued agent messages started the next turn
/// behind it). acpmux cancels it once more, then ends its process and starts it again on the
/// same conversation. The turn reads `stopping` until it really ended, nothing of the old
/// process lands after it, and the other agents' messages stay queued, held.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_agent_working_through_stop_is_restarted_on_the_same_conversation() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "works-through-stop").await;
    c.send(method::SESSION_PROMPT, prompt(&id, "works-through-cancel", Some("p-work"))).await;
    let first =
        c.wait_for(method::SESSION_UPDATE, |p| p["update"]["sessionUpdate"] == "tool_call").await;
    let title = first["update"]["title"].as_str().unwrap().to_owned();
    let old_pid = format!("pid {}", title.rsplit(' ').next().unwrap());
    let conversation = summary(&hub, &id)["agentSessionId"].clone();
    assert!(conversation.is_string(), "{conversation}");
    queued(&mut c, from_agent(&id, "p-agent", "from the coordinator")).await;
    c.tx.send(Message::notification(method::SESSION_CANCEL, json!({"sessionId": id})).to_line())
        .await
        .unwrap();
    let mut state = Value::Null;
    for _ in 0..200 {
        state = summary(&hub, &id)["state"].clone();
        if state == "stopping" {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(state, "stopping", "a Stop's turn reads stopping until it ends");
    let ended = tokio::time::timeout(
        Duration::from_secs(40),
        c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_result"),
    )
    .await
    .expect("the stopped turn never ended");
    assert_eq!(ended["msg"]["status"], "cancelled", "{ended}");
    assert_eq!(ended["msg"]["cancelForced"], true, "{ended}");
    tokio::time::timeout(
        Duration::from_secs(20),
        c.wait_for(method::MUX_EVENT, |p| p["kind"] == "stop_restarted"),
    )
    .await
    .expect("the agent was not started again");
    // Another agent's message after the Stop waits too.
    queued(&mut c, from_agent(&id, "p-agent-2", "the coordinator again")).await;
    tokio::time::sleep(Duration::from_millis(1500)).await;

    let events = hub.events(&id, 0, 100_000).unwrap();
    let result = events.iter().find(|e| e.kind == "turn_result").unwrap();
    let steps: Vec<&str> = events
        .iter()
        .filter(|e| e.kind == "stop_escalated" && e.seq < result.seq)
        .filter_map(|e| e.msg["step"].as_str())
        .collect();
    assert_eq!(steps, ["interrupt", "restart"], "cancelled again, then restarted, then ended");
    assert!(
        events.iter().any(|e| e.kind == "resumed" && e.seq > result.seq),
        "the new process did not resume the conversation"
    );
    let late: Vec<&str> = events
        .iter()
        .filter(|e| e.kind == "tool_call" && e.at > result.at + 500)
        .filter_map(|e| e.msg["params"]["update"]["title"].as_str())
        .filter(|t| t.ends_with(&old_pid))
        .collect();
    assert!(late.is_empty(), "the stopped process worked on after its turn ended: {late:?}");
    let row = summary(&hub, &id);
    assert_eq!(row["agentSessionId"], conversation, "{row}");
    assert!(row["turn"].is_null(), "a turn runs after the Stop: {row}");
    assert!(!["running", "stopping"].contains(&row["state"].as_str().unwrap()), "{row}");
    assert_eq!(
        held(&row),
        [("p-agent".to_owned(), true), ("p-agent-2".to_owned(), true)],
        "the agents' messages stay queued, held: {row}"
    );
}

/// Stop never ends a process that runs background work (Leo, 2026-10-31: "WELL THAT STOP BUTTON
/// STOPPED LITERALLY EVERYTHING"). The agent works on through both cancels beside a background
/// subagent; acpmux ends only the turn (`stop_escalated` `interrupt`, then `spared`): its process
/// is neither ended nor started again, and the background subagent still runs.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_stop_beside_background_work_ends_only_the_turn_and_keeps_the_process() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "stop-beside-background").await;
    c.send(
        method::SESSION_PROMPT,
        prompt(&id, "works-through-cancel-beside-background", Some("p-work")),
    )
    .await;
    let first =
        c.wait_for(method::SESSION_UPDATE, |p| p["update"]["sessionUpdate"] == "tool_call").await;
    let title = first["update"]["title"].as_str().unwrap().to_owned();
    let pid = format!("pid {}", title.rsplit(' ').next().unwrap());
    c.tx.send(Message::notification(method::SESSION_CANCEL, json!({"sessionId": id})).to_line())
        .await
        .unwrap();
    let ended = tokio::time::timeout(
        Duration::from_secs(40),
        c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_result"),
    )
    .await
    .expect("the stopped turn never ended");
    assert_eq!(ended["msg"]["status"], "cancelled", "{ended}");
    assert_eq!(ended["msg"]["cancelForced"], true, "{ended}");
    assert_ne!(ended["msg"]["restarted"], true, "{ended}");
    tokio::time::sleep(Duration::from_millis(1500)).await;

    let events = hub.events(&id, 0, 100_000).unwrap();
    let steps: Vec<&str> = events
        .iter()
        .filter(|e| e.kind == "stop_escalated")
        .filter_map(|e| e.msg["step"].as_str())
        .collect();
    assert_eq!(steps, ["interrupt", "spared"], "the process was ended beside background work");
    assert!(!events.iter().any(|e| e.kind == "stop_restarted"), "the agent was started again");
    assert!(
        !events.iter().any(|e| matches!(e.kind.as_str(), "stopped" | "exited")),
        "the agent's process ended"
    );
    let result = events.iter().find(|e| e.kind == "turn_result").unwrap();
    assert!(
        !events.iter().any(|e| e.kind == "resumed" && e.seq > result.seq),
        "a new process resumed the conversation"
    );
    // The same process still runs: it goes on calling tools after the turn ended.
    let after: Vec<&str> = events
        .iter()
        .filter(|e| e.kind == "tool_call" && e.seq > result.seq)
        .filter_map(|e| e.msg["params"]["update"]["title"].as_str())
        .collect();
    assert!(
        after.iter().any(|t| t.ends_with(&pid)),
        "the agent's process did not run on: {after:?}"
    );
    let row = summary(&hub, &id);
    assert!(row["turn"].is_null(), "the stopped turn is still open: {row}");
}

/// The person's Stop keeps their own queued prompt as it was: it runs next. The other agents'
/// messages wait held until it completed, then go in.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn after_the_persons_stop_their_prompt_runs_next_and_agents_wait_for_it() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "stop-keeps-person").await;
    c.send(method::SESSION_PROMPT, prompt(&id, "until-cancel", Some("p-run"))).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "running").await;
    queued(&mut c, from_agent(&id, "p-agent", "agent words")).await;
    queued(&mut c, json!({"sessionId": id, "prompt": [{"type": "text", "text": "person words"}], "_meta": {"acpmux": {"promptId": "p-next"}}})).await;
    c.tx.send(Message::notification(method::SESSION_CANCEL, json!({"sessionId": id})).to_line())
        .await
        .unwrap();
    c.wait_for(method::MUX_EVENT, |p| {
        p["kind"] == "turn_started" && p["msg"]["promptId"] == "p-next"
    })
    .await;
    let row = summary(&hub, &id);
    assert_eq!(held(&row), [("p-agent".to_owned(), true)]);
    // The list says the Stop holds it, so a client that attaches now says so too.
    assert_eq!(row["queue"][0]["heldByStop"], true, "{row}");
    tokio::time::timeout(
        Duration::from_secs(20),
        c.wait_for(method::SESSION_UPDATE, |p| {
            p["update"]["content"]["text"].as_str().is_some_and(|t| t.contains("agent words"))
        }),
    )
    .await
    .expect("the agent's message never went in after the person's turn");
}

/// After the person's Stop, an inbox digest of the agent messages it holds waits held too: it
/// neither steers nor starts a turn (`inbox_digest.rs`).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn after_the_persons_stop_an_inbox_digest_of_the_held_messages_waits_held() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "stop-holds-digest").await;
    let run = c.send(method::SESSION_PROMPT, prompt(&id, "until-cancel", Some("p-run"))).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "running").await;
    queued(&mut c, from_agent(&id, "p-a", "first words")).await;
    queued(&mut c, from_agent(&id, "p-b", "second words")).await;
    c.tx.send(Message::notification(method::SESSION_CANCEL, json!({"sessionId": id})).to_line())
        .await
        .unwrap();
    assert_eq!(c.response(run).await.0.unwrap()["stopReason"], "cancelled");
    let made = c.request("_acpmux/inbox_digest", json!({"sessionId": id})).await.unwrap();
    assert_eq!(made["digested"], 2, "{made}");
    assert_eq!(made["delivery"], "queued", "a digest under the hold steers into nothing: {made}");
    let digest = made["promptId"].as_str().unwrap().to_owned();
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(held(&summary(&hub, &id)), [(digest, true)]);
    let started = hub.events(&id, 0, 10_000).unwrap();
    let turns = started.iter().filter(|e| e.kind == "turn_started").count();
    assert_eq!(turns, 1, "a turn started after the person's Stop");
}

/// The person's Stop while a failed turn's agent messages wait for their retry: the retry
/// leaves them held, since only the person's next turn or a resume ends a Stop's hold.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn after_the_persons_stop_a_failed_turns_retry_leaves_agent_messages_held() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![1_500]);
    let id = new_session(&mut c, "stop-outlasts-retry").await;
    c.send(method::SESSION_PROMPT, prompt(&id, "until-cancel", Some("p-run"))).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "running").await;
    queued(&mut c, json!({"sessionId": id, "prompt": [{"type": "text", "text": "fail-streamed: boom"}], "_meta": {"acpmux": {"promptId": "p-f"}}})).await;
    queued(&mut c, from_agent(&id, "p-a", "agent words")).await;
    // An agent's Stop: the failing prompt runs and its failure holds the agent message.
    hub.cancel(&hub.resolve(&id).unwrap()).await.unwrap();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while !(summary(&hub, &id)["turn"].is_null()
        && held(&summary(&hub, &id)) == [("p-a".to_owned(), true)])
    {
        assert!(tokio::time::Instant::now() < deadline, "the failure never held p-a");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    // The person's Stop, before the retry wait ends.
    c.tx.send(Message::notification(method::SESSION_CANCEL, json!({"sessionId": id})).to_line())
        .await
        .unwrap();
    tokio::time::sleep(Duration::from_millis(3_000)).await;
    assert_eq!(held(&summary(&hub, &id)), [("p-a".to_owned(), true)]);
    let events = hub.events(&id, 0, 10_000).unwrap();
    assert!(
        !events.iter().any(|e| e.kind == "turn_started" && e.msg["promptId"] == "p-a"),
        "the retry ran an agent message after the person's Stop"
    );
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

/// The old cancellation result arrives after the queued prompt echo. A slash
/// prefix (including a path) is not evidence that the result belongs to it.
#[tokio::test]
async fn a_slow_stop_leaves_slash_prompts_their_own_answers() {
    for text in ["/compact", "/clear", "/review skills", "/Users/me/x.rs is broken"] {
        let (_hub, mut c) = claude_setup().await;
        let s =
            c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
        let id = s["sessionId"].as_str().unwrap().to_owned();
        c.send(method::SESSION_PROMPT, prompt(&id, "slow-stop", None)).await;
        let next = stop_with_a_queued_prompt(&mut c, &id, text).await;
        let (r, _) = c.response(next).await;
        assert_eq!(r.unwrap()["stopReason"], "end_turn", "old Stop answered {text}");
    }
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

/// Claude Code can ignore `interrupt` while it is compacting. A repeated Stop
/// still settles that turn once, before Claude's late compaction result, and
/// does not let the late result start another turn.
#[tokio::test]
async fn a_compacting_claude_stop_is_prompt_and_idempotent() {
    let (_hub, mut c) = claude_setup().await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let prompt_id = "compact-stop-prompt";
    c.send(method::SESSION_PROMPT, prompt(&id, "compact-stop", Some(prompt_id))).await;
    c.wait_for(method::SESSION_UPDATE, |p| {
        p["update"]["sessionUpdate"] == "compaction" && p["update"]["state"] == "running"
    })
    .await;
    let queued =
        c.send(method::SESSION_PROMPT, prompt(&id, "must-not-start", Some("p-next"))).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-next" && p["queued"] == true)
        .await;
    let stopped = std::time::Instant::now();
    for _ in 0..2 {
        c.tx.send(
            Message::notification(method::SESSION_CANCEL, json!({"sessionId": id})).to_line(),
        )
        .await
        .unwrap();
    }
    let (queued_result, seen) = tokio::time::timeout(Duration::from_secs(2), c.response(queued))
        .await
        .expect("the queued prompt was not withdrawn");
    let queued_result = queued_result.expect("queued prompt response failed");
    assert_eq!(queued_result["stopReason"], "cancelled", "{queued_result}");
    assert_eq!(queued_result["_meta"]["acpmux"]["withdrawn"], true, "{queued_result}");
    let result = seen
        .iter()
        .find(|(method, params)| *method == method::MUX_EVENT && params["kind"] == "turn_result")
        .map(|(_, params)| params.clone());
    let result = match result {
        Some(result) => result,
        None => tokio::time::timeout(
            Duration::from_secs(2),
            c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_result"),
        )
        .await
        .expect("forced turn_result was not published"),
    };
    assert!(stopped.elapsed() < Duration::from_secs(2));
    assert_eq!(result["msg"]["status"], "cancelled", "{result}");
    assert_eq!(result["msg"]["cancelForced"], true, "{result}");
    assert_eq!(result["msg"]["promptId"], prompt_id, "{result}");
    assert!(result["msg"]["turnId"].as_str().is_some(), "{result}");
    assert!(result["msg"]["turnSeq"].as_u64().is_some(), "{result}");
    // The fake emits its compaction result after 800 ms. It is stale after the
    // forced end: no second turn or forced result is recorded for the stop.
    tokio::time::sleep(Duration::from_millis(900)).await;
    let events = _hub.events(&id, 0, 10_000).unwrap();
    let results: Vec<_> = events.iter().filter(|e| e.kind == "turn_result").collect();
    assert_eq!(results.len(), 1, "{results:?}");
    assert_eq!(events.iter().filter(|e| e.kind == "turn_started").count(), 1, "{events:?}");
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

/// A test's stand-in harness runs at normal CPU class once its start is over, not at the
/// product's background default (`cpu_class.rs`). The stand-ins time their turns with short
/// sleeps (a Codex-steer turn polls 300 x 10 ms for a joined prompt), and on a loaded fleet Mac
/// (load 13 to 21 on 10 performance cores) a background-class stand-in did not end that turn in
/// 18 to 30 s: this test, the forum's steered rule and the steer race failed only on macOS.
/// `tests/cpu_class.rs` asks for background itself and checks the product's class.
#[cfg(target_os = "macos")]
#[test]
fn a_stand_in_harness_runs_at_normal_class_in_tests() {
    assert_eq!(acpmux::cpu_class::CpuClass::for_session([]), acpmux::cpu_class::CpuClass::Normal);
}
