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
