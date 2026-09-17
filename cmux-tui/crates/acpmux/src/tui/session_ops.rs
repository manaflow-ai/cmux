//! Part of the TUI `App`; see `tui/mod.rs`.

use super::*;

impl App {
    // ------------------------------------------------------------ overlays

    /// Ctrl-t: a blank session tab at the top of the sidebar with the cursor
    /// in the editor. The session is created when the first message is sent.
    pub(super) fn open_draft(&mut self) {
        // The target host: the filtered host if one is chosen, else the host of
        // the session we were on.
        let peer = match self.host_filter.as_deref() {
            Some("local") => None,
            Some(h) => Some(h.to_owned()),
            None => self.selected_session().and_then(|s| s.get("peer").and_then(Value::as_str).map(str::to_owned)),
        };
        let agent = self
            .selected_session()
            .and_then(|s| s.get("agent").and_then(Value::as_str).map(str::to_owned))
            .or_else(|| self.default_agent.clone())
            .or_else(|| self.agents.first().cloned())
            .unwrap_or_default();
        let cwd = self
            .selected_session()
            .and_then(|s| s.get("cwd").and_then(Value::as_str))
            .map(str::to_owned)
            .unwrap_or_else(|| std::env::current_dir().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default());
        let policy = self
            .selected_session()
            .and_then(|s| s.get("policy").and_then(Value::as_str))
            .unwrap_or("ask")
            .to_owned();
        let id = self.next_draft_id;
        self.next_draft_id += 1;
        self.drafts.insert(0, Draft { id, peer, agent, cwd, policy, model: None, creating: false, text: Editor::default(), errors: Vec::new() });
        self.selected = 0;
        self.selection = None;
        self.focus = Focus::Input;
        self.status = "new session · type a message and press Enter · :agent NAME · :cwd PATH · Esc discards".into();
    }

    pub(super) fn discard_draft(&mut self) {
        if !self.on_draft() {
            return;
        }
        let i = self.selected;
        self.drafts.remove(i);
        if self.row_count() > 0 {
            self.select(i.min(self.row_count() - 1));
        } else {
            self.selected = 0;
        }
        self.status = DEFAULT_STATUS.into();
    }

    /// Create the draft's session and send `text` as its first message.
    pub(super) fn create_from_draft(&mut self, text: String) {
        let Some(d) = self.draft_mut() else { return };
        if d.creating {
            return;
        }
        d.creating = true;
        let d = d.clone();
        if d.agent.is_empty() {
            self.report_error("no agents configured; edit ~/.acpmux/config.json".into());
            return;
        }
        let mut params = json!({"cwd": d.cwd, "mcpServers": [], "_meta": {"acpmux": {"agent": d.agent, "policy": d.policy}}});
        if let Some(p) = &d.peer {
            params["_meta"]["acpmux"]["peer"] = json!(p);
        }
        let client = self.client.clone();
        let tx = self.tx.clone();
        let model = d.model.clone();
        self.status = format!("starting {}…", d.agent);
        tokio::spawn(async move {
            match client.request(method::SESSION_NEW, params).await {
                Ok(v) => {
                    if let Some(id) = v.get("sessionId").and_then(Value::as_str) {
                        let _ = tx.send(AppMsg::Created(id.to_owned()));
                        let id = id.to_owned();
                        let c = client.clone();
                        tokio::spawn(async move {
                            if let Some(m) = model {
                                let _ = c.request(method::SESSION_SET_MODEL, json!({"sessionId": id, "modelId": m})).await;
                            }
                            let _ = c.request(method::SESSION_PROMPT, json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]})).await;
                        });
                    }
                }
                Err(e) => {
                    let _ = tx.send(AppMsg::Error(e.to_string()));
                    let _ = tx.send(AppMsg::DraftFailed);
                }
            }
        });
    }

    pub(super) fn open_new_session(&mut self) {
        let cwd = self
            .selected_session()
            .and_then(|s| s.get("cwd").and_then(Value::as_str))
            .map(str::to_owned)
            .unwrap_or_else(|| std::env::current_dir().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default());
        let agent = self
            .default_agent
            .as_ref()
            .and_then(|d| self.agents.iter().position(|a| a == d))
            .unwrap_or(0);
        self.overlay = Overlay::NewSession(NewForm {
            agents: self.agents.clone(),
            agent,
            name: String::new(),
            cwd,
            policy: 0,
            prompt: String::new(),
            field: 1,
        });
    }

    pub(super) fn submit_new_session(&mut self, form: &NewForm) {
        let Some(agent) = form.agents.get(form.agent) else {
            self.report_error("no agents configured; edit ~/.acpmux/config.json".into());
            return;
        };
        if !form.name.is_empty() {
            if let Err(e) = crate::session_name::validate(&form.name) {
                self.status = e;
                return;
            }
        }
        let mut meta = json!({"agent": agent, "policy": POLICIES[form.policy]});
        if !form.name.is_empty() {
            meta["name"] = json!(form.name);
        }
        let params = json!({"cwd": form.cwd, "mcpServers": [], "_meta": {"acpmux": meta}});
        let first = form.prompt.trim().to_owned();
        let client = self.client.clone();
        let tx = self.tx.clone();
        self.status = "starting agent…".into();
        tokio::spawn(async move {
            match client.request(method::SESSION_NEW, params).await {
                Ok(v) => {
                    if let Some(id) = v.get("sessionId").and_then(Value::as_str) {
                        let _ = tx.send(AppMsg::Created(id.to_owned()));
                        if !first.is_empty() {
                            let id = id.to_owned();
                            let c = client.clone();
                            tokio::spawn(async move {
                                let _ = c.request(method::SESSION_PROMPT, json!({"sessionId": id, "prompt": [{"type": "text", "text": first}]})).await;
                            });
                        }
                    }
                    let _ = tx.send(AppMsg::Info("session created".into()));
                }
                Err(e) => {
                    let _ = tx.send(AppMsg::Error(e.to_string()));
                }
            }
        });
        self.overlay = Overlay::None;
        self.focus = Focus::Input;
    }

    /// One picker for harness and model, like opencode's model switcher:
    /// every harness as a header, its models underneath, filter as you type.
    pub(super) fn open_model_picker(&mut self) {
        let client = self.client.clone();
        let tx = self.tx.clone();
        tokio::spawn(async move {
            match client.request("_acpmux/models", json!({})).await {
                Ok(v) => { let _ = tx.send(AppMsg::Models(v)); }
                Err(e) => { let _ = tx.send(AppMsg::Error(e.to_string())); }
            }
        });
        self.status = "loading models…".into();
    }

    pub(super) fn show_model_picker(&mut self, catalog: Value) {
        let current_agent = if self.on_draft() {
            self.draft().map(|d| d.agent.clone())
        } else {
            self.selected_session().and_then(|s| s.get("agent").and_then(Value::as_str).map(str::to_owned))
        };
        let current_model = if self.on_draft() {
            None
        } else {
            self.selected_id().and_then(|id| self.transcripts.get(&id)).and_then(|t| t.model.clone())
        };
        let live_session = if self.on_draft() { None } else { self.selected_id() };
        let mut rows = Vec::new();
        // For a live session, merge in the session's own model list, which may
        // be fresher than the daemon's cache.
        let live_models: Vec<(String, String)> = live_session
            .as_ref()
            .and_then(|id| self.details.get(id))
            .and_then(|d| d.get("configOptions").and_then(Value::as_array))
            .and_then(|opts| opts.iter().find(|o| o.get("id").and_then(Value::as_str) == Some("model")))
            .and_then(|o| o.get("options").and_then(Value::as_array))
            .map(|a| a.iter().map(|c| (c.get("value").and_then(Value::as_str).unwrap_or("").to_owned(), c.get("name").and_then(Value::as_str).unwrap_or("").to_owned())).collect())
            .unwrap_or_default();
        let mut harnesses: Vec<Value> = catalog.get("harnesses").and_then(Value::as_array).cloned().unwrap_or_default();
        // Current harness first.
        let cur_key_for_sort = match (&self.draft().and_then(|d| d.peer.clone()).or_else(|| self.selected_session().and_then(|s| s.get("peer").and_then(Value::as_str).map(str::to_owned))), &current_agent) {
            (Some(p), Some(a)) => Some(format!("{p}/{a}")),
            (None, Some(a)) => Some(a.clone()),
            _ => None,
        };
        harnesses.sort_by_key(|h| if h.get("agent").and_then(Value::as_str) == cur_key_for_sort.as_deref() { 0 } else { 1 });
        let current_peer = if self.on_draft() { self.draft().and_then(|d| d.peer.clone()) } else { self.selected_session().and_then(|s| s.get("peer").and_then(Value::as_str).map(str::to_owned)) };
        let current_key = match (&current_peer, &current_agent) {
            (Some(p), Some(a)) => Some(format!("{p}/{a}")),
            (None, Some(a)) => Some(a.clone()),
            _ => None,
        };
        for h in harnesses {
            let agent = h.get("agent").and_then(Value::as_str).unwrap_or("").to_owned();
            let is_current = Some(&agent) == current_key.as_ref();
            let note = if is_current { "current".to_owned() } else if live_session.is_some() { "forks into a new session".to_owned() } else { String::new() };
            rows.push(PickRow { value: String::new(), label: agent.clone(), header: true, group: agent.clone(), note });
            let models: Vec<(String, String)> = if is_current && !live_models.is_empty() {
                live_models.clone()
            } else {
                h.get("models").and_then(Value::as_array).map(|a| a.iter().map(|m| (m.get("id").and_then(Value::as_str).unwrap_or("").to_owned(), m.get("name").and_then(Value::as_str).unwrap_or("").to_owned())).collect()).unwrap_or_default()
            };
            for (id, name) in models {
                let label = if name.is_empty() || name == id { id.clone() } else { format!("{name}  {id}") };
                rows.push(PickRow { value: id, label, header: false, group: agent.clone(), note: String::new() });
            }
        }
        let cur = current_model.clone();
        let mut p = Picker::new("Model", rows, cur.as_deref(), PickTarget::Model(live_session), "type to filter · ↑↓ wheel · Enter or click picks · Esc");
        // Land on the current harness's first model when no exact model matched.
        if current_model.is_none() {
            p.cursor = p.visible.iter().position(|&i| !p.rows[i].header).unwrap_or(0);
        }
        self.overlay = Overlay::Picker(p);
        self.status = DEFAULT_STATUS.into();
    }

    pub(super) fn open_mode_picker(&mut self) {
        if self.on_draft() {
            self.status = "mode is set once the session runs; permissions are the draft-time control".into();
            return;
        }
        let Some(id) = self.selected_id() else { return };
        let detail = self.details.get(&id).cloned().unwrap_or(Value::Null);
        let choices: Vec<(String, String)> = detail
            .pointer("/modes/availableModes")
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .map(|m| {
                        let v = m.get("id").and_then(Value::as_str).unwrap_or("").to_owned();
                        let n = m.get("name").and_then(Value::as_str).unwrap_or(&v).to_owned();
                        (v, n)
                    })
                    .collect()
            })
            .unwrap_or_default();
        if choices.is_empty() {
            self.report_error("this agent has no modes".into());
            return;
        }
        let current = self.transcripts.get(&id).and_then(|t| t.mode.clone()).unwrap_or_default();
        let rows = choices.into_iter().map(|(v, l)| PickRow { value: v, label: l, header: false, group: String::new(), note: String::new() }).collect();
        self.overlay = Overlay::Picker(Picker::new("Mode", rows, Some(&current), PickTarget::Mode(id), "type to filter · ↑↓ wheel · Enter or click picks · Esc"));
    }

    /// Permission policy: works on a draft or a live session.
    pub(super) fn open_policy_picker(&mut self) {
        let live = if self.on_draft() { None } else { self.selected_id() };
        let current = if self.on_draft() {
            self.draft().map(|d| d.policy.clone())
        } else {
            self.selected_session().and_then(|s| s.get("policy").and_then(Value::as_str).map(str::to_owned))
        }
        .unwrap_or_else(|| "ask".into());
        let rows = POLICIES
            .iter()
            .map(|p| {
                let note = match *p {
                    "ask" => "you approve each tool call",
                    "approve-reads" => "reads auto, writes ask",
                    "approve-all" => "nothing asks",
                    _ => "everything denied",
                };
                PickRow { value: p.to_string(), label: format!("{p:<14} {note}"), header: false, group: String::new(), note: String::new() }
            })
            .collect();
        self.overlay = Overlay::Picker(Picker::new("Permissions", rows, Some(&current), PickTarget::Policy(live), "↑↓ · Enter or click picks · Esc"));
    }

    /// "Thinking": whichever effort-like option the harness exposes.
    pub(super) fn open_thinking_picker(&mut self) {
        if self.on_draft() {
            self.status = "thinking level is set once the session runs; send the first message first".into();
            return;
        }
        let Some(id) = self.selected_id() else { return };
        let detail = self.details.get(&id).cloned().unwrap_or(Value::Null);
        let ids: Vec<String> = detail
            .get("configOptions")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(|o| o.get("id").and_then(Value::as_str).map(str::to_owned)).collect())
            .unwrap_or_default();
        for cand in ["reasoning_effort", "effort", "thinking", "reasoning"] {
            if ids.iter().any(|i| i == cand) {
                self.open_config_picker(cand);
                return;
            }
        }
        self.report_error("this harness has no thinking setting; Claude's thinking follows the model".into());
    }

    pub(super) fn open_directory_dialog(&mut self) {
        let cwd = if self.on_draft() {
            self.draft().map(|d| d.cwd.clone()).unwrap_or_default()
        } else {
            self.selected_session().and_then(|s| s.get("cwd").and_then(Value::as_str)).unwrap_or("").to_owned()
        };
        let mut text = Editor::default();
        text.set_text(&cwd);
        self.overlay = Overlay::Directory { text };
    }

    /// Apply a directory: on a draft it just changes; on a live session it
    /// opens a new draft on the same harness in the new directory.
    pub(super) fn apply_directory(&mut self, path: String) {
        let path = if let Some(rest) = path.strip_prefix("~/") {
            dirs::home_dir().map(|h| h.join(rest).to_string_lossy().into_owned()).unwrap_or(path.clone())
        } else {
            path
        };
        let remote = self.draft().and_then(|d| d.peer.clone()).or_else(|| self.selected_session().and_then(|s| s.get("peer").and_then(Value::as_str).map(str::to_owned)));
        if remote.is_none() && !std::path::Path::new(&path).is_dir() {
            self.report_error(format!("not a directory: {path}"));
            return;
        }
        if self.on_draft() {
            self.draft_mut().unwrap().cwd = path.clone();
            self.status = format!("draft directory: {}", render::shorten_path(&path));
        } else {
            self.open_draft();
            if let Some(d) = self.draft_mut() {
                d.cwd = path.clone();
            }
            self.status = format!("new session tab in {}   (a running agent cannot change directory)", render::shorten_path(&path));
        }
    }

    pub(super) fn open_config_picker(&mut self, config_id: &str) {
        let Some(id) = self.selected_id() else { return };
        let detail = self.details.get(&id).cloned().unwrap_or(Value::Null);
        let Some(opt) = detail
            .get("configOptions")
            .and_then(Value::as_array)
            .and_then(|a| a.iter().find(|o| o.get("id").and_then(Value::as_str) == Some(config_id)).cloned())
        else {
            self.report_error(format!("no config option {config_id}"));
            return;
        };
        let choices: Vec<(String, String)> = opt
            .get("options")
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .map(|c| {
                        let v = c.get("value").and_then(Value::as_str).unwrap_or("").to_owned();
                        let n = c.get("name").and_then(Value::as_str).unwrap_or(&v).to_owned();
                        (v, n)
                    })
                    .collect()
            })
            .unwrap_or_default();
        if choices.is_empty() {
            self.report_error(format!("{config_id} is not a list; use :set {config_id}=value"));
            return;
        }
        let current = opt.get("currentValue").and_then(Value::as_str).unwrap_or("").to_owned();
        let rows = choices.into_iter().map(|(v, l)| PickRow { value: v, label: l, header: false, group: String::new(), note: String::new() }).collect();
        self.overlay = Overlay::Picker(Picker::new(config_id, rows, Some(&current), PickTarget::Config(id, config_id.to_owned()), "type to filter · ↑↓ wheel · Enter or click picks · Esc"));
    }

    pub(super) fn apply_pick(&mut self, target: PickTarget, value: String, group: String) {
        match target {
            PickTarget::Model(live) => {
                let current_agent = if self.on_draft() {
                    self.draft().map(|d| d.agent.clone())
                } else {
                    self.selected_session().and_then(|s| s.get("agent").and_then(Value::as_str).map(str::to_owned))
                };
                let current_peer = self.selected_session().and_then(|s| s.get("peer").and_then(Value::as_str).map(str::to_owned));
                let current_key = match (&current_peer, &current_agent) {
                    (Some(p), Some(a)) => Some(format!("{p}/{a}")),
                    (None, Some(a)) => Some(a.clone()),
                    _ => None,
                };
                let same_harness = current_key.as_deref() == Some(group.as_str());
                let (peer, agent) = match group.split_once('/') {
                    Some((p, a)) => (Some(p.to_owned()), a.to_owned()),
                    None => (None, group.clone()),
                };
                if live.is_none() && self.on_draft() {
                    let d = self.draft_mut().unwrap();
                    d.peer = peer;
                    d.agent = agent;
                    d.model = if value == "default" { None } else { Some(value.clone()) };
                    self.status = format!("draft: {group} · {value}");
                } else if let Some(id) = live {
                    if same_harness {
                        self.request_bg(method::SESSION_SET_MODEL, json!({"sessionId": id.clone(), "modelId": value.clone()}), Some(format!("model {value}")));
                        self.refresh_detail_later(&id);
                    } else {
                        // Another harness: start a new session tab with it.
                        self.open_draft();
                        if let Some(d) = self.draft_mut() {
                            d.peer = peer;
                            d.agent = agent;
                            d.model = if value == "default" { None } else { Some(value.clone()) };
                        }
                        self.status = format!("new session tab: {group} · {value}   (a running agent cannot change harness)");
                    }
                }
            }
            PickTarget::Policy(live) => match live {
                Some(id) => {
                    self.request_bg(method::MUX_SET_POLICY, json!({"sessionId": id.clone(), "policy": value.clone()}), Some(format!("policy {value}")));
                    // The daemon answers before the list refresh; re-read shortly after.
                    let client = self.client.clone();
                    let tx = self.tx.clone();
                    tokio::spawn(async move {
                        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
                        if let Ok(v) = client.request(method::MUX_SESSIONS, json!({})).await {
                            let _ = tx.send(AppMsg::Sessions(v.get("sessions").and_then(Value::as_array).cloned().unwrap_or_default()));
                        }
                    });
                }
                None => {
                    if let Some(d) = self.draft_mut() {
                        d.policy = value.clone();
                    }
                    self.status = format!("draft policy: {value}");
                }
            },
            PickTarget::Mode(id) => {
                self.request_bg(method::SESSION_SET_MODE, json!({"sessionId": id.clone(), "modeId": value.clone()}), Some(format!("mode {value}")));
                self.refresh_detail_later(&id);
            }
            PickTarget::Config(id, cid) => {
                let v = match value.as_str() {
                    "true" => json!(true),
                    "false" => json!(false),
                    s => json!(s),
                };
                self.request_bg(method::SESSION_SET_CONFIG_OPTION, json!({"sessionId": id.clone(), "configId": cid.clone(), "value": v}), Some(format!("{cid} = {value}")));
                self.refresh_detail_later(&id);
            }
            PickTarget::Agent => {
                if let Some(Overlay::NewSession(f)) = self.parked_form.as_mut() {
                    if let Some(i) = f.agents.iter().position(|a| *a == value) {
                        f.agent = i;
                    }
                }
            }
        }
    }

}
