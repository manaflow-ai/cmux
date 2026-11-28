//! Cold batch restart regression: compact -> warm usage -> restart -> original deadline.

use super::*;

/// Validation alone missed the bridge's explicit gather bit being lost before admission.
/// Exercise admission and the journal replay used after restart, without an urgent flush.
#[tokio::test]
async fn explicit_gather_fyi_compacts_then_restarts_at_the_original_cold_deadline() {
    let knobs = super::super::cold_wake::Knobs {
        enabled: true,
        compact: false,
        compact_above: super::super::cold_wake::DEFAULT_COMPACT_ABOVE_TOKENS,
    };
    super::super::cold_wake::KNOBS_FOR_TEST.with(|k| k.set(Some(knobs)));
    let (hub, session) = hub_with_chat("gather-fyi-restart");
    let now = now_ms();
    {
        let mut meta = session.meta.lock().unwrap();
        meta.usage = Some(json!({"used": 200_000, "size": 1_000_000,
            "_meta": {"acpmux": {"cacheExpiresAt": now - 40 * 60_000}}}));
        meta.last_turn = Some(json!({"turnId": "previous", "endedAt": now - 45 * 60_000}));
    }
    for (id, sender) in [("gather-slack", "slack-listen"), ("gather-forum", "agent-forum")] {
        let blocks = [json!({"type": "text", "text": id})];
        let mut provenance = crate::prompt_provenance::named_sender(sender, &session.id);
        provenance.set(super::super::cold_wake::GATHER_META, json!(true));
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        let mut accept = |notice| tx.send(notice).unwrap();
        let prompt = hub.inbox_accept(
            &session,
            &blocks,
            "test",
            id,
            sender,
            PromptClass::Fyi,
            None,
            Some(&provenance),
            false,
            false,
            None,
            &mut accept,
        );
        tokio::pin!(prompt);
        tokio::select! {
            result = &mut prompt => panic!("finished before acceptance: {result:?}"),
            ack = tokio::time::timeout(std::time::Duration::from_secs(2), rx.recv()) => {
                assert_eq!(ack.expect("bounded acceptance").expect("accepted")["promptId"], id);
            }
        }
    }
    assert_eq!(session.inbox().items.len(), 2);
    assert!(session.inbox().items.iter().all(|i| i.gather));
    assert!(!tried(&session));
    let original_due = session.cold_batch.lock().unwrap().unwrap().due;
    assert_eq!(hub.store.load(&session.id).unwrap().unwrap().cold_batch_due, Some(original_due));
    // The missing combination: the batch's own /compact completes, warming usage below
    // MIN_BATCH_TOKENS, and the daemon restarts before the original deadline.
    let compact_prompt = format!("{}restart", super::super::cold_wake::COMPACT_ID_PREFIX);
    *session.turn.lock().unwrap() = Some(TurnInfo::prompted(
        "test",
        "/compact",
        "compact-turn",
        &compact_prompt,
        Control::Local,
    ));
    hub.cold_batch_turn_started(&session);
    assert_eq!(hub.store.load(&session.id).unwrap().unwrap().cold_batch_due, Some(original_due));
    *session.turn.lock().unwrap() = None;
    {
        let mut meta = session.meta.lock().unwrap();
        meta.usage = Some(json!({"used": 10_000, "size": 200_000}));
        meta.last_turn = Some(json!({"turnId": "compact-turn", "endedAt": now_ms()}));
    }
    hub.save_meta(&session);
    assert!(super::super::cold_wake::coldness(&session.meta(), now_ms()).is_none());
    // Recreate the Session from what the store saved, with no volatile state surviving.
    if let Some(timer) = session.inbox().timer.take() {
        timer.abort();
    }
    let stored = hub.store.load(&session.id).unwrap().unwrap();
    let stored = serde_json::from_value(serde_json::to_value(stored).unwrap()).unwrap();
    let session = hub.make_session(stored);
    hub.sessions.lock().unwrap().insert(session.id.clone(), session.clone());
    hub.restore_inbox(&session);
    assert_eq!(session.inbox().items.len(), 2);
    assert!(session.inbox().items.iter().all(|i| i.gather), "journal keeps gather");
    hub.inbox_review(&session);
    let due = session.cold_batch.lock().unwrap().expect("restored batch keeps its deadline").due;
    assert_eq!(due, original_due, "compaction and restart cannot reopen the window");
    assert!(session.inbox().timer.is_some());
    assert!(!tried(&session), "nothing wakes inside the batch");
    // The timer invokes inbox_review; move its deadline, without sleeping or an urgent input.
    session.cold_batch.lock().unwrap().as_mut().unwrap().due = now_ms().saturating_sub(1);
    hub.inbox_review(&session);
    assert_eq!(carried(&session), Some(vec!["gather-forum".into(), "gather-slack".into()]));
    hub.inbox_review(&session);
    assert_eq!(carried(&session).map(|ids| ids.len()), Some(2), "one notice owns both");
    super::super::cold_wake::KNOBS_FOR_TEST.with(|k| k.set(None));
}

fn restart_saved(hub: &Hub, session: &Session) -> Arc<Session> {
    let saved = hub.store.load(&session.id).unwrap().unwrap();
    hub.make_session(serde_json::from_value(serde_json::to_value(saved).unwrap()).unwrap())
}

fn open_cold_batch(hub: &Arc<Hub>, session: &Arc<Session>) -> u64 {
    super::super::cold_wake::KNOBS_FOR_TEST.with(|k| {
        k.set(Some(super::super::cold_wake::Knobs {
            enabled: true,
            compact: false,
            compact_above: super::super::cold_wake::DEFAULT_COMPACT_ABOVE_TOKENS,
        }))
    });
    let now = now_ms();
    {
        let mut meta = session.meta.lock().unwrap();
        meta.usage = Some(json!({"used": 120_000}));
        meta.last_turn = Some(json!({"endedAt": now - 40 * 60_000}));
    }
    hub.cold_batch_due(session, &session.meta(), now).expect("cold batch opens")
}

#[tokio::test]
async fn cold_batch_restart_preserves_expiry_boundary_and_clears_stale_deadline() {
    let (hub, session) = hub_with_chat("cold-batch-expiry");
    let due = open_cold_batch(&hub, &session);
    session.meta.lock().unwrap().usage = Some(json!({"used": 10_000}));
    hub.save_meta(&session);
    let session = restart_saved(&hub, &session);
    let boundary = due + super::super::cold_wake::MAX_WINDOW_MS;
    assert_eq!(hub.cold_batch_due(&session, &session.meta(), boundary), Some(due));
    assert_eq!(hub.cold_batch_due(&session, &session.meta(), boundary + 1), None);
    assert_eq!(hub.store.load(&session.id).unwrap().unwrap().cold_batch_due, None);
    let session = restart_saved(&hub, &session);
    assert!(session.cold_batch.lock().unwrap().is_none(), "stale clear survives restart");
    assert_eq!(hub.cold_batch_due(&session, &session.meta(), boundary + 2), None);
    super::super::cold_wake::KNOBS_FOR_TEST.with(|k| k.set(None));
}

#[tokio::test]
async fn cold_batch_consumption_is_saved_before_prompt_and_does_not_resurrect() {
    let (hub, session) = hub_with_chat("cold-batch-consumed");
    let due = open_cold_batch(&hub, &session);
    let session = restart_saved(&hub, &session);
    // Turning the feature off does not cancel an already open batch, as before this fix.
    super::super::cold_wake::KNOBS_FOR_TEST.with(|k| {
        k.set(Some(super::super::cold_wake::Knobs {
            enabled: false,
            compact: false,
            compact_above: super::super::cold_wake::DEFAULT_COMPACT_ABOVE_TOKENS,
        }))
    });
    assert_eq!(hub.cold_batch_due(&session, &session.meta(), now_ms()), Some(due));
    *session.turn.lock().unwrap() = Some(TurnInfo::prompted(
        "test",
        "person or urgent prompt",
        "ordinary-turn",
        "ordinary-prompt",
        Control::Local,
    ));
    // This hook runs after start_turn but before the prompt is written. No prompt/end save
    // follows in the test: its own clear must already be durable at this crash point.
    hub.inbox_turn_started(&session);
    assert!(session.cold_batch_turn.load(Ordering::SeqCst));
    assert_eq!(hub.store.load(&session.id).unwrap().unwrap().cold_batch_due, None);
    let session = restart_saved(&hub, &session);
    assert!(session.cold_batch.lock().unwrap().is_none());
    assert_eq!(hub.cold_batch_due(&session, &session.meta(), now_ms()), None, "off opens no batch");
    super::super::cold_wake::KNOBS_FOR_TEST.with(|k| k.set(None));
}

#[tokio::test]
async fn cold_batch_first_urgent_turn_after_restart_clears_before_inbox_review() {
    let (hub, session) = hub_with_chat("cold-batch-first-urgent");
    open_cold_batch(&hub, &session);
    let session = restart_saved(&hub, &session);
    assert!(session.cold_batch.lock().unwrap().is_none(), "not hydrated yet");
    *session.turn.lock().unwrap() = Some(TurnInfo::prompted(
        "test",
        "urgent prompt",
        "urgent-turn",
        "urgent-prompt",
        Control::Local,
    ));
    hub.inbox_turn_started(&session);
    assert!(session.cold_batch_turn.load(Ordering::SeqCst));
    assert_eq!(hub.store.load(&session.id).unwrap().unwrap().cold_batch_due, None);
    let session = restart_saved(&hub, &session);
    assert_eq!(session.meta().cold_batch_due, None, "consumed deadline stays cleared");
    super::super::cold_wake::KNOBS_FOR_TEST.with(|k| k.set(None));
}
