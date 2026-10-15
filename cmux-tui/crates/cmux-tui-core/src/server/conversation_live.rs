//! Raw protocol handlers for a Chief's live run frames on the local
//! conversation owner (`chief-live-v1`, conversation_live.rs): the run's
//! agent publishes `step.delta` and `run.activity` frames while its run is
//! running, every trusted local connection reads the text so far
//! (`conversation-live`, a `run.live` snapshot), and `subscribe` sends each
//! frame to the connections that asked for live frames.

use serde::Deserialize;
use serde_json::{Value, json};

use super::Mux;
use super::conversations::decode;
use crate::conversation_live::LiveFrame;

pub(super) use crate::conversation_live::CHIEF_LIVE_CAPABILITY;

/// `conversation-live-publish`: one frame of the bound agent's own running run.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct PublishParams {
    conversation: String,
    frame: Value,
}

/// `conversation-live`: the `run.live` snapshot of a conversation (the same
/// answer as the Cloud owner's `run.live.get`).
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct LiveParams {
    conversation: String,
}

fn require_local(mux: &Mux, client: u64) -> anyhow::Result<()> {
    anyhow::ensure!(
        mux.control_clients.is_owner_client(client) && !mux.is_remote_client(client),
        "live runs require a trusted local connection"
    );
    Ok(())
}

pub(super) fn publish(mux: &Mux, client: u64, params: PublishParams) -> anyhow::Result<Value> {
    require_local(mux, client)?;
    let PublishParams { conversation, frame } = params;
    let frame: LiveFrame = decode(frame, "frame")?;
    frame.validate(&conversation)?;
    let actor = mux.conversation_principal(client);
    mux.conversation_live_publish(&conversation, &actor, &frame)?;
    Ok(json!({}))
}

pub(super) fn live(mux: &Mux, client: u64, params: LiveParams) -> anyhow::Result<Value> {
    require_local(mux, client)?;
    mux.conversation_live(&params.conversation)
}
