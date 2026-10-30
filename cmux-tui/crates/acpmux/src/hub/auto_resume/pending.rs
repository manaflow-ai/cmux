//! A pending provider reset survives a daemon restart. The event log is the source of truth;
//! no new on-disk schema, timer loop, or second queue is needed.
use super::*;

impl Hub {
    pub(in crate::hub) fn restore_auto_resume(self: &Arc<Self>, session: &Arc<Session>) {
        let last = session.meta().last_turn;
        let Some(last) = last.filter(|t| t["status"] == "failed") else { return };
        let Some(turn) = last["turnId"].as_str() else { return };
        let Some(prompt) = last["promptId"].as_str() else { return };
        if !still_cut(session, turn) || session.status() == SessionStatus::Closed {
            return;
        }
        // Serialize the durable scan with Stop's in-memory cancellation claim. Otherwise Stop
        // can append a settled marker after this scan but before restoration installs `Ending`.
        let mut pending = self.auto_resumes.lock();
        let mut scheduled = None;
        let mut manual = None;
        let mut manual_recorded = false;
        let mut settled = false;
        let skip = |_: &[u8], _: &[u8]| false;
        let _ = self.store.scan_back(&session.id, 0, u64::MAX, &skip, &mut |e: EventRecord| {
            // A manual retry's replacement prompt can have a new turn id. Its provenance keeps
            // the failed turn it replaces, so notice a durable queued/user message before the
            // manual marker is reached while scanning newest-first.
            if matches!(e.kind.as_str(), "queued" | "user_message")
                && e.msg.pointer("/_meta/provenance/manual") == Some(&Value::Bool(true))
                && e.msg.pointer("/_meta/provenance/turnId").and_then(Value::as_str) == Some(turn)
            {
                manual_recorded = true;
            }
            if e.msg["turnId"] != turn {
                return true;
            }
            match e.kind.as_str() {
                "auto_resume_scheduled" | "auto_resume_pending" => {
                    if scheduled.is_none() {
                        scheduled = Some(e.msg);
                    }
                    true
                }
                "auto_resume_manual" => {
                    if !manual_recorded && manual.is_none() {
                        manual = Some(e.msg);
                    }
                    true
                }
                "auto_resume_settled" | "auto_resume_skipped" | "auto_resume_exhausted" => {
                    // Stop can race between set_retry and appending its scheduled event.
                    // A decision for this turn wins even if that append came afterward.
                    settled = true;
                    false
                }
                "turn_started" => false,
                _ => true,
            }
        });
        if settled || manual_recorded {
            return;
        }
        if let Some(saved) = manual {
            let Some(manual_prompt) = saved["manualPromptId"].as_str().map(str::to_owned) else {
                return;
            };
            let Some(control) = saved["control"].as_str().map(str::to_owned) else { return };
            let Some(gate) = saved["trustGate"].as_bool() else { return };
            let Some(error) = saved["error"].as_str().map(str::to_owned) else { return };
            let from = saved["from"].as_str().map(str::to_owned);
            let full_access_device = saved["fullAccessDevice"].as_str().map(str::to_owned);
            if session.turn().is_some() || session.queue().iter().any(|q| !q.held) {
                return;
            }
            let wake = Arc::new(Notify::new());
            pending.insert(
                session.id.clone(),
                Mark::Waiting { turn: turn.to_owned(), retry: None, _wake: Wake(wake) },
            );
            drop(pending);
            let hub = self.clone();
            let session = session.clone();
            let by = retry_turn::RetryBy {
                control: Control::from_recorded(Some(&control)),
                trust_gate: gate,
                full_access_device,
                from,
            };
            // The marker is durable but the replacement prompt is not. Replay it under its
            // recorded authority; a Stop that wins before this task claims it changes the mark
            // to Stopped and the restored retry refuses that state.
            let _ = (manual_prompt, error); // validated above for old/incomplete markers
            tokio::spawn(async move {
                let _ = hub.retry_turn_restored(&session, by).await;
            });
            return;
        }
        let Some(saved) = scheduled else { return };
        let at = saved["nextAt"].as_u64();
        // Old scheduled events lack the original turn's authority: fail closed.
        let Some(control) = saved["control"].as_str().map(str::to_owned) else { return };
        let Some(gate) = saved["trustGate"].as_bool() else { return };
        let Some(error) = saved["error"].as_str().map(str::to_owned) else { return };
        let not_before = saved["notBefore"].as_u64();
        let from = saved["from"].as_str().map(str::to_owned);
        let prompt = prompt.to_owned();
        let turn = turn.to_owned();
        if pending.contains_key(&session.id) {
            return;
        }
        pending.insert(session.id.clone(), Mark::Ending(turn.to_owned()));
        drop(pending);
        let hub = self.clone();
        let session = session.clone();
        let cut = CutTurn {
            from: from.as_deref(),
            prompt_id: &prompt,
            turn_id: &turn,
            control: Control::from_recorded(Some(&control)),
            trust_gate: gate,
            error: &error,
            not_before,
        };
        hub.schedule_auto_resume_at(&session, &turn, Some(cut), at);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Config, StoreMode};

    #[tokio::test]
    async fn limit_recovery_restores_the_reset_deadline_but_not_a_stopped_retry() {
        for stopped in [false, true] {
            let root = tempfile::tempdir().unwrap();
            let mut cfg = Config::default();
            cfg.store.mode = StoreMode::Local;
            let store = crate::store::open(&cfg.store, root.path()).unwrap();
            let at = crate::store::now_ms() + 6 * 86400 * 1000;
            let error = "You've hit your weekly usage limit";
            let meta = json!({"schema": crate::store::META_SCHEMA, "id": "c1", "name": "c1",
                "harness": "claude", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2,
                "lastTurn": {"turnId": "t1", "promptId": "p1", "status": "failed", "errorText": error}});
            store.save(&serde_json::from_value(meta).unwrap()).unwrap();
            let saved = json!({"promptId": "p1", "turnId": "t1", "attempt": 1, "of": 4,
                "reason": "capacity", "nextAt": at, "error": error, "control": "local", "trustGate": false});
            store
                .append(
                    "c1",
                    &EventRecord {
                        seq: 1,
                        at: 1,
                        dir: "mux".into(),
                        kind: "auto_resume_scheduled".into(),
                        msg: saved,
                        host_seq: None,
                    },
                )
                .unwrap();
            if stopped {
                store
                    .append(
                        "c1",
                        &EventRecord {
                            seq: 2,
                            at: 2,
                            dir: "mux".into(),
                            kind: "auto_resume_settled".into(),
                            msg: json!({"turnId": "t1", "why": "stopped"}),
                            host_seq: None,
                        },
                    )
                    .unwrap();
            }
            let hub = Hub::new(cfg, store);
            let session = hub.resolve("c1").unwrap();
            hub.resume_queues();
            // Let the single scheduled task read the config; no real reset elapses.
            for _ in 0..10 {
                tokio::task::yield_now().await;
            }
            let row = hub.session_summary(&session);
            if stopped {
                assert_eq!(row["retry"], Value::Null, "{row}");
            } else {
                assert_eq!(row["retry"]["nextAt"], at, "{row}");
                assert_eq!(row["retry"]["attempt"], 1, "{row}");
                hub.stop_auto_resume(&session);
                assert_eq!(hub.session_summary(&session)["retry"], Value::Null);
            }
            hub.shutdown_all().await;
        }
    }
}
