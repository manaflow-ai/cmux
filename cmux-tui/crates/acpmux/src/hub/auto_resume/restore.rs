//! A scheduled retry survives restart at its original deadline, under the cut turn's rules.
use super::*;

impl Hub {
    /// After this session's log and queue have been restored, before held messages retry.
    /// Startup/import can resume queues repeatedly; claim this recovery pass only once.
    pub(in crate::hub) fn restore_auto_resume(self: &Arc<Self>, session: &Arc<Session>) {
        if !self
            .auto_resumes
            .restored
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(session.id.clone())
        {
            return;
        }
        let mut pending = self.auto_resumes.lock();
        if pending.contains_key(&session.id)
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
            "auto_resume_skipped",
            "auto_resume_settled",
            "auto_resume_exhausted",
        ];
        let scanned = self.store.scan_kinds(&session.id, &kinds, &mut |e: EventRecord| {
            let is_cut = e.msg["turnId"].as_str() == Some(turn_id.as_str());
            match e.kind.as_str() {
                "turn_started" if is_cut => {
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
                "auto_resume_scheduled" if is_cut => {
                    // daemon_restart records are queued continuations, not waiting retries.
                    retry = serde_json::from_value(e.msg).ok();
                }
                "auto_resume_skipped" | "auto_resume_settled" | "auto_resume_exhausted"
                    if is_cut =>
                {
                    retry = None
                }
                _ => {}
            }
            true
        });
        let Some(retry) = retry.filter(|r| {
            scanned.is_ok()
                && r.attempt > 0
                && r.attempt <= MAX_ATTEMPTS as u64
                && !r.prompt_id.is_empty()
        }) else {
            return;
        };
        if control == Control::Web && (ended || floor_cancelled) {
            return;
        }
        let id = format!("{}{SUFFIX}{}", retry.prompt_id, retry.attempt);
        if self.logged_prompt(session, &id).is_some() {
            return;
        }
        // Restore this cached summary from the durable cut turn, without re-emitting its
        // turn-ended side effects. still_cut and the retry row read this same summary.
        let mut summary = serde_json::Map::new();
        for key in super::super::views::LAST_TURN_KEYS {
            if let Some(value) = last.msg.get(key) {
                summary.insert(key.to_owned(), value.clone());
            }
        }
        summary.insert("endedAt".into(), json!(last.at));
        session.meta.lock().unwrap_or_else(|e| e.into_inner()).last_turn =
            Some(Value::Object(summary));
        // Stop need not wait for lazy log loading. If it arrived before this mark could be
        // restored, persist its decision now; later restarts must respect that Stop too.
        if session.cancels.load(std::sync::atomic::Ordering::SeqCst) != 0 {
            self.settled_unretried(session, &turn_id, "stopped");
            return;
        }
        let wake = Arc::new(Notify::new());
        pending.insert(
            session.id.clone(),
            Mark::Waiting {
                turn: turn_id.clone(),
                retry: Some(retry.clone()),
                _wake: Wake(wake.clone()),
            },
        );
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
