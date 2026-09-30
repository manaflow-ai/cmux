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
            None => self
                .selected_session()
                .and_then(|s| s.get("peer").and_then(Value::as_str).map(str::to_owned)),
        };
        let agent = self
            .selected_session()
            .and_then(|s| s.get("harness").and_then(Value::as_str).map(str::to_owned))
            .or_else(|| self.default_harness.clone())
            .or_else(|| self.harnesses.first().cloned())
            .unwrap_or_default();
        let cwd = self
            .selected_session()
            .and_then(|s| s.get("cwd").and_then(Value::as_str))
            .map(str::to_owned)
            .unwrap_or_else(|| {
                std::env::current_dir()
                    .map(|p| p.to_string_lossy().into_owned())
                    .unwrap_or_default()
            });
        let policy = self
            .selected_session()
            .and_then(|s| s.get("policy").and_then(Value::as_str))
            .unwrap_or("approve-all")
            .to_owned();
        let id = self.next_draft_id;
        self.next_draft_id += 1;
        self.drafts.insert(
            0,
            Draft {
                id,
                peer,
                harness: agent,
                cwd,
                policy,
                model: None,
                creating: false,
                text: Editor::default(),
                errors: Vec::new(),
                effort: None,
                images: Vec::new(),
            },
        );
        self.selected = 0;
        self.selection = None;
        self.focus = Focus::Input;
        self.status = "new session · Enter starts it · Esc discards".into();
    }

    pub(super) fn open_draft_in_directory(&mut self, cwd: String) {
        let source = self
            .sessions
            .iter()
            .find(|s| {
                s.get("cwd").and_then(Value::as_str) == Some(&cwd)
                    && s.get("peer").and_then(Value::as_str).is_none()
            })
            .cloned();
        let harness = source
            .as_ref()
            .and_then(|s| s.get("harness").and_then(Value::as_str))
            .map(str::to_owned)
            .or_else(|| self.default_harness.clone());
        self.host_filter = None;
        self.open_draft();
        if let Some(d) = self.draft_mut() {
            d.cwd = cwd;
            d.peer = None;
            if let Some(h) = harness {
                d.harness = h;
            }
            if let Some(s) = source {
                d.policy = s.get("policy").and_then(Value::as_str).unwrap_or("approve-all").into();
            }
        }
        self.status = "new session · project selected · Enter starts it · Esc discards".into();
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

    /// Open the settings menu attached to the centered new-session summary.
    /// Each row leads to the same picker used by the corresponding composer
    /// chip, so the draft has one obvious configuration entry point without
    /// duplicating picker behavior.
    pub(super) fn open_draft_config_picker(&mut self) {
        let Some(d) = self.draft() else { return };
        let model = d
            .model
            .as_deref()
            .map(crate::tui::render::model_label)
            .unwrap_or_else(|| "default model".into());
        let effort = d
            .effort
            .as_deref()
            .filter(|e| !e.is_empty())
            .map(crate::tui::render::effort_label)
            .unwrap_or_else(|| "default".into());
        let policy = crate::tui::render::policy_label(&d.policy).0;
        let rows = vec![
            PickRow {
                value: "draft:harness".into(),
                label: format!("Harness · {}", d.harness),
                header: false,
                group: String::new(),
                note: String::new(),
            },
            PickRow {
                value: "draft:model".into(),
                label: format!("Model · {model}"),
                header: false,
                group: String::new(),
                note: String::new(),
            },
            PickRow {
                value: "draft:effort".into(),
                label: format!("Thinking effort · {effort}"),
                header: false,
                group: String::new(),
                note: String::new(),
            },
            PickRow {
                value: "draft:policy".into(),
                label: format!("Permissions · {policy}"),
                header: false,
                group: String::new(),
                note: String::new(),
            },
            PickRow {
                value: "draft:directory".into(),
                label: format!("Directory · {}", crate::tui::render::shorten_path(&d.cwd)),
                header: false,
                group: String::new(),
                note: String::new(),
            },
        ];
        self.overlay = Overlay::Picker(Picker::new(
            "New session settings",
            rows,
            None,
            PickTarget::Action,
            "Enter or click picks · Esc",
        ));
    }

    /// Create the draft's session and send `text` as its first message.
    pub(super) fn create_from_draft(&mut self, text: String, images: Vec<PromptImage>) {
        let Some(d) = self.draft_mut() else { return };
        if d.creating {
            return;
        }
        d.creating = true;
        let d = d.clone();
        if d.harness.is_empty() {
            if let Some(d) = self.draft_mut() {
                d.creating = false;
            }
            self.report_error("no harnesses configured; edit ~/.acpmux/config.json".into());
            return;
        }
        let mut params = json!({"cwd": d.cwd, "mcpServers": [], "_meta": {"acpmux": {"harness": d.harness, "policy": d.policy}}});
        if let Some(p) = &d.peer {
            params["_meta"]["acpmux"]["peer"] = json!(p);
        }
        let client = self.client.clone();
        let tx = self.tx.clone();
        if let Some(model) = &d.model {
            params["_meta"]["acpmux"]["model"] = json!(model);
        }
        if let Some(effort) = &d.effort {
            params["_meta"]["acpmux"]["effort"] = json!(effort);
        }
        self.status = format!("starting {}…", d.harness);
        tokio::spawn(async move {
            match client.request(method::SESSION_NEW, params).await {
                Ok(v) => {
                    if let Some(id) = v.get("sessionId").and_then(Value::as_str) {
                        let _ = tx.send(AppMsg::Created(id.to_owned()));
                        let id = id.to_owned();
                        let c = client.clone();
                        tokio::spawn(async move {
                            let _ = c.request(method::SESSION_PROMPT, json!({"sessionId": id, "prompt": App::prompt_blocks(&text, &images)})).await;
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
            .unwrap_or_else(|| {
                std::env::current_dir()
                    .map(|p| p.to_string_lossy().into_owned())
                    .unwrap_or_default()
            });
        let agent = self
            .default_harness
            .as_ref()
            .and_then(|d| self.harnesses.iter().position(|a| a == d))
            .unwrap_or(0);
        self.overlay = Overlay::NewSession(NewForm {
            harnesses: self.harnesses.clone(),
            agent,
            name: Editor::default(),
            cwd: {
                let mut e = Editor::default();
                e.set_text(&cwd);
                e
            },
            policy: POLICIES.iter().position(|p| *p == "approve-all").unwrap_or(0),
            prompt: Editor::default(),
            field: 1,
        });
    }

    pub(super) fn submit_new_session(&mut self, form: &NewForm) {
        let Some(agent) = form.harnesses.get(form.agent) else {
            self.report_error("no harnesses configured; edit ~/.acpmux/config.json".into());
            return;
        };
        let form_name = form.name.text();
        if !form_name.is_empty()
            && let Err(e) = crate::session_name::validate(&form_name)
        {
            self.status = e;
            return;
        }
        let mut meta = json!({"harness": agent, "policy": POLICIES[form.policy]});
        if !form_name.is_empty() {
            meta["name"] = json!(form_name);
        }
        let params = json!({"cwd": form.cwd.text(), "mcpServers": [], "_meta": {"acpmux": meta}});
        let first = form.prompt.text().trim().to_owned();
        let client = self.client.clone();
        let tx = self.tx.clone();
        self.status = "starting harness…".into();
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
    pub(super) fn open_draft_harness_picker(&mut self) {
        let Some(d) = self.draft() else { return };
        let id = d.id;
        self.show_harness_picker(json!({"harnesses":self.harnesses.iter().map(|h| json!({"harness":h})).collect::<Vec<_>>()}));
        let client = self.client.clone();
        let tx = self.tx.clone();
        tokio::spawn(async move {
            match client.request("_acpmux/models", json!({})).await {
                Ok(v) => {
                    let _ = tx.send(AppMsg::HarnessCatalog(id, v));
                }
                Err(e) => {
                    let _ = tx.send(AppMsg::Error(e.to_string()));
                }
            }
        });
        self.status = "loading harnesses…".into();
    }

    pub(super) fn show_harness_picker(&mut self, catalog: Value) {
        let Some(d) = self.draft() else { return };
        let current = d
            .peer
            .as_ref()
            .map(|p| format!("{p}/{}", d.harness))
            .unwrap_or_else(|| d.harness.clone());
        let rows = catalog
            .get("harnesses")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|h| {
                let id = h.get("harness")?.as_str()?.to_owned();
                let label = if id.split('/').next_back() == Some("deepseek") {
                    format!("{id} · DeepSeek Harness")
                } else {
                    id.clone()
                };
                Some(PickRow {
                    value: id,
                    label,
                    header: false,
                    group: String::new(),
                    note: String::new(),
                })
            })
            .collect();
        self.overlay = Overlay::Picker(Picker::new(
            "Harness",
            rows,
            Some(&current),
            PickTarget::DraftHarness,
            "type to filter · Enter selects · Esc",
        ));
        self.status = DEFAULT_STATUS.into();
    }

    pub(super) fn open_draft_model_picker(&mut self) {
        self.open_model_picker();
        self.model_picker_current_only = true;
    }

    pub(super) fn open_model_picker(&mut self) {
        self.model_picker_current_only = false;
        let client = self.client.clone();
        let tx = self.tx.clone();
        tokio::spawn(async move {
            match client.request("_acpmux/models", json!({})).await {
                Ok(v) => {
                    let _ = tx.send(AppMsg::Models(v));
                }
                Err(e) => {
                    let _ = tx.send(AppMsg::Error(e.to_string()));
                }
            }
        });
        self.status = "loading models…".into();
    }

    pub(super) fn show_model_picker(&mut self, catalog: Value) {
        let current_agent = if self.on_draft() {
            self.draft().map(|d| d.harness.clone())
        } else {
            self.selected_session()
                .and_then(|s| s.get("harness").and_then(Value::as_str).map(str::to_owned))
        };
        let current_model = if self.on_draft() {
            self.draft().and_then(|d| d.model.clone())
        } else {
            self.selected_id()
                .and_then(|id| self.transcripts.get(&id))
                .and_then(|t| t.model.clone())
        };
        let live_session = if self.on_draft() { None } else { self.selected_id() };
        let mut rows = Vec::new();
        // For a live session, merge in the session's own model list, which may
        // be fresher than the daemon's cache.
        let live_models: Vec<(String, String)> = live_session
            .as_ref()
            .and_then(|id| self.details.get(id))
            .and_then(|d| d.get("configOptions").and_then(Value::as_array))
            .and_then(|opts| {
                opts.iter().find(|o| o.get("id").and_then(Value::as_str) == Some("model"))
            })
            .map(crate::model_catalog::choices)
            .unwrap_or_default();
        let mut harnesses: Vec<Value> =
            catalog.get("harnesses").and_then(Value::as_array).cloned().unwrap_or_default();
        // Current harness first.
        let cur_key_for_sort = match (
            &self.draft().and_then(|d| d.peer.clone()).or_else(|| {
                self.selected_session()
                    .and_then(|s| s.get("peer").and_then(Value::as_str).map(str::to_owned))
            }),
            &current_agent,
        ) {
            (Some(p), Some(a)) => Some(format!("{p}/{a}")),
            (None, Some(a)) => Some(a.clone()),
            _ => None,
        };
        if self.model_picker_current_only {
            harnesses.retain(|h| {
                h.get("harness").and_then(Value::as_str) == cur_key_for_sort.as_deref()
            });
            self.model_picker_current_only = false;
        }
        harnesses.sort_by_key(|h| {
            if h.get("harness").and_then(Value::as_str) == cur_key_for_sort.as_deref() {
                0
            } else {
                1
            }
        });
        let current_peer = if self.on_draft() {
            self.draft().and_then(|d| d.peer.clone())
        } else {
            self.selected_session()
                .and_then(|s| s.get("peer").and_then(Value::as_str).map(str::to_owned))
        };
        let current_key = match (&current_peer, &current_agent) {
            (Some(p), Some(a)) => Some(format!("{p}/{a}")),
            (None, Some(a)) => Some(a.clone()),
            _ => None,
        };
        for h in harnesses {
            let agent = h.get("harness").and_then(Value::as_str).unwrap_or("").to_owned();
            let is_current = Some(&agent) == current_key.as_ref();
            let note = if is_current {
                "current".to_owned()
            } else if live_session.is_some() {
                "forks into a new session".to_owned()
            } else {
                String::new()
            };
            rows.push(PickRow {
                value: String::new(),
                label: agent.clone(),
                header: true,
                group: agent.clone(),
                note,
            });
            let models: Vec<(String, String)> = if is_current && !live_models.is_empty() {
                live_models.clone()
            } else {
                h.get("models")
                    .and_then(Value::as_array)
                    .map(|a| {
                        a.iter()
                            .map(|m| {
                                (
                                    m.get("id").and_then(Value::as_str).unwrap_or("").to_owned(),
                                    m.get("name").and_then(Value::as_str).unwrap_or("").to_owned(),
                                )
                            })
                            .collect()
                    })
                    .unwrap_or_default()
            };
            for (id, name) in models {
                let label = if name.is_empty() || name == id {
                    id.clone()
                } else {
                    format!("{name}  {id}")
                };
                rows.push(PickRow {
                    value: id,
                    label,
                    header: false,
                    group: agent.clone(),
                    note: String::new(),
                });
            }
        }
        let cur = current_model.clone();
        let mut p = Picker::new(
            "Model",
            rows,
            cur.as_deref(),
            PickTarget::Model(live_session),
            "type to filter · ↑↓ wheel · Enter or click picks · Esc",
        );
        // Land on the current harness's first model when no exact model matched.
        if current_model.is_none() {
            p.cursor = p.visible.iter().position(|&i| !p.rows[i].header).unwrap_or(0);
        }
        self.overlay = Overlay::Picker(p);
        self.status = DEFAULT_STATUS.into();
    }

    pub(super) fn open_mode_picker(&mut self) {
        if self.on_draft() {
            self.status =
                "mode is set once the session runs; permissions are the draft-time control".into();
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
        let rows = choices
            .into_iter()
            .map(|(v, l)| PickRow {
                value: v,
                label: l,
                header: false,
                group: String::new(),
                note: String::new(),
            })
            .collect();
        self.overlay = Overlay::Picker(Picker::new(
            "Mode",
            rows,
            Some(&current),
            PickTarget::Mode(id),
            "type to filter · ↑↓ wheel · Enter or click picks · Esc",
        ));
    }

    /// Permission policy: works on a draft or a live session.
    pub(super) fn open_policy_picker(&mut self) {
        let live = if self.on_draft() { None } else { self.selected_id() };
        let current = if self.on_draft() {
            self.draft().map(|d| d.policy.clone())
        } else {
            self.selected_session()
                .and_then(|s| s.get("policy").and_then(Value::as_str).map(str::to_owned))
        }
        .unwrap_or_else(|| "ask".into());
        let rows = POLICIES
            .iter()
            .map(|p| {
                let note = match *p {
                    "ask" => "you approve each tool call",
                    "approve-reads" => "reads auto, writes ask",
                    "approve-edits" => "reads and edits auto, shell asks",
                    "approve-all" => "nothing asks",
                    _ => "everything denied",
                };
                let icon = match *p {
                    "ask" => "?",
                    "approve-reads" => "◉",
                    "approve-edits" => "✎",
                    "approve-all" => "✓",
                    _ => "⊘",
                };
                PickRow {
                    value: p.to_string(),
                    label: format!("{icon} {p:<14} {note}"),
                    header: false,
                    group: String::new(),
                    note: String::new(),
                }
            })
            .collect();
        self.overlay = Overlay::Picker(Picker::new(
            "Permissions",
            rows,
            Some(&current),
            PickTarget::Policy(live),
            "↑↓ · Enter or click picks · Esc",
        ));
    }

    /// "Thinking": whichever effort-like option the harness exposes.
    pub(super) fn open_thinking_picker(&mut self) {
        if let Some(d) = self.draft() {
            let current = d.effort.clone().unwrap_or_else(|| "default".into());
            let rows = super::actions::draft_effort_levels(&d.harness)
                .into_iter()
                .map(|(v, l)| PickRow {
                    value: v.into(),
                    label: l.into(),
                    header: false,
                    group: String::new(),
                    note: String::new(),
                })
                .collect();
            self.overlay = Overlay::Picker(Picker::new(
                "Thinking effort",
                rows,
                Some(&current),
                PickTarget::DraftEffort,
                "applied when the session starts · Enter or click picks · Esc",
            ));
            return;
        }
        let Some(id) = self.selected_id() else { return };
        let detail = self.details.get(&id).cloned().unwrap_or(Value::Null);
        let ids: Vec<String> = detail
            .get("configOptions")
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .filter_map(|o| o.get("id").and_then(Value::as_str).map(str::to_owned))
                    .collect()
            })
            .unwrap_or_default();
        for cand in ["reasoning_effort", "effort", "thought_level", "thinking", "reasoning"] {
            if ids.iter().any(|i| i == cand) {
                self.open_config_picker(cand);
                return;
            }
        }
        self.report_error("this harness has no thinking or effort setting".into());
    }

    pub(super) fn open_directory_dialog(&mut self) {
        self.open_directory_dialog_at(self.current_directory());
    }

    pub(super) fn open_directory_dialog_at(&mut self, value: String) {
        let path = match self.resolve_directory(&value) {
            Ok(p) => p,
            Err(e) => {
                self.report_error(e.to_string());
                return;
            }
        };
        let path = if self.remote_directory() {
            path
        } else {
            std::fs::canonicalize(&path).unwrap_or(path)
        };
        let mut text = Editor::default();
        text.set_text(&path.to_string_lossy());
        self.overlay = Overlay::Directory { text };
    }

    pub(super) fn apply_directory(&mut self, value: String) {
        let result = self.resolve_directory(&value).and_then(|p| {
            if self.remote_directory() {
                return Ok(p);
            }
            let p = std::fs::canonicalize(p)?;
            anyhow::ensure!(p.is_dir(), "Not a directory: {}", p.display());
            Ok(p)
        });
        let path = match result {
            Ok(p) => p.to_string_lossy().into_owned(),
            Err(e) => {
                self.open_directory_dialog_at(value);
                self.report_error(format!("Directory: {e}"));
                return;
            }
        };
        let base = self.current_directory();
        if directory::cd_argument(&self.editor().text()).is_some() {
            self.editor_mut().clear();
        }
        if !self.on_draft() && path == base {
            self.overlay = Overlay::None;
            return;
        }
        if !self.on_draft() {
            self.open_draft();
        }
        if let Some(d) = self.draft_mut() {
            d.cwd = path.clone();
        }
        self.previous_directory = Some(base);
        self.overlay = Overlay::None;
        self.focus = Focus::Input;
        self.status = format!("New session directory: {}", render::shorten_path(&path));
    }

    pub(super) fn open_config_picker(&mut self, config_id: &str) {
        let Some(id) = self.selected_id() else { return };
        let detail = self.details.get(&id).cloned().unwrap_or(Value::Null);
        let Some(opt) = detail.get("configOptions").and_then(Value::as_array).and_then(|a| {
            a.iter().find(|o| o.get("id").and_then(Value::as_str) == Some(config_id)).cloned()
        }) else {
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
        let rows = choices
            .into_iter()
            .map(|(v, l)| PickRow {
                value: v,
                label: l,
                header: false,
                group: String::new(),
                note: String::new(),
            })
            .collect();
        let title = match config_id {
            "effort" | "reasoning_effort" | "thought_level" | "thinking" | "reasoning" => {
                "Effort".to_owned()
            }
            "model" => "Model".to_owned(),
            "mode" => "Mode".to_owned(),
            other => {
                let mut t = other.replace('_', " ");
                if let Some(f) = t.get(0..1) {
                    let up = f.to_uppercase();
                    t.replace_range(0..1, &up);
                }
                t
            }
        };
        self.overlay = Overlay::Picker(Picker::new(
            &title,
            rows,
            Some(&current),
            PickTarget::Config(id, config_id.to_owned()),
            "type to filter · ↑↓ wheel · Enter or click picks · Esc",
        ));
    }

    pub(super) fn apply_pick(&mut self, target: PickTarget, value: String, group: String) {
        match target {
            PickTarget::Model(live) => {
                let current_agent = if self.on_draft() {
                    self.draft().map(|d| d.harness.clone())
                } else {
                    self.selected_session()
                        .and_then(|s| s.get("harness").and_then(Value::as_str).map(str::to_owned))
                };
                let current_peer = self
                    .selected_session()
                    .and_then(|s| s.get("peer").and_then(Value::as_str).map(str::to_owned));
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
                    d.harness = agent;
                    d.model = if value == "default" { None } else { Some(value.clone()) };
                    self.status = format!("draft: {group} · {value}");
                } else if let Some(id) = live {
                    if same_harness {
                        self.request_bg(
                            method::SESSION_SET_MODEL,
                            json!({"sessionId": id.clone(), "modelId": value.clone()}),
                            Some(format!("model {value}")),
                        );
                        self.refresh_detail_later(&id);
                    } else {
                        // Another harness: start a new session tab with it.
                        self.open_draft();
                        if let Some(d) = self.draft_mut() {
                            d.peer = peer;
                            d.harness = agent;
                            d.model = if value == "default" { None } else { Some(value.clone()) };
                        }
                        self.status = format!(
                            "new session tab: {group} · {value}   (a running agent cannot change harness)"
                        );
                    }
                }
            }
            PickTarget::Policy(live) => match live {
                Some(id) => {
                    self.request_bg(
                        method::MUX_SET_POLICY,
                        json!({"sessionId": id.clone(), "policy": value.clone()}),
                        Some(format!("policy {value}")),
                    );
                    // The daemon answers before the list refresh; re-read shortly after.
                    let client = self.client.clone();
                    let tx = self.tx.clone();
                    tokio::spawn(async move {
                        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
                        if let Ok(v) = client.request(method::MUX_SESSIONS, json!({})).await {
                            let _ = tx.send(AppMsg::Sessions(
                                v.get("sessions")
                                    .and_then(Value::as_array)
                                    .cloned()
                                    .unwrap_or_default(),
                            ));
                        }
                    });
                }
                None => {
                    if let Some(d) = self.draft_mut() {
                        d.policy = value.clone();
                    }
                    self.persist_default_policy(&value);
                    self.status = format!("draft policy: {value}");
                }
            },
            PickTarget::Mode(id) => {
                self.request_bg(
                    method::SESSION_SET_MODE,
                    json!({"sessionId": id.clone(), "modeId": value.clone()}),
                    Some(format!("mode {value}")),
                );
                self.refresh_detail_later(&id);
            }
            PickTarget::Config(id, cid) => {
                let v = match value.as_str() {
                    "true" => json!(true),
                    "false" => json!(false),
                    s => json!(s),
                };
                self.request_bg(
                    method::SESSION_SET_CONFIG_OPTION,
                    json!({"sessionId": id.clone(), "configId": cid.clone(), "value": v}),
                    Some(format!("{cid} = {value}")),
                );
                self.refresh_detail_later(&id);
            }
            PickTarget::DraftEffort => self.set_effort(value),
            PickTarget::DraftHarness => {
                if let Some(d) = self.draft_mut() {
                    let (peer, harness) = value
                        .split_once('/')
                        .map(|(p, h)| (Some(p.to_owned()), h.to_owned()))
                        .unwrap_or((None, value));
                    d.peer = peer;
                    d.harness = harness;
                    d.model = None;
                    d.effort = None;
                }
            }
            PickTarget::Skill { replace_prefix } => {
                if replace_prefix {
                    self.editor_mut().backspace();
                }
                let reference = format!("{}{} ", self.skill_prefix, value);
                self.editor_mut().insert_str(&reference);
                self.focus = Focus::Input;
            }
            PickTarget::Action => {
                match value.as_str() {
                    "draft:harness" => {
                        self.open_draft_harness_picker();
                        return;
                    }
                    "draft:model" => {
                        self.open_draft_model_picker();
                        return;
                    }
                    "draft:policy" => {
                        self.open_policy_picker();
                        return;
                    }
                    "draft:effort" => {
                        self.open_thinking_picker();
                        return;
                    }
                    "draft:directory" => {
                        self.open_directory_dialog();
                        return;
                    }
                    _ => {}
                }
                if let Some(command) = value.strip_prefix("agent:") {
                    if let Some(id) = self.selected_id() {
                        self.request_bg(
                            method::SESSION_PROMPT,
                            json!({"sessionId":id,"prompt":[{"type":"text","text":command}]}),
                            None,
                        );
                    }
                    return;
                }
                if let Some(id) = value.strip_prefix("goto:") {
                    let ndrafts = self.drafts.len();
                    if let Some(i) = self
                        .sessions
                        .iter()
                        .position(|s| s.get("sessionId").and_then(Value::as_str) == Some(id))
                    {
                        self.select(i + ndrafts);
                        self.focus = Focus::Input;
                    }
                    return;
                }
                if let Some(d) = super::actions::find(&value) {
                    // Optional arguments (shown in brackets) mean the action
                    // has its own picker: /model opens the model list.
                    if d.args.is_empty() || d.args.starts_with('[') {
                        self.run_action(d.action, &[]);
                    } else {
                        self.prompt_command(d.name);
                    }
                }
            }
            PickTarget::Agent => {
                if let Some(Overlay::NewSession(f)) = self.parked_form.as_mut()
                    && let Some(i) = f.harnesses.iter().position(|a| *a == value)
                {
                    f.agent = i;
                }
            }
        }
    }
}
