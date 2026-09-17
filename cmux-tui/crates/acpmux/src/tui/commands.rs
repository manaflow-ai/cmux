//! Part of the TUI `App`; see `tui/mod.rs`.

use super::*;

impl App {
    pub(super) fn run_command(&mut self, line: &str) {
        let mut parts = line.split_whitespace();
        let Some(cmd) = parts.next() else { return };
        let rest: Vec<&str> = parts.collect();
        let sid = self.selected_id();
        match cmd {
            "q" | "quit" | "detach" => self.quit = true,
            "new" => {
                if rest.is_empty() {
                    self.open_draft();
                } else if rest == ["form"] {
                    self.open_new_session();
                } else {
                    let mut meta = json!({});
                    if let Some(a) = rest.first() {
                        meta["agent"] = json!(a);
                    }
                    if let Some(n) = rest.get(1) {
                        meta["name"] = json!(n);
                    }
                    let cwd = rest.get(2).map(std::path::PathBuf::from).unwrap_or_else(|| std::env::current_dir().unwrap_or_default());
                    self.request_bg(method::SESSION_NEW, json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": meta}}), Some("session created".into()));
                }
            }
            "kill" => {
                if let Some(id) = sid {
                    let purge = rest.contains(&"--purge");
                    self.overlay = Overlay::Confirm {
                        title: format!("{} {}?", if purge { "Delete" } else { "Stop" }, self.selected_name()),
                        action: ConfirmAction::Kill { id, purge },
                    };
                }
            }
            "rename" => {
                if let (Some(id), Some(name)) = (sid, rest.first()) {
                    self.request_bg(method::MUX_RENAME, json!({"sessionId": id, "newName": name}), Some("renamed".into()));
                }
            }
            "fork" => {
                if let Some(id) = sid {
                    let mut p = json!({"sessionId": id, "mcpServers": [], "_meta": {"acpmux": {}}});
                    if let Some(n) = rest.first() {
                        p["_meta"]["acpmux"]["name"] = json!(n);
                    }
                    self.request_bg(method::SESSION_FORK, p, Some("forked".into()));
                }
            }
            "mode" => match (sid, rest.first()) {
                (Some(id), Some(m)) => {
                    self.request_bg(method::SESSION_SET_MODE, json!({"sessionId": id.clone(), "modeId": m}), Some(format!("mode {m}")));
                    self.refresh_detail_later(&id);
                }
                _ => self.open_mode_picker(),
            },
            "model" => match (sid, rest.first()) {
                (Some(id), Some(m)) => {
                    self.request_bg(method::SESSION_SET_MODEL, json!({"sessionId": id.clone(), "modelId": m}), Some(format!("model {m}")));
                    self.refresh_detail_later(&id);
                }
                _ => self.open_model_picker(),
            },
            "set" => match (sid, rest.first()) {
                (Some(id), Some(kv)) => {
                    if let Some((k, v)) = kv.split_once('=') {
                        let value = match v {
                            "true" => json!(true),
                            "false" => json!(false),
                            s => json!(s),
                        };
                        self.request_bg(method::SESSION_SET_CONFIG_OPTION, json!({"sessionId": id.clone(), "configId": k, "value": value}), Some(format!("{k} set")));
                        self.refresh_detail_later(&id);
                    } else {
                        self.open_config_picker(kv);
                    }
                }
                _ => self.report_error("usage: :set key=value or :set key".into()),
            },
            "agent" => {
                let known = self.agents.clone();
                match (self.draft_mut(), rest.first()) {
                    (Some(d), Some(a)) => {
                        if known.iter().any(|x| x == a) {
                            d.agent = a.to_string();
                            self.status = format!("draft agent: {a}");
                        } else {
                            self.report_error(format!("unknown agent {a}; known: {}", known.join(", ")));
                        }
                    }
                    (None, _) => self.status = ":agent only applies to a new session tab (Ctrl-t)".into(),
                    (Some(_), None) => self.report_error(format!("usage: :agent NAME   ({})", known.join(", "))),
                }
            }
            "cwd" => match rest.first() {
                Some(p) => self.apply_directory(p.to_string()),
                None => self.open_directory_dialog(),
            },
            "policy" if self.on_draft() => {
                if let Some(p) = rest.first() {
                    if POLICIES.contains(p) {
                        self.draft_mut().unwrap().policy = p.to_string();
                        self.status = format!("draft policy: {p}");
                    } else {
                        self.report_error(format!("policy must be one of {}", POLICIES.join(", ")));
                    }
                }
            }
            "policy" => {
                if let (Some(id), Some(p)) = (sid, rest.first()) {
                    self.request_bg(method::MUX_SET_POLICY, json!({"sessionId": id, "policy": p}), Some(format!("policy {p}")));
                }
            }
            "cancel" => self.cancel(),
            "export" => {
                if let Some(id) = sid {
                    let mut p = json!({"sessionId": id});
                    if let Some(d) = rest.first() {
                        p["dest"] = json!(d);
                    }
                    self.request_bg(method::MUX_EXPORT, p, Some("exported to ~/.acpmux/bundles".into()));
                }
            }
            "import" => {
                if let Some(path) = rest.first() {
                    self.request_bg(method::MUX_IMPORT, json!({"path": path}), Some("imported".into()));
                }
            }
            "peer" => match rest.as_slice() {
                ["add", name, url] => self.request_bg("_acpmux/peer_add", json!({"name": name, "url": url}), Some(format!("peer {name} added"))),
                ["add", name, url, token] => self.request_bg("_acpmux/peer_add", json!({"name": name, "url": url, "token": token}), Some(format!("peer {name} added"))),
                ["rm", name] => self.request_bg("_acpmux/peer_remove", json!({"name": name}), Some(format!("peer {name} removed"))),
                _ => self.report_error("usage: :peer add NAME URL [TOKEN] | :peer rm NAME".into()),
            },
            "web" => {
                if let Some(u) = &self.web_url {
                    let _ = std::process::Command::new(if cfg!(target_os = "macos") { "open" } else { "xdg-open" }).arg(u).spawn();
                    self.status = format!("opened {u}");
                }
            }
            "thoughts" => {
                self.show_thoughts = !self.show_thoughts;
                self.status = format!("thoughts {}", if self.show_thoughts { "shown" } else { "hidden" });
            }
            "help" => self.overlay = Overlay::Help,
            other => self.report_error(format!("unknown command :{other}  (? for help)")),
        }
    }

}
