//! A turn the model provider or the SR2 gateway had no capacity for goes on by itself in the same
//! session (`hub/auto_resume.rs`, reason `capacity`), and the session row says a retry waits.
//! subsession-card's ask, from Leo's "this needs to retry :(" (2026-10-26): five helpers died on
//! "API Error: 503 no non-exhausted claude accounts available" and sat failed.
use super::*;

/// The records of one kind in a session, oldest first.
fn records(hub: &Hub, id: &str, kind: &str) -> Vec<Value> {
    hub.events(id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == kind)
        .map(|e| e.msg)
        .collect()
}

fn row(hub: &Hub, id: &str) -> Value {
    hub.session_summary(&hub.resolve(id).unwrap())
}

/// The session's entry in a session list reply (`session/list` puts the summary under
/// `_meta.acpmux`).
fn listed<'a>(reply: &'a Value, id: &str) -> &'a Value {
    let rows = reply["sessions"].as_array().unwrap();
    let entry = rows.iter().find(|s| s["sessionId"] == id).unwrap();
    entry.pointer("/_meta/acpmux").unwrap_or(entry)
}

async fn cap_fail(c: &mut TestClient, id: &str, prompt_id: &str) -> String {
    let r = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "cap-fail-once: build it"}], "_meta": {"acpmux": {"promptId": prompt_id}}}),
        )
        .await;
    r.unwrap_err()
}

#[tokio::test]
async fn a_503_no_accounts_turn_is_retried_in_the_same_session_and_the_row_shows_it() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![3_000]);
    let id = new_session(&mut c, "capacity").await;
    let err = cap_fail(&mut c, &id, "p-cap").await;
    assert!(err.contains("no non-exhausted claude accounts"), "{err}");
    let agent_session = row(&hub, &id)["agentSessionId"].clone();
    assert!(agent_session.is_string(), "{}", row(&hub, &id));

    let k = until(&hub, &id, |k| k.iter().any(|k| k == "auto_resume_scheduled")).await;
    let scheduled = records(&hub, &id, "auto_resume_scheduled");
    let s = scheduled.first().unwrap_or_else(|| panic!("never scheduled: {k:?}"));
    let cut_turn = records(&hub, &id, "user_message")[0]["turnId"].clone();
    assert_eq!(s["promptId"], "p-cap", "{s}");
    assert_eq!(s["attempt"], 1, "{s}");
    assert_eq!(s["of"], 1, "{s}");
    assert_eq!(s["reason"], "capacity", "{s}");
    assert_eq!(s["turnId"], cut_turn, "{s}");
    let delay = s["delayMs"].as_u64().unwrap();
    assert!((3_000..=3_600).contains(&delay), "{s}");
    let next_at = s["nextAt"].as_u64().unwrap();
    let now = acpmux::store::now_ms();
    assert!(next_at > now && next_at <= now + delay, "{s} now {now}");

    // While it waits, the row says so, the same in both session lists.
    let retry = json!({"attempt": 1, "of": 1, "reason": "capacity", "nextAt": next_at, "promptId": "p-cap", "turnId": cut_turn});
    assert_eq!(row(&hub, &id)["retry"], retry);
    let list = c.request(method::SESSION_LIST, json!({})).await.unwrap();
    assert_eq!(listed(&list, &id)["retry"], retry, "{list}");
    let mux = c.request(method::MUX_SESSIONS, json!({})).await.unwrap();
    assert_eq!(listed(&mux, &id)["retry"], retry, "{mux}");
    assert_eq!(row(&hub, &id)["lastTurn"]["status"], "failed");

    // It fires: the same chat, the same agent session, the next attempt's prompt id.
    let k = until(&hub, &id, |k| k.iter().filter(|k| *k == "turn_result").count() == 2).await;
    let messages = records(&hub, &id, "user_message");
    assert_eq!(messages.len(), 2, "{messages:?} {k:?}");
    assert_eq!(messages[1]["promptId"], "p-cap~resume-1");
    assert_eq!(
        messages[1]["_meta"]["provenance"],
        json!({"kind": "auto_resume", "promptId": "p-cap", "attempt": 1, "turnId": cut_turn})
    );
    let text = messages[1]["text"].as_str().unwrap();
    assert!(text.contains("capacity"), "{text}");
    assert!(text.contains("no non-exhausted claude accounts"), "{text}");
    let after = row(&hub, &id);
    assert_eq!(after["retry"], Value::Null, "{after}");
    assert_eq!(after["lastTurn"]["status"], "completed", "{after}");
    assert_eq!(after["agentSessionId"], agent_session, "{after}");
    assert_eq!(hub.sessions().len(), 1, "no new session");
}

/// Stop clears the waiting retry at once, and its timer ends then, not when its wait would. A
/// watcher hears the row's `retry` come and go.
#[tokio::test]
async fn stop_clears_a_waiting_retry_at_once() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![60_000]);
    let mut w = connect(&hub).await;
    w.request(method::MUX_WATCH, json!({"enabled": true})).await.unwrap();
    let id = new_session(&mut c, "cap-stop").await;
    cap_fail(&mut c, &id, "p-stop").await;
    let changed = w
        .wait_for(method::MUX_SESSION_CHANGED, |p| {
            p["sessionId"] == id && p["kind"] == "auto_resume_scheduled"
        })
        .await;
    assert_eq!(changed["session"]["retry"]["reason"], "capacity", "{changed}");
    assert_eq!(row(&hub, &id)["retry"]["reason"], "capacity", "{}", row(&hub, &id));
    c.request(method::SESSION_CANCEL, json!({"sessionId": id})).await.unwrap();
    assert_eq!(row(&hub, &id)["retry"], Value::Null);
    let changed = w
        .wait_for(method::MUX_SESSION_CHANGED, |p| {
            p["sessionId"] == id && p["kind"] == "auto_resume_skipped"
        })
        .await;
    assert_eq!(changed["session"]["retry"], Value::Null, "{changed}");
    // A minute's wait, skipped within seconds.
    let k = until(&hub, &id, |k| k.iter().any(|k| k == "auto_resume_skipped")).await;
    let skipped = records(&hub, &id, "auto_resume_skipped");
    assert_eq!(skipped.len(), 1, "{k:?}");
    assert_eq!(skipped[0]["skipped"], "stopped");
    assert_eq!(records(&hub, &id, "user_message").len(), 1);
}

/// A prompt sent meanwhile takes the chat: the row stops showing the retry at once, and the
/// waiting retry is skipped when that prompt's turn ends.
#[tokio::test]
async fn a_prompt_sent_meanwhile_clears_the_row() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![60_000]);
    let id = new_session(&mut c, "cap-meanwhile").await;
    cap_fail(&mut c, &id, "p-mean").await;
    until(&hub, &id, |k| k.iter().any(|k| k == "auto_resume_scheduled")).await;
    assert!(row(&hub, &id)["retry"].is_object());
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "never mind"}]}),
    )
    .await
    .unwrap();
    assert_eq!(row(&hub, &id)["retry"], Value::Null);
    // The wait ends with that prompt's turn, not a minute later.
    let k = until(&hub, &id, |k| k.iter().any(|k| k == "auto_resume_skipped")).await;
    let skipped = records(&hub, &id, "auto_resume_skipped");
    assert_eq!(skipped.len(), 1, "{k:?}");
    assert_eq!(skipped[0]["skipped"], "superseded");
    assert_eq!(records(&hub, &id, "user_message").len(), 2);
}

/// An attempt refused before its turn starts (its folder went while it waited, and its agent
/// had exited) is recorded as skipped `refused`, so a watcher sees the row's `retry` go.
#[tokio::test]
async fn an_attempt_refused_before_its_turn_is_skipped_where_watchers_hear_it() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![1_500]);
    let dir = std::env::temp_dir().join(format!("acpmux-cap-refused-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let mut w = connect(&hub).await;
    w.request(method::MUX_WATCH, json!({"enabled": true})).await.unwrap();
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": dir.to_string_lossy(), "mcpServers": [], "_meta": {"acpmux": {"name": "cap-refused"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let r = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "cap-fail-then-exit"}], "_meta": {"acpmux": {"promptId": "p-gone"}}}),
        )
        .await;
    assert!(r.unwrap_err().contains("no non-exhausted"));
    let scheduled = w
        .wait_for(method::MUX_SESSION_CHANGED, |p| {
            p["sessionId"] == id && p["kind"] == "auto_resume_scheduled"
        })
        .await;
    assert_eq!(scheduled["session"]["retry"]["reason"], "capacity", "{scheduled}");
    std::fs::remove_dir_all(&dir).unwrap();
    let skipped = w
        .wait_for(method::MUX_SESSION_CHANGED, |p| {
            p["sessionId"] == id && p["kind"] == "auto_resume_skipped"
        })
        .await;
    assert_eq!(skipped["session"]["retry"], Value::Null, "{skipped}");
    let records = records(&hub, &id, "auto_resume_skipped");
    assert_eq!(records.len(), 1, "{records:?}");
    assert_eq!(records[0]["skipped"], "refused", "{records:?}");
    assert!(records[0]["error"].as_str().unwrap().contains("folder"), "{records:?}");
    assert_eq!(row(&hub, &id)["retry"], Value::Null);
}

/// An agent that dies of a refused request (its last stderr line says 403) is not continued:
/// sending it again would be refused the same way.
#[tokio::test]
async fn an_agent_that_dies_of_a_refused_request_is_not_continued() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![20]);
    let id = new_session(&mut c, "refused-died").await;
    let r = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "die: HTTP 403 permission denied"}]}),
        )
        .await;
    assert!(r.unwrap_err().contains("403"));
    tokio::time::sleep(Duration::from_millis(400)).await;
    let kinds: Vec<String> =
        hub.events(&id, 0, 10_000).unwrap().into_iter().map(|e| e.kind).collect();
    assert!(!kinds.iter().any(|k| k.starts_with("auto_resume")), "{kinds:?}");
    assert_eq!(records(&hub, &id, "user_message").len(), 1);
    assert_eq!(row(&hub, &id)["retry"], Value::Null);
}

/// A wait that resolves at the end of a turn a capacity error cut off answers once that turn's
/// retry is scheduled, so its row says when the next attempt runs: a failed turn never reads as
/// final (gui-push, 2026-10-20: "acpmux wait --print after a turn that failed (capacity) prints
/// the previous turn's reply, not the error, so a failed turn reads as done").
#[tokio::test]
async fn a_wait_that_ends_with_a_cut_turn_answers_with_its_retry() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![60_000]);
    let id = new_session(&mut c, "cap-wait").await;
    let seq0 = row(&hub, &id)["stateSeq"].as_u64().unwrap();
    c.send(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "cap-fail-once: build it"}], "_meta": {"acpmux": {"promptId": "p-wait"}}}),
    )
    .await;
    let w = c
        .request(
            method::MUX_WAIT,
            json!({"sessions": [id.clone()], "afterSeq": {id.clone(): seq0}, "timeoutMs": 10000}),
        )
        .await
        .unwrap();
    assert_eq!(w["timedOut"], false, "{w}");
    let resolved = &w["resolved"][0];
    assert_eq!(resolved["lastTurn"]["status"], "failed", "{w}");
    assert_eq!(resolved["retry"]["reason"], "capacity", "{w}");
    assert_eq!(resolved["retry"]["attempt"], 1, "{w}");
    assert_eq!(resolved["retry"]["promptId"], "p-wait", "{w}");
    // After Stop no retry waits: a wait answers at once, with none.
    c.request(method::SESSION_CANCEL, json!({"sessionId": id})).await.unwrap();
    let w = c
        .request(method::MUX_WAIT, json!({"sessions": [id.clone()], "timeoutMs": 3000}))
        .await
        .unwrap();
    assert_eq!(w["timedOut"], false, "{w}");
    assert_eq!(w["resolved"][0]["retry"], Value::Null, "{w}");
}

/// No row of a chat whose turn a capacity error cut off reads that turn as settled without its
/// retry: from the turn's end until the retry's wait is set, the row says `retryDeciding`, read
/// in one step with `retry` (Codex review: a row read between the two showed neither).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn no_row_of_a_cut_turn_reads_settled_before_its_retry_is_set() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![60_000]);
    let id = new_session(&mut c, "cap-rows").await;
    let session = hub.resolve(&id).unwrap();
    let reader = {
        let hub = hub.clone();
        tokio::spawn(async move {
            let mut bad = Vec::new();
            let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
            while tokio::time::Instant::now() < deadline {
                let row = hub.session_summary(&session);
                if row["retry"].is_object() {
                    return (bad, row);
                }
                let settled = row["lastTurn"]["status"] == "failed"
                    && row["turn"].is_null()
                    && row["retryDeciding"] != true;
                if settled {
                    bad.push(row);
                }
                tokio::task::yield_now().await;
            }
            (bad, Value::Null)
        })
    };
    cap_fail(&mut c, &id, "p-rows").await;
    let (bad, retried) = reader.await.unwrap();
    assert!(retried["retry"].is_object(), "the retry was never set");
    assert_eq!(retried["retryDeciding"], Value::Null, "{retried}");
    assert!(
        bad.is_empty(),
        "{} rows read the cut turn as settled with no retry: {}",
        bad.len(),
        bad[0]
    );
}

/// A cut turn that gets no retry (here automatic retries are off) records that decision, so
/// a watcher, and a peer that keeps the chat's row, hears the row stop saying `retryDeciding`
/// (Codex review, round 2: a peer's row kept saying it, and each wait there held for it).
#[tokio::test]
async fn a_cut_turn_with_no_retry_records_the_decision_for_watchers() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![]);
    let mut w = connect(&hub).await;
    w.request(method::MUX_WATCH, json!({"enabled": true})).await.unwrap();
    let id = new_session(&mut c, "cap-off").await;
    cap_fail(&mut c, &id, "p-off").await;
    let settled = w
        .wait_for(method::MUX_SESSION_CHANGED, |p| {
            p["sessionId"] == id && p["kind"] == "auto_resume_settled"
        })
        .await;
    let row = &settled["session"];
    assert_eq!(row["lastTurn"]["status"], "failed", "{settled}");
    assert_eq!(row["retry"], Value::Null, "{settled}");
    assert_eq!(row["retryDeciding"], Value::Null, "{settled}");
    let decided = records(&hub, &id, "auto_resume_settled");
    assert_eq!(decided.len(), 1, "{decided:?}");
    assert_eq!(decided[0]["why"], "off", "{decided:?}");
    assert_eq!(decided[0]["turnId"], row["lastTurn"]["turnId"], "{decided:?}");
    // A turn that failed on another error, or ended well, records none.
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "fine now"}]}),
    )
    .await
    .unwrap();
    assert_eq!(records(&hub, &id, "auto_resume_settled").len(), 1);
}

/// Stop on a chat whose cut turn's retry waits records that decision too, so a peer that keeps
/// the row hears it settle: an idle Stop records nothing else (Codex review, round 3).
#[tokio::test]
async fn stop_records_the_decision_for_a_retry_that_waited() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![60_000]);
    let mut w = connect(&hub).await;
    w.request(method::MUX_WATCH, json!({"enabled": true})).await.unwrap();
    let id = new_session(&mut c, "cap-stop-settle").await;
    cap_fail(&mut c, &id, "p-stop-settle").await;
    until(&hub, &id, |k| k.iter().any(|k| k == "auto_resume_scheduled")).await;
    c.request(method::SESSION_CANCEL, json!({"sessionId": id})).await.unwrap();
    let settled = w
        .wait_for(method::MUX_SESSION_CHANGED, |p| {
            p["sessionId"] == id && p["kind"] == "auto_resume_settled"
        })
        .await;
    assert_eq!(settled["session"]["retry"], Value::Null, "{settled}");
    assert_eq!(settled["session"]["retryDeciding"], Value::Null, "{settled}");
    let decided = records(&hub, &id, "auto_resume_settled");
    assert_eq!(decided.len(), 1, "{decided:?}");
    assert_eq!(decided[0]["why"], "stopped", "{decided:?}");
}
