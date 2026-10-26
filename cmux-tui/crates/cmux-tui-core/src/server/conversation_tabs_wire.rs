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

use crate::panic_free::JsonFields;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use serde::Deserialize;
use serde_json::{Value, json};

use super::{
    BudgetedText, MessageWriter, Mux, PaneId, SurfaceId, WorkspaceId, paired_surface_size,
};
use crate::Actor;
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
    /// What the page shows (`page-tab-route-v1`); only with `page`.
    #[serde(default)]
    route: Option<String>,
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
    /// With `pane`: the tab goes in a new pane split from it
    /// (`conversation-tab-split-v1`).
    #[serde(default)]
    split: Option<ConversationTabSplitParams>,
}

/// The client transaction echo on `new-conversation-tab`.
pub(crate) const CONVERSATION_TAB_TRANSACTION_CAPABILITY: &str = "conversation-tab-transaction-v1";

/// `new-conversation-tab {pane, split}`: the tab is created in a new pane on
/// one side of `pane`, in one `pane.split` commit whose one `pane-added`
/// delta holds the pane with the tab (and carries `transaction`). The
/// source pane never lists the tab.
pub(crate) const CONVERSATION_TAB_SPLIT_CAPABILITY: &str = "conversation-tab-split-v1";

/// The new pane of a conversation tab's split: its side of the source pane
/// and, as `split-client-keys-v1`, the caller-minted public id of the pane.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct ConversationTabSplitParams {
    direction: String,
    #[serde(default)]
    pane_id: Option<String>,
    /// `split-client-split-id-v1`: caller-minted public id of the new split.
    #[serde(default)]
    split_id: Option<String>,
}

impl ConversationTabSplitParams {
    fn target(self, pane: Option<PaneId>) -> anyhow::Result<ConversationTabTarget> {
        let pane = pane.ok_or_else(|| anyhow::anyhow!("bad request: split needs pane"))?;
        let direction = match self.direction.as_str() {
            "right" => "right",
            "down" => "down",
            "left" => "left",
            "up" => "up",
            other => anyhow::bail!(
                "bad request: split direction {other:?} (want right, down, left or up)"
            ),
        };
        if let Some(pane_id) = &self.pane_id {
            crate::resource::PanePublicId::parse(pane_id.clone()).map_err(|_| {
                anyhow::anyhow!("bad request: pane_id {pane_id:?} is not a pane id")
            })?;
        }
        if let Some(split_id) = &self.split_id {
            crate::resource::SplitPublicId::parse(split_id.clone()).map_err(|_| {
                anyhow::anyhow!("bad request: split_id {split_id:?} is not a split id")
            })?;
        }
        Ok(ConversationTabTarget::Split {
            pane,
            direction,
            pane_id: self.pane_id,
            split_id: self.split_id,
        })
    }
}

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

/// The host prefix of a tab whose chat runs on the machine of the store that
/// lists it (`registry:<registry id>`): the app's new chat in a pane of an SSH
/// machine or a Cloud VM.
const MACHINE_HOST_PREFIX: &str = "registry:";

/// A session for a `registry:` tab from anywhere but that machine's own
/// `agent-session-start` (cx-k21v): a session never leaves its machine, so
/// another machine's chat (a Mac's acpmux session or an outside chat it
/// resumes) is never bound into a tab of this one. Two exceptions, both chats
/// of this machine's own acpmux ([`landed_here`]): a chat this daemon itself
/// landed through `agent-transfer-finish`, and a chat an attached tab's
/// session started here as `agent-session-children` listed or followed it.
#[derive(Debug)]
pub(crate) struct MachineMismatch;

impl MachineMismatch {
    pub(crate) const CODE: &'static str = "conversation_tab.machine_mismatch";
}

impl std::fmt::Display for MachineMismatch {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(
            "a tab of this machine starts its chat only through agent-session-start: \
             a session of another machine never binds to it",
        )
    }
}

impl std::error::Error for MachineMismatch {}

/// The `error_code` of a conversation tab change refused here.
pub(super) fn error_code(error: &anyhow::Error) -> Option<String> {
    error.downcast_ref::<MachineMismatch>().map(|_| MachineMismatch::CODE.to_string())
}

/// True when `host` is this store's own and `session` is this machine's chat
/// as this machine's acpmux answered it (the id is never taken from the
/// request that names it): a chat this daemon landed
/// through a guarded `agent-transfer-finish` (Move to Cloud opens the moved
/// chat that way), or a chat an attached tab's session started here, as
/// `agent-session-children` listed or followed it (the app opens a Cloud
/// VM chat's child chat that way).
fn landed_here(mux: &Mux, host: &str, session: &str) -> bool {
    // This store's host, as agent-session-start names it.
    let own = format!("{MACHINE_HOST_PREFIX}{}", mux.registry_identity().0);
    host == own && (landed_agent_session(mux, session) || started_here(mux, session))
}

#[cfg(unix)]
fn landed_agent_session(mux: &Mux, session: &str) -> bool {
    mux.landed_agent_session(session)
}

/// agent-transfer is unix-only (server.rs), so no chat lands here.
#[cfg(not(unix))]
fn landed_agent_session(_mux: &Mux, _session: &str) -> bool {
    false
}

#[cfg(unix)]
fn started_here(mux: &Mux, session: &str) -> bool {
    mux.control_clients.agent_sessions.known_children.contains(session)
}

/// Agent session attach is unix-only (server.rs).
#[cfg(not(unix))]
fn started_here(_mux: &Mux, _session: &str) -> bool {
    false
}

fn record_of(
    mux: &Mux,
    conversation: Option<String>,
    owner: Option<String>,
    agent_session: Option<AgentSessionParams>,
    page: Option<String>,
    route: Option<String>,
) -> anyhow::Result<ConversationTabRecord> {
    anyhow::ensure!(route.is_none() || page.is_some(), "bad request: route needs page");
    match (conversation, owner, agent_session, page) {
        (Some(conversation), Some(owner), None, None) => {
            Ok(ConversationTabRecord::Conversation { conversation, owner })
        }
        (None, None, Some(AgentSessionParams { host, session, harness, host_name }), None) => {
            // A machine's own tab is created without a session; only that
            // machine's agent-session-start binds one, or it names a chat
            // this daemon landed.
            if host.starts_with(MACHINE_HOST_PREFIX)
                && let Some(session) = &session
                && !landed_here(mux, &host, session)
            {
                return Err(MachineMismatch.into());
            }
            Ok(ConversationTabRecord::AgentSession { host, session, harness, host_name })
        }
        (None, None, None, Some(page)) => Ok(ConversationTabRecord::Page { page, route }),
        _ => anyhow::bail!(
            "bad request: send conversation and owner, agent_session, or page: exactly one source"
        ),
    }
}

pub(super) fn create(
    mux: &Arc<Mux>,
    client: u64,
    params: NewConversationTabParams,
) -> anyhow::Result<Value> {
    let NewConversationTabParams {
        pane,
        workspace,
        conversation,
        owner,
        agent_session,
        page,
        route,
        origin,
        mutation_id,
        cols,
        rows,
        transaction,
        split,
    } = params;
    super::validate_client_transaction(transaction.as_deref())?;
    let target = match (pane, workspace, split) {
        (_, None, Some(split)) => split.target(pane)?,
        (_, None, None) => ConversationTabTarget::Pane(pane),
        (None, Some(workspace), None) => ConversationTabTarget::Workspace(workspace),
        (_, Some(_), Some(_)) => anyhow::bail!("bad request: split goes with pane, not workspace"),
        (Some(_), Some(_), None) => anyhow::bail!("bad request: send pane or workspace, not both"),
    };
    let actor = super::origin_gate::connection_actor(mux, client);
    let mutation = match (origin, mutation_id) {
        (Some(origin), Some(id)) => Some(WorkspaceMutation::new(id, origin, actor.clone())?),
        (None, None) => None,
        _ => anyhow::bail!("bad request: origin and mutation_id are sent together"),
    };
    let size = paired_surface_size("new-conversation-tab", cols, rows)?;
    let record = record_of(mux, conversation, owner, agent_session, page, route)?;
    // The creation's own `tab-added` carries `transaction`: one delta per
    // tab. A replay emits nothing and echoes it in the result only.
    let outcome = mux.new_conversation_tab_as(
        &actor,
        target,
        record.clone(),
        mutation.as_ref(),
        size,
        transaction.as_deref(),
    )?;
    let identity = outcome.surface.resource_identity();
    // A replay returns the tab's current record (a bound session included).
    let record = mux.conversation_tab_of(&outcome.surface).unwrap_or(record);
    let mut result = json!({
        "surface": outcome.surface.id,
        "tab_resource_id": identity.map(|identity| identity.tab_id.as_str()),
        "content_resource_id": identity.map(|identity| identity.content_id.as_str()),
        "conversation": record.wire(),
        "replayed": outcome.replayed,
    });
    if let Some(transaction) = transaction {
        result.insert("transaction", json!(transaction));
    }
    Ok(result)
}

/// `bind-conversation-tab-session`: set an agent tab's session to `session`
/// when its current session is `expected_session` (null: unbound), and its
/// harness to `harness` when given.
#[derive(Deserialize)]
pub(super) struct BindSessionParams {
    surface: SurfaceId,
    session: String,
    /// Required; JSON null names an unbound tab.
    #[serde(deserialize_with = "required_nullable")]
    expected_session: Option<String>,
    /// The agent the session runs, as its machine's acpmux reports it; set
    /// in the same commit (a bind of the tab's own session with another
    /// harness updates the harness alone).
    #[serde(default)]
    harness: Option<String>,
}

/// A field that must be present and may be null (serde treats a missing
/// `Option` field as null unless the field has its own deserializer).
fn required_nullable<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Option<String>, D::Error> {
    Option::deserialize(deserializer)
}

pub(super) fn bind(
    mux: &Arc<Mux>,
    actor: &Actor,
    params: BindSessionParams,
) -> anyhow::Result<Value> {
    let BindSessionParams { surface, session, expected_session, harness } = params;
    // A machine's own tab binds only through agent-session-start (which
    // binds in the store directly, never through this command).
    let machine_tab = mux.surface(surface).and_then(|runtime| mux.conversation_tab_of(&runtime));
    if let Some(ConversationTabRecord::AgentSession { host, .. }) = machine_tab
        && host.starts_with(MACHINE_HOST_PREFIX)
    {
        return Err(MachineMismatch.into());
    }
    let expected = expected_session.as_deref();
    // No write to or for a teammate's attachment lands between its tab check and its write
    // (agent_session_attach.rs `while_shared`).
    #[cfg(unix)]
    let _rebinding = mux.control_clients.agent_sessions.rebinding();
    let (record, replayed) = mux.bind_conversation_tab_session_as(
        actor,
        surface,
        &session,
        expected,
        harness.as_deref(),
    )?;
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

#[cfg(test)]
#[path = "conversation_tab_split_tests.rs"]
mod conversation_tab_split_tests;
