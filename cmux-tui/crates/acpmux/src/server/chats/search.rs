//! `_acpmux/chats_search {query, harness?, folder?, account?, limit?, cursor?, budgetMs?}`
//! (HQ#5333): the chats whose prompts or answers hold every word of `query`, newest chat first,
//! each with its newest such message: `{ready, enabled, hits: [{chat, turn, role, snippet,
//! matches}], scanned, unreadable, partial, nextCursor}`. `chat` is the `_acpmux/chats` value;
//! `turn` indexes `_acpmux/chat_transcript`'s `turns` (the newest 200 of a chat are searched);
//! `role` is `prompt` or `answer`.
//!
//! Each chat's turns are read now from its harness's store, never kept or indexed. The scan stops
//! at `limit` hits (default 50, at most 200) or after `budgetMs` (default 2000, 50 to 10000), so
//! one search never runs unbounded on a large history. The budget is checked between chats, and
//! one chat's read is itself bounded (the newest 64 MiB of a JSONL store, 8 MiB of a JSON one, the
//! newest 2000 rows of a SQLite one), so a search ends at most one chat's read past it: `partial`
//! says the time ran out, and
//! `nextCursor` (null when every chat was read) goes on from the last chat read. A chat whose
//! store cannot be read (gone, not readable, too large, not JSON) is skipped and counted in
//! `unreadable`; a Claude Code or Codex transcript is read as `_acpmux/chat_transcript` reads it,
//! where a line that does not parse is left out and an error mid-file ends the read with the
//! turns before it.
//!
//! What was said is user data (C5): like the rest of `_acpmux/chat*`, only the local unix socket
//! gets it (`chats.rs` refuses every other origin before this runs).

use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::chats::search::{Needle, find};
use crate::chats::{ChatCursor, ChatQuery, ChatService, chat_value};
use crate::hub::Hub;
use crate::rpc::RpcError;

const DEFAULT_LIMIT: usize = 50;
const MAX_LIMIT: usize = 200;
const DEFAULT_BUDGET_MS: u64 = 2_000;
const BUDGET_MS: std::ops::RangeInclusive<u64> = 50..=10_000;

pub(super) async fn handle(
    hub: &Arc<Hub>,
    service: Option<Arc<ChatService>>,
    params: &Value,
) -> Result<Value, RpcError> {
    let query = params
        .get("query")
        .and_then(Value::as_str)
        .ok_or_else(|| RpcError::invalid_params("query must be a string"))?;
    let needle = Needle::parse(query).map_err(RpcError::invalid_params)?;
    let mut filter = ChatQuery::from_params(params).map_err(RpcError::invalid_params)?;
    // The words are searched in the turns, not the filter's title and folder text.
    filter.text = None;
    let limit = match params.get("limit") {
        None | Some(Value::Null) => DEFAULT_LIMIT,
        Some(_) => filter.limit.min(MAX_LIMIT),
    };
    let budget = match params.get("budgetMs") {
        None | Some(Value::Null) => DEFAULT_BUDGET_MS,
        Some(v) => v
            .as_u64()
            .ok_or_else(|| RpcError::invalid_params("budgetMs must be a positive number"))?
            .clamp(*BUDGET_MS.start(), *BUDGET_MS.end()),
    };
    let Some(service) = service else {
        return Ok(json!({"ready": false, "hits": [], "nextCursor": null}));
    };
    let activity = hub.chat_activity();
    let (started, budget) = (Instant::now(), Duration::from_millis(budget));
    super::blocking(move || {
        let Some(chats) = service.listed_from(&filter) else {
            return Ok(json!({"ready": true, "enabled": false, "hits": [], "nextCursor": null}));
        };
        let mut hits = Vec::new();
        let (mut scanned, mut unreadable, mut partial) = (0_usize, 0_usize, false);
        for chat in &chats {
            if hits.len() >= limit {
                break;
            }
            if scanned > 0 && started.elapsed() >= budget {
                partial = true;
                break;
            }
            scanned = scanned.saturating_add(1);
            let Ok(turns) = super::transcript_turns(&chat.entry) else {
                unreadable = unreadable.saturating_add(1);
                continue;
            };
            if let Some(hit) = find(&needle, &turns) {
                let mut value = chat_value(chat);
                activity.decorate(&mut value);
                hits.push(hit.to_value(value));
            }
        }
        let next = (scanned < chats.len())
            .then(|| scanned.checked_sub(1).and_then(|last| chats.get(last)))
            .flatten()
            .map(|last| ChatCursor::after(last).to_text());
        Ok(json!({
            "ready": true,
            "enabled": true,
            "hits": hits,
            "scanned": scanned,
            "unreadable": unreadable,
            "partial": partial,
            "nextCursor": next,
        }))
    })
    .await
}
