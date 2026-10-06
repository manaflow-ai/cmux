//! `history-search` (`history-search-v1`): one query over the history search
//! index, on trusted local connections only. Each hit names where it jumps
//! (a chat and its turn, a terminal and its line, a tab or a workspace).

use serde::Deserialize;
use serde_json::Value;

use crate::Mux;

/// `history-search`, advertised while the binary has installed the index.
pub const HISTORY_SEARCH_CAPABILITY: &str = "history-search-v1";

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
    let _ = (mux, client, params.query, params.kinds, params.limit);
    anyhow::bail!("history-search is not implemented")
}

#[cfg(test)]
#[path = "history_search_tests.rs"]
mod tests;
