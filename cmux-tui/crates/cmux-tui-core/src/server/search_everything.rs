//! `search-query`, `search-opened` and `search-stats` (`search-v1`): the
//! search-everything index (plans/cmux-next/search-everything-DESIGN.md),
//! on trusted local connections only. One ranked list of names and
//! content; each hit names where it jumps.

use std::sync::Arc;
use std::time::Duration;

use cmux_search::{Hit, Query, Scope};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::Mux;

/// Always advertised: the index starts on first use.
pub const SEARCH_CAPABILITY: &str = "search-v1";

const DEFAULT_LIMIT: u32 = 50;
const MAX_LIMIT: u32 = 200;
/// First results within a keystroke's frame (design: under 16 ms).
const DEFAULT_BUDGET_MS: u32 = 10;
const MAX_BUDGET_MS: u32 = 5_000;
const MAX_QUERY_CHARS: usize = 200;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct SearchQueryParams {
    query: String,
    /// `chat`, `chief`, `terminal`, `file`, `workspace`, `page`; absent or
    /// empty: everything.
    #[serde(default)]
    scopes: Vec<String>,
    /// 1-200, default 50.
    #[serde(default)]
    limit: Option<u32>,
    /// Content scan time budget, 1-5000 ms, default 10.
    #[serde(default)]
    budget_ms: Option<u32>,
    /// The caller's workspace (`ws_...`), whose hits rank higher; absent:
    /// the daemon's focused workspace.
    #[serde(default)]
    workspace: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct SearchOpenedParams {
    target: String,
}

fn ensure_local(mux: &Mux, client: u64) -> anyhow::Result<()> {
    anyhow::ensure!(
        mux.control_clients.is_unix(client),
        "search requires a trusted local connection"
    );
    Ok(())
}

pub(super) fn query(
    mux: &Arc<Mux>,
    client: u64,
    params: SearchQueryParams,
) -> anyhow::Result<Value> {
    ensure_local(mux, client)?;
    let text = params.query.trim();
    anyhow::ensure!(
        (1..=MAX_QUERY_CHARS).contains(&text.chars().count())
            && !text.chars().any(char::is_control),
        "bad request: query must be 1-{MAX_QUERY_CHARS} characters with no control characters"
    );
    let limit = params.limit.unwrap_or(DEFAULT_LIMIT);
    anyhow::ensure!((1..=MAX_LIMIT).contains(&limit), "bad request: limit must be 1-{MAX_LIMIT}");
    let budget = params.budget_ms.unwrap_or(DEFAULT_BUDGET_MS);
    anyhow::ensure!(
        (1..=MAX_BUDGET_MS).contains(&budget),
        "bad request: budget_ms must be 1-{MAX_BUDGET_MS}"
    );
    let scopes = params
        .scopes
        .iter()
        .map(|scope| {
            Scope::parse(scope)
                .ok_or_else(|| anyhow::anyhow!("bad request: unknown scope {scope:?}"))
        })
        .collect::<anyhow::Result<Vec<Scope>>>()?;
    let mut query = Query::new(text, crate::history_ops::now_ms());
    query.kinds = Scope::kinds_of(&scopes);
    query.limit = limit as usize;
    query.budget = Some(Duration::from_millis(u64::from(budget)));
    if let Some(workspace) = params.workspace {
        anyhow::ensure!(
            (1..=128).contains(&workspace.len()) && !workspace.chars().any(char::is_control),
            "bad request: workspace must be 1-128 bytes with no control characters"
        );
        query.workspace_id = Some(workspace);
    }
    let result = mux.search_everything(&query);
    let took_us = u64::try_from(result.took.as_micros()).unwrap_or(u64::MAX);
    Ok(json!({
        "hits": result.hits.iter().map(hit_json).collect::<Vec<_>>(),
        "partial": result.partial,
        "took_us": took_us,
    }))
}

pub(super) fn opened(
    mux: &Arc<Mux>,
    client: u64,
    params: SearchOpenedParams,
) -> anyhow::Result<Value> {
    ensure_local(mux, client)?;
    let target = params.target.trim();
    anyhow::ensure!(
        (1..=512).contains(&target.len()) && !target.chars().any(char::is_control),
        "bad request: target must be 1-512 bytes with no control characters"
    );
    mux.search_everything_opened(target);
    Ok(json!({}))
}

pub(super) fn stats(mux: &Arc<Mux>, client: u64) -> anyhow::Result<Value> {
    ensure_local(mux, client)?;
    let stats = mux.search_everything_stats();
    Ok(json!({
        "docs": stats.stats.docs,
        "blocks": stats.stats.blocks,
        "segments": stats.stats.segments,
        "text_bytes": stats.stats.text_bytes,
        "index_bytes": stats.stats.index_bytes,
        "resident_bytes": stats.stats.resident_bytes,
        "names": stats.stats.names,
        "contexts": stats.stats.contexts,
        "read_errors": stats.stats.read_errors,
        "dropped": stats.dropped,
    }))
}

/// One hit on the wire. `highlights` are UTF-16 offset ranges into
/// `snippet`, as the app's and the TypeScript SDK's strings index.
pub(crate) fn hit_json(hit: &Hit) -> Value {
    let utf16 =
        |byte: usize| hit.snippet.get(..byte).map_or(0, |prefix| prefix.encode_utf16().count());
    let highlights: Vec<Value> = hit
        .highlights
        .iter()
        .map(|range| json!({"start": utf16(range.start), "end": utf16(range.end)}))
        .collect();
    json!({
        "kind": hit.kind.as_str(),
        "source": hit.source,
        "target": hit.target,
        "position": hit.position,
        "line": hit.line,
        "title": hit.title,
        "subtitle": hit.subtitle,
        "snippet": hit.snippet,
        "highlights": highlights,
        "at_ms": hit.at_ms,
        "tier": hit.tier,
        "score": hit.score,
        "is_name": hit.is_name,
    })
}
