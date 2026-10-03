//! Raw protocol handlers of the daemon's local feed owner
//! (`feed-local-owner-v1`, plans/cmux-next/feed.md section 9.1): list items
//! by state, read items, and the two handoff steps the app drives (B3).

use cmux_feed_core::{ItemState, ListFilter};
use serde::Deserialize;
use serde_json::{Value, json};

use super::Mux;

/// `feed-local-list`. With `state: "handing_off"` the app rebuilds its
/// handoff queue at launch (B3).
#[derive(Deserialize)]
pub(super) struct ListParams {
    #[serde(default)]
    state: Option<String>,
    #[serde(default)]
    terminal_id: Option<String>,
    #[serde(default)]
    unread: bool,
}

/// `feed-local-read`.
#[derive(Deserialize)]
pub(super) struct ReadParams {
    items: Vec<String>,
}

/// `feed-local-handoff-begin`.
#[derive(Deserialize)]
pub(super) struct BeginParams {
    item: String,
}

/// `feed-local-handoff-done`.
#[derive(Deserialize)]
pub(super) struct DoneParams {
    item: String,
    home: String,
}

pub(super) fn list(mux: &Mux, params: ListParams) -> anyhow::Result<Value> {
    let state = params
        .state
        .as_deref()
        .map(|state| ItemState::parse(state).ok_or_else(|| anyhow::anyhow!("bad state {state}")))
        .transpose()?;
    let filter = ListFilter { state, terminal: params.terminal_id, unread_only: params.unread };
    Ok(json!({"items": mux.feed_local_list(&filter)}))
}

pub(super) fn read(mux: &Mux, params: ReadParams) -> anyhow::Result<Value> {
    anyhow::ensure!(params.items.len() <= 500, "at most 500 items per read");
    Ok(json!({"items": mux.feed_local_read(&params.items)?}))
}

pub(super) fn handoff_begin(mux: &Mux, params: BeginParams) -> anyhow::Result<Value> {
    Ok(json!({"item": mux.feed_local_handoff_begin(&params.item)?}))
}

pub(super) fn handoff_done(mux: &Mux, params: DoneParams) -> anyhow::Result<Value> {
    Ok(json!({"item": mux.feed_local_handoff_done(&params.item, &params.home)?}))
}

#[cfg(test)]
#[path = "feed_local_tests.rs"]
mod tests;
