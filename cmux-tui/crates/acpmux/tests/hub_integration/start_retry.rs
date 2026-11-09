//! A prompt whose agent start missed `agentStartTimeoutMs` is pending, not failed: its start is
//! tried again after a wait, and a Stop, a stop of the chat or the run-out of its tries ends that
//! (`hub/start_retry.rs`). Each test's agent stands in for a loaded machine's slow harness with
//! `FAKE_START_GATE`: it answers its start only once the gate file exists.
use super::*;

/// A connection that is not the person: an agent's or a lane's (the person's start has no
/// deadline at all).
fn agent_client(hub: &Arc<Hub>) -> TestClient {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    TestClient { tx: in_tx, rx: out_rx, next: 0 }
}

/// A started chat whose agent is stopped, and whose next start waits on `gate` (removed), under
/// a start budget of `budget_ms`.
async fn gated_chat(gate: &std::path::Path, name: &str, budget_ms: u64) -> (Arc<Hub>, String) {
    std::fs::write(gate, b"").unwrap();
    let env = BTreeMap::from([("FAKE_START_GATE".to_owned(), gate.to_string_lossy().into_owned())]);
    let (hub, _person) = setup_env(PermissionPolicy::ApproveAll, env).await;
    let mut c = agent_client(&hub);
    let created = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": name}}}),
        )
        .await
        .unwrap();
    let id = created["sessionId"].as_str().unwrap().to_owned();
    c.request(method::MUX_KILL, json!({"sessionId": id})).await.unwrap();
    std::fs::remove_file(gate).unwrap();
    hub.config.write().await.agent_start_timeout_ms = Some(budget_ms);
    (hub, id)
}

fn kinds(hub: &Hub, id: &str, kind: &str) -> Vec<Value> {
    hub.events(id, 0, 100_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == kind)
        .map(|e| e.msg)
        .collect()
}

/// Sends `text` to chat `id` from an agent's connection, answered on the returned task.
fn send(hub: &Arc<Hub>, id: &str, text: &str) -> tokio::task::JoinHandle<Result<Value, String>> {
    let mut c = agent_client(hub);
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]});
    tokio::spawn(async move { c.request(method::SESSION_PROMPT, prompt).await })
}

/// Waits until the chat logged `n` `agent_start_retrying` records, while its prompt is pending.
async fn retries_logged(
    hub: &Hub,
    id: &str,
    n: usize,
    prompt: &tokio::task::JoinHandle<Result<Value, String>>,
) {
    let deadline = std::time::Instant::now() + Duration::from_secs(60);
    while kinds(hub, id, "agent_start_retrying").len() < n {
        assert!(
            !prompt.is_finished(),
            "the prompt ended before its start was tried again ({:?})",
            kinds(hub, id, "turn_result")
        );
        assert!(std::time::Instant::now() < deadline, "the start was never tried again");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// The pid a missed start's error names (`its agent process (pid N)`).
#[cfg(unix)]
fn named_pid(error: &str) -> Option<i32> {
    let (_, rest) = error.split_once("(pid ")?;
    rest.split(|c: char| !c.is_ascii_digit()).next()?.parse().ok()
}

/// The agent process a missed start's `error` names, if any, is gone.
#[cfg(unix)]
fn assert_named_agent_ended(error: &str) {
    if let Some(pid) = named_pid(error) {
        // SAFETY: signal 0 only asks whether the process exists.
        let alive = unsafe { libc::kill(pid, 0) } == 0;
        assert!(!alive, "the missed start's agent (pid {pid}) still runs");
    }
}

/// The lanes stuck on 2026-11-06: a start past 90 s failed the turn with "agent_start did not
/// finish within 90s" and nothing sent the prompt again. Now the turn stays open, the start is
/// tried again, and the same prompt is answered once its agent starts. The missed try's agent
/// was ended, not left running beside the one that answered.
#[tokio::test]
async fn a_prompt_whose_start_missed_its_deadline_is_answered_after_a_retry() {
    let gate = std::env::temp_dir().join(format!("acpmux-retry-gate-{}", uuid::Uuid::now_v7()));
    let (hub, id) = gated_chat(&gate, "late-start", 1_500).await;
    let prompt = send(&hub, &id, "hello");
    retries_logged(&hub, &id, 1, &prompt).await;
    // The machine catches up: the next try's agent answers.
    std::fs::write(&gate, b"").unwrap();
    let answered = tokio::time::timeout(Duration::from_secs(60), prompt)
        .await
        .expect("the retried prompt never ended")
        .unwrap()
        .expect("the retried prompt failed");
    assert!(answered["stopReason"].is_string(), "{answered}");
    let results = kinds(&hub, &id, "turn_result");
    let last = results.last().unwrap();
    assert_ne!(last["status"], "failed", "{results:?}");
    // One prompt, one turn: the retry is the same prompt, never sent twice.
    let prompts = kinds(&hub, &id, "user_message");
    assert_eq!(prompts.iter().filter(|m| m["text"] == "hello").count(), 1, "{prompts:?}");
    let retried = kinds(&hub, &id, "agent_start_retrying");
    assert_eq!(retried[0]["attempt"], 1, "{retried:?}");
    assert_eq!(retried[0]["promptId"], last["promptId"], "{retried:?}");
    // Every missed try ended its agent: one `agent_start_timed_out` each, and its process is gone.
    assert_eq!(kinds(&hub, &id, "agent_start_timed_out").len(), retried.len(), "{retried:?}");
    for r in &retried {
        let error = r["error"].as_str().unwrap();
        assert!(error.contains("agent_start did not finish within"), "{error}");
        #[cfg(unix)]
        assert_named_agent_ended(error);
    }
    let _ = std::fs::remove_file(&gate);
}

/// A Stop while the start waits to be tried again ends the turn cancelled, and no other start
/// runs. The wait is 500 ms at a 4.5 s budget: the Stop lands inside it.
#[tokio::test]
async fn a_stop_while_the_start_waits_ends_the_turn_and_starts_nothing() {
    let gate = std::env::temp_dir().join(format!("acpmux-retry-stop-{}", uuid::Uuid::now_v7()));
    let (hub, id) = gated_chat(&gate, "stopped-start", 4_500).await;
    let prompt = send(&hub, &id, "hello");
    retries_logged(&hub, &id, 1, &prompt).await;
    let c = agent_client(&hub);
    c.tx.send(Message::notification(method::SESSION_CANCEL, json!({"sessionId": id})).to_line())
        .await
        .unwrap();
    let ended = tokio::time::timeout(Duration::from_secs(30), prompt)
        .await
        .expect("the stopped prompt never ended")
        .unwrap();
    let error = ended.expect_err("a stopped prompt was answered");
    assert!(error.contains("stopped before this prompt reached the agent"), "{error}");
    let results = kinds(&hub, &id, "turn_result");
    assert_eq!(results.last().unwrap()["status"], "cancelled", "{results:?}");
    assert_eq!(kinds(&hub, &id, "agent_start_retrying").len(), 1);
    assert_eq!(kinds(&hub, &id, "agent_start_timed_out").len(), 1, "a start ran after the Stop");
    let _ = std::fs::remove_file(&gate);
}

/// A stop of the chat (`acpmux session stop`) while the start waits does the same, and the chat
/// stays closed.
#[tokio::test]
async fn a_chat_stopped_while_its_start_waits_stays_closed_and_starts_nothing() {
    let gate = std::env::temp_dir().join(format!("acpmux-retry-kill-{}", uuid::Uuid::now_v7()));
    let (hub, id) = gated_chat(&gate, "killed-start", 4_500).await;
    let prompt = send(&hub, &id, "hello");
    retries_logged(&hub, &id, 1, &prompt).await;
    let mut c = agent_client(&hub);
    c.request(method::MUX_KILL, json!({"sessionId": id})).await.unwrap();
    let ended = tokio::time::timeout(Duration::from_secs(30), prompt)
        .await
        .expect("the prompt of a stopped chat never ended")
        .unwrap();
    assert!(ended.is_err(), "the prompt of a stopped chat was answered: {ended:?}");
    assert_eq!(kinds(&hub, &id, "agent_start_retrying").len(), 1);
    assert_eq!(kinds(&hub, &id, "agent_start_timed_out").len(), 1, "a start ran after the stop");
    assert_eq!(hub.session_summary(&hub.resolve(&id).unwrap())["status"], "closed");
    let _ = std::fs::remove_file(&gate);
}
