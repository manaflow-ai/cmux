//! Portable chat export/import.
//!
//! The existing `acpmux.bundle.v1` directory is a daemon transfer format. This
//! format is deliberately a single JSON document: it can be attached to an
//! issue, copied to another machine, and imported after the app's data is gone.

use super::*;
use crate::store::{EventRecord, SessionMeta, Store};
use crate::transcript::{Item, Transcript};
use anyhow::{Context, Result};
use cmux_chat_index::{IndexedChat, transcript::Turn};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
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
    /// The exact acpmux metadata needed for a lossless daemon re-import.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<SessionMeta>,
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

pub fn markdown(bundle: &PortableBundle) -> String {
    let mut out = String::new();
    for (index, chat) in bundle.chats.iter().enumerate() {
        if index > 0 {
            out.push_str("\n\n---\n\n");
        }
        out.push_str("# ");
        out.push_str(chat.title.as_deref().filter(|s| !s.is_empty()).unwrap_or("Untitled chat"));
        out.push_str("\n\n");
        out.push_str("- Harness: `");
        out.push_str(&chat.harness);
        out.push_str("`\n- Session: `");
        out.push_str(&chat.session_id);
        out.push('`');
        if let Some(cwd) = chat.cwd.as_deref() {
            out.push_str("\n- Folder: `");
            out.push_str(cwd);
            out.push('`');
        }
        for (turn_no, turn) in chat.turns.iter().enumerate() {
            out.push_str(&format!("\n\n## Turn {}\n\n", turn_no + 1));
            out.push_str("**User**\n\n");
            out.push_str(if turn.prompt.is_empty() { "(attachment)" } else { &turn.prompt });
            out.push_str("\n\n**Assistant**\n\n");
            out.push_str(if turn.answer.is_empty() { "(no answer)" } else { &turn.answer });
            if !turn.tool_calls.is_empty() {
                out.push_str("\n\n<details>\n<summary>Tool calls ( ");
                out.push_str(&turn.tool_calls.len().to_string());
                out.push_str(" )</summary>\n\n```json\n");
                let encoded =
                    serde_json::to_string_pretty(&turn.tool_calls).unwrap_or_else(|_| "[]".into());
                out.push_str(&encoded);
                out.push_str("\n```\n\n</details>");
            }
        }
    }
    if !out.is_empty() {
        out.push('\n');
    }
    out
}

fn text_of(value: &Value) -> String {
    match value {
        Value::String(s) => s.clone(),
        Value::Array(items) => items.iter().map(text_of).collect::<Vec<_>>().join(""),
        Value::Object(map) => map
            .get("text")
            .map(text_of)
            .or_else(|| map.get("content").map(text_of))
            .unwrap_or_default(),
        _ => String::new(),
    }
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

fn restore_attachments(chat: &PortableChat) -> Result<Vec<PathBuf>> {
    use base64::Engine;
    let root = crate::config::home().join("attachments");
    let mut created = Vec::new();
    for attachment in &chat.attachments {
        let Some(id) = attachment.get("id").and_then(Value::as_str) else { continue };
        anyhow::ensure!(
            id.len() == 64 && id.bytes().all(|b| b.is_ascii_hexdigit()),
            "invalid attachment id"
        );
        let Some(data) = attachment.get("data").and_then(Value::as_str) else { continue };
        let path = root.join(id);
        if path.is_file() {
            continue;
        }
        let bytes = base64::engine::general_purpose::STANDARD.decode(data)?;
        std::fs::create_dir_all(&root)?;
        std::fs::write(&path, bytes)?;
        created.push(path);
    }
    Ok(created)
}

pub fn from_session(session: &Arc<Session>, store: &dyn Store) -> Result<PortableChat> {
    let meta = session.meta();
    let mut events = Vec::new();
    store.scan(&meta.id, 0, &mut |event| {
        events.push(event);
        true
    })?;
    let (turns, attachments) = turns_from_events(&events);
    let mut exported_meta = meta.clone();
    // Session env may contain one-time seals and other credentials. It is runtime state, not
    // chat history, and must never leave this machine in a portable bundle.
    exported_meta.session_env.clear();
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
        session: Some(exported_meta),
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
        session: None,
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

pub fn read(path: &Path) -> Result<PortableBundle> {
    let text = std::fs::read_to_string(path)
        .with_context(|| format!("read chat bundle {}", path.display()))?;
    let bundle: PortableBundle = serde_json::from_str(&text).context("parse cmux chat bundle")?;
    anyhow::ensure!(bundle.schema == SCHEMA, "unsupported chat bundle schema {:?}", bundle.schema);
    Ok(bundle)
}

pub fn write(path: &Path, bundle: &PortableBundle) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(path, serde_json::to_vec_pretty(bundle)?)?;
    Ok(())
}

fn imported_id(chat: &PortableChat) -> String {
    let mut hasher = DefaultHasher::new();
    chat.key.hash(&mut hasher);
    format!("imported-{:016x}", hasher.finish())
}

fn imported_events(chat: &PortableChat, id: &str) -> Vec<EventRecord> {
    if !chat.events.is_empty() {
        return chat.events.clone();
    }
    let mut events = Vec::new();
    let mut seq = 0;
    for turn in &chat.turns {
        seq += 1;
        let mut parts = Vec::new();
        if !turn.prompt.is_empty() {
            parts.push(json!({"type": "text", "text": turn.prompt}));
        }
        parts.extend(chat.attachments.iter().cloned());
        events.push(EventRecord {
            seq,
            at: turn.prompt_at.unwrap_or(0),
            dir: "mux".into(),
            kind: "user_message".into(),
            msg: json!({"sessionId": id, "text": turn.prompt, "parts": parts}),
            host_seq: None,
        });
        for call in &turn.tool_calls {
            seq += 1;
            events.push(EventRecord {
                seq,
                at: turn.prompt_at.unwrap_or(0),
                dir: "in".into(),
                kind: "tool_call".into(),
                msg: json!({"method": "session/update", "params": {"update": {
                    "sessionUpdate": "tool_call",
                    "toolCallId": call.get("id").and_then(Value::as_str).unwrap_or("imported-tool"),
                    "title": call.get("title").cloned().unwrap_or_else(|| Value::String("Tool call".into())),
                    "kind": call.get("kind").cloned().unwrap_or(Value::Null),
                    "status": call.get("status").cloned().unwrap_or(Value::Null),
                    "rawInput": call.get("detail").cloned().unwrap_or(Value::Null),
                }}}),
                host_seq: None,
            });
        }
        if !turn.answer.is_empty() {
            seq += 1;
            events.push(EventRecord {
                seq,
                at: turn.answer_at.or(turn.prompt_at).unwrap_or(0),
                dir: "in".into(),
                kind: "agent_message_chunk".into(),
                msg: json!({"method": "session/update", "params": {"update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": turn.answer},
                }}}),
                host_seq: None,
            });
        }
    }
    events
}

pub fn import_session_dir(root: &Path, chat: &PortableChat, harness: &str) -> Result<PathBuf> {
    let source = chat.session.as_ref();
    let id = source.map(|meta| meta.id.clone()).unwrap_or_else(|| imported_id(chat));
    anyhow::ensure!(super::transfer::is_plain_id(&id), "invalid session id in chat bundle");
    let cwd = chat
        .cwd
        .as_deref()
        .map(PathBuf::from)
        .filter(|path| path.is_dir())
        .unwrap_or_else(crate::config::home);
    let now = crate::store::now_ms();
    // Portable documents carry history, not authority to resume a destination's native session.
    // Reconstruct metadata from chat fields so new runtime fields are safe by default too.
    let mut meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA,
        "id": id,
        "name": source.map(|meta| meta.name.clone()).or_else(|| chat.title.clone())
            .unwrap_or_else(|| format!("Imported {} chat", chat.harness)),
        "harness": harness,
        "cwd": cwd,
        "status": "idle",
        "createdAt": chat.created_at.unwrap_or(now),
        "updatedAt": chat.updated_at.unwrap_or(now),
        "title": chat.title,
        "modelRequest": chat.model,
    }))?;
    let mut events = imported_events(chat, &meta.id);
    meta.last_seq = events.iter().map(|event| event.seq).max().unwrap_or(0);
    meta.transcript_seq = meta.last_seq;
    meta.event_count = events.len() as u64;
    meta.turn_count = chat.turns.len() as u64;
    let dir = root.join(&meta.id);
    std::fs::create_dir_all(dir.join("events"))?;
    std::fs::write(dir.join("session.json"), serde_json::to_vec_pretty(&meta)?)?;
    events.sort_by_key(|event| event.seq);
    let event_count = events.len();
    let mut text = String::new();
    for event in events {
        text.push_str(&serde_json::to_string(&event)?);
        text.push('\n');
    }
    std::fs::write(dir.join("events/000001.ndjson"), text)?;
    std::fs::write(
        dir.join("manifest.json"),
        serde_json::to_vec_pretty(
            &json!({"schema": "acpmux.bundle.v1", "id": meta.id, "eventCount": event_count, "lastSeq": meta.last_seq}),
        )?,
    )?;
    Ok(dir)
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
    let format = params.get("format").and_then(Value::as_str).unwrap_or("json");
    if !matches!(format, "json" | "markdown") {
        return Err(RpcError::invalid_params("format must be json or markdown"));
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
        let sessions: Vec<_> = hub.sessions.lock().unwrap().values().cloned().collect();
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
    let content = if format == "markdown" {
        Value::String(markdown(&bundle))
    } else {
        Value::String(
            serde_json::to_string_pretty(&bundle).map_err(|e| RpcError::internal(e.to_string()))?,
        )
    };
    Ok(json!({"format": format, "content": content, "chatCount": bundle.chats.len()}))
}

fn usable_import_harness(name: &str, profile: &crate::config::HarnessProfile) -> bool {
    name != "cmux-harness"
        && profile.family.as_deref() != Some("cmux-harness")
        && profile.kind != crate::config::HarnessKind::Terminal
        && !profile.argv.is_empty()
}

/// Import the lossless acpmux entries in a portable bundle through the same
/// validation and rollback path as the directory transfer format.
pub async fn import(hub: &Arc<Hub>, path: &Path) -> std::result::Result<Value, RpcError> {
    let bundle = read(path).map_err(|e| RpcError::invalid_params(e.to_string()))?;
    let configured: Vec<String> = hub
        .config
        .read()
        .await
        .harnesses
        .iter()
        .filter(|(name, profile)| usable_import_harness(name, profile))
        .map(|(name, _)| name.clone())
        .collect();
    let fallback = configured.first().cloned().ok_or_else(|| {
        RpcError::invalid_params("no configured non-cmux chat harness can host imported chats")
    })?;
    let root = tempfile::Builder::new()
        .prefix("cmux-chat-import-")
        .tempdir()
        .map_err(|e| RpcError::internal(e.to_string()))?;
    // Validate and stage the whole document before making any chat visible.
    let mut dirs = Vec::new();
    let mut ids = std::collections::HashSet::new();
    for chat in &bundle.chats {
        let harness =
            configured.iter().find(|candidate| *candidate == &chat.harness).unwrap_or(&fallback);
        let dir = import_session_dir(root.path(), chat, harness)
            .map_err(|e| RpcError::invalid_params(e.to_string()))?;
        if !ids.insert(dir.clone()) {
            return Err(RpcError::invalid_params("duplicate chat id in bundle"));
        }
        dirs.push(dir);
    }
    let mut imported = Vec::new();
    let mut imported_sessions = Vec::new();
    let mut restored_attachments = Vec::new();
    for (chat, dir) in bundle.chats.iter().zip(dirs) {
        match restore_attachments(chat) {
            Ok(attachments) => restored_attachments.extend(attachments),
            Err(error) => {
                for session in imported_sessions {
                    let _ = hub.kill(&session, true).await;
                }
                for path in restored_attachments {
                    let _ = std::fs::remove_file(path);
                }
                return Err(RpcError::invalid_params(format!("restore attachments: {error}")));
            }
        }
        match hub.import(&dir, None).await {
            Ok(session) => {
                imported.push(hub.session_summary(&session));
                imported_sessions.push(session);
            }
            Err(error) => {
                for session in imported_sessions {
                    let _ = hub.kill(&session, true).await;
                }
                for path in restored_attachments {
                    let _ = std::fs::remove_file(path);
                }
                return Err(error);
            }
        }
    }
    Ok(json!({"schema": SCHEMA, "imported": imported, "skipped": 0}))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(seq: u64, at: u64, dir: &str, kind: &str, msg: Value) -> EventRecord {
        EventRecord { seq, at, dir: dir.into(), kind: kind.into(), msg, host_seq: None }
    }

    #[test]
    fn markdown_keeps_turns_readable_and_tools_folded() {
        let events = vec![
            event(1, 10, "mux", "user_message", json!({"text": "Inspect the file"})),
            event(
                2,
                11,
                "in",
                "tool_call",
                json!({"method": "session/update", "params": {"update": {"sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Read file", "kind": "read", "status": "completed", "rawInput": {"path": "a.txt"}}}}),
            ),
            event(
                3,
                12,
                "in",
                "agent_message_chunk",
                json!({"method": "session/update", "params": {"update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Done"}}}}),
            ),
        ];
        let (turns, _) = turns_from_events(&events);
        let bundle = bundle(vec![PortableChat {
            key: "acpmux:s".into(),
            harness: "codex".into(),
            session_id: "s".into(),
            title: Some("Test".into()),
            cwd: None,
            created_at: None,
            updated_at: None,
            model: None,
            turns,
            events,
            session: None,
            attachments: vec![],
        }]);
        let text = markdown(&bundle);
        assert!(text.contains("**User**"));
        assert!(text.contains("Done"));
        assert!(text.contains("<details>"));
        assert!(text.contains("Read file"));
    }

    #[test]
    fn bundle_round_trips_lossless_events() {
        let chat = PortableChat {
            key: "acpmux:s".into(),
            harness: "codex".into(),
            session_id: "s".into(),
            title: None,
            cwd: None,
            created_at: None,
            updated_at: None,
            model: Some("m".into()),
            turns: vec![],
            events: vec![event(
                1,
                7,
                "mux",
                "user_message",
                json!({"text": "hi", "image": "data"}),
            )],
            session: None,
            attachments: vec![],
        };
        let encoded = serde_json::to_string(&bundle(vec![chat.clone()])).unwrap();
        let decoded: PortableBundle = serde_json::from_str(&encoded).unwrap();
        assert_eq!(decoded.chats[0], chat);
    }

    #[test]
    fn imported_transcript_prompts_use_the_canonical_text_field() {
        let chat = PortableChat {
            key: "foreign:s".into(),
            harness: "foreign".into(),
            session_id: "s".into(),
            title: None,
            cwd: None,
            created_at: None,
            updated_at: None,
            model: None,
            turns: vec![PortableTurn {
                prompt: "remember this".into(),
                answer: String::new(),
                prompt_at: None,
                answer_at: None,
                tool_calls: Vec::new(),
            }],
            events: Vec::new(),
            session: None,
            attachments: Vec::new(),
        };
        let events = imported_events(&chat, "imported");
        assert_eq!(events[0].msg.get("text").and_then(Value::as_str), Some("remember this"));
    }
    fn fixture() -> PortableChat {
        let mut chat: PortableChat = serde_json::from_value(json!({
            "key": "acpmux:portable", "harness": "codex", "sessionId": "portable",
            "title": "Saved chat", "cwd": std::env::temp_dir(), "createdAt": 1,
            "updatedAt": 2, "model": "test-model", "turns": [{
                "prompt": "remember this", "answer": "I remember", "promptAt": 1,
                "answerAt": 2, "toolCalls": []
            }]
        }))
        .unwrap();
        chat.session = Some(
            serde_json::from_value(json!({
                "schema": crate::store::META_SCHEMA, "id": "portable", "name": "Saved chat",
                "harness": "codex", "cwd": std::env::temp_dir(), "status": "idle",
                "createdAt": 1, "updatedAt": 2, "agentSessionId": "existing-local-native",
                "previousAgentSessionIds": ["another-local-native"], "preset": "unsafe-preset",
                "sessionEnv": {"OPTCHAT_TURN_SEAL": "secret"}, "spawnArgv": ["unsafe-command"]
            }))
            .unwrap(),
        );
        chat
    }

    #[test]
    fn portable_import_never_resumes_a_native_conversation_or_launch_state() {
        let root = tempfile::tempdir().unwrap();
        let chat = fixture();
        let dir = import_session_dir(root.path(), &chat, "codex").unwrap();
        let meta: SessionMeta =
            serde_json::from_slice(&std::fs::read(dir.join("session.json")).unwrap()).unwrap();
        assert_eq!(meta.id, "portable");
        assert_eq!(meta.model_request.as_deref(), Some("test-model"));
        assert!(meta.agent_session_id.is_none());
        assert!(meta.previous_agent_session_ids.is_empty());
        assert!(meta.session_env.is_empty());
        assert!(meta.spawn_argv.is_none());
        assert!(meta.preset.is_none());
    }

    #[test]
    fn import_harness_filter_rejects_terminal_and_durable_profiles() {
        let mut profile: crate::config::HarnessProfile =
            serde_json::from_value(json!({"argv": ["agent"]})).unwrap();
        assert!(usable_import_harness("codex", &profile));
        assert!(!usable_import_harness("cmux-harness", &profile));
        profile.family = Some("cmux-harness".into());
        assert!(!usable_import_harness("alias", &profile));
        profile.family = None;
        profile.kind = crate::config::HarnessKind::Terminal;
        assert!(!usable_import_harness("terminal", &profile));
    }

    #[tokio::test]
    async fn export_delete_store_import_restores_readable_chats() {
        use crate::store::MemoryStore;
        let mut cfg: crate::config::Config = serde_json::from_value(json!({})).unwrap();
        cfg.store.mode = crate::config::StoreMode::Memory;
        cfg.harnesses.clear();
        cfg.harnesses.insert(
            "codex".into(),
            serde_json::from_value(json!({"argv": ["unused-agent"]})).unwrap(),
        );
        let source = Hub::new(cfg.clone(), Box::new(MemoryStore::default()));
        let chat = fixture();
        let session = source.insert_test_session(chat.session.clone().unwrap());
        for record in imported_events(&chat, "portable") {
            source.append(&session, &record.dir, &record.kind, record.msg);
        }
        let exported = export_value(&source, None, &json!({"all": true})).unwrap();
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("chats.json");
        std::fs::write(&path, exported["content"].as_str().unwrap()).unwrap();
        drop(session);
        drop(source); // Discard the original profile's only store before restoring.
        let destination = Hub::new(cfg, Box::new(MemoryStore::default()));
        let restored = import(&destination, &path).await.unwrap();
        assert_eq!(restored["imported"].as_array().unwrap().len(), 1);
        let exported = export_value(&destination, None, &json!({"all": true})).unwrap();
        let bundle: PortableBundle =
            serde_json::from_str(exported["content"].as_str().unwrap()).unwrap();
        assert_eq!(bundle.chats[0].turns[0].prompt, "remember this");
        assert_eq!(bundle.chats[0].turns[0].answer, "I remember");
        assert!(markdown(&bundle).contains("remember this"));
        assert!(destination.resolve("portable").unwrap().meta().agent_session_id.is_none());
    }
}
