//! `agent.*` requests: acpmux sessions on this machine, started by the hand
//! with the hand's own permission policy, and their events sent back as
//! short summaries.
//!
//! The request picks the harness (claude, codex or opencode), folder, model
//! and effort. It never picks the policy, the environment, or the program a
//! harness runs: those are this machine's acpmux configuration.

use super::HandError;
use crate::client::Client;
use crate::rpc::{Message, method};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tokio::sync::mpsc;

pub const HARNESSES: &[&str] = &["claude", "codex", "opencode"];
/// Text is sent once this much has gathered, or at the next non-text event.
const TEXT_FLUSH: usize = 2048;

struct Session {
    cwd: PathBuf,
    client: Arc<Client>,
}

/// Sessions this hand started, by acpmux session id. A hand drives only these.
#[derive(Clone, Default)]
pub struct Agents {
    sessions: Arc<Mutex<HashMap<String, Session>>>,
}

/// One outbound frame: `{"t":"event","session","seq","event"}`.
pub type EventSink = mpsc::Sender<Value>;

impl Agents {
    /// The folder a session runs in (the path its requests are checked on).
    pub fn cwd_of(&self, session: &str) -> Result<PathBuf, HandError> {
        self.sessions
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(session)
            .map(|s| s.cwd.clone())
            .ok_or_else(|| {
                HandError::new(
                    "agent.unknown_session",
                    format!("{session} is not a session this hand started"),
                )
            })
    }

    fn client(&self, session: &str) -> Result<Arc<Client>, HandError> {
        self.sessions
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(session)
            .map(|s| s.client.clone())
            .ok_or_else(|| {
                HandError::new(
                    "agent.unknown_session",
                    format!("{session} is not a session this hand started"),
                )
            })
    }

    pub async fn start(
        &self,
        policy: &str,
        harness: &str,
        cwd: PathBuf,
        prompt: &str,
        model: Option<&str>,
        effort: Option<&str>,
        sink: EventSink,
    ) -> Result<Value, HandError> {
        if !HARNESSES.contains(&harness) {
            return Err(HandError::new(
                "agent.bad_harness",
                format!("harness {harness:?} is not one of {}", HARNESSES.join(", ")),
            ));
        }
        if !cwd.is_dir() {
            return Err(HandError::new(
                "agent.bad_cwd",
                format!("{} is not a folder", cwd.display()),
            ));
        }
        let client = crate::daemon::connect(true)
            .await
            .map_err(|e| HandError::new("agent.daemon", format!("{e:#}")))?;
        let mut meta = json!({ "harness": harness, "policy": policy });
        if let Some(m) = model {
            meta["model"] = json!(m);
        }
        if let Some(e) = effort {
            meta["effort"] = json!(e);
        }
        let created = client
            .request(
                method::SESSION_NEW,
                json!({ "cwd": cwd, "mcpServers": [], "_meta": { "acpmux": meta } }),
            )
            .await
            .map_err(|e| HandError::new("agent.start_failed", format!("{e:#}")))?;
        let session = created
            .get("sessionId")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                HandError::new("agent.start_failed", "session/new returned no sessionId")
            })?
            .to_owned();
        let Some(mut rx) = client.notifications().await else {
            return Err(HandError::new("agent.start_failed", "no event stream from the daemon"));
        };
        let attached = client
            .request(method::MUX_ATTACH, json!({ "sessionId": session, "eventStream": true, "afterSeq": 0, "visible": false }))
            .await
            .map_err(|e| HandError::new("agent.start_failed", format!("attach: {e:#}")))?;
        self.sessions
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(session.clone(), Session { cwd: cwd.clone(), client: client.clone() });
        // Pump: daemon events -> summaries -> the Cloud.
        let sid = session.clone();
        let backlog: Vec<Value> =
            attached.get("events").and_then(Value::as_array).cloned().unwrap_or_default();
        let agents = self.clone();
        tokio::spawn(async move {
            let mut text = TextBuffer::default();
            for ev in backlog {
                forward(&sid, &ev, &mut text, &sink).await;
            }
            while let Some(msg) = rx.recv().await {
                match msg {
                    Message::Notification { method: m, params: Some(params) }
                        if m == method::MUX_EVENT =>
                    {
                        forward(&sid, &params, &mut text, &sink).await;
                    }
                    Message::Notification { method: m, .. } if m == method::MUX_DISCONNECTED => {
                        break;
                    }
                    _ => {}
                }
            }
            text.flush(&sid, None, &sink).await;
            agents.sessions.lock().unwrap_or_else(std::sync::PoisonError::into_inner).remove(&sid);
        });
        let prompt_id = self.prompt(&session, prompt)?;
        Ok(json!({ "session": session, "harness": harness, "cwd": cwd, "prompt_id": prompt_id }))
    }

    /// Queues a prompt; the turn's events arrive on the event stream.
    pub fn prompt(&self, session: &str, text: &str) -> Result<String, HandError> {
        let client = self.client(session)?;
        let prompt_id = uuid::Uuid::now_v7().to_string();
        let params = json!({
            "sessionId": session,
            "prompt": [{ "type": "text", "text": text }],
            "_meta": { "acpmux": { "promptId": prompt_id, "steer": false, "resend": false } }
        });
        tokio::spawn(async move {
            // The answer comes at the end of the turn; the stream already carried it.
            let _ = client.request(method::SESSION_PROMPT, params).await;
        });
        Ok(prompt_id)
    }

    pub async fn cancel(&self, session: &str) -> Result<Value, HandError> {
        let client = self.client(session)?;
        client
            .notify(method::SESSION_CANCEL, json!({ "sessionId": session }))
            .await
            .map_err(|e| HandError::new("agent.cancel_failed", format!("{e:#}")))?;
        Ok(json!({ "session": session, "cancelled": true }))
    }

    /// Refuses (never allows) one waiting permission request of the agent.
    pub async fn deny(&self, session: &str, permission: &str) -> Result<Value, HandError> {
        let client = self.client(session)?;
        client
            .request(
                method::MUX_PERMISSION_RESPOND,
                json!({ "sessionId": session, "permissionId": permission }),
            )
            .await
            .map_err(|e| HandError::new("agent.deny_failed", format!("{e:#}")))?;
        Ok(json!({ "session": session, "permission": permission, "denied": true }))
    }

    pub async fn events(
        &self,
        session: &str,
        after_seq: u64,
        limit: u64,
    ) -> Result<Value, HandError> {
        let client = self.client(session)?;
        let page = client
            .request(
                method::MUX_EVENTS,
                json!({ "sessionId": session, "afterSeq": after_seq, "limit": limit.min(2000) }),
            )
            .await
            .map_err(|e| HandError::new("agent.events_failed", format!("{e:#}")))?;
        let raw = page.get("events").and_then(Value::as_array).cloned().unwrap_or_default();
        let last = raw
            .iter()
            .filter_map(|e| e.get("seq").and_then(Value::as_u64))
            .max()
            .unwrap_or(after_seq);
        let events: Vec<Value> = raw.iter().filter_map(summarize).collect();
        Ok(
            json!({ "session": session, "events": events, "last_seq": last, "has_more": page.get("hasMore").cloned().unwrap_or(json!(false)) }),
        )
    }
}

#[derive(Default)]
struct TextBuffer {
    text: String,
    seq: u64,
}

impl TextBuffer {
    async fn flush(&mut self, session: &str, seq: Option<u64>, sink: &EventSink) {
        if self.text.is_empty() {
            return;
        }
        let text = std::mem::take(&mut self.text);
        let at = seq.unwrap_or(self.seq);
        let _ = sink.try_send(json!({ "t": "event", "session": session, "seq": at, "event": { "kind": "text", "text": text } }));
    }
}

async fn forward(session: &str, ev: &Value, text: &mut TextBuffer, sink: &EventSink) {
    let seq = ev.get("seq").and_then(Value::as_u64).unwrap_or(0);
    let Some(summary) = summarize(ev) else { return };
    if summary["kind"] == "text" {
        text.text.push_str(summary["text"].as_str().unwrap_or(""));
        text.seq = seq;
        if text.text.len() >= TEXT_FLUSH {
            text.flush(session, Some(seq), sink).await;
        }
        return;
    }
    text.flush(session, None, sink).await;
    let _ =
        sink.try_send(json!({ "t": "event", "session": session, "seq": seq, "event": summary }));
}

/// One daemon record as a short event, or None for records the Cloud does
/// not need (raw requests, replays, usage).
pub fn summarize(ev: &Value) -> Option<Value> {
    let dir = ev.get("dir").and_then(Value::as_str)?;
    let kind = ev.get("kind").and_then(Value::as_str).unwrap_or("");
    let msg = ev.get("msg").cloned().unwrap_or(Value::Null);
    let at = ev.get("at").cloned().unwrap_or(Value::Null);
    match dir {
        "in" if !kind.ends_with(".replay")
            && msg.get("method").and_then(Value::as_str) == Some(method::SESSION_UPDATE) =>
        {
            let u = msg.pointer("/params/update")?;
            match u.get("sessionUpdate").and_then(Value::as_str)? {
                "agent_message_chunk" => {
                    let t = u.pointer("/content/text").and_then(Value::as_str)?;
                    Some(json!({ "kind": "text", "text": t }))
                }
                k @ ("tool_call" | "tool_call_update") => Some(json!({
                    "kind": "tool",
                    "update": k == "tool_call_update",
                    "id": u.get("toolCallId"),
                    "title": u.get("title"),
                    "tool_kind": u.get("kind"),
                    "status": u.get("status"),
                    "at": at,
                })),
                _ => None,
            }
        }
        "mux" => match kind {
            "turn_started" => Some(json!({ "kind": "turn_start", "at": at })),
            "turn_end" => {
                Some(json!({ "kind": "turn_end", "stop_reason": msg.get("stopReason"), "at": at }))
            }
            "turn_error" => Some(
                json!({ "kind": "error", "message": msg.get("error"), "code": msg.get("code"), "at": at }),
            ),
            "permission_request" | "permission_reissued" => Some(json!({
                "kind": "permission",
                "permission_id": msg.get("permissionId"),
                "title": msg.pointer("/request/toolCall/title"),
                "at": at,
            })),
            _ => None,
        },
        _ => None,
    }
}
