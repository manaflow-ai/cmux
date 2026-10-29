//! A scheduled retry survives restart at its original deadline, under the cut turn's rules.
use super::*;

impl Hub {
    /// After this session's log and queue have been restored, before held messages retry.
    /// Startup/import can resume queues repeatedly; claim this session instance only once.
    pub(in crate::hub) fn restore_auto_resume(self: &Arc<Self>, session: &Arc<Session>) {
        if session.auto_resume_restored.swap(true, std::sync::atomic::Ordering::SeqCst) {
            return;
        }
        let mut pending = session.auto_resume.lock();
        if pending.is_some()
            || session.replaced.load(std::sync::atomic::Ordering::SeqCst)
            || session.status() == SessionStatus::Closed
            || session.turn().is_some()
            || session.queue().iter().any(|q| !q.held)
        {
            return;
        }
        // The journal can be ahead of asynchronously saved session.json after a crash. Read
        // only to the newest turn boundary; a newer open turn supersedes any earlier retry.
        let mut last = None;
        if self
            .store
            .scan_back(
                &session.id,
                0,
                u64::MAX,
                &|_, kind| kind != b"turn_started" && kind != b"turn_result",
                &mut |e| {
                    if e.kind == "turn_result" {
                        last = Some(e);
                    }
                    false
                },
            )
            .is_err()
        {
            return;
        }
        let Some(last) = last else { return };
        let Some(turn_id) = last.msg["turnId"].as_str().map(str::to_owned) else { return };
        let error = last.msg["errorText"].as_str().unwrap_or_default().to_owned();
        if last.msg["status"] != "failed"
            || super::super::turn_errors::resume_cause(&error, &error).is_none()
        {
            return;
        }
        let (mut retry, mut from) = (None::<RetrySummary>, None::<String>);
        let mut has_retry_marker = false;
        let (mut control, mut trust_gate) = (Control::Web, true);
        let (mut ended, mut floor_cancelled) = (false, false);
        let kinds = [
            "turn_started",
            "user_message",
            "turn_control",
            "remote_control_ended",
            "remote_control_restored",
            "remote_floor_cancel",
            "auto_resume_scheduled",
            "auto_resume_stopped",
            "auto_resume_skipped",
            "auto_resume_settled",
            "auto_resume_exhausted",
        ];
        let scanned = self.store.scan_kinds(&session.id, &kinds, &mut |e: EventRecord| {
            let is_cut = e.msg["turnId"].as_str() == Some(turn_id.as_str());
            match e.kind.as_str() {
                "turn_started" if is_cut => {
                    // A stop record has no turn id. It belongs to the turn that was
                    // active when it was written; an earlier stop must not suppress
                    // recovery for this failed turn.
                    has_retry_marker = false;
                    control = Control::from_recorded(e.msg["control"].as_str());
                    trust_gate = e.msg["trustGate"].as_bool().unwrap_or(true);
                    ended = false;
                    floor_cancelled = false;
                }
                "user_message" if is_cut => {
                    let p = e.msg.pointer("/_meta/provenance");
                    if super::super::subsession_guard::is_family(p) {
                        from = p.and_then(|p| p["from"].as_str()).map(str::to_owned);
                    }
                }
                "turn_control" if is_cut && e.msg["control"] == "web" => control = Control::Web,
                "remote_control_ended" => ended = true,
                "remote_control_restored" => ended = false,
                "remote_floor_cancel" if is_cut => floor_cancelled = true,
                // daemon_restart records are queued continuations, not waiting retries.
                "auto_resume_scheduled" if is_cut && e.msg["reason"] != "daemon_restart" => {
                    has_retry_marker = true;
                    retry = serde_json::from_value(e.msg).ok();
                }
                // Stop records have no turn id; the turn_started reset above makes this
                // apply only to a stop after the current failed turn began.
                "auto_resume_stopped" => {
                    has_retry_marker = true;
                    retry = None
                }
                "auto_resume_skipped" | "auto_resume_settled" | "auto_resume_exhausted"
                    if is_cut =>
                {
                    has_retry_marker = true;
                    retry = None
                }
                _ => {}
            }
            true
        });
        // `turn_result` is durable before the asynchronous scheduler runs. If restart cuts
        // that small window, synthesize its first retry now instead of losing the transient
        // failure forever.
        if retry.is_none()
            && !has_retry_marker
            && last.msg["status"] == "failed"
            && let Some(reason) = super::super::turn_errors::resume_cause(&error, &error)
                .and_then(RetryReason::from_cause)
        {
            let (root, done) = split_attempt(last.msg["promptId"].as_str().unwrap_or_default());
            if done < MAX_ATTEMPTS {
                let recovered = RetrySummary {
                    attempt: (done + 1) as u64,
                    of: MAX_ATTEMPTS as u64,
                    reason,
                    next_at: crate::hub::now_ms(),
                    prompt_id: root.to_owned(),
                    turn_id: turn_id.to_owned(),
                };
                // The transient turn_result can be ahead of the scheduler. Persist the
                // synthesized schedule before arming its task so a second crash keeps the
                // original deadline instead of resetting it on every restart.
                self.append(
                    session,
                    "mux",
                    "auto_resume_scheduled",
                    serde_json::to_value(&recovered).unwrap_or_else(|_| json!({})),
                );
                retry = Some(recovered);
            }
        }
        let Some(retry) = retry.filter(|r| {
            scanned.is_ok()
                && r.attempt > 0
                && r.attempt <= MAX_ATTEMPTS as u64
                && !r.prompt_id.is_empty()
        }) else {
            return;
        };
        // Restore the durable summary before any blocked/skip decision. Manual retry and
        // session rows must still describe the failed turn after a crash with stale metadata.
        let mut summary = serde_json::Map::new();
        for key in super::super::views::LAST_TURN_KEYS {
            if let Some(value) = last.msg.get(key) {
                summary.insert(key.to_owned(), value.clone());
            }
        }
        summary.insert("endedAt".into(), json!(last.at));
        session.meta.lock().unwrap_or_else(|e| e.into_inner()).last_turn =
            Some(Value::Object(summary));

        if control == Control::Web && (ended || floor_cancelled) {
            let skipped =
                if floor_cancelled { "remote_floor_cancel" } else { "remote_control_ended" };
            self.append(
                session,
                "mux",
                "auto_resume_skipped",
                json!({
                    "promptId": retry.prompt_id,
                    "attempt": retry.attempt,
                    "turnId": turn_id,
                    "skipped": skipped,
                }),
            );
            return;
        }
        let id = format!("{}{SUFFIX}{}", retry.prompt_id, retry.attempt);
        if self.logged_prompt(session, &id).is_some() {
            return;
        }
        let wake = Arc::new(Notify::new());
        pending.replace(Mark::Waiting {
            turn: turn_id.clone(),
            retry: Some(retry.clone()),
            _wake: Wake(wake.clone()),
        });
        // Startup reads logs asynchronously. Publish the restored wait only after its mark
        // is visible, and before Stop can remove it, so observers can synchronize with it.
        self.append(session, "mux", "auto_resume_restored", json!(retry));
        drop(pending);
        let (hub, session) = (self.clone(), session.clone());
        tokio::spawn(async move {
            // As with a restored queued prompt, wait for login environment and catalog.
            hub.wait_startup().await;
            if hub.config.read().await.auto_resume_delays_ms.as_ref().is_some_and(Vec::is_empty) {
                if hub.take_pending(&session, &turn_id) {
                    hub.settled_unretried(&session, &turn_id, "off");
                }
                return;
            }
            let delay = retry.next_at.saturating_sub(crate::hub::now_ms());
            tokio::select! {
                () = tokio::time::sleep(Duration::from_millis(delay)) => {}
                () = wake.notified() => {}
            }
            let cut = CutTurn {
                from: from.as_deref(),
                prompt_id: &retry.prompt_id,
                turn_id: &turn_id,
                control,
                trust_gate: trust_gate || control == Control::Web,
                error: &error,
            };
            hub.auto_resume(&session, cut, retry.attempt as usize).await;
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn idle_chat() -> (Arc<Hub>, Arc<Session>) {
        let mut cfg = crate::config::Config::default();
        cfg.store.mode = crate::config::StoreMode::Memory;
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        let meta = json!({"schema": crate::store::META_SCHEMA, "id": "retry-cancel",
            "name": "retry-cancel", "harness": "claude", "cwd": "/tmp", "status": "idle",
            "createdAt": 1, "updatedAt": 2});
        store.save(&serde_json::from_value(meta).unwrap()).unwrap();
        let hub = Hub::new(cfg, store);
        // Restored tasks wait here: these tests inspect recovery, never start an agent.
        hub.begin_startup(false);
        let session = hub.resolve("retry-cancel").unwrap();
        (hub, session)
    }

    fn failed_retry(hub: &Hub, session: &Session) {
        hub.append(
            session,
            "mux",
            "turn_started",
            json!({"turnId": "later-turn",
            "promptId": "later-prompt", "control": "local", "trustGate": false}),
        );
        let result = json!({"turnId": "later-turn", "promptId": "later-prompt",
            "status": "failed", "errorText": "stream disconnected"});
        hub.append_unknown_outcome(session, result);
        hub.append(
            session,
            "mux",
            "auto_resume_scheduled",
            json!({
            "turnId": "later-turn", "promptId": "later-prompt", "attempt": 1, "of": 4,
            "reason": "transport", "nextAt": crate::hub::now_ms() + 60000}),
        );
    }

    #[tokio::test]
    async fn retry_restore_synthesizes_a_schedule_after_a_crash_window() {
        let (hub, session) = idle_chat();
        hub.append(
            &session,
            "mux",
            "turn_started",
            json!({"turnId": "window-turn", "promptId": "window-prompt", "control": "local", "trustGate": false}),
        );
        hub.append_unknown_outcome(
            &session,
            json!({"turnId": "window-turn", "promptId": "window-prompt", "status": "failed", "errorText": "stream disconnected"}),
        );
        hub.restore_auto_resume(&session);
        let retry = hub.session_summary(&session)["retry"].clone();
        assert_eq!(retry["promptId"], "window-prompt");
        assert_eq!(retry["turnId"], "window-turn");
        assert_eq!(retry["attempt"], 1);
    }

    #[tokio::test]
    async fn an_earlier_stop_does_not_suppress_a_later_crash_window_retry() {
        let (hub, session) = idle_chat();
        hub.append(
            &session,
            "mux",
            "turn_started",
            json!({"turnId": "old-turn", "promptId": "old-prompt", "control": "local", "trustGate": false}),
        );
        hub.append_unknown_outcome(
            &session,
            json!({"turnId": "old-turn", "promptId": "old-prompt", "status": "failed", "errorText": "stream disconnected"}),
        );
        hub.append(&session, "mux", "auto_resume_stopped", json!({}));
        hub.append(
            &session,
            "mux",
            "turn_started",
            json!({"turnId": "new-turn", "promptId": "new-prompt", "control": "local", "trustGate": false}),
        );
        hub.append_unknown_outcome(
            &session,
            json!({"turnId": "new-turn", "promptId": "new-prompt", "status": "failed", "errorText": "stream disconnected"}),
        );
        hub.restore_auto_resume(&session);
        assert_eq!(hub.session_summary(&session)["retry"]["promptId"], "new-prompt");
    }

    #[tokio::test]
    async fn a_pre_turn_user_message_is_not_a_logged_retry() {
        let (hub, session) = idle_chat();
        hub.append(
            &session,
            "in",
            "user_message",
            json!({"promptId": "resume~1", "turnId": "resume-turn", "text": "continue"}),
        );
        assert!(hub.logged_prompt(&session, "resume~1").is_none());
        hub.append(
            &session,
            "mux",
            "turn_started",
            json!({"turnId": "resume-turn", "promptId": "resume~1"}),
        );
        assert!(hub.logged_prompt(&session, "resume~1").is_some());
    }

    #[tokio::test]
    async fn replaced_retry_cannot_be_admitted_as_a_new_turn() {
        let (hub, session) = idle_chat();
        session.replaced.store(true, std::sync::atomic::Ordering::SeqCst);
        let turn =
            TurnInfo::prompted("acpmux", "continue", "retry-turn", "retry~1", Control::Local);
        let error = hub
            .start_turn(&session, Some("cut-turn"), false, false, turn)
            .expect_err("a replaced retry must not start");
        assert_eq!(
            error.data.as_ref().and_then(|v| v["reason"].as_str()),
            Some("auto_resume.superseded")
        );
        assert!(session.turn().is_none());
    }

    #[tokio::test]
    async fn retry_restore_does_not_apply_an_earlier_idle_cancel_to_a_later_failed_turn() {
        let (hub, session) = idle_chat();
        // No child is expected, but cancel still records the person's Stop.
        let _ = hub.cancel(&session).await;
        assert_eq!(session.cancels.load(std::sync::atomic::Ordering::SeqCst), 1);
        failed_retry(&hub, &session);
        hub.restore_auto_resume(&session);
        let row = hub.session_summary(&session);
        assert_eq!(row["retry"]["turnId"], "later-turn", "{row}");
        assert_eq!(row["retry"]["promptId"], "later-prompt", "{row}");
        assert!(
            hub.events(&session.id, 0, 100)
                .unwrap()
                .iter()
                .any(|e| e.kind == "auto_resume_restored")
        );
    }

    #[tokio::test]
    async fn retry_restore_recovers_an_import_replacing_an_already_restored_session() {
        let (source, incoming) = idle_chat();
        failed_retry(&source, &incoming);
        let expected = source.events(&incoming.id, 0, 100).unwrap().pop().unwrap().msg;
        let dir =
            std::env::temp_dir().join(format!("acpmux-retry-import-{}", uuid::Uuid::now_v7()));
        let bundle = source.export(&incoming, &dir).unwrap();
        for was_closed in [false, true] {
            let (hub, old) = idle_chat();
            hub.config.write().await.harnesses.insert(
                "claude".into(),
                serde_json::from_value(json!({"argv": ["true"]})).unwrap(),
            );
            if was_closed {
                hub.kill(&old, false).await.unwrap();
            }
            hub.resume_queues();
            assert_eq!(hub.session_summary(&old)["retry"], Value::Null);
            // A returning move replaces the closed session and its old store. Keep the old
            // Arc alive, as a concurrent reader may, while importing the same id's journal.
            *old.moving.lock().unwrap() = Some("previous-move".into());
            old.replaced.store(true, std::sync::atomic::Ordering::SeqCst);
            hub.kill(&old, false).await.unwrap();
            // Memory-store equivalent of transfer_finish staging the old store aside.
            hub.store.delete(&old.id).unwrap();
            let imported = hub.import_into(&bundle, None, true, None, true, false).await.unwrap();
            assert_eq!(old.id, imported.id);
            assert!(!Arc::ptr_eq(&old, &imported));
            hub.resume_queues();
            hub.resume_queues();
            let retry = hub.session_summary(&imported)["retry"].clone();
            assert_eq!(retry["promptId"], "later-prompt", "import lost retry: {retry}");
            assert_eq!(retry["nextAt"], expected["nextAt"]);
            assert_eq!(retry["attempt"], expected["attempt"]);
            assert_eq!(
                hub.events(&imported.id, 0, 100)
                    .unwrap()
                    .iter()
                    .filter(|e| e.kind == "auto_resume_restored")
                    .count(),
                1,
                "repeated resume_queues must recover the imported retry only once"
            );
        }
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn retry_restore_old_task_cannot_consume_a_replacements_retry() {
        let (source, incoming) = idle_chat();
        failed_retry(&source, &incoming);
        let dir =
            std::env::temp_dir().join(format!("acpmux-retry-old-task-{}", uuid::Uuid::now_v7()));
        let bundle = source.export(&incoming, &dir).unwrap();
        let (hub, old) = idle_chat();
        hub.config
            .write()
            .await
            .harnesses
            .insert("claude".into(), serde_json::from_value(json!({"argv": ["true"]})).unwrap());
        failed_retry(&hub, &old);
        hub.restore_auto_resume(&old);
        assert!(hub.session_summary(&old)["retry"].is_object());
        // Both copies retain the same turn and prompt ids. The old timer is still alive
        // behind startup when transfer replacement stops it and imports the returning log.
        *old.moving.lock().unwrap() = Some("previous-move".into());
        old.replaced.store(true, std::sync::atomic::Ordering::SeqCst);
        hub.kill(&old, false).await.unwrap();
        hub.store.delete(&old.id).unwrap();
        let imported = hub.import_into(&bundle, None, true, None, true, false).await.unwrap();
        hub.restore_auto_resume(&imported);
        let before = hub.session_summary(&imported)["retry"].clone();
        assert!(before.is_object());
        let records = hub.events(&imported.id, 0, 100).unwrap().len();
        // Drive the old timer's wake directly, without timing or starting a harness.
        hub.auto_resume(
            &old,
            CutTurn {
                from: None,
                prompt_id: "later-prompt",
                turn_id: "later-turn",
                control: Control::Local,
                trust_gate: false,
                error: "stream disconnected",
            },
            1,
        )
        .await;
        assert_eq!(hub.session_summary(&imported)["retry"], before);
        // A task already inside prompt_with can return after replacement too. Its
        // refused result and a late exhaustion decision must not settle the incoming retry.
        hub.finish_auto_resume(
            &old,
            &CutTurn {
                from: None,
                prompt_id: "later-prompt",
                turn_id: "later-turn",
                control: Control::Local,
                trust_gate: false,
                error: "stream disconnected",
            },
            1,
            &[],
            Err(RpcError::invalid_params("folder disappeared")),
            false,
        );
        hub.append_retry(&old, "auto_resume_exhausted", json!({"turnId": "later-turn"}));
        assert_eq!(hub.events(&imported.id, 0, 100).unwrap().len(), records);
        // Off/exhaustion and cleanup paths from old tasks also own only the old mark.
        assert!(!hub.take_pending(&old, "later-turn"));
        assert_eq!(hub.fire_pending(&imported, "later-turn"), Ok(()));
        hub.clear_fired(&old, "later-turn");
        assert_eq!(hub.session_summary(&imported)["retryDeciding"], true);
        hub.clear_fired(&imported, "later-turn");
        assert!(hub.session_summary(&imported)["retryDeciding"].is_null());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn retry_restore_first_close_stops_the_retry_but_repeated_close_logs_nothing() {
        let (hub, session) = idle_chat();
        failed_retry(&hub, &session);
        // No in-memory retry mark yet: close must still persist its cancellation.
        hub.kill(&session, false).await.unwrap();
        let records = hub.events(&session.id, 0, 100).unwrap();
        assert_eq!(records.iter().filter(|e| e.kind == "auto_resume_stopped").count(), 1);
        let closed_at = session.meta().updated_at;
        hub.kill(&session, false).await.unwrap();
        assert!(hub.cancel(&session).await.is_err());
        assert_eq!(hub.events(&session.id, 0, 100).unwrap().len(), records.len());
        assert_eq!(session.meta().updated_at, closed_at);

        // Reopening does not erase the first close's journal boundary. Recovery must
        // not resurrect the failed turn's wait, even after the chat is open again.
        assert!(hub.reopen(&session, session.stops.load(std::sync::atomic::Ordering::SeqCst)));
        hub.restore_auto_resume(&session);
        assert_eq!(hub.session_summary(&session)["retry"], Value::Null);
    }

    #[tokio::test]
    async fn retry_restore_preserves_a_cancel_after_scheduling_before_the_mark_is_restored() {
        let (hub, session) = idle_chat();
        failed_retry(&hub, &session);
        let _ = hub.cancel(&session).await;
        hub.restore_auto_resume(&session);
        assert_eq!(hub.session_summary(&session)["retry"], Value::Null);
        // Recreate the hub from the same durable store: the cancellation is not just an
        // in-memory counter, and it stays terminal on a later restart too.
        let cfg = hub.config.read().await.clone();
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        store.save(&session.meta()).unwrap();
        for record in hub.events(&session.id, 0, 100).unwrap() {
            store.append(&session.id, &record).unwrap();
        }
        let restored = Hub::new(cfg, store);
        restored.begin_startup(false);
        let session = restored.resolve(&session.id).unwrap();
        restored.restore_auto_resume(&session);
        assert_eq!(restored.session_summary(&session)["retry"], Value::Null);
        assert!(
            !restored
                .events(&session.id, 0, 100)
                .unwrap()
                .iter()
                .any(|e| e.kind == "auto_resume_restored")
        );
    }
}
