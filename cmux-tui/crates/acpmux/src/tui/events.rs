//! Part of the TUI `App`: daemon notifications and background-task messages.

use super::*;

impl App {
    // --------------------------------------------------------- inbound

    pub(super) fn on_notification(&mut self, m: &str, p: Value) {
        let sid = p.get("sessionId").and_then(Value::as_str).map(str::to_owned);
        match m {
            method::SESSION_UPDATE => {
                if let Some(id) = sid {
                    self.transcripts.entry(id).or_default().apply_update(&p);
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
                            .find(|s| s.get("sessionId").and_then(Value::as_str) == Some(&id))
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
                    self.transcripts.entry(id).or_default().apply_event(&p);
                }
            }
            method::MUX_SESSION_CHANGED => {
                if let Some(s) = p.get("session") {
                    let id = s.get("sessionId").and_then(Value::as_str).unwrap_or("").to_owned();
                    if p.get("kind").and_then(Value::as_str) == Some("purged") {
                        self.sessions
                            .retain(|x| x.get("sessionId").and_then(Value::as_str) != Some(&id));
                        self.transcripts.remove(&id);
                        self.attention.remove(&id);
                        self.selected = self.selected.min(self.row_count().saturating_sub(1));
                        return;
                    }
                    if let Some(slot) = self
                        .sessions
                        .iter_mut()
                        .find(|x| x.get("sessionId").and_then(Value::as_str) == Some(&id))
                    {
                        *slot = s.clone();
                    } else {
                        self.sessions.push(s.clone());
                    }
                    self.sort_sessions();
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
            method::MUX_PERMISSION_PENDING => {
                let title = p
                    .pointer("/request/toolCall/title")
                    .and_then(Value::as_str)
                    .unwrap_or("permission");
                let who = sid
                    .as_deref()
                    .and_then(|id| {
                        self.sessions
                            .iter()
                            .find(|s| s.get("sessionId").and_then(Value::as_str) == Some(id))
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
                self.status = "event stream lagged; reattach with Enter on the session".into()
            }
            _ => {}
        }
    }

    pub(super) fn sort_sessions(&mut self) {
        let selected_id = self.selected_id();
        self.sessions.sort_by(|a, b| {
            let ua = a.get("updatedAt").and_then(Value::as_u64).unwrap_or(0);
            let ub = b.get("updatedAt").and_then(Value::as_u64).unwrap_or(0);
            ub.cmp(&ua)
        });
        if let Some(id) = selected_id
            && let Some(i) = self
                .sessions
                .iter()
                .position(|s| s.get("sessionId").and_then(Value::as_str) == Some(&id))
        {
            self.selected = i + self.drafts.len();
        }
    }

    pub(super) fn on_msg(&mut self, msg: AppMsg) {
        match msg {
            AppMsg::Sessions(list) => {
                let had = !self.sessions.is_empty();
                self.sessions = list;
                self.sort_sessions();
                if !had && !self.sessions.is_empty() && self.drafts.is_empty() {
                    self.select(0);
                }
            }
            AppMsg::Attached { id, detail, events } => {
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
                let mut t = Transcript::default();
                for e in &events {
                    t.apply_event(e);
                }
                t.status = detail.get("status").and_then(Value::as_str).unwrap_or("").to_owned();
                t.mode = detail.get("currentModeId").and_then(Value::as_str).map(str::to_owned);
                t.model = detail.get("model").and_then(Value::as_str).map(str::to_owned);
                self.details.insert(id.clone(), detail);
                self.transcripts.insert(id, t);
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
