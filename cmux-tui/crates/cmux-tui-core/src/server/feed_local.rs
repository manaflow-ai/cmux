//! Raw protocol handlers of the daemon's local feed owner
//! (`feed-local-owner-v1`, plans/cmux-next/feed.md section 9.1): list items
//! by state, read items, and the handoff steps the app drives (B3): begin,
//! then done after `feed.adopt` (or `feed.adopt.cancel` answered `cancelled:
//! false`), or abort after `feed.adopt.cancel` answered `cancelled: true`.

use cmux_feed_core::{ItemState, ListFilter};
use serde::Deserialize;
use serde_json::{Value, json};

use super::{Command, Mux};
use crate::Actor;

/// Run one `feed-local-*` command. The handoff steps change which owner
/// holds an item, and only the app holds the cloud credential that moves
/// it, so they need the verified cmux app (the `frontend` actor, B8): an
/// agent or script on the same socket cannot freeze items.
pub(super) fn dispatch(mux: &Mux, actor: &Actor, cmd: Command) -> anyhow::Result<Value> {
    let handoff = matches!(
        cmd,
        Command::FeedLocalHandoffBegin(_)
            | Command::FeedLocalHandoffAbort(_)
            | Command::FeedLocalHandoffDone(_)
    );
    if handoff && !matches!(actor, Actor::Frontend { .. }) {
        return Err(cmux_feed_core::FeedError::Forbidden(
            "feed handoff requires the verified cmux app connection".into(),
        )
        .into());
    }
    match cmd {
        Command::FeedLocalList(params) => list(mux, params),
        Command::FeedLocalRead(params) => read(mux, params),
        Command::FeedLocalHandoffBegin(params) => {
            Ok(json!({"item": mux.feed_local_handoff_begin(&params.item)?}))
        }
        Command::FeedLocalHandoffAbort(params) => {
            Ok(json!({"item": mux.feed_local_handoff_abort(&params.item)?}))
        }
        Command::FeedLocalHandoffDone(params) => {
            Ok(json!({"item": mux.feed_local_handoff_done(&params.item, &params.home)?}))
        }
        _ => anyhow::bail!("not a feed-local command"),
    }
}

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

/// `feed-local-handoff-begin` and `feed-local-handoff-abort`.
#[derive(Deserialize)]
pub(super) struct ItemParams {
    item: String,
}

/// `feed-local-handoff-done`.
#[derive(Deserialize)]
pub(super) struct DoneParams {
    item: String,
    home: String,
}

fn list(mux: &Mux, params: ListParams) -> anyhow::Result<Value> {
    let state = params
        .state
        .as_deref()
        .map(|state| ItemState::parse(state).ok_or_else(|| anyhow::anyhow!("bad state {state}")))
        .transpose()?;
    let filter = ListFilter { state, terminal: params.terminal_id, unread_only: params.unread };
    Ok(json!({"items": mux.feed_local_list(&filter)}))
}

fn read(mux: &Mux, params: ReadParams) -> anyhow::Result<Value> {
    anyhow::ensure!(params.items.len() <= 500, "at most 500 items per read");
    Ok(json!({"items": mux.feed_local_read(&params.items)?}))
}
