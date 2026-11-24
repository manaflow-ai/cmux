//! A terminal agent's read-only history. The client names the harness and its exact session
//! id, never a file. Search shares the GUI's matcher and returns page coordinates. Each request
//! ends after a bounded slice so a dismissed or changed search leaves no scan running.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use super::transcript_index::Offsets;

use cmux_chat_index::AdapterKind;
use serde_json::{Value, json};

use crate::adopt_replay::{TranscriptPage, transcript_page};
use crate::adopt_tools::PastTool;
use crate::chats::search::{Needle, flatten, snippet};
use crate::chats::{ChatService, ChatSources, key_text, parse_key, terminal};
use crate::hub::Hub;
use crate::rpc::RpcError;

pub(super) use crate::rpc::method::{
    MUX_CHAT_TRANSCRIPT_FIND as FIND, MUX_CHAT_TRANSCRIPT_PAGE as PAGE,
};

pub(super) async fn handle(
    hub: &Arc<Hub>,
    service: Option<Arc<ChatService>>,
    method: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    let key = params
        .get("key")
        .and_then(Value::as_str)
        .and_then(parse_key)
        .filter(|key| {
            matches!(key.harness, AdapterKind::ClaudeCode | AdapterKind::Codex)
                && crate::adopt::is_bare_id(&key.session_id)
        })
        .ok_or_else(|| {
            RpcError::invalid_params("key must be an exact Claude Code or Codex session key")
        })?;
    let before = match params.get("before") {
        None | Some(Value::Null) => None,
        Some(value) => Some(
            value
                .as_u64()
                .ok_or_else(|| RpcError::invalid_params("before must be a byte offset"))?,
        ),
    };
    let cwd = params
        .get("cwd")
        .and_then(Value::as_str)
        .filter(|cwd| cwd.len() <= 4096)
        .map(PathBuf::from);
    let needle = if method == FIND {
        let text = params
            .get("query")
            .and_then(Value::as_str)
            .ok_or_else(|| RpcError::invalid_params("query must be a string"))?;
        Some(Needle::parse(text).map_err(RpcError::invalid_params)?)
    } else {
        None
    };
    let meta_only =
        method == PAGE && params.get("metadataOnly").and_then(Value::as_bool) == Some(true);
    let sources = match &service {
        Some(service) => service.transcript_sources().clone(),
        None => ChatSources::daemon(&*hub.config.read().await)
            .ok_or_else(|| RpcError::internal("could not locate agent stores"))?,
    };
    super::blocking(move || {
        let read_dates = meta_only || (needle.is_none() && before.is_none());
        let chat = terminal::locate(service.as_deref(), &sources, &key, cwd.as_deref(), read_dates)
            .ok_or_else(|| RpcError::not_found(format!("no transcript for {}", key_text(&key))))?;
        if meta_only {
            return Ok(json!({"key": key_text(&key), "createdMs": chat.created_ms, "updatedMs": chat.updated_ms}));
        }
        let family = if key.harness == AdapterKind::ClaudeCode { "claude" } else { "codex" };
        let mut offsets = Offsets::open(&sources.acpmux_home, &chat.path, family);
        if let Some(needle) = needle {
            return search(&chat, family, &mut offsets, before, &needle);
        }
        let page = read(&chat, family, before)?;
        if let Some(index) = &mut offsets { index.record(&page) }
        Ok(json!({
            "key": key_text(&key), "title": chat.title, "createdMs": chat.created_ms,
            "updatedMs": chat.updated_ms, "turns": turns(&page), "before": older(page.start), "pageEnd": page.end
        }))
    }).await
}

fn older(offset: u64) -> Option<u64> {
    (offset != 0).then_some(offset)
}

const TURNS: usize = 32;

fn read(
    chat: &terminal::Transcript,
    family: &str,
    before: Option<u64>,
) -> Result<TranscriptPage, RpcError> {
    let page = transcript_page(&chat.path, family, before, TURNS).map_err(|error| {
        RpcError::invalid_params(format!("could not read the transcript page: {error}"))
    })?;
    if before.is_some_and(|expected| expected != page.end) {
        return Err(RpcError::invalid_params("the transcript changed; open its latest page again"));
    }
    Ok(page)
}

pub(super) fn tool_title(tool: &PastTool) -> &str {
    tool.call.get("title").and_then(Value::as_str).unwrap_or("Tool call")
}

/// Keep command inputs and potentially enormous result bodies off the wire. The GUI expands a
/// turn's tool group into its ordered list of titles.
fn turns(page: &TranscriptPage) -> Vec<Value> {
    page.turns
        .iter()
        .map(|turn| {
            let tools: Vec<Value> =
                turn.tools.iter().map(|tool| json!({"title": tool_title(tool)})).collect();
            json!({
                "prompt": turn.prompt, "answer": turn.answer, "promptAt": turn.prompt_at,
                "answerAt": turn.answer_at, "tools": tools
            })
        })
        .collect()
}

fn search(
    chat: &terminal::Transcript,
    family: &str,
    offsets: &mut Option<Offsets>,
    mut before: Option<u64>,
    needle: &Needle,
) -> Result<Value, RpcError> {
    let started = Instant::now();
    let mut hits = Vec::new();
    // Up to one hit per role per turn. A sparse query can cover several pages per round trip;
    // the first page with any match is returned immediately, newest matching turn first.
    for _ in 0..16 {
        if let Some(index) = &mut *offsets
            && let Some(start) = index.skip(before.unwrap_or(index.end), needle)
        {
            before = older(start);
            if before.is_none() {
                break;
            }
            continue;
        }
        let page = read(chat, family, before)?;
        if let Some(index) = &mut *offsets {
            index.record(&page)
        }
        for (turn, row) in page.turns.iter().enumerate().rev() {
            let mut hit = |role: &str, text: &str| {
                let flat = flatten(text);
                if let Some(at) = needle.find(&flat) {
                    hits.push(json!({"pageEnd": page.end, "turn": turn, "role": role, "snippet": snippet(&flat, at)}));
                    true
                } else {
                    false
                }
            };
            hit("assistant", &row.answer);
            row.tools.iter().rev().any(|tool| hit("tool", tool_title(tool)));
            hit("user", &row.prompt);
        }
        before = older(page.start);
        if !hits.is_empty() || before.is_none() || started.elapsed() >= Duration::from_millis(70) {
            break;
        }
    }
    Ok(json!({"hits": hits, "before": before}))
}
