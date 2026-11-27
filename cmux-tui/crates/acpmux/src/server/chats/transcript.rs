//! A terminal agent's read-only history. The client names the harness and its exact session
//! id, never a file. Search shares the GUI's matcher and returns page coordinates. Each request
//! ends after a bounded slice so a dismissed or changed search leaves no scan running.

use std::fs::File;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use super::transcript_index::Offsets;
use super::transcript_preview::{self, tool_title};
use super::transcript_raw;

use cmux_chat_index::AdapterKind;
use serde_json::{Value, json};

use crate::adopt_replay::{TranscriptPage, transcript_page_from};
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
    let query = if method == FIND {
        let text = params
            .get("query")
            .and_then(Value::as_str)
            .ok_or_else(|| RpcError::invalid_params("query must be a string"))?;
        Some((Needle::parse(text).map_err(RpcError::invalid_params)?, text.trim().to_owned()))
    } else {
        None
    };
    let meta_only =
        method == PAGE && params.get("metadataOnly").and_then(Value::as_bool) == Some(true);
    let chunk = transcript_preview::TextChunk::parse(
        params,
        method == PAGE && !meta_only && before.is_some(),
    )?;
    let raw = transcript_raw::Request::parse(
        params,
        method == PAGE && !meta_only && before.is_some() && chunk.is_none(),
    )?;
    let supplied_witness = params.get("completeThrough").cloned();
    let sources = match &service {
        Some(service) => service.transcript_sources().clone(),
        None => ChatSources::daemon(&*hub.config.read().await)
            .ok_or_else(|| RpcError::internal("could not locate agent stores"))?,
    };
    super::blocking(move || {
        let read_dates = meta_only || (query.is_none() && before.is_none());
        let mut chat = terminal::locate(service.as_deref(), &sources, &key, cwd.as_deref(), read_dates)
            .ok_or_else(|| RpcError::not_found(format!("no transcript for {}", key_text(&key))))?;
        if meta_only {
            return Ok(json!({"key": key_text(&key), "createdMs": chat.created_ms, "updatedMs": chat.updated_ms}));
        }
        let family = if key.harness == AdapterKind::ClaudeCode { "claude" } else { "codex" };
        let mut offsets = Offsets::open(&sources.acpmux_home, &chat.path, family, &chat.metadata);
        let size = chat.metadata.len();
        let end = before.unwrap_or(size);
        let mut through = transcript_raw::witness(&mut chat.file, size, supplied_witness.as_ref())?;
        if let Some((needle, literal)) = query {
            return search(&mut chat.file, family, &mut offsets, end, size, through, (&needle, &literal));
        }
        if let Some(raw) = &raw
            && offsets.as_mut().is_some_and(|cache| cache.contains_part(end, raw.start, raw.end))
        {
            return raw.read(&mut chat.file, size);
        }
        let page = read(&mut chat.file, family, end)?;
        let parts = transcript_raw::parts(&mut chat.file, &page, size, &mut through)?;
        if let Some(index) = &mut offsets { index.record(&page, &parts); }
        if let Some(raw) = raw {
            if !parts.iter().any(|part| part.start == raw.start && part.end == raw.end) {
                return Err(RpcError::invalid_params("raw range is not part of this page"));
            }
            return raw.read(&mut chat.file, size);
        }
        if let Some(chunk) = chunk { return chunk.reply(&page); }
        Ok(json!({
            "key": key_text(&key), "title": chat.title.as_deref().map(transcript_preview::title), "createdMs": chat.created_ms,
            "updatedMs": chat.updated_ms, "turns": transcript_preview::turns(&page), "before": older(page.start), "pageEnd": page.end,
            "completeThrough":through,"rawRanges":parts
        }))
    }).await
}

fn older(offset: u64) -> Option<u64> {
    (offset != 0).then_some(offset)
}

const TURNS: usize = 32;

fn read(file: &mut File, family: &str, end: u64) -> Result<TranscriptPage, RpcError> {
    transcript_page_from(file, family, Some(end), TURNS).map_err(|error| {
        RpcError::invalid_params(format!("could not read the transcript page: {error}"))
    })
}

fn search(
    file: &mut File,
    family: &str,
    offsets: &mut Option<Offsets>,
    end: u64,
    size: u64,
    mut through: Option<u64>,
    (needle, literal): (&Needle, &str),
) -> Result<Value, RpcError> {
    let started = Instant::now();
    let mut hits = Vec::new();
    let mut before = Some(end);
    // Up to one hit per role per turn. A sparse query can cover several pages per round trip;
    // the first page with any match is returned immediately, newest matching turn first.
    for _ in 0..16 {
        let Some(end) = before else { break };
        if let Some(index) = &mut *offsets
            && let Some(start) = index.skip(end, needle)
        {
            // Only complete, ordinary pages enter the offset table.
            through = through.max(Some(end));
            before = older(start);
            if before.is_none() {
                break;
            }
            continue;
        }
        let page = read(file, family, end)?;
        let parts = transcript_raw::parts(file, &page, size, &mut through)?;
        if let Some(index) = &mut *offsets {
            index.record(&page, &parts)
        }
        for (turn, row) in page.turns.iter().enumerate().rev() {
            let mut hit = |role: &str, text: &str| {
                if !needle.may_match(text) {
                    return false;
                }
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
        for part in parts.iter().rev() {
            if let Some(hit) =
                transcript_raw::find(file, part, literal, through.unwrap_or(0), page.end)?
            {
                hits.push(hit);
            }
        }
        before = older(page.start);
        if !hits.is_empty() || before.is_none() || started.elapsed() >= Duration::from_millis(70) {
            break;
        }
    }
    Ok(json!({"hits": hits, "before": before, "completeThrough": through}))
}
