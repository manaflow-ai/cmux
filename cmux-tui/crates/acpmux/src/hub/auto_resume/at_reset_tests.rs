use super::*;
use crate::protocol::session::ResumeAtResetState;

fn chat(id: &str) -> (Arc<Hub>, Arc<Session>) {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let meta = json!({"schema": crate::store::META_SCHEMA, "id": id,
            "name": id, "harness": "claude", "cwd": "/tmp", "status": "idle",
            "createdAt": 1, "updatedAt": 2});
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    let hub = Hub::new(cfg, store);
    hub.begin_startup(false);
    let session = hub.resolve(id).unwrap();
    (hub, session)
}

/// The chat's last turn failed on the usage limit; `reset_in_s` is the reset its error reports,
/// none when it reports none.
fn limited(hub: &Hub, session: &Session, reset_in_s: Option<u64>) {
    let error = match reset_in_s {
        Some(s) => format!("usage limit|{}", now_ms() / 1000 + s),
        None => "You've hit your usage limit".to_owned(),
    };
    hub.append(
        session,
        "mux",
        "turn_started",
        json!({"turnId": "cut", "promptId": "p1", "control": "local", "trustGate": false}),
    );
    let result = json!({"turnId": "cut", "promptId": "p1", "status": "failed", "errorText": error});
    hub.append_unknown_outcome(session, result);
}

fn by() -> RetryBy {
    RetryBy { control: Control::Local, trust_gate: false, full_access_device: None, from: None }
}

fn records(hub: &Hub, session: &Session) -> Vec<Value> {
    let mut out = Vec::new();
    let _ = hub.store.scan_kinds(&session.id, &[RECORD], &mut |e: EventRecord| {
        out.push(e.msg);
        true
    });
    out
}

fn row(hub: &Hub, session: &Session) -> Option<ResumeAtReset> {
    hub.resume_at_reset_row(session, &session.meta())
}

async fn until(mut done: impl FnMut() -> bool) {
    for _ in 0..100 {
        if done() {
            return;
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    panic!("not reached in 10 s");
}

fn reason(e: &RpcError) -> Option<String> {
    e.data.as_ref()?.get("reason")?.as_str().map(str::to_owned)
}

/// No reported reset: the row offers no countdown, and arming is refused, so the person
/// retries by hand.
#[tokio::test]
async fn an_unknown_reset_offers_a_manual_retry_and_no_countdown() {
    let (hub, session) = chat("unknown-reset");
    limited(&hub, &session, None);
    let offered = row(&hub, &session).unwrap();
    assert_eq!(offered.state, ResumeAtResetState::UnknownReset);
    assert_eq!(offered.resets_at, None);
    let e = hub.resume_at_reset(&session, by(), false).await.unwrap_err();
    assert_eq!(reason(&e).as_deref(), Some("retry.at_reset.unknown_reset"));
    assert!(records(&hub, &session).is_empty());
}

/// A failure that is not the usage limit is not offered.
#[tokio::test]
async fn only_a_usage_limited_failure_is_offered() {
    let (hub, session) = chat("not-limited");
    hub.append_unknown_outcome(
        &session,
        json!({"turnId": "cut", "promptId": "p1", "status": "failed", "errorText": "stream disconnected"}),
    );
    assert_eq!(row(&hub, &session), None);
    let e = hub.resume_at_reset(&session, by(), false).await.unwrap_err();
    assert_eq!(reason(&e).as_deref(), Some("retry.at_reset.not_rate_limited"));
}

/// Armed, bound to the failed turn and the attempt it sends; arming again is the same one;
/// the person's cancel records it and clears the row back to offered.
#[tokio::test]
async fn arming_is_bound_to_the_failed_turn_and_the_person_cancels_it() {
    let (hub, session) = chat("arm-cancel");
    limited(&hub, &session, Some(3600));
    assert_eq!(row(&hub, &session).unwrap().state, ResumeAtResetState::Offered);
    let armed = hub.resume_at_reset(&session, by(), false).await.unwrap();
    assert_eq!(armed["kind"], "at_reset");
    assert_eq!(armed["promptId"], "p1~resume-1");
    assert_eq!(armed["turnId"], "cut");
    let again = hub.resume_at_reset(&session, by(), false).await.unwrap();
    assert_eq!(again["promptId"], "p1~resume-1");
    let shown = row(&hub, &session).unwrap();
    assert_eq!(shown.state, ResumeAtResetState::Armed);
    assert_eq!(shown.turn_id, "cut");
    let logged = records(&hub, &session);
    assert_eq!(logged.len(), 1, "{logged:?}");
    assert_eq!(logged[0]["state"], "armed");
    assert_eq!(logged[0]["failedPromptId"], "p1");
    let cancelled = hub.resume_at_reset(&session, by(), true).await.unwrap();
    assert_eq!(cancelled["cancelled"], true);
    let logged = records(&hub, &session);
    assert_eq!(logged[1]["state"], "cancelled");
    assert_eq!(logged[1]["why"], "person");
    assert_eq!(row(&hub, &session).unwrap().state, ResumeAtResetState::Offered);
    let e = hub.resume_at_reset(&session, by(), true).await.unwrap_err();
    assert_eq!(reason(&e).as_deref(), Some("retry.at_reset.not_armed"));
}

/// Another run ending in the chat supersedes an armed resume: it is cancelled, never sent.
#[tokio::test]
async fn a_later_run_cancels_the_armed_resume() {
    let (hub, session) = chat("superseded");
    limited(&hub, &session, Some(3600));
    hub.resume_at_reset(&session, by(), false).await.unwrap();
    hub.append_unknown_outcome(
        &session,
        json!({"turnId": "later", "promptId": "p2", "status": "completed"}),
    );
    until(|| records(&hub, &session).len() == 2).await;
    let logged = records(&hub, &session);
    assert_eq!(logged[1]["state"], "cancelled", "{logged:?}");
    assert_eq!(logged[1]["why"], "superseded");
    assert_eq!(row(&hub, &session), None);
}

/// Archive cancels it, and an archived chat is not offered one.
#[tokio::test]
async fn archive_cancels_the_armed_resume() {
    let (hub, session) = chat("archived");
    limited(&hub, &session, Some(3600));
    hub.resume_at_reset(&session, by(), false).await.unwrap();
    hub.set_archived(&session, true, false).unwrap();
    until(|| records(&hub, &session).len() == 2).await;
    assert_eq!(records(&hub, &session)[1]["why"], "archived");
    assert_eq!(row(&hub, &session), None);
}

/// At the reset it sends once: `fired` is recorded first, the slot is empty, and a restart
/// after it never arms it again.
#[tokio::test]
async fn it_fires_once_at_the_reset_and_a_restart_never_arms_it_again() {
    let (hub, session) = chat("fires");
    limited(&hub, &session, Some(1));
    hub.resume_at_reset(&session, by(), false).await.unwrap();
    until(|| records(&hub, &session).iter().any(|r| r["state"] == "fired")).await;
    let fired = records(&hub, &session).iter().filter(|r| r["state"] == "fired").count();
    assert_eq!(fired, 1);
    assert!(session.resume_at_reset.lock().unwrap().is_none());
    hub.restore_resume_at_reset(&session);
    assert!(session.resume_at_reset.lock().unwrap().is_none(), "a fired resume was armed again");
}

/// A restart restores what the log says is armed, at its recorded reset.
#[tokio::test]
async fn a_restart_restores_the_armed_resume() {
    let (hub, session) = chat("restored");
    limited(&hub, &session, Some(3600));
    hub.resume_at_reset(&session, by(), false).await.unwrap();
    let resets_at = records(&hub, &session)[0]["resetsAt"].as_u64();
    // What a new daemon's session starts with: nothing armed in memory.
    *session.resume_at_reset.lock().unwrap() = None;
    hub.restore_resume_at_reset(&session);
    let shown = row(&hub, &session).unwrap();
    assert_eq!(shown.state, ResumeAtResetState::Armed);
    assert_eq!(shown.resets_at, resets_at);
    // A cancel since is final.
    hub.resume_at_reset(&session, by(), true).await.unwrap();
    hub.restore_resume_at_reset(&session);
    assert!(session.resume_at_reset.lock().unwrap().is_none());
}
