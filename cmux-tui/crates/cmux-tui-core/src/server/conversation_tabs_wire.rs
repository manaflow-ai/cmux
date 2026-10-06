//! `conversation-tabs-v1` on the wire (plans/cmux-next/home.md section 7):
//! the raw `new-conversation-tab` command and the one outbound projection
//! that shows a conversation tab as `browser` to a connection that did not
//! negotiate the capability (raw `set-client-info` or v2
//! `client.metadata.update {capabilities}`). Storage and the journal keep the
//! canonical `conversation` kind; the projection applies to every control
//! message the connection receives (responses, `session.snapshot`,
//! `session.events`, journal replay, raw tree events). Control messages pass
//! through `project_conversation_tabs`; resource stream items through
//! `project_conversation_tab_item`.
//!
//! `agent-session-tabs-v1` adds the agent session source and
//! `bind-conversation-tab-session`. A connection with `conversation-tabs-v1`
//! but without it reads an agent session tab as `browser` with no record,
//! because its decoders require a conversation source.
//!
//! `page-tabs-v1` adds the page source (one of the app's own pages); a
//! connection without it reads a page tab as `browser` with no record.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use serde::Deserialize;
use serde_json::{Value, json};

use super::{
    BudgetedText, MessageWriter, Mux, PaneId, SurfaceId, WorkspaceId, paired_surface_size,
};
use crate::state::conversation_tabs::ConversationTabTarget;
use crate::state::conversation_tabs_store::{
    AGENT_SESSION_TABS_CAPABILITY, CONVERSATION_KIND, CONVERSATION_TABS_CAPABILITY,
    ConversationTabDowngrade, ConversationTabRecord, PAGE_TABS_CAPABILITY,
    conversation_tabs_present, downgrade_conversation_tabs,
};
use crate::workspace_registry::WorkspaceMutation;

/// `new-conversation-tab`: a tab showing `conversation` of the `local` or
/// `cloud` conversation owner, an acpmux `agent_session`
/// (`agent-session-tabs-v1`), or one of the app's own pages, by `page` id
/// (`page-tabs-v1`). With `origin` and
/// `mutation_id` a retry returns the tab the first request created. With
/// `transaction` (`conversation-tab-transaction-v1`) the raw `tab-added`
/// delta of the new tab and the result carry it; a replay echoes it in the
/// result only.
#[derive(Deserialize)]
pub(super) struct NewConversationTabParams {
    #[serde(default)]
    pane: Option<PaneId>,
    /// A workspace to put the tab in (its first pane when it is empty).
    #[serde(default)]
    workspace: Option<WorkspaceId>,
    #[serde(default)]
    conversation: Option<String>,
    #[serde(default)]
    owner: Option<String>,
    #[serde(default)]
    agent_session: Option<AgentSessionParams>,
    #[serde(default)]
    page: Option<String>,
    #[serde(default)]
    origin: Option<String>,
    #[serde(default)]
    mutation_id: Option<String>,
    #[serde(default)]
    cols: Option<u16>,
    #[serde(default)]
    rows: Option<u16>,
    #[serde(default)]
    transaction: Option<String>,
}

/// The client transaction echo on `new-conversation-tab`.
pub(crate) const CONVERSATION_TAB_TRANSACTION_CAPABILITY: &str = "conversation-tab-transaction-v1";

/// The acpmux session an agent tab shows: the install that runs it, the
/// session (absent for a new chat), the agent kind and the display name of
/// the host machine.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct AgentSessionParams {
    host: String,
    #[serde(default)]
    session: Option<String>,
    #[serde(default)]
    harness: Option<String>,
    #[serde(default)]
    host_name: Option<String>,
}

fn record_of(
    conversation: Option<String>,
    owner: Option<String>,
    agent_session: Option<AgentSessionParams>,
    page: Option<String>,
) -> anyhow::Result<ConversationTabRecord> {
    match (conversation, owner, agent_session, page) {
        (Some(conversation), Some(owner), None, None) => {
            Ok(ConversationTabRecord::Conversation { conversation, owner })
        }
        (None, None, Some(AgentSessionParams { host, session, harness, host_name }), None) => {
            Ok(ConversationTabRecord::AgentSession { host, session, harness, host_name })
        }
        (None, None, None, Some(page)) => Ok(ConversationTabRecord::Page { page }),
        _ => anyhow::bail!(
            "bad request: send conversation and owner, agent_session, or page: exactly one source"
        ),
    }
}

pub(super) fn create(mux: &Arc<Mux>, params: NewConversationTabParams) -> anyhow::Result<Value> {
    let NewConversationTabParams {
        pane,
        workspace,
        conversation,
        owner,
        agent_session,
        page,
        origin,
        mutation_id,
        cols,
        rows,
        transaction,
    } = params;
    super::validate_client_transaction(transaction.as_deref())?;
    let target = match (pane, workspace) {
        (_, None) => ConversationTabTarget::Pane(pane),
        (None, Some(workspace)) => ConversationTabTarget::Workspace(workspace),
        (Some(_), Some(_)) => anyhow::bail!("bad request: send pane or workspace, not both"),
    };
    let mutation = match (origin, mutation_id) {
        (Some(origin), Some(id)) => Some(WorkspaceMutation::new(id, origin)?),
        (None, None) => None,
        _ => anyhow::bail!("bad request: origin and mutation_id are sent together"),
    };
    let size = paired_surface_size("new-conversation-tab", cols, rows)?;
    let record = record_of(conversation, owner, agent_session, page)?;
    let outcome = mux.new_conversation_tab(target, record.clone(), mutation.as_ref(), size)?;
    let identity = outcome.surface.resource_identity();
    // A replay returns the tab's current record (a bound session included).
    let record = mux.conversation_tab_of(&outcome.surface).unwrap_or(record);
    if let Some(transaction) = transaction.as_deref()
        && !outcome.replayed
    {
        mux.emit_tab_added_for_transaction(outcome.surface.id, Arc::from(transaction));
    }
    let mut result = json!({
        "surface": outcome.surface.id,
        "tab_resource_id": identity.map(|identity| identity.tab_id.as_str()),
        "content_resource_id": identity.map(|identity| identity.content_id.as_str()),
        "conversation": record.wire(),
        "replayed": outcome.replayed,
    });
    if let Some(transaction) = transaction {
        result["transaction"] = json!(transaction);
    }
    Ok(result)
}

/// `bind-conversation-tab-session`: set an agent tab's session to `session`
/// when its current session is `expected_session` (null: unbound).
#[derive(Deserialize)]
pub(super) struct BindSessionParams {
    surface: SurfaceId,
    session: String,
    /// Required; JSON null names an unbound tab.
    #[serde(deserialize_with = "required_nullable")]
    expected_session: Option<String>,
}

/// A field that must be present and may be null (serde treats a missing
/// `Option` field as null unless the field has its own deserializer).
fn required_nullable<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Option<String>, D::Error> {
    Option::deserialize(deserializer)
}

pub(super) fn bind(mux: &Arc<Mux>, params: BindSessionParams) -> anyhow::Result<Value> {
    let BindSessionParams { surface, session, expected_session } = params;
    let (record, replayed) =
        mux.bind_conversation_tab_session(surface, &session, expected_session.as_deref())?;
    Ok(json!({"surface": surface, "conversation": record.wire(), "replayed": replayed}))
}

/// The raw tree `kind` of a tab: `conversation` for a conversation tab.
pub(super) fn raw_tab_kind(surface_kind: &'static str, conversation: bool) -> &'static str {
    if conversation { CONVERSATION_KIND } else { surface_kind }
}

/// The conversation tab capabilities one connection negotiated.
#[derive(Default)]
pub(super) struct NegotiatedTabs {
    conversation: AtomicBool,
    agent_sessions: AtomicBool,
    pages: AtomicBool,
}

impl NegotiatedTabs {
    /// What the connection must not read in canonical form, if anything.
    fn downgrade(&self) -> Option<ConversationTabDowngrade> {
        if !self.conversation.load(Ordering::Acquire) {
            return Some(ConversationTabDowngrade::All);
        }
        match (self.agent_sessions.load(Ordering::Acquire), self.pages.load(Ordering::Acquire)) {
            (true, true) => None,
            (false, true) => Some(ConversationTabDowngrade::AgentSessions),
            (true, false) => Some(ConversationTabDowngrade::Pages),
            (false, false) => Some(ConversationTabDowngrade::AgentSessionsAndPages),
        }
    }

    #[cfg(test)]
    pub(super) fn conversation(&self) -> bool {
        self.conversation.load(Ordering::Acquire)
    }
}

/// The conversation tab capabilities a client may declare.
pub(super) fn negotiable(capability: &str) -> bool {
    capability == CONVERSATION_TABS_CAPABILITY
        || capability == AGENT_SESSION_TABS_CAPABILITY
        || capability == PAGE_TABS_CAPABILITY
}

impl MessageWriter {
    /// Record the connection's capabilities: whether it reads conversation
    /// tabs, agent session tabs and page tabs in their canonical form.
    pub(super) fn negotiate_conversation_tabs<'a>(
        &self,
        capabilities: impl Iterator<Item = &'a String>,
    ) {
        for capability in capabilities {
            if capability == CONVERSATION_TABS_CAPABILITY {
                self.conversation_tabs.conversation.store(true, Ordering::Release);
            } else if capability == AGENT_SESSION_TABS_CAPABILITY {
                self.conversation_tabs.agent_sessions.store(true, Ordering::Release);
            } else if capability == PAGE_TABS_CAPABILITY {
                self.conversation_tabs.pages.store(true, Ordering::Release);
            }
        }
    }

    /// The one outbound projection: a connection without
    /// `conversation-tabs-v1` reads every conversation tab as `browser`, one
    /// without `agent-session-tabs-v1` every agent session tab, one without
    /// `page-tabs-v1` every page tab.
    pub(super) fn project_conversation_tabs(
        &self,
        text: Arc<BudgetedText>,
    ) -> std::io::Result<Arc<BudgetedText>> {
        let Some(downgrade) = self.conversation_tabs.downgrade() else { return Ok(text) };
        if !conversation_tabs_present() || !text.contains("\"conversation\"") {
            return Ok(text);
        }
        let Ok(mut value) = serde_json::from_str::<Value>(&text) else { return Ok(text) };
        if !downgrade_conversation_tabs(&mut value, downgrade) {
            return Ok(text);
        }
        self.render_service.serialize_control(&value)
    }

    /// The same projection on a stream item before it is serialized
    /// (`session.events` snapshot and delta items, journal records): stream
    /// items do not pass through `send_control`.
    pub(super) fn project_conversation_tab_item(&self, mut item: Value) -> Value {
        if let Some(downgrade) = self.conversation_tabs.downgrade()
            && conversation_tabs_present()
        {
            downgrade_conversation_tabs(&mut item, downgrade);
        }
        item
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

#[cfg(test)]
#[path = "agent_session_tabs_tests.rs"]
mod agent_session_tests;

#[cfg(test)]
#[path = "agent_session_tabs_wire_tests.rs"]
mod agent_session_wire_tests;

#[cfg(test)]
#[path = "agent_session_bind_tests.rs"]
mod agent_session_bind_tests;

#[cfg(test)]
#[path = "conversation_tab_transaction_tests.rs"]
mod conversation_tab_transaction_tests;

#[cfg(test)]
#[path = "page_tabs_tests.rs"]
mod page_tabs_tests;
