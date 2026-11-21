//! A turn acpmux ends for a cause of its own (`hub/cancel.rs` `end_turn_forced`: a capacity loop,
//! a refused sign-in, a stall) ends when its harness lets go of it, never before (cmux#47879).
//! `session/cancel` names the session, not the turn: a prompt written while the harness still runs
//! the old turn joins it and is answered cancelled. Each stand-in harness here takes the cancel and
//! answers 300 ms later, and logs any prompt that came in that time (`FAKE_PREMATURE_LOG`).

use super::*;

/// A fresh path for the fake's premature-prompt log, and its lines once the test is done.
struct PrematureLog(std::path::PathBuf);

impl PrematureLog {
    fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "acpmux-premature-{name}-{}-{}",
            std::process::id(),
            unique()
        ));
        let _ = std::fs::remove_file(&path);
        Self(path)
    }

    fn env(&self) -> (String, String) {
        ("FAKE_PREMATURE_LOG".to_owned(), self.0.to_string_lossy().into_owned())
    }

    fn lines(&self) -> Vec<String> {
        std::fs::read_to_string(&self.0)
            .map(|s| s.lines().map(str::to_owned).collect())
            .unwrap_or_default()
    }
}

impl Drop for PrematureLog {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

fn unique() -> u64 {
    use std::sync::atomic::{AtomicU64, Ordering};
    static N: AtomicU64 = AtomicU64::new(0);
    N.fetch_add(1, Ordering::SeqCst)
}

/// The `turn_result` records of `id`, oldest first.
fn results(hub: &Arc<Hub>, id: &str) -> Vec<Value> {
    find(&hub.events(id, 0, 10_000).unwrap(), "turn_result").iter().map(|e| e.msg.clone()).collect()
}

/// The records of one kind in `id`'s log.
fn records(hub: &Arc<Hub>, id: &str, kind: &str) -> Vec<Value> {
    find(&hub.events(id, 0, 10_000).unwrap(), kind).iter().map(|e| e.msg.clone()).collect()
}

/// Waits (test polling, real time, bounded) until `id`'s log has `n` turn results.
async fn until_results(hub: &Arc<Hub>, id: &str, n: usize) -> Vec<Value> {
    let deadline = std::time::Instant::now() + Duration::from_secs(30);
    loop {
        let got = results(hub, id);
        if got.len() >= n {
            return got;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "{n} turn results never came in {id}: {got:?}"
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// Queues the person's `text` behind the running turn of `id` and waits until it is queued.
async fn queue_next(c: &mut TestClient, id: &str, text: &str) -> i64 {
    let next = c.send(method::SESSION_PROMPT, prompt(id, text, Some("p-next"))).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-next" && p["queued"] == true)
        .await;
    next
}

/// A Codex stand-in whose first turn fails in place and takes 300 ms to let go of it.
async fn codex(log: &PrematureLog, ack_ms: u64) -> (Arc<Hub>, TestClient) {
    let env = BTreeMap::from([
        ("FAKE_CODEX_STEER".to_owned(), "1".to_owned()),
        ("FAKE_ACK_MS".to_owned(), ack_ms.to_string()),
        log.env(),
    ]);
    let (hub, c) = setup_env(PermissionPolicy::ApproveAll, env).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![50, 100]);
    (hub, c)
}

/// The stalled end: the queued prompt waits until the harness let go of the stalled turn, runs as
/// its own turn and completes; the stalled turn keeps its typed cause.
#[tokio::test]
async fn a_stalled_end_waits_for_the_harness_before_the_next_prompt() {
    let log = PrematureLog::new("stall");
    let (hub, mut c) = codex(&log, 300).await;
    let clock = acpmux::clock::ManualClock::new();
    hub.set_clock(clock.clone());
    hub.set_idle_child(None);
    hub.config.write().await.stalled_turn_end_ms = Some(60_000);
    let id = new_session(&mut c, "stall-ack").await;
    let old = c.send(method::SESSION_PROMPT, prompt(&id, "slow-ack:stall", Some("p-old"))).await;
    c.wait_for(method::SESSION_UPDATE, |p| {
        p["update"]["content"]["text"] == "turn: slow-ack:stall"
    })
    .await;
    let next = queue_next(&mut c, &id, "the next one").await;
    // Nobody shows the chat, so its stall is not held.
    c.request(method::MUX_DETACH, json!({"sessionId": id})).await.unwrap();
    clock.advance(Duration::from_secs(61));

    let (r, _) = c.response(old).await;
    let e = r.expect_err("the stalled turn failed");
    assert!(e.contains("no sign of work"), "the stalled cause was lost: {e}");
    // One that joined the stalled turn would be answered for it, cancelled.
    let (r, _) = c.response(next).await;
    let r = r.expect("the queued prompt failed");
    assert_eq!(r["stopReason"], "end_turn", "the queued prompt went into the stalled turn: {r}");
    assert_eq!(log.lines(), Vec::<String>::new(), "prompts went into the stalled turn");
    let ended = until_results(&hub, &id, 2).await;
    assert_eq!(ended[0]["status"], "failed", "{ended:?}");
    assert_eq!(ended[0]["detail"], "stalled", "{ended:?}");
    assert_eq!(ended[1]["status"], "completed", "{ended:?}");
}

/// A person's Stop while a stalled end waits for its harness: the turn ends as that Stop's,
/// cancelled, not as the stall, and the Stop's escalation is not run twice.
#[tokio::test]
async fn a_stop_during_a_stalled_end_ends_the_turn_as_stopped() {
    let log = PrematureLog::new("stall-stop");
    let (hub, mut c) = codex(&log, 1_500).await;
    let clock = acpmux::clock::ManualClock::new();
    hub.set_clock(clock.clone());
    hub.set_idle_child(None);
    hub.config.write().await.stalled_turn_end_ms = Some(60_000);
    let id = new_session(&mut c, "stall-stop").await;
    let old = c.send(method::SESSION_PROMPT, prompt(&id, "slow-ack:stall", Some("p-old"))).await;
    c.wait_for(method::SESSION_UPDATE, |p| {
        p["update"]["content"]["text"] == "turn: slow-ack:stall"
    })
    .await;
    c.request(method::MUX_DETACH, json!({"sessionId": id})).await.unwrap();
    clock.advance(Duration::from_secs(61));
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(results(&hub, &id).is_empty(), "the stalled turn ended before its harness let go");
    c.tx.send(Message::notification(method::SESSION_CANCEL, json!({"sessionId": id})).to_line())
        .await
        .unwrap();
    let (r, _) = c.response(old).await;
    assert_eq!(r.expect("a stopped turn answers")["stopReason"], "cancelled");
    let ended = until_results(&hub, &id, 1).await;
    assert_eq!(ended[0]["status"], "cancelled", "the Stop did not win: {ended:?}");
    assert!(ended[0]["detail"].is_null(), "{ended:?}");
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(records(&hub, &id, "auto_resume_scheduled").is_empty(), "a stopped turn continued");
    assert!(records(&hub, &id, "stop_escalated").is_empty(), "the harness answered in time");
}

/// The refused sign-in end (Claude Code's 401 retries): the turn ends once Claude Code answered its
/// interrupt, typed as signed out, and the queued prompt runs as its own turn.
#[tokio::test]
async fn a_refused_sign_in_end_waits_for_claude_before_the_next_prompt() {
    let log = PrematureLog::new("sign-in");
    let env = BTreeMap::from([
        ("FAKE_CLAUDE_RETRY_SCALE".to_owned(), "1".to_owned()),
        ("FAKE_CLAUDE_ACK_MS".to_owned(), "300".to_owned()),
        log.env(),
    ]);
    let (hub, mut c) = super::stop::claude_setup_env(env).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![50, 100]);
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let old = c.send(method::SESSION_PROMPT, prompt(&id, "auth-retry-probe", Some("p-old"))).await;
    c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_retrying").await;
    let next = queue_next(&mut c, &id, "name three fruits").await;

    let (r, _) = c.response(old).await;
    let e = r.expect_err("the refused sign-in fails the turn");
    assert!(e.contains("401"), "the sign-in cause was lost: {e}");
    let (r, _) = c.response(next).await;
    let r = r.expect("the queued prompt failed");
    assert_eq!(r["stopReason"], "end_turn", "the queued prompt went into the refused turn: {r}");
    assert_eq!(log.lines(), Vec::<String>::new(), "prompts went into the refused turn");
    let ended = until_results(&hub, &id, 2).await;
    assert_eq!(ended[0]["status"], "failed", "{ended:?}");
    // Typed as signed out: `finish_turn` gives it the sign-in card (`claude_auth.rs`).
    assert!(ended[0]["error"].as_str().is_some_and(|e| e.contains("not signed in")), "{ended:?}");
    assert_eq!(records(&hub, &id, "turn_retrying").len(), 2, "one end, at the second retry");
}
