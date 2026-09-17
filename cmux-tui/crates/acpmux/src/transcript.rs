//! A display model built from acpmux events. Shared by the CLI stream view
//! and the TUI so both render the same thing.

use serde_json::Value;

#[derive(Debug, Clone, PartialEq)]
pub enum Item {
    User { text: String, steer: bool, queued: bool },
    Assistant { text: String },
    Thought { text: String },
    Tool {
        id: String,
        title: String,
        kind: String,
        status: String,
        detail: String,
    },
    Plan { entries: Vec<(String, String)> },
    Permission {
        id: String,
        title: String,
        options: Vec<(String, String, String)>,
        decided: Option<String>,
    },
    Status { text: String },
    TurnEnd { stop: String },
    Error { text: String },
    Stderr { text: String },
}

#[derive(Debug, Default, Clone)]
pub struct Transcript {
    pub items: Vec<Item>,
    pub last_seq: u64,
    pub status: String,
    pub mode: Option<String>,
    pub model: Option<String>,
    pub usage: Option<(u64, u64)>,
    pub available_commands: Vec<String>,
    pending_user_chunk: bool,
}

fn text_of(content: &Value) -> String {
    match content {
        Value::Array(items) => items.iter().map(text_of).collect::<Vec<_>>().join(""),
        Value::Object(o) => {
            if let Some(t) = o.get("text").and_then(Value::as_str) {
                t.to_owned()
            } else if let Some(c) = o.get("content") {
                text_of(c)
            } else if o.get("type").and_then(Value::as_str) == Some("image") {
                "[image]".into()
            } else if let Some(r) = o.get("resource") {
                r.get("text").and_then(Value::as_str).unwrap_or("[resource]").to_owned()
            } else {
                String::new()
            }
        }
        Value::String(s) => s.clone(),
        _ => String::new(),
    }
}

impl Transcript {
    /// Apply a `session/update` params object (live or replayed).
    /// Apply a live or replayed update. Records carry the daemon's sequence
    /// number; anything at or below what was already applied is a duplicate
    /// (an attach snapshot racing a live notification) and is dropped.
    pub fn apply_update(&mut self, params: &Value) {
        if let Some(seq) = params.pointer("/_meta/acpmux/seq").and_then(Value::as_u64) {
            if seq <= self.last_seq {
                return;
            }
            self.last_seq = seq;
        }
        let Some(update) = params.get("update") else { return };
        self.apply_session_update(update);
    }

    pub fn apply_session_update(&mut self, update: &Value) {
        let kind = update.get("sessionUpdate").and_then(Value::as_str).unwrap_or("");
        match kind {
            "user_message_chunk" => {
                let t = text_of(update.get("content").unwrap_or(&Value::Null));
                match self.items.last_mut() {
                    Some(Item::User { text, steer: false, .. }) if !text.is_empty() && self.pending_user_chunk => text.push_str(&t),
                    _ => self.items.push(Item::User { text: t, steer: false, queued: false }),
                }
                self.pending_user_chunk = true;
                return;
            }
            "agent_message_chunk" => {
                let t = text_of(update.get("content").unwrap_or(&Value::Null));
                match self.items.last_mut() {
                    Some(Item::Assistant { text }) => text.push_str(&t),
                    _ => self.items.push(Item::Assistant { text: t }),
                }
            }
            "agent_thought_chunk" => {
                let t = text_of(update.get("content").unwrap_or(&Value::Null));
                match self.items.last_mut() {
                    Some(Item::Thought { text }) => text.push_str(&t),
                    _ => self.items.push(Item::Thought { text: t }),
                }
            }
            "tool_call" | "tool_call_update" => {
                let id = update.get("toolCallId").and_then(Value::as_str).unwrap_or("").to_owned();
                let title = update.get("title").and_then(Value::as_str).map(str::to_owned);
                let tkind = update.get("kind").and_then(Value::as_str).map(str::to_owned);
                let status = update.get("status").and_then(Value::as_str).map(str::to_owned);
                let mut detail = String::new();
                if let Some(c) = update.get("content").and_then(Value::as_array) {
                    for block in c {
                        let t = text_of(block);
                        if !t.is_empty() {
                            if !detail.is_empty() {
                                detail.push('\n');
                            }
                            detail.push_str(&t);
                        }
                    }
                }
                if detail.is_empty() {
                    if let Some(o) = update.get("rawOutput") {
                        detail = match o {
                            Value::String(s) => s.clone(),
                            other => other.to_string(),
                        };
                    }
                }
                if detail.len() > 4000 {
                    let mut cut = 4000;
                    while !detail.is_char_boundary(cut) {
                        cut -= 1;
                    }
                    detail.truncate(cut);
                    detail.push_str("\n…");
                }
                if let Some(existing) = self.items.iter_mut().rev().find_map(|i| match i {
                    Item::Tool { id: tid, .. } if *tid == id => Some(i),
                    _ => None,
                }) {
                    if let Item::Tool { title: et, kind: ek, status: es, detail: ed, .. } = existing {
                        if let Some(t) = title { *et = t; }
                        if let Some(k) = tkind { *ek = k; }
                        if let Some(s) = status { *es = s; }
                        if !detail.is_empty() { *ed = detail; }
                    }
                } else {
                    self.items.push(Item::Tool {
                        id,
                        title: title.unwrap_or_else(|| "tool".into()),
                        kind: tkind.unwrap_or_default(),
                        status: status.unwrap_or_else(|| "pending".into()),
                        detail,
                    });
                }
            }
            "plan" => {
                let entries = update
                    .get("entries")
                    .and_then(Value::as_array)
                    .map(|e| {
                        e.iter()
                            .map(|x| {
                                (
                                    x.get("status").and_then(Value::as_str).unwrap_or("").to_owned(),
                                    x.get("content").and_then(Value::as_str).unwrap_or("").to_owned(),
                                )
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                if let Some(Item::Plan { entries: e }) = self.items.iter_mut().rev().find(|i| matches!(i, Item::Plan { .. })) {
                    *e = entries;
                } else {
                    self.items.push(Item::Plan { entries });
                }
            }
            "usage_update" => {
                let used = update.get("used").and_then(Value::as_u64).unwrap_or(0);
                let size = update.get("size").and_then(Value::as_u64).unwrap_or(0);
                self.usage = Some((used, size));
            }
            "current_mode_update" => {
                self.mode = update.get("currentModeId").and_then(Value::as_str).map(str::to_owned);
            }
            "config_option_update" => {
                if let Some(opts) = update.get("configOptions").and_then(Value::as_array) {
                    for o in opts {
                        if o.get("id").and_then(Value::as_str) == Some("model") {
                            self.model = o.get("currentValue").and_then(Value::as_str).map(str::to_owned);
                        }
                    }
                }
            }
            "available_commands_update" => {
                self.available_commands = update
                    .get("availableCommands")
                    .and_then(Value::as_array)
                    .map(|a| a.iter().filter_map(|c| c.get("name").and_then(Value::as_str).map(str::to_owned)).collect())
                    .unwrap_or_default();
            }
            _ => {}
        }
        self.pending_user_chunk = false;
    }

    /// Apply one `_acpmux/event` record (mux-internal or raw wire).
    pub fn apply_event(&mut self, ev: &Value) {
        if let Some(seq) = ev.get("seq").and_then(Value::as_u64) {
            if seq <= self.last_seq {
                return;
            }
            self.last_seq = seq;
        }
        let dir = ev.get("dir").and_then(Value::as_str).unwrap_or("");
        let kind = ev.get("kind").and_then(Value::as_str).unwrap_or("");
        let msg = ev.get("msg").unwrap_or(&Value::Null);
        if dir == "in" {
            if kind.ends_with(".replay") {
                return;
            }
            if msg.get("method").and_then(Value::as_str) == Some("session/update") {
                if let Some(update) = msg.pointer("/params/update") {
                    self.apply_session_update(update);
                }
            }
            return;
        }
        if dir != "mux" {
            return;
        }
        self.pending_user_chunk = false;
        match kind {
            "queued" => self.items.push(Item::User {
                text: msg.get("text").and_then(Value::as_str).unwrap_or("").to_owned(),
                steer: false,
                queued: true,
            }),
            "user_message" => {
                let text = msg.get("text").and_then(Value::as_str).unwrap_or("").to_owned();
                let steer = msg.get("steer").and_then(Value::as_bool).unwrap_or(false);
                // A queued message becomes the live one when its turn starts.
                let promoted = self.items.iter_mut().find_map(|i| match i {
                    Item::User { text: t, queued, .. } if *queued && *t == text => Some(queued),
                    _ => None,
                });
                match promoted {
                    Some(q) => *q = false,
                    None => self.items.push(Item::User { text, steer, queued: false }),
                }
            }
            "status" => {
                self.status = msg.get("status").and_then(Value::as_str).unwrap_or("").to_owned();
            }
            "turn_end" => self.items.push(Item::TurnEnd {
                stop: msg.get("stopReason").and_then(Value::as_str).unwrap_or("end_turn").to_owned(),
            }),
            "turn_error" => self.items.push(Item::Error {
                text: msg.get("error").and_then(Value::as_str).unwrap_or("turn failed").to_owned(),
            }),
            "permission_request" => {
                let id = msg.get("permissionId").and_then(Value::as_str).unwrap_or("").to_owned();
                let req = msg.get("request").unwrap_or(&Value::Null);
                let title = req
                    .pointer("/toolCall/title")
                    .and_then(Value::as_str)
                    .unwrap_or("permission")
                    .to_owned();
                let options = req
                    .get("options")
                    .and_then(Value::as_array)
                    .map(|a| {
                        a.iter()
                            .map(|o| {
                                (
                                    o.get("optionId").and_then(Value::as_str).unwrap_or("").to_owned(),
                                    o.get("name").and_then(Value::as_str).unwrap_or("").to_owned(),
                                    o.get("kind").and_then(Value::as_str).unwrap_or("").to_owned(),
                                )
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                self.items.push(Item::Permission { id, title, options, decided: None });
            }
            "permission_decision" | "permission_auto" => {
                let id = msg.get("permissionId").and_then(Value::as_str).unwrap_or("");
                let decided = msg
                    .pointer("/outcome/optionId")
                    .or_else(|| msg.get("optionId"))
                    .and_then(Value::as_str)
                    .map(str::to_owned)
                    .or_else(|| msg.pointer("/outcome/outcome").and_then(Value::as_str).map(str::to_owned))
                    .unwrap_or_else(|| "cancelled".into());
                let mut found = false;
                for item in self.items.iter_mut().rev() {
                    if let Item::Permission { id: pid, decided: d, .. } = item {
                        if pid == id {
                            *d = Some(decided.clone());
                            found = true;
                            break;
                        }
                    }
                }
                if !found && kind == "permission_auto" {
                    let title = msg
                        .pointer("/request/toolCall/title")
                        .and_then(Value::as_str)
                        .unwrap_or("permission")
                        .to_owned();
                    self.items.push(Item::Permission { id: id.to_owned(), title, options: vec![], decided: Some(decided) });
                }
            }
            "stderr" => self.items.push(Item::Stderr {
                text: msg.get("text").and_then(Value::as_str).unwrap_or("").to_owned(),
            }),
            "exited" => self.items.push(Item::Status {
                text: format!("agent exited unexpectedly (code {})", msg.get("code").map(|c| c.to_string()).unwrap_or_default()),
            }),
            "stopped" => self.items.push(Item::Status { text: "agent stopped".into() }),
            "resumed" => self.items.push(Item::Status {
                text: format!("resumed ({})", msg.get("level").and_then(Value::as_str).unwrap_or("?")),
            }),
            "resume_failed" => self.items.push(Item::Status {
                text: format!("resume failed: {}", msg.get("error").and_then(Value::as_str).unwrap_or("?")),
            }),
            "forked" => self.items.push(Item::Status { text: "forked from parent".into() }),
            "reopened" => self.items.push(Item::Status { text: "reopened".into() }),
            "imported" => self.items.push(Item::Status { text: "imported".into() }),
            "mode" => {
                self.mode = msg.get("modeId").and_then(Value::as_str).map(str::to_owned);
                self.items.push(Item::Status { text: format!("mode: {}", self.mode.clone().unwrap_or_default()) });
            }
            "model" => {
                self.model = msg.get("modelId").and_then(Value::as_str).map(str::to_owned);
                self.items.push(Item::Status { text: format!("model: {}", self.model.clone().unwrap_or_default()) });
            }
            "config" => {
                if msg.get("configId").and_then(Value::as_str) == Some("model") {
                    self.model = msg.get("value").and_then(Value::as_str).map(str::to_owned);
                }
                self.items.push(Item::Status {
                    text: format!("{} = {}", msg.get("configId").and_then(Value::as_str).unwrap_or("?"), msg.get("value").map(|v| v.to_string()).unwrap_or_default()),
                });
            }
            "renamed" => self.items.push(Item::Status {
                text: format!("renamed to {}", msg.get("to").and_then(Value::as_str).unwrap_or("?")),
            }),
            _ => {}
        }
    }

    pub fn pending_permission(&self) -> Option<&Item> {
        self.items.iter().rev().find(|i| matches!(i, Item::Permission { decided: None, .. }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn accumulates_assistant_chunks() {
        let mut t = Transcript::default();
        t.apply_update(&json!({"update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Hel"}}}));
        t.apply_update(&json!({"update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "lo"}}}));
        assert_eq!(t.items, vec![Item::Assistant { text: "Hello".into() }]);
    }

    #[test]
    fn tool_updates_merge_by_id() {
        let mut t = Transcript::default();
        t.apply_update(&json!({"update": {"sessionUpdate": "tool_call", "toolCallId": "t1", "title": "ls", "kind": "execute", "status": "pending"}}));
        t.apply_update(&json!({"update": {"sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed", "content": [{"type": "content", "content": {"type": "text", "text": "a\nb"}}]}}));
        assert_eq!(t.items.len(), 1);
        match &t.items[0] {
            Item::Tool { status, detail, .. } => {
                assert_eq!(status, "completed");
                assert_eq!(detail, "a\nb");
            }
            _ => panic!(),
        }
    }

    #[test]
    fn mux_events_add_user_and_permission() {
        let mut t = Transcript::default();
        t.apply_event(&json!({"seq": 1, "dir": "mux", "kind": "user_message", "msg": {"text": "hi"}}));
        t.apply_event(&json!({"seq": 2, "dir": "mux", "kind": "permission_request", "msg": {"permissionId": "p1", "request": {"toolCall": {"title": "rm -rf"}, "options": [{"optionId": "y", "name": "Allow", "kind": "allow_once"}]}}}));
        assert!(t.pending_permission().is_some());
        t.apply_event(&json!({"seq": 3, "dir": "mux", "kind": "permission_decision", "msg": {"permissionId": "p1", "outcome": {"outcome": "selected", "optionId": "y"}}}));
        assert!(t.pending_permission().is_none());
        t.apply_event(&json!({"seq": 4, "dir": "mux", "kind": "queued", "msg": {"text": "later", "position": 1}}));
        assert!(matches!(t.items.last(), Some(Item::User { queued: true, .. })));
        t.apply_event(&json!({"seq": 5, "dir": "mux", "kind": "user_message", "msg": {"text": "later"}}));
        assert!(matches!(t.items.last(), Some(Item::User { queued: false, .. })));
        assert_eq!(t.items.iter().filter(|i| matches!(i, Item::User { .. })).count(), 2);
        assert_eq!(t.last_seq, 5);
    }
}
