//! Default-off, local, log-only stalled-goal review. No harness is prompted and no model is
//! called. One receipt per session bounds deduplication independently of transcript length.
//! The journal is authoritative evidence; its metadata receipt is an at-least-once checkpoint
//! (a crash between append and save can repeat a note, but can never send an intervention).

use super::*;
use crate::goal::GoalStatus;
use crate::store::ShadowReviewReceipt;
use sha2::{Digest, Sha256};
use std::time::Duration;

const PERIOD: Duration = Duration::from_secs(15 * 60);
const MIN_GAP_MS: u64 = 60 * 60 * 1000;
const KIND: &str = "shadow_review";

fn enabled(doc: &Value) -> bool {
    crate::user_settings::value(doc, "labs.shadowReview").and_then(Value::as_bool) == Some(true)
}

fn saved_enabled() -> bool {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => enabled(&doc),
        _ => false,
    }
}

fn snapshot(goal: &crate::goal::GoalState, target: &str) -> Option<(String, Value)> {
    if !matches!(goal.status, GoalStatus::Stalled | GoalStatus::Blocked)
        || goal.objective.trim().is_empty()
    {
        return None;
    }
    // Observation time, session log activity and accumulated elapsed time are not progress.
    // Including them would make the review itself trigger another review on the next pass.
    let state = json!({"target": target, "question": "stalled-goal", "goal": {
        "objective": goal.objective, "status": goal.status,
        "createdAt": goal.created_at, "updatedAt": goal.updated_at,
        "note": goal.extra.get("note"),
    }});
    let hash = format!("{:x}", Sha256::digest(state.to_string().as_bytes()));
    Some((hash, state))
}

fn due(previous: Option<&ShadowReviewReceipt>, hash: &str, now: u64) -> bool {
    previous.is_none_or(|p| p.snapshot_hash != hash && now.saturating_sub(p.at) >= MIN_GAP_MS)
}

impl Hub {
    /// No timer or transcript reads while off. The existing settings watcher wakes this task.
    pub(crate) async fn shadow_review_loop(hub: std::sync::Weak<Hub>) {
        let Some(mut settings) = hub.upgrade().map(|h| h.settings_changes.subscribe()) else {
            return;
        };
        loop {
            settings.borrow_and_update();
            let on = tokio::task::spawn_blocking(saved_enabled).await.unwrap_or(false);
            if on {
                let Some(h) = hub.upgrade() else { return };
                if h.shutting_down() {
                    return;
                }
                if h.startup_settled() {
                    let changes = settings.clone();
                    let _ = tokio::task::spawn_blocking(move || {
                        for session in h.live_session_handles() {
                            if h.shutting_down() || changes.has_changed().unwrap_or(true) {
                                break;
                            }
                            h.shadow_review(&session, crate::store::now_ms());
                        }
                    })
                    .await;
                }
            }
            if on {
                tokio::select! {
                    _ = tokio::time::sleep(PERIOD) => {},
                    result = settings.changed() => if result.is_err() { return },
                }
            } else if settings.changed().await.is_err() {
                return;
            }
        }
    }

    fn shadow_review(&self, session: &Session, observed_at: u64) {
        if session.turn_claimed()
            || session.turn().is_some()
            || session.queued() != 0
            || session.has_pending_permissions()
            || session.protected_hold.load(Ordering::SeqCst)
        {
            return;
        }
        let candidate = session.read_meta(|m| {
            if matches!(
                m.status,
                SessionStatus::Closed | SessionStatus::Running | SessionStatus::Waiting
            ) {
                return None;
            }
            let goal = m.goal.as_ref()?;
            let (hash, state) = snapshot(goal, &session.id)?;
            due(m.shadow_review.as_ref(), &hash, observed_at)
                .then(|| (hash, state, goal.objective.clone(), m.updated_at))
        });
        let Some((hash, state, objective, updated_at)) = candidate else { return };
        let (record, stored) = self.append_logged(
            session,
            "mux",
            KIND,
            json!({
                "version": 1, "mode": "log-only", "result": "not-sent",
                "snapshotHash": hash, "snapshot": state, "target": session.id,
                "observedAt": observed_at, "text": objective,
                "brief": format!("Inspect the current blocker for this goal and record the smallest supported recovery: {objective}"),
                "stopCondition": "Record one recovery result or an evidenced dependency with its owner and next action.",
                "evidence": {"goalStatus": state["goal"]["status"], "queuedPrompts": 0,
                    "activeTurns": 0, "sessionUpdatedAt": updated_at,
                    "sinceSessionUpdateMs": observed_at.saturating_sub(updated_at),
                    "reviewPeriodMs": PERIOD.as_millis() as u64},
            }),
            None,
        );
        if stored {
            session.meta.lock().unwrap_or_else(|e| e.into_inner()).shadow_review =
                Some(ShadowReviewReceipt { snapshot_hash: hash, at: observed_at, seq: record.seq });
            self.save_meta(session);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> (Arc<Hub>, Arc<Session>) {
        let mut config = Config::default();
        config.store.mode = crate::config::StoreMode::Memory;
        let store = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
        let hub = Hub::new(config, store);
        let meta: SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "shadow-test", "name": "review",
            "harness": "pi", "cwd": "/tmp", "status": "idle", "createdAt": 1,
            "updatedAt": 1, "goal": {"objective": "Repair the fixture", "status": "blocked"}
        }))
        .unwrap();
        hub.store.save(&meta).unwrap();
        let session = hub.make_session(meta);
        (hub, session)
    }

    #[test]
    fn shadow_review_is_explicitly_opt_in() {
        for doc in [
            json!({}),
            json!({"labs.shadowReview": false}),
            json!({"labs.shadowReview": "true"}),
            json!({"labs": {"shadowReview": 1}}),
        ] {
            assert!(!enabled(&doc));
        }
        assert!(enabled(&json!({"labs.shadowReview": true})));
        assert!(enabled(&json!({"labs": {"shadowReview": true}})));
    }

    #[test]
    fn shadow_review_excludes_intentional_and_quota_stops() {
        let (hub, session) = fixture();
        for status in [
            GoalStatus::Running,
            GoalStatus::Active,
            GoalStatus::Paused,
            GoalStatus::Done,
            GoalStatus::UsageLimited,
            GoalStatus::BudgetLimited,
            GoalStatus::Unknown("future".into()),
        ] {
            session.meta.lock().unwrap().goal.as_mut().unwrap().status = status;
            hub.shadow_review(&session, MIN_GAP_MS);
        }
        assert!(session.read_meta(|m| m.shadow_review.is_none()));
        assert!(hub.store.events(&session.id, 0, 20).unwrap().is_empty());
    }

    #[test]
    fn shadow_review_excludes_busy_closed_protected_and_goalless_sessions() {
        let (hub, session) = fixture();
        for status in [SessionStatus::Closed, SessionStatus::Running, SessionStatus::Waiting] {
            session.meta.lock().unwrap().status = status;
            hub.shadow_review(&session, MIN_GAP_MS);
        }
        session.meta.lock().unwrap().status = SessionStatus::Idle;
        session.protected_hold.store(true, Ordering::SeqCst);
        hub.shadow_review(&session, MIN_GAP_MS);
        session.protected_hold.store(false, Ordering::SeqCst);
        session.meta.lock().unwrap().goal = None;
        hub.shadow_review(&session, MIN_GAP_MS);
        assert!(hub.store.events(&session.id, 0, 20).unwrap().is_empty());
    }

    #[test]
    fn shadow_review_is_log_only_and_deduplicates_across_restore() {
        let (hub, session) = fixture();
        hub.shadow_review(&session, MIN_GAP_MS);
        let meta = hub.store.load(&session.id).unwrap().unwrap();
        let restored = hub.make_session(meta);
        hub.shadow_review(&restored, 3 * MIN_GAP_MS);
        let records = hub.store.events(&session.id, 0, 20).unwrap();
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].kind, KIND);
        assert_eq!(records[0].msg["result"], "not-sent");
        assert_eq!(records[0].msg["target"], session.id);
        assert!(records[0].msg["stopCondition"].as_str().unwrap().len() > 10);
        assert_eq!(session.queued(), 0);
        assert!(session.turn().is_none());
    }

    #[test]
    fn shadow_review_changed_state_waits_an_hour_and_clock_rollback_cannot_repeat() {
        let (hub, session) = fixture();
        hub.shadow_review(&session, MIN_GAP_MS);
        session.meta.lock().unwrap().goal.as_mut().unwrap().objective = "A new goal".into();
        hub.shadow_review(&session, 0);
        hub.shadow_review(&session, 2 * MIN_GAP_MS - 1);
        assert_eq!(hub.store.events(&session.id, 0, 20).unwrap().len(), 1);
        hub.shadow_review(&session, 2 * MIN_GAP_MS);
        assert_eq!(hub.store.events(&session.id, 0, 20).unwrap().len(), 2);
    }
}
