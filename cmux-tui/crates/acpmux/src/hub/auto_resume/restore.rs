//! A scheduled retry survives restart at its original deadline, under the cut turn's rules.
//!
//! Durable state machine (records before the newest turn's boundary never decide its retry):
//! | Last durable write / crash point | Recovery |
//! | --- | --- |
//! | `turn_started`, no result | Adopt the host or queue the restart continuation elsewhere. |
//! | transient `turn_result`, no decision | Persist a schedule due at result time + configured delay. |
//! | `auto_resume_scheduled` | Re-arm that exact attempt and deadline, never compute a new deadline. |
//! | retry `user_message`, no `turn_started` | Admission never happened; re-arm the same prompt id. |
//! | retry `user_message` and `turn_stop_requested` (either order) | Settle its original schedule; never resend. |
//! | retry `turn_started` / `turn_result` | Newest turn owns recovery; never resend the old attempt. |
//! | `turn_stop_requested` / stopped / skipped / settled / exhausted | Terminal for the cut turn. |
//! | `auto_resume_restored` | Notification only; the schedule was already durable before this write. |
//!
//! Stop writes its turn-scoped boundary under the same lock as scheduling, before cancelling
//! the agent. A blocked Web retry writes a terminal skip before returning. Neither can be
//! resurrected by restoring Web control, re-importing the chat, or a second daemon restart.
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
            || session.queue().iter().any(|q| !q.aside())
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
        // The durable trigger dispatcher owns retries; a generic continuation
        // would lose the verified principal and become an ordinary human turn.
        if last.msg.get("trigger") == Some(&Value::Bool(true)) {
            return;
        }
        let Some(turn_id) = last.msg.get("turnId").and_then(Value::as_str).map(str::to_owned)
        else {
            return;
        };
        let error =
            last.msg.get("errorText").and_then(Value::as_str).unwrap_or_default().to_owned();
        if last.msg.get("status").and_then(Value::as_str) != Some("failed")
            || super::super::turn_errors::resume_cause(&error, &error).is_none()
        {
            return;
        }
        let (mut retry, mut from) = (None::<RetrySummary>, None::<String>);
        let mut not_before = None::<u64>;
        let mut manual = None::<Value>;
        let mut manual_recorded = false;
        let mut has_retry_marker = false;
        let mut turn_stopped = false;
        let (mut control, mut trust_gate) = (Control::Web, true);
        let (mut ended, mut floor_cancelled) = (false, false);
        let kinds = [
            "turn_started",
            "queued",
            "user_message",
            "turn_control",
            "remote_control_ended",
            "remote_control_restored",
            "remote_floor_cancel",
            "auto_resume_scheduled",
            "auto_resume_manual",
            "auto_resume_stopped",
            "auto_resume_skipped",
            "auto_resume_settled",
            "auto_resume_exhausted",
            "turn_stop_requested",
        ];
        let scanned = self.store.scan_kinds(&session.id, &kinds, &mut |e: EventRecord| {
            if matches!(e.kind.as_str(), "queued" | "user_message")
                && e.msg.pointer("/_meta/provenance/manual") == Some(&Value::Bool(true))
                && e.msg.pointer("/_meta/provenance/turnId").and_then(Value::as_str)
                    == Some(turn_id.as_str())
            {
                manual_recorded = true;
            }
            let is_cut = e.msg.get("turnId").and_then(Value::as_str) == Some(turn_id.as_str());
            match e.kind.as_str() {
                "turn_started" if is_cut => {
                    // A stop record has no turn id. It belongs to the turn that was
                    // active when it was written; an earlier stop must not suppress
                    // recovery for this failed turn.
                    has_retry_marker = false;
                    control = Control::from_recorded(e.msg.get("control").and_then(Value::as_str));
                    trust_gate = e.msg.get("trustGate").and_then(Value::as_bool).unwrap_or(true);
                    ended = false;
                    floor_cancelled = false;
                }
                "user_message" if is_cut => {
                    let p = e.msg.pointer("/_meta/provenance");
                    if super::super::subsession_guard::is_family(p) {
                        from = p.and_then(|p| p["from"].as_str()).map(str::to_owned);
                    }
                }
                "auto_resume_manual" if is_cut && !manual_recorded => manual = Some(e.msg),
                "turn_control"
                    if is_cut && e.msg.get("control").and_then(Value::as_str) == Some("web") =>
                {
                    control = Control::Web
                }
                "remote_control_ended" => ended = true,
                "remote_control_restored" => ended = false,
                "remote_floor_cancel" if is_cut => floor_cancelled = true,
                // daemon_restart and moved records are queued continuations, not waiting
                // retries.
                "auto_resume_scheduled"
                    if is_cut
                        && !super::Cut::queued(e.msg.get("reason").and_then(Value::as_str)) =>
                {
                    has_retry_marker = true;
                    not_before = e.msg.get("notBefore").and_then(Value::as_u64);
                    retry = serde_json::from_value(e.msg).ok();
                }
                // Old stop records had no id; the turn boundary reset scopes those. New
                // records explicitly name the cut turn, including a Stop before failure.
                "auto_resume_stopped"
                    if is_cut || e.msg.get("turnId").is_none_or(Value::is_null) =>
                {
                    turn_stopped |= is_cut;
                    has_retry_marker = true;
                    retry = None;
                    manual = None;
                }
                "turn_stop_requested" if is_cut => {
                    turn_stopped = true;
                    has_retry_marker = true;
                    retry = None;
                    manual = None;
                }
                "auto_resume_skipped" | "auto_resume_settled" | "auto_resume_exhausted"
                    if is_cut =>
                {
                    has_retry_marker = true;
                    retry = None;
                    manual = None;
                }
                _ => {}
            }
            true
        });
        if scanned.is_err() {
            return;
        }
        if manual_recorded {
            manual = None;
        }
        // Stop may race the small gap between in-memory admission and turn_started.
        // Explicitly scoped cancellation remains terminal even if its record came first.
        if turn_stopped {
            has_retry_marker = true;
            retry = None;
            manual = None;
        }
        // Refresh the durable last-turn summary before every skip/configuration decision.
        let mut summary = serde_json::Map::new();
        for key in super::super::views::LAST_TURN_KEYS {
            if let Some(value) = last.msg.get(key) {
                summary.insert(key.to_owned(), value.clone());
            }
        }
        summary.insert("endedAt".into(), json!(last.at));
        session.meta.lock().unwrap_or_else(|e| e.into_inner()).last_turn =
            Some(Value::Object(summary));

        // Never substitute default retries for a config currently being changed. Wait for
        // the writer off this synchronous path, then reclaim restoration for this instance.
        let delays = match self.config.try_read() {
            Ok(config) => {
                config.auto_resume_delays_ms.clone().unwrap_or_else(|| DEFAULT_DELAYS_MS.to_vec())
            }
            Err(_) => {
                let (hub, session) = (self.clone(), session.clone());
                tokio::spawn(async move {
                    drop(hub.config.read().await);
                    session.auto_resume_restored.store(false, std::sync::atomic::Ordering::SeqCst);
                    hub.restore_auto_resume(&session);
                });
                return;
            }
        };
        if let Some(saved) = manual {
            let text = |key: &str| saved.get(key).and_then(Value::as_str);
            let Some(_manual_prompt) = text("manualPromptId") else { return };
            let Some(control) = text("control").map(str::to_owned) else { return };
            let Some(trust_gate) = saved.get("trustGate").and_then(Value::as_bool) else { return };
            let Some(_error) = text("error") else { return };
            let from = text("from").map(str::to_owned);
            let full_access_device = text("fullAccessDevice").map(str::to_owned);
            let wake = Arc::new(Notify::new());
            pending.replace(Mark::Waiting {
                turn: turn_id.clone(),
                retry: None,
                _wake: Wake(wake),
            });
            drop(pending);
            let hub = self.clone();
            let session = session.clone();
            let by = retry_turn::RetryBy {
                control: Control::from_recorded(Some(&control)),
                trust_gate,
                full_access_device,
                from,
            };
            tokio::spawn(async move {
                let _ = hub.retry_turn_restored(&session, by).await;
            });
            return;
        }
        if delays.is_empty() && (retry.is_some() || !has_retry_marker) {
            self.append(
                session,
                "mux",
                "auto_resume_settled",
                json!({"turnId": turn_id, "promptId": last.msg.get("promptId"), "why": "off"}),
            );
            return;
        }
        // `turn_result` is durable before the asynchronous scheduler runs. If restart cuts
        // that small window, synthesize its first retry now instead of losing the transient
        // failure forever.
        if retry.is_none()
            && !has_retry_marker
            && last.msg.get("status").and_then(Value::as_str) == Some("failed")
            && let Some(reason) = super::super::turn_errors::resume_cause(&error, &error)
                .and_then(RetryReason::from_cause)
        {
            let (root, done) =
                split_attempt(last.msg.get("promptId").and_then(Value::as_str).unwrap_or_default());
            if !root.is_empty()
                && let Some(&delay) = delays.get(done)
            {
                let delay = staggered(delay, &session.id);
                let recovered = RetrySummary {
                    attempt: done.saturating_add(1) as u64,
                    of: delays.len() as u64,
                    reason,
                    next_at: last.at.saturating_add(delay),
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
            } else if !root.is_empty() {
                self.append(session, "mux", "auto_resume_exhausted", json!({
                    "promptId": root, "attempts": done, "turnId": turn_id, "reason": reason.as_str()
                }));
            }
        }

        // Validate against the durable schedule's configured attempt count. The
        // default delay count is not a ceiling on explicitly configured retries.
        let Some(retry) =
            retry.filter(|r| r.attempt > 0 && r.attempt <= r.of && !r.prompt_id.is_empty())
        else {
            return;
        };
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
        if let Some(outcome) = self.logged_prompt(session, &id) {
            let outcome = outcome.unwrap_or_default();
            if outcome.get("stopReason").and_then(Value::as_str) == Some("cancelled") {
                // The retry can be stopped while startup is still pending, before its
                // turn_started. That Stop names the new turn, not the failed cut turn.
                // The prompt ledger links it back to this schedule's stable attempt ID.
                self.append(
                    session,
                    "mux",
                    "auto_resume_skipped",
                    json!({
                        "turnId": turn_id, "promptId": retry.prompt_id,
                        "attempt": retry.attempt, "skipped": "stopped"
                    }),
                );
            }
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
                not_before,
            };
            hub.auto_resume(&session, cut, usize::try_from(retry.attempt).unwrap_or(usize::MAX))
                .await;
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

    async fn restart(hub: &Hub, session: &Session) -> (Arc<Hub>, Arc<Session>) {
        let cfg = hub.config.read().await.clone();
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        // Deliberately stale session.json: the journal must restore both lastTurn and retry.
        let mut meta = session.meta();
        meta.last_turn = None;
        store.save(&meta).unwrap();
        for record in hub.events(&session.id, 0, 1000).unwrap() {
            store.append(&session.id, &record).unwrap();
        }
        let restored = Hub::new(cfg, store);
        restored.begin_startup(false);
        let session = restored.resolve(&session.id).unwrap();
        (restored, session)
    }

    fn failed_window(hub: &Hub, session: &Session, prompt: &str) -> u64 {
        hub.append(
            session,
            "mux",
            "turn_started",
            json!({
                "turnId": "cut", "promptId": prompt, "control": "local", "trustGate": false
            }),
        );
        hub.append_unknown_outcome(session, json!({
            "turnId": "cut", "promptId": prompt, "status": "failed", "errorText": "stream disconnected"
        }));
        hub.events(&session.id, 0, 1000).unwrap().last().unwrap().at
    }

    #[tokio::test]
    async fn retry_restore_crash_points_keep_the_same_attempt_and_deadline() {
        // One row per crash boundary: the original result, scheduled wait, first retry
        // message, terminal Stop, started retry, and completed retry. Only admission of
        // the retry may consume the attempt; merely logging its user_message cannot.
        for point in [
            "result",
            "schedule",
            "message",
            "message_stop",
            "stop_message",
            "stop_without_message",
            "stop",
            "unscheduled_stop",
            "started",
            "completed",
        ] {
            let (hub, session) = idle_chat();
            hub.config.write().await.auto_resume_delays_ms = Some(vec![60_000]);
            let ended_at = failed_window(&hub, &session, "original");
            let next_at = ended_at + staggered(60_000, &session.id);
            if !["result", "unscheduled_stop"].contains(&point) {
                hub.append(
                    &session,
                    "mux",
                    "auto_resume_scheduled",
                    json!({
                        "turnId": "cut", "promptId": "original", "attempt": 1, "of": 1,
                        "reason": "transport", "nextAt": next_at
                    }),
                );
            }
            if ["message", "message_stop", "started", "completed"].contains(&point) {
                hub.append(
                    &session,
                    "in",
                    "user_message",
                    json!({
                        "turnId": "retry", "promptId": "original~resume-1", "text": "continue"
                    }),
                );
            }
            if ["message_stop", "stop_message", "stop_without_message"].contains(&point) {
                // In-memory admission precedes the harness's durable turn_started.
                // Stop here names `retry`, whereas the saved schedule names `cut`.
                hub.start_turn(
                    &session,
                    None,
                    false,
                    false,
                    TurnInfo::prompted(
                        "test",
                        "continue",
                        "retry",
                        "original~resume-1",
                        Control::Local,
                    ),
                )
                .unwrap();
                hub.stop_auto_resume(&session);
            }
            if point == "stop_message" {
                hub.append(
                    &session,
                    "in",
                    "user_message",
                    json!({
                        "turnId": "retry", "promptId": "original~resume-1", "text": "continue"
                    }),
                );
            }
            if ["started", "completed"].contains(&point) {
                hub.append(
                    &session,
                    "mux",
                    "turn_started",
                    json!({
                        "turnId": "retry", "promptId": "original~resume-1", "control": "local"
                    }),
                );
            }
            if point == "completed" {
                hub.append_unknown_outcome(
                    &session,
                    json!({
                        "turnId": "retry", "promptId": "original~resume-1", "status": "completed"
                    }),
                );
            }
            if ["stop", "unscheduled_stop"].contains(&point) {
                hub.stop_auto_resume(&session);
            }
            let (restored, session) = restart(&hub, &session).await;
            restored.restore_auto_resume(&session);
            let expected = ["result", "schedule", "message"].contains(&point);
            let retry = restored.session_summary(&session)["retry"].clone();
            assert_eq!(retry.is_object(), expected, "crash after {point}: {retry}");
            if ["message_stop", "stop_message", "stop_without_message"].contains(&point) {
                assert_eq!(
                    restored.logged_prompt(&session, "original~resume-1").unwrap().unwrap()["stopReason"],
                    "cancelled"
                );
                let (again, session) = restart(&restored, &session).await;
                again.restore_auto_resume(&session);
                assert!(again.session_summary(&session)["retry"].is_null());
                let records = again.events(&session.id, 0, 1000).unwrap();
                assert!(records.iter().any(|e| e.kind == "auto_resume_skipped"
                    && e.msg["turnId"] == "cut"
                    && e.msg["skipped"] == "stopped"));
                assert!(!records.iter().any(|e| e.kind == "auto_resume_restored"));
            }
            if expected {
                assert_eq!(retry["nextAt"], next_at, "crash after {point}");
                assert_eq!(retry["of"], 1);
                let (again, session) = restart(&restored, &session).await;
                again.restore_auto_resume(&session);
                assert_eq!(
                    again.session_summary(&session)["retry"],
                    retry,
                    "second restart after {point}"
                );
                assert_eq!(
                    again
                        .events(&session.id, 0, 1000)
                        .unwrap()
                        .iter()
                        .filter(|e| e.kind == "auto_resume_scheduled" && e.msg["turnId"] == "cut")
                        .count(),
                    1
                );
            }
        }
    }

    #[tokio::test]
    async fn retry_restore_synthesis_honors_configured_attempts_and_disabled_retries() {
        for (delays, prompt, expected_attempt) in [
            (vec![], "original", None),
            (vec![10_000], "original~resume-1", None),
            (vec![10_000, 60_000], "original~resume-1", Some(2)),
            (vec![60_000; 5], "original~resume-4", Some(5)),
        ] {
            let (hub, session) = idle_chat();
            hub.config.write().await.auto_resume_delays_ms = Some(delays.clone());
            let ended_at = failed_window(&hub, &session, prompt);
            session.meta.lock().unwrap().last_turn = None;
            hub.restore_auto_resume(&session);
            let row = hub.session_summary(&session);
            assert_eq!(row["lastTurn"]["turnId"], "cut");
            match expected_attempt {
                Some(attempt) => {
                    assert_eq!(row["retry"]["attempt"], attempt);
                    assert_eq!(row["retry"]["of"], delays.len());
                    assert_eq!(
                        row["retry"]["nextAt"],
                        ended_at + staggered(delays[attempt - 1], &session.id)
                    );
                    // The next daemon reads the persisted schedule rather than
                    // synthesizing it. Both paths honor its configured attempt count.
                    let (again, session) = restart(&hub, &session).await;
                    again.restore_auto_resume(&session);
                    assert_eq!(again.session_summary(&session)["retry"], row["retry"]);
                }
                None => {
                    assert_eq!(row["retry"], Value::Null);
                    assert!(!hub.events(&session.id, 0, 1000).unwrap().iter().any(|e| matches!(
                        e.kind.as_str(),
                        "auto_resume_scheduled" | "auto_resume_restored"
                    )));
                    // Enabling or extending retries later must not revive an already settled turn.
                    hub.config.write().await.auto_resume_delays_ms =
                        Some(DEFAULT_DELAYS_MS.to_vec());
                    let (again, session) = restart(&hub, &session).await;
                    again.restore_auto_resume(&session);
                    assert!(again.session_summary(&session)["retry"].is_null());
                }
            }
        }
    }

    #[tokio::test]
    async fn retry_restore_stop_before_failure_is_durable_without_retry_events() {
        for point in ["admitted", "started", "ending"] {
            let (hub, session) = idle_chat();
            hub.start_turn(
                &session,
                None,
                false,
                false,
                TurnInfo::prompted("test", "hello", "cut", "original", Control::Local),
            )
            .unwrap();
            if point != "admitted" {
                hub.append(
                    &session,
                    "mux",
                    "turn_started",
                    json!({
                        "turnId": "cut", "promptId": "original", "control": "local"
                    }),
                );
            }
            if point == "ending" {
                hub.take_turn(&session, "cut", None);
            }
            hub.stop_auto_resume(&session);
            if point == "admitted" {
                hub.append(
                    &session,
                    "mux",
                    "turn_started",
                    json!({
                        "turnId": "cut", "promptId": "original", "control": "local"
                    }),
                );
            }
            // The same Stop also forbids the open-turn restart continuation.
            assert!(hub.log_restart_continuation(&session, "cut").is_none());
            if point != "ending" {
                hub.take_turn(&session, "cut", None);
            }
            hub.append_unknown_outcome(&session, json!({
                "turnId": "cut", "promptId": "original", "status": "failed", "errorText": "stream disconnected"
            }));
            hub.schedule_auto_resume(
                &session,
                "cut",
                Some(CutTurn {
                    from: None,
                    prompt_id: "original",
                    turn_id: "cut",
                    control: Control::Local,
                    trust_gate: false,
                    error: "stream disconnected",
                    not_before: None,
                }),
            );
            let (again, session) = restart(&hub, &session).await;
            again.restore_auto_resume(&session);
            assert!(again.session_summary(&session)["retry"].is_null());
            assert!(
                !again
                    .events(&session.id, 0, 1000)
                    .unwrap()
                    .iter()
                    .any(|e| e.kind.starts_with("auto_resume")),
                "ordinary Stop emitted retry events"
            );
        }
    }

    #[tokio::test]
    async fn retry_restore_blocked_web_turn_keeps_its_summary_and_terminal_skip() {
        for block in ["remote_control_ended", "remote_floor_cancel"] {
            let (hub, session) = idle_chat();
            failed_retry(&hub, &session);
            hub.append(
                &session,
                "mux",
                "turn_control",
                json!({"turnId": "later-turn", "control": "web"}),
            );
            hub.append(&session, "mux", block, json!({"turnId": "later-turn"}));
            session.meta.lock().unwrap().last_turn = None;
            hub.restore_auto_resume(&session);
            let row = hub.session_summary(&session);
            assert_eq!(row["lastTurn"]["turnId"], "later-turn");
            assert!(row["retry"].is_null());
            hub.append(&session, "mux", "remote_control_restored", json!({}));
            let (again, session) = restart(&hub, &session).await;
            again.restore_auto_resume(&session);
            assert!(again.session_summary(&session)["retry"].is_null());
        }
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

    #[test]
    fn finish_auto_resume_and_replacement_share_the_lock_order() {
        let (hub, session) = idle_chat();
        let (finish_done_tx, finish_done_rx) = std::sync::mpsc::channel();
        let (seal_handle_tx, seal_handle_rx) = std::sync::mpsc::channel();
        let (sealed_before_append_tx, sealed_before_append_rx) = std::sync::mpsc::channel();
        let finish_hub = hub.clone();
        let finish_session = session.clone();
        let finish = std::thread::spawn(move || {
            let seal_hub = finish_hub.clone();
            let seal_session = finish_session.clone();
            super::set_after_finish_replaced_check(Box::new(move || {
                let (seal_done_tx, seal_done_rx) = std::sync::mpsc::channel();
                let seal = std::thread::spawn(move || {
                    seal_hub.seal_retry_replacement(&seal_session);
                    let _ = seal_done_tx.send(());
                });
                seal_handle_tx.send(seal).unwrap();
                // An append-only fence can complete here, between the replaced check and
                // the stale terminal append. The ordered fence must wait for finish.
                sealed_before_append_tx
                    .send(seal_done_rx.recv_timeout(std::time::Duration::from_millis(100)).is_ok())
                    .unwrap();
            }));
            finish_hub.finish_auto_resume(
                &finish_session,
                &CutTurn {
                    from: None,
                    prompt_id: "finish-prompt",
                    turn_id: "finish-turn",
                    control: Control::Local,
                    trust_gate: false,
                    error: "stream disconnected",
                    not_before: None,
                },
                1,
                &[],
                Err(RpcError::invalid_params("folder disappeared")),
                false,
            );
            finish_done_tx.send(()).unwrap();
        });
        let seal = seal_handle_rx.recv_timeout(std::time::Duration::from_secs(5)).unwrap();
        assert!(!sealed_before_append_rx.recv_timeout(std::time::Duration::from_secs(5)).unwrap());
        finish_done_rx
            .recv_timeout(std::time::Duration::from_secs(5))
            .expect("replacement must not block terminal retry admission");
        finish.join().unwrap();
        seal.join().unwrap();
        assert!(session.replaced.load(std::sync::atomic::Ordering::SeqCst));
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
            // Committed, as `transfer_commit` marks it: only a committed move is replaced.
            old.meta.lock().unwrap().moved_to = Some(json!({}));
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
        // Committed, as `transfer_commit` marks it: only a committed move is replaced.
        old.meta.lock().unwrap().moved_to = Some(json!({}));
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
                not_before: None,
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
                not_before: None,
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

    #[tokio::test]
    async fn retry_restore_does_not_replay_a_manual_retry_stopped_before_dispatch() {
        let (hub, session) = idle_chat();
        failed_retry(&hub, &session);
        hub.append(
            &session,
            "mux",
            "auto_resume_manual",
            json!({
                "turnId": "later-turn",
                "promptId": "later-prompt",
                "manualPromptId": "later-prompt~resume-1",
                "error": "stream disconnected",
                "control": "local",
                "trustGate": false
            }),
        );
        hub.append(&session, "mux", "auto_resume_stopped", json!({"turnId": "later-turn"}));
        hub.restore_auto_resume(&session);
        assert_eq!(hub.session_summary(&session)["retry"], Value::Null);
    }
}
