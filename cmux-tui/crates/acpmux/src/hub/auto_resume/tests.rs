use super::*;

struct FailingPromptStopStore {
    inner: Box<dyn crate::store::Store>,
    failure: Arc<std::sync::atomic::AtomicU8>,
}

impl crate::store::Store for FailingPromptStopStore {
    fn list(&self) -> anyhow::Result<Vec<crate::store::SessionMeta>> {
        self.inner.list()
    }
    fn load(&self, id: &str) -> anyhow::Result<Option<crate::store::SessionMeta>> {
        self.inner.load(id)
    }
    fn save(&self, meta: &crate::store::SessionMeta) -> anyhow::Result<()> {
        self.inner.save(meta)
    }
    fn append(&self, id: &str, record: &EventRecord) -> anyhow::Result<()> {
        anyhow::ensure!(
            record.kind != "prompt_stop_requested"
                || self.failure.load(std::sync::atomic::Ordering::SeqCst) != 1,
            "injected prompt stop append failure"
        );
        self.inner.append(id, record)
    }
    fn flush_session(&self, id: &str) -> anyhow::Result<()> {
        anyhow::ensure!(
            self.failure.load(std::sync::atomic::Ordering::SeqCst) != 2,
            "injected prompt stop flush failure"
        );
        self.inner.flush_session(id)
    }
    fn events(&self, id: &str, after: u64, limit: usize) -> anyhow::Result<Vec<EventRecord>> {
        self.inner.events(id, after, limit)
    }
    fn delete(&self, id: &str) -> anyhow::Result<()> {
        self.inner.delete(id)
    }
}

#[test]
fn exact_prompt_stop_reports_failed_persistence_and_retries_before_acknowledging() {
    use std::sync::atomic::{AtomicU8, Ordering};
    for failed_operation in [1, 2] {
        let mut config = crate::config::Config::default();
        config.store.mode = crate::config::StoreMode::Memory;
        let inner = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
        let failure = Arc::new(AtomicU8::new(failed_operation));
        let store = FailingPromptStopStore { inner, failure: failure.clone() };
        let meta = serde_json::from_value(json!({
            "schema":crate::store::META_SCHEMA,"id":"failed-stop","name":"Failed stop",
            "harness":"fake","cwd":"/tmp","status":"closed","createdAt":1,"updatedAt":1
        }))
        .unwrap();
        crate::store::Store::save(&store, &meta).unwrap();
        let hub = Hub::new(config, Box::new(store));
        let session = hub.resolve("failed-stop").unwrap();
        session.auto_resume.lock().replace(Mark::Ending("workflow-turn".into()));
        for _ in 0..2 {
            assert!(
                hub.stop_prompt_retry(&session, "workflow").is_err(),
                "stop acknowledged despite failing persistence operation {failed_operation}"
            );
            assert!(matches!(session.auto_resume.lock().as_ref(),
                    Some(Mark::Ending(turn)) if turn == "workflow-turn"));
        }
        failure.store(0, Ordering::SeqCst);
        hub.stop_prompt_retry(&session, "workflow").unwrap();
        hub.clear_prompt_stop_cache_for_test(&session);
        let turn = TurnInfo::prompted(
            "workflow",
            "late retry",
            "retry-turn",
            "workflow~resume-1",
            Control::Local,
        );
        assert!(
            hub.start_turn(&session, None, false, false, turn).is_err(),
            "the acknowledged stop was not recovered from its journal"
        );
    }
}

fn retry_chat() -> (Arc<Hub>, Arc<Session>) {
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let meta=serde_json::from_value(json!({"schema":crate::store::META_SCHEMA,"id":"retry-child",
            "name":"Retry child","harness":"fake","cwd":"/tmp","status":"closed","createdAt":1,"updatedAt":1})).unwrap();
    store.save(&meta).unwrap();
    let hub = Hub::new(config, store);
    let session = hub.resolve("retry-child").unwrap();
    (hub, session)
}

#[tokio::test]
async fn exact_prompt_stop_fences_waiting_and_late_retry_without_touching_person() {
    let (hub, session) = retry_chat();
    hub.append(&session,"mux","turn_result",json!({"promptId":"workflow","turnId":"workflow-turn","status":"failed","errorText":"HTTP 503"}));
    for mark in [
        Mark::Ending("workflow-turn".into()),
        Mark::Waiting {
            turn: "workflow-turn".into(),
            retry: Some(retry("workflow-turn")),
            _wake: Wake(Arc::new(Notify::new())),
        },
    ] {
        session.auto_resume.lock().replace(mark);
        assert_eq!(hub.stop_prompt_retry(&session, "workflow").unwrap(), None);
        assert!(hub.stopped_for_test(&session, "workflow-turn"));
        assert!(hub.fire_pending(&session, "workflow-turn").is_err());
        hub.schedule_auto_resume(
            &session,
            "workflow-turn",
            Some(CutTurn {
                from: None,
                prompt_id: "workflow",
                turn_id: "workflow-turn",
                control: Control::Local,
                trust_gate: false,
                error: "HTTP 503",
                not_before: None,
            }),
        );
        assert!(
            session.auto_resume.lock().is_none(),
            "late terminal scheduling must not re-arm retry"
        );
    }
    let person =
        TurnInfo::prompted("person", "next", "person-turn", "person-prompt", Control::Local);
    *session.turn.lock().unwrap() = Some(person);
    session.auto_resume.lock().replace(Mark::Ending("person-turn".into()));
    hub.cancel_prompt(&session, "workflow").await.unwrap();
    assert_eq!(session.turn().unwrap().prompt_id, "person-prompt");
    assert!(
        matches!(session.auto_resume.lock().as_ref(),Some(Mark::Ending(turn)) if turn=="person-turn")
    );
}

#[tokio::test]
async fn exact_prompt_stop_returns_only_its_running_retry_descendant() {
    let (hub, session) = retry_chat();
    let running = TurnInfo::prompted(
        "auto_resume",
        "continue",
        "retry-turn",
        "workflow~resume-2",
        Control::Local,
    );
    *session.turn.lock().unwrap() = Some(running);
    assert_eq!(
        hub.stop_prompt_retry(&session, "workflow").unwrap().as_deref(),
        Some("workflow~resume-2")
    );
    assert!(hub.stopped_for_test(&session, "retry-turn"));
}

fn retry(turn: &str) -> RetrySummary {
    RetrySummary {
        attempt: 1,
        of: 4,
        reason: RetryReason::Capacity,
        next_at: 9,
        prompt_id: "p".into(),
        turn_id: turn.into(),
    }
}

/// Stop settles a turn whose retry is being decided or waits, with or without its time:
/// with retries off, nothing else records that decision (Codex review, round 3).
#[test]
fn stop_settles_an_ending_or_waiting_turn() {
    let wake = || Wake(Arc::new(Notify::new()));
    let unset = Mark::Waiting { turn: "t1".into(), retry: None, _wake: wake() };
    assert_eq!(settled_by_stop(Some(&unset)).as_deref(), Some("t1"));
    let set = Mark::Waiting { turn: "t1".into(), retry: Some(retry("t1")), _wake: wake() };
    assert_eq!(settled_by_stop(Some(&set)).as_deref(), Some("t1"));
    assert_eq!(settled_by_stop(Some(&Mark::Ending("t1".into()))).as_deref(), Some("t1"));
    for mark in [Mark::Firing("t1".into()), Mark::Stopped("t1".into()), Mark::Stopping("t1".into())]
    {
        assert_eq!(settled_by_stop(Some(&mark)), None);
    }
    assert_eq!(settled_by_stop(None), None);
}

/// A row reads its chat's mark again when the retry it read is gone by the time it checks
/// it (the retry fired and its turn started meanwhile), so it shows that retry's decision,
/// never neither (Codex review, round 2).
#[test]
fn a_row_reads_the_mark_again_when_its_retry_moved_on() {
    let mut reads = vec![(None, true), (Some(("t1".to_owned(), retry("t1"))), false)];
    let row = settled_retry_row(|| reads.pop().unwrap(), |_| false);
    assert_eq!(row, (None, true), "the retry started: it is being decided");
    let row = settled_retry_row(|| (Some(("t1".to_owned(), retry("t1"))), false), |t| t == "t1");
    assert_eq!(row, (Some(retry("t1")), false));
    // Superseded every time (a person's prompt took the chat): no retry, nothing deciding.
    let mut count = 0;
    let row = settled_retry_row(
        || {
            count += 1;
            (Some(("t1".to_owned(), retry("t1"))), false)
        },
        |_| false,
    );
    assert_eq!((row, count), ((None, false), ROW_READS));
    assert_eq!(settled_retry_row(|| (None, true), |_| unreachable!()), (None, true));
}

#[test]
fn the_configured_waits_say_how_many_attempts_run() {
    assert_eq!(configured_attempts(None), DEFAULT_DELAYS_MS.len());
    assert_eq!(configured_attempts(Some(&vec![])), 0);
    assert_eq!(configured_attempts(Some(&vec![1_000])), 1);
    assert_eq!(configured_attempts(Some(&vec![1_000; 9])), 9);
    // The ceiling bounds what a configured loop may set, never the default.
    assert!(DEFAULT_DELAYS_MS.len() <= MAX_CONFIGURED_ATTEMPTS);
    assert_eq!(
        checked_delays(&json!(vec![1000; MAX_CONFIGURED_ATTEMPTS + 1])).unwrap().len(),
        MAX_CONFIGURED_ATTEMPTS
    );
}

#[test]
fn attempts_are_counted_from_the_prompt_id() {
    assert_eq!(split_attempt("p1"), ("p1", 0));
    assert_eq!(split_attempt("p1~resume-1"), ("p1", 1));
    assert_eq!(split_attempt("p1~resume-3"), ("p1", 3));
    assert_eq!(split_attempt("~resume-2"), ("~resume-2", 0));
    assert_eq!(split_attempt("p1~resume-x"), ("p1~resume-x", 0));
}

#[test]
fn configured_waits_are_checked() {
    assert_eq!(checked_delays(&json!([])), Some(vec![]));
    assert_eq!(checked_delays(&json!([5000, 60000])), Some(vec![5000, 60000]));
    assert_eq!(checked_delays(&json!([0, 99_999_999])), Some(vec![1_000, 3_600_000]));
    // A loop longer than the default's four is kept: the key configures the whole loop.
    assert_eq!(checked_delays(&json!(vec![1000; 5])).unwrap().len(), 5);
    assert_eq!(checked_delays(&json!(vec![1000; 12])).unwrap().len(), 12);
    assert_eq!(checked_delays(&json!([1000, -5])), None);
    assert_eq!(checked_delays(&json!([1.5])), None);
    assert_eq!(checked_delays(&json!("10s")), None);
    assert_eq!(staggered(u64::MAX, "s"), u64::MAX);
}
