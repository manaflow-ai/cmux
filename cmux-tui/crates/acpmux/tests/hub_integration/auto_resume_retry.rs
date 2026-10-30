//! `_acpmux/retry` (`hub/auto_resume/retry_turn.rs`): the Retry button retries a chat's failed
//! last turn now, in the same session. subsession-card's ask (b), from Leo's "this needs to
//! retry :(" (2026-10-26).
use super::*;

const RETRY: &str = "_acpmux/retry";

fn row(hub: &Hub, id: &str) -> Value {
    hub.session_summary(&hub.resolve(id).unwrap())
}

async fn prompt(
    c: &mut TestClient,
    id: &str,
    prompt_id: &str,
    text: &str,
) -> Result<Value, String> {
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": {"promptId": prompt_id}}}),
    )
    .await
}

fn turn_results(k: &[String]) -> usize {
    k.iter().filter(|k| *k == "turn_result").count()
}

#[tokio::test]
async fn retry_refuses_when_nothing_failed_and_while_a_turn_runs() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "retry-refusals").await;
    let e = c.request(RETRY, json!({"sessionId": id})).await.unwrap_err();
    assert!(e.starts_with("retry.nothing_failed"), "{e}");
    prompt(&mut c, &id, "p-ok", "hello").await.unwrap();

    // A turn runs: busy.
    let mut other = connect(&hub).await;
    let sid = id.clone();
    let running =
        tokio::spawn(async move { prompt(&mut other, &sid, "p-run", "until-cancel").await });
    for _ in 0..400 {
        if hub.resolve(&id).unwrap().turn().is_some() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    let e = c.request(RETRY, json!({"sessionId": id})).await.unwrap_err();
    assert!(e.starts_with("retry.busy"), "{e}");
    c.request(method::SESSION_CANCEL, json!({"sessionId": id})).await.unwrap();
    let _ = running.await;
    // A cancelled turn did not fail.
    let e = c.request(RETRY, json!({"sessionId": id})).await.unwrap_err();
    assert!(e.starts_with("retry.nothing_failed"), "{e}");
}

/// A retry of a subagent is not one of the chat's turn: a subagent the chat does not have is
/// refused by name (`retry.unknown_subagent`), never sent as the parent's turn.
#[tokio::test]
async fn an_unknown_subagent_retry_is_refused_and_never_retries_the_parent_turn() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![]);
    let id = new_session(&mut c, "retry-subagent").await;
    prompt(&mut c, &id, "p-f", "fail-once: hello").await.unwrap_err();
    let e = c.request(RETRY, json!({"sessionId": id, "subagentId": "a1"})).await.unwrap_err();
    assert!(e.starts_with("retry.unknown_subagent"), "{e}");
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(user_messages(&hub, &id).len(), 1, "the parent's turn was not retried");
    assert_eq!(row(&hub, &id)["lastTurn"]["status"], "failed");
    // Without it, the turn retries.
    let v = c.request(RETRY, json!({"sessionId": id})).await.unwrap();
    assert_eq!(v["promptId"], "p-f~resume-1", "{v}");
}

/// A turn that failed before the model produced anything goes again as the same prompt, in the
/// same session, as the next attempt of its prompt id; a double click sends it once.
#[tokio::test]
async fn a_failed_turn_with_no_output_is_sent_again_as_the_same_prompt() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    // No automatic retry: the failure stays failed until the person retries it.
    hub.config.write().await.auto_resume_delays_ms = Some(vec![]);
    let id = new_session(&mut c, "retry-same").await;
    let e = prompt(&mut c, &id, "p-f", "fail-once: hello").await.unwrap_err();
    assert!(e.contains("simulated internal error"), "{e}");
    assert_eq!(row(&hub, &id)["lastTurn"]["status"], "failed");
    let agent_session = row(&hub, &id)["agentSessionId"].clone();
    let cut_turn = user_messages(&hub, &id)[0]["turnId"].clone();

    let mut other = connect(&hub).await;
    let (a, b) = tokio::join!(
        c.request(RETRY, json!({"sessionId": id})),
        other.request(RETRY, json!({"sessionId": id}))
    );
    let mut answered = 0;
    for r in [a, b] {
        match r {
            Ok(v) => {
                answered += 1;
                assert_eq!(v["promptId"], "p-f~resume-1", "{v}");
                assert_eq!(v["kind"], "turn", "{v}");
            }
            // The other click came while the first one's turn ran, or after it ended.
            Err(e) => {
                assert!(e.starts_with("retry.busy") || e.starts_with("retry.nothing_failed"), "{e}")
            }
        }
    }
    assert!(answered >= 1);
    let k = until(&hub, &id, |k| turn_results(k) == 2).await;
    let messages = user_messages(&hub, &id);
    assert_eq!(messages.len(), 2, "sent once: {messages:?} {k:?}");
    assert_eq!(messages[1]["promptId"], "p-f~resume-1");
    assert_eq!(messages[1]["text"], "fail-once: hello", "the same prompt");
    assert_eq!(
        messages[1]["_meta"]["provenance"],
        json!({"kind": "auto_resume", "promptId": "p-f", "attempt": 1, "turnId": cut_turn, "manual": true})
    );
    let after = row(&hub, &id);
    assert_eq!(after["lastTurn"]["status"], "completed", "{after}");
    assert_eq!(after["agentSessionId"], agent_session, "{after}");
    assert_eq!(hub.sessions().len(), 1, "no new session");
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(user_messages(&hub, &id).len(), 2);
    let e = c.request(RETRY, json!({"sessionId": id})).await.unwrap_err();
    assert!(e.starts_with("retry.nothing_failed"), "{e}");
}

/// A turn the model had started on is continued, not sent again.
#[tokio::test]
async fn a_failed_turn_with_output_is_continued() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![]);
    let id = new_session(&mut c, "retry-continue").await;
    prompt(&mut c, &id, "p-o", "fail-after-update: x").await.unwrap_err();
    let v = c.request(RETRY, json!({"sessionId": id})).await.unwrap();
    assert_eq!(v["promptId"], "p-o~resume-1", "{v}");
    assert!(v["turnId"].is_string(), "{v}");
    until(&hub, &id, |k| turn_results(k) == 2).await;
    let messages = user_messages(&hub, &id);
    assert_eq!(messages.len(), 2, "{messages:?}");
    let text = messages[1]["text"].as_str().unwrap();
    assert!(text.starts_with("Your previous turn was cut off by an error"), "{text}");
    assert!(text.contains("simulated internal error after output"), "{text}");
    assert_eq!(row(&hub, &id)["lastTurn"]["status"], "completed");
}

/// A retry that waits is taken over and sent now, under the attempt's own id: its minute's wait
/// ends at once and its timer sends nothing.
#[tokio::test]
async fn a_waiting_retry_fires_now() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![60_000]);
    let id = new_session(&mut c, "retry-now").await;
    prompt(&mut c, &id, "p-cap", "cap-fail-once: build it").await.unwrap_err();
    until(&hub, &id, |k| k.iter().any(|k| k == "auto_resume_scheduled")).await;
    assert_eq!(row(&hub, &id)["retry"]["attempt"], 1);
    let v = c.request(RETRY, json!({"sessionId": id})).await.unwrap();
    assert_eq!((&v["promptId"], &v["kind"]), (&json!("p-cap~resume-1"), &json!("turn")), "{v}");
    // Asked again: busy while it runs, nothing failed once it went through; never a second prompt.
    let e = c.request(RETRY, json!({"sessionId": id})).await.unwrap_err();
    assert!(e.starts_with("retry.busy") || e.starts_with("retry.nothing_failed"), "{e}");
    let k = until(&hub, &id, |k| turn_results(k) == 2).await;
    assert_eq!(turn_results(&k), 2, "fired within seconds, not a minute: {k:?}");
    let messages = user_messages(&hub, &id);
    assert_eq!(messages.len(), 2, "{messages:?}");
    assert_eq!(messages[1]["promptId"], "p-cap~resume-1");
    assert_eq!(row(&hub, &id)["retry"], Value::Null);
    assert_eq!(row(&hub, &id)["lastTurn"]["status"], "completed");
    let skipped =
        hub.events(&id, 0, 10_000).unwrap().into_iter().find(|e| e.kind == "auto_resume_skipped");
    assert_eq!(skipped.map(|e| e.msg["skipped"].clone()), Some(json!("superseded")));
}

/// A Web caller's retry runs under the Web's rules: one that could not prompt the chat leaves
/// the waiting retry as it was, never sends it early (Codex review of #25296).
#[tokio::test]
async fn a_caller_that_may_not_prompt_the_chat_cannot_take_over_a_waiting_retry() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![60_000]);
    let id = new_session(&mut c, "retry-web").await;
    prompt(&mut c, &id, "p-cap", "cap-fail-once: build it").await.unwrap_err();
    until(&hub, &id, |k| k.iter().any(|k| k == "auto_resume_scheduled")).await;
    // The fake harness's `normal` mode does not ask, by this table: the Web may not prompt it.
    hub.config.write().await.web_asking_modes.insert("fake".into(), vec!["strict".into()]);
    let (in_tx, in_rx) = tokio::sync::mpsc::channel(64);
    let (out_tx, out_rx) = tokio::sync::mpsc::channel(4096);
    let web = acpmux::server::Origin::Web;
    tokio::spawn(acpmux::server::serve_connection_with(hub.clone(), in_rx, out_tx, web));
    let mut web = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    let e = web.request(RETRY, json!({"sessionId": id})).await.unwrap_err();
    assert!(e.contains("does not ask"), "{e}");
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(user_messages(&hub, &id).len(), 1, "{:?}", kinds(&hub, &id));
    assert_eq!(row(&hub, &id)["retry"]["attempt"], 1, "the retry still waits");
    assert!(!kinds(&hub, &id).iter().any(|k| k == "auto_resume_skipped"));
}

/// Stop between a retry's claim and its turn's start refuses it (`retry.stopped`): the
/// failed turn is not sent again. A second retry before the stopped one's task ended is busy,
/// never joined to it under the first caller's rules (Codex review of #25296, round 2).
#[tokio::test]
async fn stop_before_a_retrys_turn_starts_prevents_it() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![]);
    let id = new_session(&mut c, "retry-stop").await;
    let e = prompt(&mut c, &id, "p-x", "net-fail-then-exit").await.unwrap_err();
    assert!(e.contains("stream disconnected"), "{e}");
    // The agent exits: the retry's prompt waits on the config to start it again
    // (`cold_prompt_check`), past the claim and before its turn starts.
    tokio::time::sleep(Duration::from_millis(500)).await;
    let session = hub.resolve(&id).unwrap();
    let mut other = connect(&hub).await;
    let config = hub.config.write().await;
    let sid = id.clone();
    let retry = tokio::spawn(async move { other.request(RETRY, json!({"sessionId": sid})).await });
    tokio::time::sleep(Duration::from_millis(500)).await;
    let _ = tokio::time::timeout(Duration::from_secs(2), hub.cancel(&session)).await;
    let e = c.request(RETRY, json!({"sessionId": id})).await.unwrap_err();
    assert!(e.starts_with("retry.busy"), "{e}");
    drop(config);
    let e = retry.await.unwrap().unwrap_err();
    assert!(e.starts_with("retry.stopped"), "{e}");
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(user_messages(&hub, &id).len(), 1, "{:?}", kinds(&hub, &id));
    // Once it ended, a retry goes.
    let v = c.request(RETRY, json!({"sessionId": id})).await.unwrap();
    assert_eq!(v["promptId"], "p-x~resume-1", "{v}");
}

/// A failed turn of agent messages put the ones that joined it back (`digest.rs`): its retry is
/// the continuation, so each joined message reaches the agent once, when it runs again.
#[tokio::test]
async fn a_failed_turn_of_agent_messages_is_continued_not_sent_again() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![]);
    let id = new_session(&mut c, "retry-digest").await;
    c.send(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "until-cancel"}]}),
    )
    .await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "running").await;
    let mut agents = connect(&hub).await;
    for (pid, agent, text) in
        [("p-a", "lane-a", "from a"), ("p-b", "lane-b", "[fail-digest-once] from b")]
    {
        agents.send(method::SESSION_PROMPT, json!({"sessionId": id, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": {"promptId": pid, "fromAgent": agent}}})).await;
        agents
            .wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == pid && p["queued"] == true)
            .await;
    }
    c.send(method::SESSION_CANCEL, json!({"sessionId": id})).await;
    // The cancelled turn, then the failed turn of both messages.
    until(&hub, &id, |k| turn_results(k) == 2).await;
    for _ in 0..200 {
        if row(&hub, &id)["lastTurn"]["status"] == "failed"
            && hub.resolve(&id).unwrap().turn().is_none()
        {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let v = c.request(RETRY, json!({"sessionId": id})).await.unwrap();
    assert_eq!(v["kind"], "turn", "{v}");
    // The continuation, then the message put back.
    until(&hub, &id, |k| turn_results(k) == 4).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    let messages = user_messages(&hub, &id);
    let sent = |s: &str| {
        messages.iter().filter(|m| m["text"].as_str().unwrap_or_default().contains(s)).count()
    };
    assert_eq!(
        sent("from b"),
        2,
        "the failed turn and its message again, never a third: {messages:?}"
    );
    assert!(
        messages.iter().any(|m| m["text"]
            .as_str()
            .unwrap_or_default()
            .starts_with("Your previous turn was cut off")),
        "{messages:?}"
    );
}

/// A prompt's hidden context is not recorded (`prompt_context.rs`): a failed turn that had one
/// is continued, never sent again without it.
#[tokio::test]
async fn a_failed_turn_with_hidden_context_is_continued() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![]);
    let id = new_session(&mut c, "retry-context").await;
    let context = "<cmux-workspace-context>CTX-MARK</cmux-workspace-context>";
    let r = c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "fail-once: hello"}],
               "_meta": {"acpmux": {"promptId": "p-c", "context": context}}}),
    );
    r.await.unwrap_err();
    assert_eq!(user_messages(&hub, &id)[0]["hiddenContext"], true);
    let v = c.request(RETRY, json!({"sessionId": id})).await.unwrap();
    assert_eq!(v["promptId"], "p-c~resume-1", "{v}");
    until(&hub, &id, |k| turn_results(k) == 2).await;
    let messages = user_messages(&hub, &id);
    let text = messages[1]["text"].as_str().unwrap();
    assert!(text.starts_with("Your previous turn was cut off by an error"), "{text}");
}
