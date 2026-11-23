//! Part of the TUI `App`: daemon notifications and background-task messages.

use super::*;

impl App {
    // --------------------------------------------------------- inbound

    pub(super) fn on_notification(&mut self, m: &str, p: Value) {
        let sid = session_route_id(&p);
        match m {
            method::SESSION_UPDATE => {
                if let Some(id) = sid {
                    self.transcripts.entry(id).or_insert_with(Transcript::paging).apply_update(&p);
                }
            }
            method::MUX_EVENT => {
                if let Some(id) = sid {
                    let kind = p.get("kind").and_then(Value::as_str).unwrap_or("");
                    let level = match kind {
                        "turn_error" => 3,
                        "turn_end" => 1,
                        _ => 0,
                    };
                    if level > 0 && self.selected_id().as_deref() != Some(&id) {
                        let e = self.attention.entry(id.clone()).or_insert(0);
                        *e = (*e).max(level);
                        let who = self
                            .sessions
                            .iter()
                            .find(|s| session_route_id(s).as_ref() == Some(&id))
                            .and_then(|s| s.get("name").and_then(Value::as_str))
                            .unwrap_or("session")
                            .to_owned();
                        super::notify::send(
                            "acpmux",
                            &if level == 3 {
                                format!("{who} failed")
                            } else {
                                format!("{who} finished")
                            },
                        );
                    }
                    self.transcripts
                        .entry(id.clone())
                        .or_insert_with(Transcript::paging)
                        .apply_event(&p);
                    self.follow_removed_rows(&id);
                }
            }
            method::MUX_SESSION_CHANGED => {
                if let Some(s) = p.get("session") {
                    let Some(id) = sid.clone().or_else(|| session_route_id(s)) else { return };
                    if p.get("kind").and_then(Value::as_str) == Some("purged") {
                        self.sessions.retain(|x| session_route_id(x).as_ref() != Some(&id));
                        self.transcripts.remove(&id);
                        self.attention.remove(&id);
                        self.selected = self.selected.min(self.row_count().saturating_sub(1));
                        return;
                    }
                    // One row changed: it moves to its place, and the list is not sorted again
                    // (a sort per change read every row's `updatedAt`, ~3,000 of them).
                    let same = |x: &Value| session_route_id(x).as_ref() == Some(&id);
                    match self.sessions.iter_mut().enumerate().find(|(_, x)| same(x)) {
                        Some((at, row)) => {
                            let moved = updated_at(row) != updated_at(s);
                            *row = s.clone();
                            if moved {
                                self.move_into_place(at);
                            }
                        }
                        None => {
                            self.sessions.push(s.clone());
                            self.move_into_place(self.sessions.len() - 1);
                        }
                    }
                    // The bar said a permission was needed: clear it once nobody waits.
                    if self.status.starts_with("permission needed in")
                        && !self.sessions.iter().any(|x| {
                            x.get("pendingPermissions").and_then(Value::as_u64).unwrap_or(0) > 0
                        })
                    {
                        self.status = super::DEFAULT_STATUS.into();
                    }
                }
            }
            // Watchers now also get permission_pending for sessions they do not
            // attach to; the TUI already marks those from session_changed.
            method::MUX_PERMISSION_PENDING
                if p.get("via").and_then(Value::as_str) == Some("watch") => {}
            method::MUX_PERMISSION_PENDING => {
                let title = p
                    .pointer("/request/toolCall/title")
                    .and_then(Value::as_str)
                    .unwrap_or("permission");
                let who = sid
                    .as_deref()
                    .and_then(|id| {
                        self.sessions.iter().find(|s| session_route_id(s).as_deref() == Some(id))
                    })
                    .and_then(|s| s.get("name").and_then(Value::as_str))
                    .unwrap_or("?");
                self.status = format!("permission needed in {who}: {title}  (y / n / 1-9)");
                super::notify::send("acpmux", &format!("{who} needs a permission: {title}"));
                if let Some(id) = sid.clone()
                    && self.selected_id().as_deref() != Some(&id)
                {
                    let e = self.attention.entry(id).or_insert(0);
                    *e = (*e).max(2);
                }
            }
            "_acpmux/lagged" => {
                // `_acpmux/lagged` is connection-wide and intentionally has
                // no session id.  Replay every session this TUI has attached
                // to from its own last applied sequence, with one request per
                // session at most while the recovery is in flight.
                let ids: Vec<String> = self.attached.iter().cloned().collect();
                let mut recovering = 0;
                for id in ids {
                    let Some(after_seq) = self.transcripts.get(&id).map(|t| t.last_seq) else {
                        continue;
                    };
                    if self.recover_after_lag(&id, after_seq) {
                        recovering += 1;
                    }
                }
                self.status = if recovering == 0 {
                    "event stream lagged; recovery required".into()
                } else {
                    format!("event stream lagged; recovering {recovering} session(s)…")
                };
            }
            _ => {}
        }
    }

    pub(super) fn sort_sessions(&mut self) {
        self.sort_sessions_preserving(self.selected_id());
    }

    /// Puts the row at `at`, the only one out of order, where the stable sort of
    /// [`Self::sort_sessions`] puts it (among rows as new, by where it was), and keeps the
    /// selection on the row it was on.
    fn move_into_place(&mut self, at: usize) {
        if at >= self.sessions.len() {
            return;
        }
        let row = self.sessions.remove(at);
        let key = updated_at(&row);
        let newer = self.sessions.partition_point(|s| updated_at(s) > key);
        let as_new = self.sessions.partition_point(|s| updated_at(s) >= key);
        let to = at.clamp(newer, as_new);
        self.sessions.insert(to, row);
        // `self.selected` is not moved yet: it is the selected row's index before the move.
        let Some(selected) = self.session_index().filter(|i| *i < self.sessions.len()) else {
            return;
        };
        let now = if selected == at {
            to
        } else if at < selected && selected <= to {
            selected - 1
        } else if to <= selected && selected < at {
            selected + 1
        } else {
            selected
        };
        self.selected = now + self.drafts.len();
    }

    fn sort_sessions_preserving(&mut self, selected_id: Option<String>) {
        self.sessions.sort_by_key(|s| std::cmp::Reverse(updated_at(s)));
        if let Some(id) = selected_id
            && let Some(i) =
                self.sessions.iter().position(|s| session_route_id(s).as_ref() == Some(&id))
        {
            self.selected = i + self.drafts.len();
        }
    }

    pub(super) fn on_msg(&mut self, msg: AppMsg) {
        match msg {
            AppMsg::Sessions(list) => {
                let had = !self.sessions.is_empty();
                let selected_id = self.selected_id();
                self.sessions = list;
                self.sort_sessions_preserving(selected_id);
                if !had && !self.sessions.is_empty() && self.drafts.is_empty() {
                    self.select(0);
                }
            }
            AppMsg::Attached { id, detail, events, after_seq, has_more, last_seq: _ } => {
                if let Some(after_seq) = after_seq {
                    let mut recovered = 0;
                    let mut next_seq = after_seq;
                    if let Some(t) = self.transcripts.get_mut(&id) {
                        for e in &events {
                            let seq = e.get("seq").and_then(Value::as_u64).unwrap_or(0);
                            if seq <= t.last_seq {
                                continue;
                            }
                            t.apply_event(e);
                            recovered += 1;
                        }
                        if let Some(status) = detail.get("status").and_then(Value::as_str) {
                            t.status = status.to_owned();
                        }
                        next_seq = t.last_seq;
                    }
                    self.follow_removed_rows(&id);
                    self.details.insert(id.clone(), detail);
                    let total_recovered = self.recovery_replayed.entry(id.clone()).or_default();
                    *total_recovered += recovered;
                    if has_more {
                        let page = self.recovery_pages.get(&id).copied().unwrap_or(1);
                        if recovered == 0 || next_seq <= after_seq {
                            let total = self.recovery_replayed.remove(&id).unwrap_or(recovered);
                            let start = self.recovery_start.remove(&id).unwrap_or(after_seq);
                            self.recovery_pages.remove(&id);
                            self.recovery_in_flight.remove(&id);
                            self.status = format!(
                                "recovery stopped after seq {next_seq}; {total} events recovered from seq {start}, more remain"
                            );
                        } else if page >= super::MAX_RECOVERY_PAGES {
                            let total = self.recovery_replayed.remove(&id).unwrap_or(recovered);
                            let start = self.recovery_start.remove(&id).unwrap_or(after_seq);
                            self.recovery_pages.remove(&id);
                            self.recovery_in_flight.remove(&id);
                            self.status = format!(
                                "recovery stopped after {page} pages at seq {next_seq}; {total} events recovered from seq {start}, more remain"
                            );
                        } else {
                            self.recovery_pages.insert(id.clone(), page + 1);
                            self.status = format!(
                                "recovering session after seq {next_seq} (page {page}/{})…",
                                super::MAX_RECOVERY_PAGES
                            );
                            self.request_attach(&id, Some(next_seq));
                        }
                    } else {
                        let total = self.recovery_replayed.remove(&id).unwrap_or(recovered);
                        let start = self.recovery_start.remove(&id).unwrap_or(after_seq);
                        self.recovery_pages.remove(&id);
                        self.recovery_in_flight.remove(&id);
                        self.status = format!("recovered {total} events from seq {start}");
                    }
                    return;
                }
                if events.is_empty() && self.transcripts.contains_key(&id) {
                    if let Some(t) = self.transcripts.get_mut(&id) {
                        t.mode = detail
                            .get("currentModeId")
                            .and_then(Value::as_str)
                            .map(str::to_owned)
                            .or(t.mode.clone());
                        t.model = detail
                            .get("model")
                            .and_then(Value::as_str)
                            .map(str::to_owned)
                            .or(t.model.clone());
                    }
                    self.details.insert(id, detail);
                    return;
                }
                let mut t = Transcript::paging();
                for e in &events {
                    t.apply_event(e);
                }
                // A fresh replay: folds already name its rows.
                t.removed_items.clear();
                t.status = detail.get("status").and_then(Value::as_str).unwrap_or("").to_owned();
                t.mode = detail.get("currentModeId").and_then(Value::as_str).map(str::to_owned);
                t.model = detail.get("model").and_then(Value::as_str).map(str::to_owned);
                self.details.insert(id.clone(), detail);
                self.history_more.insert(id.clone(), has_more);
                self.transcripts.insert(id, t);
            }
            AppMsg::Older { id, events, has_more } => {
                self.history_in_flight.remove(&id);
                // An empty page has nothing older to give: stop asking.
                let has_more = has_more && !events.is_empty();
                self.history_more.insert(id.clone(), has_more);
                if let Some(t) = self.transcripts.get_mut(&id) {
                    let added = t.prepend_events(&events);
                    self.shift_folds(&id, added);
                    // `offset` counts rows: keep the rows on screen where they are by keeping
                    // the distance to the end, which the prepended rows do not change.
                    if let Some(v) = self.viewport.get_mut(&id)
                        && !v.follow
                    {
                        v.keep_below = Some(v.total.saturating_sub(v.offset));
                    }
                    if self.transcript_anchor.as_ref().is_some_and(|(a, _, _)| *a == id) {
                        self.transcript_anchor = None;
                    }
                    if self.selection.as_ref().is_some_and(|s| s.session == id) {
                        self.selection = None;
                    }
                    self.status = if has_more {
                        "loaded earlier history; scroll up for more".into()
                    } else {
                        "loaded all available history".into()
                    };
                }
            }
            AppMsg::OlderFailed { id, error } => {
                self.history_in_flight.remove(&id);
                self.status = format!("earlier history failed: {error}");
            }
            AppMsg::RecoveryFailed { id, after_seq, error } => {
                self.recovery_pages.remove(&id);
                self.recovery_replayed.remove(&id);
                self.recovery_start.remove(&id);
                self.recovery_in_flight.remove(&id);
                self.status = format!("recovery failed after seq {after_seq}: {error}");
            }
            AppMsg::Agents(list, default) => {
                self.harnesses = list;
                self.default_harness = default;
            }
            AppMsg::Status(v) => {
                self.web_url = v.get("webUrl").and_then(Value::as_str).map(str::to_owned);
                self.hosts = v
                    .get("peers")
                    .and_then(Value::as_array)
                    .map(|a| {
                        a.iter()
                            .map(|p| {
                                (
                                    p.get("name").and_then(Value::as_str).unwrap_or("").to_owned(),
                                    p.get("connected").and_then(Value::as_bool).unwrap_or(false),
                                    p.get("sessions").and_then(Value::as_u64).unwrap_or(0),
                                )
                            })
                            .collect()
                    })
                    .unwrap_or_default();
            }
            AppMsg::Models(v) => self.show_model_picker(v),
            AppMsg::HarnessCatalog(id, v) => {
                if self.draft().map(|d| d.id) == Some(id)
                    && matches!(self.overlay, Overlay::Picker(ref p) if matches!(p.on_pick, PickTarget::DraftHarness))
                {
                    let filter = if let Overlay::Picker(ref p) = self.overlay {
                        p.filter.text().to_owned()
                    } else {
                        String::new()
                    };
                    self.show_harness_picker(v);
                    if let Overlay::Picker(ref mut p) = self.overlay {
                        p.filter.insert_str(&filter);
                        p.refilter();
                    }
                }
            }
            AppMsg::DraftFailed => {
                for d in self.drafts.iter_mut() {
                    d.creating = false;
                }
            }
            AppMsg::Info(s) => self.status = s,
            AppMsg::Error(e) => self.report_error(e),
            AppMsg::Created(id) => {
                self.refresh_sessions();
                self.attach(&id);
                self.pending_select = Some(id);
                self.status = DEFAULT_STATUS.into();
            }
        }
    }
}

/// A session row's sort key: its `updatedAt`, 0 without one.
fn updated_at(session: &Value) -> u64 {
    session.get("updatedAt").and_then(Value::as_u64).unwrap_or(0)
}

#[cfg(all(test, unix))]
mod peer_route_tests {
    use super::*;

    #[tokio::test]
    async fn peer_events_update_selected_transcript_and_preserve_selection_when_sorted() {
        let (mut app, _requests) = interaction_tests::app().await;
        app.drafts.clear();
        let local = json!({"sessionId": "raw", "name": "local", "updatedAt": 2});
        let remote = json!({"sessionId": "raw", "peer": "worker", "qualifiedSessionId": "worker/raw", "name": "worker/remote", "updatedAt": 1});
        app.sessions = vec![local.clone(), remote.clone()];
        app.selected = 1;
        app.transcripts.insert("worker/raw".into(), Transcript::default());
        app.on_notification(method::SESSION_UPDATE, json!({
            "sessionId": "raw", "peer": "worker",
            "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "remote reply"}}
        }));
        assert!(
            !app.transcripts["worker/raw"].items.is_empty(),
            "remote update must reach the selected transcript"
        );
        assert!(
            !app.transcripts.contains_key("raw"),
            "remote output must not enter a local transcript"
        );
        let mut changed = remote.clone();
        changed["updatedAt"] = json!(3);
        app.on_notification(
            method::MUX_SESSION_CHANGED,
            json!({"sessionId": "raw", "peer": "worker", "session": changed, "kind": "turn_start"}),
        );
        assert_eq!(app.sessions.len(), 2);
        assert_eq!(app.selected, 0);
        assert_eq!(app.selected_id().as_deref(), Some("worker/raw"));
        assert_eq!(app.sessions[1], local);
        // The returned list may already have a new order before sort_sessions runs.
        app.on_msg(AppMsg::Sessions(vec![local.clone(), remote]));
        assert_eq!(app.selected_id().as_deref(), Some("worker/raw"));
        app.on_notification(method::MUX_SESSION_CHANGED, json!({"sessionId": "raw", "peer": "worker", "session": {"sessionId": "raw"}, "kind": "purged"}));
        assert_eq!(app.sessions, vec![local]);
        assert!(!app.transcripts.contains_key("worker/raw"));
    }
}

/// What one `session_changed` costs the TUI as its list grows (Leo 2026-11-04: "never ...
/// acceptable ... linear time growth degradation"), and that a row moves to the place a full sort
/// gives it. Manual timing: `cargo test -p acpmux --lib update_cost -- --ignored --nocapture`.
#[cfg(all(test, unix))]
mod update_cost_tests {
    use super::*;

    fn rows(n: usize) -> Vec<Value> {
        (0..n)
            .map(|i| {
                let id = format!("s-{i:05}");
                json!({"sessionId": id, "name": id, "updatedAt": (n - i) as u64 / 2})
            })
            .collect()
    }

    fn changed(app: &mut App, id: &str, at: u64) {
        app.on_notification(
            method::MUX_SESSION_CHANGED,
            json!({"sessionId": id, "kind": "status",
                "session": {"sessionId": id, "name": id, "updatedAt": at}}),
        );
    }

    /// Each change leaves the list and the selection as a full stable sort would.
    #[tokio::test]
    async fn a_changed_row_takes_the_place_a_sort_gives_it() {
        let (mut app, _requests) = interaction_tests::app().await;
        app.drafts.clear();
        app.sessions = rows(40);
        app.sort_sessions();
        app.selected = 7;
        let selected = app.selected_id();
        // Rows that cross the selected one both ways, and the selected row itself moving.
        for (n, at) in
            [(3, 100), (39, 0), (20, 10), (0, 10), (12, 5), (30, 19), (7, 200), (7, 0), (33, 300)]
        {
            let id = format!("s-{n:05}");
            changed(&mut app, &id, at);
            assert_eq!(app.sessions.len(), 40);
            let at = |row: &Value| row["updatedAt"].as_u64().unwrap_or(0);
            for pair in app.sessions.windows(2) {
                assert!(at(&pair[0]) >= at(&pair[1]), "out of order after {id}");
            }
            assert_eq!(app.selected_id(), selected, "the selection stays on its row");
        }
        changed(&mut app, "new", 1_000);
        assert_eq!(app.sessions[0]["sessionId"], "new");
        assert_eq!(app.selected_id(), selected);
    }

    #[tokio::test]
    #[ignore = "manual per-event cost measurement"]
    async fn update_cost_tui_session_changed() {
        for n in [100, 1_000, 3_000] {
            let (mut app, _requests) = interaction_tests::app().await;
            app.drafts.clear();
            app.sessions = rows(n);
            app.sort_sessions();
            app.selected = n / 2;
            let rounds = 200;
            let started = std::time::Instant::now();
            for round in 0..rounds {
                // A turn's status on a row near the end: it moves to the top.
                let id = format!("s-{:05}", n - 1 - round % 10);
                changed(&mut app, &id, (n + round) as u64);
            }
            let per = started.elapsed().as_secs_f64() * 1e6 / rounds as f64;
            eprintln!("UPDATE-COST tui_session_changed n={n} per_event_us={per:.1}");
        }
    }
}
