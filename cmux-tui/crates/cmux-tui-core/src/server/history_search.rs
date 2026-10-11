//! `history-search` (`history-search-v1`): one query over the history search
//! index, on trusted local connections only. Each hit names where it jumps
//! (a chat and its turn, a terminal and its line, a tab or a workspace).

use std::time::Instant;

use cmux_history::{SearchHit, SearchKind};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::Mux;

/// `history-search`, advertised while the binary has installed the index.
pub const HISTORY_SEARCH_CAPABILITY: &str = "history-search-v1";

const DEFAULT_LIMIT: u32 = 20;
const MAX_LIMIT: u32 = 100;
const MAX_QUERY_CHARS: usize = 200;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct HistorySearchParams {
    query: String,
    /// `chat`, `command`, `scrollback`, `tab`, `workspace`; absent or empty:
    /// every kind.
    #[serde(default)]
    kinds: Vec<String>,
    /// 1-100, default 20.
    #[serde(default)]
    limit: Option<u32>,
}

pub(super) fn search(mux: &Mux, client: u64, params: HistorySearchParams) -> anyhow::Result<Value> {
    anyhow::ensure!(
        mux.control_clients.is_unix(client),
        "history search requires a trusted local connection"
    );
    let Some(index) = mux.history_search() else {
        anyhow::bail!("history search is unavailable");
    };
    let query = params.query.trim();
    anyhow::ensure!(
        (1..=MAX_QUERY_CHARS).contains(&query.chars().count())
            && !query.chars().any(char::is_control),
        "bad request: query must be 1-{MAX_QUERY_CHARS} characters with no control characters"
    );
    let limit = params.limit.unwrap_or(DEFAULT_LIMIT);
    anyhow::ensure!((1..=MAX_LIMIT).contains(&limit), "bad request: limit must be 1-{MAX_LIMIT}");
    let kinds: Vec<SearchKind> =
        params.kinds.iter().map(|kind| parse_kind(kind)).collect::<anyhow::Result<_>>()?;
    let started = Instant::now();
    let hits = index.search(query, &kinds, limit as usize)?;
    let took_us = u64::try_from(started.elapsed().as_micros()).unwrap_or(u64::MAX);
    Ok(json!({"hits": hits.iter().map(hit_json).collect::<Vec<_>>(), "took_us": took_us}))
}

fn parse_kind(kind: &str) -> anyhow::Result<SearchKind> {
    SearchKind::parse(kind).ok_or_else(|| anyhow::anyhow!("bad request: unknown kind {kind:?}"))
}

/// One hit on the wire. `highlights` are UTF-16 offset ranges into
/// `snippet`, as the app's and the TypeScript SDK's strings index.
fn hit_json(hit: &SearchHit) -> Value {
    let utf16 = |byte: usize| hit.snippet[..byte].encode_utf16().count();
    let highlights: Vec<Value> = hit
        .highlights
        .iter()
        .map(|range| json!({"start": utf16(range.start), "end": utf16(range.end)}))
        .collect();
    json!({
        "key": hit.key,
        "kind": hit.kind.as_str(),
        "target": hit.target,
        "position": hit.position,
        "title": hit.title,
        "snippet": hit.snippet,
        "highlights": highlights,
        "at_ms": hit.at_ms,
    })
}
