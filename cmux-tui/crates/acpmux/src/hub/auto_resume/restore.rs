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
        let mut cloud_mobile = false;
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
                    cloud_mobile =
                        e.msg.get("cloudMobile").and_then(Value::as_bool).unwrap_or(false);
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
        session.floor.cloud_mobile_turn.store(cloud_mobile, std::sync::atomic::Ordering::SeqCst);
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

        // A copied machine's first start (`clone_boot.rs`): the wait belongs to the machine it
        // was copied from. Settle it here for good, so no later start of the copy restores it.
        if let Some(from) = self.clone_of()
            && (retry.is_some() || manual.is_some() || !has_retry_marker)
        {
            let prompt_id = retry
                .as_ref()
                .map(|r| json!(r.prompt_id))
                .unwrap_or_else(|| last.msg.get("promptId").cloned().unwrap_or(Value::Null));
            self.append(
                session,
                "mux",
                "auto_resume_skipped",
                json!({
                    "turnId": turn_id, "promptId": prompt_id,
                    "attempt": retry.as_ref().map(|r| r.attempt),
                    "skipped": "clone_boot", "cloneOf": from,
                }),
            );
            return;
        }

        // Never substitute default retries for a config currently being changed. Wait for
        // the writer off this synchronous path, then reclaim restoration for this instance.
        let delays = match self.config.try_read() {
            Ok(config) => {
                let configured = config.auto_resume_delays_ms.clone();
                drop(config);
                super::effective_delays(configured)
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
            // A chat past its context window gets one attempt, at once (`compact_first.rs`).
            let delays = if reason == RetryReason::Context {
                super::compact_first::waits(&delays)
            } else {
                delays.clone()
            };
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
        // A context attempt that already compacted: its compaction's end settled what follows.
        let compacted =
            format!("{}{}{}", retry.prompt_id, super::compact_first::SUFFIX, retry.attempt);
        if retry.reason == RetryReason::Context && self.logged_prompt(session, &compacted).is_some()
        {
            return;
        }
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
            let attempt = usize::try_from(retry.attempt).unwrap_or(usize::MAX);
            hub.resume_or_compact(&session, cut, attempt).await;
        });
    }
}

#[cfg(test)]
#[path = "restore_tests.rs"]
mod tests;
