//! Portable chat export: one call writes a chat, a selection, or every chat on
//! this device as a single `cmux.chat-bundle.v1` JSON document that can be
//! attached to an issue or copied to another machine.

use super::*;
use crate::store::{EventRecord, Store};
use crate::transcript::{Item, Transcript};
use anyhow::Result;
use cmux_chat_index::{IndexedChat, transcript::Turn};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::sync::Arc;

pub const SCHEMA: &str = "cmux.chat-bundle.v1";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PortableBundle {
    pub schema: String,
    pub exported_at: u64,
    pub chats: Vec<PortableChat>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PortableChat {
    pub key: String,
    pub harness: String,
    pub session_id: String,
    pub title: Option<String>,
    pub cwd: Option<String>,
    pub created_at: Option<u64>,
    pub updated_at: Option<u64>,
    pub model: Option<String>,
    pub turns: Vec<PortableTurn>,
    /// The complete acpmux event journal. Empty for a foreign harness whose
    /// adapter exposes only a transcript.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub events: Vec<EventRecord>,
    /// Attachment blocks are retained separately for consumers that do not
    /// want to walk the raw journal.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub attachments: Vec<Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PortableTurn {
    pub prompt: String,
    pub answer: String,
    pub prompt_at: Option<u64>,
    pub answer_at: Option<u64>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tool_calls: Vec<Value>,
}

fn attachment_bytes(id: &str) -> Option<Vec<u8>> {
    if id.len() != 64 || !id.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return None;
    }
    let path = crate::config::home().join("attachments").join(id);
    #[cfg(unix)]
    {
        use std::io::Read;
        use std::os::unix::fs::OpenOptionsExt;
        let mut file = std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(path)
            .ok()?;
        let mut bytes = Vec::new();
        file.read_to_end(&mut bytes).ok()?;
        Some(bytes)
    }
    #[cfg(not(unix))]
    {
        let metadata = std::fs::symlink_metadata(&path).ok()?;
        metadata.file_type().is_file().then(|| std::fs::read(path).ok()).flatten()
    }
}

fn turns_from_events(events: &[EventRecord]) -> (Vec<PortableTurn>, Vec<Value>) {
    let mut transcript = Transcript::default();
    for event in events {
        transcript.apply_event(&json!({"seq": event.seq, "at": event.at, "dir": event.dir, "kind": event.kind, "msg": event.msg}));
    }
    let mut turns = Vec::new();
    let mut attachments = Vec::new();
    let mut current: Option<PortableTurn> = None;
    for item in &transcript.items {
        match item {
            Item::User { text, .. } => {
                if let Some(turn) = current.take() {
                    turns.push(turn);
                }
                current = Some(PortableTurn {
                    prompt: text.clone(),
                    answer: String::new(),
                    prompt_at: None,
                    answer_at: None,
                    tool_calls: Vec::new(),
                });
            }
            Item::Assistant { text } => {
                if let Some(turn) = current.as_mut() {
                    turn.answer.push_str(text);
                }
            }
            Item::Tool { id, title, kind, status, detail } => {
                let call = json!({"id": id, "title": title, "kind": kind, "status": status, "detail": detail});
                if let Some(turn) = current.as_mut() {
                    turn.tool_calls.push(call);
                }
            }
            _ => {}
        }
    }
    if let Some(turn) = current {
        turns.push(turn);
    }
    for event in events {
        if event.kind == "user_message" {
            for key in ["images", "attachments"] {
                if let Some(items) = event.msg.get(key).and_then(Value::as_array) {
                    attachments.extend(items.iter().cloned());
                }
            }
            if let Some(parts) = event.msg.get("parts").and_then(Value::as_array) {
                attachments.extend(
                    parts
                        .iter()
                        .filter(|part| {
                            matches!(
                                part.get("type").and_then(Value::as_str),
                                Some("image" | "resource_link")
                            )
                        })
                        .cloned(),
                );
            }
        }
    }
    let mut with_data = Vec::new();
    for attachment in attachments {
        let Some(id) = attachment.get("id").and_then(Value::as_str).map(str::to_owned) else {
            with_data.push(attachment);
            continue;
        };
        let mut value = attachment;
        if let Some(bytes) = attachment_bytes(&id) {
            use base64::Engine;
            value["data"] = Value::String(base64::engine::general_purpose::STANDARD.encode(bytes));
        }
        with_data.push(value);
    }
    (turns, with_data)
}

pub fn from_session(session: &Arc<Session>, store: &dyn Store) -> Result<PortableChat> {
    let meta = session.meta();
    let mut events = Vec::new();
    store.scan(&meta.id, 0, &mut |event| {
        events.push(event);
        true
    })?;
    let (turns, attachments) = turns_from_events(&events);
    Ok(PortableChat {
        key: format!("acpmux:{}", meta.id),
        harness: meta.harness.clone(),
        session_id: meta.id.clone(),
        title: meta.title.clone().or_else(|| Some(meta.name.clone())),
        cwd: Some(meta.cwd.to_string_lossy().into_owned()),
        created_at: Some(meta.created_at),
        updated_at: Some(meta.updated_at),
        model: meta.model_request.clone(),
        turns,
        events,
        attachments,
    })
}

fn indexed_turns(
    chat: &IndexedChat,
) -> std::result::Result<Vec<PortableTurn>, cmux_chat_index::transcript::TranscriptError> {
    let entry = &chat.entry;
    Ok(cmux_chat_index::transcript::read_turns(
        entry.harness,
        &entry.source_path,
        &entry.session_id,
    )?
    .into_iter()
    .map(|Turn { prompt, answer, prompt_at, answer_at }| PortableTurn {
        prompt,
        answer,
        prompt_at,
        answer_at,
        tool_calls: Vec::new(),
    })
    .collect())
}

fn portable_indexed(chat: &IndexedChat, turns: Vec<PortableTurn>) -> PortableChat {
    let entry = &chat.entry;
    PortableChat {
        key: format!("{}:{}", entry.harness.id(), entry.session_id),
        harness: entry.harness.id().to_owned(),
        session_id: entry.session_id.clone(),
        title: entry.title.clone(),
        cwd: entry.cwd.clone(),
        created_at: entry.created_ms.and_then(|ms| u64::try_from(ms).ok()),
        updated_at: u64::try_from(entry.updated_ms).ok(),
        model: None,
        turns,
        events: Vec::new(),
        attachments: Vec::new(),
    }
}

pub fn from_indexed(chat: &IndexedChat) -> Result<PortableChat> {
    let turns = indexed_turns(chat).map_err(|e| anyhow::anyhow!("transcript.{}: {e}", e.code()))?;
    Ok(portable_indexed(chat, turns))
}

pub fn bundle(chats: Vec<PortableChat>) -> PortableBundle {
    PortableBundle { schema: SCHEMA.to_owned(), exported_at: crate::store::now_ms(), chats }
}

/// Build the portable bundle requested by `_acpmux/chat_export`.
fn add_live_session(
    hub: &Hub,
    session: Arc<Session>,
    seen: &mut std::collections::HashSet<String>,
    chats: &mut Vec<PortableChat>,
) -> std::result::Result<(), RpcError> {
    let id = session.meta().id;
    if seen.insert(format!("acpmux:{id}")) {
        if !hub.store_deferred(&session) {
            return Err(RpcError::internal("could not store the chat's newest tool output"));
        }
        chats.push(
            from_session(&session, hub.store.as_ref())
                .map_err(|e| RpcError::internal(e.to_string()))?,
        );
    }
    Ok(())
}

pub fn export_value(
    hub: &Hub,
    service: Option<&Arc<crate::chats::ChatService>>,
    params: &Value,
) -> std::result::Result<Value, RpcError> {
    if params.get("format").and_then(Value::as_str).is_some_and(|format| format != "json") {
        return Err(RpcError::invalid_params("format must be json"));
    }
    let all = params.get("all").and_then(Value::as_bool).unwrap_or(false);
    let mut keys: Vec<String> = params
        .get("keys")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(str::to_owned)
        .collect();
    if let Some(id) = params.get("sessionId").and_then(Value::as_str) {
        keys.push(format!("acpmux:{id}"));
    }
    if !all && keys.is_empty() {
        return Err(RpcError::invalid_params("keys, sessionId, or all is required"));
    }
    let mut chats = Vec::new();
    let mut seen = std::collections::HashSet::new();
    if all {
        let sessions: Vec<_> = hub
            .sessions
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .values()
            .cloned()
            .collect();
        for session in sessions {
            add_live_session(hub, session, &mut seen, &mut chats)?;
        }
        if let Some(service) = service {
            let query = crate::chats::ChatQuery::default();
            if let Some(indexed) = service.listed_from(&query) {
                for chat in indexed {
                    let key = format!("{}:{}", chat.entry.harness.id(), chat.entry.session_id);
                    if seen.insert(key) {
                        match indexed_turns(&chat) {
                            Ok(turns) => chats.push(portable_indexed(&chat, turns)),
                            Err(cmux_chat_index::transcript::TranscriptError::Unsupported) => {}
                            Err(error) => {
                                return Err(RpcError::invalid_params(format!(
                                    "transcript.{}: {error}",
                                    error.code()
                                )));
                            }
                        }
                    }
                }
            }
        }
    } else {
        for key in keys {
            if let Some(id) = key.strip_prefix("acpmux:") {
                add_live_session(hub, hub.resolve(id)?, &mut seen, &mut chats)?;
                continue;
            }
            let parsed = crate::chats::parse_key(&key)
                .ok_or_else(|| RpcError::invalid_params(format!("invalid chat key {key:?}")))?;
            let service = service.ok_or_else(|| RpcError::not_found("chat index is not ready"))?;
            let chat = service
                .get(&parsed)
                .ok_or_else(|| RpcError::not_found(format!("no chat {key}")))?;
            if seen.insert(key) {
                chats.push(
                    from_indexed(&chat).map_err(|e| RpcError::invalid_params(e.to_string()))?,
                );
            }
        }
    }
    chats.sort_by_key(|chat| std::cmp::Reverse(chat.updated_at.unwrap_or(0)));
    let bundle = bundle(chats);
    let content =
        serde_json::to_string_pretty(&bundle).map_err(|e| RpcError::internal(e.to_string()))?;
    Ok(json!({"format": "json", "content": content, "chatCount": bundle.chats.len()}))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(seq: u64, at: u64, dir: &str, kind: &str, msg: Value) -> EventRecord {
        EventRecord { seq, at, dir: dir.into(), kind: kind.into(), msg, host_seq: None }
    }

    fn update(kind: &str, update: Value) -> Value {
        let mut update = update;
        update["sessionUpdate"] = json!(kind);
        json!({"method": "session/update", "params": {"update": update}})
    }

    #[test]
    fn turns_keep_prompt_answer_and_tool_calls() {
        let events = vec![
            event(1, 10, "mux", "user_message", json!({"text": "Inspect the file"})),
            event(
                2,
                11,
                "in",
                "tool_call",
                update(
                    "tool_call",
                    json!({"toolCallId": "t1", "title": "Read file", "kind": "read", "status": "completed"}),
                ),
            ),
            event(
                3,
                12,
                "in",
                "agent_message_chunk",
                update("agent_message_chunk", json!({"content": {"type": "text", "text": "Done"}})),
            ),
        ];
        let (turns, _) = turns_from_events(&events);
        assert_eq!(turns.len(), 1);
        assert_eq!(turns[0].prompt, "Inspect the file");
        assert_eq!(turns[0].answer, "Done");
        assert_eq!(turns[0].tool_calls[0]["title"], "Read file");
    }

    #[test]
    fn export_of_a_live_session_is_one_call_and_round_trips() {
        let mut cfg: crate::config::Config = serde_json::from_value(json!({})).unwrap();
        cfg.store.mode = crate::config::StoreMode::Memory;
        let hub = Hub::new(cfg, Box::new(crate::store::MemoryStore::default()));
        let meta: crate::store::SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "portable", "name": "Saved chat",
            "harness": "codex", "cwd": std::env::temp_dir(), "status": "idle",
            "createdAt": 1, "updatedAt": 2, "sessionEnv": {"OPTCHAT_TURN_SEAL": "secret"}
        }))
        .unwrap();
        // A store keeps a session's events only once it holds the session (`MemoryStore::append`).
        hub.store.save(&meta).unwrap();
        let session = hub.insert_test_session(meta);
        hub.append(&session, "mux", "user_message", json!({"text": "remember this"}));
        let answer = json!({"content": {"type": "text", "text": "I remember"}});
        hub.append(&session, "in", "agent_message_chunk", update("agent_message_chunk", answer));
        let out = export_value(&hub, None, &json!({"sessionId": "portable"})).unwrap();
        let text = out["content"].as_str().unwrap();
        assert!(!text.contains("secret"), "session env must never leave the machine");
        let bundle: PortableBundle = serde_json::from_str(text).unwrap();
        assert_eq!(bundle.schema, SCHEMA);
        let chat = &bundle.chats[0];
        assert_eq!(
            (chat.key.as_str(), chat.title.as_deref()),
            ("acpmux:portable", Some("Saved chat"))
        );
        assert_eq!(
            (chat.turns[0].prompt.as_str(), chat.turns[0].answer.as_str()),
            ("remember this", "I remember")
        );
        assert_eq!(chat.events.len(), 2);
        assert_eq!(
            serde_json::from_str::<PortableBundle>(&serde_json::to_string(&bundle).unwrap())
                .unwrap(),
            bundle
        );
        assert!(export_value(&hub, None, &json!({"format": "markdown", "all": true})).is_err());
        assert!(export_value(&hub, None, &json!({})).is_err());
    }
}
