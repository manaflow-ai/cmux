//! `conversation-tabs-v1` on the wire (plans/cmux-next/home.md section 7):
//! the raw `new-conversation-tab` command and the one outbound projection
//! that shows a conversation tab as `browser` to a connection that did not
//! negotiate the capability (raw `set-client-info` or v2
//! `client.metadata.update {capabilities}`). Storage and the journal keep the
//! canonical `conversation` kind; the projection applies to every control
//! message the connection receives (responses, `session.snapshot`,
//! `session.events`, journal replay, raw tree events).

use std::sync::Arc;
use std::sync::atomic::Ordering;

use serde::Deserialize;
use serde_json::{Value, json};

use super::{BudgetedText, MessageWriter, Mux, PaneId, paired_surface_size};
use crate::state::conversation_tabs_store::{
    CONVERSATION_KIND, CONVERSATION_TABS_CAPABILITY, ConversationTabRecord,
    conversation_tabs_present, downgrade_conversation_tabs,
};
use crate::workspace_registry::WorkspaceMutation;

/// `new-conversation-tab`: a tab showing `conversation` of the `local` or
/// `cloud` conversation owner. With `origin` and `mutation_id` a retry
/// returns the tab the first request created.
#[derive(Deserialize)]
pub(super) struct NewConversationTabParams {
    #[serde(default)]
    pane: Option<PaneId>,
    conversation: String,
    owner: String,
    #[serde(default)]
    origin: Option<String>,
    #[serde(default)]
    mutation_id: Option<String>,
    #[serde(default)]
    cols: Option<u16>,
    #[serde(default)]
    rows: Option<u16>,
}

pub(super) fn new_conversation_tab(
    mux: &Arc<Mux>,
    params: NewConversationTabParams,
) -> anyhow::Result<Value> {
    let NewConversationTabParams { pane, conversation, owner, origin, mutation_id, cols, rows } =
        params;
    let mutation = match (origin, mutation_id) {
        (Some(origin), Some(id)) => Some(WorkspaceMutation::new(id, origin)?),
        (None, None) => None,
        _ => anyhow::bail!("bad request: origin and mutation_id are sent together"),
    };
    let size = paired_surface_size("new-conversation-tab", cols, rows)?;
    let record = ConversationTabRecord { conversation, owner };
    let outcome = mux.new_conversation_tab(pane, record.clone(), mutation.as_ref(), size)?;
    let identity = outcome.surface.resource_identity();
    Ok(json!({
        "surface": outcome.surface.id,
        "tab_resource_id": identity.map(|identity| identity.tab_id.as_str()),
        "content_resource_id": identity.map(|identity| identity.content_id.as_str()),
        "conversation": record.wire(),
        "replayed": outcome.replayed,
    }))
}

/// The raw tree `kind` of a tab: `conversation` for a conversation tab.
pub(super) fn raw_tab_kind(surface_kind: &'static str, conversation: bool) -> &'static str {
    if conversation { CONVERSATION_KIND } else { surface_kind }
}

impl MessageWriter {
    /// Record the connection's capabilities: whether it reads conversation
    /// tabs in their canonical form.
    pub(super) fn negotiate_conversation_tabs<'a>(
        &self,
        mut capabilities: impl Iterator<Item = &'a String>,
    ) {
        if capabilities.any(|capability| capability == CONVERSATION_TABS_CAPABILITY) {
            self.conversation_tabs.store(true, Ordering::Release);
        }
    }

    /// The one outbound projection: a connection without
    /// `conversation-tabs-v1` reads every conversation tab as `browser`.
    pub(super) fn project_conversation_tabs(
        &self,
        text: Arc<BudgetedText>,
    ) -> std::io::Result<Arc<BudgetedText>> {
        if self.conversation_tabs.load(Ordering::Acquire)
            || !conversation_tabs_present()
            || !text.contains("\"conversation\"")
        {
            return Ok(text);
        }
        let Ok(mut value) = serde_json::from_str::<Value>(&text) else { return Ok(text) };
        if !downgrade_conversation_tabs(&mut value) {
            return Ok(text);
        }
        self.render_service.serialize_control(&value)
    }
}

/// v2 `client.metadata.update {capabilities}`: the same additive set as raw
/// `set-client-info`, for the requesting connection only.
pub(super) fn set_resource_capabilities(
    mux: &Mux,
    requesting_client: u64,
    target: u64,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<(), crate::resource::ResourceError> {
    let Some(capabilities) = request.fields.get("capabilities") else { return Ok(()) };
    if target != requesting_client {
        return Err(crate::resource::ResourceError::validation_invalid(
            Some("capabilities"),
            "a connection declares only its own capabilities",
        ));
    }
    let capabilities: Vec<String> = serde_json::from_value(capabilities.clone()).map_err(|_| {
        crate::resource::ResourceError::validation_invalid(Some("capabilities"), "must be strings")
    })?;
    mux.control_clients.set_info(target, None, None, Some(capabilities)).map(|_| ()).map_err(
        |error| crate::resource::ResourceError::validation_invalid(None, error.to_string()),
    )
}

#[cfg(test)]
#[path = "conversation_tabs_tests.rs"]
mod tests;
